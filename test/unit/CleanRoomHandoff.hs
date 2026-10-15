{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module CleanRoomHandoff (cleanRoomHandoffSuite) where

import CycleLedgerFixtures
  ( Step (..)
  , Variant (..)
  , deletionMarkFor
  , extendLedger
  , ledgerOf
  , markFor
  , proofForIdentity
  )
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy.Char8 qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as Text
import Prodbox.Test.CleanRoomHandoff
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( canonicalKeyPolicy
  , partsOfIdentity
  )
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( CutoverEpoch (EpochPostActivation)
  , CutoverMarkKind (..)
  , CycleLedger
  , LedgerRecord (RecordCutoverMark)
  , appendRecord
  , emptyCycleLedger
  , epochOfLedger
  , ledgerPhase
  )
import Prodbox.Test.Qualification.Evidence
  ( QualificationEvidenceInput (..)
  , QualificationIdentity (..)
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (ManifestRegularFile)
  , SourceCandidate (SourceCandidate)
  , SourceIdentity
  , WorktreeState (WorktreeDirty)
  , mkGitHead
  , mkSourceIdentity
  )
import QualificationEvidence qualified
import TestSupport

cleanRoomHandoffSuite :: SuiteBuilder ()
cleanRoomHandoffSuite =
  describe "Sprint 6.4 clean-room handoff composition" $ do
    it "resumes every interruption prefix at the exact next boundary" $
      map
        resumeCleanRoomActions
        (init (scanl (\prefix action -> prefix ++ [action]) [] canonicalCleanRoomActions))
        `shouldBe` map (Right . (`drop` canonicalCleanRoomActions)) [0 .. length canonicalCleanRoomActions - 1]

    it "accepts the complete trace as converged" $
      resumeCleanRoomActions canonicalCleanRoomActions `shouldBe` Right []

    it "refuses a skipped boundary and a duplicate boundary" $ do
      resumeCleanRoomActions [ObserveLegacyRetainedState, VerifyAuthorityShadow]
        `shouldBe` Left
          (CleanRoomSkippedOrReordered ImportAuthorityProjections VerifyAuthorityShadow)
      resumeCleanRoomActions [ObserveLegacyRetainedState, ObserveLegacyRetainedState]
        `shouldBe` Left
          (CleanRoomSkippedOrReordered ImportAuthorityProjections ObserveLegacyRetainedState)

    it "allows only old observation retry before cutover" $ do
      rollbackDisposition [ObserveLegacyRetainedState, ImportAuthorityProjections]
        `shouldBe` RetryLegacyObservation
      rollbackDisposition (takeThrough ActivateReplacementEpoch canonicalCleanRoomActions)
        `shouldBe` RefuseRollbackBeforeMutation

    it "renders cutover refusal before destructive restoration" $ do
      let rendered = renderCleanRoomPlan (takeThrough ActivateReplacementEpoch canonicalCleanRoomActions)
      rendered `shouldContain` "ROLLBACK=refuse-before-mutation"
      rendered `shouldContain` "STEP=refuse-post-cutover-rollback"
      rendered `shouldContain` "STEP=cluster-delete"

    goldenTest
      "renders the complete versioned dry-run plan"
      "test/golden/clean-room/handoff-plan.txt"
      (pure (ByteString.pack (renderCleanRoomPlan [])))

    it "finds removed paths and forbidden transport references" $ do
      legacyResidueViolations
        ["src/Prodbox/Gateway/ObjectStore.hs"]
        [("src/Example.hs", "import Prodbox.Pulumi.HostDirectObjectStore")]
        `shouldBe` [ LegacyPathPresent "src/Prodbox/Gateway/ObjectStore.hs"
                   , LegacyFragmentPresent
                       "src/Example.hs"
                       "Prodbox.Pulumi.HostDirectObjectStore"
                   ]

    it "accepts the isolated replacement topology" $
      legacyResidueViolations
        ["src/Prodbox/ControlPlane/TargetMaterialEndpoint.hs"]
        [("src/Example.hs", "import Prodbox.ControlPlane.TargetMaterialEndpoint")]
        `shouldBe` []

    it "keeps exactly one writer across the type-indexed cutover" $ do
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
          pre = initialCutoverState replacement
      cutoverStatePhase (rollbackLegacy pre) `shouldBe` PreActivation
      cutoverStateHasLegacyWriter pre `shouldBe` True
      cutoverStateHasReplacementWriter pre `shouldBe` False
      passed <- witnessFor replacement
      active <- accepted (activateReplacement passed pre)
      cutoverStatePhase active `shouldBe` PostActivation
      cutoverStateHasLegacyWriter active `shouldBe` False
      cutoverStateHasReplacementWriter active `shouldBe` True
      afterDeletion <- postDeletionIdentity input
      deleted <- accepted (deleteLegacyRoute passed afterDeletion active)
      postPassed <- witnessFor afterDeletion
      complete <- accepted (qualifyPostActivation postPassed deleted)
      cutoverStatePhase complete `shouldBe` PostActivationQualified
      cutoverStateHasLegacyWriter complete `shouldBe` False
      cutoverStateHasReplacementWriter complete `shouldBe` True

    it "refuses a deletion that leaves the source identity unchanged" $ do
      -- The deletion is what returns the deployment to qualification-pending.
      -- If it could keep the identity, the witness that authorized activation
      -- would still satisfy `qualifyPostActivation`, and the deployment would
      -- stay called qualified after the source it was qualified on had gone.
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
      passed <- witnessFor replacement
      active <- accepted (activateReplacement passed (initialCutoverState replacement))
      cutoverRefusal (deleteLegacyRoute passed replacement active)
        `shouldBe` Just CutoverDeletionIdentityUnchanged

    it "refuses a deletion carrying another identity's witness" $ do
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
      passed <- witnessFor replacement
      active <- accepted (activateReplacement passed (initialCutoverState replacement))
      afterDeletion <- postDeletionIdentity input
      elsewhere <- witnessFor afterDeletion
      cutoverRefusal (deleteLegacyRoute elsewhere afterDeletion active)
        `shouldBe` Just (CutoverStageWitnessMismatch PlanDeleteLegacyRouteAndIdentity)

    it "mints a witness only for the identity the cycle proof names" $ do
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
          proof = proofForIdentity replacement
          mismatch = Just CutoverQualificationIdentityMismatch
      cutoverRefusal (qualifyReplacement replacement proof) `shouldBe` Nothing
      -- A proof for another deployment is not a proof for this one.
      cutoverRefusal (qualifyReplacement (evidenceSupersededIdentity input) proof)
        `shouldBe` mismatch
      -- Images are a set: the same deployment observed in another order is the same identity.
      cutoverRefusal
        ( qualifyReplacement
            replacement
              { qualificationComponentImageDigests = reverse (qualificationComponentImageDigests replacement)
              }
            proof
        )
        `shouldBe` Nothing
      -- Any one digest moving is another deployment.
      cutoverRefusal
        ( qualifyReplacement
            replacement {qualificationLoadFaultDigest = qualificationResourceEnvelopeDigest replacement}
            proof
        )
        `shouldBe` mismatch

    it "requires exact staged cutover order" $ do
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
      passed <- witnessFor replacement
      admitted <- accepted (admitCutoverPlan replacement (Just passed) canonicalCutoverPlan)
      resumeCutoverPlan [] `shouldBe` Right canonicalCutoverPlan
      outOfOrder <-
        accepted
          ( admitCutoverPlan
              replacement
              (Just passed)
              [PlanRunQualificationOnlyCandidate, PlanActivateSingleReplacementWriter]
          )
      resumeCutoverPlan outOfOrder
        `shouldBe` Left
          (PlanActivateSingleReplacementWriter, Just PlanObserveQualificationReceipt)
      resumeCutoverPlan admitted `shouldBe` Right []

    it "refuses to admit the two witness-bearing stages without a witness" $ do
      -- The whole staged plan used to be an ordering fold over constructors
      -- anyone could name, so a run containing activation and deletion was
      -- constructible with no witness in existence anywhere. The resume fold
      -- can no longer be handed one.
      input <- QualificationEvidence.validInput
      let replacement = evidenceReplacementIdentity input
      filter cutoverStageRequiresWitness canonicalCutoverPlan
        `shouldBe` [PlanActivateSingleReplacementWriter, PlanDeleteLegacyRouteAndIdentity]
      map
        (fmap admittedCutoverStage . admitCutoverStage replacement Nothing)
        canonicalCutoverPlan
        `shouldBe` map
          ( \stage ->
              if cutoverStageRequiresWitness stage
                then Left (CutoverStageWitnessMissing stage)
                else Right stage
          )
          canonicalCutoverPlan

    it "refuses to admit a witness-bearing stage for another identity" $ do
      input <- QualificationEvidence.validInput
      passed <- witnessFor (evidenceReplacementIdentity input)
      admitCutoverStage
        (evidenceSupersededIdentity input)
        (Just passed)
        PlanActivateSingleReplacementWriter
        `shouldBe` Left (CutoverStageWitnessMismatch PlanActivateSingleReplacementWriter)

    it "selects the legacy scan from the phase the ledger replays to" $ do
      map
        legacyScanModeForPhase
        [PreActivation, PostActivation, LegacyRouteDeleted, PostActivationQualified]
        `shouldBe` [ LegacyScanPreActivation
                   , LegacyScanPreActivation
                   , LegacyScanPostActivation
                   , LegacyScanPostActivation
                   ]
      input <- QualificationEvidence.validInput
      afterDeletion <- postDeletionIdentity input
      let before = deployment (evidenceReplacementIdentity input)
          after = deployment afterDeletion
          phaseAfter steps = cutoverPhaseOfLedger (ledgerPhase (fst (ledgerOf steps)))
          activated = preHistory before ++ [Activate ["pre-1", "pre-2"] before]
          deleted = activated ++ [DeleteRoute after]
      -- No ledger is the phase the validation has always scanned for.
      cutoverPhaseOfLedger (ledgerPhase emptyCycleLedger) `shouldBe` PreActivation
      map
        phaseAfter
        [ preHistory before
        , activated
        , deleted
        , deleted ++ postHistory after ++ [QualifyPost ["post-a", "post-b"] after]
        ]
        `shouldBe` [PreActivation, PostActivation, LegacyRouteDeleted, PostActivationQualified]

    it "resumes a state only on the tree the last mark was recorded on" $ do
      input <- QualificationEvidence.validInput
      afterDeletion <- postDeletionIdentity input
      let replacement = evidenceReplacementIdentity input
          before = deployment replacement
          phase = ledgerPhase (fst (ledgerOf (preHistory before ++ [Activate ["pre-1", "pre-2"] before])))
      -- Before the activating edit lands, the tree is still the recorded one.
      fmap someCutoverStatePhase (resumeCutoverState phase replacement)
        `shouldBe` Right PostActivation
      -- A tree that has moved on has a different identity and is refused, not relabelled.
      fmap someCutoverStatePhase (resumeCutoverState phase afterDeletion)
        `shouldBe` Left CutoverQualificationIdentityMismatch

    it "qualifies the post-deletion state only from the phase a deletion leaves it in" $ do
      input <- QualificationEvidence.validInput
      afterDeletion <- postDeletionIdentity input
      let replacement = evidenceReplacementIdentity input
          before = deployment replacement
          after = deployment afterDeletion
          deletedPhase =
            ledgerPhase
              ( fst
                  ( ledgerOf
                      (preHistory before ++ [Activate ["pre-1", "pre-2"] before, DeleteRoute after])
                  )
              )
      passed <- witnessFor afterDeletion
      resumed <- accepted (resumeCutoverState deletedPhase afterDeletion)
      qualifyResumedPostActivation passed resumed `shouldBe` Right PostActivationQualified
      -- A state resumed in another phase is refused.
      early <- accepted (resumeCutoverState (ledgerPhase emptyCycleLedger) replacement)
      qualifyResumedPostActivation passed early
        `shouldBe` Left (CutoverResumedPhaseUnexpected PreActivation)

    it "agrees with the typed machine about which cutover transitions are legal, in every order" $ do
      -- The ledger replays marks by key because the identity the typed state is
      -- indexed by cannot be recomputed after the activating edit. These are the
      -- same three transitions, so every order of them must be legal in both or
      -- in neither, step by step.
      input <- QualificationEvidence.validInput
      afterDeletion <- postDeletionIdentity input
      let replacement = evidenceReplacementIdentity input
          before = deployment replacement
          after = deployment afterDeletion
          allTransitions = [TransitionActivate, TransitionDelete, TransitionQualify]
          scripts = concatMap (\width -> mapM (const allTransitions) [1 .. width]) [0 .. 3 :: Int]
      activation <- witnessFor replacement
      qualification <- witnessFor afterDeletion
      let start = (MachinePre (initialCutoverState replacement), baseLedger before)
          advance (seen, (machine, ledger)) transition =
            let typed = typedStep activation qualification afterDeletion machine transition
                recorded = ledgerStep before after ledger transition
             in ( seen ++ [(isJust typed, isJust recorded)]
                , (fromMaybe machine typed, fromMaybe ledger recorded)
                )
          decisions script = fst (foldl advance ([], start) script)
      mapM_
        (\script -> mapM_ (\(typed, recorded) -> typed `shouldBe` recorded) (decisions script))
        scripts
      -- The legal path exists in both, and nothing else completes it.
      decisions [TransitionActivate, TransitionDelete, TransitionQualify]
        `shouldBe` [(True, True), (True, True), (True, True)]
      decisions [TransitionDelete, TransitionActivate]
        `shouldBe` [(False, False), (True, True)]
      decisions [TransitionActivate, TransitionActivate]
        `shouldBe` [(True, True), (False, False)]

    it "bounds pre-activation legacy sites and requires zero after deletion" $ do
      let sources =
            [ (path, fragment)
            | (path, fragment) <- registeredLegacyCutoverFragments
            ]
      legacyCutoverResidueViolations LegacyScanPreActivation sources `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation [] `shouldBe` []
      legacyCutoverResidueViolations LegacyScanPostActivation sources
        `shouldSatisfy` (not . null)

    it "reports a half-deleted legacy route rather than calling it a duplicate" $ do
      -- The bounded set is still bounded when a registered path stops mentioning
      -- a fragment that survives elsewhere, so the scan used to call that a
      -- duplication and carry a count that was not a duplication count. A
      -- partial removal is the more dangerous event of the two: the pre-
      -- activation scan would otherwise read the tree as unchanged while the
      -- legacy route had already been half-deleted underneath it.
      let halfDeleted =
            [ (path, fragment)
            | (path, fragment) <- registeredLegacyCutoverFragments
            , (path, fragment) /= ("src/Prodbox/CLI/Rke2.hs", "runNativeDeleteCascade")
            ]
      legacyCutoverResidueViolations LegacyScanPreActivation halfDeleted
        `shouldBe` [ LegacyCutoverFragmentAbsentFromPath
                       "src/Prodbox/CLI/Rke2.hs"
                       "runNativeDeleteCascade"
                   ]

    it "matches a registered fragment as a token, never as a substring" $ do
      -- `CascadePhaseOutcome` is a prefix of any longer constructor that starts
      -- with it, and a substring rule gets the answer wrong in both directions:
      -- it invents a site before activation and refuses to call the tree clean
      -- after deletion.
      legacyCutoverFragmentOccurs "CascadePhaseOutcome" "data CascadePhaseOutcome ="
        `shouldBe` True
      legacyCutoverFragmentOccurs "CascadePhaseOutcome" "data CascadePhaseOutcomeFrame ="
        `shouldBe` False
      legacyCutoverFragmentOccurs "runNativeDeleteCascade" "runNativeDeleteCascadeTwice x"
        `shouldBe` False
      legacyCutoverResidueViolations
        LegacyScanPostActivation
        [("src/Prodbox/CLI/Rke2.hs", "data CascadePhaseOutcomeFrame =")]
        `shouldBe` []

    it "covers every installed cascade terminal trace with stable bindings" $ do
      map installedTraceFault fixedInstalledCascadeTraces
        `shouldBe` [minBound .. maxBound]
      map installedTraceRunId fixedInstalledCascadeTraces
        `shouldBe` replicate 5 "cascade-candidate-regression"
      map installedTraceDisposition fixedInstalledCascadeTraces
        `shouldBe` [ InstalledCascadeComplete
                   , InstalledCascadeIncomplete
                   , InstalledCascadeIncomplete
                   , InstalledCascadeComplete
                   , InstalledCascadeComplete
                   ]
      mapM_
        ( \trace -> do
            installedTraceResourceKeys trace `shouldSatisfy` (not . null)
            installedTraceObservationAuthorities trace `shouldSatisfy` (not . null)
            renderInstalledCascadeTrace trace `shouldContain` "CLEANUP_RUN_ID="
        )
        fixedInstalledCascadeTraces

    it "resumes every replacement-cascade durable prefix exactly" $ do
      let prefixes =
            init
              ( scanl
                  (\prefix boundary -> prefix ++ [boundary])
                  []
                  canonicalReplacementCascadeBoundaries
              )
      map resumeReplacementCascadeBoundaries prefixes
        `shouldBe` map
          (Right . (`drop` canonicalReplacementCascadeBoundaries))
          [0 .. length canonicalReplacementCascadeBoundaries - 1]
      resumeReplacementCascadeBoundaries
        [StartRecoveryProfile, ObserveRegisteredTargets]
        `shouldBe` Left
          (ObserveRegisteredTargets, Just ReadBackRecoveryProfile)

takeThrough :: (Eq value) => value -> [value] -> [value]
takeThrough _ [] = []
takeThrough target (value : values)
  | target == value = [value]
  | otherwise = value : takeThrough target values

-- | The refusal a cutover step returned, if it refused.
--
-- A 'CutoverState' has no 'Eq': its whole point is that holding one is the
-- proof, so comparing two of them would be comparing proofs rather than
-- outcomes. The refusal is the part a test has anything to say about.
cutoverRefusal :: Either CutoverRefusal state -> Maybe CutoverRefusal
cutoverRefusal = either Just (const Nothing)

-- | The identity a qualified deletion produces.
--
-- Deleting the legacy route changes the source tree, so the resulting
-- deployment is a different identity from the one activation was qualified on
-- — which is the whole reason deletion returns qualification to pending. The
-- change has to be in the source manifest rather than in a digest field,
-- because the source manifest digest is what the qualification key and the
-- reused-identity check both compare, and a deletion that left it equal would
-- be a deletion that removed no source.
postDeletionIdentity :: QualificationEvidenceInput -> IO QualificationIdentity
postDeletionIdentity input = do
  deletedSource <- fixtureSourceIdentity "src/Prodbox/Test/New.hs" "new-without-legacy-route"
  pure
    ( (evidenceReplacementIdentity input)
        { qualificationSourceIdentity = deletedSource
        }
    )

-- | The step of the cutover each side of the conformance test is asked to take.
data Transition = TransitionActivate | TransitionDelete | TransitionQualify
  deriving (Eq, Show)

-- | The typed machine in whichever phase it is, so a script can try a step the
-- types would not let a caller write down.
data Machine
  = MachinePre (CutoverState 'PreActivation)
  | MachinePost (CutoverState 'PostActivation)
  | MachineDeleted (CutoverState 'LegacyRouteDeleted)
  | MachineQualified (CutoverState 'PostActivationQualified)

typedStep
  :: QualificationPassed
  -> QualificationPassed
  -> QualificationIdentity
  -> Machine
  -> Transition
  -> Maybe Machine
typedStep activation qualification afterDeletion machine transition =
  case (machine, transition) of
    (MachinePre state, TransitionActivate) ->
      either (const Nothing) (Just . MachinePost) (activateReplacement activation state)
    (MachinePost state, TransitionDelete) ->
      either (const Nothing) (Just . MachineDeleted) (deleteLegacyRoute activation afterDeletion state)
    (MachineDeleted state, TransitionQualify) ->
      either (const Nothing) (Just . MachineQualified) (qualifyPostActivation qualification state)
    _ -> Nothing

-- | The same step as a mark by key. A qualification is preceded by the two
-- post-deletion cycles that would license it, when the ledger is in the epoch
-- they count in; otherwise the mark is attempted on its own, to be refused.
ledgerStep :: Variant -> Variant -> CycleLedger -> Transition -> Maybe CycleLedger
ledgerStep before after ledger transition = case transition of
  TransitionActivate ->
    record ledger (markFor MarkActivated ["pre-1", "pre-2"] before ledger)
  TransitionDelete -> record ledger (deletionMarkFor after ledger)
  TransitionQualify
    | isPostEpoch ->
        let withCycles = fst (extendLedger (ledger, Map.empty) (postHistory after))
         in record withCycles (markFor MarkPostActivationQualified ["post-a", "post-b"] after withCycles)
    | otherwise ->
        record ledger (markFor MarkPostActivationQualified ["post-a", "post-b"] after ledger)
 where
  record target mark = either (const Nothing) (Just . fst) (appendRecord target (RecordCutoverMark mark))
  isPostEpoch = case epochOfLedger ledger of
    EpochPostActivation _ -> True
    _ -> False

-- | The ledger every script starts from: one qualifying pair, not yet activated.
baseLedger :: Variant -> CycleLedger
baseLedger before = fst (ledgerOf (preHistory before))

-- | The cycles of an identity's tree, as a deployment a history can run on.
deployment :: QualificationIdentity -> Variant
deployment = DeploymentParts . partsOfIdentity canonicalKeyPolicy

preHistory :: Variant -> [Step]
preHistory before = [Pass "pre-1" before, Pass "pre-2" before]

postHistory :: Variant -> [Step]
postHistory after = [Pass "post-a" after, Pass "post-b" after]

-- | The witness two consecutive qualifying cycles on exactly this identity earn.
witnessFor :: QualificationIdentity -> IO QualificationPassed
witnessFor identity = accepted (qualifyReplacement identity (proofForIdentity identity))

fixtureSourceIdentity :: String -> String -> IO SourceIdentity
fixtureSourceIdentity path contents = do
  headId <- accepted (mkGitHead "0123456789abcdef0123456789abcdef01234567")
  accepted
    ( mkSourceIdentity
        headId
        WorktreeDirty
        []
        [ SourceCandidate
            (Text.pack path)
            ManifestRegularFile
            0o644
            (ByteString8.pack contents)
        ]
    )

accepted :: (Show err) => Either err value -> IO value
accepted = either (fail . show) pure
