{-# LANGUAGE OverloadedStrings #-}

module QualificationTeardownCounterexample
  ( qualificationTeardownCounterexampleSuite
  )
where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Prodbox.CLI.Command (IntegrationSuite (..), TestScope (..))
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import Prodbox.Test.Qualification.TeardownCounterexample
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (ValidationTeardownRecovery)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

qualificationTeardownCounterexampleSuite :: SuiteBuilder ()
qualificationTeardownCounterexampleSuite =
  describe "stable TEARDOWN-2026-08-15 counterexample oracle" $ do
    it "loads every canonical artifact and exact frozen identity" $ do
      fixture <- loadCanonicalFixture
      frozenTeardownFixtureId fixture `shouldBe` canonicalTeardownFixtureId
      frozenTeardownEvidenceScope fixture `shouldBe` canonicalTeardownEvidenceScope
      teardownArtifactDigestText (frozenTeardownArtifactDigest fixture)
        `shouldBe` "ee72b06f35ecc6cddae9e318bfc1084f9c5f64736e0e927da904d738efe413f0"
      frozenTeardownRequests fixture
        `shouldBe` [ExactAwsEks, ExactAwsEksSubzone, ExactAwsTest]
      frozenTeardownAuditResources fixture
        `shouldBe` [ NormalizedAuditResource
                       canonicalRetainedBucketArn
                       ( Map.fromList
                           [ ("prodbox.io/managed-by", "prodbox")
                           , ("prodbox.io/role", "long-lived-pulumi-state")
                           ]
                       )
                   ]
      frozenTeardownExactObservations fixture
        `shouldBe` [ ExactStackObservation
                       stackKey
                       (OracleFailure "exact-stack-authority-not-serving")
                   | stackKey <- [minBound .. maxBound]
                   ]
      frozenTeardownCheckpointObservations fixture
        `shouldBe` [ CheckpointObservation
                       stackKey
                       (OracleFailure "primary-checkpoint-unobservable")
                   | stackKey <- [minBound .. maxBound]
                   ]

    it "binds distinct superseded and replacement source/composition identities" $ do
      fixture <- loadCanonicalFixture
      let superseded = frozenTeardownSupersededIdentity fixture
          replacement = frozenTeardownReplacementIdentity fixture
      superseded `shouldNotBe` replacement
      frozenSourceHead (frozenCompositionSource superseded)
        `shouldNotBe` frozenSourceHead (frozenCompositionSource replacement)
      Map.keys (frozenCompositionImages superseded)
        `shouldBe` ["legacy-cleanup-runner"]
      Map.keys (frozenCompositionImages replacement)
        `shouldBe` [ "backup-adapter"
                   , "lifecycle-authority"
                   , "provider-worker"
                   , "recovery-runner"
                   ]

    it "loads the exhaustive 25-row external-state disposition table" $ do
      fixture <- loadCanonicalFixture
      let rows = frozenTeardownExternalStateRows fixture
      length rows `shouldBe` 25
      map externalStateRowCase rows `shouldBe` [minBound .. maxBound]
      externalDisposition rows ExternalAwsAbsent
        `shouldBe` RecoveryAlreadyAppliedReadBack
      externalDisposition rows ExternalAwsPresent
        `shouldBe` RecoveryResumeCommittedIntent
      externalDisposition rows ExternalAwsPartial
        `shouldBe` RecoverySuccessorBlockedAmbiguous
      externalDisposition rows ExternalAwsUnobservable
        `shouldBe` RecoverySuccessorBlockedAmbiguous
      externalDisposition rows ExternalAuthorityLoss
        `shouldBe` RecoveryFailClosedRefusal

    it "covers both sides of every durable transition for all interruption kinds" $ do
      fixture <- loadCanonicalFixture
      let transitions = frozenTeardownDurableTransitions fixture
          schedule = frozenTeardownInterruptionSchedule fixture
          expectedKeys =
            [ (interruptionKind, interruptionSide, durableTransitionId transition)
            | transition <- transitions
            , interruptionKind <- [minBound .. maxBound]
            , interruptionSide <- [minBound .. maxBound]
            ]
          observedKeys =
            [ ( interruptionScheduleKind row
              , interruptionScheduleSide row
              , durableTransitionId (interruptionScheduleTransition row)
              )
            | row <- schedule
            ]
      length transitions `shouldBe` 8
      length schedule `shouldBe` 80
      sort observedKeys `shouldBe` sort expectedKeys
      length (nub observedKeys) `shouldBe` 80
      map interruptionScheduleRunScope schedule
        `shouldBe` replicate 80 (teardownScopeRun canonicalTeardownEvidenceScope)
      map
        (durableTransitionOperationId . interruptionScheduleTransition)
        schedule
        `shouldSatisfy` all (Text.isPrefixOf "teardown-op-")
      mapM_
        ( \row ->
            interruptionScheduleDisposition row
              `shouldBe` case interruptionScheduleSide row of
                InterruptBefore -> RecoveryResumeCommittedIntent
                InterruptAfter -> RecoveryAlreadyAppliedReadBack
        )
        schedule

    it "keeps causal totals equal while preserving a distinct justified production profile" $ do
      fixture <- loadCanonicalFixture
      let causal = frozenTeardownCausalProfile fixture
          production = frozenTeardownProductionProfile fixture
      profile_id causal `shouldBe` "teardown-causal-v1"
      profile_kind causal `shouldBe` "causal"
      independently_justified causal `shouldBe` False
      fault_schedule causal
        `shouldBe` map durableTransitionId (frozenTeardownDurableTransitions fixture)
      profileTotals (superseded_envelopes causal)
        `shouldBe` profileTotals (replacement_envelopes causal)
      profileTotals (superseded_envelopes causal)
        `shouldBe` ResourceTotals 1000 1024 1024 1024
      profile_id production `shouldBe` "teardown-production-v1"
      profile_kind production `shouldBe` "production"
      independently_justified production `shouldBe` True
      fault_schedule production `shouldBe` fault_schedule causal
      profileTotals (superseded_envelopes production)
        `shouldBe` profileTotals (replacement_envelopes production)
      profileTotals (superseded_envelopes production)
        `shouldBe` ResourceTotals 1600 2048 2048 2048
      production `shouldNotBe` causal

    it "reproduces the superseded false three-stack global-copy classification" $ do
      fixture <- loadCanonicalFixture
      let superseded = supersededGlobalCopyOracle fixture
          copied = supersededCopiedExactPresence superseded
      length (supersededDecodedAuditRows superseded) `shouldBe` 2
      supersededAuditArns superseded
        `shouldBe` replicate 2 canonicalRetainedBucketArn
      Map.keys copied `shouldBe` [ExactAwsEks, ExactAwsEksSubzone, ExactAwsTest]
      Map.elems copied
        `shouldBe` replicate 3 (replicate 2 canonicalRetainedBucketArn)
      supersededDrainSelection superseded
        `shouldBe` DrainSelected DrainAwsEks
      awsAuditArnText canonicalRetainedBucketArn
        `shouldSatisfy` Text.isPrefixOf "arn:aws:s3:::"

    it "preserves retained narration, three Unobservable stacks, and both failures" $ do
      fixture <- loadCanonicalFixture
      let replacement = replacementTeardownOracle fixture
      replacementRetainedAuditArns replacement
        `shouldBe` [canonicalRetainedBucketArn]
      replacementExactUnobservables replacement
        `shouldBe` Map.fromList
          [ (stackKey, OracleFailure "exact-stack-authority-not-serving")
          | stackKey <- [minBound .. maxBound]
          ]
      replacementCheckpointUnobservables replacement
        `shouldBe` Map.fromList
          [ (stackKey, OracleFailure "primary-checkpoint-unobservable")
          | stackKey <- [minBound .. maxBound]
          ]
      replacementDrainSelection replacement `shouldBe` NoDrainSelected
      replacementDestroySelection replacement `shouldBe` NoDestroySelected
      replacementCascadeResult replacement
        `shouldBe` CascadeIncomplete
          ( CallerFailure
              "local-cascade-caller"
              (OracleFailure "lifecycle-authority-caller-unobservable")
          )
          [ CleanupFailure
              "lifecycle-authority"
              (OracleFailure "lifecycle-authority-unobservable")
          ]
      replacementReportObservation replacement
        `shouldBe` ReportObservation "teardown-final-report" 1 1

    it "runs all seven typed fake boundaries in deterministic exact-key order" $ do
      fixture <- loadCanonicalFixture
      requestTrace <- newIORef []
      let fixtureId = frozenTeardownFixtureId fixture
          scope = frozenTeardownEvidenceScope fixture
          record request response = do
            modifyIORef' requestTrace (++ [request])
            pure (Right response)
          interpreter =
            mkTeardownRecoveryInterpreter
              ( \observedFixture observedScope stackKey ->
                  record
                    (TeardownRecoveryProviderRequest observedFixture observedScope stackKey)
                    (exactFixtureObservation fixture stackKey)
              )
              ( \observedFixture observedScope stackKey ->
                  record
                    (TeardownRecoveryCheckpointRequest observedFixture observedScope stackKey)
                    (checkpointFixtureObservation fixture stackKey)
              )
              ( \observedFixture observedScope ->
                  record
                    (TeardownRecoveryAuditRequest observedFixture observedScope)
                    (frozenTeardownAuditResources fixture)
              )
              ( \observedFixture observedScope identity ->
                  record
                    (TeardownRecoveryKubernetesRequest observedFixture observedScope identity)
                    (frozenTeardownCallerObservation fixture)
              )
              ( \observedFixture observedScope identity ->
                  record
                    (TeardownRecoveryAuthorityRequest observedFixture observedScope identity)
                    (frozenTeardownAuthorityObservation fixture)
              )
              ( \observedFixture observedScope identity ->
                  record
                    (TeardownRecoveryBackupRequest observedFixture observedScope identity)
                    (frozenTeardownBackupObservation fixture)
              )
              ( \observedFixture observedScope identity ->
                  record
                    (TeardownRecoveryReportRequest observedFixture observedScope identity)
                    (frozenTeardownReportObservation fixture)
              )
      result <- runTeardownRecoveryOracle fixture interpreter
      result `shouldBe` Right (replacementTeardownOracle fixture)
      observed <- readIORef requestTrace
      observed
        `shouldBe` [ TeardownRecoveryProviderRequest fixtureId scope ExactAwsEks
                   , TeardownRecoveryProviderRequest fixtureId scope ExactAwsEksSubzone
                   , TeardownRecoveryProviderRequest fixtureId scope ExactAwsTest
                   , TeardownRecoveryCheckpointRequest fixtureId scope ExactAwsEks
                   , TeardownRecoveryCheckpointRequest fixtureId scope ExactAwsEksSubzone
                   , TeardownRecoveryCheckpointRequest fixtureId scope ExactAwsTest
                   , TeardownRecoveryAuditRequest fixtureId scope
                   , TeardownRecoveryKubernetesRequest fixtureId scope "local-cascade-caller"
                   , TeardownRecoveryAuthorityRequest fixtureId scope "lifecycle-authority"
                   , TeardownRecoveryBackupRequest fixtureId scope "retained-report-backup"
                   , TeardownRecoveryReportRequest fixtureId scope "teardown-final-report"
                   ]

    it "refuses a missing request at each typed fake boundary" $ do
      fixture <- loadCanonicalFixture
      let fixtureId = frozenTeardownFixtureId fixture
          scope = frozenTeardownEvidenceScope fixture
          missingRequests =
            [ TeardownRecoveryProviderRequest fixtureId scope ExactAwsEks
            , TeardownRecoveryCheckpointRequest fixtureId scope ExactAwsEks
            , TeardownRecoveryAuditRequest fixtureId scope
            , TeardownRecoveryKubernetesRequest fixtureId scope "local-cascade-caller"
            , TeardownRecoveryAuthorityRequest fixtureId scope "lifecycle-authority"
            , TeardownRecoveryBackupRequest fixtureId scope "retained-report-backup"
            , TeardownRecoveryReportRequest fixtureId scope "teardown-final-report"
            ]
      mapM_
        ( \missingRequest -> do
            result <-
              runTeardownRecoveryOracle
                fixture
                (interpreterMissing fixture missingRequest)
            result
              `shouldBe` Left
                ( TeardownRecoveryFakeRefused
                    (TeardownRecoveryFakeRequestMissing missingRequest)
                )
        )
        missingRequests

    it "refuses wrong-key and altered provider/checkpoint observations" $ do
      fixture <- loadCanonicalFixture
      let canonical = canonicalCallbacks fixture
          wrongProvider =
            mkTeardownRecoveryInterpreter
              ( \fixtureId scope stackKey ->
                  if stackKey == ExactAwsEks
                    then
                      pure
                        (Right (ExactStackObservation ExactAwsTest (OracleFailure "exact-stack-authority-not-serving")))
                    else providerCallback canonical fixtureId scope stackKey
              )
              (checkpointCallback canonical)
              (auditCallback canonical)
              (kubernetesCallback canonical)
              (authorityCallback canonical)
              (backupCallback canonical)
              (reportCallback canonical)
          alteredCheckpoint =
            mkTeardownRecoveryInterpreter
              (providerCallback canonical)
              ( \fixtureId scope stackKey ->
                  if stackKey == ExactAwsEks
                    then pure (Right (CheckpointObservation ExactAwsEks (OracleFailure "forged-checkpoint")))
                    else checkpointCallback canonical fixtureId scope stackKey
              )
              (auditCallback canonical)
              (kubernetesCallback canonical)
              (authorityCallback canonical)
              (backupCallback canonical)
              (reportCallback canonical)
      wrongProviderResult <- runTeardownRecoveryOracle fixture wrongProvider
      wrongProviderResult
        `shouldBe` Left (TeardownRecoveryProviderKeyMismatch ExactAwsEks ExactAwsTest)
      alteredCheckpointResult <- runTeardownRecoveryOracle fixture alteredCheckpoint
      alteredCheckpointResult
        `shouldBe` Left
          ( TeardownRecoveryCheckpointMismatch
              ExactAwsEks
              (CheckpointObservation ExactAwsEks (OracleFailure "primary-checkpoint-unobservable"))
              (CheckpointObservation ExactAwsEks (OracleFailure "forged-checkpoint"))
          )

    it "refuses the committed external-state mutation fixture" $ do
      repoRoot <- getCurrentDirectory
      result <- loadTeardownCounterexampleFixture repoRoot MutatedTeardownTrace
      case result of
        Left
          ( TeardownExternalStateDispositionMismatch
              ExternalAwsUnobservable
              RecoverySuccessorBlockedAmbiguous
              RecoveryResumeCommittedIntent
            ) -> pure ()
        Left err -> expectationFailure ("unexpected mutation refusal: " ++ show err)
        Right _ -> expectationFailure "the committed mutation fixture passed"

    it "refuses missing and duplicated external-state or interruption rows" $ do
      (trace, dispositions, causal, production) <- readCanonicalArtifacts
      let missingExternal = dropArtifactLine "external aws-unobservable " dispositions
          duplicateExternal = dispositions <> "external aws-absent already-applied-readback\n"
          missingInterrupt =
            dropArtifactLine "interrupt restart after commit-terminal-report " dispositions
          wrongRunBinding =
            Text.replace
              "interrupt ctrl-c before register-run same-run"
              "interrupt ctrl-c before register-run wrong-run"
              dispositions
          wrongOperationBinding =
            Text.replace
              "interrupt ctrl-c before register-run same-run same-operation"
              "interrupt ctrl-c before register-run same-run wrong-operation"
              dispositions
      missingExternalResult <-
        parseTeardownCounterexampleArtifacts trace missingExternal causal production
      missingExternalResult
        `shouldBe` Left (TeardownExternalStateInventoryIncomplete [ExternalAwsUnobservable])
      duplicateExternalResult <-
        parseTeardownCounterexampleArtifacts trace duplicateExternal causal production
      duplicateExternalResult
        `shouldBe` Left (TeardownExternalStateDuplicate ExternalAwsAbsent)
      missingInterruptResult <-
        parseTeardownCounterexampleArtifacts trace missingInterrupt causal production
      missingInterruptResult
        `shouldBe` Left (TeardownInterruptionInventoryIncomplete 80 79)
      wrongRunResult <-
        parseTeardownCounterexampleArtifacts trace wrongRunBinding causal production
      wrongRunResult `shouldSatisfy` isLeft
      wrongOperationResult <-
        parseTeardownCounterexampleArtifacts trace wrongOperationBinding causal production
      wrongOperationResult `shouldSatisfy` isLeft

    it "refuses mutations across every trace identity/key/scope/cardinality class" $ do
      (trace, dispositions, causal, production) <- readCanonicalArtifacts
      let replacements =
            [ ("fixture-id TEARDOWN-2026-08-15", "fixture-id TEARDOWN-2026-08-15-mutated")
            , ("run-scope teardown-2026-08-15-run-0001", "run-scope wrong-run")
            , ("registry-revision lifecycle-registry/v1", "registry-revision lifecycle-registry/v2")
            , ("surface cascade", "surface explicit")
            , ("operation reconcile-desired-absent", "operation wrong-operation")
            , ("foundation home-linux-rke2", "foundation wrong-foundation")
            , ("aws-account 111122223333", "aws-account 000000000000")
            , ("aws-region ca-central-1", "aws-region us-east-1")
            , ("source-head superseded 5a40", "source-head superseded 6a40")
            , ("source-dirty superseded true", "source-dirty superseded false")
            , ("source-policy-version superseded 1", "source-policy-version superseded 2")
            , ("source-policy-id superseded teardown-source-allowlist", "source-policy-id superseded changed")
            , ("source-policy-digest superseded 8ae0", "source-policy-digest superseded 9ae0")
            , ("source-manifest-digest superseded 68da", "source-manifest-digest superseded 78da")
            , ("generated-config-digest superseded", "generated-config-digest replacement")
            , ("topology-digest superseded", "topology-digest replacement")
            , ("wiring-digest superseded", "wiring-digest replacement")
            , ("component-image superseded legacy-cleanup-runner", "component-image superseded changed")
            , ("prodbox.io/role long-lived-pulumi-state", "prodbox.io/role wrong-role")
            , ("request aws-test", "request aws-eks")
            , ("provider aws-test unobservable", "provider aws-test absent")
            , ("checkpoint aws-test unobservable", "checkpoint aws-test absent")
            , ("kubernetes local-cascade-caller", "kubernetes wrong-caller")
            , ("authority lifecycle-authority", "authority wrong-authority")
            , ("backup retained-report-backup", "backup wrong-backup")
            , ("report teardown-final-report committed 1 1", "report teardown-final-report committed 0 0")
            , ("transition commit-terminal-report", "transition wrong-terminal-report")
            , ("teardown-op-terminal-report", "teardown-op-wrong-terminal-report")
            ]
      mapM_
        ( \(before, after) -> do
            result <-
              parseTeardownCounterexampleArtifacts
                (Text.replace before after trace)
                dispositions
                causal
                production
            result `shouldSatisfy` isLeft
        )
        replacements
      missingTagResult <-
        parseTeardownCounterexampleArtifacts
          (dropArtifactLine "tag-row arn:aws:s3:::prodbox-retained-state-fixture prodbox.io/role" trace)
          dispositions
          causal
          production
      missingTagResult `shouldSatisfy` isLeft

    it "refuses mutations across every causal/production profile field class" $ do
      (trace, dispositions, causal, production) <- readCanonicalArtifacts
      let causalMutations =
            [ ("format_version = 1", "format_version = 2")
            , ("fixture_id = \"TEARDOWN-2026-08-15\"", "fixture_id = \"wrong\"")
            , ("profile_id = \"teardown-causal-v1\"", "profile_id = \"wrong\"")
            , ("profile_kind = \"causal\"", "profile_kind = \"wrong\"")
            , ("request_rate_per_second = 4", "request_rate_per_second = 5")
            , ("concurrent_clients = 2", "concurrent_clients = 3")
            , ("payload_bytes = 1024", "payload_bytes = 1025")
            , ("\"commit-independent-readback\"", "\"wrong-readback\"")
            , ("fault_schedule_digest = \"8493", "fault_schedule_digest = \"9493")
            , ("independently_justified = False", "independently_justified = True")
            , ("cpu_millis = 1000", "cpu_millis = 999")
            , ("memory_mib = 1024", "memory_mib = 1023")
            , ("ephemeral_mib = 1024", "ephemeral_mib = 1023")
            , ("persistence_mib = 1024", "persistence_mib = 1023")
            , ("superseded_component = \"legacy-cleanup-runner\"", "superseded_component = \"wrong\"")
            , ("\"recovery-runner\"", "\"wrong-runner\"")
            ]
      mapM_
        ( \(before, after) -> do
            result <-
              parseTeardownCounterexampleArtifacts
                trace
                dispositions
                (Text.replace before after causal)
                production
            case result of
              Left (TeardownProfileDigestMismatch CausalProfileArtifact _ _) -> pure ()
              Left err -> expectationFailure ("unexpected profile refusal: " ++ show err)
              Right _ -> expectationFailure "mutated causal profile passed"
        )
        causalMutations
      productionResult <-
        parseTeardownCounterexampleArtifacts
          trace
          dispositions
          causal
          (Text.replace "independently_justified = True" "independently_justified = False" production)
      case productionResult of
        Left (TeardownProfileDigestMismatch ProductionProfileArtifact _ _) -> pure ()
        Left err -> expectationFailure ("unexpected production profile refusal: " ++ show err)
        Right _ -> expectationFailure "mutated production profile passed"

    it "bounds each artifact before decoding" $
      withSystemTempDirectory "prodbox-teardown-bounds" $ \temporaryRoot -> do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        let qualification = temporaryRoot </> "test" </> "qualification"
        createDirectoryIfMissing True qualification
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.trace")
          (Text.replicate 65537 "x")
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.dispositions")
          dispositions
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.causal-profile.dhall")
          causal
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.production-profile.dhall")
          production
        result <- loadTeardownCounterexample temporaryRoot
        result `shouldBe` Left (TeardownArtifactUnbounded TraceArtifact 65536 65537)
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.trace")
          trace
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.dispositions")
          (Text.replicate 131073 "x")
        dispositionsResult <- loadTeardownCounterexample temporaryRoot
        dispositionsResult
          `shouldBe` Left
            (TeardownArtifactUnbounded DispositionsArtifact 131072 131073)
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.dispositions")
          dispositions
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.causal-profile.dhall")
          (Text.replicate 32769 "x")
        causalResult <- loadTeardownCounterexample temporaryRoot
        causalResult
          `shouldBe` Left
            (TeardownArtifactUnbounded CausalProfileArtifact 32768 32769)
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.causal-profile.dhall")
          causal
        TextIO.writeFile
          (qualification </> "TEARDOWN-2026-08-15.production-profile.dhall")
          (Text.replicate 32769 "x")
        productionResult <- loadTeardownCounterexample temporaryRoot
        productionResult
          `shouldBe` Left
            (TeardownArtifactUnbounded ProductionProfileArtifact 32768 32769)

    it "keeps this oracle production-independent, credential-free, and residue-input-free" $ do
      source <- TextIO.readFile "src/Prodbox/Test/Qualification/TeardownCounterexample.hs"
      validationSource <- TextIO.readFile "src/Prodbox/Test/CounterexampleValidation.hs"
      source `shouldSatisfy` (not . Text.isInfixOf "import Prodbox.Lifecycle")
      source `shouldSatisfy` (not . Text.isInfixOf "import Prodbox.CLI")
      source `shouldSatisfy` (not . Text.isInfixOf "PRODBOX_TEST_RESIDUE_ABSENT")
      validationSource
        `shouldSatisfy` (not . Text.isInfixOf "PRODBOX_TEST_RESIDUE_ABSENT")
      artifacts <- readCanonicalArtifacts
      let lowered = Text.toLower (foldArtifacts artifacts)
      mapM_
        (\forbidden -> lowered `shouldSatisfy` (not . Text.isInfixOf forbidden))
        [ "aws_secret_access_key"
        , "aws_access_key_id"
        , "password="
        , "private-key"
        , "begin private key"
        ]

    it "plans the named command as a credential-free native validation" $ do
      let plan =
            testExecutionPlan
              SubstrateHomeLocal
              (TestIntegration IntegrationTeardownRecovery)
      testPlanLabel plan `shouldBe` "integration teardown-recovery"
      testPlanHaskellSuites plan `shouldBe` []
      case testPlanExecutionMode plan of
        DelegatedSuite _ -> expectationFailure "expected a native teardown-recovery plan"
        NativeSuite suitePlan -> do
          nativeSuiteId suitePlan `shouldBe` "integration-teardown-recovery"
          nativeValidations suitePlan `shouldBe` [ValidationTeardownRecovery]
          nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
          nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []
          nativeManagedAwsHarnessPolicyTier suitePlan `shouldBe` Nothing
          nativeRequiresIntegrationRunbook suitePlan `shouldBe` False
          nativeRequiresSupportedRuntimeBootstrap suitePlan `shouldBe` False
          nativeRequiresSupportedRuntimePostflight suitePlan `shouldBe` False

data CanonicalCallbacks m = CanonicalCallbacks
  { providerCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> ExactStackKey
      -> m (Either TeardownRecoveryFakeFailure ExactStackObservation)
  , checkpointCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> ExactStackKey
      -> m (Either TeardownRecoveryFakeFailure CheckpointObservation)
  , auditCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> m (Either TeardownRecoveryFakeFailure [NormalizedAuditResource])
  , kubernetesCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure LocalCallerObservation)
  , authorityCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure AuthorityObservation)
  , backupCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure BackupObservation)
  , reportCallback
      :: TeardownFixtureId
      -> TeardownEvidenceScope
      -> Text
      -> m (Either TeardownRecoveryFakeFailure ReportObservation)
  }

