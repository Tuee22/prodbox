{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.41: the frozen @CREATE-INTERRUPTED-2026-09-08@ family.
--
-- The cases here are about the two things a frozen counterexample has to be
-- able to do, and which a family that only parses cannot: separate the
-- implementation that fails from the one that does not, and fail when its own
-- committed matrix is wrong.
module QualificationCreateInterruptedCounterexample
  ( qualificationCreateInterruptedCounterexampleSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Prodbox.CLI.Command (IntegrationSuite (..), TestScope (..))
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import Prodbox.Test.Qualification.CounterexampleProfile
import Prodbox.Test.Qualification.CreateInterruptedCounterexample
import Prodbox.TestPlan
  ( NativeSuitePlan (..)
  , NativeValidation (ValidationCreateInterrupted)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

qualificationCreateInterruptedCounterexampleSuite :: SuiteBuilder ()
qualificationCreateInterruptedCounterexampleSuite =
  describe "stable CREATE-INTERRUPTED-2026-09-08 counterexample oracle" $ do
    describe "the committed family" $ do
      it "loads every canonical artifact and exact frozen identity" $ do
        fixture <- loadCanonicalFixture
        frozenCreateFixtureId fixture `shouldBe` canonicalCreateFixtureId
        frozenCreateEvidenceScope fixture `shouldBe` canonicalCreateEvidenceScope
        map declaredCoordinateName (frozenCreateDeclaredCoordinates fixture)
          `shouldBe` [ "aws-eks-vpc"
                     , "aws-eks-cluster"
                     , "aws-eks-node-group"
                     , "aws-eks-node-role"
                     , "aws-eks-node-role-policy"
                     ]
        map observedIdentityCoordinate (frozenCreateObservedIdentities fixture)
          `shouldBe` map declaredCoordinateName (frozenCreateDeclaredCoordinates fixture)
        frozenCreateProviderTags fixture
          `shouldBe` [ ProviderTagRow
                         "prodbox.io/run-scope"
                         "stack-create/1757318400000000"
                     , ProviderTagRow
                         "prodbox.io/submission"
                         "operator-reconcile-aws-eks-0001"
                     ]

      it "carries the complete derived matrices and nothing else" $ do
        fixture <- loadCanonicalFixture
        frozenCreateInterruptionMatrix fixture `shouldBe` canonicalInterruptionMatrix
        frozenCreateExternalStateMatrix fixture `shouldBe` canonicalExternalStateMatrix
        length canonicalInterruptionMatrix `shouldBe` 100
        length canonicalExternalStateMatrix `shouldBe` 13

      it "holds the topology-normalized budget constant in both profiles" $ do
        -- The constant is what stops a counterexample being closed by spending
        -- more. It is enforced at load, so this asserts the committed numbers
        -- rather than the rule.
        fixture <- loadCanonicalFixture
        let causal = frozenCreateCausalProfile fixture
            production = frozenCreateProductionProfile fixture
        profileTotals (superseded_envelopes causal)
          `shouldBe` profileTotals (replacement_envelopes causal)
        profileTotals (superseded_envelopes causal)
          `shouldBe` ResourceTotals 900 1024 768 768
        profileTotals (superseded_envelopes production)
          `shouldBe` profileTotals (replacement_envelopes production)
        profileTotals (superseded_envelopes production)
          `shouldBe` ResourceTotals 1500 2048 1536 1536
        independently_justified causal `shouldBe` False
        independently_justified production `shouldBe` True
        fault_schedule production `shouldBe` fault_schedule causal

    describe "the two lanes the counterexample is about" $ do
      it "gives the superseded lane no step between the generation and the effect" $
        -- The whole finding, stated as a list. A generation names a cycle; the
        -- next thing that happened was five resources.
        implementationTransitions SupersededCreate
          `shouldBe` [AdmitCreate, CommitGeneration, ExecuteAdmittedCreate]

      it "runs the effect in both lanes" $ do
        -- An implementation that never mutates never orphans either, and is not
        -- a fix. Both lanes must reach the effect for the comparison to mean
        -- anything.
        implementationTransitions SupersededCreate
          `shouldSatisfy` elem ExecuteAdmittedCreate
        implementationTransitions ReplacementCreate
          `shouldSatisfy` elem ExecuteAdmittedCreate

      it "orphans on the superseded lane exactly at and after the effect" $ do
        successorDispositionFor SupersededCreate ExecuteAdmittedCreate BeforeTransition
          `shouldBe` CycleAddressableOnly
        successorDispositionFor SupersededCreate ExecuteAdmittedCreate AfterTransition
          `shouldBe` OrphanUnnameable

      it "names the coordinates on the replacement lane from the commit onward" $ do
        successorDispositionFor
          ReplacementCreate
          CommitWriteAheadManifest
          BeforeTransition
          `shouldBe` CycleAddressableOnly
        successorDispositionFor ReplacementCreate CommitWriteAheadManifest AfterTransition
          `shouldBe` CoordinatesNamed
        successorDispositionFor ReplacementCreate ExecuteAdmittedCreate AfterTransition
          `shouldBe` CoordinatesNamed

      it "answers cycle-addressable-only when the read-back finds nothing" $
        -- This is why the read-back is a second, independent call: a commit that
        -- says it wrote and a read that finds one are different observations,
        -- and only the second may be believed.
        externalStateDispositionFor ReplacementCreate ManifestReadBackAbsent
          `shouldBe` CycleAddressableOnly

      it "has no manifest external case on a lane with no manifest step" $ do
        reachableExternalStateCases SupersededCreate
          `shouldBe` [ AuthorityUnreachable
                     , AdmissionReplyLost
                     , GenerationCommitReplyLost
                     , ProviderDispatchReplyLost
                     , ProviderAnsweredFailure
                     ]
        reachableExternalStateCases ReplacementCreate
          `shouldBe` [minBound .. maxBound]

    describe "the oracle" $ do
      it "closes the counterexample on the committed family" $ do
        fixture <- loadCanonicalFixture
        let result = runCreateInterruptedOracle fixture
        oracleOrphanPoints (oracleSupersededOutcome result) `shouldSatisfy` (not . null)
        oracleOrphanPoints (oracleReplacementOutcome result) `shouldBe` []
        oracleNamedPoints (oracleSupersededOutcome result) `shouldBe` []
        oracleCounterexampleClosed result `shouldBe` True

      it "names every point at which the superseded lane orphans" $ do
        fixture <- loadCanonicalFixture
        let result = runCreateInterruptedOracle fixture
        map interruptionRowKind (oracleOrphanPoints (oracleSupersededOutcome result))
          `shouldBe` [minBound .. maxBound]
        map interruptionRowTransition (oracleOrphanPoints (oracleSupersededOutcome result))
          `shouldSatisfy` all (== ExecuteAdmittedCreate)

    describe "the committed mutation" $ do
      it "refuses the mutated matrix, naming the row and both dispositions" $ do
        repoRoot <- getCurrentDirectory
        mutated <- loadCreateCounterexampleFixture repoRoot MutatedCreateTrace
        mutated
          `shouldBe` Left
            ( CreateInterruptionDispositionMismatch
                ReplacementCreate
                ExecuteAdmittedCreate
                AfterTransition
                CoordinatesNamed
                OrphanUnnameable
            )

      it "differs from the canonical matrix in exactly one disposition" $ do
        -- A mutation fixture that changed two things would not show which one
        -- the oracle caught.
        (canonical, mutated) <- readBothDispositionFiles
        let differing =
              [ (canonicalLine, mutatedLine)
              | (canonicalLine, mutatedLine) <- zip (matrixRows canonical) (matrixRows mutated)
              , canonicalLine /= mutatedLine
              ]
        length differing `shouldBe` 1

    describe "the artifacts refuse what would make them meaningless" $ do
      it "refuses a trace that renames the counterexample or moves its scope" $ do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        mapM_
          ( \(before, after) -> do
              result <-
                parseCreateCounterexampleArtifacts
                  (Text.replace before after trace)
                  dispositions
                  causal
                  production
              result `shouldSatisfy` isLeftResult
          )
          [ ("fixture-id CREATE-INTERRUPTED-2026-09-08", "fixture-id CREATE-INTERRUPTED-mutated")
          , ("format-version 1", "format-version 2")
          , ("run-scope stack-create/1757318400000000", "run-scope stack-create/1")
          , ("submission-key operator-reconcile-aws-eks-0001", "submission-key other-key")
          , ("registry-revision lifecycle-registry/v1", "registry-revision lifecycle-registry/v2")
          , ("surface registered-stack-create", "surface cascade")
          , ("operation reconcile-desired-present", "operation reconcile-desired-absent")
          , ("foundation linux-rke2/home", "foundation linux-rke2/other")
          , ("aws-account 111122223333", "aws-account 000000000000")
          ,
            ( "aws-region " <> fixtureAwsRegion FixtureCaCentral1
            , "aws-region " <> fixtureAwsRegion FixtureUsEast1
            )
          , ("stack aws-eks\n", "stack aws-test\n")
          , ("declared aws-eks-vpc aws:ec2:Vpc", "declared aws-eks-vpc aws:ec2:Subnet")
          , ("observed aws-eks-vpc provider-operation/vpc-0001", "observed aws-eks-vpc x")
          , ("provider-tag prodbox.io/run-scope", "provider-tag prodbox.io/other")
          ]

      it "refuses a trace that gives the superseded lane the step it lacked" $ do
        -- The counterexample is the missing step. A trace that adds it to the
        -- superseded lane is describing a different 2026-09-08.
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        result <-
          parseCreateCounterexampleArtifacts
            ( Text.replace
                "lane superseded commit-generation"
                "lane superseded commit-generation\nlane superseded commit-write-ahead-manifest"
                trace
            )
            dispositions
            causal
            production
        result `shouldSatisfy` isLeftResult

      it "refuses a disposition file that drops a row" $ do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        result <-
          parseCreateCounterexampleArtifacts
            trace
            (dropArtifactLine "interrupt superseded restart after execute-admitted-create" dispositions)
            causal
            production
        result `shouldBe` Left (CreateInterruptionInventoryIncomplete 100 99)

      it "refuses a disposition file that claims an unreachable external case" $ do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        result <-
          parseCreateCounterexampleArtifacts
            trace
            ( dispositions
                <> "\nexternal superseded manifest-commit-reply-lost coordinates-named\n"
            )
            causal
            production
        result
          `shouldBe` Left
            (CreateExternalStateUnreachable SupersededCreate ManifestCommitReplyLost)

      it "refuses a disposition file whose header swaps the two sides" $ do
        -- Standard P wants the expected failure and the expected pass stated in
        -- the artifact. A header nothing reads would be a claim nothing tests.
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        result <-
          parseCreateCounterexampleArtifacts
            trace
            ( Text.replace
                "result superseded unnameable-create-orphan expected-failure"
                "result superseded unnameable-create-orphan expected-pass"
                dispositions
            )
            causal
            production
        result
          `shouldBe` Left
            (CreateArtifactSemanticMismatch CreateDispositionsArtifact "superseded result")

      it "refuses a profile that breaks the budget constant" $ do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        result <-
          parseCreateCounterexampleArtifacts
            trace
            dispositions
            (Text.replace "cpu_millis = 900" "cpu_millis = 901" causal)
            production
        result `shouldBe` Left (CreateProfileMismatch CreateCausalProfileArtifact)

      it "refuses every other profile field class" $ do
        (trace, dispositions, causal, production) <- readCanonicalArtifacts
        mapM_
          ( \(before, after) -> do
              result <-
                parseCreateCounterexampleArtifacts
                  trace
                  dispositions
                  (Text.replace before after causal)
                  production
              result `shouldBe` Left (CreateProfileMismatch CreateCausalProfileArtifact)
          )
          [ ("format_version = 1", "format_version = 2")
          , ("fixture_id = \"CREATE-INTERRUPTED-2026-09-08\"", "fixture_id = \"wrong\"")
          , ("profile_id = \"create-interrupted-causal-v1\"", "profile_id = \"wrong\"")
          , ("profile_kind = \"causal\"", "profile_kind = \"wrong\"")
          , ("request_rate_per_second = 4", "request_rate_per_second = 5")
          , ("concurrent_clients = 2", "concurrent_clients = 3")
          , ("payload_bytes = 1024", "payload_bytes = 1025")
          , ("\"commit-write-ahead-manifest\"", "\"wrong-step\"")
          , ("fault_schedule_digest = \"d7e5", "fault_schedule_digest = \"e7e5")
          , ("independently_justified = False", "independently_justified = True")
          , ("superseded_component = \"legacy-create-submitter\"", "superseded_component = \"wrong\"")
          , ("\"ownership-manifest-store\"", "\"wrong-store\"")
          ]
        productionResult <-
          parseCreateCounterexampleArtifacts
            trace
            dispositions
            causal
            (Text.replace "independently_justified = True" "independently_justified = False" production)
        productionResult
          `shouldBe` Left (CreateProfileMismatch CreateProductionProfileArtifact)

      it "bounds each artifact before decoding" $
        withSystemTempDirectory "prodbox-create-bounds" $ \temporaryRoot -> do
          (trace, dispositions, causal, production) <- readCanonicalArtifacts
          let qualification = temporaryRoot </> "test" </> "qualification"
              write name = TextIO.writeFile (qualification </> name)
          createDirectoryIfMissing True qualification
          write "CREATE-INTERRUPTED-2026-09-08.trace" (Text.replicate 65537 "x")
          write "CREATE-INTERRUPTED-2026-09-08.dispositions" dispositions
          write "CREATE-INTERRUPTED-2026-09-08.causal-profile.dhall" causal
          write "CREATE-INTERRUPTED-2026-09-08.production-profile.dhall" production
          traceResult <- loadCreateCounterexample temporaryRoot
          traceResult
            `shouldBe` Left (CreateArtifactUnbounded CreateTraceArtifact 65536 65537)
          write "CREATE-INTERRUPTED-2026-09-08.trace" trace
          write "CREATE-INTERRUPTED-2026-09-08.dispositions" (Text.replicate 131073 "x")
          dispositionsResult <- loadCreateCounterexample temporaryRoot
          dispositionsResult
            `shouldBe` Left (CreateArtifactUnbounded CreateDispositionsArtifact 131072 131073)
          write "CREATE-INTERRUPTED-2026-09-08.dispositions" dispositions
          write "CREATE-INTERRUPTED-2026-09-08.causal-profile.dhall" (Text.replicate 32769 "x")
          causalResult <- loadCreateCounterexample temporaryRoot
          causalResult
            `shouldBe` Left (CreateArtifactUnbounded CreateCausalProfileArtifact 32768 32769)
          write "CREATE-INTERRUPTED-2026-09-08.causal-profile.dhall" causal
          write "CREATE-INTERRUPTED-2026-09-08.production-profile.dhall" (Text.replicate 32769 "x")
          productionResult <- loadCreateCounterexample temporaryRoot
          productionResult
            `shouldBe` Left
              (CreateArtifactUnbounded CreateProductionProfileArtifact 32768 32769)

    describe "the oracle stays a reference, not a copy of production" $ do
      it "imports no lifecycle runtime and carries no credential" $ do
        source <-
          TextIO.readFile
            "src/Prodbox/Test/Qualification/CreateInterruptedCounterexample.hs"
        source `shouldSatisfy` (not . Text.isInfixOf "import Prodbox.Lifecycle")
        source `shouldSatisfy` (not . Text.isInfixOf "import Prodbox.ControlPlane")
        source `shouldSatisfy` (not . Text.isInfixOf "import Prodbox.CLI")
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
                (TestIntegration IntegrationCreateInterrupted)
        testPlanLabel plan `shouldBe` "integration create-interrupted"
        testPlanHaskellSuites plan `shouldBe` []
        case testPlanExecutionMode plan of
          DelegatedSuite _ -> expectationFailure "expected a native create-interrupted plan"
          NativeSuite suitePlan -> do
            nativeSuiteId suitePlan `shouldBe` "integration-create-interrupted"
            nativeValidations suitePlan `shouldBe` [ValidationCreateInterrupted]
            nativeInitialIntegrationGatePrerequisites suitePlan `shouldBe` []
            nativeDeferredIntegrationGatePrerequisites suitePlan `shouldBe` []

loadCanonicalFixture :: IO FrozenCreateCounterexample
loadCanonicalFixture = do
  repoRoot <- getCurrentDirectory
  loaded <- loadCreateCounterexample repoRoot
  case loaded of
    Right fixture -> pure fixture
    Left err -> error ("canonical create counterexample refused: " ++ show err)

readCanonicalArtifacts :: IO (Text, Text, Text, Text)
readCanonicalArtifacts = do
  repoRoot <- getCurrentDirectory
  trace <- TextIO.readFile (createTraceFixturePath repoRoot)
  dispositions <-
    TextIO.readFile (createDispositionsFixturePath repoRoot CanonicalCreateTrace)
  causal <- TextIO.readFile (createCausalProfileFixturePath repoRoot)
  production <- TextIO.readFile (createProductionProfileFixturePath repoRoot)
  pure (trace, dispositions, causal, production)

readBothDispositionFiles :: IO (Text, Text)
readBothDispositionFiles = do
  repoRoot <- getCurrentDirectory
  canonical <-
    TextIO.readFile (createDispositionsFixturePath repoRoot CanonicalCreateTrace)
  mutated <- TextIO.readFile (createDispositionsFixturePath repoRoot MutatedCreateTrace)
  pure (canonical, mutated)

matrixRows :: Text -> [Text]
matrixRows contents =
  [ line
  | line <- Text.lines contents
  , "interrupt " `Text.isPrefixOf` line || "external " `Text.isPrefixOf` line
  ]

dropArtifactLine :: Text -> Text -> Text
dropArtifactLine prefix contents =
  Text.unlines [line | line <- Text.lines contents, not (prefix `Text.isPrefixOf` line)]

foldArtifacts :: (Text, Text, Text, Text) -> Text
foldArtifacts (trace, dispositions, causal, production) =
  Text.concat [trace, dispositions, causal, production]

isLeftResult :: Either err value -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False
