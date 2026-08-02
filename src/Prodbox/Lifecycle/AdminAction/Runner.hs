{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Runtime boundary of the attested one-shot Admin Action Job.
--
-- It reads one bounded stdin frame, compares the framed/signed identity with
-- its downward-API Pod name and UID plus immutable argv metadata, verifies the
-- Authority signature using public Transit metadata, executes the one closed
-- action, and always revokes its short Vault session before emitting a receipt.
module Prodbox.Lifecycle.AdminAction.Runner
  ( AdminActionRunnerOptions (..)
  , AdminActionRunnerError (..)
  , AdminActionAuditorRecoveryBoundary (..)
  , acquireAdminActionAuditorWith
  , runAdminActionRunnerWith
  , finishAdminActionRunnerSession
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, displayException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isControl, isSpace)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time.Clock.POSIX (POSIXTime, getPOSIXTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.AdminActionAuthorityExecutionClient
  ( callCommitAdminActionCompletion
  )
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityResponse (..)
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( adminActionRunnerAuditorVaultRole
  , adminActionRunnerCompletionVaultRole
  , adminActionRunnerVaultRole
  , controlPlaneSigningKeyRefFor
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerAdminActionRunner)
  )
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.ProjectedServiceAccountIdentity
  ( decodeProjectedServiceAccountIdentity
  , projectedServiceAccountIdentityMatches
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLifecycleError (..)
  , ServiceSessionLoginBoundary (..)
  , ServiceSessionSubjects (..)
  , allocateNextServiceSessionBinding
  , withFencedServiceSession
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitRequestSigningCapability
  , transitAuthenticatedClientProviders
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.ControlPlane.VaultServiceSessionJournal
  ( vaultServiceSessionJournalRepository
  )
import Prodbox.Lifecycle.AdminAction.Execution
  ( AdminActionInterpreters
  , executeSignedAdminAction
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionJobBinding
  , AdminActionReceipt
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionJobServiceAccount
  , adminActionJobServiceAccountUid
  , adminActionPermitAction
  , adminActionPermitAuthorityScope
  , adminActionPermitDeadline
  , adminActionPermitOperationId
  , adminActionRunnerServiceAccount
  , encodeAdminActionReceipt
  , encodeSignedAdminActionPermit
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  , signedAdminActionPermitSignerGeneration
  , verifySignedAdminActionPermit
  )
import Prodbox.Lifecycle.AdminAction.WorkerProtocol
  ( AdminActionWorkerIngressError
  , adminActionWorkerIngressMaximumBytes
  , withAdminActionWorkerIngress
  )
import Prodbox.Lifecycle.Authority.AdminAction (AdminAction)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( manifestPublicKeyBytes
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Settings (Credentials)
import Prodbox.Vault.Client
  ( TokenAccessorListing (..)
  , VaultAddress (..)
  , VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  , vaultListTokenAccessors
  , vaultLookupTokenAccessorInfo
  , vaultRevokeSelf
  , vaultRevokeTokenAccessor
  , vaultTokenAccessorAbsent
  )
import Prodbox.Vault.Session
  ( LoginLease (..)
  , VaultSession
  , newVaultSession
  , realSessionClock
  , sessionAddress
  , sessionToken
  )
import System.Exit (ExitCode (..))
import System.IO (Handle, stdin, stdout)

data AdminActionRunnerOptions = AdminActionRunnerOptions
  { adminActionRunnerExpectedAction :: !AdminAction
  , adminActionRunnerOperationId :: !Text
  , adminActionRunnerDeadlineMicros :: !Natural
  , adminActionRunnerPodNameFile :: !FilePath
  , adminActionRunnerPodUidFile :: !FilePath
  , adminActionRunnerServiceAccountTokenFile :: !FilePath
  }
  deriving stock (Eq, Show)

data AdminActionRunnerError
  = AdminActionRunnerStdinReadFailed
  | AdminActionRunnerStdinTooLarge !Int !Int
  | AdminActionRunnerFrameRejected !AdminActionWorkerIngressError
  | AdminActionRunnerPodIdentityReadFailed
  | AdminActionRunnerPodIdentityInvalid
  | AdminActionRunnerPodIdentityMismatch
  | AdminActionRunnerProjectedIdentityMismatch
  | AdminActionRunnerPermitMetadataMismatch
  | AdminActionRunnerClockUnavailable
  | AdminActionRunnerVaultLoginUnavailable
  | AdminActionRunnerAuthorityKeyUnavailable
  | AdminActionRunnerPermitRejected
  | AdminActionRunnerInterpreterUnavailable
  | AdminActionRunnerExecutionFailed
  | AdminActionRunnerSessionRevocationFailed
  | AdminActionRunnerCompletionUnavailable
  deriving stock (Eq, Show)

runAdminActionRunnerWith
  :: ( Credentials
       -> VaultSession
       -> SignedAdminActionPermit
       -> IO (Either Text (AdminActionInterpreters IO))
     )
  -> AdminActionRunnerOptions
  -> IO ExitCode
runAdminActionRunnerWith loadInterpreters options = do
  result <- runWorker loadInterpreters options
  case result of
    Left err -> do
      -- The error algebra contains no credential, token, stdin, AWS response,
      -- or Vault body.
      writeDiagnosticLine ("admin-action runner refused: " <> show err)
      pure (ExitFailure 1)
    Right receipt -> do
      ByteString.hPut stdout (encodeAdminActionReceipt receipt)
      pure ExitSuccess

runWorker
  :: ( Credentials
       -> VaultSession
       -> SignedAdminActionPermit
       -> IO (Either Text (AdminActionInterpreters IO))
     )
  -> AdminActionRunnerOptions
  -> IO (Either AdminActionRunnerError AdminActionReceipt)
runWorker loadInterpreters options = do
  stdinResult <- readHandleBounded adminActionWorkerIngressMaximumBytes stdin
  podNameResult <- readPodIdentity (adminActionRunnerPodNameFile options)
  podUidResult <- readPodIdentity (adminActionRunnerPodUidFile options)
  case (stdinResult, podNameResult, podUidResult) of
    (Left err, _, _) -> pure (Left err)
    (_, Left err, _) -> pure (Left err)
    (_, _, Left err) -> pure (Left err)
    (Right input, Right actualPodName, Right actualPodUid) ->
      case withAdminActionWorkerIngress input (execute actualPodName actualPodUid) of
        Left err -> pure (Left (AdminActionRunnerFrameRejected err))
        Right effect -> effect
 where
  execute
    :: Text
    -> Text
    -> SignedAdminActionPermit
    -> Credentials
    -> IO (Either AdminActionRunnerError AdminActionReceipt)
  execute actualPodName actualPodUid permit credentials
    | actualPodName /= adminActionJobPodName binding =
        pure (Left AdminActionRunnerPodIdentityMismatch)
    | actualPodUid /= adminActionJobPodUid binding =
        pure (Left AdminActionRunnerPodIdentityMismatch)
    | adminActionPermitAction core /= adminActionRunnerExpectedAction options =
        pure (Left AdminActionRunnerPermitMetadataMismatch)
    | adminActionPermitOperationId core /= adminActionRunnerOperationId options =
        pure (Left AdminActionRunnerPermitMetadataMismatch)
    | authorityTimeMicros (adminActionPermitDeadline core)
        /= adminActionRunnerDeadlineMicros options =
        pure (Left AdminActionRunnerPermitMetadataMismatch)
    | otherwise = do
        nowResult <- currentTime
        case nowResult of
          Left err -> pure (Left err)
          Right now -> do
            withRunnerVaultSession
              options
              binding
              actualPodName
              actualPodUid
              permit
              ( \session ->
                  executeAuthenticated
                    loadInterpreters
                    session
                    now
                    permit
                    credentials
              )
   where
    core = signedAdminActionPermitCore permit
    binding = signedAdminActionPermitBinding permit

executeAuthenticated
  :: ( Credentials
       -> VaultSession
       -> SignedAdminActionPermit
       -> IO (Either Text (AdminActionInterpreters IO))
     )
  -> VaultSession
  -> AuthorityTime
  -> SignedAdminActionPermit
  -> Credentials
  -> IO (Either AdminActionRunnerError AdminActionReceipt)
executeAuthenticated loadInterpreters session now permit credentials = do
  publicResult <-
    readAuthorityManifestPublicKey (vaultAuthorityManifestSigner session)
  case publicResult of
    Left _ -> pure (Left AdminActionRunnerAuthorityKeyUnavailable)
    Right (publicGeneration, publicKey)
      | publicGeneration /= signedAdminActionPermitSignerGeneration permit ->
          pure (Left AdminActionRunnerPermitRejected)
      | otherwise -> case verifySignedAdminActionPermit
          (manifestPublicKeyBytes publicKey)
          now
          permit of
          Left _ -> pure (Left AdminActionRunnerPermitRejected)
          Right () -> do
            loaded <- loadInterpreters credentials session permit
            case loaded of
              Left _ -> pure (Left AdminActionRunnerInterpreterUnavailable)
              Right interpreters -> do
                result <- executeSignedAdminAction interpreters permit
                pure $ case result of
                  Left _ -> Left AdminActionRunnerExecutionFailed
                  Right receipt -> Right receipt

-- | Cleanup lies outside the success path.  A revoke response is provisional:
-- the exact server-issued accessor must subsequently be proven absent by the
-- narrow auditor identity before any receipt can escape.
finishAdminActionRunnerSession
  :: IO (Either AdminActionRunnerError value)
  -> IO (Either AdminActionRunnerError ())
  -> IO (Either AdminActionRunnerError Bool)
  -> IO (Either AdminActionRunnerError value)
finishAdminActionRunnerSession =
  finishClosedSession
    AdminActionRunnerExecutionFailed
    AdminActionRunnerSessionRevocationFailed

revokeRunnerSession :: VaultSession -> IO (Either AdminActionRunnerError ())
revokeRunnerSession session = do
  tokenResult <- sessionToken session
  case tokenResult of
    Left _ -> pure (Left AdminActionRunnerSessionRevocationFailed)
    Right token -> do
      revoked <- vaultRevokeSelf (sessionAddress session) token
      pure $ case revoked of
        Left _ -> Left AdminActionRunnerSessionRevocationFailed
        Right () -> Right ()

data RunnerVaultLogin = RunnerVaultLogin
  { runnerLoginSession :: !VaultSession
  , runnerLoginAccessor :: !Text
  }

withRunnerVaultSession
  :: AdminActionRunnerOptions
  -> AdminActionJobBinding
  -> Text
  -> Text
  -> SignedAdminActionPermit
  -> (VaultSession -> IO (Either AdminActionRunnerError AdminActionReceipt))
  -> IO (Either AdminActionRunnerError AdminActionReceipt)
withRunnerVaultSession options binding actualPodName actualPodUid permit action = do
  jwtResult <- readProjectedToken (adminActionRunnerServiceAccountTokenFile options)
  case jwtResult of
    Left _ -> pure (Left AdminActionRunnerVaultLoginUnavailable)
    Right jwt -> case decodeProjectedServiceAccountIdentity jwt of
      Left _ -> pure (Left AdminActionRunnerProjectedIdentityMismatch)
      Right identity
        | not
            ( projectedServiceAccountIdentityMatches
                adminActionRunnerNamespace
                actualPodName
                actualPodUid
                (adminActionJobServiceAccount binding)
                (adminActionJobServiceAccountUid binding)
                identity
            ) ->
            pure (Left AdminActionRunnerProjectedIdentityMismatch)
        | otherwise -> do
            auditorResult <- newRunnerAuditor jwt
            case auditorResult of
              Left err -> pure (Left err)
              Right auditor -> do
                let repository =
                      vaultServiceSessionJournalRepository
                        runnerVaultAddress
                        (vaultLoginToken auditor)
                        adminActionRunnerVaultRole
                allocated <-
                  allocateNextServiceSessionBinding
                    repository
                    adminActionRunnerVaultRole
                    (adminActionPermitOperationId (signedAdminActionPermitCore permit))
                    (runnerAttemptId permit)
                case allocated of
                  Left _ -> pure (Left AdminActionRunnerSessionRevocationFailed)
                  Right sessionBinding -> do
                    actionError <- newIORef Nothing
                    result <-
                      withFencedServiceSession
                        repository
                        (runnerAccessorAuditOps auditor)
                        (runnerSessionSubjects binding)
                        sessionBinding
                        (runnerLoginBoundary jwt)
                        (runAction actionError)
                    case result of
                      Right receipt ->
                        commitRunnerCompletion jwt permit receipt
                      Left lifecycleError -> do
                        original <- readIORef actionError
                        pure (Left (mapLifecycleError original lifecycleError))
 where
  runAction actionError login = do
    result <- action (runnerLoginSession login)
    case result of
      Left err -> do
        writeIORef actionError (Just err)
        pure (Left "Admin Action execution refused")
      Right value -> pure (Right value)

newRunnerVaultSession
  :: Text -> IO (Either AdminActionRunnerError RunnerVaultLogin)
newRunnerVaultSession jwt = do
  result <-
    vaultKubernetesLoginWithLease
      runnerVaultAddress
      runnerVaultAuthPath
      adminActionRunnerVaultRole
      jwt
  case result of
    Left _ -> pure (Left AdminActionRunnerVaultLoginUnavailable)
    Right login
      | not (validRunnerLogin login) -> do
          _ <- vaultRevokeSelf runnerVaultAddress (vaultLoginToken login)
          pure (Left AdminActionRunnerVaultLoginUnavailable)
      | otherwise -> do
          let lease =
                LoginLease
                  { loginLeaseToken = vaultLoginToken login
                  , loginLeaseSeconds = vaultLoginLeaseSeconds login
                  , loginLeaseRenewable = vaultLoginRenewable login
                  }
          session <-
            newVaultSession
              runnerVaultAddress
              realSessionClock
              (pure (Right lease))
          pure
            ( Right
                RunnerVaultLogin
                  { runnerLoginSession = session
                  , runnerLoginAccessor = vaultLoginAccessor login
                  }
            )

validRunnerLogin :: VaultKubernetesLoginResult -> Bool
validRunnerLogin login =
  vaultLoginTokenType login == "service"
    && not (Text.null (vaultLoginAccessor login))
    && vaultLoginAccessor login == Text.strip (vaultLoginAccessor login)
    && vaultLoginLeaseSeconds login > 0
    && vaultLoginLeaseSeconds login <= runnerMaximumLeaseSeconds

newRunnerAuditor
  :: Text -> IO (Either AdminActionRunnerError VaultKubernetesLoginResult)
newRunnerAuditor jwt = do
  acquired <-
    acquireAdminActionAuditorWith
      runnerAuditorRecoveryAttempts
      AdminActionAuditorRecoveryBoundary
        { acquireAdminActionAuditorLogin =
            first (const "Admin Action auditor login unavailable")
              <$> vaultKubernetesLoginWithLease
                runnerVaultAddress
                runnerVaultAuthPath
                adminActionRunnerAuditorVaultRole
                jwt
        , adminActionAuditorLoginAccepted =
            isBoundedBatchAuditorLogin runnerAuditorMaximumLeaseSeconds
        , adminActionAuditorLoginMayHaveAccessor = \login ->
            vaultLoginTokenType login /= "batch"
              || not (Text.null (Text.strip (vaultLoginAccessor login)))
        , adminActionAuditorLoginAccessor = vaultLoginAccessor
        , revokeAdminActionAuditorLogin = \login ->
            first (const "Admin Action invalid auditor revoke unavailable")
              <$> vaultRevokeSelf runnerVaultAddress (vaultLoginToken login)
        , closeAdminActionAuditorRole = \auditor accessors ->
            closeRunnerRoleAccessors
              auditor
              adminActionRunnerAuditorVaultRole
              accessors
        }
  pure (first (const AdminActionRunnerSessionRevocationFailed) acquired)

-- | Injectable recovery for a Vault role that drifted from the mandatory
-- accessor-free bounded batch-token shape. Every invalid bearer is revoked
-- immediately. A later valid batch auditor must then revoke every returned
-- accessor directly and prove the entire role has a stable zero inventory
-- before it can be returned to the Runner.
data AdminActionAuditorRecoveryBoundary m login
  = AdminActionAuditorRecoveryBoundary
  { acquireAdminActionAuditorLogin :: m (Either Text login)
  , adminActionAuditorLoginAccepted :: login -> Bool
  , adminActionAuditorLoginMayHaveAccessor :: login -> Bool
  , adminActionAuditorLoginAccessor :: login -> Text
  , revokeAdminActionAuditorLogin :: login -> m (Either Text ())
  , closeAdminActionAuditorRole
      :: login
      -> [Text]
      -> m (Either Text ())
  }

acquireAdminActionAuditorWith
  :: (Monad m)
  => Int
  -> AdminActionAuditorRecoveryBoundary m login
  -> m (Either Text login)
acquireAdminActionAuditorWith maximumAttempts boundary =
  seek maximumAttempts []
 where
  seek remaining leakedAccessors
    | remaining <= 0 =
        pure (Left "Admin Action auditor evidence is unavailable")
    | otherwise = do
        acquired <- acquireAdminActionAuditorLogin boundary
        case acquired of
          Left _ -> seek (remaining - 1) leakedAccessors
          Right login
            | adminActionAuditorLoginAccepted boundary login -> do
                closed <-
                  closeAdminActionAuditorRole
                    boundary
                    login
                    (reverse leakedAccessors)
                pure (login <$ closed)
            | otherwise -> do
                -- Revoke-self responses are provisional. The later valid
                -- batch auditor's role-wide stable-zero proof is terminal.
                _ <- revokeAdminActionAuditorLogin boundary login
                let maybeAccessor =
                      canonicalRunnerAccessor
                        (adminActionAuditorLoginAccessor boundary login)
                    nextAccessors = case maybeAccessor of
                      Just accessor -> accessor : leakedAccessors
                      Nothing -> leakedAccessors
                    mayHaveAccessor =
                      adminActionAuditorLoginMayHaveAccessor boundary login
                -- Even when Vault returned no usable accessor, continue: the
                -- exact role scan is authoritative for a response-lost or
                -- malformed login result.
                mayHaveAccessor `seq` seek (remaining - 1) nextAccessors

canonicalRunnerAccessor :: Text -> Maybe Text
canonicalRunnerAccessor raw
  | Text.null raw = Nothing
  | Text.length raw > 512 = Nothing
  | Text.strip raw /= raw = Nothing
  | Text.any (\character -> isControl character || isSpace character) raw = Nothing
  | otherwise = Just raw

-- | The authoritative completion is deliberately authenticated only after
-- the accessor-bearing worker session has reached retained @Vacant@.  A fresh
-- accessor-free batch identity has no worker or token-administration policy;
-- it can only sign this bounded terminal control-plane handoff and then
-- expires without a revocation obligation.
commitRunnerCompletion
  :: Text
  -> SignedAdminActionPermit
  -> AdminActionReceipt
  -> IO (Either AdminActionRunnerError AdminActionReceipt)
commitRunnerCompletion jwt permit receipt = do
  loggedIn <-
    vaultKubernetesLoginWithLease
      runnerVaultAddress
      runnerVaultAuthPath
      adminActionRunnerCompletionVaultRole
      jwt
  case loggedIn of
    Left _ -> pure (Left AdminActionRunnerCompletionUnavailable)
    Right completionLogin
      | not
          ( isBoundedBatchAuditorLogin
              runnerCompletionMaximumLeaseSeconds
              completionLogin
          ) ->
          cleanupInvalidRunnerRoleLogin
            jwt
            adminActionRunnerCompletionVaultRole
            completionLogin
            >> pure (Left AdminActionRunnerCompletionUnavailable)
      | otherwise -> do
          let lease =
                LoginLease
                  { loginLeaseToken = vaultLoginToken completionLogin
                  , loginLeaseSeconds = vaultLoginLeaseSeconds completionLogin
                  , loginLeaseRenewable = False
                  }
          completionSession <-
            newVaultSession
              runnerVaultAddress
              realSessionClock
              (pure (Right lease))
          signerResult <-
            resolveTransitRequestSigningCapability
              completionSession
              CallerAdminActionRunner
              (controlPlaneSigningKeyRefFor CallerAdminActionRunner)
          let configured = do
                signer <-
                  first
                    (const AdminActionRunnerCompletionUnavailable)
                    signerResult
                bounds <-
                  first
                    (const AdminActionRunnerCompletionUnavailable)
                    ( mkAuthenticatedTransportBounds
                        runnerCompletionFrameMaximum
                        runnerCompletionMetadataMaximum
                        runnerCompletionEnvelopeMaximum
                    )
                scope <-
                  first
                    (const AdminActionRunnerCompletionUnavailable)
                    ( mkAuthorityScope
                        ( adminActionPermitAuthorityScope
                            (signedAdminActionPermitCore permit)
                        )
                    )
                lifetime <-
                  first
                    (const AdminActionRunnerCompletionUnavailable)
                    (authorityDurationFromMicros runnerCompletionAuthenticationLifetimeMicros)
                pure (signer, bounds, scope, lifetime)
          case configured of
            Left err -> pure (Left err)
            Right (signer, bounds, scope, lifetime) -> do
              let providers =
                    transitAuthenticatedClientProviders
                      signer
                      (pure (Right scope))
                      (readRetainedAuthorityEpoch completionSession)
                      lifetime
              committed <-
                callCommitAdminActionCompletion bounds providers permit receipt
              pure $ case committed of
                Right (AdminActionAuthorityCompletionCommitted confirmed)
                  | confirmed == receipt -> Right confirmed
                _ -> Left AdminActionRunnerCompletionUnavailable

runnerLoginBoundary :: Text -> ServiceSessionLoginBoundary RunnerVaultLogin
runnerLoginBoundary jwt =
  ServiceSessionLoginBoundary
    { attemptServiceSessionLogin =
        first (Text.pack . show) <$> newRunnerVaultSession jwt
    , serviceSessionLoginAccessor = runnerLoginAccessor
    , revokeServiceSessionLogin = \login ->
        first (Text.pack . show) <$> revokeRunnerSession (runnerLoginSession login)
    }

runnerAccessorAuditOps
  :: VaultKubernetesLoginResult -> VaultAccessorAuditOps IO
runnerAccessorAuditOps auditor =
  VaultAccessorAuditOps
    { auditListAccessors =
        first (const "accessor inventory unavailable")
          . fmap tokenAccessorKeys
          <$> vaultListTokenAccessors runnerVaultAddress token
    , auditLookupAccessor = \accessor ->
        first (const "accessor classification unavailable")
          <$> vaultLookupTokenAccessorInfo runnerVaultAddress token accessor
    , auditRevokeAccessor = \accessor ->
        first (const "accessor revocation unavailable")
          <$> vaultRevokeTokenAccessor runnerVaultAddress token accessor
    , auditObserveAccessorAbsent = \accessor ->
        first (const "accessor absence unavailable")
          <$> vaultTokenAccessorAbsent runnerVaultAddress token accessor
    , auditWaitVisibilityGrace =
        threadDelay runnerAccessorVisibilityGraceMicros >> pure (Right ())
    }
 where
  token = vaultLoginToken auditor

-- | Close credentials returned by a role that should have issued an
-- accessor-free batch token. The invalid bearer is revoked first, then a
-- separately validated batch auditor proves the whole role empty. Cleanup is
-- deliberately fail-closed; callers never treat a failed proof as success.
cleanupInvalidRunnerRoleLogin
  :: Text
  -> Text
  -> VaultKubernetesLoginResult
  -> IO (Either Text ())
cleanupInvalidRunnerRoleLogin jwt role login = do
  _ <- vaultRevokeSelf runnerVaultAddress (vaultLoginToken login)
  auditorResult <- newRunnerAuditor jwt
  case auditorResult of
    Left err -> pure (Left (Text.pack (show err)))
    Right auditor ->
      closeRunnerRoleAccessors
        auditor
        role
        (maybe [] pure (canonicalRunnerAccessor (vaultLoginAccessor login)))

closeRunnerRoleAccessors
  :: VaultKubernetesLoginResult
  -> Text
  -> [Text]
  -> IO (Either Text ())
closeRunnerRoleAccessors auditor role knownAccessors =
  proveKnown knownAccessors
 where
  ops = runnerAccessorAuditOps auditor
  subject = runnerRoleAccessorSubject role

  proveKnown [] =
    first (Text.pack . show)
      <$> revokeAndProveVaultAccessorSubjectAbsent ops subject Nothing
  proveKnown (accessor : rest) = do
    -- Direct revocation is provisional: exact accessor absence plus the
    -- correlated role inventory are both established by the bounded audit.
    _ <- auditRevokeAccessor ops accessor
    proved <-
      first (Text.pack . show)
        <$> revokeAndProveVaultAccessorSubjectAbsent
          ops
          subject
          (Just accessor)
    case proved of
      Left detail -> pure (Left detail)
      Right () -> proveKnown rest

runnerRoleAccessorSubject :: Text -> VaultAccessorSubject
runnerRoleAccessorSubject role =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", role]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", role)
          , ("service_account_name", adminActionRunnerServiceAccount)
          , ("service_account_namespace", adminActionRunnerNamespace)
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

runnerSessionSubjects :: AdminActionJobBinding -> ServiceSessionSubjects
runnerSessionSubjects binding =
  ServiceSessionSubjects
    { serviceSessionCleanupSubject = subject Nothing
    , serviceSessionActiveSubject =
        subject (Just (adminActionJobServiceAccountUid binding))
    }
 where
  subject maybeUid =
    VaultAccessorSubject
      { vaultAccessorSubjectPolicies = ["default", adminActionRunnerVaultRole]
      , vaultAccessorSubjectMetadata =
          Map.fromList
            ( [ ("role", adminActionRunnerVaultRole)
              , ("service_account_name", adminActionJobServiceAccount binding)
              , ("service_account_namespace", adminActionRunnerNamespace)
              ]
                <> maybe [] (\uid -> [("service_account_uid", uid)]) maybeUid
            )
      , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
      }

mapLifecycleError
  :: Maybe AdminActionRunnerError
  -> ServiceSessionLifecycleError
  -> AdminActionRunnerError
mapLifecycleError original lifecycleError = case lifecycleError of
  ServiceSessionLifecycleActionFailed _ ->
    maybe AdminActionRunnerExecutionFailed id original
  ServiceSessionLifecycleLoginFailedCleaned _ ->
    AdminActionRunnerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorInvalid ->
    AdminActionRunnerVaultLoginUnavailable
  ServiceSessionLifecycleAccessorIdentityMismatch ->
    AdminActionRunnerVaultLoginUnavailable
  ServiceSessionLifecycleUnhandledException ->
    maybe AdminActionRunnerExecutionFailed id original
  _ -> AdminActionRunnerSessionRevocationFailed

runnerAttemptId :: SignedAdminActionPermit -> Text
runnerAttemptId permit =
  "permit-" <> sha256Text (encodeSignedAdminActionPermit permit)

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

runnerVaultAddress :: VaultAddress
runnerVaultAddress = VaultAddress "http://vault.vault.svc.cluster.local:8200"

runnerVaultAuthPath :: Text
runnerVaultAuthPath = "kubernetes"

adminActionRunnerNamespace :: Text
adminActionRunnerNamespace = "admin-action-runner"

runnerMaximumLeaseSeconds :: Int
runnerMaximumLeaseSeconds = 600

runnerAuditorMaximumLeaseSeconds :: Int
runnerAuditorMaximumLeaseSeconds = 300

runnerAuditorRecoveryAttempts :: Int
runnerAuditorRecoveryAttempts = 4

runnerAccessorVisibilityGraceMicros :: Int
runnerAccessorVisibilityGraceMicros = 1000000

runnerCompletionMaximumLeaseSeconds :: Int
runnerCompletionMaximumLeaseSeconds = 120

runnerCompletionFrameMaximum :: Int
runnerCompletionFrameMaximum = 1024 * 1024

runnerCompletionMetadataMaximum :: Int
runnerCompletionMetadataMaximum = 64 * 1024

runnerCompletionEnvelopeMaximum :: Int
runnerCompletionEnvelopeMaximum = runnerCompletionFrameMaximum - 4096

runnerCompletionAuthenticationLifetimeMicros :: Natural
runnerCompletionAuthenticationLifetimeMicros = 60 * 1000000

currentTime :: IO (Either AdminActionRunnerError AuthorityTime)
currentTime = do
  attempted <- try getPOSIXTime :: IO (Either IOException POSIXTime)
  pure $ case attempted of
    Left _ -> Left AdminActionRunnerClockUnavailable
    Right value
      | value < 0 -> Left AdminActionRunnerClockUnavailable
      | otherwise ->
          Right (authorityTimeFromMicros (fromInteger (floor (value * 1000000))))

readPodIdentity
  :: FilePath
  -> IO (Either AdminActionRunnerError Text)
readPodIdentity path = do
  attempted <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case attempted of
    Left _ -> Left AdminActionRunnerPodIdentityReadFailed
    Right raw
      | Text.null value -> Left AdminActionRunnerPodIdentityInvalid
      | Text.length value > 256 -> Left AdminActionRunnerPodIdentityInvalid
      | Text.any (<= '\x20') value -> Left AdminActionRunnerPodIdentityInvalid
      | otherwise -> Right value
     where
      value = Text.strip raw

readProjectedToken :: FilePath -> IO (Either String Text)
readProjectedToken path = do
  attempted <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case attempted of
    Left err -> Left (displayException err)
    Right raw
      | Text.null (Text.strip raw) -> Left "projected token is empty"
      | Text.length raw > 32768 -> Left "projected token is too large"
      | otherwise -> Right (Text.strip raw)

readHandleBounded
  :: Int
  -> Handle
  -> IO (Either AdminActionRunnerError ByteString)
readHandleBounded maximumBytes handle = go ByteString.empty
 where
  go accumulated = do
    attempted <- try (ByteString.hGetSome handle 4096) :: IO (Either IOException ByteString)
    case attempted of
      Left _ -> pure (Left AdminActionRunnerStdinReadFailed)
      Right chunk
        | ByteString.null chunk -> pure (Right accumulated)
        | ByteString.length accumulated + ByteString.length chunk > maximumBytes ->
            pure
              ( Left
                  ( AdminActionRunnerStdinTooLarge
                      (ByteString.length accumulated + ByteString.length chunk)
                      maximumBytes
                  )
              )
        | otherwise -> go (accumulated <> chunk)
