{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Production composition for the Bootstrap Broker.  This module owns the
-- process-scoped fence identity and is the only place where the engine's
-- abstract store, Kubernetes, authority-clock, and Vault observation ports are
-- connected to live interpreters.
module Prodbox.Bootstrap.Broker.ProductionEngine
  ( BrokerReadinessCache
  , BaselineSessionIdentityPlan (..)
  , brokerReadinessCacheRefresh
  , classifyRootAccessorAbsenceHttpFailure
  , classifyRootAccessorAbsenceListing
  , classifyRootAccessorInventoryHttpFailure
  , classifyRootAccessorInventoryListing
  , classifyRootAccessorRevocationHttpFailure
  , classifyRootAccessorRevocationListing
  , classifyProvisionerAccessorCleanupHttpFailure
  , classifyProvisionerAccessorCleanupListing
  , classifyProvisionerAccessorRevocationHttpFailure
  , classifyProvisionerAccessorRevocationListing
  , classifyProvisionerAccessorAbsenceHttpFailure
  , classifyProvisionerAccessorAbsenceListing
  , classifyProvisionerPolicyRepairHttpFailure
  , classifyProvisionerPolicyCoreReconcileFailure
  , classifyProvisionerPolicyPkiReconcileFailure
  , decideRootAccessorAbsenceProof
  , planBaselineSessionIdentity
  , productionBrokerEngine
  )
where

import Codec.Serialise (Serialise, serialise)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , newTVarIO
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, mask, throwIO, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Custody
  ( RootInitPhase (..)
  , RootInitState (..)
  )
import Prodbox.Bootstrap.Broker.Engine
  ( BrokerEngine
  , BrokerEngineBoundary (..)
  , BrokerLocalCall (..)
  , BrokerPhysicalCall (..)
  , BrokerProgramEvidenceBoundary (..)
  , EngineBoundaryError (..)
  , EngineFenceUseObservation (..)
  , ProvisionerAccessorAbsenceCause (..)
  , ProvisionerAccessorAbsenceHttpFailure (..)
  , ProvisionerAccessorAbsenceHttpOperation (..)
  , ProvisionerAccessorCleanupCause (..)
  , ProvisionerAccessorCleanupHttpFailure (..)
  , ProvisionerAccessorCleanupHttpOperation (..)
  , ProvisionerAccessorRevocationCause (..)
  , ProvisionerAccessorRevocationHttpFailure (..)
  , ProvisionerAccessorRevocationHttpOperation (..)
  , ProvisionerPolicyApplicationCause (..)
  , RootAccessorAbsenceProofCause (..)
  , RootAccessorAbsenceProofHttpFailure (..)
  , RootAccessorAbsenceProofHttpOperation (..)
  , RootAccessorAbsenceProofRequirement (..)
  , RootAccessorInventoryCause (..)
  , RootAccessorInventoryHttpFailure (..)
  , RootAccessorInventoryHttpOperation (..)
  , RootAccessorRevocationCause (..)
  , RootAccessorRevocationHttpFailure (..)
  , RootAccessorRevocationHttpOperation (..)
  , RootInitRecoveryObservation (..)
  , mkBrokerEngine
  )
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceAcquireDecision (..)
  , BootstrapFenceAcquireRefusal (..)
  , BootstrapFenceOwnerCleanupObservation (..)
  , BootstrapFenceRetireConfirmationRefusal (..)
  , BootstrapFenceRetireRefusal (..)
  , BootstrapFenceStoreObservation
  , BootstrapLeaseObservation (..)
  , BootstrapLeaseRefusal (..)
  , BootstrapSessionFence
  , BootstrapStoreMutationPermit
  , BootstrapVaultEffectPermit
  , abandonFreshlyAcquiredFence
  , bootstrapFenceGeneration
  , bootstrapFenceGenerationValue
  , bootstrapFenceOwnerCleanupFromWorkerObservation
  , confirmBootstrapFenceCas
  , confirmBootstrapFenceRetireCas
  , confirmBootstrapLease
  , decideBootstrapFenceAcquire
  , decideBootstrapFenceRetire
  , mkBootstrapFenceAcquireRequest
  , vaultEffectPermitActionDigest
  , vaultEffectPermitDeadline
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( ControllerImageObservation (..)
  , ControllerSelfObservationScope (..)
  , KubernetesWorkerBoundary (..)
  , VaultStorageIdentity
  , productionKubernetesWorkerBoundary
  , readProjectedServiceAccountToken
  , renderVaultStorageIdentity
  , renderVaultStorageResetFailure
  )
import Prodbox.Bootstrap.Broker.Model
  ( PostUnsealHandoffPhase (..)
  , PostUnsealHandoffState (..)
  , RootSessionBinding (..)
  , RootSessionPhase (..)
  , RootSessionState (..)
  , rootSessionBaselineIsCurrent
  , rootSessionIsCancelledClean
  , rootSessionIsComplete
  )
import Prodbox.Bootstrap.Broker.PgpBoundary
  ( GeneratedRootCoreHttpFailure (..)
  , generatedChildRecoveryPublicKeyBase64
  , generatedRootPublicKeyBase64
  )
import Prodbox.Bootstrap.Broker.PristineJournal
  ( classifyPristineJournal
  )
import Prodbox.Bootstrap.Broker.ProductionCapabilities
  ( ProductionCapabilityRegistry
  , mkProductionCapabilityRegistry
  , productionCapabilityInventoryComplete
  , productionCapabilityRegistryBindings
  )
import Prodbox.Bootstrap.Broker.ProductionCryptoParameters
  ( productionPristineStorageProof
  , productionRootInitCryptoParameters
  )
import Prodbox.Bootstrap.Broker.ProductionPgp
  ( classifyVaultCoreReconcileFailure
  , classifyVaultPkiReconcileFailure
  , productionPgpBoundaryAt
  , productionPgpReady
  )
import Prodbox.Bootstrap.Broker.ProductionSecretWorkerBoundary
  ( productionBrokerSecretWorkerBoundary
  )
import Prodbox.Bootstrap.Broker.ProductionStore
  ( bootstrapStoreReady
  , productionBootstrapStoreBoundary
  , productionTransitRotationBoundary
  )
import Prodbox.Bootstrap.Broker.Program
  ( BootstrapMutationReceipt (..)
  , BootstrapStatus (..)
  , PkiIssueRequest
  , VaultPkiStatus (..)
  , mkBrokerCapabilityRefs
  , pkiIssueCommonName
  , pkiIssueTtlSeconds
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , brokerActionDigest
  , brokerActionStorageGeneration
  )
import Prodbox.Bootstrap.Broker.Readiness
  ( BrokerDependencyObservation (..)
  , BrokerReadinessFacts (..)
  , BrokerReadinessState
  , brokerReadinessSchedule
  , computeBrokerReadiness
  , observationBudgetMicros
  , unobservedBrokerReadinessFacts
  )
import Prodbox.Bootstrap.Broker.Request (RequestDigest)
import Prodbox.Bootstrap.Broker.Routes (BrokerRoute)
import Prodbox.Bootstrap.Broker.Settings
  ( BootstrapBrokerSettings
  , brokerClusterId
  , brokerServiceIdentity
  , brokerVaultAddress
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , StoreBoundaryError
  , StoreReadBack (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( AccessorAbsenceAttestation
  , ArtifactDigest
  , BaselineReadBackReceipt
  , BootstrapValueError (..)
  , ChildAttestation
  , ChildCustodyBinding (..)
  , DeliveryNonce
  , InitAmbiguity
  , PostUnsealConsumer
  , PostUnsealHandoffReceipt
  , PreparedInitEnvelope
  , PristineResetProof
  , PristineStorageProof
  , ProvisionerAccessor
  , ProvisionerAccessorAbsenceAttestation
  , ProvisionerLoginReceipt
  , RecoveryCustodyReceipt
  , RootAccessorInventory
  , RootInitBinding (..)
  , RootPolicyAccessor
  , RootSessionId
  , VaultStorageGeneration
  , ambiguousInitBinding
  , ambiguousPreparedEnvelopeDigest
  , baselineReadBackStorageGeneration
  , encryptedResponseBurnToken
  , encryptedResponseShares
  , finalUnlockBundleBinding
  , mkAccessorAbsenceAttestation
  , mkArtifactDigest
  , mkBaselineStateAbsence
  , mkBootstrapTransactionId
  , mkChildAttestation
  , mkChildEncryptedReceipt
  , mkChildId
  , mkCustodyGeneration
  , mkDeliveryNonce
  , mkDurableInitResponseAbsence
  , mkEstablishedStateAbsence
  , mkPristineResetProof
  , mkProvisionerAccessor
  , mkProvisionerAccessorAbsenceAttestation
  , mkProvisionerAccessorInventory
  , mkProvisionerLoginReceipt
  , mkRecoveryCustodyReceipt
  , mkRootAccessorInventory
  , mkRootPolicyAccessor
  , mkRootSessionId
  , mkVaultStorageGeneration
  , preparedInitEnvelopeDigest
  , pristineStorageBinding
  , provisionerLoginAccessor
  , provisionerLoginStorageGeneration
  , renderArtifactDigest
  , renderProvisionerAccessor
  , renderRootPolicyAccessor
  , resetAmbiguity
  , resetAmbiguousBinding
  , resetReplacementPristine
  , rootAccessorInventoryAccessors
  , rootAccessorInventoryGeneration
  , rootInitStorageGeneration
  )
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  , deriveOperationDeadline
  )
import Prodbox.ControlPlane.BootstrapCustodyClient
  ( BootstrapCustodyClient
  , BootstrapCustodyClientError (..)
  , bootstrapCustodyClient
  )
import Prodbox.ControlPlane.BootstrapCustodyClient qualified as BootstrapCustody
import Prodbox.ControlPlane.BootstrapCustodyEndpoint
  ( bootstrapCustodyMaximumBytes
  )
import Prodbox.ControlPlane.BootstrapHandoffClient
  ( BootstrapHandoffClient
  , BootstrapHandoffClientError (..)
  , bootstrapHandoffClient
  )
import Prodbox.ControlPlane.BootstrapHandoffClient qualified as BootstrapHandoff
import Prodbox.ControlPlane.BootstrapHandoffEndpoint
  ( bootstrapHandoffMaximumBytes
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.Client
  ( mkLifecycleAuthorityEndpoint
  , mkTargetSecretAgentEndpoint
  , newControlPlaneClient
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineExpired
  , deadlineObservation
  , monotonicInstantMicros
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.ListenPort (controlPlaneClusterServiceUrlText)
import Prodbox.ControlPlane.RequestAuthentication (mkRequestNonce)
import Prodbox.ControlPlane.RetainedAuthentication
  ( readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.TransitRequestAuthentication
  ( resolveTransitRequestSigningCapability
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditDetailedError (..)
  , VaultAccessorAuditDetailedOps (..)
  , VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  , revokeAndProveVaultAccessorSubjectAbsent
  , revokeAndProveVaultAccessorSubjectAbsentDetailed
  , vaultAccessorMatchesSubject
  )
import Prodbox.Http.Client (HttpError (..), defaultHttpConfig)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , OwnerNonce
  , addAuthorityDuration
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import Prodbox.Runtime.Role (RuntimeRole (BootstrapBroker))
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile
  ( bootstrapControlPlaneClientRole
  , bootstrapPkiOperatorRole
  , bootstrapPolicyRepairRole
  , bootstrapProvisionerPolicySpec
  , bootstrapProvisionerRole
  , bootstrapSealRole
  , observeVaultPkiBaseline
  , provisionerVaultReconcilePlan
  , reconcileVaultPkiBaseline
  , runVaultReconcile
  , tokenAccessorAuditorRole
  )
import Prodbox.Vault.Reconcile qualified as VaultReconcile
import Prodbox.Vault.Session qualified as VaultSession

data ProductionBrokerClients = ProductionBrokerClients
  { productionCustodyClient :: !(BootstrapCustodyClient IO)
  , productionHandoffClient :: !(BootstrapHandoffClient IO)
  }

type ProvisionerTokenRegistry = IORef (Map ProvisionerAccessor Vault.VaultToken)

-- | Build the production engine together with the readiness cache its
-- background observer owns. The two are returned as one value so a caller
-- cannot start the listener without also holding the thing that must keep the
-- latch fresh.
productionBrokerEngine
  :: BootstrapBrokerSettings
  -> IO (Either String (BrokerEngine IO, BrokerReadinessCache))
productionBrokerEngine settings = do
  storeResult <- productionBootstrapStoreBoundary settings
  kubernetesResult <- productionKubernetesWorkerBoundary
  ownerResult <- freshOwnerNonce
  clientsResult <- productionBrokerClients settings
  provisionerTokens <- newIORef Map.empty
  -- Fail-closed until the observer's first pass completes.
  factsVar <- newTVarIO unobservedBrokerReadinessFacts
  pure $ do
    store <- mapLeft show storeResult
    kubernetes <- kubernetesResult
    owner <- ownerResult
    clients <- clientsResult
    observe <- coordinate "bootstrap-observe"
    mutate <- coordinate "bootstrap-mutate"
    baseline <- coordinate "baseline-reconcile"
    pki <- coordinate "pki-operate"
    let cache =
          BrokerReadinessCache
            { brokerReadinessCacheFacts = factsVar
            , brokerReadinessCacheRefresh = pure ()
            }
        (boundary, capabilityRegistry) =
          productionBoundary settings owner store kubernetes clients provisionerTokens cache
        refresh = do
          facts <- observeBrokerReadinessFacts capabilityRegistry settings kubernetes
          atomically (writeTVar factsVar facts)
    engine <-
      mkBrokerEngine
        (mkBrokerCapabilityRefs observe mutate baseline pki)
        64
        boundary
    Right (engine, cache {brokerReadinessCacheRefresh = refresh})
 where
  coordinate :: Text -> Either String CapabilityCoordinate
  coordinate logicalName = do
    service <- mapLeft show (mkServiceIdentity (brokerServiceIdentity settings))
    authority <- mapLeft show (mkAuthorityScope ("bootstrap/" <> brokerClusterId settings))
    endpoint <- mapLeft show (mkCapabilityEndpoint (brokerVaultAddress settings))
    logical <- mapLeft show (mkLogicalName logicalName)
    generation <- mapLeft show (mkCredentialGeneration 1)
    Right (mkCoordinate service authority endpoint logical generation)

productionBrokerClients
  :: BootstrapBrokerSettings -> IO (Either String ProductionBrokerClients)
productionBrokerClients settings =
  case clientConstants of
    Left detail -> pure (Left detail)
    Right (bounds, lifetime, scope, targetRaw, authorityRaw) -> do
      session <-
        VaultSession.newVaultSession
          address
          VaultSession.realSessionClock
          login
      let principal = CallerService BootstrapBroker
          providers =
            AuthenticatedClientProviders
              { provideAuthenticatedClientSigner =
                  resolveTransitRequestSigningCapability
                    session
                    principal
                    (controlPlaneSigningKeyRefFor principal)
              , provideAuthenticatedClientScope = pure (Right scope)
              , provideAuthenticatedClientEpoch = readRetainedAuthorityEpoch session
              , provideAuthenticatedClientDeadline = do
                  now <- currentClientAuthorityTime
                  pure (Right (addAuthorityDuration now lifetime))
              , provideAuthenticatedClientNonce = do
                  bytes <- getRandomBytes 32
                  pure (mapLeft (Text.pack . show) (mkRequestNonce bytes))
              }
          custody =
            bootstrapCustodyClient
              (mkAuthenticatedClientTransport bounds providers targetRaw)
          handoff =
            bootstrapHandoffClient
              (mkAuthenticatedClientTransport bounds providers authorityRaw)
      pure
        ( Right
            ProductionBrokerClients
              { productionCustodyClient = custody
              , productionHandoffClient = handoff
              }
        )
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  login = do
    projected <- readProjectedServiceAccountToken
    case projected of
      Left detail ->
        pure (Left (VaultSession.VaultSessionUnavailable (Text.unpack detail)))
      Right jwt -> do
        result <-
          Vault.vaultKubernetesLoginWithLease
            address
            "kubernetes"
            bootstrapControlPlaneClientRole
            jwt
        pure $ case result of
          Left err -> Left (VaultSession.httpErrorToSessionError err)
          Right lease
            | not (isBoundedBatchAuditorLogin (15 * 60) lease) ->
                Left
                  ( VaultSession.VaultSessionUnavailable
                      "Bootstrap control-plane client did not receive a bounded batch token"
                  )
          Right lease ->
            Right
              VaultSession.LoginLease
                { VaultSession.loginLeaseToken = Vault.vaultLoginToken lease
                , VaultSession.loginLeaseSeconds = Vault.vaultLoginLeaseSeconds lease
                , VaultSession.loginLeaseRenewable = Vault.vaultLoginRenewable lease
                }

  clientConstants = do
    bounds <-
      mapLeft
        show
        (mkAuthenticatedTransportBounds clientFrameMaximum 1024 clientEnvelopeMaximum)
    lifetime <- mapLeft show (authorityDurationFromMicros (30 * 1000 * 1000))
    scope <- mapLeft show (mkAuthorityScope (brokerClusterId settings))
    targetEndpoint <-
      mapLeft
        show
        (mkTargetSecretAgentEndpoint targetSecretAgentServiceEndpoint)
    targetRaw <-
      mapLeft
        show
        (newControlPlaneClient defaultHttpConfig bootstrapCustodyMaximumBytes targetEndpoint)
    authorityEndpoint <-
      mapLeft
        show
        (mkLifecycleAuthorityEndpoint lifecycleAuthorityServiceEndpoint)
    authorityRaw <-
      mapLeft
        show
        (newControlPlaneClient defaultHttpConfig bootstrapHandoffMaximumBytes authorityEndpoint)
    Right (bounds, lifetime, scope, targetRaw, authorityRaw)

  clientFrameMaximum = bootstrapCustodyMaximumBytes + 64 * 1024
  clientEnvelopeMaximum = bootstrapCustodyMaximumBytes + 32 * 1024

currentClientAuthorityTime :: IO AuthorityTime
currentClientAuthorityTime = do
  now <- getCurrentTime
  pure
    ( authorityTimeFromMicros
        ( fromInteger
            (max 0 (floor (utcTimeToPOSIXSeconds now * 1000000) :: Integer))
        )
    )

targetSecretAgentServiceEndpoint :: Text
targetSecretAgentServiceEndpoint =
  controlPlaneClusterServiceUrlText "target-secret-agent" "target-secret-agent"

lifecycleAuthorityServiceEndpoint :: Text
lifecycleAuthorityServiceEndpoint =
  controlPlaneClusterServiceUrlText "lifecycle-authority" "lifecycle-authority"

productionBoundary
  :: BootstrapBrokerSettings
  -> OwnerNonce
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> ProductionBrokerClients
  -> ProvisionerTokenRegistry
  -> BrokerReadinessCache
  -> (BrokerEngineBoundary IO, ProductionCapabilityRegistry)
productionBoundary settings owner store kubernetes clients provisionerTokens readinessCache =
  let evidence = productionEvidence settings store kubernetes
      secretWorker = productionBrokerSecretWorkerBoundary settings store kubernetes
      pgp =
        productionPgpBoundaryAt
          (Vault.VaultAddress (brokerVaultAddress settings))
      transitRotation = productionTransitRotationBoundary settings
      capabilityRegistry =
        mkProductionCapabilityRegistry
          evidence
          store
          transitRotation
          pgp
          secretWorker
          ( runPhysical
              capabilityRegistry
              settings
              store
              kubernetes
              clients
              provisionerTokens
              readinessCache
          )
          (runLocal store clients)
      boundary =
        BrokerEngineBoundary
          { engineEvidenceBoundary = evidence
          , engineResolveRootInitCryptoParameters =
              \proof ->
                pure
                  ( mapLeft
                      (EngineBoundaryRefused . Text.pack)
                      (productionRootInitCryptoParameters settings proof)
                  )
          , engineAdmitCapability = \_ _ -> pure (Right ())
          , engineBeginCapabilityExecution = \_ _ -> pure (Right ())
          , engineAcquireMutationFence = acquireFence owner store kubernetes
          , engineObserveFenceUse = observeFenceUse store kubernetes
          , engineReleaseMutationFence = releaseFence store
          , engineRunPhysicalCall =
              runPhysical
                capabilityRegistry
                settings
                store
                kubernetes
                clients
                provisionerTokens
                readinessCache
          , engineRunLocalCall = runLocal store clients
          , engineSecretWorkerBoundary = Just secretWorker
          , enginePgpBoundary = Just pgp
          , engineInMemoryBoundary = Nothing
          , engineStoreBoundary = store
          }
   in (boundary, capabilityRegistry)

productionEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BrokerProgramEvidenceBoundary IO
productionEvidence settings store kubernetes =
  BrokerProgramEvidenceBoundary
    { resolvePristineStorageProof = pristineEvidence settings store
    , resolveUnsealRecoveryCustody = recoveryEvidence store
    , resolveUnlockRotationCustody = recoveryEvidence store
    , resolveBaselineCustodyAndSession = baselineEvidence store
    , resolveAmbiguousResetEvidence =
        resetEvidence settings store kubernetes
    , resolveChildCustodyBinding = childCustodyEvidence settings store
    , resolveChildRecoveryDeliveryEvidence = childRecoveryDeliveryEvidence settings store
    , resolveChildRecoveryObservation = childRecoveryObservationEvidence settings store
    }

-- | The current durable root binding is the child bootstrap intent anchor.
-- The custody transaction therefore cannot be rebound by controller JSON: its
-- child identity comes from mounted configuration, its storage generation and
-- transaction come from the exact MinIO generation object, and the first
-- custody generation is the closed bootstrap generation.
childCustodyEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError ChildCustodyBinding)
childCustodyEvidence settings store action = do
  observed <- observeVaultStorageGeneration store
  pure $ do
    binding <- mapLeft storeBoundaryError observed
    if rootInitStorageGeneration binding /= brokerActionStorageGeneration action
      then Left (EngineBoundaryRefused "child-custody action generation does not match durable storage")
      else do
        child <- mapValue (mkChildId (brokerClusterId settings))
        generation <- mapValue (mkCustodyGeneration 1)
        Right
          ChildCustodyBinding
            { childCustodyChildId = child
            , childCustodyStorageGeneration = rootInitStorageGeneration binding
            , childCustodyGeneration = generation
            , childCustodyTransactionId = rootInitTransactionId binding
            }
 where
  mapValue = mapLeft (EngineBoundaryRefused . Text.pack . show)

childRecoveryDeliveryEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO
       ( Either
           EngineBoundaryError
           (ChildCustodyBinding, DeliveryNonce, ChildAttestation)
       )
childRecoveryDeliveryEvidence settings store action = do
  bindingResult <- childCustodyEvidence settings store action
  pure $ do
    binding <- bindingResult
    nonce <-
      mapLeft
        (EngineBoundaryRefused . Text.pack . show)
        (mkDeliveryNonce (renderArtifactDigest (brokerActionDigest action)))
    Right (binding, nonce, mkChildAttestation (brokerActionDigest action))

childRecoveryObservationEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError (ChildCustodyBinding, DeliveryNonce))
childRecoveryObservationEvidence settings store action = do
  resolved <- childRecoveryDeliveryEvidence settings store action
  pure $ do
    (binding, nonce, _) <- resolved
    Right (binding, nonce)

pristineEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError PristineStorageProof)
pristineEvidence settings store action = do
  generation <- observeVaultStorageGeneration store
  status <- Vault.vaultSealStatus (Vault.VaultAddress (brokerVaultAddress settings))
  case (generation, status) of
    (Right binding, Right observed)
      | rootInitStorageGeneration binding /= brokerActionStorageGeneration action ->
          boundaryRefused "request storage generation does not match the durable generation"
      | Vault.sealStatusInitialized observed ->
          boundaryRefused "Vault is already initialized"
      | otherwise -> do
          journal <- readRootInitJournal store binding
          pure $ case journal of
            Right observation ->
              case classifyPristineJournal binding observation of
                Right proof -> Right proof
                Left _ ->
                  Left
                    ( EngineBoundaryRefused
                        "root initialization journal is not pristine"
                    )
            Left failure -> Left (storeBoundaryError failure)
    (Left failure, _) -> pure (Left (storeBoundaryError failure))
    (_, Left _) -> boundaryUnavailable "Vault seal-status is unavailable"

resetEvidence
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError (InitAmbiguity, PristineResetProof))
resetEvidence settings store kubernetes action = do
  let oldGeneration = brokerActionStorageGeneration action
  generationResult <- observeVaultStorageGeneration store
  journalResult <- readRootInitJournalForReset store oldGeneration
  case (generationResult, journalResult) of
    (Left failure, _) -> pure (Left (storeBoundaryError failure))
    (_, Left failure) -> pure (Left (storeBoundaryError failure))
    (_, Right StoreObjectAbsent) ->
      boundaryRefused "ambiguous root-initialization journal is absent"
    (Right currentBinding, Right (StoreObjectPresent _ _ state)) ->
      case rootInitStatePhase state of
        RootResetPristine proof ->
          pure
            ( validatePersistedResetEvidence
                oldGeneration
                currentBinding
                proof
            )
        RootInitializationAmbiguous ambiguity
          | rootInitStorageGeneration (ambiguousInitBinding ambiguity)
              /= oldGeneration ->
              boundaryRefused "ambiguous root initialization has another storage generation"
          | otherwise ->
              auditAmbiguousReset
                settings
                store
                kubernetes
                action
                currentBinding
                ambiguity
        _ -> boundaryRefused "root initialization is not in an ambiguous phase"

validatePersistedResetEvidence
  :: VaultStorageGeneration
  -> RootInitBinding
  -> PristineResetProof
  -> Either EngineBoundaryError (InitAmbiguity, PristineResetProof)
validatePersistedResetEvidence oldGeneration currentBinding proof
  | rootInitStorageGeneration (resetAmbiguousBinding proof) /= oldGeneration =
      Left (EngineBoundaryRefused "persisted reset proof names another old generation")
  | currentBinding /= resetAmbiguousBinding proof
      && currentBinding
        /= pristineStorageBinding (resetReplacementPristine proof) =
      Left (EngineBoundaryRefused "persisted reset proof does not name the durable generation")
  | otherwise = Right (resetAmbiguity proof, proof)

auditAmbiguousReset
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BrokerActionRequest
  -> RootInitBinding
  -> InitAmbiguity
  -> IO (Either EngineBoundaryError (InitAmbiguity, PristineResetProof))
auditAmbiguousReset settings store kubernetes action currentBinding ambiguity = do
  let oldBinding = ambiguousInitBinding ambiguity
      oldGeneration = rootInitStorageGeneration oldBinding
  preparedResult <- readPreparedInitEnvelope store oldBinding
  responseResult <- readEncryptedInitResponse store oldBinding
  bundleResult <- readFinalUnlockBundle store oldBinding
  sessionResult <- readRootSessionJournal store oldGeneration
  handoffResult <- readPostUnsealHandoff store oldBinding
  statusResult <- Vault.vaultSealStatus (Vault.VaultAddress (brokerVaultAddress settings))
  now <- realMonotonicNow
  identityResult <-
    kubernetesObserveVaultStorageIdentity
      kubernetes
      (deadlineAtOffset now (RemainingDuration (5 * 1000 * 1000)))
  pure $ do
    prepared <- mapLeft storeBoundaryError preparedResult
    requireAmbiguousPreparedEnvelope ambiguity prepared
    requireResetObjectAbsent "durable init response" responseResult
    requireResetObjectAbsent "final unlock bundle" bundleResult
    requireResetObjectAbsent "root session" sessionResult
    requireResetObjectAbsent "post-unseal handoff" handoffResult
    status <-
      mapLeft
        (const (EngineBoundaryUnavailable "Vault seal-status is unavailable"))
        statusResult
    identity <-
      mapLeft
        (const (EngineBoundaryUnavailable "Vault storage identity is unavailable"))
        identityResult
    replacement <- resetReplacementBinding action ambiguity identity
    if currentBinding /= oldBinding && currentBinding /= replacement
      then
        Left (EngineBoundaryRefused "durable storage generation is neither the old nor replacement binding")
      else do
        let replacementProof = productionPristineStorageProof replacement
            identityText = renderVaultStorageIdentity identity
            establishedAbsence =
              mkEstablishedStateAbsence
                oldBinding
                ( digestSerialised
                    ( "bootstrap-reset-established-absence-v1" :: Text
                    , ambiguity
                    , identityText
                    , Vault.sealStatusInitialized status
                    , Vault.sealStatusSealed status
                    )
                )
            responseAbsence =
              mkDurableInitResponseAbsence
                oldBinding
                ( digestSerialised
                    ( "bootstrap-reset-response-absence-v1" :: Text
                    , ambiguity
                    , identityText
                    )
                )
            baselineAbsence =
              mkBaselineStateAbsence
                oldBinding
                ( digestSerialised
                    ( "bootstrap-reset-baseline-absence-v1" :: Text
                    , ambiguity
                    , identityText
                    )
                )
        proof <-
          mapLeft
            (EngineBoundaryRefused . Text.pack . show)
            ( mkPristineResetProof
                ambiguity
                replacementProof
                establishedAbsence
                responseAbsence
                baselineAbsence
            )
        Right (ambiguity, proof)

resetReplacementBinding
  :: BrokerActionRequest
  -> InitAmbiguity
  -> VaultStorageIdentity
  -> Either EngineBoundaryError RootInitBinding
resetReplacementBinding action ambiguity identity = do
  let replacementDigest =
        digestSerialised
          ( "bootstrap-vault-storage-reset-v1" :: Text
          , ambiguity
          , brokerActionDigest action
          , renderVaultStorageIdentity identity
          )
      suffix = renderArtifactDigest replacementDigest
  transaction <-
    mapLeft
      (EngineBoundaryRefused . Text.pack . show)
      (mkBootstrapTransactionId ("reset-" <> suffix))
  generation <-
    mapLeft
      (EngineBoundaryRefused . Text.pack . show)
      (mkVaultStorageGeneration ("vault-reset-" <> suffix))
  Right
    RootInitBinding
      { rootInitTransactionId = transaction
      , rootInitStorageGeneration = generation
      }

requireAmbiguousPreparedEnvelope
  :: InitAmbiguity
  -> StoreReadBack PreparedInitEnvelope
  -> Either EngineBoundaryError ()
requireAmbiguousPreparedEnvelope ambiguity observed = case observed of
  StoreObjectAbsent ->
    Left (EngineBoundaryRefused "ambiguous prepared envelope is absent")
  StoreObjectPresent _ _ prepared
    | preparedInitEnvelopeDigest prepared
        == ambiguousPreparedEnvelopeDigest ambiguity ->
        Right ()
    | otherwise ->
        Left (EngineBoundaryRefused "ambiguous prepared-envelope digest does not match")

requireResetObjectAbsent
  :: Text
  -> Either StoreBoundaryError (StoreReadBack value)
  -> Either EngineBoundaryError ()
requireResetObjectAbsent label observed = case observed of
  Left failure -> Left (storeBoundaryError failure)
  Right StoreObjectAbsent -> Right ()
  Right StoreObjectPresent {} ->
    Left (EngineBoundaryRefused (label <> " is present"))

recoveryEvidence
  :: BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError RecoveryCustodyReceipt)
