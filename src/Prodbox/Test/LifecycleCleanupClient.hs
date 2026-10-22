{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Validation-specific composition over the lifecycle-owned cleanup kernel.
--
-- This module selects registered targets, but it does not build a graph,
-- allocate node operation identities, accept mutation callbacks, or interpret
-- cleanup node states.  The canonical program compiler, descriptor-bound
-- runner, closed production dispatcher, and lifecycle result decision own
-- those responsibilities.
--
-- The composition runs in three parts around the validation body, and no
-- authenticated session or port-forward is open while the body runs.  The body
-- may delete and recreate the cluster the sessions reach the Authority through,
-- so a session opened before it is dead after it; the first part therefore
-- registers and claims, closes, and the third part opens a fresh session to
-- record the primary outcome, claim again, and drive.  Both sessions
-- authenticate as the operator, which is the cleanup caller the doctrine
-- names: the harness identity is a Gateway-lifetime fixture that the body may
-- remove, and the first node of every ordinary program posts a route only the
-- operator may call.
module Prodbox.Test.LifecycleCleanupClient
  ( LifecycleTestHarnessCleanupInputs (..)
  , LifecycleTestHarnessCleanupOutcome
  , lifecycleTestHarnessCleanupCaller
  , lifecycleTestHarnessCleanupLifecycleResults
  , lifecycleTestHarnessCleanupZoneDisposition
  , lifecycleTestHarnessCleanupSettled
  , lifecycleTestHarnessCleanupExitCode
  , HarnessCredentialDisposition (..)
  , lifecycleTestHarnessCredentialDisposition
  , finishHarnessCredentialCleanup
  , LifecycleTestHarnessCleanupError (..)
  , renderLifecycleTestHarnessCleanupError
  , runLifecycleTestHarnessCleanup
  , HarnessCleanupBracket (..)
  , HarnessRunRegistration (..)
  , HarnessBodyScope
  , harnessBodyObservationScope
  , harnessBodyRegisteredTargets
  , harnessBodyRunId
  , orchestrateHarnessCleanup
  , ZoneDisposition (..)
  , ZoneEvidence (..)
  , ZoneTailPlan (..)
  , planZoneTail
  , PrimaryDecision (..)
  , primaryDecision
  , harnessMainRunPrefix
  , harnessZoneRunPrefix
  , runIdBelongsTo
  , partitionByZoneScope
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , displayException
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (forM_, void)
import Data.Char (isAlphaNum, isDigit)
import Data.List (partition)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Aws (awsHarnessAdminScope)
import Prodbox.CLI.Rke2
  ( reconcileHarnessLifecycleProviderCredential
  , revokeHarnessLifecycleProviderCredential
  , runNativeHarnessPostCredentialRuntime
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (compactDescriptorBoundCleanupRun)
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunPrimaryOutcome
  , descriptorBoundCleanupRunTerminal
  , scanDescriptorBoundCleanupRuns
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
  ( descriptorBoundOrdinaryLifecycleNodeActionInternal
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( homeLinuxRke2FoundationId
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( resolveLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRunError
  , CleanupRunId
  , cleanupGraphDigest
  , cleanupRunIdText
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.CleanupRunEntry
  ( CleanupHostPreparation (NoHostPreparation)
  , LifecycleCleanupClientError
  , LifecycleCleanupDescriptor
  , LifecycleCleanupDescriptorError
  , LifecycleCleanupResult
  , RegisteredLifecycleCleanup
  , adoptExplicitPerRunLifecycleCleanup
  , attachLifecycleCleanupPrimaryOutcome
  , claimLifecycleCleanupRun
  , lifecycleCleanupNodesSucceeded
  , lifecycleCleanupTerminalAuditSucceeded
  , mkOrdinaryCleanupDescriptor
  , observeLifecycleCleanupResult
  , registerLifecycleCleanupRun
  , registeredLifecycleCleanupBoundRun
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError
  , resumeDescriptorBoundDurableCleanupWithContext
  )
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential (HarnessCredentialLineage)
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.LiveResidue
  ( PerRunResidueStatuses (perRunAwsEksSubzone)
  , queryPerRunResidueStatuses
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (..)
  , renderResidueUnreachableReason
  , residueObservationStatus
  )
import Prodbox.Lifecycle.RuntimeProfile (NativeRuntimeProfile)
import Prodbox.Lifecycle.Teardown.CloudRuntime (CloudRuntime)
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( ProductionCloudRuntimeError
  , ProductionCloudRuntimeInputs (..)
  , derivedEksDrainLeaseSeconds
  , mkEksDrainLeaseSeconds
  , productionCloudRuntime
  , renderProductionCloudRuntimeError
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , DesiredAbsenceGraphError (DesiredAbsenceAuditBindingRequired)
  , compileAuditedExplicitPerRunGraph
  , compileDesiredAbsenceGraphForRegisteredKeysWithBindings
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsScope
  , CleanupSurface (ExplicitPerRun)
  , CleanupSurfaceWitness (ExplicitPerRunSurface)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegisteredResourceKey
  , evidenceAwsDnsZone
  , evidenceAwsScope
  , evidenceLinuxRke2Foundation
  , evidenceResourceScopeBindings
  , registeredResourceKeyRequiresDnsZone
  )
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings (ResourceScopeBindings)
import Prodbox.PublicEdge (resolveSubstrateHostedZoneId)
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import Prodbox.Settings
  ( ValidatedCoordinates (coordinateAwsSubstrateZoneId)
  , loadConfigFile
  , validateAndLoadSettings
  , validatedCoordinatesFor
  )
import Prodbox.Settings.Coordinate (route53ZoneIdText)
import Prodbox.Substrate (Substrate (SubstrateAws))
import System.Exit (ExitCode (..))

data LifecycleTestHarnessCleanupInputs = LifecycleTestHarnessCleanupInputs
  { lifecycleTestHarnessRepositoryRoot :: !FilePath
  , lifecycleTestHarnessSuiteId :: !Text
  , lifecycleTestHarnessSelectedTargets :: ![RegisteredResourceKey]
  , lifecycleTestHarnessKubectlEnvironment :: ![(String, String)]
  , lifecycleTestHarnessCredentialLineage :: !HarnessCredentialLineage
  , lifecycleTestHarnessResourceBindings :: !ResourceScopeBindings
  , lifecycleTestHarnessRuntimeProfile :: !NativeRuntimeProfile
  }

-- | What became of the families that cannot be addressed without a hosted zone.
--
-- 'ZoneIncomplete' is the only disposition that withholds the credential: it
-- means the zone could not be established from evidence, and an unobservable
-- zone is never read as an absent one.
data ZoneDisposition
  = -- | No selected target needs a zone.
    ZoneNotSelected
  | -- | The authored configuration names a zone, so one program covers every
    -- selected target.
    ZoneAuthored
  | -- | The per-run subzone stack is positively absent: nothing was created
    -- that these families could have left behind.
    ZoneNotApplicable
  | -- | A second run over the zone-scoped targets was registered and driven.
    ZoneRunDriven
  | ZoneIncomplete !Text
  deriving stock (Eq, Show)

data LifecycleTestHarnessCleanupOutcome = LifecycleTestHarnessCleanupOutcome
  { internalLifecycleTestHarnessPrimaryExit :: !(Maybe ExitCode)
  , internalLifecycleTestHarnessResults :: ![LifecycleCleanupResult]
  , internalLifecycleTestHarnessZoneDisposition :: !ZoneDisposition
  , internalLifecycleTestHarnessCredentialDisposition :: !HarnessCredentialDisposition
  , internalLifecycleTestHarnessCredentialPreparationExit :: !ExitCode
  }

data HarnessCredentialDisposition
  = HarnessCredentialRevoked
  | HarnessCredentialPreservedForRecovery
  | HarnessCredentialRevocationUnresolved
  deriving stock (Eq, Show)

lifecycleTestHarnessCredentialDisposition
  :: LifecycleTestHarnessCleanupOutcome -> HarnessCredentialDisposition
lifecycleTestHarnessCredentialDisposition = internalLifecycleTestHarnessCredentialDisposition

-- | The caller every part of this composition authenticates as.
--
-- The operator and the harness identity are each trusted for every control-plane
-- route that lists the harness, and the operator alone is trusted for the host
-- observation the first node of every ordinary program posts. The operator's
-- ServiceAccount lives in the bootstrap-core namespace and survives the cluster
-- deletion the body may perform; the harness identity lives in the Gateway
-- namespace and does not. Widening the route's trust list instead would put a
-- Gateway-lifetime caller on a commit-only route.
lifecycleTestHarnessCleanupCaller :: ExternalLifecycleAuthorityCaller
lifecycleTestHarnessCleanupCaller = LifecycleAuthorityOperator

-- | Every run's result, in the order the runs were driven: the zone-scoped run
-- first when one exists, then the main run.
lifecycleTestHarnessCleanupLifecycleResults
  :: LifecycleTestHarnessCleanupOutcome -> [LifecycleCleanupResult]
lifecycleTestHarnessCleanupLifecycleResults = internalLifecycleTestHarnessResults

lifecycleTestHarnessCleanupZoneDisposition
  :: LifecycleTestHarnessCleanupOutcome -> ZoneDisposition
lifecycleTestHarnessCleanupZoneDisposition = internalLifecycleTestHarnessZoneDisposition

-- | Whether the cleanup finished what it was asked to do: every run drove all
-- of its nodes to success, and no zone-scoped family was left unestablished.
--
-- A settled cleanup is the resource-evidence gate for releasing the harness's
-- Lifecycle-provider credential. The finalizer runs before cancellation is
-- rethrown and preserves the credential whenever this evidence is incomplete.
lifecycleTestHarnessCleanupSettled
  :: LifecycleTestHarnessCleanupOutcome -> Bool
lifecycleTestHarnessCleanupSettled outcome =
  harnessCleanupSettled
    (internalLifecycleTestHarnessResults outcome)
    (internalLifecycleTestHarnessZoneDisposition outcome)

harnessCleanupSettled :: [LifecycleCleanupResult] -> ZoneDisposition -> Bool
harnessCleanupSettled results disposition =
  not (null results)
    && all lifecycleCleanupNodesSucceeded results
    && any lifecycleCleanupTerminalAuditSucceeded results
    && not (zoneIncomplete disposition)
 where
  zoneIncomplete = \case
    ZoneIncomplete _ -> True
    _ -> False

lifecycleTestHarnessCleanupExitCode
  :: LifecycleTestHarnessCleanupOutcome -> ExitCode
lifecycleTestHarnessCleanupExitCode outcome
  | not (lifecycleTestHarnessCleanupSettled outcome) =
      ExitFailure 1
  | internalLifecycleTestHarnessCredentialDisposition outcome /= HarnessCredentialRevoked =
      ExitFailure 1
  | failure@(ExitFailure _) <- internalLifecycleTestHarnessCredentialPreparationExit outcome = failure
  | otherwise = case internalLifecycleTestHarnessPrimaryExit outcome of
      Just exitCode -> exitCode
      Nothing -> ExitFailure 1

-- | The ordinary harness's credential tail. A failed validation still retires
-- its credential once every resource result is successful; incomplete resource
-- or zone evidence never invokes the Credential Provisioner.
finishHarnessCredentialCleanup
  :: (Monad m)
  => m ExitCode
  -> [LifecycleCleanupResult]
  -> ZoneDisposition
  -> m HarnessCredentialDisposition
finishHarnessCredentialCleanup revoke results disposition
  | not (harnessCleanupSettled results disposition) = pure HarnessCredentialPreservedForRecovery
  | otherwise = do
      revoked <- revoke
      pure $ case revoked of
        ExitSuccess -> HarnessCredentialRevoked
        ExitFailure _ -> HarnessCredentialRevocationUnresolved

data LifecycleTestHarnessCleanupError
  = LifecycleTestHarnessPreparationFailed !Text
  | LifecycleTestHarnessRunIdInvalid !Text
  | LifecycleTestHarnessOwnerInvalid !Text
  | LifecycleTestHarnessProgramInvalid !DesiredAbsenceGraphError
  | LifecycleTestHarnessInitialRunInvalid !CleanupRunError
  | LifecycleTestHarnessDescriptorInvalid !LifecycleCleanupDescriptorError
  | LifecycleTestHarnessAuthenticationFailed
      !LifecycleAuthorityAuthenticationError
  | LifecycleTestHarnessScanFailed !CleanupRunClientError
  | LifecycleTestHarnessMultipleRuns ![CleanupRunId]
  | LifecycleTestHarnessMainRunMissing
  | LifecycleTestHarnessAdoptionFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessRegistrationFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessClaimFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessPrimaryFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessCloudRuntimeInvalid !ProductionCloudRuntimeError
  | LifecycleTestHarnessDriveFailed !CleanupRunDriverError
  deriving stock (Eq, Show)

renderLifecycleTestHarnessCleanupError
  :: LifecycleTestHarnessCleanupError -> String
renderLifecycleTestHarnessCleanupError = \case
  LifecycleTestHarnessPreparationFailed detail -> Text.unpack detail
  LifecycleTestHarnessRunIdInvalid detail -> Text.unpack detail
  LifecycleTestHarnessOwnerInvalid detail -> Text.unpack detail
  LifecycleTestHarnessProgramInvalid err ->
    "compile the lifecycle-owned harness cleanup program: " ++ show err
  LifecycleTestHarnessInitialRunInvalid err ->
    "construct the initial lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessDescriptorInvalid err ->
    "capture the lifecycle cleanup descriptor: " ++ show err
  LifecycleTestHarnessAuthenticationFailed err ->
    renderLifecycleAuthorityAuthenticationError err
  LifecycleTestHarnessScanFailed err ->
    "scan descriptor-bound lifecycle cleanup runs: " ++ show err
  LifecycleTestHarnessMultipleRuns runIds ->
    "more than one nonterminal cleanup run exists for this test suite: "
      ++ show runIds
  LifecycleTestHarnessMainRunMissing ->
    "no nonterminal cleanup run exists for this test suite after the validation ran"
  LifecycleTestHarnessAdoptionFailed err ->
    "adopt the existing lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessRegistrationFailed err ->
    "register the lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessClaimFailed err ->
    "claim the lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessPrimaryFailed err ->
    "record the validation outcome: " ++ show err
  LifecycleTestHarnessCloudRuntimeInvalid err ->
    renderProductionCloudRuntimeError err
  LifecycleTestHarnessDriveFailed err ->
    "drive the lifecycle cleanup run: " ++ show err

-- | The two parts of the composition that touch the Authority, with the body
-- between them.  Neither part returns a session or anything bound to one, so
-- nothing can carry a dead transport across the body.
data HarnessRunRegistration bodyContext
  = FreshHarnessRun !bodyContext
  | AdoptedHarnessRun
  deriving (Eq, Show)

-- | Only a successful fresh registration/claim returns this metadata to the
-- body. It carries no session, transport, credential, or mutable reference.
data HarnessBodyScope = HarnessBodyScope !CleanupRunId !ObservationEvidenceScope ![RegisteredResourceKey]

harnessBodyObservationScope :: HarnessBodyScope -> ObservationEvidenceScope
harnessBodyObservationScope (HarnessBodyScope _ scope _) = scope

harnessBodyRegisteredTargets :: HarnessBodyScope -> [RegisteredResourceKey]
harnessBodyRegisteredTargets (HarnessBodyScope _ _ targets) = targets

harnessBodyRunId :: HarnessBodyScope -> Text
harnessBodyRunId (HarnessBodyScope runId _ _) = cleanupRunIdText runId

data HarnessCleanupBracket bodyContext outcome = HarnessCleanupBracket
  { bracketRegister :: IO (Either LifecycleTestHarnessCleanupError (HarnessRunRegistration bodyContext))
  , -- Establish the run before the first mutation and hold it;
    -- a fresh registration supplies its exact metadata to the body. An adopted
    -- run is recovered without running its old body again.
    bracketPrepareCredential :: !(IO ExitCode)
  , bracketDrive
      :: Maybe (Either SomeException ExitCode)
      -> IO (Either LifecycleTestHarnessCleanupError outcome)
  -- ^ With a fresh session, record the primary outcome, claim, and drive.
  , bracketFinalizeCredential
      :: Either SomeException ExitCode
      -> outcome
      -> IO (Either LifecycleTestHarnessCleanupError outcome)
  }

-- | Run the body between the two parts, with cancellation handled as before:
-- the drive runs masked, and an asynchronous exception the body raised is
-- rethrown after cleanup has been attempted.
orchestrateHarnessCleanup
  :: HarnessCleanupBracket bodyContext outcome
  -> (bodyContext -> IO ExitCode)
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           outcome
       )
orchestrateHarnessCleanup bracket body = do
  registered <- bracketRegister bracket
  case registered of
    Left err -> pure (Left err)
    Right registration ->
      mask $ \restore -> do
        prepared <- try (restore (bracketPrepareCredential bracket))
        primaryResult <- case prepared of
          Right ExitSuccess -> capturePrimaryResult registration (try . restore . body)
          _ -> pure $ case registration of
            FreshHarnessRun _ -> Just prepared
            AdoptedHarnessRun -> Nothing
        driven <- bracketDrive bracket primaryResult
        finalized <- case driven of
          Left err -> pure (Left err)
          Right outcome -> bracketFinalizeCredential bracket prepared outcome
        afterBody <- rethrowCancellation primaryResult finalized
        rethrowCancellation (Just prepared) afterBody

runLifecycleTestHarnessCleanup
  :: LifecycleTestHarnessCleanupInputs
  -> (HarnessBodyScope -> IO ExitCode)
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           LifecycleTestHarnessCleanupOutcome
       )
runLifecycleTestHarnessCleanup inputs body = do
  prepared <- try (prepareInputs inputs) :: IO (Either SomeException PreparedInputs)
  case prepared of
    Left err ->
      pure
        ( Left
            ( LifecycleTestHarnessPreparationFailed
                (Text.pack (displayException err))
            )
        )
    Right ready -> do
      started <- currentMicros
      case mkOwner started of
        Left err -> pure (Left err)
        Right owner ->
          orchestrateHarnessCleanup (productionBracket inputs ready owner) body

productionBracket
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> HarnessCleanupBracket HarnessBodyScope LifecycleTestHarnessCleanupOutcome
productionBracket inputs ready owner =
  HarnessCleanupBracket
    { bracketRegister = registerPart inputs ready owner
    , bracketPrepareCredential = do
        established <-
          reconcileHarnessLifecycleProviderCredential
            (lifecycleTestHarnessRepositoryRoot inputs)
            (lifecycleTestHarnessCredentialLineage inputs)
        case established of
          failure@(ExitFailure _) -> pure failure
          ExitSuccess ->
            runNativeHarnessPostCredentialRuntime
              (lifecycleTestHarnessRepositoryRoot inputs)
              (lifecycleTestHarnessRuntimeProfile inputs)
    , bracketDrive = drivePart inputs ready owner
    , bracketFinalizeCredential = finalizeCredential inputs
    }

finalizeCredential
  :: LifecycleTestHarnessCleanupInputs
  -> Either SomeException ExitCode
  -> LifecycleTestHarnessCleanupOutcome
  -> IO (Either LifecycleTestHarnessCleanupError LifecycleTestHarnessCleanupOutcome)
finalizeCredential inputs prepared outcome = do
  disposition <-
    finishHarnessCredentialCleanup
      ( revokeHarnessLifecycleProviderCredential
          (lifecycleTestHarnessRepositoryRoot inputs)
          (lifecycleTestHarnessCredentialLineage inputs)
      )
      (internalLifecycleTestHarnessResults outcome)
      (internalLifecycleTestHarnessZoneDisposition outcome)
  pure
    ( Right
        outcome
          { internalLifecycleTestHarnessCredentialDisposition = disposition
          , internalLifecycleTestHarnessCredentialPreparationExit = either (const (ExitFailure 1)) id prepared
          }
    )

-- | One authenticated session as the cleanup caller, closed when the action
-- returns.
withCleanupSession
  :: LifecycleTestHarnessCleanupInputs
  -> ( AuthenticatedClientTransport 'LifecycleAuthorityRuntime
       -> IO (Either LifecycleTestHarnessCleanupError value)
     )
  -> IO (Either LifecycleTestHarnessCleanupError value)
withCleanupSession inputs action = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication
      lifecycleTestHarnessCleanupCaller
      (lifecycleTestHarnessRepositoryRoot inputs)
      ( \authentication ->
          withLifecycleAuthorityAuthenticatedTransport authentication action
      )
  pure $ case authenticated of
    Left err -> Left (LifecycleTestHarnessAuthenticationFailed err)
    Right (Left err) -> Left (LifecycleTestHarnessAuthenticationFailed err)
    Right (Right result) -> result

-- | Part one: scan, register or adopt the main run, claim it, close.
--
-- The main run is registered before the body's first mutation, over every
-- selected target that can be addressed without a zone, or over all of them
-- when the authored configuration names one.
registerPart
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> IO (Either LifecycleTestHarnessCleanupError (HarnessRunRegistration HarnessBodyScope))
registerPart inputs ready owner =
  withCleanupSession inputs $ \transport -> do
    let client = descriptorBoundCleanupRunClient transport
    scanned <- scanDescriptorBoundCleanupRuns client
    case scanned of
      Left err -> pure (Left (LifecycleTestHarnessScanFailed err))
      Right allRuns -> do
        compactFinishedRuns client (suitePrefixOf inputs) allRuns
        case liveRunsFor (harnessMainRunPrefix (suitePrefixOf inputs)) allRuns of
          [] -> registerFresh inputs ready owner client
          [existing] -> adoptAndClaim owner client existing
          duplicates ->
            pure
              ( Left
                  ( LifecycleTestHarnessMultipleRuns
                      (descriptorBoundCleanupRunId <$> duplicates)
                  )
              )

-- | Compact this suite's finished runs.
--
-- Ignoring a terminal run when choosing between resuming and starting fresh
-- means every invocation registers a new run, and nothing else removes the old
-- ones: the Authority's run index is bounded and refuses a registration when it
-- is full, which would then also refuse every other user of the index. The
-- kernel compacts a run only once its lease has lapsed, so a run that finished
-- inside its lease is removed by the next invocation rather than by its own.
-- Best effort: a run that is not yet eligible, or a refusal, leaves it for the
-- next one and says nothing, because a compaction failure is never a reason to
-- fail a cleanup.
compactFinishedRuns
  :: DescriptorBoundCleanupRunClient IO -> Text -> [DescriptorBoundCleanupRun] -> IO ()
compactFinishedRuns client suite runs = do
  now <- currentMicros
  forM_ finished $ \run ->
    void (compactDescriptorBoundCleanupRun client run now reportRetentionMicros)
 where
  finished =
    [ run
    | run <- runs
    , descriptorBoundCleanupRunTerminal run
    , any
        (`runIdBelongsTo` descriptorBoundCleanupRunId run)
        [harnessMainRunPrefix suite, harnessZoneRunPrefix suite]
    ]

registerFresh
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> DescriptorBoundCleanupRunClient IO
  -> IO (Either LifecycleTestHarnessCleanupError (HarnessRunRegistration HarnessBodyScope))
registerFresh inputs ready owner client = do
  now <- currentMicros
  case newPlan
    HarnessFinalCleanupProgram
    (harnessMainRunPrefix (suitePrefixOf inputs))
    (mainRunKeys inputs ready)
    (preparedAwsDnsZone ready)
    ready
    owner
    now of
    Left err -> pure (Left err)
    Right (descriptor, _) -> do
      registered <- registerLifecycleCleanupRun NoHostPreparation client descriptor
      case registered of
        Left err -> pure (Left (LifecycleTestHarnessRegistrationFailed err))
        Right admitted -> do
          claimedAt <- currentMicros
          claimed <-
            claimLifecycleCleanupRun
              client
              owner
              claimedAt
              (claimedAt + leaseMicros)
              admitted
          pure $ case claimed of
            Left err -> Left (LifecycleTestHarnessClaimFailed err)
            Right held -> do
              compiled <- compiledFromRegistered held
              Right
                ( FreshHarnessRun
                    ( HarnessBodyScope
                        (compiledDesiredAbsenceRunId compiled)
                        (compiledDesiredAbsenceObservationScope compiled)
                        (mainRunKeys inputs ready)
                    )
                )

adoptAndClaim
  :: CleanupOwnerId
  -> DescriptorBoundCleanupRunClient IO
  -> DescriptorBoundCleanupRun
  -> IO (Either LifecycleTestHarnessCleanupError (HarnessRunRegistration HarnessBodyScope))
adoptAndClaim owner client existing =
  case adoptExplicitPerRunLifecycleCleanup existing of
    Left err -> pure (Left (LifecycleTestHarnessAdoptionFailed err))
    Right registered -> do
      claimedAt <- currentMicros
      claimed <-
        claimLifecycleCleanupRun
          client
          owner
          claimedAt
          (claimedAt + leaseMicros)
          registered
      pure $ case claimed of
        Left err -> Left (LifecycleTestHarnessClaimFailed err)
        Right _ -> Right AdoptedHarnessRun

-- | Part three: with a session opened after the body, record the primary
-- outcome on every run, claim, and drive the zone-scoped run first and the main
-- run second.
--
-- The order matters. Removing the DNS01 challenge records is a Kubernetes
-- owner delete through the live cluster, and the subzone destroy needs those
-- records gone; the single program the registry compiles renders the zone
-- chain before the stack's final nodes, but no graph edge enforces it once the
-- program is split in two, so the order is decided here.
drivePart
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> Maybe (Either SomeException ExitCode)
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           LifecycleTestHarnessCleanupOutcome
       )
drivePart inputs ready owner primaryResult =
  withCleanupSession inputs $ \transport -> do
    let client = descriptorBoundCleanupRunClient transport
        suite = suitePrefixOf inputs
    scanned <- scanDescriptorBoundCleanupRuns client
    case scanned of
      Left err -> pure (Left (LifecycleTestHarnessScanFailed err))
      Right allRuns ->
        case liveRunsFor (harnessMainRunPrefix suite) allRuns of
          [] -> pure (Left LifecycleTestHarnessMainRunMissing)
          (_ : _ : _) ->
            pure
              ( Left
                  ( LifecycleTestHarnessMultipleRuns
                      (descriptorBoundCleanupRunId <$> liveRunsFor (harnessMainRunPrefix suite) allRuns)
                  )
              )
          [mainExisting] -> case adoptDrivable mainExisting of
            Left err -> pure (Left err)
            Right mainRun -> do
              -- Whether the main run covers the zone-scoped families is a fact
              -- about the program it was registered with, not about the
              -- configuration read now: the configuration can change between an
              -- interrupted invocation and the one that resumes it.
              let mainScope = compiledDesiredAbsenceObservationScope (drivableCompiled mainRun)
              zoneTail <-
                zoneRunFor
                  inputs
                  ready
                  owner
                  client
                  mainScope
                  (liveRunsFor (harnessZoneRunPrefix suite) allRuns)
              case zoneTail of
                Left err -> pure (Left err)
                Right (zoneRuns, disposition) -> do
                  zoneResults <-
                    traverse
                      (driveRun inputs ready owner transport client primaryResult)
                      zoneRuns
                  mainResult <-
                    driveRun inputs ready owner transport client primaryResult mainRun
                  pure $ do
                    zoneDriven <- sequence zoneResults
                    (primaryExit, mainLifecycleResult) <- mainResult
                    Right
                      LifecycleTestHarnessCleanupOutcome
                        { internalLifecycleTestHarnessPrimaryExit = primaryExit
                        , internalLifecycleTestHarnessResults =
                            map snd zoneDriven ++ [mainLifecycleResult]
                        , internalLifecycleTestHarnessZoneDisposition = disposition
                        , internalLifecycleTestHarnessCredentialDisposition = HarnessCredentialPreservedForRecovery
                        , internalLifecycleTestHarnessCredentialPreparationExit = ExitSuccess
                        }

-- | A run ready to drive, with the program it was compiled from.
data DrivableRun = DrivableRun
  { drivableRegistered :: !(RegisteredLifecycleCleanup 'ExplicitPerRun)
  , drivableCompiled :: !(CompiledDesiredAbsenceProgram 'ExplicitPerRun)
  }

-- | The zone-scoped run, if there is one to drive: an earlier invocation's live
-- zone run is adopted; otherwise one is registered only when the zone can be
-- established from evidence.
zoneRunFor
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> DescriptorBoundCleanupRunClient IO
  -> ObservationEvidenceScope
  -> [DescriptorBoundCleanupRun]
  -> IO (Either LifecycleTestHarnessCleanupError ([DrivableRun], ZoneDisposition))
zoneRunFor inputs ready owner client scope liveZoneRuns = case evidenceAwsScope scope of
  Nothing ->
    pure
      (Left (LifecycleTestHarnessPreparationFailed "retained cleanup scope has no AWS account/region"))
  Just aws ->
    let LinuxRke2FoundationId foundation = evidenceLinuxRke2Foundation scope
        retained =
          ready
            { preparedFoundation = foundation
            , preparedAwsScope = aws
            , preparedAwsDnsZone = evidenceAwsDnsZone scope
            , preparedResourceBindings = evidenceResourceScopeBindings scope
            }
     in zoneRunForBound inputs retained owner client (isJust (evidenceAwsDnsZone scope)) liveZoneRuns

zoneRunForBound
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> DescriptorBoundCleanupRunClient IO
  -> Bool
  -> [DescriptorBoundCleanupRun]
  -> IO (Either LifecycleTestHarnessCleanupError ([DrivableRun], ZoneDisposition))
zoneRunForBound inputs ready owner client mainHasZone liveZoneRuns =
  case (zoneScopedKeys, mainHasZone, liveZoneRuns) of
    ([], _, _) -> pure (Right ([], ZoneNotSelected))
    (_, True, _) -> pure (Right ([], ZoneAuthored))
    (_, False, [existing]) -> adoptZoneRun existing
    (_, False, _ : _ : _) ->
      pure
        ( Left
            ( LifecycleTestHarnessMultipleRuns
                (descriptorBoundCleanupRunId <$> liveZoneRuns)
            )
        )
    (keys, False, []) -> do
      evidence <- observeZoneEvidence (lifecycleTestHarnessRepositoryRoot inputs)
      case planZoneTail keys evidence of
        ZoneTailNone disposition -> pure (Right ([], disposition))
        ZoneTailRegister zone zoneKeys -> registerZoneRun zone zoneKeys
 where
  (_, zoneScopedKeys) = partitionByZoneScope (lifecycleTestHarnessSelectedTargets inputs)

  adoptZoneRun existing =
    pure ((\run -> ([run], ZoneRunDriven)) <$> adoptDrivable existing)

  registerZoneRun zone zoneKeys = do
    now <- currentMicros
    case newPlan
      HarnessResourceCleanupProgram
      (harnessZoneRunPrefix (suitePrefixOf inputs))
      zoneKeys
      (Just zone)
      ready
      owner
      now of
      Left err -> pure (Left err)
      Right (descriptor, compiled) -> do
        registered <- registerLifecycleCleanupRun NoHostPreparation client descriptor
        pure $ case registered of
          Left err -> Left (LifecycleTestHarnessRegistrationFailed err)
          Right admitted ->
            Right ([DrivableRun admitted compiled], ZoneRunDriven)

-- | An existing run, adopted and paired with the program it was compiled from.
adoptDrivable
  :: DescriptorBoundCleanupRun
  -> Either LifecycleTestHarnessCleanupError DrivableRun
adoptDrivable existing =
  case adoptExplicitPerRunLifecycleCleanup existing of
    Left err -> Left (LifecycleTestHarnessAdoptionFailed err)
    Right registered -> DrivableRun registered <$> compiledFromRegistered registered

-- | Record the primary outcome, claim, drive to a terminal report, and observe
-- it.  The primary is attached before the claim, so a lease that lapsed while a
-- long body ran is taken over with the primary preserved rather than recorded
-- as a lost runner.
driveRun
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> CleanupOwnerId
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> DescriptorBoundCleanupRunClient IO
  -> Maybe (Either SomeException ExitCode)
  -> DrivableRun
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           (Maybe ExitCode, LifecycleCleanupResult)
       )
driveRun inputs ready owner transport client primaryResult run = do
  attached <- attachPrimary client (drivableRegistered run) primaryResult
  case attached of
    Left err -> pure (Left err)
    Right (primaryExit, cleanupReady) -> do
      claimedAt <- currentMicros
      claimed <-
        claimLifecycleCleanupRun
          client
          owner
          claimedAt
          (claimedAt + leaseMicros)
          cleanupReady
      case claimed of
        Left err -> pure (Left (LifecycleTestHarnessClaimFailed err))
        Right held ->
          case cloudRuntimeFor inputs ready transport held (drivableCompiled run) of
            Left err -> pure (Left err)
            Right cloudRuntime -> do
              driven <-
                resumeDescriptorBoundDurableCleanupWithContext
                  client
                  owner
                  ( descriptorBoundOrdinaryLifecycleNodeActionInternal
                      cloudRuntime
                      transport
                  )
                  (registeredLifecycleCleanupBoundRun held)
              case driven of
                Left err -> pure (Left (LifecycleTestHarnessDriveFailed err))
                Right _ -> do
                  terminalNow <- currentMicros
                  result <-
                    observeLifecycleCleanupResult
                      client
                      terminalNow
                      reportRetentionMicros
                      held
                  pure (Right (primaryExit, result))

data PreparedInputs = PreparedInputs
  { preparedFoundation :: !Text
  , preparedAwsScope :: !AwsScope
  , preparedAwsDnsZone :: !(Maybe HostedZoneId)
  , preparedResourceBindings :: !(Maybe ResourceScopeBindings)
  }

prepareInputs :: LifecycleTestHarnessCleanupInputs -> IO PreparedInputs
prepareInputs inputs = do
  authority <-
    resolveLongLivedCheckpointAuthority
      (lifecycleTestHarnessRepositoryRoot inputs)
      >>= either fail pure
  awsScope <- awsHarnessAdminScope (lifecycleTestHarnessRepositoryRoot inputs)
  config <-
    loadConfigFile (lifecycleTestHarnessRepositoryRoot inputs)
      >>= either fail pure
  coordinates <- either fail pure (validatedCoordinatesFor config)
  awsDnsZone <-
    traverse
      (either (fail . show) pure . mkHostedZoneId . route53ZoneIdText)
      (coordinateAwsSubstrateZoneId coordinates)
  pure
    PreparedInputs
      { preparedFoundation = checkpointAuthorityClusterId authority
      , preparedAwsScope = awsScope
      , preparedAwsDnsZone = awsDnsZone
      , preparedResourceBindings = Just (lifecycleTestHarnessResourceBindings inputs)
      }

-- | The sanitized suite id every run id of this composition is built from.
suitePrefixOf :: LifecycleTestHarnessCleanupInputs -> Text
suitePrefixOf = sanitizeId . lifecycleTestHarnessSuiteId

-- | The prefix of the main run's id. A run id is this prefix followed by digits
-- and nothing else, so a suite whose id extends another's (@integration-aws@
-- and @integration-aws-eks@) does not claim the other's runs.
harnessMainRunPrefix :: Text -> Text
harnessMainRunPrefix suite = "test-harness-" <> suite <> "-"

-- | The prefix of the zone-scoped run's id. @.@ is a legal run-id character
-- that 'sanitizeId' removes from every suite id, so no main prefix can be a
-- prefix of this one or the reverse.
harnessZoneRunPrefix :: Text -> Text
harnessZoneRunPrefix suite = "test-harness-zonetail." <> suite <> "-"

-- | Whether a run id is exactly @prefix@ followed by one or more digits.
runIdBelongsTo :: Text -> CleanupRunId -> Bool
runIdBelongsTo prefix runId =
  prefix `Text.isPrefixOf` text
    && not (Text.null suffix)
    && Text.all isDigit suffix
 where
  text = cleanupRunIdText runId
  suffix = Text.drop (Text.length prefix) text

-- | The nonterminal runs of one prefix. A terminal run is a finished
-- invocation's record, not work: adopting it made the next invocation skip its
-- body and return the old outcome as its own.
liveRunsFor :: Text -> [DescriptorBoundCleanupRun] -> [DescriptorBoundCleanupRun]
liveRunsFor prefix =
  filter
    ( \run ->
        runIdBelongsTo prefix (descriptorBoundCleanupRunId run)
          && not (descriptorBoundCleanupRunTerminal run)
    )

-- | The selected targets that can be addressed without a zone, then those that
-- cannot.
partitionByZoneScope
  :: [RegisteredResourceKey] -> ([RegisteredResourceKey], [RegisteredResourceKey])
partitionByZoneScope = partition (not . registeredResourceKeyRequiresDnsZone)

-- | The targets the main run is registered over before the body runs.
mainRunKeys :: LifecycleTestHarnessCleanupInputs -> PreparedInputs -> [RegisteredResourceKey]
mainRunKeys inputs ready = case preparedAwsDnsZone ready of
  Just _ -> lifecycleTestHarnessSelectedTargets inputs
  Nothing -> fst (partitionByZoneScope (lifecycleTestHarnessSelectedTargets inputs))

-- | What the per-run subzone stack's checkpoint says about the zone.
data ZoneEvidence
  = ZoneEvidenceAbsent
  | ZoneEvidenceResolved !HostedZoneId
  | ZoneEvidenceIncomplete !Text
  deriving stock (Eq, Show)

data ZoneTailPlan
  = ZoneTailNone !ZoneDisposition
  | ZoneTailRegister !HostedZoneId ![RegisteredResourceKey]
  deriving stock (Eq, Show)

-- | The decision over the zone-scoped targets, from evidence alone.
--
-- An unobservable stack is never read as an absent one: that is the single
-- case in which the credential is withheld.
planZoneTail :: [RegisteredResourceKey] -> ZoneEvidence -> ZoneTailPlan
planZoneTail zoneScoped evidence
  | null zoneScoped = ZoneTailNone ZoneNotSelected
  | otherwise = case evidence of
      ZoneEvidenceAbsent -> ZoneTailNone ZoneNotApplicable
      ZoneEvidenceResolved zone -> ZoneTailRegister zone zoneScoped
      ZoneEvidenceIncomplete detail -> ZoneTailNone (ZoneIncomplete detail)

-- | Read the subzone stack's checkpoint through the Authority and, when it
-- exists, resolve the zone it created.
observeZoneEvidence :: FilePath -> IO ZoneEvidence
observeZoneEvidence repoRoot = do
  statuses <- queryPerRunResidueStatuses repoRoot
  case residueObservationStatus (perRunAwsEksSubzone statuses) of
    ResidueAbsent -> pure ZoneEvidenceAbsent
    ResidueUnreachable reason ->
      pure
        ( ZoneEvidenceIncomplete
            ( "the per-run subzone stack could not be observed: "
                <> Text.pack (renderResidueUnreachableReason reason)
            )
        )
    ResiduePresent _ -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left detail ->
          pure
            ( ZoneEvidenceIncomplete
                ("the subzone's zone could not be resolved: " <> Text.pack detail)
            )
        Right settings -> do
          resolved <- resolveSubstrateHostedZoneId repoRoot settings SubstrateAws
          pure $ case resolved of
            Left detail ->
              ZoneEvidenceIncomplete
                ("the subzone's zone could not be resolved: " <> Text.pack detail)
            Right zoneText -> case mkHostedZoneId zoneText of
              Left err ->
                ZoneEvidenceIncomplete
                  ("the subzone's zone id is not a hosted zone id: " <> Text.pack (show err))
              Right zone -> ZoneEvidenceResolved zone

-- | Compile, wrap and capture one run over the given targets.
data HarnessCleanupProgramKind = HarnessResourceCleanupProgram | HarnessFinalCleanupProgram

newPlan
  :: HarnessCleanupProgramKind
  -> Text
  -> [RegisteredResourceKey]
  -> Maybe HostedZoneId
  -> PreparedInputs
  -> CleanupOwnerId
  -> Natural
  -> Either
       LifecycleTestHarnessCleanupError
       ( LifecycleCleanupDescriptor 'ExplicitPerRun
       , CompiledDesiredAbsenceProgram 'ExplicitPerRun
       )
newPlan kind prefix keys zone prepared owner now = do
  runId <-
    firstText
      LifecycleTestHarnessRunIdInvalid
      (mkCleanupRunId (prefix <> Text.pack (show now)))
  compiled <-
    firstValue
      LifecycleTestHarnessProgramInvalid
      ( case kind of
          HarnessFinalCleanupProgram -> case preparedResourceBindings prepared of
            Nothing -> Left DesiredAbsenceAuditBindingRequired
            Just bindings ->
              compileAuditedExplicitPerRunGraph
                runId
                (homeLinuxRke2FoundationId (preparedFoundation prepared))
                (preparedAwsScope prepared)
                zone
                bindings
                keys
          HarnessResourceCleanupProgram ->
            compileDesiredAbsenceGraphForRegisteredKeysWithBindings
              runId
              (homeLinuxRke2FoundationId (preparedFoundation prepared))
              (Just (preparedAwsScope prepared))
              zone
              (preparedResourceBindings prepared)
              ExplicitPerRunSurface
              keys
      )
  initial <-
    firstValue
      LifecycleTestHarnessInitialRunInvalid
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          owner
          now
          (now + leaseMicros)
      )
  descriptor <-
    firstValue
      LifecycleTestHarnessDescriptorInvalid
      (mkOrdinaryCleanupDescriptor runId compiled initial)
  Right (descriptor, compiled)

compiledFromRegistered
  :: RegisteredLifecycleCleanup 'ExplicitPerRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CompiledDesiredAbsenceProgram 'ExplicitPerRun)
compiledFromRegistered registered =
  case withDescriptorBoundCleanupProgram
    (registeredLifecycleCleanupBoundRun registered)
    selectExplicitPerRunCompiled of
    Left err -> Left (LifecycleTestHarnessScanFailed err)
    Right result -> result

selectExplicitPerRunCompiled
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> DescriptorBoundCleanupRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CompiledDesiredAbsenceProgram 'ExplicitPerRun)
selectExplicitPerRunCompiled witness compiled _ = case witness of
  ExplicitPerRunSurface -> Right compiled
  _ ->
    Left
      ( LifecycleTestHarnessPreparationFailed
          "cleanup surface changed during adoption"
      )

cloudRuntimeFor
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RegisteredLifecycleCleanup 'ExplicitPerRun
  -> CompiledDesiredAbsenceProgram 'ExplicitPerRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CloudRuntime IO)
cloudRuntimeFor inputs _ transport registered compiled = do
  lease <-
    firstValue
      LifecycleTestHarnessCloudRuntimeInvalid
      (mkEksDrainLeaseSeconds derivedEksDrainLeaseSeconds)
  firstValue
    LifecycleTestHarnessCloudRuntimeInvalid
    ( productionCloudRuntime
        ProductionCloudRuntimeInputs
          { productionCloudRepositoryRoot = lifecycleTestHarnessRepositoryRoot inputs
          , productionCloudCaller = lifecycleTestHarnessCleanupCaller
          , productionCloudKubectlPath = "kubectl"
          , productionCloudKubectlEnvironment =
              lifecycleTestHarnessKubectlEnvironment inputs
          , productionCloudKubectlWorkingDirectory =
              Just (lifecycleTestHarnessRepositoryRoot inputs)
          , productionCloudDrainLease = lease
          }
        transport
        (descriptorBoundCleanupRunId (registeredLifecycleCleanupBoundRun registered))
        (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled))
    )

