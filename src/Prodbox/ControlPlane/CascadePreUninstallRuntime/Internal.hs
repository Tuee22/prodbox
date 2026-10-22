{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Closed descriptor-bound runtime for the three cascade Stage-C nodes.
--
-- The runtime reconstructs convergence from the opaque durable run on every
-- entry, takes a fresh exact terminal audit under the audit node's stable
-- operation identity, and persists only the opaque Ready binding.  It keeps no
-- process-local proof cache, so response loss or process restart resumes from
-- Authority and retained-root facts rather than from remembered values.
module Prodbox.ControlPlane.CascadePreUninstallRuntime.Internal
  ( CascadePreUninstallRuntime
  , mkCascadePreUninstallRuntime
  , cascadePreUninstallDescriptorBoundNodeActionInternal
  , observeCascadePreUninstallEpochInternal
  , retireCascadePreUninstallCredentialInternal
  , fixedCascadePreUninstallEpochChecks
  )
where

import Data.Bifunctor (first)
import Data.Either (fromLeft)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientTransport)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityControlPayload (..))
import Prodbox.ControlPlane.AuthorityControlClient
  ( AuthorityControlClient (submitAuthorityControl)
  , authorityControlClientWithTransport
  , observeProviderAdmissionRecoveryWithTransport
  )