recoveryEvidence store action = do
  generation <- observeVaultStorageGeneration store
  case generation of
    Left failure -> pure (Left (storeBoundaryError failure))
    Right binding
      | rootInitStorageGeneration binding /= brokerActionStorageGeneration action ->
          boundaryRefused "request storage generation does not match the durable generation"
      | otherwise -> do
          journal <- readRootInitJournal store binding
          pure $ case journal of
            Right (StoreObjectPresent _ _ state) -> case rootInitStatePhase state of
              RootRecoveryCustodyDurable _ receipt -> Right receipt
              _ -> Left (EngineBoundaryRefused "recovery custody is not durable")
            Right StoreObjectAbsent -> Left (EngineBoundaryRefused "root initialization journal is absent")
            Left failure -> Left (storeBoundaryError failure)

baselineEvidence
  :: BootstrapStoreBoundary IO
  -> BrokerActionRequest
  -> IO (Either EngineBoundaryError (RecoveryCustodyReceipt, RootSessionId))
baselineEvidence store action = do
  custodyResult <- recoveryEvidence store action
  case custodyResult of
    Left failure -> pure (Left failure)
    Right custody -> do
      let generation = brokerActionStorageGeneration action
      observed <- readRootSessionJournal store generation
      case observed of
        Left failure -> pure (Left (storeBoundaryError failure))
        Right StoreObjectAbsent -> fmap (fmap (custody,)) freshRootSessionId
        Right (StoreObjectPresent _ _ state) ->
          case planBaselineSessionIdentity state of
            ReuseRetainedRootSessionId sessionId ->
              pure (Right (custody, sessionId))
            MintFreshRootSessionId -> fmap (fmap (custody,)) freshRootSessionId

data BaselineSessionIdentityPlan
  = ReuseRetainedRootSessionId !RootSessionId
  | MintFreshRootSessionId
  deriving stock (Eq, Show)

planBaselineSessionIdentity :: RootSessionState -> BaselineSessionIdentityPlan
planBaselineSessionIdentity state
  | rootSessionIsComplete state && rootSessionBaselineIsCurrent state = reuse
  | rootSessionIsCancelledClean state = reuse
  | otherwise = MintFreshRootSessionId
 where
  reuse = ReuseRetainedRootSessionId (rootSessionBindingId (rootSessionStateBinding state))