attachPrimary
  :: DescriptorBoundCleanupRunClient IO
  -> RegisteredLifecycleCleanup 'ExplicitPerRun
  -> Maybe (Either SomeException ExitCode)
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           ( Maybe ExitCode
           , RegisteredLifecycleCleanup 'ExplicitPerRun
           )
       )
attachPrimary client registered primaryResult =
  case primaryDecision recorded primaryResult of
    PrimaryKeepRecorded outcome ->
      pure (Right (primaryExitCode (Just outcome), registered))
    PrimaryRecord exitCode outcome -> do
      attached <- attachLifecycleCleanupPrimaryOutcome client outcome registered
      pure $ case attached of
        Left err -> Left (LifecycleTestHarnessPrimaryFailed err)
        Right ready -> Right (exitCode, ready)
 where
  recorded =
    descriptorBoundCleanupRunPrimaryOutcome
      (registeredLifecycleCleanupBoundRun registered)

-- | What to do about a run's primary outcome.
data PrimaryDecision
  = -- | The run already carries one, and it stands.
    PrimaryKeepRecorded !CleanupPrimaryOutcome
  | -- | Record this one, and report this exit code for it.
    PrimaryRecord !(Maybe ExitCode) !CleanupPrimaryOutcome
  deriving stock (Eq, Show)