canonicalCallbacks :: (Applicative m) => FrozenTeardownCounterexample -> CanonicalCallbacks m
canonicalCallbacks fixture =
  CanonicalCallbacks
    { providerCallback = \_ _ stackKey -> pure (Right (exactFixtureObservation fixture stackKey))
    , checkpointCallback = \_ _ stackKey -> pure (Right (checkpointFixtureObservation fixture stackKey))
    , auditCallback = \_ _ -> pure (Right (frozenTeardownAuditResources fixture))
    , kubernetesCallback = \_ _ _ -> pure (Right (frozenTeardownCallerObservation fixture))
    , authorityCallback = \_ _ _ -> pure (Right (frozenTeardownAuthorityObservation fixture))
    , backupCallback = \_ _ _ -> pure (Right (frozenTeardownBackupObservation fixture))
    , reportCallback = \_ _ _ -> pure (Right (frozenTeardownReportObservation fixture))
    }

interpreterMissing
  :: (Applicative m)
  => FrozenTeardownCounterexample
  -> TeardownRecoveryRequestIdentity
  -> TeardownRecoveryInterpreter m
interpreterMissing fixture missingRequest =
  let canonical = canonicalCallbacks fixture
      missing request fallback =
        if request == missingRequest
          then pure (Left (TeardownRecoveryFakeRequestMissing request))
          else fallback
   in mkTeardownRecoveryInterpreter
        ( \fixtureId scope stackKey ->
            missing
              (TeardownRecoveryProviderRequest fixtureId scope stackKey)
              (providerCallback canonical fixtureId scope stackKey)
        )
        ( \fixtureId scope stackKey ->
            missing
              (TeardownRecoveryCheckpointRequest fixtureId scope stackKey)
              (checkpointCallback canonical fixtureId scope stackKey)
        )
        ( \fixtureId scope ->
            missing
              (TeardownRecoveryAuditRequest fixtureId scope)
              (auditCallback canonical fixtureId scope)
        )
        ( \fixtureId scope identity ->
            missing
              (TeardownRecoveryKubernetesRequest fixtureId scope identity)
              (kubernetesCallback canonical fixtureId scope identity)
        )
        ( \fixtureId scope identity ->
            missing
              (TeardownRecoveryAuthorityRequest fixtureId scope identity)
              (authorityCallback canonical fixtureId scope identity)
        )
        ( \fixtureId scope identity ->
            missing
              (TeardownRecoveryBackupRequest fixtureId scope identity)
              (backupCallback canonical fixtureId scope identity)
        )
        ( \fixtureId scope identity ->
            missing
              (TeardownRecoveryReportRequest fixtureId scope identity)
              (reportCallback canonical fixtureId scope identity)
        )