freshRootSessionId :: IO (Either EngineBoundaryError RootSessionId)
freshRootSessionId = do
  bytes <- getRandomBytes 32
  pure
    ( mapLeft
        (EngineBoundaryRefused . Text.pack . show)
        (mkRootSessionId ("root-session-" <> lowerHexBytes bytes))
    )

-- | Sprint 2.47: the closed refusal set, named without its payload.
--
-- 'BootstrapFenceAcquireOverlap' and 'BootstrapFenceAcquireExpiredPredecessor'
-- each carry a 'BootstrapSessionFence', which carries the owner nonce — a
-- 32-byte ownership token. The constructor name distinguishes the five causes
-- without publishing it, which is the same rule Sprint 2.46 applied one level
-- up.
bootstrapFenceAcquireRefusalName :: BootstrapFenceAcquireRefusal -> String
bootstrapFenceAcquireRefusalName refusal = case refusal of
  BootstrapFenceAcquireRequestDeadlineExpired ->
    "BootstrapFenceAcquireRequestDeadlineExpired"
  BootstrapFenceAcquireDeadlineRefused _ -> "BootstrapFenceAcquireDeadlineRefused"
  BootstrapFenceAcquireStoreUnobservable _ -> "BootstrapFenceAcquireStoreUnobservable"
  BootstrapFenceAcquireOverlap _ -> "BootstrapFenceAcquireOverlap"
  BootstrapFenceAcquireExpiredPredecessor _ -> "BootstrapFenceAcquireExpiredPredecessor"

-- | Sprint 2.47: the same closed name-only rule as
-- 'bootstrapFenceAcquireRefusalName', applied to the retirement refusals.
-- Three of the eight carry a 'BootstrapSessionFence' or a Lease witness, both
-- of which carry the owner nonce.
bootstrapFenceRetireRefusalName :: BootstrapFenceRetireRefusal -> String
bootstrapFenceRetireRefusalName refusal = case refusal of
  BootstrapFenceRetireRequestDeadlineExpired ->
    "BootstrapFenceRetireRequestDeadlineExpired"
  BootstrapFenceRetirePredecessorStillLive _ ->
    "BootstrapFenceRetirePredecessorStillLive"
  BootstrapFenceRetireDeadlineUnobservable _ ->
    "BootstrapFenceRetireDeadlineUnobservable"
  BootstrapFenceRetireLeaseStillLive _ -> "BootstrapFenceRetireLeaseStillLive"
  BootstrapFenceRetireLeaseRefused _ -> "BootstrapFenceRetireLeaseRefused"
  BootstrapFenceRetireOwnerStillPresent _ -> "BootstrapFenceRetireOwnerStillPresent"
  BootstrapFenceRetireOwnerMismatch _ _ -> "BootstrapFenceRetireOwnerMismatch"
  BootstrapFenceRetireCleanupUnobservable _ -> "BootstrapFenceRetireCleanupUnobservable"

-- | Sprint 2.48: the same closed name-only rule for the retirement CAS's own
-- confirmation refusals, which the compensating release in 'acquireFence'
-- narrates. All three carry a 'BootstrapFenceStoreObservation', which carries
-- the owner nonce.
bootstrapFenceRetireConfirmationRefusalName
  :: BootstrapFenceRetireConfirmationRefusal -> String
bootstrapFenceRetireConfirmationRefusalName refusal = case refusal of
  BootstrapFenceRetireReadBackMismatch _ _ -> "BootstrapFenceRetireReadBackMismatch"
  BootstrapFenceRetireCasConflictRefusal _ -> "BootstrapFenceRetireCasConflictRefusal"
  BootstrapFenceRetireCasResultUnobservable _ ->
    "BootstrapFenceRetireCasResultUnobservable"

-- | Sprint 2.48: how this invocation came to hold the fence it is establishing
-- a Lease for. It decides one thing only — whether a failed @ensureLease@ may
-- release the fence as its own side effect — and it is an ADT rather than a
-- 'Bool' because that is the question, not the answer.
data FenceAcquisitionOrigin
  = -- | This call CAS'd the fence into existence and nothing has used it.
    FreshlyCasAcquired
  | -- | The durable fence already held exactly this request; an earlier attempt
    -- of the same request may already have confirmed its Lease.
    ResumedExisting
  deriving stock (Eq, Show)

-- | Sprint 2.47: the same closed name-only rule again, for the Lease
-- refusals. Two of the six carry a 'BootstrapLeaseBinding', which carries the
-- owner nonce, so those two publish their constructor and nothing else.
--
-- Sprint 2.48 carries the __reason__ through for the two constructors whose
-- payload is already a fixed, payload-free string, and the distinction is not a
-- relaxation of the rule — it is the rule applied to different payloads. The
-- first live reproduction after 2.47 named
-- 'BootstrapLeaseObservationUnobservable' and stopped there, while that one
-- constructor still covers three unrelated causes: a transport failure, a
-- non-success API status, and a structurally invalid response body. Naming the
-- constructor moved the record from a six-way collapse to a three-way one.
--
-- Publishing the reason is safe because Sprint 2.42 already made it so: these
-- details are built by @unobservableReason@ over
-- @kubernetesTransportFailureLabel@, which maps every @HttpExceptionContent@
-- constructor onto a fixed label with no wildcard arm and never inspects the
-- 'Request' — precisely because it carries an @Authorization: Bearer@ header.
-- 2.42 asserted with a planted token that no bearer material reaches a rendered
-- reason. This consumes that guarantee rather than re-establishing it.
bootstrapLeaseRefusalName :: BootstrapLeaseRefusal -> String
bootstrapLeaseRefusalName refusal = case refusal of
  BootstrapLeaseNotFound -> "BootstrapLeaseNotFound"
  BootstrapLeaseObservationUnobservable detail ->
    "BootstrapLeaseObservationUnobservable: " ++ Text.unpack detail
  BootstrapLeaseBindingMismatch _ _ -> "BootstrapLeaseBindingMismatch"
  BootstrapLeaseExpired -> "BootstrapLeaseExpired"
  BootstrapLeaseResourceVersionEmpty -> "BootstrapLeaseResourceVersionEmpty"
  BootstrapLeaseIdentityRefused detail ->
    "BootstrapLeaseIdentityRefused: " ++ Text.unpack detail

acquireFence
  :: OwnerNonce
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> capability
  -> BrokerRoute
  -> BrokerActionRequest
  -> RequestDigest
  -> Deadline
  -> IO (Either EngineBoundaryError BootstrapSessionFence)
acquireFence owner store kubernetes _ _ action requestDigest requestDeadline = do
  monotonicNow <- realMonotonicNow
  clock <- authorityClockNow
  case (clock, deadlineObservation monotonicNow requestDeadline) of
    (AuthorityTimeTrusted acceptedAt _, DeadlineOpen (RemainingDuration remaining)) -> do
      case authorityDurationFromMicros remaining of
        Left refusal -> boundaryRefused (Text.pack (show refusal))
        Right duration -> do
          let operationDeadline = deriveOperationDeadline acceptedAt duration
              request =
                mkBootstrapFenceAcquireRequest
                  owner
                  (brokerActionDigest action)
                  requestDigest
                  (brokerActionStorageGeneration action)
                  operationDeadline
          observed <- observeBootstrapSessionFence store
          case observed of
            Left failure -> pure (Left (storeBoundaryError failure))
            Right observation ->
              case decideBootstrapFenceAcquire monotonicNow requestDeadline clock request observation of
                -- Sprint 2.47: the one refusal that has a supported remedy.
                -- Every other arm still refuses immediately.
                BootstrapFenceAcquireRefused (BootstrapFenceAcquireExpiredPredecessor held) ->
                  retireExpiredPredecessor request held
                BootstrapFenceAcquireRefused refusal -> refuseAcquire refusal
                BootstrapFenceAcquireResume fence -> ensureLease ResumedExisting fence
                BootstrapFenceAcquireCas plan -> applyAcquireCas plan
    _ -> boundaryRefused "request deadline is expired or authority clock is unavailable"
 where
  refuseAcquire refusal = do
    -- Sprint 2.46/2.47: name which of the five fence refusals fired.
    -- Constructor only: two of them carry a BootstrapSessionFence, which
    -- carries the owner nonce.
    writeDiagnosticLine
      ( "bootstrap-broker fence acquire refused: "
          ++ bootstrapFenceAcquireRefusalName refusal
      )
    boundaryRefused (Text.pack (show refusal))

  applyAcquireCas plan = do
    applied <- casBootstrapSessionFence store plan
    case applied of
      Left failure -> pure (Left (storeBoundaryError failure))
      Right result -> case confirmBootstrapFenceCas plan result of
        Left refusal -> boundaryRefused (Text.pack (show refusal))
        Right fence -> ensureLease FreshlyCasAcquired fence

  -- Sprint 2.47: retire a positively-expired predecessor through the existing
  -- CAS, then re-acquire exactly once.
  --
  -- Before this, @decideBootstrapFenceRetire@ had zero production callers while
  -- its store half was fully wired, so a predecessor abandoned by a failed
  -- bring-up refused every subsequent acquisition forever — and @cluster delete
  -- --cascade@ preserves the object by design, because the same @.data/@ tree
  -- holds per-run Pulumi state. The host could never complete @vault init@
  -- again without hand-clearing a durable object.
  --
  -- __The retirement is what makes takeover safe, not merely what follows it.__
  -- Absence of the predecessor's worker Pod does not prove absence of a Vault
  -- session it may still hold — and no shape short of widening the durable
  -- fence could prove that, because the predecessor's session id and accessor
  -- are not recoverable from the record that survives it. They do not need to
  -- be: every Vault effect and every durable mutation re-reads this exact fence
  -- through 'authorizeBootstrapVaultEffect' /
  -- 'authorizeBootstrapStoreMutation' immediately before acting. Retiring the
  -- fence is therefore the positive revocation, and any surviving predecessor
  -- fails closed at its next effect with @BootstrapFenceUseFenceLost@ or
  -- @BootstrapFenceUseFenceStale@.
  retireExpiredPredecessor request held = do
    leaseObservation <- kubernetesObserveBootstrapLease kubernetes requestDeadline
    workerObservation <-
      kubernetesReconcileFenceOwnerWorker
        kubernetes
        requestDeadline
        (bootstrapFenceGeneration held)
    -- Sprint 2.49: sample the clock AFTER the observations, and the ordering is
    -- load-bearing rather than stylistic.
    --
    -- `bootstrapLeaseFromResponse` encodes an already-expired Lease as
    -- `deadlineFromInstant monotonicBeforeWall` — a deadline at the instant the
    -- observation was taken — and `deadlineExpired now limit` is `now >= limit`.
    -- Sampling before the observation therefore guarantees
    -- `now < monotonicBeforeWall`, so a Lease that expired hours ago reads as
    -- __still live__, `decideBootstrapFenceRetire` refuses
    -- `BootstrapFenceRetireLeaseStillLive`, and the fence can never be retired.
    --
    -- This was latent in Sprint 2.47 and unreachable until Sprint 2.48 made the
    -- Lease creatable at all: before that, every retirement saw
    -- `BootstrapLeaseMissing` and short-circuited. Fixing the Lease is what
    -- exposed it, which is the honest reason the earlier live proof passed and
    -- this arm still failed. More elapsed time is also strictly safer for the
    -- other two uses of this instant — the request deadline and the
    -- predecessor's expiry both only become more certain.
    retireMonotonicNow <- realMonotonicNow
    retireClock <- authorityClockNow
    let cleanupObservation =
          bootstrapFenceOwnerCleanupFromWorkerObservation held workerObservation
    case decideBootstrapFenceRetire
      retireMonotonicNow
      requestDeadline
      retireClock
      held
      leaseObservation
      cleanupObservation of
      Left retireRefusal -> do
        writeDiagnosticLine
          ( "bootstrap-broker expired-fence retirement refused: "
              ++ bootstrapFenceRetireRefusalName retireRefusal
          )
        refuseAcquire (BootstrapFenceAcquireExpiredPredecessor held)
      Right plan -> do
        retired <- casRetireBootstrapSessionFence store plan
        case retired of
          Left failure -> pure (Left (storeBoundaryError failure))
          Right result -> case confirmBootstrapFenceRetireCas plan result of
            Left refusal -> boundaryRefused (Text.pack (show refusal))
            Right vacated -> do
              writeDiagnosticLine
                ( "bootstrap-broker retired expired fence generation "
                    ++ show (bootstrapFenceGenerationValue (bootstrapFenceGeneration held))
                    ++ "; worker-absence receipt "
                    ++ absenceReceiptName cleanupObservation
                )
              reacquireAfterRetirement
                retireMonotonicNow
                retireClock
                request
                vacated

  -- Exactly one second pass, against the confirmed post-retirement read-back
  -- rather than a fresh store read. The bound is structural: this function has
  -- no path back into 'retireExpiredPredecessor', so a predecessor that somehow
  -- survives the CAS refuses instead of looping.
  reacquireAfterRetirement retireMonotonicNow retireClock request vacated =
    case decideBootstrapFenceAcquire
      retireMonotonicNow
      requestDeadline
      retireClock
      request
      vacated of
      BootstrapFenceAcquireRefused refusal -> refuseAcquire refusal
      BootstrapFenceAcquireResume fence -> ensureLease ResumedExisting fence
      BootstrapFenceAcquireCas plan -> applyAcquireCas plan

  -- Sprint 2.48: compensate a fence this call CAS'd but never made usable.
  --
  -- Best-effort and never masking: the original Lease refusal is what the
  -- caller receives whether the release lands or not, because the release is a
  -- cleanup of this call's own side effect and not a second diagnosis. A failed
  -- release is narrated and then falls back to exactly the behaviour that
  -- existed before this arm — the leak, which Sprint 2.47's retirement path
  -- already makes self-healing within one operation deadline.
  releaseFreshlyAcquiredFence fence = do
    released <- casRetireBootstrapSessionFence store (abandonFreshlyAcquiredFence fence)
    let generation =
          show (bootstrapFenceGenerationValue (bootstrapFenceGeneration fence))
    case released of
      Left _ ->
        writeDiagnosticLine
          ( "bootstrap-broker could not release unusable fence generation "
              ++ generation
              ++ "; it expires with its operation deadline"
          )
      Right result -> case confirmBootstrapFenceRetireCas (abandonFreshlyAcquiredFence fence) result of
        Left refusal ->
          writeDiagnosticLine
            ( "bootstrap-broker unusable-fence release refused: "
                ++ bootstrapFenceRetireConfirmationRefusalName refusal
            )
        Right _ ->
          writeDiagnosticLine
            ( "bootstrap-broker released unusable fence generation "
                ++ generation
                ++ " after its Lease could not be confirmed"
            )

  ensureLease origin fence = do
    observed <- kubernetesEnsureBootstrapLease kubernetes requestDeadline fence
    now <- realMonotonicNow
    case confirmBootstrapLease now fence observed of
      Left refusal -> do
        -- Sprint 2.47: this narrated the fixed string "lease not confirmed"
        -- for all six refusals, which is the exact collapse Sprint 2.46 fixed
        -- one level up for the acquire refusals and this function was missed
        -- by. It matters beyond tidiness: the second blocker recorded behind
        -- the stale-fence row is a Lease refusal whose constructor was never
        -- captured, and the ledger holds a paraphrase — "no Lease present" —
        -- where `BootstrapLeaseNotFound` and `BootstrapLeaseObservationUnobservable`
        -- would have named different faults. The next reproduction names it.
        writeDiagnosticLine
          ( "bootstrap-broker fence acquire refused: lease not confirmed: "
              ++ bootstrapLeaseRefusalName refusal
          )
        -- Sprint 2.48: only the freshly CAS'd fence is released. A resumed
        -- fence pre-existed this call and an earlier attempt of the same
        -- request may already have confirmed its Lease and run effects under
        -- it, so releasing it would discard exactly the exclusion those effects
        -- rely on.
        case origin of
          FreshlyCasAcquired -> releaseFreshlyAcquiredFence fence
          ResumedExisting -> pure ()
        pure (Left (EngineBoundaryRefused (Text.pack (show refusal))))
      Right _ -> pure (Right fence)

observeFenceUse
  :: BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError EngineFenceUseObservation)
observeFenceUse store kubernetes _ = do
  now <- realMonotonicNow
  let observationDeadline = deadlineAtOffset now (RemainingDuration (5 * 1000 * 1000))
  clock <- authorityClockNow
  storeObservation <- observeBootstrapSessionFence store
  leaseObservation <- kubernetesObserveBootstrapLease kubernetes observationDeadline
  pure $ do
    observed <- mapLeft storeBoundaryError storeObservation
    Right
      EngineFenceUseObservation
        { engineFenceMonotonicNow = now
        , engineFenceAuthorityClock = clock
        , engineFenceStoreObservation = observed
        , engineFenceLeaseObservation = leaseObservation
        }