import Prodbox.ControlPlane.CascadeReportRepository
  ( CascadeReportAuthorityClient
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionDecision (..)
  , authorityAggregateProviderAdmissionEpochView
  , initialCleanInstallAuthority
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , CascadeTerminalAuditReceipt
  , CascadeTerminalAuditVerdict (..)
  , ProviderAdmissionEpochView (ProviderAdmissionCascadeCredentialRevoked)
  , ProviderAdmissionRecoveryObservation
  , ProviderAdmissionRecoveryPhase (..)
  , ProviderCredentialRetirementConfirmation
  , ProviderCredentialRevocationReceipt
  , cascadeTerminalAuditReceiptQueryDigest
  , cascadeTerminalAuditReceiptRetainedSetDigest
  , cascadeTerminalAuditReceiptScopeDigest
  , cascadeTerminalAuditReceiptVerdict
  , confirmProviderCredentialRetirement
  , mkCascadeAuditFreezeBinding
  , mkCascadeTerminalAuditReceipt
  , mkProviderCredentialRevocationReceipt
  , providerAdmissionRecoveryPhase
  , restoreCascadeAuditRecoveryBinding
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (CleanupNodeSucceeded)
  , CleanupNodeState (..)
  , cleanupDigestOfBytes
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupRunId
  , mkCleanupAttemptId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( DescriptorBoundCleanupNodeExecutionAction
  , descriptorBoundCleanupNodeAction
  )
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
  ( HarnessCredentialRevocationEvidence
  , harnessCredentialRevocationEpochReceipt
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentStore
  , hostCleanupReadyMatches
  , observeHostCleanupIntentForResume
  , observedHostCleanupIntent
  , persistHostCleanupReady
  , restoreObservedHostCleanupReady
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeAbsenceEvidence
  , CascadeCapabilityCustodyEvidence
  , CascadeCredentialDispositionEvidence
  , CascadePreUninstallReportObservation (..)
  , CascadeTerminalAuditEvidence
  , ReadyToUninstallEvidence
  , mkCascadeRunConvergenceEvidence
  , mkCascadeTerminalConvergenceEvidence
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( CascadeTerminalAuditFullBoundary (..)
  , fullCascadeTerminalAuditCatalog
  , observeFullCascadeTerminalAudit
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
  ( cascadeTerminalAuditReceiptFor
  , providerFullCascadeTerminalAuditBoundary
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( LifecycleTeardownEffects (..)
  , TeardownExecutionContext
  , TeardownNodeResult (..)
  , runCompiledTeardownNodeWithDescriptorContext
  , teardownExecutionOperationIdFor
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , CleanupSurfaceWitness (..)
  , ObservationFailure (ObservationFailure)
  , ObservationRevision (ObservationRevision)
  , evidenceAwsScope
  , evidenceResourceScopeBindings
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditObservation
  , terminalAuditEvidenceScopeDigest
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( PreUninstallReadinessOutcome (..)
  , PreUninstallReadinessRun (..)
  , commitPreUninstallReport
  , renderPreUninstallReadinessRefusal
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReport
  ( preUninstallReportBytes
  , preUninstallReportDigest
  , renderPreUninstallReport
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReportCommit
  ( cascadeReportCommitBoundary
  )
import Prodbox.Lifecycle.Teardown.PreUninstallStageC
  ( CascadeStageC (..)
  , renderCascadeStageCRefusal
  , runCascadeStageC
  )
import Prodbox.Lifecycle.Teardown.Program
  ( SomeTeardownOperation (..)
  , TeardownOperation (..)
  , TeardownResultKind (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchPurpose (ProviderTerminalAudit)
  , TeardownProviderBoundary
  , dispatchRegisteredProviderObservation
  , mkFencedTerminalAuditProviderDispatchKey
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  , providerDispatchSubmissionKey
  )
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings (resourceScopeAuditRetainedNames)
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  , mkRetainedNameBinding
  )

import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent (ObserveProviderAwsScope))
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( captureCleanupProgramDescriptor
  , cleanupProgramDescriptorDigest
  )
import Prodbox.Lifecycle.Teardown.PerRunTerminalAuditPlan
  ( perRunAuditQueryProviderIntent
  , terminalAuditEndpointQueriesFor
  )
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForCascadeTerminalAudit)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- | The authenticated epoch interpreter is separate from the orchestration.
-- Its observer re-reads durable state after every write outcome.
data CascadeAuditEpochBoundary = CascadeAuditEpochBoundary
  { auditEpochSubmit :: AuthorityControlPayload -> IO (Either Text Text)
  , auditEpochObserve
      :: CascadeAuditFreezeBinding -> IO (Either Text ProviderAdmissionRecoveryObservation)
  }

productionCascadeAuditEpochBoundary
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> CascadeAuditEpochBoundary
productionCascadeAuditEpochBoundary transport =
  CascadeAuditEpochBoundary
    { auditEpochSubmit = \payload ->
        first (Text.pack . show)
          <$> submitAuthorityControl (authorityControlClientWithTransport transport) payload
    , auditEpochObserve = \binding ->
        first (Text.pack . show)
          <$> observeProviderAdmissionRecoveryWithTransport transport binding
    }

data CascadePreUninstallRuntime = CascadePreUninstallRuntime
  { cascadePreUninstallReportAuthority :: !(CascadeReportAuthorityClient IO)
  , cascadePreUninstallReportBackup :: !(CleanupReportBackupClient IO)
  , cascadePreUninstallProvider :: !(TeardownProviderBoundary IO)
  , cascadePreUninstallHostStore :: !HostCleanupIntentStore
  , cascadePreUninstallEpoch :: !CascadeAuditEpochBoundary
  , cascadePreUninstallCredentialGeneration :: !(IO (Either Text (Maybe Natural)))
  }

mkCascadePreUninstallRuntime
  :: CascadeReportAuthorityClient IO
  -> CleanupReportBackupClient IO
  -> TeardownProviderBoundary IO
  -> HostCleanupIntentStore
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either Text (Maybe Natural))
  -> CascadePreUninstallRuntime
mkCascadePreUninstallRuntime report backup provider store transport generation =
  CascadePreUninstallRuntime
    report
    backup
    provider
    store
    (productionCascadeAuditEpochBoundary transport)
    generation

cascadePreUninstallDescriptorBoundNodeActionInternal
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
cascadePreUninstallDescriptorBoundNodeActionInternal runtime =
  descriptorBoundCleanupNodeAction $ \running _ compiled context plan ->
    runCascadePreUninstallEffects
      ( runCompiledTeardownNodeWithDescriptorContext
          running
          compiled
          context
          plan
      )
      runtime
      running

-- | Reader-like carrier whose environment contains only the closed Stage-C
-- runtime and the opaque descriptor-bound run.  The operation interpreter
-- re-opens that handle on every effect, so it never trusts a caller-supplied
-- compiled program or process-local proof cache.
newtype CascadePreUninstallEffects value = CascadePreUninstallEffects
  { runCascadePreUninstallEffects
      :: CascadePreUninstallRuntime
      -> DescriptorBoundCleanupRun
      -> IO value
  }

instance Functor CascadePreUninstallEffects where
  fmap transform action =
    CascadePreUninstallEffects $ \runtime running ->
      fmap transform (runCascadePreUninstallEffects action runtime running)

instance Applicative CascadePreUninstallEffects where
  pure value = CascadePreUninstallEffects $ \_ _ -> pure value
  function <*> value =
    CascadePreUninstallEffects $ \runtime running -> do
      transform <- runCascadePreUninstallEffects function runtime running
      input <- runCascadePreUninstallEffects value runtime running
      pure (transform input)

instance Monad CascadePreUninstallEffects where
  action >>= next =
    CascadePreUninstallEffects $ \runtime running -> do
      value <- runCascadePreUninstallEffects action runtime running
      runCascadePreUninstallEffects (next value) runtime running

instance LifecycleTeardownEffects CascadePreUninstallEffects where
  executeLifecycleTeardownOperation context operation =
    CascadePreUninstallEffects executeOperation
   where
    executeOperation runtime running = case operation of
      AuditCascadeEscapes ->
        withCascadeProgram
          running
          (\compiled -> runAudit runtime running compiled context)
      CommitCascadePreUninstallReport ->
        withCascadeProgram
          running
          (\compiled -> runCommit runtime running compiled context)
      ReadBackCascadePreUninstallReport ->
        withCascadeProgram
          running
          (\compiled -> runReadBack runtime running compiled context)
      _ ->
        pure
          ( TeardownNodeRefused
              ( "cascade pre-uninstall runtime does not own `"
                  <> teardownOperationTag operation
                  <> "`"
              )
          )

withCascadeProgram
  :: forall result
   . DescriptorBoundCleanupRun
  -> ( CompiledDesiredAbsenceProgram 'Cascade
       -> IO (TeardownNodeResult 'Cascade result)
     )
  -> IO (TeardownNodeResult 'Cascade result)
withCascadeProgram running consume =
  case withDescriptorBoundCleanupProgram running select of
    Left err -> pure (TeardownNodeRefused (Text.pack (show err)))
    Right action -> action
 where
  select
    :: forall surface
     . CleanupSurfaceWitness surface
    -> CompiledDesiredAbsenceProgram surface
    -> DescriptorBoundCleanupRun
    -> IO (TeardownNodeResult 'Cascade result)
  select witness compiled _ = case witness of
    CascadeSurface -> consume compiled
    _ ->
      pure
        ( TeardownNodeRefused
            "cascade pre-uninstall runtime received a non-cascade descriptor"
        )

runAudit
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade 'TerminalAuditObservationResult)
runAudit runtime running compiled context = do
  observed <- observeTerminal runtime running compiled context
  pure $ case observed of
    Left detail -> TeardownNodeRefused detail
    Right (_, observation) ->
      TeardownTerminalAuditObservation observation

runCommit
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade 'MutationAttemptResult)
runCommit runtime running compiled context = do
  convergence <- convergenceEvidence runtime running compiled context
  case convergence of
    Left detail -> pure (TeardownNodeRefused detail)
    Right (absence, credentials, audit, _custody) ->
      case renderPreUninstallReport compiled absence credentials audit of
        Left err -> pure (TeardownNodeRefused (Text.pack (show err)))
        Right report ->
          case cascadeReportCommitBoundary
            (cascadePreUninstallReportAuthority runtime)
            (cascadePreUninstallReportBackup runtime)
            compiled
            (preUninstallReportBytes report) of
            Left detail -> pure (TeardownNodeRefused detail)
            Right boundary -> do
              committed <- commitPreUninstallReport boundary (preUninstallReportDigest report)
              pure (TeardownMutationAttempt committed)

runReadBack
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade 'DurableReceiptObservationResult)
runReadBack runtime running compiled context = do
  convergence <- convergenceEvidence runtime running compiled context
  case convergence of
    Left detail -> pure (TeardownNodeRefused detail)
    Right (absence, credentials, audit, custody) -> do
      staged <-
        runCascadeStageC
          (cascadePreUninstallReportAuthority runtime)
          (cascadePreUninstallReportBackup runtime)
          compiled
          absence
          credentials
          audit
          custody
      case staged of
        Left err -> pure (TeardownNodeRefused (Text.pack (renderCascadeStageCRefusal err)))
        Right stage -> case preUninstallReadinessOutcome (cascadeStageCRun stage) of
          PreUninstallNotReady err ->
            pure (TeardownNodeRefused (Text.pack (renderPreUninstallReadinessRefusal err)))
          PreUninstallReady ready -> do
            persisted <- persistReady runtime ready
            pure $ case persisted of
              Left detail -> TeardownNodeRefused detail
              Right () ->
                TeardownDurableReceiptObservation
                  ( cascadePreUninstallReportReceipt
                      (preUninstallReadinessObservation (cascadeStageCRun stage))
                  )

-- | Reconstruct every pre-uninstall proof from durable run state plus the
-- stable terminal-audit operation.  The audit is deliberately repeated for
-- commit/read-back retries; its Provider submission and revision stay stable.
convergenceEvidence
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO
       ( Either
           Text
           ( CascadeAbsenceEvidence
           , CascadeCredentialDispositionEvidence
           , CascadeTerminalAuditEvidence
           , CascadeCapabilityCustodyEvidence
           )
       )
convergenceEvidence runtime running compiled context =
  case first
    (Text.pack . show)
    (mkCascadeRunConvergenceEvidence compiled (descriptorBoundCleanupRunNodeStates running)) of
    Left detail -> pure (Left detail)
    Right (absence, custody) -> do
      observed <- observeTerminal runtime running compiled context
      pure $ do
        (credentials, audit) <- fst <$> observed
        Right (absence, credentials, audit, custody)

observeTerminal
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO
       ( Either
           Text
           ( ( CascadeCredentialDispositionEvidence
             , CascadeTerminalAuditEvidence
             )
           , TerminalAuditObservation 'Cascade
           )
       )
observeTerminal runtime running compiled context =
  case ( evidenceAwsScope (compiledDesiredAbsenceObservationScope compiled)
       , cascadeAuditRetainedNames compiled
       ) of
    (Nothing, _) -> pure (Left "cascade terminal audit has no compiled AWS scope")
    (_, Left detail) -> pure (Left detail)
    (Just awsScope, Right retained) -> case fullCascadeTerminalAuditCatalog awsScope retained of
      Left err -> pure (Left (Text.pack (show err)))
      Right catalog -> case teardownExecutionOperationIdFor context AuditCascadeEscapes of
        Nothing -> pure (Left "cascade terminal audit operation identity is missing")
        Just operationId -> case mkProviderDispatchKey operationId ProviderTerminalAudit of
          Left err -> pure (Left (Text.pack (show err)))
          Right dispatchKey -> case auditBindingFor running compiled of
            Left detail -> pure (Left detail)
            Right requested -> do
              let dispatch intent = case mkFencedTerminalAuditProviderDispatchKey operationId intent of
                    Left err -> pure (Left (Text.pack (show err)))
                    Right queryKey ->
                      first (Text.pack . show)
                        <$> dispatchRegisteredProviderObservation
                          (cascadePreUninstallProvider runtime)
                          queryKey
                          intent
                  boundary = providerFullCascadeTerminalAuditBoundary awsScope dispatch
              observation <-
                runConfirmedCascadeAudit
                  (cascadePreUninstallEpoch runtime)
                  (cascadePreUninstallCredentialGeneration runtime)
                  requested
                  $ first (Text.pack . show)
                    <$> observeFullCascadeTerminalAudit
                      boundary
                      retained
                      compiled
                      (observationRevisionForProviderDispatchKey dispatchKey)
              pure $ do
                exact <- observation
                evidence <- first (Text.pack . show) (mkCascadeTerminalConvergenceEvidence catalog compiled exact)
                Right (evidence, exact)

-- | Re-open the exact durable audit binding without issuing Provider work.
-- The replaceable cleanup lease attempt is restored from the authenticated epoch.
observeCascadePreUninstallEpochInternal
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> IO (Either Text (CascadeAuditFreezeBinding, ProviderAdmissionRecoveryObservation))
observeCascadePreUninstallEpochInternal runtime running =
  case withDescriptorBoundCleanupProgram
    running
    (\_ compiled _ -> observeAuditEpoch runtime running compiled) of
    Left err -> pure (Left (Text.pack (show err)))
    Right action -> action

-- | Retire the credential while both authenticated control-plane roles still
-- exist. A lost control reply is settled by an independent epoch read. A
-- previously revoked epoch only needs fresh Target absence; it never reinstalls.
retireCascadePreUninstallCredentialInternal
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> IO (Either Text HarnessCredentialRevocationEvidence)
  -> IO (Either Text ProviderCredentialRetirementConfirmation)
retireCascadePreUninstallCredentialInternal runtime running revoke = do
  recovered <- observeCascadePreUninstallEpochInternal runtime running
  case recovered of
    Left detail -> pure (Left detail)
    Right (_, observation) ->
      case withDescriptorBoundCleanupProgram running (\_ compiled _ -> auditBindingFor running compiled) of
        Left err -> pure (Left (Text.pack (show err)))
        Right (Left detail) -> pure (Left detail)
        Right (Right requested) ->
          retireConfirmedCascadeCredential
            (cascadePreUninstallEpoch runtime)
            (cascadePreUninstallCredentialGeneration runtime)
            (fmap (>>= first (Text.pack . show) . harnessCredentialRevocationEpochReceipt) revoke)
            requested
            observation

retireConfirmedCascadeCredential
  :: CascadeAuditEpochBoundary
  -> IO (Either Text (Maybe Natural))
  -> IO (Either Text ProviderCredentialRevocationReceipt)
  -> CascadeAuditFreezeBinding
  -> ProviderAdmissionRecoveryObservation
  -> IO (Either Text ProviderCredentialRetirementConfirmation)
retireConfirmedCascadeCredential boundary generation revoke requested observation =
  case restoreCascadeAuditRecoveryBinding requested observation of
    Left err -> pure (Left (Text.pack (show err)))
    Right original -> retire original
 where
  retire binding =
    case providerAdmissionRecoveryPhase observation of
      ProviderRecoveryRevoked {} -> confirmAbsent observation
      ProviderRecoveryRecorded recordedGeneration _ audit
        | cascadeTerminalAuditReceiptVerdict audit == CascadeTerminalAuditReceiptClean -> do
            revoked <- revoke
            case revoked of
              Left detail -> do
                recovered <- auditEpochObserve boundary binding
                case recovered of
                  Right actual -> case providerAdmissionRecoveryPhase actual of
                    ProviderRecoveryRevoked revokedGeneration _ recorded _
                      | revokedGeneration == recordedGeneration && recorded == audit -> confirmAbsent actual
                    _ -> pure (Left detail)
                  Left _ -> pure (Left detail)
              Right receipt -> do
                attempted <-
                  auditEpochSubmit boundary (AuthorityControlRevokeCascadeProviderCredential binding receipt)
                observed <- auditEpochObserve boundary binding
                pure $ case observed of
                  Right actual -> case providerAdmissionRecoveryPhase actual of
                    ProviderRecoveryRevoked revokedGeneration _ recorded confirmed
                      | revokedGeneration == recordedGeneration && recorded == audit && confirmed == receipt ->
                          first (Text.pack . show) (confirmProviderCredentialRetirement requested actual)
                    _ ->
                      Left
                        ( "the credential revoke has no independently observed epoch receipt: "
                            <> fromLeft "the epoch has no matching revoked receipt" attempted
                        )
                  Left detail -> Left ("the credential-revocation epoch cannot be observed: " <> detail)
      ProviderRecoveryLegacyServingUnbound -> refuse
      ProviderRecoveryServing _ -> refuse
      ProviderRecoveryOrdinaryCredentialRetired _ -> refuse
      ProviderRecoveryFrozen {} -> refuse
      ProviderRecoveryRecorded {} -> refuse
  confirmAbsent actual = do
    observed <- generation
    pure $ case observed of
      Right Nothing -> first (Text.pack . show) (confirmProviderCredentialRetirement requested actual)
      _ -> Left "the revoked cascade epoch has no fresh Target-absence confirmation"
  refuse = pure (Left "credential retirement requires the exact recorded clean terminal audit")

observeAuditEpoch
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> IO (Either Text (CascadeAuditFreezeBinding, ProviderAdmissionRecoveryObservation))
observeAuditEpoch runtime running compiled = case auditBindingFor running compiled of
  Left detail -> pure (Left detail)
  Right requested -> readCascadeAuditEpoch (cascadePreUninstallEpoch runtime) requested

readCascadeAuditEpoch
  :: CascadeAuditEpochBoundary
  -> CascadeAuditFreezeBinding
  -> IO (Either Text (CascadeAuditFreezeBinding, ProviderAdmissionRecoveryObservation))
readCascadeAuditEpoch boundary requested = do
  observed <-
    auditEpochObserve boundary requested
  pure $ do
    actual <- observed
    binding <- case providerAdmissionRecoveryPhase actual of
      ProviderRecoveryLegacyServingUnbound -> Right requested
      ProviderRecoveryServing _ -> Right requested
      ProviderRecoveryOrdinaryCredentialRetired _ -> Left "the ordinary credential is retired; resume credential installation before this cascade"
      ProviderRecoveryFrozen {} -> first (Text.pack . show) (restoreCascadeAuditRecoveryBinding requested actual)
      ProviderRecoveryRecorded {} -> first (Text.pack . show) (restoreCascadeAuditRecoveryBinding requested actual)
      ProviderRecoveryRevoked {} -> first (Text.pack . show) (restoreCascadeAuditRecoveryBinding requested actual)
    Right (binding, actual)

cascadeAuditRetainedNames
  :: CompiledDesiredAbsenceProgram surface -> Either Text RetainedNameBinding
cascadeAuditRetainedNames compiled =
  maybe
    (Left "the cascade program has no sealed retained audit names")
    Right
    ( evidenceResourceScopeBindings (compiledDesiredAbsenceObservationScope compiled)
        >>= resourceScopeAuditRetainedNames
    )

auditBindingFor
  :: DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram surface
  -> Either Text CascadeAuditFreezeBinding
auditBindingFor running compiled = do
  retained <- cascadeAuditRetainedNames compiled
  nodeId <- case [ node
                 | (node, SomeTeardownOperation AuditCascadeEscapes) <- compiledDesiredAbsenceOperations compiled
                 ] of
    [node] -> Right node
    _ -> Left "the exact cascade terminal-audit node is missing or duplicated"
  plan <-
    maybe
      (Left "the cascade terminal-audit plan is missing")
      Right
      (find ((== nodeId) . cleanupNodeId) (cleanupGraphNodes (descriptorBoundCleanupRunGraph running)))
  attempt <- case Map.lookup nodeId (descriptorBoundCleanupRunNodeStates running) of
    Just (CleanupNodeRunning selected) -> Right selected
    Just (CleanupNodeCompleted selected CleanupNodeSucceeded) -> Right selected
    _ -> Left "the cascade terminal audit has no running or successful attempt"
  let operationId = cleanupNodeOperationId plan
  awsScope <-
    maybe
      (Left "cascade audit reservation has no AWS scope")
      Right
      (evidenceAwsScope (compiledDesiredAbsenceObservationScope compiled))
  keys <-
    mapM
      ( \query ->
          first
            (Text.pack . show)
            ( providerDispatchSubmissionKey
                <$> mkFencedTerminalAuditProviderDispatchKey operationId query
            )
      )
      ( ObserveProviderAwsScope
          : map
            perRunAuditQueryProviderIntent
            (terminalAuditEndpointQueriesFor awsScope retained)
      )
  first
    (Text.pack . show)
    ( mkCascadeAuditFreezeBinding
        (descriptorBoundCleanupRunId running)
        (descriptorBoundCleanupRunDescriptorDigest running)
        (descriptorBoundCleanupRunGraphDigest running)
        ( terminalAuditEvidenceScopeDigest
            (scopeForCascadeTerminalAudit (compiledDesiredAbsenceObservationScope compiled))
        )
        nodeId
        operationId
        attempt
        (sort keys)
    )

-- | One production protocol for freeze/read, queries, record/read. A write
-- acknowledgement cannot admit queries or stand in for the durable receipt.
runConfirmedCascadeAudit
  :: CascadeAuditEpochBoundary
  -> IO (Either Text (Maybe Natural))
  -> CascadeAuditFreezeBinding
  -> IO (Either Text (TerminalAuditObservation 'Cascade))
  -> IO (Either Text (TerminalAuditObservation 'Cascade))
runConfirmedCascadeAudit boundary generation requested queries = do
  prepared <- prepareCascadeAuditEpoch boundary generation requested
  case prepared of
    Left detail -> pure (Left detail)
    Right binding -> do
      observed <- queries
      case observed of
        Left detail -> pure (Left detail)
        Right exact -> case cascadeTerminalAuditReceiptFor exact of
          Left err -> pure (Left (Text.pack (show err)))
          Right receipt -> do
            recorded <- recordCascadeAuditEpoch boundary binding receipt
            pure (exact <$ recorded)

prepareCascadeAuditEpoch
  :: CascadeAuditEpochBoundary
  -> IO (Either Text (Maybe Natural))
  -> CascadeAuditFreezeBinding
  -> IO (Either Text CascadeAuditFreezeBinding)
prepareCascadeAuditEpoch boundary observeGeneration requested = do
  recovered <- readCascadeAuditEpoch boundary requested
  case recovered of
    Left detail -> pure (Left detail)
    Right (binding, observed) -> case providerAdmissionRecoveryPhase observed of
      ProviderRecoveryLegacyServingUnbound -> freezeCurrent binding
      ProviderRecoveryServing _ -> freezeCurrent binding
      ProviderRecoveryOrdinaryCredentialRetired _ ->
        pure
          (Left "the ordinary credential is retired; resume credential installation before the terminal audit")
      ProviderRecoveryFrozen {} -> freezeCurrent binding
      ProviderRecoveryRecorded {} -> freezeCurrent binding
      ProviderRecoveryRevoked {} -> pure (Left "the credential is already revoked; no new pre-uninstall audit is admitted")
 where
  freezeCurrent binding = do
    generation <- observeGeneration
    case generation of
      Left detail -> pure (Left detail)
      Right Nothing -> pure (Left "the Lifecycle-provider Target is absent before the terminal audit")
      Right (Just current) -> do
        attempted <-
          auditEpochSubmit
            boundary
            (AuthorityControlFreezeProviderAdmissionAtGeneration current binding)
        checked <-
          auditEpochObserve boundary binding
        pure $ case checked of
          Right actual
            | frozenAt current (providerAdmissionRecoveryPhase actual) ->
                first (Text.pack . show) (restoreCascadeAuditRecoveryBinding binding actual)
          _ ->
            Left
              ( "the cascade audit freeze is not independently confirmed: "
                  <> fromLeft "the epoch remained outside its expected frozen/recorded generation" attempted
              )
  frozenAt wanted phase = case phase of
    ProviderRecoveryFrozen generation _ -> generation == wanted
    ProviderRecoveryRecorded generation _ _ -> generation == wanted
    ProviderRecoveryLegacyServingUnbound -> False
    ProviderRecoveryServing _ -> False
    ProviderRecoveryOrdinaryCredentialRetired _ -> False
    ProviderRecoveryRevoked {} -> False

recordCascadeAuditEpoch
  :: CascadeAuditEpochBoundary
  -> CascadeAuditFreezeBinding
  -> CascadeTerminalAuditReceipt
  -> IO (Either Text ())
recordCascadeAuditEpoch boundary binding receipt = do
  attempted <-
    auditEpochSubmit
      boundary
      (AuthorityControlRecordCascadeTerminalAuditReceipt binding receipt)
  observed <-
    auditEpochObserve boundary binding
  pure $ case observed of
    Right actual
      | confirms (providerAdmissionRecoveryPhase actual) -> Right ()
      | otherwise -> refused attempted
    Left _ -> refused attempted
 where
  confirms phase = case phase of
    ProviderRecoveryRecorded _ _ recorded -> recorded == receipt
    ProviderRecoveryLegacyServingUnbound -> False
    ProviderRecoveryServing _ -> False
    ProviderRecoveryOrdinaryCredentialRetired _ -> False
    ProviderRecoveryFrozen {} -> False
    ProviderRecoveryRevoked {} -> False

  refused attempted =
    Left
      ( "the terminal-audit receipt is not independently confirmed: "
          <> fromLeft "the epoch has no matching recorded audit" attempted
      )

persistReady
  :: CascadePreUninstallRuntime
  -> ReadyToUninstallEvidence
  -> IO (Either Text ())
persistReady runtime ready = do
  observed <- observeHostCleanupIntentForResume (cascadePreUninstallHostStore runtime)
  case observed of
    Left err -> pure (Left (Text.pack (show err)))
    Right Nothing -> pure (Left "cascade host-cleanup intent is missing")
    Right (Just exact) -> do
      let intent = observedHostCleanupIntent exact
      persisted <-
        persistHostCleanupReady
          (cascadePreUninstallHostStore runtime)
          intent
          ready
      case persisted of
        Left err -> pure (Left (Text.pack (show err)))
        Right _ -> do
          readBack <- observeHostCleanupIntentForResume (cascadePreUninstallHostStore runtime)
          pure $ case readBack of
            Left err -> Left (Text.pack (show err))
            Right Nothing -> Left "cascade host-cleanup Ready binding disappeared"
            Right (Just durable) -> do
              restored <- first (Text.pack . show) (restoreObservedHostCleanupReady durable)
              matches <-
                first
                  (Text.pack . show)
                  (hostCleanupReadyMatches (observedHostCleanupIntent durable) restored)
              if restored == ready && matches
                then Right ()
                else Left "cascade host-cleanup Ready binding read-back mismatched"

-- | Fixed I/O-boundary checks over the production orchestration and the real
-- epoch fold. No epoch, evidence, effect record or caller callback escapes.
data AuditEpochScenario
  = EpochNormal
  | EpochFreezeResponseLost
  | EpochFreezeNotWritten
  | EpochPendingWork
  | EpochRecordResponseLost
  | EpochRecordNotWritten
  | EpochGenerationChanged
  | EpochAlreadyRevoked
  | EpochPriorLeaseAttempt
  | EpochAlreadyRecorded
  | EpochQueryUnobservable
  deriving (Bounded, Enum, Eq, Show)

fixedCascadePreUninstallEpochChecks :: IO (Either Text [(Text, Bool)])
fixedCascadePreUninstallEpochChecks =
  case withFixedCascadeEvidenceFixtureInternal (\compiled initial _ _ _ -> checks compiled initial) of
    Left detail -> pure (Left detail)
    Right action -> action
 where
  checks compiled initial = case setup compiled initial of
    Left detail -> pure (Left detail)
    Right (retained, binding, replacementBinding, initialAggregate, awsScope) -> do
      baseline <-
        observeFullCascadeTerminalAudit
          (CascadeTerminalAuditFullBoundary (pure (Right awsScope)) (\_ -> pure (Right [])))
          retained
          compiled
          (ObservationRevision 1)
      case first (Text.pack . show) baseline >>= first (Text.pack . show) . cascadeTerminalAuditReceiptFor of
        Left detail -> pure (Left detail)
        Right cleanReceipt -> do
          results <-
            mapM
              (check compiled retained binding replacementBinding cleanReceipt initialAggregate awsScope)
              [minBound .. maxBound]
          retirements <-
            mapM
              (checkCredentialRetirement binding replacementBinding cleanReceipt initialAggregate)
              [minBound .. maxBound]
          pure (Right (results ++ retirements))

  setup compiled initial = do
    retained <-
      first
        (Text.pack . show)
        ( mkRetainedNameBinding
            "prodbox-fixed-state"
            "prodbox-fixed-ses-capture"
            "fixed.example.test"
            "aws-eks-test-cluster"
        )
    descriptor <- first (Text.pack . show) (captureCleanupProgramDescriptor compiled initial)
    node <- case [ nodeId
                 | (nodeId, SomeTeardownOperation AuditCascadeEscapes) <- compiledDesiredAbsenceOperations compiled
                 ] of
      [nodeId] ->
        maybe
          (Left "fixed audit plan missing")
          Right
          (find ((== nodeId) . cleanupNodeId) (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)))
      _ -> Left "fixed audit operation missing"
    awsScope <-
      maybe
        (Left "fixed audit has no AWS scope")
        Right
        (evidenceAwsScope (compiledDesiredAbsenceObservationScope compiled))
    keys <-
      mapM
        ( \query ->
            first
              (Text.pack . show)
              ( providerDispatchSubmissionKey
                  <$> mkFencedTerminalAuditProviderDispatchKey
                    (cleanupNodeOperationId node)
                    query
              )
        )
        ( ObserveProviderAwsScope
            : map perRunAuditQueryProviderIntent (terminalAuditEndpointQueriesFor awsScope retained)
        )
    firstAttempt <- mkCleanupAttemptId "cascade-epoch-fixture/original"
    secondAttempt <- mkCleanupAttemptId "cascade-epoch-fixture/second-lease"
    let bind attempt =
          first
            (Text.pack . show)
            ( mkCascadeAuditFreezeBinding
                (cleanupRunId initial)
                (cleanupProgramDescriptorDigest descriptor)
                (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled))
                ( terminalAuditEvidenceScopeDigest
                    (scopeForCascadeTerminalAudit (compiledDesiredAbsenceObservationScope compiled))
                )
                (cleanupNodeId node)
                (cleanupNodeOperationId node)
                attempt
                (sort keys)
            )
    binding <- bind firstAttempt
    replacement <- bind secondAttempt
    initialAggregate <- first (Text.pack . show) (initialCleanInstallAuthority 1 1)
    Right (retained, binding, replacement, initialAggregate, awsScope)

  check compiled retained binding replacement cleanReceipt legacy awsScope scenario = do
    let transition command current = case stepAuthorityAdmission current command of
          (AuthorityAdmissionCommandRefused refusal, _) -> Left (Text.pack (show refusal))
          (_, next) -> Right next
        initial = case scenario of
          EpochGenerationChanged -> transition (BindProviderAdmissionGeneration 7) legacy
          EpochPriorLeaseAttempt -> frozen
          EpochAlreadyRecorded -> recorded
          EpochAlreadyRevoked -> do
            before <- recorded
            proof <-
              first
                (Text.pack . show)
                ( mkProviderCredentialRevocationReceipt
                    (cleanupDigestOfBytes "fixed IAM absence")
                    (cleanupDigestOfBytes "fixed Target absence")
                )
            transition (RevokeCascadeProviderCredential binding proof) before
          EpochNormal -> Right legacy
          EpochFreezeResponseLost -> Right legacy
          EpochFreezeNotWritten -> Right legacy
          EpochPendingWork -> Right legacy
          EpochRecordResponseLost -> Right legacy
          EpochRecordNotWritten -> Right legacy
          EpochQueryUnobservable -> Right legacy
        frozen = transition (FreezeProviderAdmissionAtGeneration 7 binding) legacy
        recorded =
          frozen >>= \before -> transition (RecordCascadeTerminalAuditReceipt binding cleanReceipt) before
    case initial of
      Left detail -> pure (Text.pack (show scenario) <> ": " <> detail, False)
      Right initialEpoch -> do
        epoch <- newIORef initialEpoch
        queryCount <- newIORef (0 :: Int)
        let observe requested = do
              current <- readIORef epoch
              pure $ case stepAuthorityAdmission current (ObserveProviderAdmissionRecovery requested) of
                (AuthorityProviderAdmissionRecoveryObserved observation, _) -> Right observation
                (other, _) -> Left (Text.pack (show other))
            publish omit responseLost changed = case first (Text.pack . show) changed of
              Left detail -> pure (Left detail)
              Right next
                | omit -> pure (Right "acknowledged without a durable write")
                | otherwise -> do
                    writeIORef epoch next
                    pure (if responseLost then Left "applied; response lost" else Right "committed")
            submit payload = do
              current <- readIORef epoch
              case payload of
                AuthorityControlFreezeProviderAdmissionAtGeneration generation requested ->
                  if scenario == EpochPendingWork
                    then pure (Left "fixed pending-Provider refusal")
                    else
                      publish
                        (scenario == EpochFreezeNotWritten)
                        (scenario == EpochFreezeResponseLost)
                        (transition (FreezeProviderAdmissionAtGeneration generation requested) current)
                AuthorityControlRecordCascadeTerminalAuditReceipt requested receipt ->
                  publish
                    (scenario == EpochRecordNotWritten)
                    (scenario == EpochRecordResponseLost)
                    (transition (RecordCascadeTerminalAuditReceipt requested receipt) current)
                _ -> pure (Left "the fixed audit interpreter admits only freeze and record")
            boundary = CascadeAuditEpochBoundary submit observe
            candidateBinding = if scenario == EpochPriorLeaseAttempt then replacement else binding
            beforeQuery = do
              modifyIORef' queryCount (+ 1)
              current <- observe binding
              pure $ case current of
                Right observation -> phaseAdmitsQueries (providerAdmissionRecoveryPhase observation)
                Left _ -> False
            queries =
              first (Text.pack . show)
                <$> observeFullCascadeTerminalAudit
                  ( CascadeTerminalAuditFullBoundary
                      ( do
                          admitted <- beforeQuery
                          pure
                            ( if admitted
                                then Right awsScope
                                else Left (ObservationFailure "identity read preceded the durable freeze")
                            )
                      )
                      ( \_ -> do
                          admitted <- beforeQuery
                          pure
                            ( if not admitted || scenario == EpochQueryUnobservable
                                then Left (ObservationFailure "fixed endpoint query could not be observed")
                                else Right []
                            )
                      )
                  )
                  retained
                  compiled
                  (ObservationRevision 1)
        outcome <-
          runConfirmedCascadeAudit
            boundary
            (pure (Right (Just (if scenario == EpochGenerationChanged then 8 else 7))))
            candidateBinding
            queries
        count <- readIORef queryCount
        actual <- observe binding
        let success = case (outcome, actual) of
              (Right _, Right observation) -> case providerAdmissionRecoveryPhase observation of
                ProviderRecoveryRecorded 7 _ receipt -> receipt == cleanReceipt
                _ -> False
              _ -> False
            refused = case outcome of Left _ -> True; Right _ -> False
            completeQueries = count == 1 + length (terminalAuditEndpointQueriesFor awsScope retained)
            passed = case scenario of
              EpochNormal -> success && completeQueries
              EpochFreezeResponseLost -> success && completeQueries
              EpochRecordResponseLost -> success && completeQueries
              EpochPriorLeaseAttempt -> success && completeQueries
              EpochAlreadyRecorded -> success && completeQueries
              EpochFreezeNotWritten -> refused && count == 0
              EpochPendingWork -> refused && count == 0
              EpochGenerationChanged -> refused && count == 0
              EpochAlreadyRevoked -> refused && count == 0
              EpochRecordNotWritten -> refused && completeQueries
              EpochQueryUnobservable -> case (outcome, actual) of
                (Right _, Right observation) -> case providerAdmissionRecoveryPhase observation of
                  ProviderRecoveryRecorded 7 _ receipt -> case cascadeTerminalAuditReceiptVerdict receipt of
                    CascadeTerminalAuditReceiptUnobservable failures -> failures > 0 && completeQueries
                    _ -> False
                  _ -> False
                _ -> False
        pure (Text.pack (show scenario), passed)

  phaseAdmitsQueries phase = case phase of
    ProviderRecoveryFrozen 7 _ -> True
    ProviderRecoveryRecorded 7 _ _ -> True
    ProviderRecoveryLegacyServingUnbound -> False
    ProviderRecoveryServing _ -> False
    ProviderRecoveryOrdinaryCredentialRetired _ -> False
    ProviderRecoveryFrozen _ _ -> False
    ProviderRecoveryRecorded {} -> False
    ProviderRecoveryRevoked {} -> False

data CredentialRetirementScenario
  = RetirementNormal
  | RetirementControlResponseLost
  | RetirementControlNotWritten
  | RetirementReadUnobservable
  | RetirementEffectFailed
  | RetirementUnrecorded
  | RetirementAuditUnobservable
  | RetirementAlreadyRevoked
  | RetirementTargetPresent
  | RetirementTargetUnobservable
  | RetirementWrongReceipt
  | RetirementPriorLeaseAttempt
  | RetirementEffectReplyLost
  | RetirementEffectReplyLostTargetPresent
  | RetirementEffectReplyLostTargetUnobservable
  | RetirementEffectReplyLostReadUnobservable
  deriving (Eq, Show, Enum, Bounded)

checkCredentialRetirement
  :: CascadeAuditFreezeBinding
  -> CascadeAuditFreezeBinding
  -> CascadeTerminalAuditReceipt
  -> AuthorityAdmissionAggregate
  -> CredentialRetirementScenario
  -> IO (Text, Bool)
checkCredentialRetirement binding replacement clean initial scenario =
  case prepared of
    Left detail -> pure (label <> ": " <> detail, False)
    Right aggregate -> do
      current <- newIORef aggregate
      revocations <- newIORef (0 :: Int)
      writes <- newIORef (0 :: Int)
      let observe requested = do
            state <- readIORef current
            written <- readIORef writes
            pure $
              if (scenario == RetirementReadUnobservable && written > 0)
                || (scenario == RetirementEffectReplyLostReadUnobservable && providerEpochRevoked state)
                then Left "read-back unavailable"
                else case stepAuthorityAdmission state (ObserveProviderAdmissionRecovery requested) of
                  (AuthorityProviderAdmissionRecoveryObserved actual, _) -> Right actual
                  (other, _) -> Left (Text.pack (show other))
          submit payload = do
            modifyIORef' writes (+ 1)
            state <- readIORef current
            case payload of
              AuthorityControlRevokeCascadeProviderCredential requested receipt ->
                let selected =
                      if scenario == RetirementWrongReceipt
                        then
                          first
                            (Text.pack . show)
                            ( mkProviderCredentialRevocationReceipt
                                (cleanupDigestOfBytes "different IAM attestation")
                                (cleanupDigestOfBytes "different Agent evidence")
                            )
                        else Right receipt
                 in case selected >>= \actual -> transition (RevokeCascadeProviderCredential requested actual) state of
                      Left detail -> pure (Left detail)
                      Right next
                        | scenario == RetirementControlNotWritten -> pure (Right "acknowledged without a write")
                        | otherwise -> do
                            writeIORef current next
                            pure
                              (if scenario == RetirementControlResponseLost then Left "applied; reply lost" else Right "committed")
              _ -> pure (Left "unexpected control mutation")
          revoke = do
            modifyIORef' revocations (+ 1)
            if scenario
              `elem` [ RetirementEffectReplyLost
                     , RetirementEffectReplyLostTargetPresent
                     , RetirementEffectReplyLostTargetUnobservable
                     , RetirementEffectReplyLostReadUnobservable
                     ]
              then do
                state <- readIORef current
                case proof >>= \receipt -> transition (RevokeCascadeProviderCredential binding receipt) state of
                  Left detail -> pure (Left detail)
                  Right committed -> writeIORef current committed >> pure (Left "revocation committed; callback reply lost")
              else pure (if scenario == RetirementEffectFailed then Left "IAM absence unavailable" else proof)
          generation = pure $ case scenario of
            RetirementTargetPresent -> Right (Just 7)
            RetirementTargetUnobservable -> Left "Target cannot be read"
            RetirementEffectReplyLostTargetPresent -> Right (Just 7)
            RetirementEffectReplyLostTargetUnobservable -> Left "Target cannot be read"
            _ -> Right Nothing
      let requested = if scenario == RetirementPriorLeaseAttempt then replacement else binding
      before <- observe requested
      outcome <- case before of
        Left detail -> pure (Left detail)
        Right observation ->
          retireConfirmedCascadeCredential
            (CascadeAuditEpochBoundary submit observe)
            generation
            revoke
            requested
            observation
      revokeCount <- readIORef revocations
      writeCount <- readIORef writes
      after <- observe requested
      let succeeded = case (outcome, after) of
            (Right confirmation, Right observed) -> confirmProviderCredentialRetirement requested observed == Right confirmation
            _ -> False
          expected = case scenario of
            RetirementNormal -> (True, 1, 1)
            RetirementControlResponseLost -> (True, 1, 1)
            RetirementControlNotWritten -> (False, 1, 1)
            RetirementReadUnobservable -> (False, 1, 1)
            RetirementEffectFailed -> (False, 1, 0)
            RetirementUnrecorded -> (False, 0, 0)
            RetirementAuditUnobservable -> (False, 0, 0)
            RetirementAlreadyRevoked -> (True, 0, 0)
            RetirementTargetPresent -> (False, 0, 0)
            RetirementTargetUnobservable -> (False, 0, 0)
            RetirementWrongReceipt -> (False, 1, 1)
            RetirementPriorLeaseAttempt -> (True, 1, 1)
            RetirementEffectReplyLost -> (True, 1, 0)
            RetirementEffectReplyLostTargetPresent -> (False, 1, 0)
            RetirementEffectReplyLostTargetUnobservable -> (False, 1, 0)
            RetirementEffectReplyLostReadUnobservable -> (False, 1, 0)
      pure (label, (succeeded, revokeCount, writeCount) == expected)
 where
  label = Text.pack (show scenario)
  providerEpochRevoked state = case authorityAggregateProviderAdmissionEpochView state of
    ProviderAdmissionCascadeCredentialRevoked _ -> True
    _ -> False
  transition command state = case stepAuthorityAdmission state command of
    (AuthorityAdmissionCommandRefused refusal, _) -> Left (Text.pack (show refusal))
    (_, next) -> Right next
  proof =
    first
      (Text.pack . show)
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "actual IAM attestation")
          (cleanupDigestOfBytes "actual Agent evidence")
      )
  prepared = do
    frozen <- transition (FreezeProviderAdmissionAtGeneration 7 binding) initial
    audit <-
      if scenario == RetirementAuditUnobservable
        then
          first
            (Text.pack . show)
            ( mkCascadeTerminalAuditReceipt
                (cascadeTerminalAuditReceiptScopeDigest clean)
                (cascadeTerminalAuditReceiptQueryDigest clean)
                (cascadeTerminalAuditReceiptRetainedSetDigest clean)
                (CascadeTerminalAuditReceiptUnobservable 1)
            )
        else Right clean
    recorded <- transition (RecordCascadeTerminalAuditReceipt binding audit) frozen
    receipt <- proof
    case scenario of
      RetirementUnrecorded -> Right frozen
      RetirementAlreadyRevoked -> transition (RevokeCascadeProviderCredential binding receipt) recorded
      RetirementTargetPresent -> transition (RevokeCascadeProviderCredential binding receipt) recorded
      RetirementTargetUnobservable -> transition (RevokeCascadeProviderCredential binding receipt) recorded
      RetirementWrongReceipt -> Right recorded
      _ -> Right recorded
