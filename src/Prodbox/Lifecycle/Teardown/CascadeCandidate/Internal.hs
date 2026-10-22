{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the non-public candidate entrypoint for the recover-to-clean
-- cascade.
--
-- Both closed runtimes the descriptor-bound dispatcher takes are constructible
-- — the cascade host runtime from
-- "Prodbox.Lifecycle.HostCleanupCompositionRoot" and the cloud runtime from
-- "Prodbox.Lifecycle.Teardown.CloudRuntimeProduction" — and nothing drove the
-- dispatcher over a durable run.  This module is that drive.  It is
-- package-private, and its facade exposes only non-authorizing booleans: Sprint
-- @6.5@ owns activating a public writer.  The one caller is
-- "Prodbox.Test.CascadeQualification", which drives it under a named
-- qualification cycle and holds no writer permit of either kind; no public
-- command reaches it.
--
-- Six properties carry the design.
--
--   * __Caller-declared identity is validated before a session is opened.__
--     AWS account and region are deliberately not caller fields: after the
--     retained Authority session opens, one exact @ObserveProviderAwsScope@
--     completion supplies them.  Only its confirmed canonical receipt may be
--     promoted into the scope used to compile the program.
--
--   * __The plan is a function of the declared identity, so re-entry replays.__
--     The program descriptor digests the initial run, and the initial run's
--     lease is a /declared/ window rather than a clock sample.  Two entries
--     with the same inputs therefore derive the same descriptor, and the
--     Authority replays the run it already holds instead of admitting a second
--     one for the same cascade.  Sampling a clock here would make every resume
--     a different program.
--
--   * __One repository root and one caller for both halves.__  The cloud half's
--     Provider dispatch and the host half's Authority session are derived from
--     the same composition inputs, because a cloud half authenticating as a
--     different caller than the host half would be two cascades sharing a run
--     id.
--
--   * __The terminal identity is compiled, not authored.__  The host intent's
--     terminal operation is the operation id the compiled program gave its
--     @UninstallCascadeLocalFoundation@ node, so the durable host record and
--     the graph cannot disagree about which node is allowed to destroy the
--     host.
--
--   * __A recorded primary outcome is immutable on resume.__  A vacant fresh
--     run records success because the cascade is its own primary work.  An
--     expired-owner takeover instead preserves the kernel's runner-lost fact
--     (or any other already-recorded outcome) and resumes cleanup.  The final
--     report therefore remains non-qualifying without stranding the graph.
--     The fresh primary fact is attached before claiming the epoch-time lease:
--     the descriptor's stable initial lease is a declared window relative to
--     zero, so claiming it first would misclassify every new cascade as an
--     expired predecessor.
--
-- What this module does not own: the content of any node, which belongs to the
-- runtime that answers it; the public @cluster delete --cascade@ route, which
-- Sprint @6.5@ cuts over; and the decision to run at all, which belongs to the
-- operator who names a qualification cycle rather than to any command.
module Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal
  ( -- * What the caller supplies
    CascadeCandidateInputs (..)
  , CascadeCandidateEnvironment (..)

    -- * The transport-free half
  , CascadeCandidatePlan
  , cascadeCandidatePlanRunId
  , cascadeCandidatePlanGraphDigest
  , cascadeCandidatePlanDescriptorDigest
  , cascadeCandidatePlanTerminalOperationId
  , resolveCascadeCandidatePlan

    -- * What can go wrong
  , CascadeCandidateError (..)
  , renderCascadeCandidateError

    -- * The drive
  , CascadeCandidateOutcome (..)
  , runCascadeCandidate
  , CascadeCandidateHostResume
  , observeCascadeCandidateHostResume
  , cascadeCandidateHostResumeInputs
  , runCascadeCandidateHostResume

    -- * Non-authorizing diagnostics
  , CascadeCandidateRegression
  , fixedCascadeCandidateRegression
  , fixedCascadeCandidateEpochChecks
  , cascadeCandidatePlanIsDeterministic
  , cascadeCandidateTerminalOperationIsCompiled
  , cascadeCandidateDeclaredLeaseIsRequired
  , cascadeCandidateIdentityBindsDescriptor
  , cascadeCandidatePreservesRecordedPrimaryOutcome
  , cascadeCandidateFreshPrimarySurvivesDeclaredLeaseClaim
  , CascadeCandidatePlanSummary (..)
  , fixedCascadeCandidatePlanSummary
  , cascadeCandidateShapeSummary
  )
where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError
  , dispatchAuthorityProviderIntentWithOperation
  )
import Prodbox.ControlPlane.CascadeHostRuntime.Internal
  ( mkCascadeHostRuntime
  )
import Prodbox.ControlPlane.CascadePreUninstallRuntime.Internal
  ( fixedCascadePreUninstallEpochChecks
  , mkCascadePreUninstallRuntime
  , retireCascadePreUninstallCredentialInternal
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunPrimaryOutcome
  )