releaseFence
  :: BootstrapStoreBoundary IO
  -> BootstrapStoreMutationPermit
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError BootstrapFenceStoreObservation)
releaseFence store permit fence =
  fmap (mapLeft storeBoundaryError) (releaseBootstrapSessionFence store permit fence)

runPhysical
  :: ProductionCapabilityRegistry
  -> BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> KubernetesWorkerBoundary
  -> ProductionBrokerClients
  -> ProvisionerTokenRegistry
  -> BrokerReadinessCache
  -> BrokerPhysicalCall operation result
  -> IO (Either EngineBoundaryError result)
-- The capability registry no longer participates in the request path: since
-- Sprint 2.39 the readiness arm folds the latched record instead of observing
-- the registry inline. The parameter is retained so the caller's argument order
-- is unchanged.
runPhysical _capabilityRegistry settings store kubernetes clients provisionerTokens readinessCache call = case call of
  PhysicalHealth _ -> pure (Right True)
  PhysicalReadiness _ -> Right <$> productionReady readinessCache
  PhysicalObserveVaultStatus _ -> observeBootstrapStatus settings store
  PhysicalSealVault _ permit -> sealVaultPhysical settings permit
  PhysicalCancelIncompleteGenerateRoot {} ->
    mapVaultUnit "generated-root cancellation" (Vault.vaultCancelGenerateRoot address)
  PhysicalInventoryRootAccessors _ _ generation ->
    inventoryRootAccessors settings generation
  PhysicalRevokeRootAccessor _ _ accessor ->
    revokeRootAccessor settings accessor
  PhysicalProveRootAccessorsAbsent _ _ requirement inventory ->
    proveRootAccessorsAbsent settings requirement inventory
  PhysicalStartGenerateRoot _ _ _ publicKey ->
    startGeneratedRoot settings (generatedRootPublicKeyBase64 publicKey)
  PhysicalCleanupProvisionerSessions _ _ generation ->
    cleanupProvisionerSessions settings provisionerTokens generation
  PhysicalLoginProvisioner _ _ generation ->
    loginProvisioner settings provisionerTokens generation
  PhysicalApplyProvisionerBaseline _ _ receipt ->
    applyProvisionerBaseline settings provisionerTokens receipt
  PhysicalReadBackProvisionerBaseline _ _ receipt expected ->
    readBackProvisionerBaseline settings provisionerTokens receipt expected
  PhysicalRevokeProvisionerSession _ _ receipt ->
    revokeProvisionerSession settings provisionerTokens receipt
  PhysicalProveProvisionerSessionAbsent _ _ receipt ->
    proveProvisionerSessionAbsent settings receipt
  PhysicalObservePostUnsealConsumer _ binding consumer ->
    observePostUnsealConsumer clients binding consumer
  PhysicalResetAmbiguousInitialization _ permit ambiguity proof ->
    resetAmbiguousPhysical settings kubernetes permit ambiguity proof
  PhysicalObserveVaultPkiStatus _ -> observeVaultPkiStatus settings
  PhysicalIssueVaultPkiTestCertificate _ permit issue ->
    issueVaultPkiTestCertificate settings permit issue
  PhysicalObserveChildRecoveryConsumption _ _ delivery ->
    fmap
      (mapLeft custodyClientBoundaryError)
      ( BootstrapCustody.observeChildRecoveryConsumption
          (productionCustodyClient clients)
          delivery
      )
  PhysicalConsumeChildRecovery _ _ delivery ->
    fmap
      (mapLeft custodyClientBoundaryError)
      ( BootstrapCustody.commitChildRecoveryConsumption
          (productionCustodyClient clients)
          delivery
      )
  PhysicalCancelChildIncompleteGenerateRoot {} ->
    mapVaultUnit "child generated-root cancellation" (Vault.vaultCancelGenerateRoot address)
  PhysicalInventoryChildRootAccessors _ _ binding ->
    inventoryRootAccessors settings (childCustodyStorageGeneration binding)
  PhysicalRevokeChildRootAccessor _ _ accessor ->
    revokeRootAccessor settings accessor
  PhysicalProveChildRootAccessorsAbsent _ _ requirement inventory ->
    proveRootAccessorsAbsent settings requirement inventory
  PhysicalStartChildGenerateRoot _ _ _ publicKey ->
    startGeneratedRoot settings (generatedChildRecoveryPublicKeyBase64 publicKey)
  -- These constructors are executable only through the attested one-shot
  -- worker boundary.  Keeping every arm explicit makes a newly-added physical
  -- capability fail compilation instead of falling into a production stub.
  PhysicalPrepareRootInitRecipients {} -> secretWorkerBypassRefused
  PhysicalResumeRootInitRecipients {} -> secretWorkerBypassRefused
  PhysicalInitializeVault {} -> secretWorkerBypassRefused
  PhysicalSealFinalUnlockBundle {} -> secretWorkerBypassRefused
  PhysicalUnsealVault {} -> secretWorkerBypassRefused
  PhysicalRotateUnlockBundle {} -> secretWorkerBypassRefused
  PhysicalRotateTransitKey {} -> secretWorkerBypassRefused
  PhysicalAwaitGeneratedRootCiphertext {} -> secretWorkerBypassRefused
  PhysicalAwaitChildGeneratedRootCiphertext {} -> secretWorkerBypassRefused
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  secretWorkerBypassRefused =
    boundaryRefused "secret-bearing physical operation bypassed its attested one-shot worker"

resetAmbiguousPhysical
  :: BootstrapBrokerSettings
  -> KubernetesWorkerBoundary
  -> BootstrapVaultEffectPermit
  -> InitAmbiguity
  -> PristineResetProof
  -> IO (Either EngineBoundaryError PristineResetProof)
resetAmbiguousPhysical settings kubernetes permit ambiguity proof
  | resetAmbiguity proof /= ambiguity =
      boundaryRefused "pristine-reset proof does not match the ambiguous initialization"
  | otherwise = do
      resetResult <-
        kubernetesResetVaultStorage
          kubernetes
          (vaultEffectPermitDeadline permit)
          proof
      case resetResult of
        Left failure ->
          boundaryUnavailable
            ( "vault-reset:"
                <> renderVaultStorageResetFailure failure
            )
        Right _ -> do
          observed <-
            awaitPristineVault
              (Vault.VaultAddress (brokerVaultAddress settings))
              (vaultEffectPermitDeadline permit)
          pure (proof <$ observed)

awaitPristineVault
  :: Vault.VaultAddress
  -> Deadline
  -> IO (Either EngineBoundaryError ())
awaitPristineVault address deadline = do
  now <- realMonotonicNow
  if deadlineExpired now deadline
    then boundaryRefused "Vault did not become pristine before the operation deadline"
    else do
      observed <- Vault.vaultSealStatus address
      case observed of
        Right status
          | not (Vault.sealStatusInitialized status)
              && Vault.sealStatusSealed status ->
              pure (Right ())
        _ -> do
          threadDelay 100000
          awaitPristineVault address deadline

sealVaultPhysical
  :: BootstrapBrokerSettings
  -> BootstrapVaultEffectPermit
  -> IO (Either EngineBoundaryError BootstrapMutationReceipt)
sealVaultPhysical settings permit = do
  loggedIn <- loginVaultBatchRole settings bootstrapSealRole
  result <- case loggedIn of
    Left failure -> pure (Left failure)
    Right login -> do
      sealed <- Vault.vaultSeal address (Vault.vaultLoginToken login)
      pure $ case sealed of
        Left _ -> Left (EngineBoundaryUnavailable "Vault seal failed")
        Right () -> Right ()
  pure $ case result of
    Left failure -> Left failure
    Right () ->
      Right
        BootstrapMutationReceipt
          { bootstrapMutationDigest = vaultEffectPermitActionDigest permit
          , bootstrapMutationChanged = True
          }
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

startGeneratedRoot
  :: BootstrapBrokerSettings -> Text -> IO (Either EngineBoundaryError ())
startGeneratedRoot settings publicKey = do
  started <- Vault.vaultStartGenerateRoot address publicKey
  pure $ case started of
    Right response
      | Vault.generateRootStarted response
          && not (Vault.generateRootComplete response)
          && Vault.generateRootProgress response == 0
          && maybe False (not . Text.null) (Vault.generateRootNonce response) ->
          Right ()
    _ -> Left (EngineBoundaryRefused "Vault generated-root start read-back was not exact")
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

inventoryRootAccessors
  :: BootstrapBrokerSettings
  -> VaultStorageGeneration
  -> IO (Either EngineBoundaryError RootAccessorInventory)
inventoryRootAccessors settings generation = do
  loggedIn <- loginRootAccessorAuditor settings
  case loggedIn of
    Left failure ->
      pure
        ( Left
            ( EngineBoundaryRootAccessorInventory
                (rootAccessorInventoryAuditorCause failure)
            )
        )
    Right login -> do
      let token = Vault.vaultLoginToken login
      listing <- Vault.vaultListTokenAccessors address token
      case classifyRootAccessorInventoryListing listing of
        Left failure -> pure (Left (EngineBoundaryRootAccessorInventory failure))
        Right rawAccessors -> do
          classified <-
            traverse
              (classifyRootAccessor address token)
              rawAccessors
          pure $ do
            accessors <- sequence classified
            mapLeft
              (EngineBoundaryRootAccessorInventory . classifyRootAccessorInventoryFailure)
              (mkRootAccessorInventory generation [accessor | Just accessor <- accessors])
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

classifyRootAccessor
  :: Vault.VaultAddress
  -> Vault.VaultToken
  -> Text
  -> IO (Either EngineBoundaryError (Maybe RootPolicyAccessor))
classifyRootAccessor address token rawAccessor = do
  observed <- Vault.vaultLookupTokenAccessorPolicies address token rawAccessor
  pure $ case observed of
    Left failure ->
      Left
        ( EngineBoundaryRootAccessorInventory
            ( RootAccessorInventoryHttpFailure
                RootAccessorInventoryLookupAccessorPolicies
                (classifyRootAccessorInventoryHttpFailure failure)
            )
        )
    Right policies
      | "root" `elem` policies ->
          Just
            <$> mapLeft
              ( const
                  ( EngineBoundaryRootAccessorInventory
                      RootAccessorInventoryObservedAccessorInvalid
                  )
              )
              (mkRootPolicyAccessor rawAccessor)
      | otherwise -> Right Nothing

revokeRootAccessor
  :: BootstrapBrokerSettings
  -> RootPolicyAccessor
  -> IO (Either EngineBoundaryError ())
revokeRootAccessor settings accessor = do
  loggedIn <- loginRootAccessorAuditor settings
  case loggedIn of
    Left failure ->
      pure
        ( Left
            ( EngineBoundaryRootAccessorRevocation
                (rootAccessorRevocationAuditorCause failure)
            )
        )
    Right login -> do
      let token = Vault.vaultLoginToken login
          rawAccessor = renderRootPolicyAccessor accessor
      revoked <- Vault.vaultRevokeTokenAccessor address token rawAccessor
      case revoked of
        Left failure ->
          pure
            ( Left
                ( EngineBoundaryRootAccessorRevocation
                    ( RootAccessorRevocationHttpFailure
                        RootAccessorRevocationRequest
                        (classifyRootAccessorRevocationHttpFailure failure)
                    )
                )
            )
        Right () -> do
          listed <- Vault.vaultListTokenAccessors address token
          pure $ case classifyRootAccessorRevocationListing listed of
            Left failure ->
              Left
                ( EngineBoundaryRootAccessorRevocation
                    failure
                )
            Right accessors
              | rawAccessor `notElem` accessors -> Right ()
              | otherwise ->
                  Left
                    ( EngineBoundaryRootAccessorRevocation
                        RootAccessorRevocationTargetStillPresent
                    )
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

proveRootAccessorsAbsent
  :: BootstrapBrokerSettings
  -> RootAccessorAbsenceProofRequirement
  -> RootAccessorInventory
  -> IO (Either EngineBoundaryError AccessorAbsenceAttestation)
proveRootAccessorsAbsent settings requirement inventory = do
  observed <-
    inventoryRootAccessorsForAbsenceProof
      settings
      (rootAccessorInventoryGeneration inventory)
  pure $ do
    current <- mapLeft EngineBoundaryRootAccessorAbsenceProof observed
    mapLeft
      EngineBoundaryRootAccessorAbsenceProof
      (decideRootAccessorAbsenceProof requirement inventory current)
    Right
      ( mkAccessorAbsenceAttestation
          inventory
          (digestSerialised (inventory, current))
      )

inventoryRootAccessorsForAbsenceProof
  :: BootstrapBrokerSettings
  -> VaultStorageGeneration
  -> IO (Either RootAccessorAbsenceProofCause RootAccessorInventory)
inventoryRootAccessorsForAbsenceProof settings generation = do
  loggedIn <- loginRootAccessorAuditor settings
  case loggedIn of
    Left failure -> pure (Left (rootAccessorAbsenceAuditorCause failure))
    Right login -> do
      let token = Vault.vaultLoginToken login
      listing <- Vault.vaultListTokenAccessors address token
      case classifyRootAccessorAbsenceListing listing of
        Left failure -> pure (Left failure)
        Right rawAccessors -> do
          classified <-
            traverse
              (classifyRootAccessorForAbsenceProof address token)
              rawAccessors
          pure $ do
            accessors <- sequence classified
            mapLeft
              classifyRootAccessorAbsenceInventoryFailure
              (mkRootAccessorInventory generation [accessor | Just accessor <- accessors])
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

data RootAccessorAuditorFailure
  = RootAccessorAuditorProjectedTokenUnavailable
  | RootAccessorAuditorLoginHttpFailure !RootAccessorAbsenceProofHttpFailure
  | RootAccessorAuditorLoginInvalid
  | RootAccessorAuditorCleanupUnavailable
  | RootAccessorAuditorCleanupRefused
  | RootAccessorAuditorCleanupAmbiguous

loginRootAccessorAuditor
  :: BootstrapBrokerSettings
  -> IO
       ( Either
           RootAccessorAuditorFailure
           Vault.VaultKubernetesLoginResult
       )
loginRootAccessorAuditor settings = do
  projected <- readProjectedServiceAccountToken
  case projected of
    Left _ -> pure (Left RootAccessorAuditorProjectedTokenUnavailable)
    Right jwt -> do
      loggedIn <-
        Vault.vaultKubernetesLoginWithLease
          address
          "kubernetes"
          tokenAccessorAuditorRole
          jwt
      case loggedIn of
        Left failure ->
          pure
            ( Left
                ( RootAccessorAuditorLoginHttpFailure
                    (classifyRootAccessorAbsenceHttpFailure failure)
                )
            )
        Right login
          | isBoundedBatchAuditorLogin 300 login -> pure (Right login)
          | otherwise -> do
              cleaned <-
                cleanupInvalidSuccessfulVaultLogin
                  settings
                  jwt
                  tokenAccessorAuditorRole
                  login
              pure $ case cleaned of
                Left failure -> Left (classifyRootAccessorAuditorCleanup failure)
                Right () -> Left RootAccessorAuditorLoginInvalid
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

classifyRootAccessorForAbsenceProof
  :: Vault.VaultAddress
  -> Vault.VaultToken
  -> Text
  -> IO (Either RootAccessorAbsenceProofCause (Maybe RootPolicyAccessor))
classifyRootAccessorForAbsenceProof address token rawAccessor = do
  observed <- Vault.vaultLookupTokenAccessorPolicies address token rawAccessor
  pure $ case observed of
    Left failure ->
      Left
        ( RootAccessorAbsenceHttpFailure
            RootAccessorAbsenceLookupAccessorPolicies
            (classifyRootAccessorAbsenceHttpFailure failure)
        )
    Right policies
      | "root" `elem` policies ->
          Just
            <$> mapLeft
              (const RootAccessorAbsenceObservedAccessorInvalid)
              (mkRootPolicyAccessor rawAccessor)
      | otherwise -> Right Nothing

classifyRootAccessorAbsenceInventoryFailure
  :: BootstrapValueError -> RootAccessorAbsenceProofCause
classifyRootAccessorAbsenceInventoryFailure failure = case failure of
  BootstrapAccessorInventoryTooLarge {} ->
    RootAccessorAbsenceObservedInventoryTooLarge
  BootstrapAccessorInventoryDuplicate {} ->
    RootAccessorAbsenceObservedInventoryDuplicate
  _ -> RootAccessorAbsenceObservedAccessorInvalid

classifyRootAccessorInventoryFailure
  :: BootstrapValueError -> RootAccessorInventoryCause
classifyRootAccessorInventoryFailure failure = case failure of
  BootstrapAccessorInventoryTooLarge {} ->
    RootAccessorInventoryObservedInventoryTooLarge
  BootstrapAccessorInventoryDuplicate {} ->
    RootAccessorInventoryObservedInventoryDuplicate
  _ -> RootAccessorInventoryObservedAccessorInvalid

classifyRootAccessorAuditorCleanup
  :: EngineBoundaryError -> RootAccessorAuditorFailure