-- | The primary outcome a run is driven under.
--
-- An outcome already recorded wins, because the kernel refuses a different one:
-- a run left nonterminal by an earlier invocation keeps that invocation's
-- outcome, and a later invocation that tried to record its own would be
-- refused on every attempt and never complete the run. A run with none takes
-- this invocation's. When this invocation did not run the body (it adopted an
-- earlier run's), there is nothing observed to record, and the outcome of the
-- validation that run was cleaning up after is unknown, which is exactly what a
-- cancelled primary says. A run that never receives a primary can never become
-- terminal.
primaryDecision
  :: Maybe CleanupPrimaryOutcome
  -> Maybe (Either SomeException ExitCode)
  -> PrimaryDecision
primaryDecision recorded observed = case (recorded, observed) of
  (Just outcome, _) -> PrimaryKeepRecorded outcome
  (Nothing, Just result) ->
    let (exitCode, outcome) = primaryObservation result
     in PrimaryRecord exitCode outcome
  (Nothing, Nothing) -> PrimaryRecord Nothing CleanupPrimaryCancelled

primaryObservation
  :: Either SomeException ExitCode -> (Maybe ExitCode, CleanupPrimaryOutcome)
primaryObservation result = case result of
  Right ExitSuccess -> (Just ExitSuccess, CleanupPrimarySucceeded)
  Right failure@(ExitFailure code) ->
    (Just failure, CleanupPrimaryExitFailure code)
  Left err
    | isAsync err -> (Nothing, CleanupPrimaryCancelled)
    | otherwise ->
        (Nothing, CleanupPrimaryFailed (Text.pack (displayException err)))

