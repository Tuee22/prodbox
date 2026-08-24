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
-- @6.5@ owns activating a public writer, and nothing in the repository calls
-- the entrypoint below.
--
-- Four properties carry the design.
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
-- What this module does not own: the content of any node, which belongs to the
-- runtime that answers it; the public @cluster delete --cascade@ route, which
-- Sprint @6.5@ cuts over; and the decision to run at all, which no caller in
-- this repository makes.
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

    -- * Non-authorizing diagnostics
  , CascadeCandidateRegression
  , fixedCascadeCandidateRegression
  , cascadeCandidatePlanIsDeterministic
  , cascadeCandidateTerminalOperationIsCompiled
  , cascadeCandidateDeclaredLeaseIsRequired
  , cascadeCandidateIdentityBindsDescriptor
  , CascadeCandidatePlanSummary (..)
  , fixedCascadeCandidatePlanSummary
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
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
  ( mkCascadePreUninstallRuntime
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( descriptorBoundCleanupRunClient
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
  , CleanupOperationId
  , CleanupOwnerId
  , CleanupPrimaryOutcome (CleanupPrimarySucceeded)
  , CleanupRunError
  , CleanupRunId
  , cleanupDigestText
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.CleanupRunEntry
  ( CleanupHostPreparation (PrepareHostUninstallRecord)
  , LifecycleCleanupClientError
  , LifecycleCleanupDescriptor
  , LifecycleCleanupDescriptorError
  , LifecycleCleanupResult
  , attachLifecycleCleanupPrimaryOutcome
  , claimLifecycleCleanupRun
  , lifecycleCleanupDescriptorHostIntent
  , lifecycleCleanupDescriptorProgramDescriptor
  , mkLifecycleCleanupDescriptor
  , observeLifecycleCleanupResult
  , registerLifecycleCleanupRun
  , registeredLifecycleCleanupBoundRun
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError
  , resumeDescriptorBoundDurableCleanupWithContext
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( HostCleanupCompositionError
  , HostCleanupCompositionInputs (..)
  , HostCleanupProductionRuntime (..)
  , renderHostCleanupCompositionError
  , withHostCleanupProductionSources
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostTerminalPermitId
  , hostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , mkHostTerminalPermitId
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
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , CleanupSurfaceWitness (CascadeSurface)
  , LinuxRke2FoundationId (..)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (UninstallCascadeLocalFoundation)
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( productionTeardownProviderBoundary
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  )

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
  , cascadeCandidateRetainedNameBinding :: !RetainedNameBinding
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
  compiled <-
    first
      CascadeCandidateProgramUncompilable
      ( compileDesiredAbsenceGraph
          runId
          (cascadeCandidateFoundation inputs)
          (Just awsScope)
          (cascadeCandidateAwsDnsZone inputs)
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
  deriving stock (Eq, Show)

renderCascadeCandidateError :: CascadeCandidateError -> String
renderCascadeCandidateError = \case
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

-- ---------------------------------------------------------------------------
-- The drive
-- ---------------------------------------------------------------------------

-- | Drive one cascade to a terminal durable run and observe its report.
--
-- Nothing in this repository calls this function.  Activating it as the public
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
      composed <-
        withHostCleanupProductionSources
          (cascadeCandidateComposition environment)
          driveAfterScopeObservation
      pure $ case composed of
        Left err -> Left (CascadeCandidateCompositionFailed err)
        Right result -> result
 where
  driveAfterScopeObservation runtime = do
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
            (cascadeCandidateRetainedNameBinding environment)
            (hostCleanupProductionCascadeReportAuthority runtime)
            (hostCleanupProductionCleanupReportBackup runtime)
            ( productionTeardownProviderBoundary
                (hostCleanupCaller composition)
                (hostCleanupRepositoryRoot composition)
            )
            store
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
            now <- currentEpochMicros
            claimed <-
              claimLifecycleCleanupRun
                client
                owner
                now
                (now + cascadeCandidateLeaseWindowMicros environment)
                admitted
            case claimed of
              Left err -> pure (Left (CascadeCandidateClaimFailed err))
              Right held -> do
                -- The cascade is its own primary work; there is no separate
                -- action whose failure the cleanup would be reacting to, so
                -- the primary outcome is a fact about the run rather than an
                -- observation of something else.
                attached <-
                  attachLifecycleCleanupPrimaryOutcome
                    client
                    CleanupPrimarySucceeded
                    held
                case attached of
                  Left err -> pure (Left (CascadeCandidatePrimaryFailed err))
                  Right ready -> do
                    driven <-
                      resumeDescriptorBoundDurableCleanupWithContext
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
                      Right _ -> do
                        terminalNow <- currentEpochMicros
                        result <-
                          observeLifecycleCleanupResult
                            client
                            terminalNow
                            (cascadeCandidateReportRetentionMicros environment)
                            ready
                        pure
                          ( Right
                              CascadeCandidateOutcome
                                { cascadeCandidateOutcomeAwsScope = awsScope
                                , cascadeCandidateOutcomeGraphDigest =
                                    internalCandidateGraphDigest plan
                                , cascadeCandidateOutcomeDescriptorDigest =
                                    cascadeCandidatePlanDescriptorDigest plan
                                , cascadeCandidateOutcomeLifecycleResult = result
                                }
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
data CascadeCandidateRegression
  = CascadeCandidateRegression !Bool !Bool !Bool !Bool

fixedCascadeCandidateRegression :: CascadeCandidateRegression
fixedCascadeCandidateRegression =
  CascadeCandidateRegression
    deterministic
    terminalCompiled
    leaseRequired
    identityBinds
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
      _ -> False

cascadeCandidatePlanIsDeterministic :: CascadeCandidateRegression -> Bool
cascadeCandidatePlanIsDeterministic
  (CascadeCandidateRegression value _ _ _) = value

cascadeCandidateTerminalOperationIsCompiled
  :: CascadeCandidateRegression -> Bool
cascadeCandidateTerminalOperationIsCompiled
  (CascadeCandidateRegression _ value _ _) = value

cascadeCandidateDeclaredLeaseIsRequired :: CascadeCandidateRegression -> Bool
cascadeCandidateDeclaredLeaseIsRequired
  (CascadeCandidateRegression _ _ value _) = value

cascadeCandidateIdentityBindsDescriptor :: CascadeCandidateRegression -> Bool
cascadeCandidateIdentityBindsDescriptor
  (CascadeCandidateRegression _ _ _ value) = value

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
  first renderCascadeCandidateError $ do
    plan <- resolveCascadeCandidatePlan regressionAwsScope regressionInputs
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
       , operation == UninstallCascadeLocalFoundation
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
    , cascadeCandidateTerminalPermitId = regressionPermitId
    , cascadeCandidateDeclaredLeaseMicros = 1_000_000
    }

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
