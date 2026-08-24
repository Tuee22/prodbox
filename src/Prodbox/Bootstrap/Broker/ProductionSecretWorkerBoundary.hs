{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Production controller-side composition for the attested one-shot worker
-- protocol.  Kubernetes owns workload identity and lifecycle, MinIO owns the
-- crash-safe checkpoint/result handoff, and every checkpoint mutation is
-- authorized from fresh fence and Lease observations.
module Prodbox.Bootstrap.Broker.ProductionSecretWorkerBoundary
  ( productionBrokerSecretWorkerBoundary
  )
where

import Control.Concurrent (threadDelay)
import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.ChartStatics qualified as ChartStatics
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerPhysicalCall (..)
  , BrokerSecretWorkerBoundary (..)
  , EngineBoundaryError (..)
  , RootInitCallOutcome (..)
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker
  ( EngineSecretWorkerBoundary (..)
  )
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapSessionFence
  , BootstrapStoreMutation
  , BootstrapStoreMutationPermit
  , authorizeBootstrapStoreMutation
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( ControllerImageIdentity (..)
  , ControllerImageObservation (..)
  , ControllerSelfObservationScope (..)
  , KubernetesWorkerBoundary (..)
  , controllerImageObservationDetail
  , readProjectedServiceAccountToken
  )
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( generatedChildRecoveryCiphertextFromRoot
  )
import Prodbox.Bootstrap.Broker.ProductionStore
  ( ProductionSecretWorkerResult
  , observeProductionSecretWorkerResult
  , productionSecretWorkerResultReceipt
  , productionSecretWorkerResultValue
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( ExecutedSecretWorker
  , RawSecretWorkerReceipt
  , RunningSecretWorker
  , SecretFreeWorkerRequest
  , SecretWorkerAttestationObservation (..)
  , SecretWorkerCleanupBinding (..)
  , SecretWorkerDurableResult
  , SecretWorkerEffectPermit
  , SecretWorkerIntent
  , SecretWorkerLifecycleObservation (..)
  , SecretWorkerOperation (SecretWorkerRotateTransitKey)
  , WorkerServiceAccount
  , WorkerSessionId
  , durableEncryptedInitialization
  , durableFinalizedInitialization
  , durableGeneratedRootCiphertext
  , durableInitializationAmbiguityCause
  , durablePreparedInitialization
  , durableResumedInitialization
  , durableTransitRotationResult
  , durableUnlockRotationResult
  , durableUnsealResult
  , finishSecretWorkerExecution
  , mkSecretWorkerIntent
  , mkWorkerServiceAccount
  , mkWorkerSessionId
  , secretWorkerEffectPermitDeadline
  , secretWorkerEffectPermitRequest
  , secretWorkerRequestOperation
  , workerSessionAccessorIssued
  , workerSessionNotIssued
  )
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , brokerVaultAddress
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary
  )
import Prodbox.Bootstrap.Broker.StoreBoundary qualified as Store
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineExpired
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile (tokenAccessorAuditorRole)
import Prodbox.Vault.RoleId
  ( VaultRoleId (VaultRoleBootstrapBroker)
  , vaultRoleIdText
  )

productionBrokerSecretWorkerBoundary
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BrokerSecretWorkerBoundary IO
productionBrokerSecretWorkerBoundary settings store kubernetes =
  BrokerSecretWorkerBoundary
    { brokerSecretWorkerDriverBoundary = driver
    , runBrokerSecretWorkerPhysicalCall = runPhysicalWorker
    }
 where
  driver =
    EngineSecretWorkerBoundary
      { observeSecretWorkerMonotonicNow = Right <$> realMonotonicNow
      , allocateSecretWorkerIntent = allocateIntent kubernetes
      , createSecretWorkerWorkload = \intent -> do
          deadline <- localDeadline workerApiBudgetMicros
          mapLeftText <$> kubernetesCreateWorkerWorkload kubernetes deadline intent
      , observeSecretWorkerAttestation =
          observeAttestationUntil kubernetes workerStartupBudgetMicros
      , discardUnreceiptedSecretWorker = \request _ -> do
          deadline <- localDeadline workerCleanupBudgetMicros
          discarded <-
            mapLeftText
              <$> kubernetesDiscardUnreceiptedWorker kubernetes deadline request
          case discarded of
            Left failure -> pure (Left failure)
            Right ()
              | secretWorkerRequestOperation request
                  == SecretWorkerRotateTransitKey ->
                  auditWorkerVaultRoleStableZero settings Nothing
              | otherwise -> pure (Right ())
      , withSecretWorkerCheckpointPermit =
          withCheckpointPermit store kubernetes
      , readSecretWorkerCheckpoint = Store.readSecretWorkerCheckpoint store
      , createSecretWorkerCheckpoint = Store.createSecretWorkerCheckpoint store
      , casSecretWorkerCheckpoint = Store.casSecretWorkerCheckpoint store
      , revokeSecretWorkerSession =
          revokeObservedWorkerSession settings
      , observeSecretWorkerExit =
          observeLifecycleUntil
            workerCleanupBudgetMicros
            (kubernetesObserveWorkerExit kubernetes)
            isExited
      , deleteSecretWorkerPod = \binding -> do
          deadline <- localDeadline workerCleanupBudgetMicros
          Right <$> kubernetesDeleteWorkerPod kubernetes deadline binding
      , observeSecretWorkerAbsence =
          observeLifecycleUntil
            workerCleanupBudgetMicros
            (kubernetesObserveWorkerAbsence kubernetes)
            isAbsent
      }

  runPhysicalWorker
    :: forall scope operation result
     . SecretWorkerEffectPermit
    -> RunningSecretWorker scope
    %1 -> BrokerPhysicalCall operation result
    -> IO
         ( Either
             EngineBoundaryError
             ( ExecutedSecretWorker
             , RawSecretWorkerReceipt
             , result
             )
         )
  runPhysicalWorker permit running call =
    finishSecretWorkerExecution
      permit
      (pollPhysicalResult settings permit call)
      running

allocateIntent
  :: KubernetesWorkerBoundary
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError SecretWorkerIntent)
allocateIntent kubernetes operation fence = do
  deadline <- localDeadline workerApiBudgetMicros
  imageObservation <-
    kubernetesObserveControllerImage
      kubernetes
      ControllerObservedForWorkerLaunch
      deadline
  identities <- freshWorkerIdentities
  pure $ do
    -- Sprint 2.51: the intent pins the controller's observed __runtime__ digest,
    -- which is what the worker is attested against. The declared reference the
    -- kubelet needs is observed again at Pod creation, because it is an
    -- addressing hint rather than part of the durable binding.
    image <- case imageObservation of
      ControllerImageObserved observed -> Right (controllerImageRuntimeDigest observed)
      failed ->
        Left
          ( EngineBoundaryUnavailable
              (fromMaybe "controller image observation failed" (controllerImageObservationDetail failed))
          )
    (serviceAccount, sessionId) <- identities
    Right
      ( mkSecretWorkerIntent
          operation
          image
          serviceAccount
          sessionId
          workerSessionNotIssued
          fence
      )

