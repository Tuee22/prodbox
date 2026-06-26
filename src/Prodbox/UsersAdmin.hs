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
  , inviteUserAtPublicHost
  , listUsers
  , revokeUser
  , revokeUserAtPublicHost
  , reconcileRealmOidcSecretsAtPublicHost
  , loadKeycloakAdminPassword
  , loadKeycloakSmtpSettings
  , smtpSettingsFromVaultFields
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Command (UsersListStatus (..))
import Prodbox.Keycloak.Admin
  ( KeycloakClient
  , NewUser (..)
  , RealmSmtpSettings (..)
  , UserRecord (..)
  , acquireAdminToken
  , createUser
  , deleteUser
  , disableUser
  , ensureRealmSmtpSettings
  , executeActionsEmail
  , withKeycloakClient
  , withKeycloakClientAtPublicHost
  )
import Prodbox.Keycloak.Admin qualified as KCAdmin
import Prodbox.Result (Result (..))
import Prodbox.Settings (ValidatedSettings)
import Prodbox.Vault.Host
  ( readHostVaultKvField
  , readHostVaultKvObject
  )

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

-- | Read the Keycloak admin password from Vault KV. The operator-facing users
-- CLI targets the shared public stack, where Keycloak is deployed transitively
-- by the @vscode@ root chart and therefore reads @secret/vscode/keycloak/admin@.
-- This is intentionally a Vault read: if Vault is sealed, unreachable, or the
-- field is missing, admin flows fail loud instead of falling back to a
-- Kubernetes Secret.
loadKeycloakAdminPassword :: FilePath -> IO (Either String Text)
loadKeycloakAdminPassword repoRoot =
  readHostVaultKvField repoRoot "secret" "vscode/keycloak/admin" "password"

-- | Read Keycloak SMTP settings from the externally-owned Vault KV object fed
-- by the AWS SES setup path. A missing path or denied policy is a retryable
-- setup error, not a signal to read any non-Vault store.
loadKeycloakSmtpSettings :: FilePath -> IO (Either String RealmSmtpSettings)
loadKeycloakSmtpSettings repoRoot = do
  fieldsResult <- readHostVaultKvObject repoRoot "secret" "keycloak/smtp"
  pure $ fieldsResult >>= smtpSettingsFromVaultFields

smtpSettingsFromVaultFields :: Map Text Text -> Either String RealmSmtpSettings
smtpSettingsFromVaultFields fields =
  RealmSmtpSettings
    <$> requireVaultField fields "host"
    <*> requireVaultField fields "port"
    <*> requireVaultField fields "from"
    <*> requireVaultField fields "from_display_name"
    <*> requireVaultField fields "reply_to"
    <*> requireVaultField fields "username"
    <*> requireVaultField fields "password"

requireVaultField :: Map Text Text -> Text -> Either String Text
requireVaultField fields fieldName =
  case Map.lookup fieldName fields of
    Nothing ->
      Left ("keycloak/smtp Vault KV object missing `" <> Text.unpack fieldName <> "`")
    Just value
      | Text.null (Text.strip value) ->
          Left ("keycloak/smtp Vault KV field `" <> Text.unpack fieldName <> "` is empty")
      | otherwise -> Right value

-- | Invite a new operator-owned user. Creates the Keycloak user with `enabled: true`,
-- `emailVerified: false`, and `requiredActions: ["VERIFY_EMAIL", "UPDATE_PASSWORD"]`,
-- then triggers Keycloak's SES-backed invite email. Returns the created user summary
-- on success.
inviteUser
  :: FilePath -> ValidatedSettings -> String -> Maybe String -> IO (Either String UserSummary)
inviteUser repoRoot settings email maybeRole =
  inviteUserWith
    (withAdminClient repoRoot settings)
    (loadKeycloakSmtpSettings repoRoot)
    email
    maybeRole

inviteUserAtPublicHost
  :: FilePath -> Text -> String -> Maybe String -> IO (Either String UserSummary)
inviteUserAtPublicHost repoRoot publicHost email maybeRole =
  inviteUserWith
    (withAdminClientAtPublicHost repoRoot publicHost)
    (loadKeycloakSmtpSettings repoRoot)
    email
    maybeRole

inviteUserWith
  :: ((KeycloakClient -> Text -> IO (Either String UserSummary)) -> IO (Either String UserSummary))
  -> IO (Either String RealmSmtpSettings)
  -> String
  -> Maybe String
  -> IO (Either String UserSummary)
