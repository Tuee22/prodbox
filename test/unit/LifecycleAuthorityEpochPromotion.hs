{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityEpochPromotion (lifecycleAuthorityEpochPromotionSuite) where

import Control.Monad (forM_)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import EpochPromotionFixture
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.MigrationEndpoint
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (..)
  , BackupRepairCommand (AssessBackupHealth)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.Authority.Submission (RequestDigest (RequestDigest))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent (ObserveOperationalIdentity))
import Prodbox.Runtime.Role (RuntimeRole (ProviderWorkerRuntime))
import TestSupport

lifecycleAuthorityEpochPromotionSuite :: SuiteBuilder ()
lifecycleAuthorityEpochPromotionSuite =
  describe "Sprint 6.5 frozen epoch promotion and final admission" $ do
    it "refuses the frozen aggregate's coarse activation even after all six old labels" $ do
      let commands = map PrepareBinding [minBound .. maxBound] ++ [ActivateReplacement target]
          final = applyCommands importedFrozenEpochAggregate commands
      activeAuthorityEpoch final `shouldSatisfy` isLeft
      retainedEpoch final `shouldBe` Just authorityEpochGenesis
      fst (stepAuthorityAdmission final (ApplyAuthorityMigration (ActivateReplacement target)))
        `shouldBe` AuthorityMigrationDecided (MigrationRefused StagedEpochPromotionRequired)

    it "prepares without changing the retained epoch or opening admission" $ do
      let states = scanCommands importedFrozenEpochAggregate (preparedEpochCommands 1 2)
      map retainedEpoch states `shouldBe` replicate (length states) (Just authorityEpochGenesis)
      map activeAuthorityEpoch states `shouldSatisfy` all isLeft

    it "commits the new epoch while every normal submission remains frozen" $ do
      let committed = applyCommands importedFrozenEpochAggregate (committedEpochCommands 1 2)
      retainedEpoch committed `shouldBe` authorityEpochFromValue 2
      activeAuthorityEpoch committed `shouldSatisfy` isLeft
      phaseOf committed `shouldBe` Just EpochFrozen

    it "opens only after every promotion and a second old-writer rejection readback" $ do
      let states = scanCommands importedFrozenEpochAggregate (epochPromotionCommands 1 2)
      map activeAuthorityEpoch (init states) `shouldSatisfy` all isLeft
      activeAuthorityEpoch (last states) `shouldBe` Right (fromJust (authorityEpochFromValue 2))
      phaseOf (last states) `shouldBe` Just EpochAdmissionOpen

    it "refuses a forged predecessor against the same retained aggregate CAS" $ do
      let command = PrepareReplacementEpoch (epochFixtureEpoch 2) (epochFixtureEpoch 3) epochTopologyFixture
          (decision, final) = stepAuthorityAdmission importedFrozenEpochAggregate (ApplyAuthorityMigration command)
      decision
        `shouldBe` AuthorityAdmissionCommandRefused
          (AuthorityMigrationEpochPredecessorMismatch authorityEpochGenesis 2)
      final `shouldBe` importedFrozenEpochAggregate

    it "refuses another epoch, topology or binding digest without changing progress" $ do
      let prepared = applyCommands importedFrozenEpochAggregate (take 1 (preparedEpochCommands 1 2))
          binding = Set.findMin (epochTopologyBindings epochTopologyFixture)
          wrong = fromJust (mkCutoverDigest (Text.replicate 64 "f"))
          requests =
            [ EpochPromotionRequest 3 epochTopologyFixtureDigest CommitFrozenEpoch
            , EpochPromotionRequest 2 wrong CommitFrozenEpoch
            , EpochPromotionRequest
                2
                epochTopologyFixtureDigest
                (ObservePreparedEpochBinding (EpochBindingReadback binding wrong))
            ]
      forM_ requests $ \request -> do
        let (decision, final) = stepAuthorityAdmission prepared (ApplyAuthorityMigration (ApplyPreparedEpochPromotion request))
        decision `shouldSatisfy` promotionRefused
        final `shouldBe` prepared

    forM_ (Set.toList (epochTopologyBindings epochTopologyFixture)) $ \binding -> do
      it ("refuses commit without prepared binding " ++ show binding) $ do
        let omitted = filter (not . prepares binding) (preparedEpochCommands 1 2)
            incomplete = applyCommands importedFrozenEpochAggregate omitted
        fst (stepAuthorityAdmission incomplete (ApplyAuthorityMigration (epochRequest 2 CommitFrozenEpoch)))
          `shouldBe` AuthorityMigrationDecided
            ( MigrationRefused
                (EpochPromotionProtocolRefused (PromotionPreparedBindingsMissing (Set.singleton binding)))
            )
        activeAuthorityEpoch incomplete `shouldSatisfy` isLeft
      it ("refuses final admission without promoted binding " ++ show binding) $ do
        let omitted = filter (not . promotes binding) (promotedEpochCommands 1 2)
            incomplete = applyCommands importedFrozenEpochAggregate omitted
        fst
          (stepAuthorityAdmission incomplete (ApplyAuthorityMigration (epochRequest 2 OpenEpochAdmission)))
          `shouldBe` AuthorityMigrationDecided
            (MigrationRefused (EpochPromotionProtocolRefused (PromotionReadbacksMissing (Set.singleton binding))))
        activeAuthorityEpoch incomplete `shouldSatisfy` isLeft

    forM_ (Set.toList (epochTopologyOldWriterBindings epochTopologyFixture)) $ \binding ->
      it ("requires old-writer rejection before and after commit: " ++ show binding) $ do
        let pre = filter (not . rejects binding) (preparedEpochCommands 1 2)
            incompletePre = applyCommands importedFrozenEpochAggregate pre
            committed = applyCommands importedFrozenEpochAggregate (committedEpochCommands 1 2)
            post = drop (length (committedEpochCommands 1 2)) (promotedEpochCommands 1 2)
            incompletePost = applyCommands committed (filter (not . rejects binding) post)
            expected =
              AuthorityMigrationDecided
                ( MigrationRefused
                    (EpochPromotionProtocolRefused (PromotionOldWriterRejectionReadbacksMissing (Set.singleton binding)))
                )
        fst
          (stepAuthorityAdmission incompletePre (ApplyAuthorityMigration (epochRequest 2 CommitFrozenEpoch)))
          `shouldBe` expected
        fst
          (stepAuthorityAdmission incompletePost (ApplyAuthorityMigration (epochRequest 2 OpenEpochAdmission)))
          `shouldBe` expected

    it "retires all prepared bindings before closing precommit rollback and never opens a writer" $ do
      let prepared = applyCommands importedFrozenEpochAggregate (preparedEpochCommands 1 2)
          rollingBack = applyCommands prepared [epochRequest 2 BeginPreparedEpochRollback]
          retired =
            applyCommands
              rollingBack
              [ epochRequest 2 (ObservePreparedEpochBindingAbsent binding)
              | binding <- Set.toList (epochTopologyBindings epochTopologyFixture)
              ]
          finished = applyCommands retired [epochRequest 2 FinishPreparedEpochRollback]
      fst
        ( stepAuthorityAdmission
            rollingBack
            (ApplyAuthorityMigration (epochRequest 2 FinishPreparedEpochRollback))
        )
        `shouldSatisfy` promotionRefused
      phaseOf finished `shouldBe` Just EpochPreparedBindingsRetired
      retainedEpoch finished `shouldBe` Just authorityEpochGenesis
      activeAuthorityEpoch finished `shouldSatisfy` isLeft
      fst (stepAuthorityAdmission finished (ApplyAuthorityMigration (epochRequest 2 OpenEpochAdmission)))
        `shouldSatisfy` promotionRefused

    it "requires greater-epoch recovery after the frozen commit, including before open" $ do
      forM_ [committedEpochCommands 1 2, epochPromotionCommands 1 2] $ \commands -> do
        let committed = applyCommands importedFrozenEpochAggregate commands
        fst
          ( stepAuthorityAdmission
              committed
              (ApplyAuthorityMigration (epochRequest 2 BeginPreparedEpochRollback))
          )
          `shouldBe` AuthorityMigrationDecided
            (MigrationRefused (EpochPromotionProtocolRefused PromotionRequiresGreaterEpochRecovery))
        let same = ApplyAuthorityForwardMigration (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 2))
            greater = ApplyAuthorityForwardMigration (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 3))
            (refused, _) = stepAuthorityAdmission committed same
            (accepted, forward) = stepAuthorityAdmission committed greater
            frozen = applyCommands forward [FreezeLegacy epochFixtureDigest]
            recovered = applyCommands frozen (epochPromotionCommands 2 3)
        refused
          `shouldBe` AuthorityForwardMigrationDecided (ForwardMigrationRefused ForwardMigrationEpochMustAdvance)
        accepted `shouldBe` AuthorityForwardMigrationDecided ForwardMigrationAccepted
        activeAuthorityEpoch forward `shouldSatisfy` isLeft
        activeAuthorityEpoch recovered `shouldBe` Right (fromJust (authorityEpochFromValue 3))

    it "round-trips every durable prefix with the staged state and command codecs" $ do
      let commands = epochPromotionCommands 1 2
          states = scanCommands importedFrozenEpochAggregate commands
      forM_ states $ \aggregate -> do
        validateAuthorityAdmissionAggregate 4 8 aggregate `shouldBe` Right ()
        case authorityAggregateMigration aggregate of
          AuthorityMigrationControlled migration -> decodeMigrationState 4096 (encodeMigrationState migration) `shouldBe` Right migration
          AuthorityCleanInstall -> expectationFailure "lost migration state"
      map (decodeMigrationCommand 4096 . encodeMigrationCommand) commands `shouldBe` map Right commands

    it "refuses to stage historical forward state without complete imported projections" $ do
      let oldCommands =
            [VerifyShadow epochFixtureDigest, FreezeLegacy epochFixtureDigest]
              ++ map PrepareBinding [minBound .. maxBound]
              ++ [ActivateReplacement (epochFixtureEpoch 2)]
          oldActive = foldl (\state command -> fst (stepMigration state command)) initialMigrationState oldCommands
          (forward, _) = stepForwardMigration oldActive (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 3))
          frozen = fst (stepMigration forward (FreezeLegacy epochFixtureDigest))
      stepMigration
        frozen
        (PrepareReplacementEpoch (epochFixtureEpoch 2) (epochFixtureEpoch 3) epochTopologyFixture)
        `shouldBe` (frozen, MigrationRefused (EpochPromotionImportsIncomplete requiredMigrationProjections))
      decodeMigrationState 4096 (encodeMigrationState frozen) `shouldBe` Right frozen

    it "composes an independently repaired retained epoch with frozen and open forward recovery" $ do
      forM_ [committedEpochCommands 1 2, epochPromotionCommands 1 2] $ \commands -> do
        let current = applyCommands importedFrozenEpochAggregate commands
            repaired = repairBackup current
            tooLow = ApplyAuthorityForwardMigration (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 3))
            greater = ApplyAuthorityForwardMigration (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 4))
            forward = applyEpochAggregateCommand repaired greater
            frozen = applyCommands forward [FreezeLegacy epochFixtureDigest]
            restored = applyCommands frozen (epochPromotionCommands 3 4)
        retainedEpoch repaired `shouldBe` authorityEpochFromValue 3
        activeAuthorityEpoch repaired `shouldSatisfy` isLeft
        stepAuthorityAdmission repaired tooLow
          `shouldBe` ( AuthorityForwardMigrationDecided (ForwardMigrationRefused ForwardMigrationEpochMustAdvance)
                     , repaired
                     )
        activeAuthorityEpoch restored `shouldBe` Right (fromJust (authorityEpochFromValue 4))
        validateAuthorityAdmissionAggregate 4 8 restored `shouldBe` Right ()

    it "retires precommit bindings before fresh preparation after backup repair advances the epoch" $ do
      let prepared = applyCommands importedFrozenEpochAggregate (preparedEpochCommands 1 2)
          repaired = repairBackup prepared
          commit = epochRequest 2 CommitFrozenEpoch
          rollingBack = applyCommands repaired [epochRequest 2 BeginPreparedEpochRollback]
          retired =
            applyCommands
              rollingBack
              ( [ epochRequest 2 (ObservePreparedEpochBindingAbsent binding)
                | binding <- Set.toList (epochTopologyBindings epochTopologyFixture)
                ]
                  ++ [epochRequest 2 FinishPreparedEpochRollback]
              )
          restored = applyCommands retired (epochPromotionCommands 2 3)
      retainedEpoch repaired `shouldBe` authorityEpochFromValue 2
      fst (stepAuthorityAdmission repaired (ApplyAuthorityMigration commit))
        `shouldSatisfy` admissionRefused
      activeAuthorityEpoch repaired `shouldSatisfy` isLeft
      activeAuthorityEpoch restored `shouldBe` Right (fromJust (authorityEpochFromValue 3))

    it "waits for exact Provider settlement while keeping its old operation identity readable" $ do
      let caller = CallerService ProviderWorkerRuntime
          generation = mustRight (mkRegisteredClientGeneration 1)
          slot = mustRight (mkRegisteredClientSlot 1)
          spec = mustRight (mkRegisteredClientSpec (clientPrincipalForCaller caller) slot generation 4)
          registry = mustRight (mkRegisteredClientTable 1 [spec])
          initial = importedFrozenEpochAggregateWithClients registry
          active = applyCommands initial (epochPromotionCommands 1 2)
          submissionKey = mustRight (mkClientSubmissionKey "cutover/pending-provider")
          digest = RequestDigest "cutover-pending-provider"
      (accepted, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              active
              caller
              generation
              submissionKey
              digest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      operation <- case accepted of
        AuthorityProviderSubmissionAccepted identifier -> pure identifier
        other -> expectationFailure (show other) >> fail "expected retained Provider operation"
      let forward =
            applyEpochAggregateCommand
              pending
              (ApplyAuthorityForwardMigration (BeginForwardMigration epochFixtureDigest (epochFixtureEpoch 3)))
          frozen = applyCommands forward [FreezeLegacy epochFixtureDigest]
          prepare =
            ApplyAuthorityMigration
              (PrepareReplacementEpoch (epochFixtureEpoch 2) (epochFixtureEpoch 3) epochTopologyFixture)
      stepAuthorityAdmission frozen prepare
        `shouldBe` (AuthorityAdmissionCommandRefused (AuthorityMigrationPendingProviderOperations 1), frozen)
      (settled, quiesced) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              caller
              generation
              operation
              ObserveOperationalIdentity
              "canonical-terminal-evidence"
              frozen
          )
      settled `shouldBe` AuthorityProviderSettlementCompleted
      let restored = applyCommands quiesced (epochPromotionCommands 2 3)
      activeAuthorityEpoch restored `shouldBe` Right (fromJust (authorityEpochFromValue 3))
      (duplicate, unchanged) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              restored
              caller
              generation
              submissionKey
              digest
              ObserveOperationalIdentity
              ProviderOperationUnownedByCleanupRun
          )
      duplicate
        `shouldBe` AuthorityProviderSubmissionDuplicateCompleted operation "canonical-terminal-evidence"
      unchanged `shouldBe` restored

    it "refuses a forged readback digest in the bounded request decoder" $ do
      let binding = Set.findMin (epochTopologyBindings epochTopologyFixture)
          encoded = encodeMigrationCommand (epochRequest 2 (ObservePreparedEpochBinding (epochReadback binding)))
          forged = LazyByteString.init encoded <> LazyByteString.singleton 10
      decodeMigrationCommand 4096 forged `shouldBe` Left MigrationEnvelopeInvalid

    let commands = epochPromotionCommands 1 2
        prefixes = scanCommands importedFrozenEpochAggregate commands
    forM_ (zip3 [0 :: Int ..] commands prefixes) $ \(index, command, prefix) ->
      it ("recovers a lost exact-revision CAS reply at durable transition " ++ show index) $ do
        stateRef <- newIORef prefix
        revisionRef <- newIORef (0 :: Word)
        let repository = responseLostRepository stateRef revisionRef
            body = encodeMigrationCommand command
        first <- serveAuthorityMigrationApply 65536 repository body
        migrationEndpointHttpStatus first `shouldBe` ReplyOk
        migrationEndpointSummary first `shouldBe` "migration-accepted"
        second <- serveAuthorityMigrationApply 65536 repository body
        migrationEndpointHttpStatus second `shouldBe` ReplyOk
        migrationEndpointSummary second `shouldBe` "migration-already-applied"
        readIORef revisionRef `shouldReturn` 1
        readIORef stateRef `shouldReturn` applyCommands prefix [command]

    describe "complete declared topology" $ do
      it "requires the retained home control plane" $
        mkEpochTopology (Set.singleton CutoverAws) Set.empty Set.empty Map.empty
          `shouldBe` Left EpochTopologyHomeMissing
      it "refuses a scope owned by an undeclared substrate" $
        mkEpochTopology
          (Set.singleton CutoverHome)
          (Set.singleton (CutoverAws, epochTopologyFixtureDigest))
          Set.empty
          Map.empty
          `shouldBe` Left EpochTopologyUndeclaredSubstrate
      forM_ (Set.toList (epochTopologyBindings epochTopologyFixture)) $ \binding ->
        it ("cannot discard declared binding " ++ show binding) $ do
          let substrates = Set.fromList [CutoverHome, CutoverAws]
              scopeDigest character = fromJust (mkCutoverDigest (Text.replicate 64 (Text.singleton character)))
              scopes = Set.fromList [(CutoverHome, scopeDigest 'a'), (CutoverAws, scopeDigest 'b')]
              dns = Set.fromList [(CutoverHome, scopeDigest 'c'), (CutoverAws, scopeDigest 'd')]
              rows =
                Map.fromSet
                  (fromJust . epochTopologyBindingDigest epochTopologyFixture)
                  (epochTopologyBindings epochTopologyFixture)
          mkEpochTopology substrates scopes dns (Map.delete binding rows)
            `shouldBe` Left (EpochTopologyBindingsDiffer (Set.singleton binding) Set.empty)
 where
  target = epochFixtureEpoch 2