freshWorkerIdentities
  :: IO
       ( Either
           EngineBoundaryError
           ( WorkerServiceAccount
           , WorkerSessionId
           )
       )
freshWorkerIdentities = do
  sessionBytes <- getRandomBytes 32
  pure $ do
    serviceAccount <-
      mapValueError
        "compiled worker ServiceAccount is invalid"
        ( mkWorkerServiceAccount
            (ChartStatics.brokerStaticWorkerServiceAccount ChartStatics.brokerChartStatics)
        )
    sessionId <-
      mapValueError
        "random worker session ID is invalid"
        (mkWorkerSessionId ("worker-session-" <> lowerHexBytes sessionBytes))
    Right (serviceAccount, sessionId)

-- | A workload that never logged in has no Vault identity to revoke. When a
-- worker did log in, the server-issued accessor in its durable receipt is
-- checked through the post-baseline auditor role and its absence is observed
-- before cleanup may advance.
revokeObservedWorkerSession
  :: BootstrapBrokerSettings
  -> SecretWorkerCleanupBinding
  -> IO (Either EngineBoundaryError SecretWorkerLifecycleObservation)
revokeObservedWorkerSession settings binding =
  case workerSessionAccessorIssued (cleanupWorkerSessionAccessor binding) of
    Nothing -> pure (Right (SecretWorkerSessionNotIssued binding))
    Just accessor -> do
      audited <- auditWorkerVaultRoleStableZero settings (Just accessor)
      pure (SecretWorkerSessionRevoked binding <$ audited)

-- | Prove the complete worker-role subject at stable zero with a separately
-- validated accessor-free batch auditor.  The exact known accessor is first
-- revoked provisionally even when a drifted Vault response gave it the wrong
-- policy metadata; the shared subject scan then closes response-loss and
-- unknown-accessor cases.  Every malformed successful auditor login is
-- self-revoked and its accessor is proved absent before the valid auditor is
-- itself revoked.
auditWorkerVaultRoleStableZero
  :: BootstrapBrokerSettings
  -> Maybe Text
  -> IO (Either EngineBoundaryError ())
