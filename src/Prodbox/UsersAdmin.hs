{-# LANGUAGE OverloadedStrings #-}

-- | Operator-facing user management surface backed by the Keycloak admin API.
--
-- The wire-protocol live HTTP integration lives in `Prodbox.Keycloak.Admin`; this
-- module composes the admin client with the chart-platform-managed
-- `keycloak_admin_password` secret and exposes the public `prodbox users …`
-- semantics: `inviteUser` creates the user + triggers the SES-backed invite,
-- `listUsers` projects Keycloak's user payload onto the operator-facing
-- `UserSummary`, and `revokeUser` either disables or deletes (with `--delete`).
module Prodbox.UsersAdmin
  ( UserSummary (..)
  , UserVerificationStatus (..)
  , inviteUser
  , listUsers
  , revokeUser
  , loadKeycloakAdminPassword
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Command (UsersListStatus (..))
import Prodbox.Keycloak.Admin
  ( KeycloakClient
  , NewUser (..)
  , UserRecord (..)
  , acquireAdminToken
  , createUser
  , deleteUser
  , disableUser
  , executeActionsEmail
  , withKeycloakClient
  )
import Prodbox.Keycloak.Admin qualified as KCAdmin
import Prodbox.Result (Result (..))
import Prodbox.Settings (ValidatedSettings)
import System.FilePath ((</>))

data UserVerificationStatus
  = UserVerified
  | UserUnverified
  deriving (Eq, Show)

data UserSummary = UserSummary
  { userSummaryId :: Text
  , userSummaryUsername :: Text
  , userSummaryEmail :: Text
  , userSummaryVerification :: UserVerificationStatus
  , userSummaryLastLogin :: Maybe Text
  }
  deriving (Eq, Show)

-- | Read the chart-platform-managed `keycloak_admin_password` from
-- `.prodbox-state/charts/keycloak/.secrets.json`. This file is owned by
-- `Prodbox.Lib.ChartPlatform.resolveChartSecrets`; reading it here keeps
-- `Prodbox.UsersAdmin` decoupled from the chart-platform module graph.
loadKeycloakAdminPassword :: FilePath -> IO (Either String Text)
loadKeycloakAdminPassword repoRoot = do
  let secretsPath = repoRoot </> ".prodbox-state" </> "charts" </> "keycloak" </> ".secrets.json"
  attempt <- try (BS.readFile secretsPath)
  case attempt of
    Left ioe ->
      pure
        ( Left
            ( "could not read "
                <> secretsPath
                <> ": "
                <> show (ioe :: IOException)
                <> " — run `prodbox charts deploy keycloak` first so the chart-platform secrets exist."
            )
        )
    Right bytes ->
      case eitherDecodeStrict bytes of
        Left err -> pure (Left ("could not parse " <> secretsPath <> ": " <> err))
        Right (raw :: Map String String) ->
          case Map.lookup "keycloak_admin_password" raw of
            Nothing ->
              pure
                ( Left
                    ( secretsPath
                        <> " is missing `keycloak_admin_password`; rerun `prodbox charts deploy keycloak`."
                    )
                )
            Just value -> pure (Right (Text.pack value))

-- | Invite a new operator-owned user. Creates the Keycloak user with `enabled: true`,
-- `emailVerified: false`, and `requiredActions: ["VERIFY_EMAIL", "UPDATE_PASSWORD"]`,
-- then triggers Keycloak's SES-backed invite email. Returns the created user summary
-- on success.
inviteUser
  :: FilePath -> ValidatedSettings -> String -> Maybe String -> IO (Either String UserSummary)
inviteUser repoRoot settings email maybeRole =
  withAdminClient repoRoot settings $ \client token -> do
    let payload =
          NewUser
            { newUserEmail = Text.pack email
            , newUserRole = fmap Text.pack maybeRole
            }
    createResult <- createUser client token payload
    case createResult of
      Failure err -> pure (Left ("Keycloak user creation failed: " <> err))
      Success userId -> do
        let actions = ["VERIFY_EMAIL", "UPDATE_PASSWORD"]
        triggerResult <- executeActionsEmail client token userId actions
        case triggerResult of
          Failure err -> pure (Left ("Keycloak invite-email trigger failed: " <> err))
          Success () ->
            pure
              ( Right
                  UserSummary
                    { userSummaryId = userId
                    , userSummaryUsername = Text.pack email
                    , userSummaryEmail = Text.pack email
                    , userSummaryVerification = UserUnverified
                    , userSummaryLastLogin = Nothing
                    }
              )

-- | List users currently known to Keycloak with their email-verification status.
listUsers :: FilePath -> ValidatedSettings -> UsersListStatus -> IO (Either String [UserSummary])
listUsers repoRoot settings status =
  withAdminClient repoRoot settings $ \client token -> do
    result <- KCAdmin.listUsers client token
    case result of
      Failure err -> pure (Left ("Keycloak user listing failed: " <> err))
      Success records ->
        let filtered = filter (matchesFilter status) records
            summaries = map toSummary filtered
         in pure (Right summaries)
 where
  toSummary record =
    UserSummary
      { userSummaryId = userRecordId record
      , userSummaryUsername = userRecordUsername record
      , userSummaryEmail = userRecordEmail record
      , userSummaryVerification =
          if userRecordEmailVerified record
            then UserVerified
            else UserUnverified
      , userSummaryLastLogin = Nothing
      }
  matchesFilter UsersAll _ = True
  matchesFilter UsersVerified record = userRecordEmailVerified record
  matchesFilter UsersUnverified record = not (userRecordEmailVerified record)

-- | Revoke (disable, or delete with `hardDelete`) an existing user. `ident` may be a
-- raw Keycloak user id or an email; in the email case the function resolves the id via
-- `listUsers` first.
revokeUser :: FilePath -> ValidatedSettings -> String -> Bool -> IO (Either String ())
revokeUser repoRoot settings ident hardDelete =
  withAdminClient repoRoot settings $ \client token -> do
    userIdResult <- resolveUserId client token (Text.pack ident)
    case userIdResult of
      Left err -> pure (Left err)
      Right userId ->
        if hardDelete
          then do
            result <- deleteUser client token userId
            pure $ case result of
              Failure err -> Left ("Keycloak user delete failed: " <> err)
              Success () -> Right ()
          else do
            result <- disableUser client token userId
            pure $ case result of
              Failure err -> Left ("Keycloak user disable failed: " <> err)
              Success () -> Right ()
 where
  resolveUserId client token candidate
    | Text.elem '@' candidate = do
        listing <- KCAdmin.listUsers client token
        case listing of
          Failure err -> pure (Left ("listing users to resolve `" <> Text.unpack candidate <> "`: " <> err))
          Success records ->
            case filter (\r -> userRecordEmail r == candidate) records of
              [match] -> pure (Right (userRecordId match))
              [] -> pure (Left ("no Keycloak user found with email `" <> Text.unpack candidate <> "`"))
              _ ->
                pure
                  ( Left
                      ("multiple Keycloak users matched email `" <> Text.unpack candidate <> "` — pass the user id instead")
                  )
    | otherwise = pure (Right candidate)

-- Internal: build the Keycloak admin client, acquire a token, and run the supplied
-- action. The realm and admin user are hardcoded constants matching the chart's
-- `keycloak.realmName` / `keycloak.adminUser` values; the admin password is read from
-- the chart-platform-managed secret store via `loadKeycloakAdminPassword`.
withAdminClient
  :: FilePath
  -> ValidatedSettings
  -> (KeycloakClient -> Text -> IO (Either String a))
  -> IO (Either String a)
withAdminClient repoRoot settings action = do
  passwordResult <- loadKeycloakAdminPassword repoRoot
  case passwordResult of
    Left err -> pure (Left err)
    Right password ->
      withKeycloakClient settings "admin" password "prodbox" $ \client -> do
        tokenResult <- acquireAdminToken client
        case tokenResult of
          Failure err -> pure (Left ("Keycloak admin token acquisition failed: " <> err))
          Success token -> action client token