inviteUserWith withClient loadSmtpSettings email maybeRole =
  withClient $ \client token -> do
    smtpResult <- loadSmtpSettings
    case smtpResult of
      Left err -> pure (Left ("Keycloak SMTP settings load failed: " <> err))
      Right smtpSettings -> do
        smtpUpdateResult <- ensureRealmSmtpSettings client token smtpSettings
        case smtpUpdateResult of
          Failure err -> pure (Left ("Keycloak realm SMTP update failed: " <> err))
          Success () -> createAndTriggerInvite client token
 where
  createAndTriggerInvite client token = do
    let payload =
          NewUser
            { newUserEmail = Text.pack email
            , newUserRole = fmap Text.pack maybeRole
            }
    createResult <- createUser client token payload
    case createResult of
      Failure err -> pure (Left ("Keycloak user creation failed: " <> err))
      Success userId -> triggerInviteEmail client token userId

  triggerInviteEmail client token userId = do
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
  revokeUserWith (withAdminClient repoRoot settings) ident hardDelete

revokeUserAtPublicHost :: FilePath -> Text -> String -> Bool -> IO (Either String ())
revokeUserAtPublicHost repoRoot publicHost ident hardDelete =
  revokeUserWith (withAdminClientAtPublicHost repoRoot publicHost) ident hardDelete

revokeUserWith
  :: ((KeycloakClient -> Text -> IO (Either String ())) -> IO (Either String ()))
  -> String
  -> Bool
  -> IO (Either String ())
revokeUserWith withClient ident hardDelete =
  withClient $ \client token -> do
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

withAdminClientAtPublicHost
  :: FilePath
  -> Text
  -> (KeycloakClient -> Text -> IO (Either String a))
  -> IO (Either String a)
withAdminClientAtPublicHost repoRoot publicHost action = do
  passwordResult <- loadKeycloakAdminPassword repoRoot
  case passwordResult of
    Left err -> pure (Left err)
    Right password ->
      withKeycloakClientAtPublicHost publicHost "admin" password "prodbox" $ \client -> do
        tokenResult <- acquireAdminToken client
        case tokenResult of
          Failure err -> pure (Left ("Keycloak admin token acquisition failed: " <> err))
          Success token -> action client token

-- | Sprint 5.10 follow-up (durable fix for the charts-vscode OIDC 401): reconcile
-- the realm's OIDC client secrets (@prodbox-api@, @prodbox-websocket@, @vscode@)
-- and the @demo-user@ password with Vault via the admin API.
--
-- @--import-realm@ is @IGNORE_EXISTING@ and never updates an existing realm, and
-- the OIDC secrets in Vault are write-if-absent (stable). So when a preserved
-- Keycloak database and Vault drift, the realm keeps the secrets from its first
-- import and the password grant fails with @invalid_client_credentials@. This
-- patches the live realm to match Vault on every reconcile — idempotent, and the
-- admin-API analog of the realm-SMTP reconcile that already exists for the same
-- import-skip reason.
reconcileRealmOidcSecretsAtPublicHost :: FilePath -> Text -> IO (Either String ())
reconcileRealmOidcSecretsAtPublicHost repoRoot publicHost = do
  let clientSpecs =
        [ ("prodbox-api", "vscode/oidc/prodbox-api")
        , ("prodbox-websocket", "vscode/oidc/prodbox-websocket")
        , ("vscode", "vscode/oidc/vscode")
        ]
  secretReads <-
    mapM
      (\(_, path) -> readHostVaultKvField repoRoot "secret" path "client_secret")
      clientSpecs
  demoPasswordResult <-
    readHostVaultKvField repoRoot "secret" "vscode/oidc/demo-user" "password"
  case (sequence secretReads, demoPasswordResult) of
    (Left err, _) -> pure (Left ("realm OIDC reconcile: " <> err))
    (_, Left err) -> pure (Left ("realm OIDC reconcile: " <> err))
    (Right clientSecrets, Right demoPassword) ->
      withAdminClientAtPublicHost repoRoot publicHost $ \client token ->
        runReconcileSteps
          ( [ KCAdmin.setClientSecret client token clientId secretValue
            | (clientId, secretValue) <- zip (map fst clientSpecs) clientSecrets
            ]
              ++ [KCAdmin.resetUserPassword client token "demo-user" demoPassword]
          )
 where
  runReconcileSteps [] = pure (Right ())
  runReconcileSteps (step : rest) = do
    result <- step
    case result of
      Success () -> runReconcileSteps rest
      Failure err -> pure (Left ("realm OIDC reconcile: " <> err))