auditWorkerVaultRoleStableZero settings knownWorkerAccessor = do
  projected <- readProjectedServiceAccountToken
  case projected of
    Left _ -> unavailable "projected Bootstrap Broker token is unavailable"
    Right jwt -> do
      acquired <- acquireStableZeroAuditor settings jwt cleanupAuditorAttempts []
      case acquired of
        Left failure -> pure (Left failure)
        Right (auditor, invalidAuditorAccessors) -> do
          let auditorToken = Vault.vaultLoginToken auditor
          workerAudit <-
            auditVaultSubjectStableZero
              settings
              auditorToken
              bootstrapWorkerVaultSubject
              knownWorkerAccessor
          auditorAudit <- case workerAudit of
            Left failure -> pure (Left failure)
            Right () ->
              auditInvalidAuditorAccessors auditorToken invalidAuditorAccessors
          case auditorAudit of
            Left failure -> pure (Left failure)
            Right () -> do
              revoked <- Vault.vaultRevokeSelf address auditorToken
              pure $ case revoked of
                Left _ ->
                  Left
                    ( EngineBoundaryUnavailable
                        "bounded Vault accessor auditor revoke-self failed"
                    )
                Right () -> Right ()
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  unavailable = pure . Left . EngineBoundaryUnavailable

  auditInvalidAuditorAccessors _ [] = pure (Right ())
  auditInvalidAuditorAccessors token (accessor : remaining) = do
    audited <-
      auditVaultSubjectStableZero
        settings
        token
        bootstrapAuditorVaultSubject
        (Just accessor)
    case audited of
      Left failure -> pure (Left failure)
      Right () -> auditInvalidAuditorAccessors token remaining

acquireStableZeroAuditor
  :: BootstrapBrokerSettings
  -> Text
  -> Natural
  -> [Text]
  -> IO
       ( Either
           EngineBoundaryError
           (Vault.VaultKubernetesLoginResult, [Text])
       )
acquireStableZeroAuditor _ _ 0 _ =
  pure
    ( Left
        ( EngineBoundaryUnavailable
            "Vault cleanup auditor did not return bounded batch evidence"
        )
    )
acquireStableZeroAuditor settings jwt remaining invalidAccessors = do
  loggedIn <-
    Vault.vaultKubernetesLoginWithLease
      address
      "kubernetes"
      tokenAccessorAuditorRole
      jwt
  case loggedIn of
    Left _ ->
      pure
        ( Left
            (EngineBoundaryUnavailable "Vault token-accessor auditor login failed")
        )
    Right login
      | isBoundedBatchAuditorLogin maximumAuditorLeaseSeconds login ->
          pure (Right (login, reverse invalidAccessors))
      | otherwise -> do
          revoked <- Vault.vaultRevokeSelf address (Vault.vaultLoginToken login)
          let maybeAccessor = normalizedVaultLoginAccessor login
          case (maybeAccessor, revoked) of
            (Nothing, Left _) ->
              pure
                ( Left
                    ( EngineBoundaryUnavailable
                        "accessor-free malformed auditor login could not be revoked"
                    )
                )
            _ ->
              acquireStableZeroAuditor
                settings
                jwt
                (remaining - 1)
                (maybe invalidAccessors (: invalidAccessors) maybeAccessor)
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

auditVaultSubjectStableZero
  :: BootstrapBrokerSettings
  -> Vault.VaultToken
  -> VaultAccessorSubject
  -> Maybe Text
  -> IO (Either EngineBoundaryError ())
