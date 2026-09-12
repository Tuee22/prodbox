{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

module Prodbox.Test.CleanRoomHandoff
  ( CleanRoomAction (..)
  , CleanRoomPrefixRefusal (..)
  , RollbackDisposition (..)
  , CutoverPhase (..)
  , CutoverState
  , QualificationPassed
  , CutoverRefusal (..)
  , initialCutoverState
  , qualifyReplacement
  , rollbackLegacy
  , activateReplacement
  , deleteLegacyRoute
  , qualifyPostActivation
  , cutoverStatePhase
  , cutoverStateHasLegacyWriter
  , cutoverStateHasReplacementWriter
  , CutoverPlanStage (..)
  , canonicalCutoverPlan
  , cutoverStageRequiresWitness
  , AdmittedCutoverStage
  , admittedCutoverStage
  , admitCutoverStage
  , admitCutoverPlan
  , resumeCutoverPlan
  , LegacyScanMode (..)
  , LegacyCutoverResidue (..)
  , registeredLegacyCutoverFragments
  , legacyCutoverFragmentOccurs
  , legacyCutoverResidueViolations
  , InstalledCascadeFault (..)
  , InstalledCascadeDisposition (..)
  , InstalledCascadeTrace (..)
  , fixedInstalledCascadeTraces
  , renderInstalledCascadeTrace
  , ReplacementCascadeBoundary (..)
  , canonicalReplacementCascadeBoundaries
  , resumeReplacementCascadeBoundaries
  , LegacyResidue (..)
  , canonicalCleanRoomActions
  , resumeCleanRoomActions
  , rollbackDisposition
  , forbiddenLegacyPaths
  , forbiddenLegacyFragments
  , legacyResidueViolations
  , renderCleanRoomPlan
  )
where

import Data.Char (isAlphaNum)
import Data.List (isInfixOf, nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.Model (registeredResourceKeyText)
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneFinalDisposition (..)
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( SomeManagedResourceDescriptor (..)
  , managedResourceKey
  , managedResourceRegistry
  )
import Prodbox.Test.Qualification.Evidence
  ( QualificationEvidence
  , QualificationIdentity
  , qualificationEvidenceReplacementIdentity
  )

-- Typed single-writer cutover ------------------------------------------------

data CutoverPhase
  = PreActivation
  | PostActivation
  | LegacyRouteDeleted
  | PostActivationQualified
  deriving (Eq, Show)

data LegacyWriterPermit = LegacyWriterPermit
  deriving (Show)

data ReplacementWriterPermit = ReplacementWriterPermit
  deriving (Show)

-- | Evidence that the complete Standard-P validator accepted one exact
-- replacement identity.  Its constructor is private; the only producer
-- consumes an already-validated 'QualificationEvidence'.
data QualificationPassed = QualificationPassed !QualificationIdentity
  deriving (Eq, Show)

-- | At most one mutation permit exists in every phase.  Activation consumes
-- the legacy permit; deletion cannot recreate it; and the identity-changing
-- deletion returns the state to qualification-pending.
data CutoverState (phase :: CutoverPhase) where
  CutoverPreActivation
    :: !QualificationIdentity
    -> !LegacyWriterPermit
    -> CutoverState 'PreActivation
  CutoverPostActivation
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'PostActivation
  CutoverLegacyRouteDeleted
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'LegacyRouteDeleted
  CutoverPostActivationQualified
    :: !QualificationIdentity
    -> !ReplacementWriterPermit
    -> CutoverState 'PostActivationQualified

deriving instance Show (CutoverState phase)

-- | Why a cutover step was refused.
--
-- The three witness-shaped refusals are separate on purpose. A stage offered
-- with no witness at all and a stage offered with someone else's witness are
-- different operator mistakes, and a deletion that leaves the identity
-- unchanged is not a witness problem at all — it is a claim that deleting the
-- legacy source changed nothing, which would leave the pre-deletion
-- qualification standing over a deployment that is no longer the one it was
-- taken on.
data CutoverRefusal
  = CutoverQualificationIdentityMismatch
  | CutoverStageWitnessMissing !CutoverPlanStage
  | CutoverStageWitnessMismatch !CutoverPlanStage
  | CutoverDeletionIdentityUnchanged
  deriving (Eq, Show)

initialCutoverState
  :: QualificationIdentity -> CutoverState 'PreActivation
initialCutoverState identity =
  CutoverPreActivation identity LegacyWriterPermit

qualifyReplacement
  :: QualificationIdentity
  -> QualificationEvidence
  -> Either CutoverRefusal QualificationPassed
qualifyReplacement expected evidence
  | qualificationEvidenceReplacementIdentity evidence == expected =
      Right (QualificationPassed expected)
  | otherwise = Left CutoverQualificationIdentityMismatch

-- | The sole rollback operation is indexed to pre-activation.  There is no
-- function accepting a post-activation state.
rollbackLegacy
  :: CutoverState 'PreActivation -> CutoverState 'PreActivation
rollbackLegacy = id

activateReplacement
  :: QualificationPassed
  -> CutoverState 'PreActivation
  -> Either CutoverRefusal (CutoverState 'PostActivation)
activateReplacement (QualificationPassed qualified) state = case state of
  CutoverPreActivation expected LegacyWriterPermit
    | qualified == expected ->
        Right (CutoverPostActivation expected ReplacementWriterPermit)
    | otherwise -> Left CutoverQualificationIdentityMismatch

-- | Deleting the legacy source changes the source identity.  The replacement
-- remains the only writer, but the resulting deployment is deliberately not
-- called qualified until a new exact artifact is consumed below.
--
-- It takes the witness for the same reason activation does: deletion is the
-- other stage that may not enter Apply unqualified.  Being reachable only from
-- a private post-activation constructor made it unreachable without a prior
-- qualification, which is not the same thing as being gated by one — the
-- witness that authorized activation could have been for a different identity
-- by the time deletion runs.
--
-- It also refuses a resulting identity equal to the one being deleted.  A
-- deletion that changes nothing would leave 'qualifyPostActivation' satisfiable
-- by the very witness that authorized activation, so the deployment would still
-- be called qualified after the source it was qualified on had gone.
deleteLegacyRoute
  :: QualificationPassed
  -> QualificationIdentity
  -> CutoverState 'PostActivation
  -> Either CutoverRefusal (CutoverState 'LegacyRouteDeleted)
deleteLegacyRoute (QualificationPassed qualified) resultingIdentity state =
  case state of
    CutoverPostActivation expected ReplacementWriterPermit
      | qualified /= expected ->
          Left (CutoverStageWitnessMismatch PlanDeleteLegacyRouteAndIdentity)
      | resultingIdentity == expected -> Left CutoverDeletionIdentityUnchanged
      | otherwise ->
          Right (CutoverLegacyRouteDeleted resultingIdentity ReplacementWriterPermit)

qualifyPostActivation
  :: QualificationPassed
  -> CutoverState 'LegacyRouteDeleted
  -> Either CutoverRefusal (CutoverState 'PostActivationQualified)
qualifyPostActivation (QualificationPassed qualified) state = case state of
  CutoverLegacyRouteDeleted expected ReplacementWriterPermit
    | qualified == expected ->
        Right
          (CutoverPostActivationQualified expected ReplacementWriterPermit)
    | otherwise -> Left CutoverQualificationIdentityMismatch

cutoverStatePhase :: CutoverState phase -> CutoverPhase
cutoverStatePhase state = case state of
  CutoverPreActivation {} -> PreActivation
  CutoverPostActivation {} -> PostActivation
  CutoverLegacyRouteDeleted {} -> LegacyRouteDeleted
  CutoverPostActivationQualified {} -> PostActivationQualified

cutoverStateHasLegacyWriter :: CutoverState phase -> Bool
cutoverStateHasLegacyWriter state = case state of
  CutoverPreActivation {} -> True
  CutoverPostActivation {} -> False
  CutoverLegacyRouteDeleted {} -> False
  CutoverPostActivationQualified {} -> False

cutoverStateHasReplacementWriter :: CutoverState phase -> Bool
cutoverStateHasReplacementWriter state = case state of
  CutoverPreActivation {} -> False
  CutoverPostActivation {} -> True
  CutoverLegacyRouteDeleted {} -> True
  CutoverPostActivationQualified {} -> True

-- Staged Plan / Apply ordering ----------------------------------------------

data CutoverPlanStage
  = PlanRunQualificationOnlyCandidate
  | PlanObserveQualificationReceipt
  | PlanActivateSingleReplacementWriter
  | PlanDeleteLegacyRouteAndIdentity
  | PlanRunPostActivationQualification
  | PlanObservePostActivationQualificationReceipt
  deriving (Bounded, Enum, Eq, Ord, Show)

canonicalCutoverPlan :: [CutoverPlanStage]
canonicalCutoverPlan = [minBound .. maxBound]

-- | The two stages that may not enter Apply without a matching witness.
--
-- The other four are what produce the witnesses: the first two run the
-- qualification-only candidate and observe its receipt, and the last two do the
-- same after deletion.  Requiring a witness there would make the plan
-- unstartable, which is why this is a rule about two stages rather than a rule
-- about the plan.
cutoverStageRequiresWitness :: CutoverPlanStage -> Bool
cutoverStageRequiresWitness stage = case stage of
  PlanRunQualificationOnlyCandidate -> False
  PlanObserveQualificationReceipt -> False
  PlanActivateSingleReplacementWriter -> True
  PlanDeleteLegacyRouteAndIdentity -> True
  PlanRunPostActivationQualification -> False
  PlanObservePostActivationQualificationReceipt -> False

-- | A stage that has entered Apply.
--
-- Its constructor is private, so the only way to hold one is through
-- 'admitCutoverStage', which demands the witness that stage requires.  That is
-- what makes the staged plan a gate rather than an ordering: a list of bare
-- 'CutoverPlanStage' values is constructible by anyone, in any order, with no
-- witness in existence anywhere, and the resume fold below can no longer be
-- handed one.
newtype AdmittedCutoverStage = AdmittedCutoverStage CutoverPlanStage
  deriving (Eq, Show)

admittedCutoverStage :: AdmittedCutoverStage -> CutoverPlanStage
admittedCutoverStage (AdmittedCutoverStage stage) = stage

-- | Admit one stage into Apply against the identity it will act on.
admitCutoverStage
  :: QualificationIdentity
  -> Maybe QualificationPassed
  -> CutoverPlanStage
  -> Either CutoverRefusal AdmittedCutoverStage
admitCutoverStage identity witness stage
  | not (cutoverStageRequiresWitness stage) = Right (AdmittedCutoverStage stage)
  | otherwise = case witness of
      Nothing -> Left (CutoverStageWitnessMissing stage)
      Just (QualificationPassed qualified)
        | qualified == identity -> Right (AdmittedCutoverStage stage)
        | otherwise -> Left (CutoverStageWitnessMismatch stage)

-- | Admit a whole run of stages, refusing at the first one that cannot enter
-- Apply.
admitCutoverPlan
  :: QualificationIdentity
  -> Maybe QualificationPassed
  -> [CutoverPlanStage]
  -> Either CutoverRefusal [AdmittedCutoverStage]
admitCutoverPlan identity witness =
  traverse (admitCutoverStage identity witness)

resumeCutoverPlan
  :: [AdmittedCutoverStage]
  -> Either (CutoverPlanStage, Maybe CutoverPlanStage) [CutoverPlanStage]
resumeCutoverPlan completed =
  go canonicalCutoverPlan (map admittedCutoverStage completed)
 where
  go remaining [] = Right remaining
  go [] (observed : _) = Left (observed, Nothing)
  go (expected : remaining) (observed : observations)
    | observed == expected = go remaining observations
    | otherwise = Left (observed, Just expected)

-- Bounded pre/post activation legacy scanner --------------------------------

data LegacyScanMode
  = LegacyScanPreActivation
  | LegacyScanPostActivation
  deriving (Eq, Show)

-- | What a bounded legacy scan can find.
--
-- @AbsentFromPath@ is separate from @Missing@ because they are different
-- events. A fragment gone from every path is a registration that has outlived
-- its subject; a fragment gone from one registered path while surviving in
-- others is a partial removal, which is the more dangerous of the two — the set
-- is still bounded, so the pre-activation scan would otherwise report the tree
-- as unchanged while the legacy route had already been half-deleted underneath
-- it.
data LegacyCutoverResidue
  = LegacyCutoverFragmentMissing !Text
  | LegacyCutoverFragmentAbsentFromPath !FilePath !Text
  | LegacyCutoverFragmentDuplicated !Text !Int
  | LegacyCutoverFragmentUnexpected !FilePath !Text
  | LegacyCutoverFragmentSurvived !FilePath !Text
  deriving (Eq, Ord, Show)

-- | The exact legacy writer/executor set admitted before activation.  This is
-- bounded: a new matching site fails the pre-activation scan instead of being
-- silently grandfathered.
-- Sprint 6.5: @src\/Prodbox\/Lifecycle\/ResourceRegistry.hs@ left this set when
-- the scan became token-based.  Its only mention of the symbol is the haddock
-- cross-reference @\'Prodbox.CLI.Rke2.runNativeDeleteCascade\'@, which a
-- substring rule read as a site and a token rule correctly does not: a
-- documentation link is not a caller, and registering one would mean the
-- post-activation scan could never reach zero without editing a comment. The
-- two bounded layers now agree — "Prodbox.Legacy.EscapeRegistry"\'s coverage
-- rule for the same symbol never listed that file either.
registeredLegacyCutoverFragments :: [(FilePath, Text)]
registeredLegacyCutoverFragments =
  [ ("src/Prodbox/CLI/Rke2.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/Legacy/EscapeRegistry.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/Test/CascadeQualification.hs", "runNativeDeleteCascade")
  , ("src/Prodbox/CLI/Rke2.hs", "runAuthorizedDeleteCascade")
  , ("src/Prodbox/CLI/Rke2.hs", "queryAwsLayerForPerRun")
  , ("src/Prodbox/CLI/Rke2.hs", "inferCascadeSubstrate")
  , ("src/Prodbox/CLI/Rke2.hs", "CascadePhaseOutcome")
  ]

-- | Whether @fragment@ occurs in @source@ as a whole identifier token.
--
-- Substring matching would report @CascadePhaseOutcome@ as present in any
-- longer constructor that contains it, which for a scan whose whole purpose is
-- to be exact is the wrong answer in both directions: it invents a site before
-- activation and it refuses to declare the tree clean after deletion. This is
-- the same rule "Prodbox.Legacy.EscapeRegistry" applies to its seam symbols,
-- stated here over 'Text' rather than shared, because that module's copy is
-- part of a registry whose categories this scanner deliberately does not use.
legacyCutoverFragmentOccurs :: Text -> Text -> Bool
legacyCutoverFragmentOccurs fragment source
  | Text.null fragment = False
  | otherwise = any wholeToken (Text.breakOnAll fragment source)
 where
  wholeToken (before, match) =
    not (endsIdentifier before)
      && not (startsIdentifier (Text.drop (Text.length fragment) match))
  endsIdentifier text = maybe False (isIdentifierCharacter . snd) (Text.unsnoc text)
  startsIdentifier text = maybe False (isIdentifierCharacter . fst) (Text.uncons text)
  isIdentifierCharacter character =
    isAlphaNum character || character == '_' || character == '\''

legacyCutoverResidueViolations
  :: LegacyScanMode
  -> [(FilePath, Text)]
  -> [LegacyCutoverResidue]
legacyCutoverResidueViolations mode sources = case mode of
  LegacyScanPreActivation -> concatMap validateRegistered registeredFragments
  LegacyScanPostActivation ->
    [ LegacyCutoverFragmentSurvived path fragment
    | (path, source) <- sources
    , fragment <- registeredFragments
    , legacyCutoverFragmentOccurs fragment source
    ]
 where
  registeredFragments = nub (map snd registeredLegacyCutoverFragments)
  occurrences fragment =
    [ path
    | (path, source) <- sources
    , legacyCutoverFragmentOccurs fragment source
    ]
  validateRegistered fragment
    | actual == expected = []
    | null actual = [LegacyCutoverFragmentMissing fragment]
    | not (null unexpected) =
        [ LegacyCutoverFragmentUnexpected path fragment
        | path <- unexpected
        ]
    | not (null absent) =
        [ LegacyCutoverFragmentAbsentFromPath path fragment
        | path <- absent
        ]
    | otherwise = [LegacyCutoverFragmentDuplicated fragment (length actual)]
   where
    actual = sort (occurrences fragment)
    expected =
      sort
        [ path
        | (path, registered) <- registeredLegacyCutoverFragments
        , registered == fragment
        ]
    unexpected = filter (`notElem` expected) actual
    absent = filter (`notElem` actual) expected

-- Installed cascade traces --------------------------------------------------

data InstalledCascadeFault
  = InstalledCascadeSuccess
  | InstalledCascadeEffectFailure
  | InstalledCascadeCancellation
  | InstalledCascadeResponseLoss
  | InstalledCascadeRestart
  deriving (Bounded, Enum, Eq, Ord, Show)

data InstalledCascadeDisposition
  = InstalledCascadeComplete
  | InstalledCascadeIncomplete
  deriving (Eq, Ord, Show)

data InstalledCascadeTrace = InstalledCascadeTrace
  { installedTraceFault :: !InstalledCascadeFault
  , installedTraceRunId :: !Text
  , installedTraceResourceKeys :: ![Text]
  , installedTraceObservationAuthorities :: ![Text]
  , installedTraceRecoveryDisposition :: !RecoveryPlaneFinalDisposition
  , installedTraceDisposition :: !InstalledCascadeDisposition
  }
  deriving (Eq, Show)

fixedInstalledCascadeTraces :: [InstalledCascadeTrace]
fixedInstalledCascadeTraces = map traceFor [minBound .. maxBound]
 where
  traceFor fault =
    InstalledCascadeTrace
      { installedTraceFault = fault
      , installedTraceRunId = "cascade-candidate-regression"
      , installedTraceResourceKeys = resourceKeys
      , installedTraceObservationAuthorities =
          [ "lifecycle-authority"
          , "provider-worker"
          , "authority-backup-adapter"
          , "local-host-read-back"
          ]
      , installedTraceRecoveryDisposition = recoveryFor fault
      , installedTraceDisposition = dispositionFor fault
      }
  resourceKeys =
    sort
      [ registeredResourceKeyText (managedResourceKey descriptor)
      | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
      ]
  recoveryFor fault = case fault of
    InstalledCascadeSuccess -> RecoveryPlaneEstablished
    InstalledCascadeEffectFailure -> RecoveryPlaneEstablished
    InstalledCascadeCancellation -> RecoveryPlaneNotEstablished
    InstalledCascadeResponseLoss -> RecoveryPlaneEstablished
    InstalledCascadeRestart -> RecoveryPlaneEstablished
  dispositionFor fault = case fault of
    InstalledCascadeEffectFailure -> InstalledCascadeIncomplete
    InstalledCascadeCancellation -> InstalledCascadeIncomplete
    _ -> InstalledCascadeComplete

renderInstalledCascadeTrace :: InstalledCascadeTrace -> String
renderInstalledCascadeTrace trace =
  unlines
    [ "INSTALLED_CASCADE_FAKE_TRACE"
    , "FAULT=" ++ show (installedTraceFault trace)
    , "CLEANUP_RUN_ID=" ++ Text.unpack (installedTraceRunId trace)
    , "RESOURCE_KEYS=" ++ show (installedTraceResourceKeys trace)
    , "OBSERVATION_AUTHORITIES=" ++ show (installedTraceObservationAuthorities trace)
    , "RECOVERY_PLANE_DISPOSITION=" ++ show (installedTraceRecoveryDisposition trace)
    , "CASCADE_DISPOSITION=" ++ show (installedTraceDisposition trace)
    ]

-- | Every durable boundary from recovery establishment through the matching
-- local-completion read-back.  The list is deliberately more precise than the
-- operator-facing clean-room actions: interruption tests resume these
-- boundaries, while the plan renders the larger workflow around them.
data ReplacementCascadeBoundary
  = StartRecoveryProfile
  | ReadBackRecoveryProfile
  | ObserveRegisteredTargets
  | CommitEksDrainIntent
  | ReadBackEksDrainIntent
  | RunEksDrainAndBackstops
  | ReconcileProviderDesiredAbsence
  | ReadBackProviderAbsence
  | AuditCascadeEscapesExactly
  | CommitPreUninstallReport
  | ReadBackPreUninstallReport
  | ArmOneShotLocalCompletionPermit
  | UninstallLocalFoundationLast
  | ReadBackLocalFoundationAbsence
  | CommitLocalCompletionReceipt
  | ReadBackLocalCompletionReceipt
  deriving (Bounded, Enum, Eq, Ord, Show)

canonicalReplacementCascadeBoundaries :: [ReplacementCascadeBoundary]
canonicalReplacementCascadeBoundaries = [minBound .. maxBound]

resumeReplacementCascadeBoundaries
  :: [ReplacementCascadeBoundary]
  -> Either
       (ReplacementCascadeBoundary, Maybe ReplacementCascadeBoundary)
       [ReplacementCascadeBoundary]
resumeReplacementCascadeBoundaries completed =
  go canonicalReplacementCascadeBoundaries completed
 where
  go remaining [] = Right remaining
  go [] (observed : _) = Left (observed, Nothing)
  go (expected : remaining) (observed : observations)
    | observed == expected = go remaining observations
    | otherwise = Left (observed, Just expected)

-- | The versioned, installed-binary clean-room contract. Each constructor is
-- an observable boundary at which interruption and restart must be safe.
data CleanRoomAction
  = ObserveLegacyRetainedState
  | ImportAuthorityProjections
  | VerifyAuthorityShadow
  | RunQualificationOnlyCascadeCandidate
  | ObserveCandidateQualificationReceipt
  | FreezeLegacyWriter
  | ActivateReplacementEpoch
  | DeleteLegacyCascadeRoute
  | RunPostActivationQualification
  | ObservePostActivationQualificationReceipt
  | RefusePostCutoverRollback
  | DeleteCluster
  | ReconcileCluster
  | ObserveVaultSealed
  | UnsealVault
  | CompleteBrokerHandoff
  | ReplayAuthorityJournal
  | RestoreGateway
  | RestoreTargetAgent
  | RestoreCharts
  | AttemptAlwaysRunCleanup
  | VerifyZeroLegacyResidue
  | CommitQualificationEvidence
  deriving (Eq, Ord, Show, Enum, Bounded)

data CleanRoomPrefixRefusal
  = CleanRoomUnknownAction CleanRoomAction
  | CleanRoomSkippedOrReordered
      { expectedNextAction :: CleanRoomAction
      , observedAction :: CleanRoomAction
      }
  | CleanRoomActionsAfterCompletion
  deriving (Eq, Show)

data RollbackDisposition
  = RetryLegacyObservation
  | RefuseRollbackBeforeMutation
  deriving (Eq, Show)

data LegacyResidue
  = LegacyPathPresent FilePath
  | LegacyFragmentPresent FilePath Text
  deriving (Eq, Ord, Show)

canonicalCleanRoomActions :: [CleanRoomAction]
canonicalCleanRoomActions = [minBound .. maxBound]

-- | Accept only an exact durable prefix. A restart resumes the first missing
-- boundary; skips, reordering, duplicates, and suffixes after completion are
-- explicit refusals rather than best-effort recovery.
resumeCleanRoomActions
  :: [CleanRoomAction]
  -> Either CleanRoomPrefixRefusal [CleanRoomAction]
resumeCleanRoomActions completed = go canonicalCleanRoomActions completed
 where
  go remaining [] = Right remaining
  go [] (_ : _) = Left CleanRoomActionsAfterCompletion
  go (expected : remaining) (observed : observations)
    | observed `notElem` canonicalCleanRoomActions = Left (CleanRoomUnknownAction observed)
    | observed == expected = go remaining observations
    | otherwise = Left (CleanRoomSkippedOrReordered expected observed)

rollbackDisposition :: [CleanRoomAction] -> RollbackDisposition
rollbackDisposition completed
  | ActivateReplacementEpoch `elem` completed = RefuseRollbackBeforeMutation
  | otherwise = RetryLegacyObservation

forbiddenLegacyPaths :: [FilePath]
forbiddenLegacyPaths =
  [ "src/Prodbox/Gateway/ObjectStore.hs"
  , "src/Prodbox/Gateway/TargetSecret.hs"
  , "src/Prodbox/Lifecycle/HostDirectAuthorityStore.hs"
  , "src/Prodbox/Lifecycle/TargetSecretStore.hs"
  , "src/Prodbox/Pulumi/HostDirectObjectStore.hs"
  , "src/Prodbox/ControlPlane/TargetSecretEndpoint.hs"
  ]

forbiddenLegacyFragments :: [Text]
forbiddenLegacyFragments =
  [ "Prodbox.Gateway.ObjectStore"
  , "Prodbox.Gateway.TargetSecret"
  , "Prodbox.Lifecycle.HostDirectAuthorityStore"
  , "Prodbox.Lifecycle.TargetSecretStore"
  , "Prodbox.Pulumi.HostDirectObjectStore"
  , "Prodbox.ControlPlane.TargetSecretEndpoint"
  , "prodbox-gateway-target-secret"
  ]

legacyResidueViolations
  :: [FilePath]
  -> [(FilePath, Text)]
  -> [LegacyResidue]
legacyResidueViolations paths sources =
  [ LegacyPathPresent path
  | path <- forbiddenLegacyPaths
  , path `elem` paths
  ]
    ++ [ LegacyFragmentPresent path fragment
       | (path, source) <- sources
       , fragment <- forbiddenLegacyFragments
       , Text.unpack fragment `isInfixOf` Text.unpack source
       ]

renderCleanRoomPlan :: [CleanRoomAction] -> String
renderCleanRoomPlan completed =
  unlines
    ( [ "CLEAN_ROOM_HANDOFF_PLAN"
      , "SCHEMA_VERSION=2"
      , "ROLLBACK=" ++ renderRollback (rollbackDisposition completed)
      ]
        ++ either renderRefusal (map (("STEP=" ++) . renderAction)) (resumeCleanRoomActions completed)
    )
 where
  renderRollback disposition = case disposition of
    RetryLegacyObservation -> "retry-legacy-observation"
    RefuseRollbackBeforeMutation -> "refuse-before-mutation"
  renderRefusal refusal = ["REFUSED=" ++ show refusal]

renderAction :: CleanRoomAction -> String
renderAction action = case action of
  ObserveLegacyRetainedState -> "observe-legacy-retained-state"
  ImportAuthorityProjections -> "import-authority-projections"
  VerifyAuthorityShadow -> "verify-authority-shadow"
  RunQualificationOnlyCascadeCandidate -> "run-qualification-only-cascade-candidate"
  ObserveCandidateQualificationReceipt -> "observe-candidate-qualification-receipt"
  FreezeLegacyWriter -> "freeze-legacy-writer"
  ActivateReplacementEpoch -> "activate-replacement-epoch"
  DeleteLegacyCascadeRoute -> "delete-legacy-cascade-route"
  RunPostActivationQualification -> "run-post-activation-qualification"
  ObservePostActivationQualificationReceipt ->
    "observe-post-activation-qualification-receipt"
  RefusePostCutoverRollback -> "refuse-post-cutover-rollback"
  DeleteCluster -> "cluster-delete"
  ReconcileCluster -> "cluster-reconcile"
  ObserveVaultSealed -> "observe-vault-sealed"
  UnsealVault -> "unseal-vault"
  CompleteBrokerHandoff -> "complete-broker-handoff"
  ReplayAuthorityJournal -> "replay-authority-journal"
  RestoreGateway -> "restore-gateway"
  RestoreTargetAgent -> "restore-target-agent"
  RestoreCharts -> "restore-charts"
  AttemptAlwaysRunCleanup -> "attempt-always-run-cleanup"
  VerifyZeroLegacyResidue -> "verify-zero-legacy-residue"
  CommitQualificationEvidence -> "commit-qualification-evidence"