import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
  ( descriptorBoundLifecycleNodeActionInternal
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( ProviderAwsScopeReceiptError
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeRegion
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal
  ( verifySettledAuthorityProviderAwsScopeReceipt
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , ClientSubmissionKeyError
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupLease (..)
  , CleanupOperationId
  , CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRunError
  , CleanupRunId
  , claimCleanupRun
  , cleanupDigestText
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunIdText
  , cleanupRunLease
  , cleanupRunPrimaryOutcome
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  , recordPrimaryOutcome
  )
import Prodbox.Lifecycle.CleanupRunEntry
  ( CleanupHostPreparation (PrepareHostUninstallRecord)
  , LifecycleCleanupClientError
  , LifecycleCleanupDescriptor
  , LifecycleCleanupDescriptorError
  , LifecycleCleanupResult (LifecycleCleanupReportObserved)
  , RegisteredLifecycleCleanup
  , attachLifecycleCleanupPrimaryOutcome
  , claimLifecycleCleanupRun
  , lifecycleCleanupDescriptorHostIntent
  , lifecycleCleanupDescriptorInitialRun
  , lifecycleCleanupDescriptorProgramDescriptor
  , mkLifecycleCleanupDescriptor
  , observeLifecycleCleanupResult
  , registerLifecycleCleanupRun
  , registeredLifecycleCleanupBoundRun
  , retireTerminalLifecycleCleanupHostIntent
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError
  , DescriptorBoundCleanupProgress (..)
  , resumeDescriptorBoundCleanupBeforeLocalUninstall
  )
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
  ( HarnessCredentialRevocationEvidence
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( HostCleanupCompositionError
  , HostCleanupCompositionInputs (..)
  , HostCleanupLocalComposition
  , HostCleanupProductionRuntime (..)
  , HostCleanupTerminalComposition
  , hostCleanupLocalIntentStore
  , hostCleanupLocalTerminalComposition
  , hostCleanupTerminalIntentStore
  , hostCleanupTerminalRunnerEffects
  , renderHostCleanupCompositionError
  , resolveHostCleanupLocalComposition
  , resolveHostCleanupTerminalComposition
  , withHostCleanupProductionSources
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntent
  , HostCleanupIntentError
  , HostCleanupIntentPhase (..)
  , HostCleanupTerminalHandoff
  , HostTerminalPermitId
  , hostCleanupFoundationId
  , hostCleanupGraphDigest
  , hostCleanupIntentPhase
  , hostCleanupObservationEvidenceScope
  , hostCleanupRun
  , hostCleanupRunId
  , hostCleanupScope
  , hostCleanupTerminalHandoffDescriptorDigest
  , hostCleanupTerminalHandoffIntent
  , hostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , hostCleanupTerminalPermitId
  , mkHostCleanupIntent
  , mkHostTerminalPermitId
  , observeHostCleanupIntent
  , observeHostCleanupTerminalHandoff
  , persistHostCleanupTerminalHandoff
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerError
  , runHostCleanupTerminalHandoff
  , stepHostCleanupRunner
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( cleanupProgramDescriptorDigest
  )
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( EksDrainLeaseSeconds
  , ProductionCloudRuntimeError
  , ProductionCloudRuntimeInputs (..)
  , productionCloudRuntime
  , renderProductionCloudRuntimeError
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , DesiredAbsenceGraphError
  , compileDesiredAbsenceGraphWithBindings
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  , LinuxRke2FoundationId (..)
  , evidenceAwsDnsZone
  , evidenceAwsScope
  , evidenceResourceScopeBindings
  )
import Prodbox.Lifecycle.Teardown.Program
  ( SomeTeardownOperation (SomeTeardownOperation)
  , TeardownOperation (UninstallCascadeLocalFoundation)
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( productionTeardownProviderBoundary
  )
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
  ( InviteMailSelector (ValidationInviteDomain)
  , ResourceScopeBindings
  , emptyResourceScopeBindings
  , mkHomeDns01Scope
  , mkInviteMailScope
  , mkResourceScopeBindingsWithAudit
  , resourceScopeAuditRetainedNames
  , resourceScopeHomeDns01
  , resourceScopeInviteMail
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory (mkRetainedNameBinding)
import Prodbox.Settings.Coordinate (mkS3BucketName)

-- ---------------------------------------------------------------------------
-- What the caller supplies
-- ---------------------------------------------------------------------------

-- | The identity of one cascade.  Every field is declared rather than
-- observed, which is what makes the resulting plan a function of its inputs.
data CascadeCandidateInputs = CascadeCandidateInputs
  { cascadeCandidateRunId :: !CleanupRunId
  , cascadeCandidateOwner :: !CleanupOwnerId
  , cascadeCandidateFoundation :: !LinuxRke2FoundationId
  , cascadeCandidateAwsDnsZone :: !(Maybe HostedZoneId)
  , cascadeCandidateResourceScopeBindings :: !ResourceScopeBindings
  , cascadeCandidateTerminalPermitId :: !HostTerminalPermitId
  , cascadeCandidateDeclaredLeaseMicros :: !Natural
  -- ^ The initial run's declared lease window.  It is digested into the
  -- program descriptor, so it must be a declaration: a clock sample here
  -- would give every resume a different program identity.
  }

-- | Everything the two halves need from the host they run on.
--
-- The repository root and the authenticated caller live in the host
-- composition inputs and are read from there by the cloud half, so the two
-- cannot name different identities.
data CascadeCandidateEnvironment = CascadeCandidateEnvironment
  { cascadeCandidateComposition :: !HostCleanupCompositionInputs
  , cascadeCandidateRevokeProviderCredential :: !(IO (Either Text HarnessCredentialRevocationEvidence))
  , cascadeCandidateKubectlPath :: !FilePath
  , cascadeCandidateKubectlEnvironment :: ![(String, String)]
  , cascadeCandidateKubectlWorkingDirectory :: !(Maybe FilePath)
  , cascadeCandidateDrainLease :: !EksDrainLeaseSeconds
  , cascadeCandidateLeaseWindowMicros :: !Natural
  -- ^ How far past @now@ the Authority lease is claimed for.
  , cascadeCandidateReportRetentionMicros :: !Natural
  -- ^ The retention the terminal compaction is asked for.
  }

-- | The observed production identity and exact plan digests returned beside
-- the terminal lifecycle result.  Keeping this package-private lets the
-- qualification recorder bind its artifact to the scope the Authority
-- actually signed without giving a public caller a way to author that scope.
data CascadeCandidateOutcome = CascadeCandidateOutcome
  { cascadeCandidateOutcomeAwsScope :: !AwsScope
  , cascadeCandidateOutcomeGraphDigest :: !CleanupDigest
  , cascadeCandidateOutcomeDescriptorDigest :: !CleanupDigest
  , cascadeCandidateOutcomeLifecycleResult :: !LifecycleCleanupResult
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The transport-free half
-- ---------------------------------------------------------------------------

-- | The compiled program and its canonical bindings, resolved with no
-- transport, no store, and no clock.
data CascadeCandidatePlan = CascadeCandidatePlan
  { internalCandidateProgram :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , internalCandidateDescriptor :: !(LifecycleCleanupDescriptor 'Cascade)
  , internalCandidateRunId :: !CleanupRunId
  , internalCandidateGraphDigest :: !CleanupDigest
  }

cascadeCandidatePlanRunId :: CascadeCandidatePlan -> CleanupRunId
cascadeCandidatePlanRunId = internalCandidateRunId

cascadeCandidatePlanGraphDigest :: CascadeCandidatePlan -> CleanupDigest
cascadeCandidatePlanGraphDigest = internalCandidateGraphDigest

cascadeCandidatePlanDescriptorDigest :: CascadeCandidatePlan -> CleanupDigest
cascadeCandidatePlanDescriptorDigest =
  cleanupProgramDescriptorDigest
    . lifecycleCleanupDescriptorProgramDescriptor
    . internalCandidateDescriptor

-- | The operation id the compiled program gave its local-uninstall node, as
-- recorded in the durable host intent.  Read back off the intent rather than
-- recomputed, so this diagnostic cannot agree with the graph while the record
-- disagrees.
cascadeCandidatePlanTerminalOperationId
  :: CascadeCandidatePlan -> CleanupOperationId
cascadeCandidatePlanTerminalOperationId =
  hostCleanupTerminalOperationId
    . hostCleanupTerminalIdentity
    . lifecycleCleanupDescriptorHostIntent
    . internalCandidateDescriptor

resolveCascadeCandidatePlan
  :: AwsScope
  -> CascadeCandidateInputs
  -> Either CascadeCandidateError CascadeCandidatePlan
resolveCascadeCandidatePlan awsScope inputs = do
  let bindings = cascadeCandidateResourceScopeBindings inputs
  case ( resourceScopeHomeDns01 bindings
       , resourceScopeInviteMail bindings
       , resourceScopeAuditRetainedNames bindings
       ) of
    (Just _, Just _, Just _) -> Right ()
    _ ->
      Left
        ( CascadeCandidateResourceScopeInvalid
            "home DNS01, validation mail and retained audit names must all be sealed before registration"
        )
  compiled <-
    first
      CascadeCandidateProgramUncompilable
      ( compileDesiredAbsenceGraphWithBindings
          runId
          (cascadeCandidateFoundation inputs)
          (Just awsScope)
          (cascadeCandidateAwsDnsZone inputs)
          (Just bindings)
          CascadeSurface
      )
  let graph = compiledDesiredAbsenceGraph compiled
  initialRun <-
    first
      CascadeCandidateInitialRunInvalid
      ( newCleanupRun
          runId
          graph
          (cascadeCandidateOwner inputs)
          0
          (cascadeCandidateDeclaredLeaseMicros inputs)
      )
  descriptor <-
    first
      CascadeCandidateDescriptorInvalid
      ( mkLifecycleCleanupDescriptor
          runId
          compiled
          initialRun
          (cascadeCandidateTerminalPermitId inputs)
      )
  Right
    CascadeCandidatePlan
      { internalCandidateProgram = compiled
      , internalCandidateDescriptor = descriptor
      , internalCandidateRunId = runId
      , internalCandidateGraphDigest = cleanupGraphDigest graph
      }
 where
  runId = cascadeCandidateRunId inputs

-- ---------------------------------------------------------------------------
-- What can go wrong
-- ---------------------------------------------------------------------------

data CascadeCandidateError
  = CascadeCandidateProgramUncompilable !DesiredAbsenceGraphError
  | CascadeCandidateInitialRunInvalid !CleanupRunError
  | CascadeCandidateDescriptorInvalid !LifecycleCleanupDescriptorError
  | CascadeCandidateCompositionFailed !HostCleanupCompositionError
  | CascadeCandidateScopeSubmissionKeyInvalid !ClientSubmissionKeyError
  | CascadeCandidateScopeDispatchFailed !AuthorityProviderClientError
  | CascadeCandidateScopeReceiptInvalid !ProviderAwsScopeReceiptError
  | CascadeCandidateCloudRuntimeInvalid !ProductionCloudRuntimeError
  | CascadeCandidateRegistrationFailed !LifecycleCleanupClientError
  | CascadeCandidateClaimFailed !LifecycleCleanupClientError
  | CascadeCandidatePrimaryFailed !LifecycleCleanupClientError
  | CascadeCandidateDriveFailed !CleanupRunDriverError
  | CascadeCandidateHostIntentRetirementFailed
      !LifecycleCleanupClientError
  | CascadeCandidateHostHandoffFailed !HostCleanupIntentError
  | CascadeCandidateHostHandoffBindingMismatch !Text
  | CascadeCandidateHostTerminalFailed !HostCleanupRunnerError
  | CascadeCandidateCredentialRetirementFailed !Text
  | CascadeCandidateResourceScopeInvalid !Text
  deriving stock (Eq, Show)

renderCascadeCandidateError :: CascadeCandidateError -> String
renderCascadeCandidateError = \case
  CascadeCandidateResourceScopeInvalid detail ->
    "the cascade resource scope cannot be sealed: " ++ Text.unpack detail
  CascadeCandidateProgramUncompilable err ->
    "the cascade program could not be compiled: " ++ show err
  CascadeCandidateInitialRunInvalid err ->
    "the declared initial cleanup run is invalid: " ++ show err
  CascadeCandidateDescriptorInvalid err ->
    "the cascade program descriptor could not be captured: " ++ show err
  CascadeCandidateCompositionFailed err ->
    renderHostCleanupCompositionError err
  CascadeCandidateScopeSubmissionKeyInvalid err ->
    "the cascade AWS-scope submission key was invalid: " ++ show err
  CascadeCandidateScopeDispatchFailed err ->
    "the Lifecycle Authority could not observe the cascade AWS scope: "
      ++ show err
  CascadeCandidateScopeReceiptInvalid err ->
    "the Lifecycle Authority returned an invalid cascade AWS-scope receipt: "
      ++ show err
  CascadeCandidateCloudRuntimeInvalid err ->
    renderProductionCloudRuntimeError err
  CascadeCandidateRegistrationFailed err ->
    "the cascade run could not be registered at the Lifecycle Authority: "
      ++ show err
  CascadeCandidateClaimFailed err ->
    "the cascade run could not be claimed: " ++ show err
  CascadeCandidatePrimaryFailed err ->
    "the cascade primary outcome could not be recorded: " ++ show err
  CascadeCandidateDriveFailed err ->
    "the cascade could not be driven to a terminal run: " ++ show err
  CascadeCandidateHostIntentRetirementFailed err ->
    "the cascade terminal host intent could not be retired: " ++ show err
  CascadeCandidateHostHandoffFailed err ->
    "the cascade terminal handoff could not be observed or persisted: " ++ show err
  CascadeCandidateHostHandoffBindingMismatch detail ->
    "the cascade terminal handoff does not match this invocation: " ++ Text.unpack detail
  CascadeCandidateCredentialRetirementFailed detail ->
    "the cascade Provider credential retirement remains unresolved: " ++ Text.unpack detail
  CascadeCandidateHostTerminalFailed err ->
    "the cascade local completion remains unresolved: " ++ show err

-- ---------------------------------------------------------------------------
-- The drive
-- ---------------------------------------------------------------------------

-- | A retained host binding already records the scope observed before its
-- registration.  Its exact descriptor is checked again by registration before
-- any Provider work; probing a new scope after the terminal fence is invalid.
data CascadeCandidateScopeResolution
  = CascadeCandidateObserveAwsScope
  | CascadeCandidateResumeObservedScope !AwsScope !CascadeCandidatePlan

resolveCascadeCandidateScope
  :: CascadeCandidateInputs
  -> Maybe HostCleanupIntent
  -> Either CascadeCandidateError CascadeCandidateScopeResolution
resolveCascadeCandidateScope _ Nothing = Right CascadeCandidateObserveAwsScope
resolveCascadeCandidateScope inputs (Just intent) =
  case evidenceAwsScope (hostCleanupObservationEvidenceScope (hostCleanupScope intent)) of
    Nothing -> Left (CascadeCandidateHostHandoffBindingMismatch "the retained host scope has no AWS identity")
    Just awsScope -> do
      plan <- resolveCascadeCandidatePlan awsScope inputs
      if candidateHostIntentMatchesPlan plan intent
        then Right (CascadeCandidateResumeObservedScope awsScope plan)
        else
          Left
            (CascadeCandidateHostHandoffBindingMismatch "the retained host run, scope or terminal permit differs")

candidateHostIntentMatchesPlan :: CascadeCandidatePlan -> HostCleanupIntent -> Bool
candidateHostIntentMatchesPlan plan intent =
  let expected = lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor plan)
   in hostCleanupRun expected == hostCleanupRun intent
        && hostCleanupScope expected == hostCleanupScope intent
        && hostCleanupTerminalIdentity expected == hostCleanupTerminalIdentity intent

data CascadeCandidateRemoteOutcome
  = CascadeCandidateRemoteTerminal !CascadeCandidateOutcome
  | CascadeCandidateRemoteHandoff !HostCleanupTerminalHandoff !HostCleanupLocalComposition

-- | Drive one cascade to a terminal durable run and observe its report.
--
-- Qualification is the current caller.  Activating it as the public
-- @cluster delete --cascade@ writer, and deleting the legacy route it would
-- replace, is Sprint @6.5@'s qualified single-writer cutover.
runCascadeCandidate
  :: CascadeCandidateInputs
  -> CascadeCandidateEnvironment
  -> IO (Either CascadeCandidateError CascadeCandidateOutcome)
runCascadeCandidate inputs environment =
  -- Resolve once against the non-authorizing regression scope before opening
  -- a session. Scope changes identity, not input validity, so this is the one
  -- total prevalidation path for zero leases and every other malformed input.
  case resolveCascadeCandidatePlan regressionAwsScope inputs of
    Left err -> pure (Left err)
    Right _ -> do
      resolved <- resolveHostCleanupLocalComposition (cascadeCandidateComposition environment)
      case resolved of
        Left err -> pure (Left (CascadeCandidateCompositionFailed err))
        Right local -> do
          observed <-
            observeHostCleanupTerminalHandoff (hostCleanupLocalIntentStore local) (cascadeCandidateRunId inputs)
          case observed of
            Left err -> pure (Left (CascadeCandidateHostHandoffFailed err))
            Right (Just handoff) -> finishLocal local handoff
            Right Nothing -> do
              composed <-
                withHostCleanupProductionSources
                  (cascadeCandidateComposition environment)
                  driveAfterScopeObservation
              case composed of
                Left err -> pure (Left (CascadeCandidateCompositionFailed err))
                Right (Left err) -> pure (Left err)
                Right (Right (CascadeCandidateRemoteTerminal outcome)) -> pure (Right outcome)
                Right (Right (CascadeCandidateRemoteHandoff handoff resolvedLocal)) ->
                  -- All authentication/session finalizers have completed here.
                  finishLocal resolvedLocal handoff
 where
  finishLocal local handoff =
    finishCascadeCandidateHostHandoff
      (hostCleanupRepositoryRoot (cascadeCandidateComposition environment))
      inputs
      (hostCleanupLocalTerminalComposition local)
      handoff

  armTerminalHost runtime = go (2 :: Int)
   where
    store = hostCleanupProductionIntentStore runtime
    go remaining = do
      observed <- observeHostCleanupIntent store
      case observed of
        Left err -> pure (Left (CascadeCandidateHostHandoffFailed err))
        Right (Just intent) -> case hostCleanupIntentPhase intent of
          HostCleanupTerminalArmed -> pure (Right ())
          phase | phase `elem` [HostCleanupPrepared, HostCleanupAuthorityAccepted] && remaining > 0 -> do
            stepped <- stepHostCleanupRunner store (hostCleanupProductionEffects runtime) Nothing
            case stepped of
              Left err -> pure (Left (CascadeCandidateHostTerminalFailed err))
              Right _ -> go (remaining - 1)
          _ ->
            pure
              ( Left
                  (CascadeCandidateHostHandoffBindingMismatch "the host is outside its pre-uninstall arming phases")
              )
        Right Nothing -> pure (Left (CascadeCandidateHostHandoffBindingMismatch "the host intent is missing"))

  driveAfterScopeObservation runtime = do
    observed <- observeHostCleanupIntent (hostCleanupProductionIntentStore runtime)
    case observed of
      Left err -> pure (Left (CascadeCandidateHostHandoffFailed err))
      Right intent -> case resolveCascadeCandidateScope inputs intent of
        Left err -> pure (Left err)
        Right (CascadeCandidateResumeObservedScope awsScope plan) -> drive awsScope plan runtime
        Right CascadeCandidateObserveAwsScope -> observeFreshScope runtime

  observeFreshScope runtime = do
    let transport = hostCleanupProductionAuthorityTransport runtime
    case cascadeScopeSubmissionKey inputs of
      Left err -> pure (Left (CascadeCandidateScopeSubmissionKeyInvalid err))
      Right submissionKey -> do
        observed <-
          dispatchAuthorityProviderIntentWithOperation
            transport
            submissionKey
            ObserveProviderAwsScope
        case observed of
          Left err -> pure (Left (CascadeCandidateScopeDispatchFailed err))
          Right (operationId, receipt) ->
            case verifySettledAuthorityProviderAwsScopeReceipt operationId receipt of
              Left err -> pure (Left (CascadeCandidateScopeReceiptInvalid err))
              Right proof ->
                let awsScope =
                      AwsScope
                        (verifiedAuthorityProviderAwsScopeAccountId proof)
                        (verifiedAuthorityProviderAwsScopeRegion proof)
                 in case resolveCascadeCandidatePlan awsScope inputs of
                      Left err -> pure (Left err)
                      Right plan -> drive awsScope plan runtime

  drive awsScope plan runtime = do
    let transport = hostCleanupProductionAuthorityTransport runtime
        store = hostCleanupProductionIntentStore runtime
        cascadeHost =
          mkCascadeHostRuntime store (hostCleanupProductionEffects runtime)
        cascadePreUninstall =
          mkCascadePreUninstallRuntime
            (hostCleanupProductionCascadeReportAuthority runtime)
            (hostCleanupProductionCleanupReportBackup runtime)
            ( productionTeardownProviderBoundary
                (hostCleanupCaller composition)
                (hostCleanupRepositoryRoot composition)
            )
            store
            transport
            (hostCleanupProductionProviderCredentialGeneration runtime)
        client = descriptorBoundCleanupRunClient transport
        descriptor = internalCandidateDescriptor plan
        composition = cascadeCandidateComposition environment
    case productionCloudRuntime
      (cloudInputsFor environment)
      transport
      (internalCandidateRunId plan)
      (internalCandidateGraphDigest plan) of
      Left err -> pure (Left (CascadeCandidateCloudRuntimeInvalid err))
      Right cloudRuntime -> do
        registered <-
          registerLifecycleCleanupRun
            (PrepareHostUninstallRecord store)
            client
            descriptor
        case registered of
          Left err -> pure (Left (CascadeCandidateRegistrationFailed err))
          Right admitted -> do
            -- The cascade is its own primary work; there is no separate
            -- action whose failure the cleanup would be reacting to, so the
            -- primary outcome is a fact about the run rather than an
            -- observation of something else.  Commit that fact before the
            -- first epoch-time claim: a fresh deterministic descriptor holds
            -- a declared lease window relative to zero, not an expired
            -- predecessor whose vacant primary should become RunnerLost.
            prepared <- case cascadePrimaryPreparation admitted of
              CascadePrimaryAttachSucceeded ->
                attachLifecycleCleanupPrimaryOutcome
                  client
                  CleanupPrimarySucceeded
                  admitted
              CascadePrimaryResumeRecorded -> pure (Right admitted)
            case prepared of
              Left err -> pure (Left (CascadeCandidatePrimaryFailed err))
              Right primaryReady -> do
                now <- currentEpochMicros
                claimed <-
                  claimLifecycleCleanupRun
                    client
                    owner
                    now
                    (now + cascadeCandidateLeaseWindowMicros environment)
                    primaryReady
                case claimed of
                  Left err -> pure (Left (CascadeCandidateClaimFailed err))
                  Right ready -> do
                    driven <-
                      resumeDescriptorBoundCleanupBeforeLocalUninstall
                        client
                        owner
                        ( descriptorBoundLifecycleNodeActionInternal
                            cloudRuntime
                            transport
                            cascadePreUninstall
                            cascadeHost
                        )
                        (registeredLifecycleCleanupBoundRun ready)
                    case driven of
                      Left err -> pure (Left (CascadeCandidateDriveFailed err))
                      Right (DescriptorBoundCleanupPaused bound) -> do
                        retired <-
                          retireCascadePreUninstallCredentialInternal
                            cascadePreUninstall
                            bound
                            (cascadeCandidateRevokeProviderCredential environment)
                        case retired of
                          Left detail -> pure (Left (CascadeCandidateCredentialRetirementFailed detail))
                          Right confirmation -> do
                            armed <- armTerminalHost runtime
                            case armed of
                              Left err -> pure (Left err)
                              Right () -> do
                                persisted <- persistHostCleanupTerminalHandoff store bound confirmation
                                pure $ case persisted of
                                  Left err -> Left (CascadeCandidateHostHandoffFailed err)
                                  Right handoff -> Right (CascadeCandidateRemoteHandoff handoff (hostCleanupProductionLocalComposition runtime))
                      Right (DescriptorBoundCleanupTerminal _) -> do
                        retired <-
                          retireTerminalLifecycleCleanupHostIntent
                            (PrepareHostUninstallRecord store)
                            client
                            ready
                        case retired of
                          Left err ->
                            pure
                              ( Left
                                  ( CascadeCandidateHostIntentRetirementFailed
                                      err
                                  )
                              )
                          Right () -> do
                            terminalNow <- currentEpochMicros
                            result <-
                              observeLifecycleCleanupResult
                                client
                                terminalNow
                                (cascadeCandidateReportRetentionMicros environment)
                                ready
                            pure
                              ( Right
                                  ( CascadeCandidateRemoteTerminal
                                      CascadeCandidateOutcome
                                        { cascadeCandidateOutcomeAwsScope = awsScope
                                        , cascadeCandidateOutcomeGraphDigest =
                                            internalCandidateGraphDigest plan
                                        , cascadeCandidateOutcomeDescriptorDigest =
                                            cascadeCandidatePlanDescriptorDigest plan
                                        , cascadeCandidateOutcomeLifecycleResult = result
                                        }
                                  )
                              )

  owner = cascadeCandidateOwner inputs

  cloudInputsFor candidateEnvironment =
    ProductionCloudRuntimeInputs
      { productionCloudRepositoryRoot =
          hostCleanupRepositoryRoot composition
      , productionCloudCaller = hostCleanupCaller composition
      , productionCloudKubectlPath =
          cascadeCandidateKubectlPath candidateEnvironment
      , productionCloudKubectlEnvironment =
          cascadeCandidateKubectlEnvironment candidateEnvironment
      , productionCloudKubectlWorkingDirectory =
          cascadeCandidateKubectlWorkingDirectory candidateEnvironment
      , productionCloudDrainLease =
          cascadeCandidateDrainLease candidateEnvironment
      }
   where
    composition = cascadeCandidateComposition candidateEnvironment

finishCascadeCandidateHostHandoff
  :: FilePath
  -> CascadeCandidateInputs
  -> HostCleanupTerminalComposition
  -> HostCleanupTerminalHandoff
  -> IO (Either CascadeCandidateError CascadeCandidateOutcome)
finishCascadeCandidateHostHandoff repositoryRoot inputs local handoff = do
  let snapshot = hostCleanupTerminalHandoffIntent handoff
  case evidenceAwsScope (hostCleanupObservationEvidenceScope (hostCleanupScope snapshot)) of
    Nothing -> pure (Left (CascadeCandidateHostHandoffBindingMismatch "the stored scope has no AWS identity"))
    Just awsScope -> case resolveCascadeCandidatePlan awsScope inputs of
      Left err -> pure (Left err)
      Right plan
        | cascadeCandidatePlanDescriptorDigest plan /= hostCleanupTerminalHandoffDescriptorDigest handoff
            || not (candidateHostIntentMatchesPlan plan snapshot) ->
            pure
              ( Left
                  (CascadeCandidateHostHandoffBindingMismatch "run, graph, descriptor or terminal permit differs")
              )
        | otherwise -> do
            completed <-
              runHostCleanupTerminalHandoff
                (hostCleanupTerminalIntentStore local)
                ( hostCleanupTerminalRunnerEffects
                    repositoryRoot
                    local
                )
                handoff
            pure $ case completed of
              Left err -> Left (CascadeCandidateHostTerminalFailed err)
              Right (_, report) ->
                Right
                  CascadeCandidateOutcome
                    { cascadeCandidateOutcomeAwsScope = awsScope
                    , cascadeCandidateOutcomeGraphDigest = internalCandidateGraphDigest plan
                    , cascadeCandidateOutcomeDescriptorDigest = cascadeCandidatePlanDescriptorDigest plan
                    , cascadeCandidateOutcomeLifecycleResult = LifecycleCleanupReportObserved report
                    }

-- | An observed, credential-retired handoff and its native-only interpreter.
-- Neither a constructor nor an arbitrary action escapes this private owner.
data CascadeCandidateHostResume
  = CascadeCandidateHostResume
      !FilePath
      !CascadeCandidateInputs
      !HostCleanupTerminalComposition
      !HostCleanupTerminalHandoff

cascadeCandidateHostResumeInputs :: CascadeCandidateHostResume -> CascadeCandidateInputs
cascadeCandidateHostResumeInputs (CascadeCandidateHostResume _ inputs _ _) = inputs

restoreCascadeCandidateInputs
  :: HostCleanupIntent -> Either CascadeCandidateError CascadeCandidateInputs
restoreCascadeCandidateInputs intent = do
  let initial = hostCleanupRun intent
      scope = hostCleanupObservationEvidenceScope (hostCleanupScope intent)
  bindings <-
    maybe
      ( Left
          (CascadeCandidateResourceScopeInvalid "the historical handoff has no sealed resource coordinates")
      )
      Right
      (evidenceResourceScopeBindings scope)
  Right
    CascadeCandidateInputs
      { cascadeCandidateRunId = hostCleanupRunId intent
      , cascadeCandidateOwner = cleanupLeaseOwner (cleanupRunLease initial)
      , cascadeCandidateFoundation = hostCleanupFoundationId (hostCleanupScope intent)
      , cascadeCandidateAwsDnsZone = evidenceAwsDnsZone scope
      , cascadeCandidateResourceScopeBindings = bindings
      , cascadeCandidateTerminalPermitId = hostCleanupTerminalPermitId (hostCleanupTerminalIdentity intent)
      , cascadeCandidateDeclaredLeaseMicros = cleanupLeaseExpiresAtMicros (cleanupRunLease initial)
      }

observeCascadeCandidateHostResume
  :: FilePath -> CleanupRunId -> IO (Either CascadeCandidateError (Maybe CascadeCandidateHostResume))
observeCascadeCandidateHostResume repositoryRoot runId = do
  resolved <- resolveHostCleanupTerminalComposition repositoryRoot
  case resolved of
    Left err -> pure (Left (CascadeCandidateCompositionFailed err))
    Right local -> do
      observed <- observeHostCleanupTerminalHandoff (hostCleanupTerminalIntentStore local) runId
      pure $ case observed of
        Left err -> Left (CascadeCandidateHostHandoffFailed err)
        Right Nothing -> Right Nothing
        Right (Just handoff) -> do
          let intent = hostCleanupTerminalHandoffIntent handoff
              scope = hostCleanupObservationEvidenceScope (hostCleanupScope intent)
          inputs <- restoreCascadeCandidateInputs intent
          aws <-
            maybe
              (Left (CascadeCandidateHostHandoffBindingMismatch "the historical handoff has no AWS identity"))
              Right
              (evidenceAwsScope scope)
          plan <- resolveCascadeCandidatePlan aws inputs
          if candidateHostIntentMatchesPlan plan intent
            && cascadeCandidatePlanDescriptorDigest plan == hostCleanupTerminalHandoffDescriptorDigest handoff
            then Right (Just (CascadeCandidateHostResume repositoryRoot inputs local handoff))
            else
              Left
                ( CascadeCandidateHostHandoffBindingMismatch
                    "the native resume differs from the exact historical program"
                )

runCascadeCandidateHostResume
  :: CascadeCandidateHostResume -> IO (Either CascadeCandidateError CascadeCandidateOutcome)
runCascadeCandidateHostResume (CascadeCandidateHostResume repositoryRoot inputs local handoff) =
  finishCascadeCandidateHostHandoff repositoryRoot inputs local handoff

currentEpochMicros :: IO Natural
currentEpochMicros = do
  seconds <- getPOSIXTime
  pure (floor (seconds * 1_000_000))

-- | Stable across resume for one declared run.  The Authority therefore
-- replays the same retained observation instead of allocating a new identity.
cascadeScopeSubmissionKey
  :: CascadeCandidateInputs
  -> Either ClientSubmissionKeyError ClientSubmissionKey
cascadeScopeSubmissionKey inputs =
  mkClientSubmissionKey
    ("cascade-scope:" <> cleanupRunIdText (cascadeCandidateRunId inputs))

-- ---------------------------------------------------------------------------
-- Non-authorizing diagnostics
-- ---------------------------------------------------------------------------

-- | Fixed, non-authorizing diagnostics.  No plan, descriptor, transport, or
-- runtime escapes the public facade; holding one of these booleans authorizes
-- nothing.
fixedCascadeCandidateEpochChecks :: IO (Either Text [(Text, Bool)])
fixedCascadeCandidateEpochChecks = fixedCascadePreUninstallEpochChecks

data CascadeCandidateRegression
  = CascadeCandidateRegression !Bool !Bool !Bool !Bool !Bool !Bool

fixedCascadeCandidateRegression :: CascadeCandidateRegression
fixedCascadeCandidateRegression =
  CascadeCandidateRegression
    deterministic
    terminalCompiled
    leaseRequired
    identityBinds
    primaryResumePreserves
    freshPrimarySurvivesClaim
 where
  first' = resolveCascadeCandidatePlan regressionAwsScope regressionInputs
  second' = resolveCascadeCandidatePlan regressionAwsScope regressionInputs

  -- Two resolutions of one declared identity produce one program descriptor.
  -- This is what lets a resumed cascade re-enter through the same call: the
  -- Authority replays the run it holds instead of admitting a second one.
  deterministic = case (first', second') of
    (Right left, Right right) ->
      cascadeCandidatePlanDescriptorDigest left
        == cascadeCandidatePlanDescriptorDigest right
        && cascadeCandidatePlanGraphDigest left
          == cascadeCandidatePlanGraphDigest right
        && cascadeCandidatePlanRunId left == cascadeCandidatePlanRunId right
    _ -> False

  -- The durable host record's terminal operation is the compiled program's,
  -- carried through the intent rather than authored beside it.  Both sides are
  -- computed here — the record's value and the program's own — because a
  -- non-empty identity would also be satisfied by one the graph never gave.
  terminalCompiled = case first' of
    Right plan ->
      Just (cascadeCandidatePlanTerminalOperationId plan)
        == compiledLocalUninstallOperationId (internalCandidateProgram plan)
    _ -> False

  -- A declared lease window of zero is not a plan.  The window is digested
  -- into the descriptor, so admitting a degenerate one would admit a program
  -- identity no resume could reproduce for a reason the operator never sees.
  leaseRequired =
    case resolveCascadeCandidatePlan
      regressionAwsScope
      regressionInputs {cascadeCandidateDeclaredLeaseMicros = 0} of
      Left (CascadeCandidateInitialRunInvalid _) -> True
      _ -> False

  -- A different declared run id is a different program identity.  Two
  -- cascades cannot share a descriptor, which is what keeps the Authority's
  -- replay of an existing run a replay of /that/ run.
  identityBinds =
    case ( first'
         , resolveCascadeCandidatePlan
             regressionAwsScope
             regressionInputs {cascadeCandidateRunId = regressionOtherRunId}
         ) of
      (Right left, Right other) ->
        cascadeCandidatePlanDescriptorDigest left
          /= cascadeCandidatePlanDescriptorDigest other
          && retainedScopeBinding left
          && resourceBindingIsSealed left
          && case restoreCascadeCandidateInputs
            (lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor left)) of
            Left _ -> False
            Right restored -> case resolveCascadeCandidatePlan regressionAwsScope restored of
              Left _ -> False
              Right replay -> cascadeCandidatePlanDescriptorDigest replay == cascadeCandidatePlanDescriptorDigest left
      _ -> False

  retainedScopeBinding plan =
    let intent = lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor plan)
        neighborInputs = regressionInputs {cascadeCandidateFoundation = LinuxRke2FoundationId "neighbor-foundation"}
        permitInputs = do
          permit <-
            first
              (const ("neighbor permit invalid" :: Text))
              (mkHostTerminalPermitId "neighbor-terminal-permit")
          Right regressionInputs {cascadeCandidateTerminalPermitId = permit}
        refused result = case result of Left _ -> True; Right _ -> False
        resumes result = case result of
          Right (CascadeCandidateResumeObservedScope scope restored) ->
            scope == regressionAwsScope
              && cascadeCandidatePlanDescriptorDigest restored == cascadeCandidatePlanDescriptorDigest plan
          _ -> False
     in case ( resolveCascadeCandidatePlan regressionAwsScope neighborInputs
             , permitInputs
                 >>= first (const "neighbor plan invalid") . resolveCascadeCandidatePlan regressionAwsScope
             ) of
          (Right neighbor, Right permitPlan) ->
            let swappedScope =
                  mkHostCleanupIntent
                    (hostCleanupRunId intent)
                    (hostCleanupGraphDigest intent)
                    (hostCleanupRun intent)
                    (hostCleanupScope (lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor neighbor)))
                    (hostCleanupTerminalIdentity intent)
                unbound = case resolveCascadeCandidateScope regressionInputs Nothing of
                  Right CascadeCandidateObserveAwsScope -> True
                  _ -> False
             in unbound
                  && resumes (resolveCascadeCandidateScope regressionInputs (Just intent))
                  && refused
                    ( resolveCascadeCandidateScope
                        regressionInputs
                        (Just (lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor permitPlan)))
                    )
                  && case swappedScope of
                    Left _ -> False
                    Right changed -> refused (resolveCascadeCandidateScope regressionInputs (Just changed))
          _ -> False

  resourceBindingIsSealed plan =
    let original = cascadeCandidateResourceScopeBindings regressionInputs
        intent = lifecycleCleanupDescriptorHostIntent (internalCandidateDescriptor plan)
        names =
          unsafeFixed
            ( mkRetainedNameBinding
                "changed-state"
                "prodbox-fixed-ses-capture"
                "fixed.example.test"
                "aws-eks-test-cluster"
            )
        changed =
          mkResourceScopeBindingsWithAudit
            (resourceScopeHomeDns01 original)
            (resourceScopeInviteMail original)
            names
        changedInputs = regressionInputs {cascadeCandidateResourceScopeBindings = changed}
        emptyInputs = regressionInputs {cascadeCandidateResourceScopeBindings = emptyResourceScopeBindings}
     in evidenceResourceScopeBindings
          (compiledDesiredAbsenceObservationScope (internalCandidateProgram plan))
          == Just original
          && case resolveCascadeCandidatePlan regressionAwsScope emptyInputs of
            Left (CascadeCandidateResourceScopeInvalid _) -> case resolveCascadeCandidatePlan regressionAwsScope changedInputs of
              Right neighbor ->
                cascadeCandidatePlanDescriptorDigest neighbor /= cascadeCandidatePlanDescriptorDigest plan
                  && case resolveCascadeCandidateScope changedInputs (Just intent) of
                    Left (CascadeCandidateHostHandoffBindingMismatch _) -> True
                    _ -> False
              _ -> False
            _ -> False

  primaryResumePreserves =
    cascadePrimaryPreparationFromOutcome Nothing == CascadePrimaryAttachSucceeded
      && all
        ( (== CascadePrimaryResumeRecorded)
            . cascadePrimaryPreparationFromOutcome
            . Just
        )
        [ CleanupPrimarySucceeded
        , CleanupPrimaryFailed "primary-failed"
        , CleanupPrimaryCancelled
        , CleanupPrimaryRunnerLost
        , CleanupPrimaryExitFailure 1
        ]

  -- The declared window is already below the later epoch-time sample.  The
  -- production order must attach the intrinsic fresh-cascade fact first: the
  -- same kernel then preserves it across the expired-window claim, whereas a
  -- claim-first mutation records RunnerLost in the vacant immutable slot.
  freshPrimarySurvivesClaim = case first' of
    Left _ -> False
    Right plan ->
      let initial =
            lifecycleCleanupDescriptorInitialRun
              (internalCandidateDescriptor plan)
          lease = cleanupRunLease initial
          afterDeclaredWindow = cleanupLeaseExpiresAtMicros lease + 1
          activeExpiry = afterDeclaredWindow + 1_000_000
          attachFirst = do
            recorded <-
              recordPrimaryOutcome
                (cleanupLeaseOwner lease)
                (cleanupLeaseFence lease)
                CleanupPrimarySucceeded
                initial
            claimCleanupRun
              (cleanupLeaseOwner lease)
              afterDeclaredWindow
              activeExpiry
              recorded
          claimFirst =
            claimCleanupRun
              (cleanupLeaseOwner lease)
              afterDeclaredWindow
              activeExpiry
              initial
       in (cleanupRunPrimaryOutcome <$> attachFirst)
            == Right (Just CleanupPrimarySucceeded)
            && (cleanupRunPrimaryOutcome <$> claimFirst)
              == Right (Just CleanupPrimaryRunnerLost)

cascadeCandidatePlanIsDeterministic :: CascadeCandidateRegression -> Bool
cascadeCandidatePlanIsDeterministic
  (CascadeCandidateRegression value _ _ _ _ _) = value

cascadeCandidateTerminalOperationIsCompiled
  :: CascadeCandidateRegression -> Bool
cascadeCandidateTerminalOperationIsCompiled
  (CascadeCandidateRegression _ value _ _ _ _) = value

cascadeCandidateDeclaredLeaseIsRequired :: CascadeCandidateRegression -> Bool
cascadeCandidateDeclaredLeaseIsRequired
  (CascadeCandidateRegression _ _ value _ _ _) = value

cascadeCandidateIdentityBindsDescriptor :: CascadeCandidateRegression -> Bool
cascadeCandidateIdentityBindsDescriptor
  (CascadeCandidateRegression _ _ _ value _ _) = value

cascadeCandidatePreservesRecordedPrimaryOutcome
  :: CascadeCandidateRegression -> Bool
cascadeCandidatePreservesRecordedPrimaryOutcome
  (CascadeCandidateRegression _ _ _ _ value _) = value

cascadeCandidateFreshPrimarySurvivesDeclaredLeaseClaim
  :: CascadeCandidateRegression -> Bool
cascadeCandidateFreshPrimarySurvivesDeclaredLeaseClaim
  (CascadeCandidateRegression _ _ _ _ _ value) = value

data CascadePrimaryPreparation
  = CascadePrimaryAttachSucceeded
  | CascadePrimaryResumeRecorded
  deriving stock (Eq, Show)

cascadePrimaryPreparation
  :: RegisteredLifecycleCleanup surface -> CascadePrimaryPreparation
cascadePrimaryPreparation =
  cascadePrimaryPreparationFromOutcome
    . descriptorBoundCleanupRunPrimaryOutcome
    . registeredLifecycleCleanupBoundRun

cascadePrimaryPreparationFromOutcome
  :: Maybe CleanupPrimaryOutcome -> CascadePrimaryPreparation
cascadePrimaryPreparationFromOutcome = \case
  Nothing -> CascadePrimaryAttachSucceeded
  Just _ -> CascadePrimaryResumeRecorded

-- | Secret-free identities from the fixed qualification trace.  It contains
-- no plan, descriptor, runtime, permit, or callable effect and therefore
-- cannot authorize a cascade; the installed validation renders it to prove
-- that its fake traces are bound to a real compiled candidate identity.
data CascadeCandidatePlanSummary = CascadeCandidatePlanSummary
  { cascadeCandidateSummaryRunId :: !Text
  , cascadeCandidateSummaryGraphDigest :: !Text
  , cascadeCandidateSummaryDescriptorDigest :: !Text
  , cascadeCandidateSummaryTerminalOperationId :: !Text
  }
  deriving stock (Eq, Show)

fixedCascadeCandidatePlanSummary
  :: Either String CascadeCandidatePlanSummary
fixedCascadeCandidatePlanSummary =
  cascadeCandidateShapeSummary
    (cascadeCandidateFoundation regressionInputs)
    (cascadeCandidateAwsDnsZone regressionInputs)
    (cascadeCandidateDeclaredLeaseMicros regressionInputs)

-- | The identities of the compiled program for one foundation, DNS zone and
-- declared lease, with everything that names a /run/ held constant: the run id,
-- owner and terminal permit are the fixture's, and the AWS scope is the
-- non-authorizing regression scope.
--
-- Two cycles of one deployment differ in all of those, so their own plans never
-- agree; this is what they do agree on. It certifies the shape of the program
-- compiled for this foundation and zone, not account-bound operation ids. The
-- zone is real, so this is computed where the zone is known, before the cascade
-- runs, and compared afterwards. It cannot authorize anything.
cascadeCandidateShapeSummary
  :: LinuxRke2FoundationId
  -> Maybe HostedZoneId
  -> Natural
  -> Either String CascadeCandidatePlanSummary
cascadeCandidateShapeSummary foundation dnsZone declaredLeaseMicros =
  first renderCascadeCandidateError $ do
    plan <-
      resolveCascadeCandidatePlan
        regressionAwsScope
        regressionInputs
          { cascadeCandidateFoundation = foundation
          , cascadeCandidateAwsDnsZone = dnsZone
          , cascadeCandidateDeclaredLeaseMicros = declaredLeaseMicros
          }
    Right
      CascadeCandidatePlanSummary
        { cascadeCandidateSummaryRunId =
            cleanupRunIdText (cascadeCandidatePlanRunId plan)
        , cascadeCandidateSummaryGraphDigest =
            cleanupDigestText (cascadeCandidatePlanGraphDigest plan)
        , cascadeCandidateSummaryDescriptorDigest =
            cleanupDigestText (cascadeCandidatePlanDescriptorDigest plan)
        , cascadeCandidateSummaryTerminalOperationId =
            cleanupOperationIdText
              (cascadeCandidatePlanTerminalOperationId plan)
        }

-- | The operation id the compiled program gave its local-uninstall node.
compiledLocalUninstallOperationId
  :: CompiledDesiredAbsenceProgram 'Cascade -> Maybe CleanupOperationId
compiledLocalUninstallOperationId compiled =
  case [ cleanupNodeOperationId node
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , operation == SomeTeardownOperation UninstallCascadeLocalFoundation
       , node <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
       , cleanupNodeId node == nodeId
       ] of
    [operationId] -> Just operationId
    _ -> Nothing

regressionInputs :: CascadeCandidateInputs
regressionInputs =
  CascadeCandidateInputs
    { cascadeCandidateRunId = regressionRunId
    , cascadeCandidateOwner = regressionOwner
    , cascadeCandidateFoundation = LinuxRke2FoundationId "foundation/home"
    , cascadeCandidateAwsDnsZone =
        Just (unsafeFixed (mkHostedZoneId "Z0123456789ABCDEFGHIJ"))
    , cascadeCandidateResourceScopeBindings = regressionResourceBindings
    , cascadeCandidateTerminalPermitId = regressionPermitId
    , cascadeCandidateDeclaredLeaseMicros = 1_000_000
    }

regressionResourceBindings :: ResourceScopeBindings
regressionResourceBindings = mkResourceScopeBindingsWithAudit (Just home) (Just mail) names
 where
  home =
    unsafeFixed
      (mkHomeDns01Scope (unsafeFixed (mkHostedZoneId "ZPARENTEXAMPLE")) ("home.example.test" :| []))
  mail =
    unsafeFixed
      ( mkInviteMailScope
          (unsafeFixed (mkS3BucketName "prodbox-fixed-ses-capture"))
          (ValidationInviteDomain "receive.example.test")
      )
  names =
    unsafeFixed
      ( mkRetainedNameBinding
          "prodbox-fixed-state"
          "prodbox-fixed-ses-capture"
          "fixed.example.test"
          "aws-eks-test-cluster"
      )

regressionAwsScope :: AwsScope
regressionAwsScope =
  AwsScope (AwsAccountId "111122223333") (AwsRegion canonicalRegressionAwsRegion)

regressionRunId :: CleanupRunId
regressionRunId = unsafeFixed (mkCleanupRunId "cascade-candidate-regression")

regressionOtherRunId :: CleanupRunId
regressionOtherRunId =
  unsafeFixed (mkCleanupRunId "cascade-candidate-regression-other")

regressionOwner :: CleanupOwnerId
regressionOwner =
  unsafeFixed (mkCleanupOwnerId "cascade-candidate-regression-owner")

regressionPermitId :: HostTerminalPermitId
regressionPermitId =
  unsafeFixed (mkHostTerminalPermitId "cascade-candidate-regression-permit")

-- | Fixed literals only.  A fixture identity that failed validation would be a
-- defect in this module, not a runtime condition.
unsafeFixed :: (Show err) => Either err value -> value
unsafeFixed = \case
  Left err -> error ("fixed cascade-candidate fixture is invalid: " ++ show err)
  Right value -> value
