{-# LANGUAGE OverloadedStrings #-}

-- | Keycloak admin API HTTP client.
--
-- This module owns the operator-invited Phase 8 surface: token acquisition via the
-- password grant on the master realm, user CRUD on the configured realm, and the
-- `execute-actions-email` invite-trigger endpoint. The shape mirrors `Prodbox.Result`
-- so the existing `prodbox users …` dispatcher in `Prodbox.CLI.Users` and the
-- `ValidationKeycloakInvite` body in `Prodbox.TestValidation` consume the same
-- failure shape every other validation arm uses.
--
-- The base URL is derived from `domain.demo_fqdn` plus the canonical `/auth` path
-- prefix (matches the Keycloak chart's `keycloak.httpRelativePath` constant). The
-- realm is hardcoded to `prodbox` (matches `keycloak.realmName`). The admin
-- credentials are read from the chart-platform-managed `.prodbox-state/charts/keycloak/.secrets.json`
-- (`keycloak_admin_password`) — callers resolve these and pass them into
-- `withKeycloakClient`, so this module stays free of `Prodbox.Lib.ChartPlatform`
-- dependencies.
module Prodbox.Keycloak.Admin
  ( KeycloakClient (..)
  , NewUser (..)
  , UserRecord (..)
  , buildKeycloakBaseUrl
  , withKeycloakClient
  , acquireAdminToken
  , createUser
  , listUsers
  , disableUser
  , deleteUser
  , executeActionsEmail
  )
where

import Control.Exception (catch)
import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode, object, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, parseJSON, withObject)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)
import Network.HTTP.Client
  ( HttpException
  , Manager
  , Request (..)
  , RequestBody (..)
  , Response (..)
  , httpLbs
  , parseRequest
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Header (hAuthorization, hContentType)
import Network.HTTP.Types.Status (Status (..))
import Prodbox.Result (Result (..))
import Prodbox.Settings (DomainSection (..), ValidatedSettings (..), demo_fqdn, domain)
import Prodbox.Settings qualified as Settings

-- | A live Keycloak admin client. Holds a shared TLS manager, the resolved base URL
-- (e.g. `https://test.resolvefintech.com/auth`), the target realm, and the admin
-- credentials needed to refresh the bearer token.
data KeycloakClient = KeycloakClient
  { keycloakManager :: Manager
  , keycloakBaseUrl :: Text
  , keycloakRealm :: Text
  , keycloakAdminUser :: Text
  , keycloakAdminPassword :: Text
  }

-- | Body for creating a new operator-invited user. Matches the realm config seeded by
-- the Sprint 8.2 Keycloak chart (`emailVerified=false`, `requiredActions=["VERIFY_EMAIL"]`).
data NewUser = NewUser
  { newUserEmail :: Text
  , newUserRole :: Maybe Text
  }
  deriving (Eq, Show)

-- | Inbound user shape from `GET /admin/realms/<realm>/users`. Captures the fields the
-- `prodbox users list` CLI surface and the `ValidationKeycloakInvite` arm care about;
-- silently drops fields outside the listed set so the parser is forward-compatible.
data UserRecord = UserRecord
  { userRecordId :: Text
  , userRecordUsername :: Text
  , userRecordEmail :: Text
  , userRecordEmailVerified :: Bool
  , userRecordEnabled :: Bool
  }
  deriving (Eq, Show, Generic)

instance FromJSON UserRecord where
  parseJSON = withObject "UserRecord" $ \v ->
    UserRecord
      <$> v .: "id"
      <*> (fromMaybe "" <$> v .:? "username")
      <*> (fromMaybe "" <$> v .:? "email")
      <*> (fromMaybe False <$> v .:? "emailVerified")
      <*> (fromMaybe True <$> v .:? "enabled")

instance ToJSON UserRecord where
  toJSON record =
    object
      [ "id" .= userRecordId record
      , "username" .= userRecordUsername record
      , "email" .= userRecordEmail record
      , "emailVerified" .= userRecordEmailVerified record
      , "enabled" .= userRecordEnabled record
      ]

-- | Derive the Keycloak base URL from the configured public FQDN.
--
-- The Keycloak chart is deployed behind Envoy Gateway on the canonical public host with
-- the `/auth` path prefix (per `Prodbox.PublicEdge.authPathPrefix`). This helper keeps
-- the admin client aligned with the chart's `keycloak.httpRelativePath` constant.
buildKeycloakBaseUrl :: ValidatedSettings -> Text
buildKeycloakBaseUrl settings =
  let fqdn = Text.strip (demo_fqdn (domain (validatedConfig settings)))
   in "https://" <> fqdn <> "/auth"

-- | Bracket a Keycloak admin client. Constructs a single TLS manager and threads the
-- caller-supplied admin credentials through.
--
-- Callers resolve the admin password via `Prodbox.Lib.ChartPlatform.resolveChartSecrets
-- repoRoot "keycloak"` (looking up `keycloak_admin_password`) before invoking this; the
-- chart platform owns the secrets, the admin client owns the wire protocol.
withKeycloakClient
  :: ValidatedSettings
  -> Text
  -- ^ admin username (defaults to chart's `keycloak.adminUser`, typically `admin`)
  -> Text
  -- ^ admin password (from the chart-platform-managed secret store)
  -> Text
  -- ^ realm name (typically `prodbox`)
  -> (KeycloakClient -> IO a)
  -> IO a
withKeycloakClient settings adminUser adminPass realm action = do
  manager <- newTlsManager
  action
    KeycloakClient
      { keycloakManager = manager
      , keycloakBaseUrl = buildKeycloakBaseUrl settings
      , keycloakRealm = realm
      , keycloakAdminUser = adminUser
      , keycloakAdminPassword = adminPass
      }

-- | Acquire a bearer token via the password grant against the master realm. Returns
-- the raw `access_token` value; callers are responsible for refreshing if they keep
-- the token across the 30 s default Keycloak validity.
acquireAdminToken :: KeycloakClient -> IO (Result Text)
acquireAdminToken client = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/realms/master/protocol/openid-connect/token"
      body =
        BL8.pack $
          "grant_type=password"
            <> "&client_id=admin-cli"
            <> "&username="
            <> Text.unpack (keycloakAdminUser client)
            <> "&password="
            <> Text.unpack (keycloakAdminPassword client)
  reqInit <- parseRequest url
  let req =
        reqInit
          { method = "POST"
          , requestHeaders =
              [(hContentType, "application/x-www-form-urlencoded")]
          , requestBody = RequestBodyLBS body
          }
  performJsonRequest "Keycloak admin token acquisition" client req parseAccessToken

-- | Create a new operator-invited user. Returns the Keycloak user id parsed out of the
-- `Location` header (which Keycloak emits on a successful 201).
createUser :: KeycloakClient -> Text -> NewUser -> IO (Result Text)
createUser client token newUser = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/admin/realms/"
          <> Text.unpack (keycloakRealm client)
          <> "/users"
      payload =
        object
          [ "enabled" .= True
          , "email" .= newUserEmail newUser
          , "username" .= newUserEmail newUser
          , "emailVerified" .= False
          , "requiredActions" .= (["VERIFY_EMAIL"] :: [Text])
          ]
  reqInit <- parseRequest url
  let req =
        reqInit
          { method = "POST"
          , requestHeaders =
              [ (hContentType, "application/json")
              , (hAuthorization, "Bearer " <> Text.encodeUtf8 token)
              ]
          , requestBody = RequestBodyLBS (encode payload)
          }
  performRawRequest "Keycloak user creation" client req handleCreateUserResponse

-- | List all users in the configured realm. Forward-compatible: unknown fields are
-- dropped during decode.
listUsers :: KeycloakClient -> Text -> IO (Result [UserRecord])
listUsers client token = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/admin/realms/"
          <> Text.unpack (keycloakRealm client)
          <> "/users?max=200"
  reqInit <- parseRequest url
  let req =
        reqInit
          { requestHeaders = [(hAuthorization, "Bearer " <> Text.encodeUtf8 token)]
          }
  performJsonRequest "Keycloak user listing" client req parseUserListing

-- | Disable a user (`enabled: false`). Keycloak treats this as a soft revoke.
disableUser :: KeycloakClient -> Text -> Text -> IO (Result ())
disableUser client token userId = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/admin/realms/"
          <> Text.unpack (keycloakRealm client)
          <> "/users/"
          <> Text.unpack userId
      payload = object ["enabled" .= False]
  reqInit <- parseRequest url
  let req =
        reqInit
          { method = "PUT"
          , requestHeaders =
              [ (hContentType, "application/json")
              , (hAuthorization, "Bearer " <> Text.encodeUtf8 token)
              ]
          , requestBody = RequestBodyLBS (encode payload)
          }
  performRawRequest "Keycloak user disable" client req (expect204 "user disable")

-- | Hard-delete a user from Keycloak.
deleteUser :: KeycloakClient -> Text -> Text -> IO (Result ())
deleteUser client token userId = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/admin/realms/"
          <> Text.unpack (keycloakRealm client)
          <> "/users/"
          <> Text.unpack userId
  reqInit <- parseRequest url
  let req =
        reqInit
          { method = "DELETE"
          , requestHeaders =
              [(hAuthorization, "Bearer " <> Text.encodeUtf8 token)]
          }
  performRawRequest "Keycloak user delete" client req (expect204 "user delete")

-- | Trigger the invite email by asking Keycloak to send the listed required actions to
-- the user. The `prodbox users invite` flow uses `["VERIFY_EMAIL", "UPDATE_PASSWORD"]`
-- so the user lands on the credential-setup page after clicking through.
executeActionsEmail :: KeycloakClient -> Text -> Text -> [Text] -> IO (Result ())
executeActionsEmail client token userId actions = do
  let url =
        Text.unpack (keycloakBaseUrl client)
          <> "/admin/realms/"
          <> Text.unpack (keycloakRealm client)
          <> "/users/"
          <> Text.unpack userId
          <> "/execute-actions-email?client_id=account"
      payload = Aeson.toJSON actions
  reqInit <- parseRequest url
  let req =
        reqInit
          { method = "PUT"
          , requestHeaders =
              [ (hContentType, "application/json")
              , (hAuthorization, "Bearer " <> Text.encodeUtf8 token)
              ]
          , requestBody = RequestBodyLBS (encode payload)
          }
  performRawRequest "Keycloak execute-actions-email" client req (expect204 "execute-actions-email")

-- Internal helpers.

-- | Named handler helpers extracted from the dispatch sites so the doctrine's
-- "Avoid case inside lambda body" style guard stays clean. Each helper is a
-- pure function from `Response` (or `Value`) to `Result`.
parseAccessToken :: Value -> Result Text
parseAccessToken value =
  case parseEither (\v -> withObject "TokenResponse" (.: "access_token") v) value of
    Left err -> Failure ("could not parse access_token from token response: " <> err)
    Right token -> Success token

parseUserListing :: Value -> Result [UserRecord]
parseUserListing value =
  case parseEither parseJSON value of
    Left err -> Failure ("user listing payload decode failed: " <> err)
    Right records -> Success records

handleCreateUserResponse :: Response ByteString -> Result Text
handleCreateUserResponse resp =
  case statusCode (responseStatus resp) of
    201 -> resolveCreatedUserId resp
    code -> Failure (renderHttpFailure "user create" code (responseBody resp))

resolveCreatedUserId :: Response ByteString -> Result Text
resolveCreatedUserId resp =
  case lookup "Location" (responseHeaders resp) of
    Just loc ->
      let locText = Text.decodeUtf8 loc
          userId = Text.reverse (Text.takeWhile (/= '/') (Text.reverse locText))
       in if Text.null userId
            then Failure "user create returned 201 without parsable Location"
            else Success userId
    Nothing -> Failure "user create returned 201 without Location header"

expect204 :: String -> Response ByteString -> Result ()
expect204 label resp =
  case statusCode (responseStatus resp) of
    204 -> Success ()
    code -> Failure (renderHttpFailure label code (responseBody resp))

performRawRequest
  :: String
  -> KeycloakClient
  -> Request
  -> (Response ByteString -> Result a)
  -> IO (Result a)
performRawRequest label client req handler =
  (handler <$> httpLbs req (keycloakManager client))
    `catch` httpExceptionHandler label

httpExceptionHandler :: String -> HttpException -> IO (Result a)
httpExceptionHandler label exception =
  pure (Failure (label <> " failed: " <> show exception))

performJsonRequest
  :: String
  -> KeycloakClient
  -> Request
  -> (Value -> Result a)
  -> IO (Result a)
performJsonRequest label client req handler =
  performRawRequest label client req (interpretJsonResponse label handler)

interpretJsonResponse
  :: String
  -> (Value -> Result a)
  -> Response ByteString
  -> Result a
interpretJsonResponse label handler resp =
  let code = statusCode (responseStatus resp)
   in if code >= 200 && code < 300
        then decodeJsonBody label handler (responseBody resp)
        else Failure (renderHttpFailure label code (responseBody resp))

decodeJsonBody :: String -> (Value -> Result a) -> ByteString -> Result a
decodeJsonBody label handler body =
  case eitherDecode body of
    Left err -> Failure (label <> ": failed to decode JSON: " <> err)
    Right value -> handler value

renderHttpFailure :: String -> Int -> ByteString -> String
renderHttpFailure label code body =
  let excerpt = take 200 (BL8.unpack body)
   in label
        <> " returned HTTP "
        <> show code
        <> (if null excerpt then "" else " — body: " <> excerpt)

-- Suppress -Wunused-imports for fields we want exported via the record but used only
-- by callers.
_unusedSettings :: ValidatedSettings -> ()
_unusedSettings _ = ()

_unusedDomainSection :: DomainSection -> ()
_unusedDomainSection _ = ()

_unusedSettingsModule :: ()
_unusedSettingsModule = Settings.supportedPublicHostname `seq` ()

_unusedBL :: BL.ByteString -> ()
_unusedBL _ = ()