auditVaultSubjectStableZero settings auditorToken subject maybeKnown = do
  -- This direct revoke is intentionally provisional: an applied response may
  -- be lost.  The shared finite proof below decides terminal absence.
  traverse_ (Vault.vaultRevokeTokenAccessor address auditorToken) maybeKnown
  audited <-
    revokeAndProveVaultAccessorSubjectAbsent
      VaultAccessorAuditOps
        { auditListAccessors =
            fmap
              (either (Left . Text.pack . show) (Right . Vault.tokenAccessorKeys))
              (Vault.vaultListTokenAccessors address auditorToken)
        , auditLookupAccessor = \accessor ->
            fmap
              (either (Left . Text.pack . show) Right)
              (Vault.vaultLookupTokenAccessorInfo address auditorToken accessor)
        , auditRevokeAccessor = \accessor ->
            fmap
              (either (Left . Text.pack . show) Right)
              (Vault.vaultRevokeTokenAccessor address auditorToken accessor)
        , auditObserveAccessorAbsent = \accessor ->
            fmap
              (either (Left . Text.pack . show) Right)
              (Vault.vaultTokenAccessorAbsent address auditorToken accessor)
        , auditWaitVisibilityGrace = do
            threadDelay vaultAccessorVisibilityGraceMicros
            pure (Right ())
        }
      subject
      maybeKnown
  pure $ case audited of
    Left refusal ->
      Left
        ( EngineBoundaryRefused
            ("Vault worker-session stable-zero audit failed: " <> Text.pack (show refusal))
        )
    Right () -> Right ()
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

bootstrapWorkerVaultSubject :: VaultAccessorSubject
bootstrapWorkerVaultSubject =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies =
        ["default", vaultRoleIdText VaultRoleBootstrapBroker]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", vaultRoleIdText VaultRoleBootstrapBroker)
          , ("service_account_name", "prodbox-bootstrap-secret-worker")
          , ("service_account_namespace", "bootstrap-broker")
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

bootstrapAuditorVaultSubject :: VaultAccessorSubject
bootstrapAuditorVaultSubject =
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", tokenAccessorAuditorRole]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", tokenAccessorAuditorRole)
          , ("service_account_name", "prodbox-bootstrap-broker")
          , ("service_account_namespace", "bootstrap-broker")
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

normalizedVaultLoginAccessor
  :: Vault.VaultKubernetesLoginResult -> Maybe Text
normalizedVaultLoginAccessor login =
  let accessor = Text.strip (Vault.vaultLoginAccessor login)
   in if Text.null accessor then Nothing else Just accessor

cleanupAuditorAttempts :: Natural
cleanupAuditorAttempts = 4

maximumAuditorLeaseSeconds :: Int
maximumAuditorLeaseSeconds = 300

vaultAccessorVisibilityGraceMicros :: Int
vaultAccessorVisibilityGraceMicros = 500000

observeAttestationUntil
  :: KubernetesWorkerBoundary
  -> Natural
  -> SecretFreeWorkerRequest
  -> IO (Either EngineBoundaryError SecretWorkerAttestationObservation)
observeAttestationUntil kubernetes budget request = do
  deadline <- localDeadline budget
  go deadline
 where
  go deadline = do
    observed <- kubernetesObserveWorkerAttestation kubernetes deadline request
    case observed of
      SecretWorkerAttestationObserved {} -> pure (Right observed)
      _ -> do
        now <- realMonotonicNow
        if deadlineExpired now deadline
          then pure (Right observed)
          else do
            threadDelay workerPollMicros
            go deadline

observeLifecycleUntil
  :: Natural
  -> (Deadline -> binding -> IO SecretWorkerLifecycleObservation)
  -> (SecretWorkerLifecycleObservation -> Bool)
  -> binding
  -> IO (Either EngineBoundaryError SecretWorkerLifecycleObservation)
observeLifecycleUntil budget observe terminal binding = do
  deadline <- localDeadline budget
  go deadline
 where
  go deadline = do
    observed <- observe deadline binding
    if terminal observed
      then pure (Right observed)
      else do
        now <- realMonotonicNow
        if deadlineExpired now deadline
          then pure (Right observed)
          else do
            threadDelay workerPollMicros
            go deadline

isExited :: SecretWorkerLifecycleObservation -> Bool
isExited observation = case observation of
  SecretWorkerProcessExited {} -> True
  _ -> False

isAbsent :: SecretWorkerLifecycleObservation -> Bool
isAbsent observation = case observation of
  SecretWorkerPodAbsent {} -> True
  _ -> False

withCheckpointPermit
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BootstrapSessionFence
  -> BootstrapStoreMutation
  -> ( MonotonicInstant
       -> BootstrapStoreMutationPermit
       -> IO result
     )
  -> IO (Either EngineBoundaryError result)
withCheckpointPermit store kubernetes fence mutation use = do
  now <- realMonotonicNow
  deadline <- localDeadline workerApiBudgetMicros
  clock <- authorityClockNow
  observedStore <- Store.observeBootstrapSessionFence store
  observedLease <- kubernetesObserveBootstrapLease kubernetes deadline
  case observedStore of
    Left failure -> pure (Left (EngineBoundaryUnavailable (Text.pack (show failure))))
    Right storeObservation ->
      case authorizeBootstrapStoreMutation
        now
        deadline
        clock
        fence
        storeObservation
        observedLease
        mutation of
        Left refusal ->
          pure (Left (EngineBoundaryRefused (Text.pack (show refusal))))
        Right permit -> Right <$> use now permit