classifyRootAccessorAuditorCleanup failure = case failure of
  EngineBoundaryUnavailable _ -> RootAccessorAuditorCleanupUnavailable
  EngineBoundaryRefused _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryAmbiguous _ -> RootAccessorAuditorCleanupAmbiguous
  EngineBoundaryRootAccessorAbsenceProof _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryRootAccessorRevocation _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryRootAccessorInventory _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryProvisionerAccessorCleanup _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryProvisionerAccessorRevocation _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryProvisionerAccessorAbsence _ -> RootAccessorAuditorCleanupRefused
  EngineBoundaryProvisionerPolicyApplication _ ->
    RootAccessorAuditorCleanupRefused

rootAccessorAbsenceAuditorCause
  :: RootAccessorAuditorFailure -> RootAccessorAbsenceProofCause
rootAccessorAbsenceAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    RootAccessorAbsenceProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    RootAccessorAbsenceHttpFailure RootAccessorAbsenceAuditorLogin httpFailure
  RootAccessorAuditorLoginInvalid -> RootAccessorAbsenceAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable -> RootAccessorAbsenceAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> RootAccessorAbsenceAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous -> RootAccessorAbsenceAuditorCleanupAmbiguous

rootAccessorRevocationAuditorCause
  :: RootAccessorAuditorFailure -> RootAccessorRevocationCause
rootAccessorRevocationAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    RootAccessorRevocationProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    RootAccessorRevocationHttpFailure
      RootAccessorRevocationAuditorLogin
      (rootAccessorRevocationHttpFailure httpFailure)
  RootAccessorAuditorLoginInvalid -> RootAccessorRevocationAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable -> RootAccessorRevocationAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> RootAccessorRevocationAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous -> RootAccessorRevocationAuditorCleanupAmbiguous

rootAccessorInventoryAuditorCause
  :: RootAccessorAuditorFailure -> RootAccessorInventoryCause
rootAccessorInventoryAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    RootAccessorInventoryProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    RootAccessorInventoryHttpFailure
      RootAccessorInventoryAuditorLogin
      (rootAccessorInventoryHttpFailure httpFailure)
  RootAccessorAuditorLoginInvalid -> RootAccessorInventoryAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable -> RootAccessorInventoryAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> RootAccessorInventoryAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous -> RootAccessorInventoryAuditorCleanupAmbiguous

rootAccessorRevocationHttpFailure
  :: RootAccessorAbsenceProofHttpFailure -> RootAccessorRevocationHttpFailure
rootAccessorRevocationHttpFailure failure = case failure of
  RootAccessorAbsenceHttpConnectionFailure -> RootAccessorRevocationHttpConnectionFailure
  RootAccessorAbsenceHttpTimeout -> RootAccessorRevocationHttpTimeout
  RootAccessorAbsenceHttpStatus status -> RootAccessorRevocationHttpStatus status
  RootAccessorAbsenceHttpDecode -> RootAccessorRevocationHttpDecode

rootAccessorInventoryHttpFailure
  :: RootAccessorAbsenceProofHttpFailure -> RootAccessorInventoryHttpFailure
rootAccessorInventoryHttpFailure failure = case failure of
  RootAccessorAbsenceHttpConnectionFailure -> RootAccessorInventoryHttpConnectionFailure
  RootAccessorAbsenceHttpTimeout -> RootAccessorInventoryHttpTimeout
  RootAccessorAbsenceHttpStatus status -> RootAccessorInventoryHttpStatus status
  RootAccessorAbsenceHttpDecode -> RootAccessorInventoryHttpDecode

classifyRootAccessorAbsenceHttpFailure
  :: HttpError -> RootAccessorAbsenceProofHttpFailure
classifyRootAccessorAbsenceHttpFailure failure = case failure of
  HttpConnectionFailure _ -> RootAccessorAbsenceHttpConnectionFailure
  HttpTimeout _ -> RootAccessorAbsenceHttpTimeout
  HttpStatus status _ -> RootAccessorAbsenceHttpStatus status
  HttpDecode _ -> RootAccessorAbsenceHttpDecode

-- | Vault returns 404 for LIST auth/token/accessors when the collection is
-- empty.  Only that exact response establishes an empty inventory; every
-- other transport or response failure remains a closed refusal.
classifyRootAccessorAbsenceListing
  :: Either HttpError Vault.TokenAccessorListing
  -> Either RootAccessorAbsenceProofCause [Text]
classifyRootAccessorAbsenceListing listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left (HttpStatus 404 _) -> Right []
  Left failure ->
    Left
      ( RootAccessorAbsenceHttpFailure
          RootAccessorAbsenceListAccessors
          (classifyRootAccessorAbsenceHttpFailure failure)
      )

classifyRootAccessorRevocationHttpFailure
  :: HttpError -> RootAccessorRevocationHttpFailure
classifyRootAccessorRevocationHttpFailure failure = case failure of
  HttpConnectionFailure _ -> RootAccessorRevocationHttpConnectionFailure
  HttpTimeout _ -> RootAccessorRevocationHttpTimeout
  HttpStatus status _ -> RootAccessorRevocationHttpStatus status
  HttpDecode _ -> RootAccessorRevocationHttpDecode

-- | Vault answers an empty token-accessor collection with LIST HTTP 404. This
-- interpretation belongs only to the authoritative post-revocation read-back;
-- every other failure remains a closed revocation cause.
classifyRootAccessorRevocationListing
  :: Either HttpError Vault.TokenAccessorListing
  -> Either RootAccessorRevocationCause [Text]
classifyRootAccessorRevocationListing listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left (HttpStatus 404 _) -> Right []
  Left failure ->
    Left
      ( RootAccessorRevocationHttpFailure
          RootAccessorRevocationListReadBack
          (classifyRootAccessorRevocationHttpFailure failure)
      )

classifyRootAccessorInventoryHttpFailure
  :: HttpError -> RootAccessorInventoryHttpFailure
classifyRootAccessorInventoryHttpFailure failure = case failure of
  HttpConnectionFailure _ -> RootAccessorInventoryHttpConnectionFailure
  HttpTimeout _ -> RootAccessorInventoryHttpTimeout
  HttpStatus status _ -> RootAccessorInventoryHttpStatus status
  HttpDecode _ -> RootAccessorInventoryHttpDecode

-- | Vault returns 404 for LIST auth/token/accessors when the collection is
-- empty. Only that exact response establishes an empty inventory; every other
-- transport or response failure remains a closed refusal.
classifyRootAccessorInventoryListing
  :: Either HttpError Vault.TokenAccessorListing
  -> Either RootAccessorInventoryCause [Text]
classifyRootAccessorInventoryListing listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left (HttpStatus 404 _) -> Right []
  Left failure ->
    Left
      ( RootAccessorInventoryHttpFailure
          RootAccessorInventoryListAccessors
          (classifyRootAccessorInventoryHttpFailure failure)
      )

classifyProvisionerAccessorCleanupHttpFailure
  :: HttpError -> ProvisionerAccessorCleanupHttpFailure
classifyProvisionerAccessorCleanupHttpFailure failure = case failure of
  HttpConnectionFailure _ -> ProvisionerAccessorCleanupHttpConnectionFailure
  HttpTimeout _ -> ProvisionerAccessorCleanupHttpTimeout
  HttpStatus status _ -> ProvisionerAccessorCleanupHttpStatus status
  HttpDecode _ -> ProvisionerAccessorCleanupHttpDecode

-- | Vault returns 404 for LIST auth/token/accessors when the collection is
-- empty. Only that exact response establishes an empty cleanup inventory;
-- every other transport or response failure remains a closed refusal.
classifyProvisionerAccessorCleanupListing
  :: ProvisionerAccessorCleanupHttpOperation
  -> Either HttpError Vault.TokenAccessorListing
  -> Either ProvisionerAccessorCleanupCause [Text]
classifyProvisionerAccessorCleanupListing operation listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left (HttpStatus 404 _) -> Right []
  Left failure -> Left (provisionerAccessorCleanupHttpCause operation failure)

classifyProvisionerAccessorRevocationHttpFailure
  :: HttpError -> ProvisionerAccessorRevocationHttpFailure
classifyProvisionerAccessorRevocationHttpFailure failure = case failure of
  HttpConnectionFailure _ -> ProvisionerAccessorRevocationHttpConnectionFailure
  HttpTimeout _ -> ProvisionerAccessorRevocationHttpTimeout
  HttpStatus status _ -> ProvisionerAccessorRevocationHttpStatus status
  HttpDecode _ -> ProvisionerAccessorRevocationHttpDecode

-- | Vault returns 404 when either token-accessor LIST observes an empty
-- collection. Sprints 2.75 and 2.81 licensed those exact operation/status
-- pairs independently; non-list operations and every other failure refuse.
classifyProvisionerAccessorRevocationListing
  :: ProvisionerAccessorRevocationHttpOperation
  -> Either HttpError Vault.TokenAccessorListing
  -> Either ProvisionerAccessorRevocationCause [Text]
classifyProvisionerAccessorRevocationListing operation listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left failure@(HttpStatus 404 _) -> case operation of
    ProvisionerAccessorRevocationInitialListAccessors -> Right []
    ProvisionerAccessorRevocationPostListAccessors -> Right []
    ProvisionerAccessorRevocationAuditorLogin -> refused failure
    ProvisionerAccessorRevocationTargetLookupAccessor -> refused failure
    ProvisionerAccessorRevocationRevokeAccessor -> refused failure
    ProvisionerAccessorRevocationPostLookupAccessor -> refused failure
  Left failure -> Left (provisionerAccessorRevocationHttpCause operation failure)
 where
  refused = Left . provisionerAccessorRevocationHttpCause operation

provisionerAccessorRevocationHttpCause
  :: ProvisionerAccessorRevocationHttpOperation
  -> HttpError
  -> ProvisionerAccessorRevocationCause
provisionerAccessorRevocationHttpCause operation failure =
  ProvisionerAccessorRevocationHttpFailure
    operation
    (classifyProvisionerAccessorRevocationHttpFailure failure)

provisionerAccessorCleanupHttpCause
  :: ProvisionerAccessorCleanupHttpOperation
  -> HttpError
  -> ProvisionerAccessorCleanupCause
provisionerAccessorCleanupHttpCause operation failure =
  ProvisionerAccessorCleanupHttpFailure
    operation
    (classifyProvisionerAccessorCleanupHttpFailure failure)

classifyProvisionerAccessorCleanupAuditFailure
  :: VaultAccessorAuditDetailedError ProvisionerAccessorCleanupCause
  -> ProvisionerAccessorCleanupCause
classifyProvisionerAccessorCleanupAuditFailure failure = case failure of
  VaultAccessorAuditDetailedIdentityInvalid ->
    ProvisionerAccessorCleanupAuditIdentityInvalid
  VaultAccessorAuditDetailedObservationFailed cause -> cause
  VaultAccessorAuditDetailedClassificationFailed cause -> cause
  VaultAccessorAuditDetailedVisibilityWaitFailed cause -> cause
  VaultAccessorAuditDetailedStableAbsenceFailed ->
    ProvisionerAccessorCleanupStableAbsenceFailed

classifyProvisionerAccessorCleanupVisibility
  :: EngineBoundaryError -> ProvisionerAccessorCleanupCause
classifyProvisionerAccessorCleanupVisibility failure = case failure of
  EngineBoundaryUnavailable _ -> ProvisionerAccessorCleanupVisibilityUnavailable
  EngineBoundaryRefused _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryAmbiguous _ -> ProvisionerAccessorCleanupVisibilityAmbiguous
  EngineBoundaryRootAccessorAbsenceProof _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryRootAccessorRevocation _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryRootAccessorInventory _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryProvisionerAccessorCleanup _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryProvisionerAccessorRevocation _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryProvisionerAccessorAbsence _ -> ProvisionerAccessorCleanupVisibilityRefused
  EngineBoundaryProvisionerPolicyApplication _ ->
    ProvisionerAccessorCleanupVisibilityRefused

classifyProvisionerAccessorCleanupValueFailure
  :: BootstrapValueError -> ProvisionerAccessorCleanupCause
classifyProvisionerAccessorCleanupValueFailure failure = case failure of
  BootstrapAccessorInventoryTooLarge {} ->
    ProvisionerAccessorCleanupObservedInventoryTooLarge
  BootstrapAccessorInventoryDuplicate {} ->
    ProvisionerAccessorCleanupObservedInventoryDuplicate
  _ -> ProvisionerAccessorCleanupObservedAccessorInvalid

provisionerAccessorCleanupAuditorCause
  :: RootAccessorAuditorFailure -> ProvisionerAccessorCleanupCause
provisionerAccessorCleanupAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    ProvisionerAccessorCleanupProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    ProvisionerAccessorCleanupHttpFailure
      ProvisionerAccessorCleanupAuditorLogin
      (provisionerAccessorCleanupHttpFailure httpFailure)
  RootAccessorAuditorLoginInvalid -> ProvisionerAccessorCleanupAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable -> ProvisionerAccessorCleanupAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> ProvisionerAccessorCleanupAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous -> ProvisionerAccessorCleanupAuditorCleanupAmbiguous

provisionerAccessorRevocationAuditorCause
  :: RootAccessorAuditorFailure -> ProvisionerAccessorRevocationCause
provisionerAccessorRevocationAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    ProvisionerAccessorRevocationProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    ProvisionerAccessorRevocationHttpFailure
      ProvisionerAccessorRevocationAuditorLogin
      (provisionerAccessorRevocationHttpFailure httpFailure)
  RootAccessorAuditorLoginInvalid -> ProvisionerAccessorRevocationAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable ->
    ProvisionerAccessorRevocationAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> ProvisionerAccessorRevocationAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous ->
    ProvisionerAccessorRevocationAuditorCleanupAmbiguous

provisionerAccessorCleanupHttpFailure
  :: RootAccessorAbsenceProofHttpFailure
  -> ProvisionerAccessorCleanupHttpFailure
provisionerAccessorCleanupHttpFailure failure = case failure of
  RootAccessorAbsenceHttpConnectionFailure -> ProvisionerAccessorCleanupHttpConnectionFailure
  RootAccessorAbsenceHttpTimeout -> ProvisionerAccessorCleanupHttpTimeout
  RootAccessorAbsenceHttpStatus status -> ProvisionerAccessorCleanupHttpStatus status
  RootAccessorAbsenceHttpDecode -> ProvisionerAccessorCleanupHttpDecode

provisionerAccessorRevocationHttpFailure
  :: RootAccessorAbsenceProofHttpFailure
  -> ProvisionerAccessorRevocationHttpFailure
provisionerAccessorRevocationHttpFailure failure = case failure of
  RootAccessorAbsenceHttpConnectionFailure ->
    ProvisionerAccessorRevocationHttpConnectionFailure
  RootAccessorAbsenceHttpTimeout -> ProvisionerAccessorRevocationHttpTimeout
  RootAccessorAbsenceHttpStatus status -> ProvisionerAccessorRevocationHttpStatus status
  RootAccessorAbsenceHttpDecode -> ProvisionerAccessorRevocationHttpDecode

classifyProvisionerAccessorAbsenceHttpFailure
  :: HttpError -> ProvisionerAccessorAbsenceHttpFailure
classifyProvisionerAccessorAbsenceHttpFailure failure = case failure of
  HttpConnectionFailure _ -> ProvisionerAccessorAbsenceHttpConnectionFailure
  HttpTimeout _ -> ProvisionerAccessorAbsenceHttpTimeout
  HttpStatus status _ -> ProvisionerAccessorAbsenceHttpStatus status
  HttpDecode _ -> ProvisionerAccessorAbsenceHttpDecode

-- | Vault's final role-wide accessor LIST uses HTTP 404 for the empty
-- collection. Sprint 2.82's deployed diagnostic licensed only this exact
-- operation/status; lookup and every other failure remain refusals.
classifyProvisionerAccessorAbsenceListing
  :: Either HttpError Vault.TokenAccessorListing
  -> Either ProvisionerAccessorAbsenceCause [Text]
classifyProvisionerAccessorAbsenceListing listing = case listing of
  Right observed -> Right (Vault.tokenAccessorKeys observed)
  Left (HttpStatus 404 _) -> Right []
  Left failure ->
    Left
      ( ProvisionerAccessorAbsenceHttpFailure
          ProvisionerAccessorAbsenceListAccessors
          (classifyProvisionerAccessorAbsenceHttpFailure failure)
      )

provisionerAccessorAbsenceHttpFailure
  :: RootAccessorAbsenceProofHttpFailure
  -> ProvisionerAccessorAbsenceHttpFailure
provisionerAccessorAbsenceHttpFailure failure = case failure of
  RootAccessorAbsenceHttpConnectionFailure ->
    ProvisionerAccessorAbsenceHttpConnectionFailure
  RootAccessorAbsenceHttpTimeout -> ProvisionerAccessorAbsenceHttpTimeout
  RootAccessorAbsenceHttpStatus status -> ProvisionerAccessorAbsenceHttpStatus status
  RootAccessorAbsenceHttpDecode -> ProvisionerAccessorAbsenceHttpDecode