applyCommands :: AuthorityAdmissionAggregate -> [MigrationCommand] -> AuthorityAdmissionAggregate
applyCommands =
  foldl (\aggregate command -> applyEpochAggregateCommand aggregate (ApplyAuthorityMigration command))

scanCommands :: AuthorityAdmissionAggregate -> [MigrationCommand] -> [AuthorityAdmissionAggregate]
scanCommands =
  scanl (\aggregate command -> applyEpochAggregateCommand aggregate (ApplyAuthorityMigration command))

retainedEpoch :: AuthorityAdmissionAggregate -> Maybe AuthorityEpoch
retainedEpoch = establishedEpoch . authorityAggregateAdmission

phaseOf :: AuthorityAdmissionAggregate -> Maybe EpochPromotionPhase
phaseOf aggregate = case authorityAggregateMigration aggregate of
  AuthorityCleanInstall -> Nothing
  AuthorityMigrationControlled migration -> epochPromotionPhase <$> migrationEpochPromotion migration

promotionRefused :: AuthorityAdmissionDecision -> Bool
promotionRefused decision = case decision of
  AuthorityMigrationDecided (MigrationRefused (EpochPromotionProtocolRefused _)) -> True
  _ -> False

admissionRefused :: AuthorityAdmissionDecision -> Bool
admissionRefused decision = case decision of
  AuthorityAdmissionCommandRefused _ -> True
  _ -> False