pollPhysicalResult
  :: BootstrapBrokerSettings
  -> SecretWorkerEffectPermit
  -> BrokerPhysicalCall operation result
  -> IO (Either EngineBoundaryError (RawSecretWorkerReceipt, result))
pollPhysicalResult settings permit call = go
 where
  request = secretWorkerEffectPermitRequest permit
  deadline = secretWorkerEffectPermitDeadline permit

  go = do
    observed <- observeProductionSecretWorkerResult settings request
    case observed of
      Left failure ->
        pure (Left (EngineBoundaryUnavailable (Text.pack (show failure))))
      Right (Just result) -> pure (projectPhysicalResult call result)
      Right Nothing -> do
        now <- realMonotonicNow
        if deadlineExpired now deadline
          then pure (Left (EngineBoundaryRefused "secret-worker result deadline elapsed"))
          else do
            threadDelay workerPollMicros
            go

projectPhysicalResult
  :: forall operation result
   . BrokerPhysicalCall operation result
  -> ProductionSecretWorkerResult
  -> Either EngineBoundaryError (RawSecretWorkerReceipt, result)
projectPhysicalResult call production = do
  projected <- project (productionSecretWorkerResultValue production)
  Right (productionSecretWorkerResultReceipt production, projected)
 where
  project :: SecretWorkerDurableResult -> Either EngineBoundaryError result
  project durable = case call of
    PhysicalPrepareRootInitRecipients {} ->
      requireProjection (durablePreparedInitialization durable)
    PhysicalResumeRootInitRecipients {} ->
      requireProjection (durableResumedInitialization durable)
    PhysicalInitializeVault {} ->
      case durableInitializationAmbiguityCause durable of
        Just cause -> Right (RootInitAppliedWithoutResponse cause)
        Nothing ->
          RootInitEncryptedResponse
            <$> requireProjection (durableEncryptedInitialization durable)
    PhysicalSealFinalUnlockBundle {} ->
      requireProjection (durableFinalizedInitialization durable)
    PhysicalUnsealVault {} ->
      requireProjection (durableUnsealResult durable)
    PhysicalRotateUnlockBundle {} ->
      requireProjection (durableUnlockRotationResult durable)
    PhysicalRotateTransitKey {} ->
      requireProjection (durableTransitRotationResult durable)
    PhysicalAwaitGeneratedRootCiphertext {} ->
      requireProjection (durableGeneratedRootCiphertext durable)
    PhysicalAwaitChildGeneratedRootCiphertext {} ->
      generatedChildRecoveryCiphertextFromRoot
        <$> requireProjection (durableGeneratedRootCiphertext durable)
    _ -> Left (EngineBoundaryRefused "physical call is not a secret-worker operation")

  requireProjection =
    maybe
      (Left (EngineBoundaryRefused "secret-worker durable result constructor mismatch"))
      Right

localDeadline :: Natural -> IO Deadline
localDeadline budget = do
  now <- realMonotonicNow
  pure (deadlineAtOffset now (RemainingDuration budget))

authorityClockNow :: IO AuthorityClockObservation
authorityClockNow = do
  seconds <- getPOSIXTime
  let micros :: Natural
      micros = max 0 (floor (seconds * 1000000))
  pure
    ( AuthorityTimeTrusted
        (authorityTimeFromMicros micros)
        (clockUncertaintyFromMicros 1000)
    )

mapLeftText :: Either Text value -> Either EngineBoundaryError value
mapLeftText = either (Left . EngineBoundaryUnavailable) Right

mapValueError
  :: Text
  -> Either error value
  -> Either EngineBoundaryError value
mapValueError detail = either (const (Left (EngineBoundaryRefused detail))) Right

lowerHexBytes :: ByteString.ByteString -> Text
lowerHexBytes = Text.pack . concatMap twoHex . ByteString.unpack
 where
  twoHex byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

workerApiBudgetMicros :: Natural
workerApiBudgetMicros = 5 * 1000 * 1000

workerStartupBudgetMicros :: Natural
workerStartupBudgetMicros = 2 * 60 * 1000 * 1000

workerCleanupBudgetMicros :: Natural
workerCleanupBudgetMicros = 30 * 1000 * 1000

workerPollMicros :: Int
workerPollMicros = 100000