provisionerAccessorAbsenceAuditorCause
  :: RootAccessorAuditorFailure -> ProvisionerAccessorAbsenceCause
provisionerAccessorAbsenceAuditorCause failure = case failure of
  RootAccessorAuditorProjectedTokenUnavailable ->
    ProvisionerAccessorAbsenceProjectedTokenUnavailable
  RootAccessorAuditorLoginHttpFailure httpFailure ->
    ProvisionerAccessorAbsenceHttpFailure
      ProvisionerAccessorAbsenceAuditorLogin
      (provisionerAccessorAbsenceHttpFailure httpFailure)
  RootAccessorAuditorLoginInvalid -> ProvisionerAccessorAbsenceAuditorLoginInvalid
  RootAccessorAuditorCleanupUnavailable ->
    ProvisionerAccessorAbsenceAuditorCleanupUnavailable
  RootAccessorAuditorCleanupRefused -> ProvisionerAccessorAbsenceAuditorCleanupRefused
  RootAccessorAuditorCleanupAmbiguous ->
    ProvisionerAccessorAbsenceAuditorCleanupAmbiguous

classifyProvisionerAccessorAbsenceValueFailure
  :: BootstrapValueError -> ProvisionerAccessorAbsenceCause
classifyProvisionerAccessorAbsenceValueFailure failure = case failure of
  BootstrapAccessorInventoryTooLarge {} ->
    ProvisionerAccessorAbsenceObservedInventoryTooLarge
  BootstrapProvisionerAccessorInventoryDuplicate {} ->
    ProvisionerAccessorAbsenceObservedInventoryDuplicate
  _ -> ProvisionerAccessorAbsenceObservedAccessorInvalid

decideRootAccessorAbsenceProof
  :: RootAccessorAbsenceProofRequirement
  -> RootAccessorInventory
  -> RootAccessorInventory
  -> Either RootAccessorAbsenceProofCause ()
decideRootAccessorAbsenceProof requirement expected current
  | rootAccessorInventoryGeneration current
      /= rootAccessorInventoryGeneration expected =
      Left RootAccessorAbsenceGenerationMismatch
  | any (`elem` observed) targets = Left RootAccessorAbsenceTargetPresent
  | requirement == RootAccessorStableZeroRequired
      && not (null observed) =
      Left RootAccessorAbsenceStableZeroMismatch
  | otherwise = Right ()
 where
  targets = rootAccessorInventoryAccessors expected
  observed = rootAccessorInventoryAccessors current

cleanupProvisionerSessions
  :: BootstrapBrokerSettings
  -> ProvisionerTokenRegistry
  -> VaultStorageGeneration
  -> IO (Either EngineBoundaryError ProvisionerAccessorAbsenceAttestation)
cleanupProvisionerSessions settings registry generation = do
  cleaned <- cleanupVaultRoleAccessors settings bootstrapProvisionerRole
  case cleaned of
    Left failure ->
      pure (Left (EngineBoundaryProvisionerAccessorCleanup failure))
    Right rawAccessors ->
      case traverse mkTypedAccessor rawAccessors
        >>= mapLeft
          classifyProvisionerAccessorCleanupValueFailure
          . mkProvisionerAccessorInventory generation of
        Left failure ->
          pure (Left (EngineBoundaryProvisionerAccessorCleanup failure))
        Right inventory -> do
          writeIORef registry Map.empty
          pure
            ( Right
                ( mkProvisionerAccessorAbsenceAttestation
                    inventory
                    (digestSerialised ("provisioner-policy-stable-zero-v1" :: Text, inventory))
                )
            )
 where
  mkTypedAccessor =
    mapLeft
      (const ProvisionerAccessorCleanupObservedAccessorInvalid)
      . mkProvisionerAccessor

-- | Revoke every service token carrying the exact role policy, then perform a
-- fresh policy-wide inventory and require stable zero.  The auditor is a
-- bounded batch token and therefore has no accessor cleanup tail of its own.
cleanupVaultRoleAccessors
  :: BootstrapBrokerSettings
  -> Text
  -> IO (Either ProvisionerAccessorCleanupCause [Text])
cleanupVaultRoleAccessors =
  cleanupVaultRoleAccessorsWithGrace boundedVaultAccessorVisibilityGrace

cleanupVaultRoleAccessorsWithGrace
  :: IO (Either EngineBoundaryError ())
  -> BootstrapBrokerSettings
  -> Text
  -> IO (Either ProvisionerAccessorCleanupCause [Text])
cleanupVaultRoleAccessorsWithGrace waitForVisibility settings role = do
  loggedIn <- loginRootAccessorAuditor settings
  case loggedIn of
    Left failure -> pure (Left (provisionerAccessorCleanupAuditorCause failure))
    Right auditor ->
      auditVaultRoleStableZeroForProvisionerCleanup
        waitForVisibility
        settings
        (Vault.vaultLoginToken auditor)
        role

auditVaultRoleStableZeroForProvisionerCleanup
  :: IO (Either EngineBoundaryError ())
  -> BootstrapBrokerSettings
  -> Vault.VaultToken
  -> Text
  -> IO (Either ProvisionerAccessorCleanupCause [Text])
auditVaultRoleStableZeroForProvisionerCleanup waitForVisibility settings token role = do
  initial <- roleAccessorsForProvisionerCleanup settings token role
  case initial of
    Left failure -> pure (Left failure)
    Right accessors -> do
      audited <-
        revokeAndProveVaultAccessorSubjectAbsentDetailed auditOps subject Nothing
      pure $ case audited of
        Left failure -> Left (classifyProvisionerAccessorCleanupAuditFailure failure)
        Right () -> Right accessors
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  subject = bootstrapBrokerRoleSubject role
  auditOps =
    VaultAccessorAuditDetailedOps
      { detailedAuditListAccessors =
          fmap
            (classifyProvisionerAccessorCleanupListing ProvisionerAccessorCleanupAuditListAccessors)
            (Vault.vaultListTokenAccessors address token)
      , detailedAuditLookupAccessor =
          \accessor ->
            fmap
              (mapLeft (provisionerAccessorCleanupHttpCause ProvisionerAccessorCleanupAuditLookupAccessor))
              (Vault.vaultLookupTokenAccessorInfo address token accessor)
      , detailedAuditRevokeAccessor =
          \accessor ->
            fmap
              (mapLeft (provisionerAccessorCleanupHttpCause ProvisionerAccessorCleanupAuditRevokeAccessor))
              (Vault.vaultRevokeTokenAccessor address token accessor)
      , detailedAuditObserveAccessorAbsent =
          \accessor ->
            fmap
              (mapLeft (provisionerAccessorCleanupHttpCause ProvisionerAccessorCleanupAuditObserveKnownAccessor))
              (Vault.vaultTokenAccessorAbsent address token accessor)
      , detailedAuditWaitVisibilityGrace =
          fmap (mapLeft classifyProvisionerAccessorCleanupVisibility) waitForVisibility
      }

roleAccessorsForProvisionerCleanup
  :: BootstrapBrokerSettings
  -> Vault.VaultToken
  -> Text
  -> IO (Either ProvisionerAccessorCleanupCause [Text])
roleAccessorsForProvisionerCleanup settings token role = do
  listing <- Vault.vaultListTokenAccessors address token
  case classifyProvisionerAccessorCleanupListing
    ProvisionerAccessorCleanupInitialListAccessors
    listing of
    Left failure -> pure (Left failure)
    Right accessors -> do
      classified <- traverse classify accessors
      pure (fmap concat (sequence classified))
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  classify accessor = do
    info <- Vault.vaultLookupTokenAccessorInfo address token accessor
    pure $ case info of
      Left failure ->
        Left
          ( provisionerAccessorCleanupHttpCause
              ProvisionerAccessorCleanupInitialLookupAccessor
              failure
          )
      Right observed
        | vaultAccessorMatchesSubject (bootstrapBrokerRoleSubject role) observed ->
            Right [accessor]
        | otherwise -> Right []

-- | Run the shared finite stable-zero proof with an already validated batch
-- auditor.  A known accessor is an additional mandatory observation; the
-- role-wide subject scan still closes response-loss and missing-accessor
-- login drift.
auditVaultRoleStableZeroWithToken
  :: IO (Either EngineBoundaryError ())
  -> BootstrapBrokerSettings
  -> Vault.VaultToken
  -> Text
  -> Maybe Text
  -> IO (Either EngineBoundaryError [Text])
auditVaultRoleStableZeroWithToken waitForVisibility settings token role knownAccessor = do
  initial <- roleAccessorsWithToken settings token role
  case initial of
    Left failure -> pure (Left failure)
    Right accessors -> do
      audited <-
        revokeAndProveVaultAccessorSubjectAbsent auditOps subject knownAccessor
      pure $ case audited of
        Left refusal ->
          Left
            ( EngineBoundaryRefused
                ("Vault role-session stable-zero audit failed: " <> Text.pack (show refusal))
            )
        Right () -> Right accessors
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  subject = bootstrapBrokerRoleSubject role
  auditOps =
    VaultAccessorAuditOps
      { auditListAccessors =
          fmap
            (mapLeft (Text.pack . show) . fmap Vault.tokenAccessorKeys)
            (Vault.vaultListTokenAccessors address token)
      , auditLookupAccessor =
          \accessor ->
            fmap
              (mapLeft (Text.pack . show))
              (Vault.vaultLookupTokenAccessorInfo address token accessor)
      , auditRevokeAccessor =
          \accessor ->
            fmap
              (mapLeft (Text.pack . show))
              (Vault.vaultRevokeTokenAccessor address token accessor)
      , auditObserveAccessorAbsent =
          \accessor ->
            fmap
              (mapLeft (Text.pack . show))
              (Vault.vaultTokenAccessorAbsent address token accessor)
      , auditWaitVisibilityGrace =
          fmap (mapLeft (Text.pack . show)) waitForVisibility
      }

boundedVaultAccessorVisibilityGrace :: IO (Either EngineBoundaryError ())
boundedVaultAccessorVisibilityGrace = do
  -- Vault's Kubernetes login and token-accessor list are separate server
  -- operations.  Keep the grace short and bounded, but non-zero, so a login
  -- whose HTTP response was lost can become visible before the second proof.
  threadDelay 500000
  pure (Right ())

roleAccessorsWithToken
  :: BootstrapBrokerSettings
  -> Vault.VaultToken
  -> Text
  -> IO (Either EngineBoundaryError [Text])
roleAccessorsWithToken settings token role = do
  listing <- Vault.vaultListTokenAccessors address token
  case listing of
    Left _ -> boundaryUnavailable "Vault token-accessor inventory is unavailable"
    Right observed -> do
      classified <- traverse classify (Vault.tokenAccessorKeys observed)
      pure (fmap concat (sequence classified))
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  classify accessor = do
    info <- Vault.vaultLookupTokenAccessorInfo address token accessor
    pure $ case info of
      Left _ -> Left (EngineBoundaryUnavailable "Vault token-accessor policy lookup is unavailable")
      Right observed
        | vaultAccessorMatchesSubject (bootstrapBrokerRoleSubject role) observed ->
            Right [accessor]
        | otherwise -> Right []

bootstrapBrokerRoleSubject :: Text -> VaultAccessorSubject
bootstrapBrokerRoleSubject role =
  -- A response-lost login has no returned accessor from which to recover a
  -- dynamic identity.  The Kubernetes auth role is statically bound to this
  -- one exact ServiceAccount name/namespace (never a wildcard), and the
  -- durable Broker fence serializes the lane.  Vault exposes these fields plus
  -- the exact role and creation path before an accessor is returned, so they
  -- are the recovery correlation key; no UID guess is made.
  VaultAccessorSubject
    { vaultAccessorSubjectPolicies = ["default", role]
    , vaultAccessorSubjectMetadata =
        Map.fromList
          [ ("role", role)
          , ("service_account_name", "prodbox-bootstrap-broker")
          , ("service_account_namespace", "bootstrap-broker")
          ]
    , vaultAccessorSubjectCreationPath = "auth/kubernetes/login"
    }

revokeProvisionerSession
  :: BootstrapBrokerSettings
  -> ProvisionerTokenRegistry
  -> ProvisionerLoginReceipt
  -> IO (Either EngineBoundaryError ())
revokeProvisionerSession settings registry receipt =
  do
    loggedIn <- loginRootAccessorAuditor settings
    case loggedIn of
      Left failure -> refused (provisionerAccessorRevocationAuditorCause failure)
      Right auditor -> do
        let token = Vault.vaultLoginToken auditor
            accessor = renderProvisionerAccessor (provisionerLoginAccessor receipt)
        listing <- Vault.vaultListTokenAccessors address token
        case classifyProvisionerAccessorRevocationListing
          ProvisionerAccessorRevocationInitialListAccessors
          listing of
          Left failure -> refused failure
          Right initialAccessors -> do
            revoked <-
              if accessor `elem` initialAccessors
                then revokeTarget token accessor
                else pure (Right ())
            case revoked of
              Left failure -> refused failure
              Right () -> do
                absence <- proveTargetAndRoleAbsent token accessor
                case absence of
                  Left failure -> refused failure
                  Right () -> do
                    modifyIORef' registry (Map.delete (provisionerLoginAccessor receipt))
                    pure (Right ())
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  refused = pure . Left . EngineBoundaryProvisionerAccessorRevocation
  revokeTarget token accessor = do
    info <- Vault.vaultLookupTokenAccessorInfo address token accessor
    case info of
      Left failure ->
        pure
          ( Left
              ( provisionerAccessorRevocationHttpCause
                  ProvisionerAccessorRevocationTargetLookupAccessor
                  failure
              )
          )
      Right accessorInfo
        | vaultAccessorMatchesSubject
            (bootstrapBrokerRoleSubject bootstrapProvisionerRole)
            accessorInfo ->
            fmap
              ( mapLeft
                  ( provisionerAccessorRevocationHttpCause
                      ProvisionerAccessorRevocationRevokeAccessor
                  )
              )
              (Vault.vaultRevokeTokenAccessor address token accessor)
        | otherwise -> pure (Left ProvisionerAccessorRevocationTargetIdentityInvalid)
  proveTargetAndRoleAbsent token target = do
    listing <- Vault.vaultListTokenAccessors address token
    case classifyProvisionerAccessorRevocationListing
      ProvisionerAccessorRevocationPostListAccessors
      listing of
      Left failure -> pure (Left failure)
      Right rawAccessors -> do
        classified <- traverse (matchesProvisionerSubject token) rawAccessors
        pure $ do
          matchingRole <- sequence classified
          if target `elem` rawAccessors
            then Left ProvisionerAccessorRevocationTargetStillPresent
            else
              if or matchingRole
                then Left ProvisionerAccessorRevocationRoleAccessorStillPresent
                else Right ()
  matchesProvisionerSubject token accessor = do
    info <- Vault.vaultLookupTokenAccessorInfo address token accessor
    pure $ case info of
      Left failure ->
        Left
          ( provisionerAccessorRevocationHttpCause
              ProvisionerAccessorRevocationPostLookupAccessor
              failure
          )
      Right observed ->
        Right
          ( vaultAccessorMatchesSubject
              (bootstrapBrokerRoleSubject bootstrapProvisionerRole)
              observed
          )

proveProvisionerSessionAbsent
  :: BootstrapBrokerSettings
  -> ProvisionerLoginReceipt
  -> IO (Either EngineBoundaryError ProvisionerAccessorAbsenceAttestation)
proveProvisionerSessionAbsent settings receipt = do
  loggedIn <- loginRootAccessorAuditor settings
  case loggedIn of
    Left failure -> refused (provisionerAccessorAbsenceAuditorCause failure)
    Right auditor -> do
      let token = Vault.vaultLoginToken auditor
          target = provisionerLoginAccessor receipt
      remaining <- provisionerRoleAccessorsForAbsence settings token
      pure $ do
        accessors <- mapLeft EngineBoundaryProvisionerAccessorAbsence remaining
        if null accessors
          && renderProvisionerAccessor target `notElem` accessors
          then do
            inventory <-
              mapLeft
                ( EngineBoundaryProvisionerAccessorAbsence
                    . classifyProvisionerAccessorAbsenceValueFailure
                )
                ( mkProvisionerAccessorInventory
                    (provisionerLoginStorageGeneration receipt)
                    [target]
                )
            Right
              ( mkProvisionerAccessorAbsenceAttestation
                  inventory
                  (digestSerialised ("provisioner-accessor-absence-v1" :: Text, inventory, accessors))
              )
          else
            Left
              ( EngineBoundaryProvisionerAccessorAbsence
                  ProvisionerAccessorAbsenceRoleAccessorStillPresent
              )
 where
  refused = pure . Left . EngineBoundaryProvisionerAccessorAbsence

