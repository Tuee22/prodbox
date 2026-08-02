{-# LANGUAGE OverloadedStrings #-}

-- | Operator-facing user management through the exact Keycloak consumer.
--
-- The operator host never reads a Keycloak, SMTP, or OIDC secret.  A closed
-- operation is executed inside the Keycloak Pod, where the workload sources
-- its own Vault-Kubernetes-auth projection.  Only non-secret user/status JSON
-- crosses back over the Kubernetes exec channel.
module Prodbox.UsersAdmin
  ( UserSummary (..)
  , UserVerificationStatus (..)
  , inviteUser
  , inviteUserAtPublicHost
  , listUsers
  , revokeUser
  , revokeUserAtPublicHost
  , reconcileRealmOidcSecretsAtPublicHost
  , issueDemoOidcAccessToken
  , issueUserOidcAccessToken
  )
where

import Control.Monad qualified
import Data.Aeson (eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Command (UsersListStatus (..))
import Prodbox.ControlPlane.TargetMaterialRegistry (OidcIdentity (..))
import Prodbox.Error (errorMsg)
import Prodbox.Keycloak.Admin (UserRecord (..))
import Prodbox.Settings (ValidatedSettings)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

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

data KeycloakConsumerOperation
  = ConsumerInvite !Text !(Maybe Text)
  | ConsumerList
  | ConsumerDisable !Text
  | ConsumerDelete !Text
  | ConsumerReconcileRuntime
  | ConsumerIssueDemoToken !OidcIdentity
  | ConsumerIssueUserToken !OidcIdentity !Text !Text
  deriving (Eq, Show)

inviteUser
  :: FilePath -> ValidatedSettings -> String -> Maybe String -> IO (Either String UserSummary)
inviteUser repoRoot _settings email maybeRole =
  inviteUserThroughConsumer repoRoot email maybeRole

inviteUserAtPublicHost
  :: FilePath -> Text -> String -> Maybe String -> IO (Either String UserSummary)
inviteUserAtPublicHost repoRoot _publicHost email maybeRole =
  inviteUserThroughConsumer repoRoot email maybeRole

inviteUserThroughConsumer :: FilePath -> String -> Maybe String -> IO (Either String UserSummary)
inviteUserThroughConsumer repoRoot email maybeRole =
  case validateInviteArguments email maybeRole of
    Left err -> pure (Left err)
    Right (validatedEmail, validatedRole) -> do
      reconciled <- runKeycloakConsumerOperation repoRoot ConsumerReconcileRuntime
      case reconciled of
        Left err -> pure (Left ("Keycloak runtime-material reconcile failed: " <> err))
        Right _ -> do
          created <-
            runKeycloakConsumerOperation
              repoRoot
              (ConsumerInvite validatedEmail validatedRole)
          pure $ do
            userId <- created
            if Text.null (Text.strip userId)
              then Left "Keycloak user creation returned an empty user id"
              else
                Right
                  UserSummary
                    { userSummaryId = Text.strip userId
                    , userSummaryUsername = validatedEmail
                    , userSummaryEmail = validatedEmail
                    , userSummaryVerification = UserUnverified
                    , userSummaryLastLogin = Nothing
                    }

listUsers :: FilePath -> ValidatedSettings -> UsersListStatus -> IO (Either String [UserSummary])
listUsers repoRoot _settings status = do
  result <- runKeycloakConsumerOperation repoRoot ConsumerList
  pure $ do
    payload <- result
    records <-
      either
        (Left . ("Keycloak user listing JSON decode failed: " <>))
        Right
        (eitherDecode (LazyChar8.pack (Text.unpack payload)))
    Right (map toSummary (filter (matchesFilter status) records))
 where
  toSummary record =
    UserSummary
      { userSummaryId = userRecordId record
      , userSummaryUsername = userRecordUsername record
      , userSummaryEmail = userRecordEmail record
      , userSummaryVerification =
          if userRecordEmailVerified record then UserVerified else UserUnverified
      , userSummaryLastLogin = Nothing
      }
  matchesFilter UsersAll _ = True
  matchesFilter UsersVerified record = userRecordEmailVerified record
  matchesFilter UsersUnverified record = not (userRecordEmailVerified record)

revokeUser :: FilePath -> ValidatedSettings -> String -> Bool -> IO (Either String ())
revokeUser repoRoot _settings ident hardDelete =
  revokeUserThroughConsumer repoRoot ident hardDelete

revokeUserAtPublicHost :: FilePath -> Text -> String -> Bool -> IO (Either String ())
revokeUserAtPublicHost repoRoot _publicHost ident hardDelete =
  revokeUserThroughConsumer repoRoot ident hardDelete

revokeUserThroughConsumer :: FilePath -> String -> Bool -> IO (Either String ())
revokeUserThroughConsumer repoRoot ident hardDelete =
  case validateUserIdentity ident of
    Left err -> pure (Left err)
    Right validatedIdent -> do
      let operation =
            if hardDelete
              then ConsumerDelete validatedIdent
              else ConsumerDisable validatedIdent
      fmap (Control.Monad.void) (runKeycloakConsumerOperation repoRoot operation)

-- | Reconcile the preserved realm against the OIDC/SMTP values already
-- projected into the Keycloak Pod.  The public host is deliberately irrelevant
-- to secret custody; the consumer talks to its loopback Keycloak listener.
reconcileRealmOidcSecretsAtPublicHost :: FilePath -> Text -> IO (Either String ())
reconcileRealmOidcSecretsAtPublicHost repoRoot _publicHost =
  fmap
    (Control.Monad.void)
    (runKeycloakConsumerOperation repoRoot ConsumerReconcileRuntime)

-- | Obtain a short-lived demo-user token without exporting either the client
-- secret or demo-user password. The closed client identity selects one fixed
-- environment projection inside Keycloak; only the issued access token is
-- returned to the validation harness.
issueDemoOidcAccessToken :: FilePath -> OidcIdentity -> IO (Either String String)
issueDemoOidcAccessToken repoRoot identity =
  case identity of
    OidcDemoUser -> pure (Left "demo-user is a credential identity, not an OIDC client")
    _ -> do
      result <- runKeycloakConsumerOperation repoRoot (ConsumerIssueDemoToken identity)
      pure $ do
        token <- Text.unpack . Text.strip <$> result
        if null token then Left "Keycloak consumer returned an empty access token" else Right token

-- | Obtain a short-lived token for a caller-owned test user while keeping the
-- registered client secret inside the Keycloak Pod. The username/password pair
-- crosses only the bounded @kubectl exec --stdin@ channel and is absent from
-- argv, environment, diagnostics, and durable Kubernetes objects.
issueUserOidcAccessToken
  :: FilePath -> OidcIdentity -> Text -> Text -> IO (Either String String)
issueUserOidcAccessToken repoRoot identity rawUsername rawPassword =
  case (identity, validateTokenUsername rawUsername, validateTokenPassword rawPassword) of
    (OidcDemoUser, _, _) ->
      pure (Left "demo-user is a credential identity, not an OIDC client")
    (_, Left err, _) -> pure (Left err)
    (_, _, Left err) -> pure (Left err)
    (_, Right username, Right password) -> do
      result <-
        runKeycloakConsumerOperation
          repoRoot
          (ConsumerIssueUserToken identity username password)
      pure $ do
        token <- Text.unpack . Text.strip <$> result
        if null token then Left "Keycloak consumer returned an empty access token" else Right token

runKeycloakConsumerOperation
  :: FilePath -> KeycloakConsumerOperation -> IO (Either String Text)
runKeycloakConsumerOperation repoRoot operation = do
  result <-
    case operationInput operation of
      Nothing ->
        captureSubprocessBounded
          keycloakConsumerLimits
          (keycloakConsumerSubprocess repoRoot operation)
      Just input ->
        captureSubprocessWithInputBounded
          keycloakConsumerLimits
          input
          (keycloakConsumerSubprocess repoRoot operation)
  pure $ case result of
    Left err -> Left (Text.unpack (errorMsg err))
    Right output -> case processExitCode output of
      ExitSuccess -> Right (Text.pack (processStdout output))
      ExitFailure _ ->
        Left
          ( "Keycloak consumer operation failed: "
              <> scrubConsumerDiagnostic (processStderr output <> processStdout output)
          )

keycloakConsumerSubprocess :: FilePath -> KeycloakConsumerOperation -> Subprocess
keycloakConsumerSubprocess repoRoot operation =
  Subprocess
    { subprocessPath = "kubectl"
    , subprocessArguments =
        [ "exec"
        ]
          <> ["--stdin" | operationUsesStdin operation]
          <> [ "--namespace"
             , keycloakNamespace
             , "deployment/keycloak"
             , "--container"
             , "keycloak"
             , "--"
             , "/bin/sh"
             , "-ec"
             , keycloakConsumerScript
             , "prodbox-keycloak-consumer"
             ]
          <> operationArguments operation
    , subprocessEnvironment = Nothing
    , subprocessWorkingDirectory = Just repoRoot
    }

operationArguments :: KeycloakConsumerOperation -> [String]
operationArguments operation = case operation of
  ConsumerInvite email maybeRole ->
    ["invite", Text.unpack email, maybe "" Text.unpack maybeRole]
  ConsumerList -> ["list"]
  ConsumerDisable ident -> ["disable", Text.unpack ident]
  ConsumerDelete ident -> ["delete", Text.unpack ident]
  ConsumerReconcileRuntime -> ["reconcile-runtime"]
  ConsumerIssueDemoToken identity -> ["issue-demo-token", oidcClientId identity]
  ConsumerIssueUserToken identity _ _ -> ["issue-user-token", oidcClientId identity]

operationUsesStdin :: KeycloakConsumerOperation -> Bool
operationUsesStdin operation = case operation of
  ConsumerIssueUserToken {} -> True
  _ -> False

operationInput :: KeycloakConsumerOperation -> Maybe ByteString
operationInput operation = case operation of
  ConsumerIssueUserToken _ username password ->
    Just (ByteString8.pack (Text.unpack username ++ "\n" ++ Text.unpack password ++ "\n"))
  _ -> Nothing

keycloakNamespace :: String
keycloakNamespace = "vscode"

oidcClientId :: OidcIdentity -> String
oidcClientId identity = case identity of
  OidcVscode -> "vscode"
  OidcProdboxApi -> "prodbox-api"
  OidcProdboxWebsocket -> "prodbox-websocket"
  OidcDemoUser -> "demo-user"

keycloakConsumerLimits :: BoundedSubprocessLimits
keycloakConsumerLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 4 * 1024
    , boundedSubprocessMaximumStdoutBytes = 2 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 64 * 1024
    , boundedSubprocessTimeoutMicros = 120 * 1000 * 1000
    }

-- | Static closed dispatcher. Secret values are expanded only by this script
-- inside the Keycloak container; they are absent from the host argv and output.
keycloakConsumerScript :: String
keycloakConsumerScript =
  unlines
    [ "set -eu"
    , ". /vault-materialized/keycloak.env"
    , "KCADM=/opt/keycloak/bin/kcadm.sh"
    , "KCADM_CONFIG=\"$(mktemp /run/prodbox-admin/kcadm.XXXXXX)\""
    , "trap 'rm -f \"${KCADM_CONFIG}\"' EXIT"
    , "${KCADM} config credentials --server http://127.0.0.1:8080/auth --realm master --user \"${KEYCLOAK_ADMIN:-admin}\" --password \"${KEYCLOAK_ADMIN_PASSWORD}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "realm=prodbox"
    , "reconcile_client() {"
    , "  client_name=\"$1\""
    , "  client_secret=\"$2\""
    , "  client_uuid=\"$(${KCADM} get clients -r \"${realm}\" -q clientId=\"${client_name}\" --fields id --format csv --noquotes --config \"${KCADM_CONFIG}\" | tail -n 1)\""
    , "  test -n \"${client_uuid}\""
    , "  ${KCADM} update \"clients/${client_uuid}\" -r \"${realm}\" -s \"secret=${client_secret}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "}"
    , "reconcile_runtime() {"
    , "  ${KCADM} update \"realms/${realm}\" --config \"${KCADM_CONFIG}\" -s \"smtpServer.host=${PRODBOX_SMTP_HOST}\" -s \"smtpServer.port=${PRODBOX_SMTP_PORT}\" -s \"smtpServer.from=${PRODBOX_SMTP_FROM}\" -s \"smtpServer.fromDisplayName=${PRODBOX_SMTP_FROM_DISPLAY_NAME}\" -s \"smtpServer.replyTo=${PRODBOX_SMTP_REPLY_TO}\" -s 'smtpServer.auth=true' -s 'smtpServer.starttls=true' -s 'smtpServer.ssl=false' -s \"smtpServer.user=${PRODBOX_SMTP_USER}\" -s \"smtpServer.password=${PRODBOX_SMTP_PASSWORD}\" >/dev/null"
    , "  reconcile_client vscode \"${PRODBOX_VSCODE_CLIENT_SECRET}\""
    , "  reconcile_client prodbox-api \"${PRODBOX_API_CLIENT_SECRET}\""
    , "  reconcile_client prodbox-websocket \"${PRODBOX_WEBSOCKET_CLIENT_SECRET}\""
    , "  ${KCADM} set-password -r \"${realm}\" --username demo-user --new-password \"${PRODBOX_DEMO_USER_PASSWORD}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "}"
    , "resolve_user_id() {"
    , "  candidate=\"$1\""
    , "  case \"${candidate}\" in"
    , "    *@*) ${KCADM} get users -r \"${realm}\" -q email=\"${candidate}\" --fields id --format csv --noquotes --config \"${KCADM_CONFIG}\" | tail -n 1 ;;"
    , "    *) printf '%s\\n' \"${candidate}\" ;;"
    , "  esac"
    , "}"
    , "operation=\"$1\""
    , "shift"
    , "case \"${operation}\" in"
    , "  reconcile-runtime) reconcile_runtime ;;"
    , "  issue-demo-token)"
    , "    client_name=\"$1\""
    , "    case \"${client_name}\" in"
    , "      vscode) client_secret=\"${PRODBOX_VSCODE_CLIENT_SECRET}\" ;;"
    , "      prodbox-api) client_secret=\"${PRODBOX_API_CLIENT_SECRET}\" ;;"
    , "      prodbox-websocket) client_secret=\"${PRODBOX_WEBSOCKET_CLIENT_SECRET}\" ;;"
    , "      *) echo 'unsupported closed OIDC client identity' >&2; exit 64 ;;"
    , "    esac"
    , "    ${KCADM} config credentials --server http://127.0.0.1:8080/auth --realm \"${realm}\" --user demo-user --password \"${PRODBOX_DEMO_USER_PASSWORD}\" --client \"${client_name}\" --secret \"${client_secret}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "    awk -F '\"' '/\"access_token\"/ { pri"
        <> "nt $4; found=1; exit } END { if (!found) exit 1 }' \"${KCADM_CONFIG}\""
    , "    ;;"
    , "  issue-user-token)"
    , "    client_name=\"$1\""
    , "    case \"${client_name}\" in"
    , "      vscode) client_secret=\"${PRODBOX_VSCODE_CLIENT_SECRET}\" ;;"
    , "      prodbox-api) client_secret=\"${PRODBOX_API_CLIENT_SECRET}\" ;;"
    , "      prodbox-websocket) client_secret=\"${PRODBOX_WEBSOCKET_CLIENT_SECRET}\" ;;"
    , "      *) echo 'unsupported closed OIDC client identity' >&2; exit 64 ;;"
    , "    esac"
    , "    IFS= read -r username"
    , "    IFS= read -r user_password"
    , "    test -n \"${username}\""
    , "    test -n \"${user_password}\""
    , "    ${KCADM} config credentials --server http://127.0.0.1:8080/auth --realm \"${realm}\" --user \"${username}\" --password \"${user_password}\" --client \"${client_name}\" --secret \"${client_secret}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "    unset user_password"
    , "    awk -F '\"' '/\"access_token\"/ { pri"
        <> "nt $4; found=1; exit } END { if (!found) exit 1 }' \"${KCADM_CONFIG}\""
    , "    ;;"
    , "  invite)"
    , "    email=\"$1\""
    , "    requested_role=\"$2\""
    , "    first_name=\"${email%%@*}\""
    , "    test -n \"${first_name}\" || first_name=Invited"
    , "    user_id=\"$(${KCADM} create users -r \"${realm}\" -i --config \"${KCADM_CONFIG}\" -s enabled=true -s emailVerified=false -s \"email=${email}\" -s \"username=${email}\" -s \"firstName=${first_name}\" -s lastName=Invitee -s 'requiredActions=[\"VERIFY_EMAIL\",\"UPDATE_PASSWORD\"]')\""
    , "    test -n \"${user_id}\""
    , "    ${KCADM} put \"users/${user_id}/execute-actions-email\" -r \"${realm}\" --config \"${KCADM_CONFIG}\" -b '[\"VERIFY_EMAIL\",\"UPDATE_PASSWORD\"]' >/dev/null"
    , "    if [ -n \"${requested_role}\" ]; then"
    , "      ${KCADM} add-roles -r \"${realm}\" --uusername \"${email}\" --rolename \"${requested_role}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "    fi"
    , "    printf '%s\\n' \"${user_id}\""
    , "    ;;"
    , "  list) ${KCADM} get users -r \"${realm}\" --config \"${KCADM_CONFIG}\" --fields id,username,email,emailVerified,enabled ;;"
    , "  disable)"
    , "    user_id=\"$(resolve_user_id \"$1\")\""
    , "    test -n \"${user_id}\""
    , "    ${KCADM} update \"users/${user_id}\" -r \"${realm}\" --config \"${KCADM_CONFIG}\" -s enabled=false >/dev/null"
    , "    ;;"
    , "  delete)"
    , "    user_id=\"$(resolve_user_id \"$1\")\""
    , "    test -n \"${user_id}\""
    , "    ${KCADM} delete \"users/${user_id}\" -r \"${realm}\" --config \"${KCADM_CONFIG}\" >/dev/null"
    , "    ;;"
    , "  *) echo 'unsupported closed Keycloak consumer operation' >&2; exit 64 ;;"
    , "esac"
    ]