loadCanonicalFixture :: IO FrozenTeardownCounterexample
loadCanonicalFixture = do
  repoRoot <- getCurrentDirectory
  result <- loadTeardownCounterexample repoRoot
  case result of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right fixture -> pure fixture

readCanonicalArtifacts :: IO (Text, Text, Text, Text)
readCanonicalArtifacts = do
  repoRoot <- getCurrentDirectory
  trace <- TextIO.readFile (teardownTraceFixturePath repoRoot)
  dispositions <-
    TextIO.readFile (teardownDispositionsFixturePath repoRoot CanonicalTeardownTrace)
  causal <- TextIO.readFile (teardownCausalProfileFixturePath repoRoot)
  production <- TextIO.readFile (teardownProductionProfileFixturePath repoRoot)
  pure (trace, dispositions, causal, production)

foldArtifacts :: (Text, Text, Text, Text) -> Text
foldArtifacts (trace, dispositions, causal, production) =
  Text.intercalate "\NUL" [trace, dispositions, causal, production]

dropArtifactLine :: Text -> Text -> Text
dropArtifactLine prefix contents =
  Text.unlines
    [ line
    | line <- Text.lines contents
    , not (prefix `Text.isPrefixOf` Text.strip line)
    ]

externalDisposition
  :: [ExternalStateDispositionRow]
  -> ExternalStateCase
  -> RecoveryReferenceDisposition
externalDisposition rows externalState =
  case [ externalStateRowDisposition row
       | row <- rows
       , externalStateRowCase row == externalState
       ] of
    [disposition] -> disposition
    _ -> error "canonical fixture lost an external-state disposition"

exactFixtureObservation
  :: FrozenTeardownCounterexample -> ExactStackKey -> ExactStackObservation
exactFixtureObservation fixture stackKey =
  case [ observation
       | observation <- frozenTeardownExactObservations fixture
       , exactObservationKey observation == stackKey
       ] of
    [observation] -> observation
    _ -> error "canonical fixture lost an exact provider observation"

checkpointFixtureObservation
  :: FrozenTeardownCounterexample -> ExactStackKey -> CheckpointObservation
checkpointFixtureObservation fixture stackKey =
  case [ observation
       | observation <- frozenTeardownCheckpointObservations fixture
       , checkpointObservationKey observation == stackKey
       ] of
    [observation] -> observation
    _ -> error "canonical fixture lost an exact checkpoint observation"

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False