provisionerRoleAccessorsForAbsence
  :: BootstrapBrokerSettings
  -> Vault.VaultToken
  -> IO (Either ProvisionerAccessorAbsenceCause [Text])
provisionerRoleAccessorsForAbsence settings token = do
  listing <- Vault.vaultListTokenAccessors address token
  case classifyProvisionerAccessorAbsenceListing listing of
    Left failure -> pure (Left failure)
    Right rawAccessors -> do
      classified <- traverse classify rawAccessors
      pure (fmap concat (sequence classified))
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  classify accessor = do
    info <- Vault.vaultLookupTokenAccessorInfo address token accessor
    pure $ case info of
      Left failure ->
        Left
          ( ProvisionerAccessorAbsenceHttpFailure
              ProvisionerAccessorAbsenceLookupAccessor
              (classifyProvisionerAccessorAbsenceHttpFailure failure)
          )
      Right observed
        | vaultAccessorMatchesSubject
            (bootstrapBrokerRoleSubject bootstrapProvisionerRole)
            observed ->
            Right [accessor]
        | otherwise -> Right []

loginProvisioner
  :: BootstrapBrokerSettings
  -> ProvisionerTokenRegistry
  -> VaultStorageGeneration
  -> IO (Either EngineBoundaryError ProvisionerLoginReceipt)
loginProvisioner settings registry generation =
  mask $ \restore -> do
    attempted <- tryEngineAction (restore (loginVaultRole settings bootstrapProvisionerRole))
    case attempted of
      Left exception -> do
        cleaned <- cleanupProvisionerSessions settings registry generation
        case cleaned of
          Left cleanupFailure -> pure (Left cleanupFailure)
          Right _ -> throwIO exception
      Right (Left loginFailure) -> do
        cleaned <- cleanupProvisionerSessions settings registry generation
        pure $ case cleaned of
          Left cleanupFailure -> Left cleanupFailure
          Right _ -> Left loginFailure
      Right (Right login) ->
        case provisionerReceiptFromLogin generation login of
          Left refusal -> do
            cleaned <- cleanupProvisionerSessions settings registry generation
            pure $ case cleaned of
              Left cleanupFailure -> Left cleanupFailure
              Right _ -> Left refusal
          Right receipt -> do
            modifyIORef'
              registry
              (Map.insert (provisionerLoginAccessor receipt) (Vault.vaultLoginToken login))
            pure (Right receipt)

applyProvisionerBaseline
  :: BootstrapBrokerSettings
  -> ProvisionerTokenRegistry
  -> ProvisionerLoginReceipt
  -> IO (Either EngineBoundaryError ())
applyProvisionerBaseline settings registry receipt = do
  tokenResult <- lookupProvisionerPolicyApplicationToken registry receipt
  case tokenResult of
    Left failure ->
      pure (Left (EngineBoundaryProvisionerPolicyApplication failure))
    Right token -> do
      repaired <- repairProvisionerPolicy settings
      case repaired of
        Left failure ->
          pure (Left (EngineBoundaryProvisionerPolicyApplication failure))
        Right () -> do
          reconciled <-
            runVaultReconcile
              (Vault.VaultAddress (brokerVaultAddress settings))
              token
              provisionerVaultReconcilePlan
          case mapLeft classifyProvisionerPolicyCoreReconcileFailure reconciled of
            Left failure ->
              pure (Left (EngineBoundaryProvisionerPolicyApplication failure))
            Right _ -> do
              pki <-
                reconcileVaultPkiBaseline
                  (Vault.VaultAddress (brokerVaultAddress settings))
                  token
              pure $ case mapLeft classifyProvisionerPolicyPkiReconcileFailure pki of
                Left failure ->
                  Left (EngineBoundaryProvisionerPolicyApplication failure)
                Right _ -> Right ()

readBackProvisionerBaseline
  :: BootstrapBrokerSettings
  -> ProvisionerTokenRegistry
  -> ProvisionerLoginReceipt
  -> BaselineReadBackReceipt
  -> IO (Either EngineBoundaryError BaselineReadBackReceipt)
readBackProvisionerBaseline settings registry receipt expected
  | provisionerLoginStorageGeneration receipt
      /= baselineReadBackStorageGeneration expected =
      boundaryRefused "provisioner read-back generation mismatch"
  | otherwise =
      do
        tokenResult <- lookupProvisionerToken registry receipt
        case tokenResult of
          Left failure -> pure (Left failure)
          Right token -> do
            policy <- observeProvisionerPolicy settings
            case policy of
              Left cause ->
                pure (Left (EngineBoundaryProvisionerPolicyApplication cause))
              Right () -> do
                reconciled <-
                  runVaultReconcile
                    (Vault.VaultAddress (brokerVaultAddress settings))
                    token
                    provisionerVaultReconcilePlan
                pki <-
                  observeVaultPkiBaseline
                    (Vault.VaultAddress (brokerVaultAddress settings))
                    token
                pure $ do
                  _ <- mapReconcileResult reconciled
                  status <- mapReconcileResult pki
                  if status == VaultReconcile.VaultPkiBaselineReady
                    then Right expected
                    else Left (EngineBoundaryRefused "Vault PKI baseline read-back was not exact")

provisionerReceiptFromLogin
  :: VaultStorageGeneration
  -> Vault.VaultKubernetesLoginResult
  -> Either EngineBoundaryError ProvisionerLoginReceipt
provisionerReceiptFromLogin generation login
  | Vault.vaultLoginLeaseSeconds login <= 0 =
      Left (EngineBoundaryRefused "provisioner login omitted a positive lease")
  | otherwise = do
      accessor <-
        mapLeft
          (EngineBoundaryRefused . Text.pack . show)
          (mkProvisionerAccessor (Vault.vaultLoginAccessor login))
      mapLeft
        (EngineBoundaryRefused . Text.pack . show)
        ( mkProvisionerLoginReceipt
            generation
            accessor
            (fromIntegral (Vault.vaultLoginLeaseSeconds login))
        )

lookupProvisionerToken
  :: ProvisionerTokenRegistry
  -> ProvisionerLoginReceipt
  -> IO (Either EngineBoundaryError Vault.VaultToken)
lookupProvisionerToken registry receipt = do
  tokens <- readIORef registry
  pure $ case Map.lookup (provisionerLoginAccessor receipt) tokens of
    Just token -> Right token
    Nothing ->
      Left
        ( EngineBoundaryUnavailable
            "journaled provisioner session token is unavailable; restart cleanup is required"
        )

lookupProvisionerPolicyApplicationToken
  :: ProvisionerTokenRegistry
  -> ProvisionerLoginReceipt
  -> IO (Either ProvisionerPolicyApplicationCause Vault.VaultToken)
lookupProvisionerPolicyApplicationToken registry receipt = do
  tokens <- readIORef registry
  pure $ case Map.lookup (provisionerLoginAccessor receipt) tokens of
    Just token -> Right token
    Nothing -> Left ProvisionerPolicyApplicationTokenUnavailable

repairProvisionerPolicy
  :: BootstrapBrokerSettings
  -> IO (Either ProvisionerPolicyApplicationCause ())
repairProvisionerPolicy settings = do
  acquired <- loginVaultBatchRole settings bootstrapPolicyRepairRole
  case acquired of
    Left _ -> pure (Left ProvisionerPolicyApplicationRepairAuthorityUnavailable)
    Right login -> do
      let token = Vault.vaultLoginToken login
          spec = bootstrapProvisionerPolicySpec
      written <-
        Vault.vaultWritePolicy
          address
          token
          (VaultReconcile.vaultPolicySpecName spec)
          (VaultReconcile.vaultPolicySpecDocument spec)
      case written of
        Left failure ->
          pure
            ( Left
                ( ProvisionerPolicyApplicationRepairWriteHttp
                    (classifyProvisionerPolicyRepairHttpFailure failure)
                )
            )
        Right () -> observeProvisionerPolicyWithToken address token
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

observeProvisionerPolicy
  :: BootstrapBrokerSettings
  -> IO (Either ProvisionerPolicyApplicationCause ())
observeProvisionerPolicy settings = do
  acquired <- loginVaultBatchRole settings bootstrapPolicyRepairRole
  case acquired of
    Left _ -> pure (Left ProvisionerPolicyApplicationRepairAuthorityUnavailable)
    Right login ->
      observeProvisionerPolicyWithToken
        (Vault.VaultAddress (brokerVaultAddress settings))
        (Vault.vaultLoginToken login)

observeProvisionerPolicyWithToken
  :: Vault.VaultAddress
  -> Vault.VaultToken
  -> IO (Either ProvisionerPolicyApplicationCause ())
observeProvisionerPolicyWithToken address token = do
  let spec = bootstrapProvisionerPolicySpec
  observed <-
    Vault.vaultReadPolicy address token (VaultReconcile.vaultPolicySpecName spec)
  pure $ case observed of
    Left failure ->
      Left
        ( ProvisionerPolicyApplicationRepairReadBackHttp
            (classifyProvisionerPolicyRepairHttpFailure failure)
        )
    Right readBack
      | Vault.policyReadbackDocument readBack
          == VaultReconcile.vaultPolicySpecDocument spec ->
          Right ()
      | otherwise -> Left ProvisionerPolicyApplicationRepairReadBackMismatch

classifyProvisionerPolicyRepairHttpFailure
  :: HttpError -> GeneratedRootCoreHttpFailure
classifyProvisionerPolicyRepairHttpFailure failure = case failure of
  HttpConnectionFailure _ -> GeneratedRootCoreHttpConnectionFailure
  HttpTimeout _ -> GeneratedRootCoreHttpTimeout
  HttpStatus status _ -> GeneratedRootCoreHttpStatus status
  HttpDecode _ -> GeneratedRootCoreHttpDecode

classifyProvisionerPolicyCoreReconcileFailure
  :: VaultReconcile.VaultReconcileError
  -> ProvisionerPolicyApplicationCause
classifyProvisionerPolicyCoreReconcileFailure =
  ProvisionerPolicyApplicationCoreReconcile
    . classifyVaultCoreReconcileFailure

classifyProvisionerPolicyPkiReconcileFailure
  :: VaultReconcile.VaultPkiReconcileError
  -> ProvisionerPolicyApplicationCause
classifyProvisionerPolicyPkiReconcileFailure =
  ProvisionerPolicyApplicationPkiReconcile
    . classifyVaultPkiReconcileFailure

observePostUnsealConsumer
  :: ProductionBrokerClients
  -> RootInitBinding
  -> PostUnsealConsumer
  -> IO (Either EngineBoundaryError (Maybe PostUnsealHandoffReceipt))
observePostUnsealConsumer clients binding consumer = do
  observed <-
    BootstrapHandoff.observeBootstrapHandoff
      client
      binding
      consumer
  case observed of
    Left failure -> pure (Left (handoffClientBoundaryError failure))
    Right (Just receipt) -> pure (Right (Just receipt))
    Right Nothing -> do
      accepted <-
        BootstrapHandoff.acceptBootstrapHandoff
          client
          binding
          consumer
      case accepted of
        Left failure -> pure (Left (handoffClientBoundaryError failure))
        Right expected -> do
          confirmed <-
            BootstrapHandoff.observeBootstrapHandoff
              client
              binding
              consumer
          pure $ case confirmed of
            Left failure -> Left (handoffClientBoundaryError failure)
            Right (Just actual)
              | actual == expected -> Right (Just actual)
            Right _ ->
              Left
                ( EngineBoundaryRefused
                    "post-unseal Authority acceptance read-back differs"
                )
 where
  client = productionHandoffClient clients

observeVaultPkiStatus
  :: BootstrapBrokerSettings -> IO (Either EngineBoundaryError VaultPkiStatus)
observeVaultPkiStatus settings =
  withVaultBatchRole settings bootstrapPkiOperatorRole $ \login -> do
    observed <- observeVaultPkiBaseline address (Vault.vaultLoginToken login)
    pure $ case observed of
      Right VaultReconcile.VaultPkiBaselineReady -> Right VaultPkiBaselineReady
      Right _ -> Right VaultPkiBaselineAbsent
      Left _ -> Left (EngineBoundaryUnavailable "Vault PKI status is unavailable")
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

issueVaultPkiTestCertificate
  :: BootstrapBrokerSettings
  -> BootstrapVaultEffectPermit
  -> PkiIssueRequest
  -> IO (Either EngineBoundaryError BootstrapMutationReceipt)
issueVaultPkiTestCertificate settings permit issue =
  withVaultBatchRole settings bootstrapPkiOperatorRole $ \login -> do
    issued <-
      Vault.vaultPkiIssueTestCertificate
        address
        (Vault.vaultLoginToken login)
        "prodbox-bootstrap-test"
        (pkiIssueCommonName issue)
        (Text.pack (show (pkiIssueTtlSeconds issue)) <> "s")
    pure $ case issued of
      Right _ ->
        Right
          BootstrapMutationReceipt
            { bootstrapMutationDigest = vaultEffectPermitActionDigest permit
            , bootstrapMutationChanged = True
            }
      Left _ -> Left (EngineBoundaryUnavailable "Vault PKI test-certificate issuance failed")
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

tryEngineAction :: IO value -> IO (Either SomeException value)
tryEngineAction = try

-- | Run an accessor-free, non-renewable Vault batch role.  There is no
-- server-side token accessor (and therefore no recursive auditor cleanup
-- obligation); the bounded batch lease is validated by 'loginVaultBatchRole'.
withVaultBatchRole
  :: BootstrapBrokerSettings
  -> Text
  -> (Vault.VaultKubernetesLoginResult -> IO (Either EngineBoundaryError value))
  -> IO (Either EngineBoundaryError value)
withVaultBatchRole settings role use = do
  loggedIn <- loginVaultBatchRole settings role
  case loggedIn of
    Left failure -> pure (Left failure)
    Right login -> use login

loginVaultRole
  :: BootstrapBrokerSettings
  -> Text
  -> IO (Either EngineBoundaryError Vault.VaultKubernetesLoginResult)
loginVaultRole settings role = do
  projected <- readProjectedServiceAccountToken
  case projected of
    Left _ -> boundaryUnavailable "projected Bootstrap Broker token is unavailable"
    Right jwt -> do
      loggedIn <- Vault.vaultKubernetesLoginWithLease address "kubernetes" role jwt
      case loggedIn of
        Left _ -> boundaryUnavailable ("Vault Kubernetes login failed for role " <> role)
        Right login
          | Vault.vaultLoginTokenType login /= "service" -> do
              cleaned <- cleanupInvalidSuccessfulVaultLogin settings jwt role login
              pure
                ( cleaned
                    >> Left
                      ( EngineBoundaryRefused
                          "Vault Kubernetes login did not return a service token"
                      )
                )
          | Text.null (Text.strip (Vault.vaultLoginAccessor login)) -> do
              cleaned <- cleanupInvalidSuccessfulVaultLogin settings jwt role login
              pure
                ( cleaned
                    >> Left
                      ( EngineBoundaryRefused
                          "Vault Kubernetes login omitted its session accessor"
                      )
                )
          | otherwise -> pure (Right login)
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

loginVaultBatchRole
  :: BootstrapBrokerSettings
  -> Text
  -> IO (Either EngineBoundaryError Vault.VaultKubernetesLoginResult)
loginVaultBatchRole settings role = do
  projected <- readProjectedServiceAccountToken
  case projected of
    Left _ -> boundaryUnavailable "projected Bootstrap Broker token is unavailable"
    Right jwt -> do
      loggedIn <- Vault.vaultKubernetesLoginWithLease address "kubernetes" role jwt
      case loggedIn of
        Left _ ->
          boundaryUnavailable ("Vault batch login failed for role " <> role)
        Right login
          | not (isBoundedBatchAuditorLogin 300 login) -> do
              cleaned <- cleanupInvalidSuccessfulVaultLogin settings jwt role login
              pure
                ( cleaned
                    >> Left
                      ( EngineBoundaryRefused
                          "Vault auditor/seal login did not return a bounded, accessor-free batch token"
                      )
                )
          | otherwise -> pure (Right login)
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

-- | A successful login response transfers ownership of its bearer to this
-- process even when the returned token type, lease, or accessor evidence is
-- wrong.  Revoke-self is provisional (its response can be lost); terminal
-- refusal is emitted only after a separately validated bounded batch auditor
-- proves the complete role subject at stable zero.  Invalid auditor-login
-- attempts are themselves revoked and included in the same proof.
cleanupInvalidSuccessfulVaultLogin
  :: BootstrapBrokerSettings
  -> Text
  -> Text
  -> Vault.VaultKubernetesLoginResult
  -> IO (Either EngineBoundaryError ())