primaryExitCode :: Maybe CleanupPrimaryOutcome -> Maybe ExitCode
primaryExitCode outcome = case outcome of
  Just CleanupPrimarySucceeded -> Just ExitSuccess
  Just (CleanupPrimaryExitFailure code) -> Just (ExitFailure code)
  _ -> Nothing

mkOwner :: Natural -> Either LifecycleTestHarnessCleanupError CleanupOwnerId
mkOwner now =
  firstText
    LifecycleTestHarnessOwnerInvalid
    (mkCleanupOwnerId ("test-harness-owner-" <> Text.pack (show now)))

sanitizeId :: Text -> Text
sanitizeId = Text.map (\character -> if isAlphaNum character then character else '-')

rethrowCancellation
  :: Maybe (Either SomeException ExitCode)
  -> Either LifecycleTestHarnessCleanupError value
  -> IO (Either LifecycleTestHarnessCleanupError value)
rethrowCancellation primaryResult result = case primaryResult of
  Just (Left err) | isAsync err -> throwIO err
  _ -> pure result

isAsync :: SomeException -> Bool
isAsync exception = case fromException exception :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False

currentMicros :: IO Natural
currentMicros = round . (* 1_000_000) <$> getPOSIXTime

leaseMicros :: Natural
leaseMicros = 30 * 60 * 1_000_000

reportRetentionMicros :: Natural
reportRetentionMicros = 0

capturePrimaryResult
  :: HarnessRunRegistration bodyContext -> (bodyContext -> IO value) -> IO (Maybe value)
capturePrimaryResult registration action = case registration of
  FreshHarnessRun context -> Just <$> action context
  AdoptedHarnessRun -> pure Nothing

firstText
  :: (Text -> error)
  -> Either Text value
  -> Either error value
firstText constructor = either (Left . constructor) Right

firstValue
  :: (sourceError -> error)
  -> Either sourceError value
  -> Either error value
firstValue constructor = either (Left . constructor) Right