repairBackup :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
repairBackup aggregate =
  foldl
    applyEpochAggregateCommand
    aggregate
    [ ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable)
    , ApplyAuthorityBackupRepair (AssessBackupHealth BackupHealthy)
    ]

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id

prepares :: EpochTopologyBinding -> MigrationCommand -> Bool
prepares binding command = case command of
  ApplyPreparedEpochPromotion (EpochPromotionRequest _ _ (ObservePreparedEpochBinding readback)) -> readbackBinding readback == binding
  _ -> False

promotes :: EpochTopologyBinding -> MigrationCommand -> Bool
promotes binding command = case command of
  ApplyPreparedEpochPromotion (EpochPromotionRequest _ _ (ObservePromotedEpochBinding readback)) -> readbackBinding readback == binding
  _ -> False

rejects :: EpochTopologyBinding -> MigrationCommand -> Bool
rejects binding command = case command of
  ApplyPreparedEpochPromotion (EpochPromotionRequest _ _ (ObserveOldEpochRejected readback _)) -> readbackBinding readback == binding
  _ -> False

responseLostRepository
  :: IORef AuthorityAdmissionAggregate
  -> IORef Word
  -> AuthorityAdmissionRepository IO Word
responseLostRepository stateRef revisionRef =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        state <- readIORef stateRef
        revision <- readIORef revisionRef
        pure (Right (AuthorityAdmissionSnapshot revision state))
    , compareAndSwapAuthorityAdmission = \expected next -> do
        revision <- readIORef revisionRef
        if revision /= expected
          then pure (Left "lost exact revision")
          else do
            writeIORef stateRef next
            writeIORef revisionRef (revision + 1)
            pure (Left "reply lost after durable write")
    }

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO = either (fail . show) pure