cleanupInvalidSuccessfulVaultLogin settings jwt role invalidLogin = do
  selfRevoked <- Vault.vaultRevokeSelf address (Vault.vaultLoginToken invalidLogin)
  case requireAccessorFreeInvalidLoginRevoked invalidLogin selfRevoked of
    Left failure -> pure (Left failure)
    Right () -> do
      acquired <- acquireCleanupAuditor settings jwt maximumCleanupAuditorAttempts []
      case acquired of
        Left failure -> pure (Left failure)
        Right (auditor, invalidAuditorAccessors) -> do
          requested <-
            auditVaultRoleStableZeroWithToken
              boundedVaultAccessorVisibilityGrace
              settings
              (Vault.vaultLoginToken auditor)
              role
              (normalizedLoginAccessor invalidLogin)
          case requested of
            Left failure -> pure (Left failure)
            Right _ ->
              auditInvalidAuditorAccessors
                (Vault.vaultLoginToken auditor)
                invalidAuditorAccessors
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)
  auditInvalidAuditorAccessors _ [] = pure (Right ())
  auditInvalidAuditorAccessors auditorToken (known : remaining) = do
    audited <-
      auditVaultRoleStableZeroWithToken
        boundedVaultAccessorVisibilityGrace
        settings
        auditorToken
        tokenAccessorAuditorRole
        known
    case audited of
      Left failure -> pure (Left failure)
      Right _ -> auditInvalidAuditorAccessors auditorToken remaining

maximumCleanupAuditorAttempts :: Natural
maximumCleanupAuditorAttempts = 4

acquireCleanupAuditor
  :: BootstrapBrokerSettings
  -> Text
  -> Natural
  -> [Maybe Text]
  -> IO
       ( Either
           EngineBoundaryError
           (Vault.VaultKubernetesLoginResult, [Maybe Text])
       )
acquireCleanupAuditor _ _ 0 _ =
  boundaryUnavailable "Vault cleanup auditor did not return valid bounded batch evidence"
acquireCleanupAuditor settings jwt remaining invalidAccessors = do
  loggedIn <-
    Vault.vaultKubernetesLoginWithLease
      address
      "kubernetes"
      tokenAccessorAuditorRole
      jwt
  case loggedIn of
    Left _ -> boundaryUnavailable "Vault cleanup auditor login failed"
    Right login
      | isBoundedBatchAuditorLogin 300 login ->
          pure (Right (login, reverse invalidAccessors))
      | otherwise -> do
          selfRevoked <- Vault.vaultRevokeSelf address (Vault.vaultLoginToken login)
          case requireAccessorFreeInvalidLoginRevoked login selfRevoked of
            Left failure -> pure (Left failure)
            Right () ->
              acquireCleanupAuditor
                settings
                jwt
                (remaining - 1)
                (normalizedLoginAccessor login : invalidAccessors)
 where
  address = Vault.VaultAddress (brokerVaultAddress settings)

normalizedLoginAccessor
  :: Vault.VaultKubernetesLoginResult -> Maybe Text
normalizedLoginAccessor login =
  let accessor = Text.strip (Vault.vaultLoginAccessor login)
   in if Text.null accessor then Nothing else Just accessor

-- Vault does not index batch-token accessors.  If an invalid successful
-- login is accessor-free and claims to be a batch token, revoke-self is the
-- only possible terminal cleanup proof and therefore cannot be treated as a
-- provisional response.
requireAccessorFreeInvalidLoginRevoked
  :: Vault.VaultKubernetesLoginResult
  -> Either error ()
  -> Either EngineBoundaryError ()
requireAccessorFreeInvalidLoginRevoked login revoked =
  case (Vault.vaultLoginTokenType login, normalizedLoginAccessor login, revoked) of
    ("batch", Nothing, Left _) ->
      Left
        ( EngineBoundaryUnavailable
            "Vault accessor-free invalid login could not be revoked"
        )
    _ -> Right ()

mapVaultUnit
  :: Text -> IO (Either error ()) -> IO (Either EngineBoundaryError ())
mapVaultUnit label action =
  fmap
    (either (const (Left (EngineBoundaryUnavailable (label <> " failed")))) Right)
    action

custodyClientBoundaryError
  :: BootstrapCustodyClientError -> EngineBoundaryError
custodyClientBoundaryError failure = case failure of
  BootstrapCustodyRefused detail -> EngineBoundaryRefused detail
  BootstrapCustodyHttpStatus status
    | status >= 400 && status < 500 ->
        EngineBoundaryRefused
          ("Target child-custody endpoint returned HTTP " <> Text.pack (show status))
  _ ->
    EngineBoundaryUnavailable
      "Target child-custody authenticated endpoint is unavailable"

handoffClientBoundaryError
  :: BootstrapHandoffClientError -> EngineBoundaryError
handoffClientBoundaryError failure = case failure of
  BootstrapHandoffClientRefused detail -> EngineBoundaryRefused detail
  BootstrapHandoffHttpStatus status
    | status >= 400 && status < 500 ->
        EngineBoundaryRefused
          ("Lifecycle handoff endpoint returned HTTP " <> Text.pack (show status))
  _ ->
    EngineBoundaryUnavailable
      "Lifecycle handoff authenticated endpoint is unavailable"

mapReconcileResult :: Either error value -> Either EngineBoundaryError value
mapReconcileResult =
  either (const (Left (EngineBoundaryUnavailable "Vault baseline reconcile failed"))) Right

-- | Sprint 2.47: publish the absence receipt that authorized a takeover.
--
-- This is the digest's only consumer. 'decideBootstrapFenceRetire' has nothing
-- to compare it against and does not read it, so narrating it is what keeps it
-- from being a field that enforces nothing — the shape Sprints 4.68, 4.72, and
-- 4.77 each found. A digest is safe to publish; the observation it commits to
-- binds only API-assigned coordinates and never the owner nonce.
absenceReceiptName :: BootstrapFenceOwnerCleanupObservation -> String
absenceReceiptName observation = case observation of
  BootstrapFenceOwnerAbsent _ receipt -> Text.unpack (renderArtifactDigest receipt)
  BootstrapFenceOwnerStillPresent _ -> "none"
  BootstrapFenceOwnerCleanupUnobservable _ -> "none"

digestSerialised :: (Serialise value) => value -> ArtifactDigest
digestSerialised value =
  case mkArtifactDigest (lowerHexBytes (SHA256.hash (LazyByteString.toStrict (serialise value)))) of
    Right digest -> digest
    Left _ -> error "SHA-256 artifact digest invariant failed"

runLocal
  :: BootstrapStoreBoundary IO
  -> ProductionBrokerClients
  -> BrokerLocalCall result
  -> IO (Either EngineBoundaryError result)
runLocal store clients call = case call of
  LocalRecoverRootInitCall binding -> do
    observed <- readEncryptedInitResponse store binding
    pure $ case observed of
      Left failure -> Left (storeBoundaryError failure)
      Right StoreObjectAbsent -> Right RootInitRecoveredAmbiguity
      Right (StoreObjectPresent _ _ receipt) -> Right (RootInitRecoveredResponse receipt)
  LocalAcknowledgeRecoveryCustody bundle -> do
    observed <- readFinalUnlockBundle store (finalUnlockBundleBinding bundle)
    pure $ case observed of
      Left failure -> Left (storeBoundaryError failure)
      Right (StoreObjectPresent _ _ durable)
        | durable == bundle ->
            Right
              ( mkRecoveryCustodyReceipt
                  bundle
                  (digestSerialised ("bootstrap-recovery-custody-v1" :: Text, bundle))
              )
        | otherwise -> Left (EngineBoundaryRefused "final unlock-bundle custody read-back differs")
      Right StoreObjectAbsent ->
        Left (EngineBoundaryRefused "final unlock-bundle custody is absent")
  LocalCaptureChildEncryptedReceipt binding -> do
    rootBinding <- observeVaultStorageGeneration store
    case rootBinding of
      Left failure -> pure (Left (storeBoundaryError failure))
      Right durableBinding
        | rootInitStorageGeneration durableBinding
            /= childCustodyStorageGeneration binding ->
            boundaryRefused "child custody generation does not match durable root initialization"
        | rootInitTransactionId durableBinding
            /= childCustodyTransactionId binding ->
            boundaryRefused "child custody transaction does not match durable root initialization"
        | otherwise -> do
            observed <- readEncryptedInitResponse store durableBinding
            pure $ case observed of
              Left failure -> Left (storeBoundaryError failure)
              Right StoreObjectAbsent ->
                Left (EngineBoundaryRefused "encrypted initialization receipt is absent")
              Right (StoreObjectPresent _ _ response) ->
                mapLeft
                  (EngineBoundaryRefused . Text.pack . show)
                  ( mkChildEncryptedReceipt
                      binding
                      (encryptedResponseShares response)
                      (encryptedResponseBurnToken response)
                      (digestSerialised ("child-encrypted-receipt-v1" :: Text, binding, response))
                  )
  LocalPrepareChildRecoveryDelivery binding nonce attestation ->
    fmap
      (mapLeft custodyClientBoundaryError)
      ( BootstrapCustody.prepareChildRecovery
          (productionCustodyClient clients)
          binding
          nonce
          attestation
      )

-- | The readiness request path.
--
-- This is the whole of @\/readyz@: read the latched record, read the monotonic
-- clock, fold. It performs no object-store, Vault, OpenPGP, or Kubernetes work
-- of any kind — that is the invariant the broker's chart comment always
-- asserted, and it is now enforced by the
-- @broker-readiness-projection@ conformance gate in @prodbox dev check@ rather
-- than merely described.
productionReady :: BrokerReadinessCache -> IO BrokerReadinessState
productionReady cache = do
  now <- realMonotonicNow
  facts <- readTVarIO (brokerReadinessCacheFacts cache)
  pure (computeBrokerReadiness brokerReadinessSchedule (monotonicInstantMicros now) facts)

-- | The latched dependency facts plus the action that refreshes them. The
-- record keeps the two halves together so no caller can acquire the cache
-- without also being able to name what fills it.
data BrokerReadinessCache = BrokerReadinessCache
  { brokerReadinessCacheFacts :: !(TVar BrokerReadinessFacts)
  , brokerReadinessCacheRefresh :: !(IO ())
  }

-- | One background observation pass. Every boundary call in the readiness path
-- lives here and nowhere else.
observeBrokerReadinessFacts
  :: ProductionCapabilityRegistry
  -> BootstrapBrokerSettings
  -> KubernetesWorkerBoundary
  -> IO BrokerReadinessFacts
observeBrokerReadinessFacts capabilityRegistry settings kubernetes = do
  storeReady <- bootstrapStoreReady settings
  vaultReady <- Vault.vaultSealStatus (Vault.VaultAddress (brokerVaultAddress settings))
  pgpReady <- productionPgpReady
  now <- realMonotonicNow
  lease <-
    kubernetesObserveBootstrapLease
      kubernetes
      (deadlineAtOffset now (RemainingDuration (observationBudgetMicros brokerReadinessSchedule)))
  image <-
    kubernetesObserveControllerImage
      kubernetes
      -- Never the worker-launch scope: requiring this Pod's own Ready
      -- condition here is the circular dependency that made a cold bring-up
      -- unable to converge.
      ControllerObservedForOwnReadiness
      (deadlineAtOffset now (RemainingDuration (observationBudgetMicros brokerReadinessSchedule)))
  observedAt <- realMonotonicNow
  pure
    BrokerReadinessFacts
      { brokerFactCapabilityInventory =
          flagDependency
            "the production capability inventory is incomplete"
            ( productionCapabilityInventoryComplete
                (productionCapabilityRegistryBindings capabilityRegistry)
            )
      , brokerFactBootstrapStore =
          flagDependency "the bootstrap object store is unreachable" storeReady
      , brokerFactVaultSeal =
          flagDependency
            "Vault seal-status is unavailable"
            (either (const False) (const True) vaultReady)
      , brokerFactOpenPgp =
          flagDependency "the OpenPGP boundary is unavailable" pgpReady
      , brokerFactBootstrapLease = leaseDependency lease
      , brokerFactControllerImage = controllerImageDependency image
      , brokerFactObservedAtMicros = Just (monotonicInstantMicros observedAt)
      }
 where
  flagDependency detail satisfied =
    if satisfied
      then BrokerDependencyReady
      else BrokerDependencyUnavailable detail

-- | An absent Lease is the normal pre-mutation state, so it is ready. An
-- identity rejection is absorbing and keeps its own constructor: this is the
-- exact collapse that made a refused ServiceAccount token indistinguishable
-- from a dependency that had not come up yet.
leaseDependency :: BootstrapLeaseObservation -> BrokerDependencyObservation
leaseDependency observation = case observation of
  BootstrapLeaseMissing -> BrokerDependencyReady
  BootstrapLeaseObserved {} -> BrokerDependencyReady
  BootstrapLeaseUnobservable detail -> BrokerDependencyUnavailable detail
  BootstrapLeaseIdentityRejected detail -> BrokerDependencyIdentityRejected detail

controllerImageDependency :: ControllerImageObservation -> BrokerDependencyObservation
controllerImageDependency observation = case observation of
  ControllerImageObserved _ -> BrokerDependencyReady
  ControllerImageUnobservable detail -> BrokerDependencyUnavailable detail
  ControllerImageIdentityRejected detail -> BrokerDependencyIdentityRejected detail

observeBootstrapStatus
  :: BootstrapBrokerSettings
  -> BootstrapStoreBoundary IO
  -> IO (Either EngineBoundaryError BootstrapStatus)
observeBootstrapStatus settings store = do
  bindingResult <- observeVaultStorageGeneration store
  vaultResult <- Vault.vaultSealStatus (Vault.VaultAddress (brokerVaultAddress settings))
  case (bindingResult, vaultResult) of
    (Right binding, Right vaultStatus) -> do
      root <- readRootInitJournal store binding
      session <- readRootSessionJournal store (rootInitStorageGeneration binding)
      handoff <- readPostUnsealHandoff store binding
      pure $ do
        rootState <- mapLeft storeBoundaryError root
        sessionState <- mapLeft storeBoundaryError session
        handoffState <- mapLeft storeBoundaryError handoff
        Right
          BootstrapStatus
            { bootstrapStatusStorageGeneration = rootInitStorageGeneration binding
            , bootstrapStatusInitialized = Vault.sealStatusInitialized vaultStatus
            , bootstrapStatusSealed = Vault.sealStatusSealed vaultStatus
            , bootstrapStatusRecoveryCustodyDurable = recoveryDurable rootState
            , bootstrapStatusInitializationAmbiguous = initializationAmbiguous rootState
            , bootstrapStatusRootSessionActive = rootSessionActive sessionState
            , bootstrapStatusHandoffObserved = handoffObserved handoffState
            }
    (Left failure, _) -> pure (Left (storeBoundaryError failure))
    (_, Left _) -> boundaryUnavailable "Vault seal-status is unavailable"

recoveryDurable :: StoreReadBack RootInitState -> Bool
recoveryDurable observed = case observed of
  StoreObjectPresent _ _ state -> case rootInitStatePhase state of
    RootRecoveryCustodyDurable {} -> True
    _ -> False
  StoreObjectAbsent -> False

initializationAmbiguous :: StoreReadBack RootInitState -> Bool
initializationAmbiguous observed = case observed of
  StoreObjectPresent _ _ state -> case rootInitStatePhase state of
    RootInitializationAmbiguous {} -> True
    _ -> False
  StoreObjectAbsent -> False

rootSessionActive :: StoreReadBack RootSessionState -> Bool
rootSessionActive observed = case observed of
  StoreObjectPresent _ _ state -> case rootSessionStatePhase state of
    RootSessionClosed {} -> False
    RootSessionCancelledClean {} -> False
    _ -> True
  StoreObjectAbsent -> False

handoffObserved :: StoreReadBack PostUnsealHandoffState -> Bool
handoffObserved observed = case observed of
  StoreObjectPresent _ _ state -> case postUnsealHandoffStatePhase state of
    PostUnsealHandoffObserved {} -> True
    _ -> False
  StoreObjectAbsent -> False

authorityClockNow :: IO AuthorityClockObservation
authorityClockNow = do
  seconds <- getPOSIXTime
  let micros :: Natural
      micros = max 0 (floor (seconds * 1000000))
  pure (AuthorityTimeTrusted (authorityTimeFromMicros micros) (clockUncertaintyFromMicros 1000))

freshOwnerNonce :: IO (Either String OwnerNonce)
freshOwnerNonce = do
  bytes <- getRandomBytes 32
  pure (mapLeft show (mkOwnerNonce (lowerHexBytes bytes)))

lowerHexBytes :: ByteString -> Text
lowerHexBytes = Text.pack . concatMap twoHex . ByteString.unpack
 where
  twoHex byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

storeBoundaryError :: StoreBoundaryError -> EngineBoundaryError
storeBoundaryError = EngineBoundaryUnavailable . Text.pack . show

boundaryUnavailable :: Text -> IO (Either EngineBoundaryError value)
boundaryUnavailable = pure . Left . EngineBoundaryUnavailable

boundaryRefused :: Text -> IO (Either EngineBoundaryError value)
boundaryRefused = pure . Left . EngineBoundaryRefused

mapLeft :: (error -> mapped) -> Either error value -> Either mapped value
mapLeft render = either (Left . render) Right