-- | Avoid replaying third-party diagnostics verbatim when they could echo an
-- expanded argument. The stable class is enough for the operator; detailed
-- server logs remain inside the consumer Pod.
scrubConsumerDiagnostic :: String -> String
scrubConsumerDiagnostic diagnostic
  | null (Text.unpack (Text.strip (Text.pack diagnostic))) = "consumer returned no diagnostic"
  | otherwise = "see Keycloak consumer Pod logs"

validateInviteArguments :: String -> Maybe String -> Either String (Text, Maybe Text)
validateInviteArguments email maybeRole = do
  validatedEmail <- validateEmail (Text.pack email)
  validatedRole <- traverse (validateRole . Text.pack) maybeRole
  pure (validatedEmail, validatedRole)

validateEmail :: Text -> Either String Text
validateEmail raw =
  let value = Text.strip raw
      atCount = Text.length (Text.filter (== '@') value)
   in if Text.null value || Text.length value > 320
        then Left "user email must be between 1 and 320 characters"
        else
          if atCount /= 1 || Text.any (\character -> character <= ' ' || character == '\DEL') value
            then Left "user email must contain one @ and no spaces or control characters"
            else Right value

validateUserIdentity :: String -> Either String Text
validateUserIdentity raw
  | '@' `elem` raw = validateEmail (Text.pack raw)
  | otherwise =
      let value = Text.strip (Text.pack raw)
       in if Text.null value || Text.length value > 128 || not (Text.all isIdentityCharacter value)
            then Left "Keycloak user id must be 1-128 ASCII identifier characters"
            else Right value

validateRole :: Text -> Either String Text
validateRole raw =
  let value = Text.strip raw
   in if Text.null value || Text.length value > 64 || not (Text.all isIdentityCharacter value)
        then Left "Keycloak role must be 1-64 ASCII identifier characters"
        else Right value

validateTokenUsername :: Text -> Either String Text
validateTokenUsername raw =
  let value = Text.strip raw
   in if Text.null value
        || Text.length value > 320
        || Text.any isLineOrControlCharacter value
        then Left "OIDC token username must be 1-320 characters without control characters"
        else Right value

validateTokenPassword :: Text -> Either String Text
validateTokenPassword raw
  | Text.null raw || Text.length raw > 1024 =
      Left "OIDC token password must be 1-1024 characters"
  | Text.any isLineOrControlCharacter raw =
      Left "OIDC token password must not contain control characters"
  | otherwise = Right raw

isLineOrControlCharacter :: Char -> Bool
isLineOrControlCharacter character = character < ' ' || character == '\DEL'

isIdentityCharacter :: Char -> Bool
isIdentityCharacter character =
  isAsciiLower character
    || isAsciiUpper character
    || isDigit character
    || character `elem` ("._:-" :: String)
