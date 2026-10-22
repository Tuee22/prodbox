{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsLifecycleScope (awsLifecycleScopeSuite) where

import Control.Monad (forM_)
import Data.IORef
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Command (IntegrationSuite (..), PolicyTier (..), TestScope (..))
import Prodbox.CLI.Rke2
  ( ReconcileStepId (..)
  , nativeHarnessBootstrapFloorStepOrder
  , nativeHarnessProviderReadinessStepOrder
  , nativeInstallStepOrder
  )
import Prodbox.Config.ComponentGraph (defaultComponentGraph, validateComponentGraph)
import Prodbox.Infra.AwsFieldAudit (FieldAudit (..))
import Prodbox.Lifecycle.AwsAudit
import Prodbox.Lifecycle.AwsAuditEvidence (AuditBinding (..))
import Prodbox.Lifecycle.RuntimeProfile (NativeRuntimeProfile (..))
import Prodbox.Lifecycle.Teardown.Model (RegisteredResourceKey (..))
import Prodbox.PrerequisiteId (PrerequisiteId (..))
import Prodbox.Substrate (Substrate (..))
import Prodbox.Test.AwsLifecycle
import Prodbox.TestPlan
import Prodbox.TestRunner
  ( GatewayRuntimeValidationBoundary (..)
  , gatewayRuntimeValidationBoundary
  , lifecycleCleanupTargetsForSuite
  )
import Prodbox.TestValidation (NativeValidationKubeconfigMode (..), nativeValidationKubeconfigMode)
import System.Exit (ExitCode (..))
import TestSupport

awsLifecycleScopeSuite :: SuiteBuilder ()
awsLifecycleScopeSuite = describe "Sprint 5.59 AWS lifecycle harness scope" $ do
  forM_ [SubstrateHomeLocal, SubstrateAws] $ \substrate ->
    forM_
      [ (IntegrationAwsLifecycle, ValidationAwsLifecycle)
      , (IntegrationAwsLifecycleCanary, ValidationAwsLifecycleCanary)
      ]
      $ \(suite, validation) ->
        it ("selects the actual minimal " ++ show suite ++ " plan on " ++ show substrate) $ do
          let plan = testExecutionPlan substrate (TestIntegration suite)
          testPlanHaskellSuites plan `shouldBe` []
          case testPlanExecutionMode plan of
            DelegatedSuite _ -> expectationFailure "lifecycle drills require the native harness"
            NativeSuite native -> do
              nativeValidations native `shouldBe` [validation]
              nativeManagedAwsHarnessPolicyTier native `shouldBe` Just PolicyFull
              nativeInitialIntegrationGatePrerequisites native
                `shouldBe` [ HostSubstrateSupported
                           , ToolDocker
                           , ToolCtr
                           , ToolHelm
                           , ToolKubectl
                           , ToolSudo
                           , ToolSystemctl
                           , SettingsObject
                           , ToolPulumi
                           ]
              nativeDeferredIntegrationGatePrerequisites native `shouldBe` []
              nativeRequiresSupportedRuntimeBootstrap native `shouldBe` False
              nativeRequiresSupportedRuntimePostflight native `shouldBe` False
              nativeRequiresIntegrationRunbook native `shouldBe` False
              harnessPreparationSteps (nativeValidations native) `shouldBe` []
              harnessRuntimeProfileForValidations (nativeValidations native) `shouldBe` LifecycleWorkersRuntime
              nativeValidationKubeconfigMode validation `shouldBe` ValidationOwnsKubeconfigScopes
              gatewayRuntimeValidationBoundary substrate validation `shouldBe` GatewayRuntimeNoBoundary
              let expectedTargets = case suite of
                    IntegrationAwsLifecycleCanary -> [AwsTestKey, AwsTestVpcCniInterfacesKey, AwsTestCanarySecurityGroupsKey]
                    _ ->
                      [ AwsEksKey
                      , AwsTestKey
                      , AwsEbsPerRunTestKey
                      , AwsEksIamRoleFamilyKey
                      , AwsEksLoadBalancerControllerFamilyKey
                      , AwsEksVpcCniInterfacesKey
                      , AwsTestVpcCniInterfacesKey
                      , AwsEksClusterSecurityGroupsKey
                      , AwsTestCanarySecurityGroupsKey
                      ]
              sort (lifecycleCleanupTargetsForSuite native) `shouldBe` sort expectedTargets
  it "reserves both complete client bodies, including public-verb field brackets" $ do
    lifecycleExerciseProviderBodyRequestMaximum AwsStackCycles `shouldBe` 18
    lifecycleExerciseProviderBodyRequestMaximum AwsTestVpcCanary `shouldBe` 10
    lifecycleExerciseRecordedOutputReadMaximum AwsStackCycles `shouldBe` 2
    lifecycleExerciseRecordedOutputReadMaximum AwsTestVpcCanary `shouldBe` 2
  it "keeps ordinary preparation and prevents a mixed suite selecting the lifecycle-only profile" $ do
    harnessPreparationSteps [ValidationAwsEks] `shouldBe` [HarnessAcmeEabIngress]
    harnessPreparationSteps [ValidationKeycloakInvite]
      `shouldBe` [HarnessAcmeEabIngress, HarnessSesSmtpIngress]
    harnessRuntimeProfileForValidations [ValidationAwsLifecycle, ValidationKeycloakInvite]
      `shouldBe` FullRuntime
    harnessRuntimeProfileForValidations [] `shouldBe` FullRuntime
  it "keeps the exact retained bootstrap/config floor before its two worker roles" $
    withOrder $ \order -> do
      let floorSteps = nativeHarnessBootstrapFloorStepOrder order
          selected = nativeHarnessProviderReadinessStepOrder order
          workerRoles = [StepProviderWorkerChartReady, StepTlsRetentionChartReady]
      filter (`notElem` workerRoles) selected `shouldBe` floorSteps
      forM_ workerRoles (\role -> selected `shouldContain` [role])
      length selected `shouldBe` (length floorSteps + length workerRoles)
      take (length floorSteps) selected `shouldBe` floorSteps
  it "enters no application, edge, or certificate-controller step" $
    withOrder $ \order -> do
      let selected = nativeHarnessProviderReadinessStepOrder order
      forM_
        [ StepGatewayChartReady
        , StepCertManagerRuntime
        , StepMetalLbRuntime
        , StepEnvoyGatewayRuntime
        , StepPostgresOperatorRuntime
        , StepAdminPublicEdgeRoutes
        , StepRootChartNamespaceGuardrails
        , StepReconcileManagedAnnotations
        , StepRequireOperationalAwsCredentials
        , StepPublicEdgeAcmeRuntime
        , StepReconcileDnsBootstrapRecord
        ]
        (\step -> selected `shouldNotContain` [step])
  it "preserves the authored order and never invents a role absent from it" $
    withOrder $ \order -> do
      let reversed = reverse order
      nativeHarnessProviderReadinessStepOrder reversed
        `shouldBe` reverse (nativeHarnessProviderReadinessStepOrder order)
      nativeHarnessProviderReadinessStepOrder [] `shouldBe` []
      nativeHarnessProviderReadinessStepOrder [StepGatewayChartReady] `shouldBe` []
  forM_ [minBound .. maxBound] $ \exercise -> do
    it ("declares exactly the enumerated classes of " ++ show exercise) $ do
      let covered =
            [ class'
            | member <- [minBound .. maxBound]
            , EnumeratedField class' <- [lifecycleFieldCoverage exercise member]
            ]
      sort covered `shouldBe` sort (nub (concatMap auditStackClasses (lifecycleExerciseStacks exercise)))
      length covered `shouldBe` length (nub covered)
      length (renderLifecycleCoverage exercise)
        `shouldBe` length ([minBound .. maxBound] :: [LifecycleFieldMember])
    it
      ( "emits field coverage before every effect and closes "
          ++ show exercise
          ++ " through fresh inventories"
      )
      $ do
        let stacks = lifecycleExerciseStacks exercise
        ((boundary, plant), events) <- scriptedBoundary (concatMap cycleFields stacks)
        requests <- newIORef 0
        let charge count action = modifyIORef' requests (+ count) >> action
            counted =
              boundary
                { observeLifecycleField = \stack -> charge 1 (observeLifecycleField boundary stack)
                , reconcileLifecycleStack = \stack -> charge 3 (reconcileLifecycleStack boundary stack)
                , destroyLifecycleStack = \stack -> charge 3 (destroyLifecycleStack boundary stack)
                }
        runExercise (counted, charge 1 plant) exercise >>= (`shouldBe` Right ())
        events >>= (`shouldBe` ("coverage" : concatMap (cycleEvents exercise) stacks))
        readIORef requests `shouldReturn` lifecycleExerciseProviderBodyRequestMaximum exercise
  it "names every omitted target binding, retained family and unbracketed destroy" $ do
    forM_
      [ VpcByRecordedIdentifier
      , RetainedEbsFamily
      , ValidationHostedZoneFamily
      , PerRunSubzone
      , RunScopeTagJoin
      , SubzoneDestroyBracket
      , SesDestroyBracket
      , CascadeDestroyBracket
      , PersistentIdentifierConfidentiality
      ]
      (\member -> lifecycleFieldCoverage AwsStackCycles member `shouldSatisfy` isNotCovered)
    length (lifecycleNotCovered AwsStackCycles) `shouldBe` 9
    lifecycleFieldCoverage AwsTestVpcCanary EksCluster `shouldSatisfy` isNotCovered
    lifecycleFieldCoverage AwsTestVpcCanary PerRunEbsVolumes `shouldSatisfy` isNotCovered
  it "refuses a dirty initial field before create or plant" $ do
    (boundary, events) <- scriptedBoundary [presentField AuditAwsTest]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldWrongVerdict LifecycleBeforeCreate AuditAwsTest "Residue"))
    events >>= (`shouldBe` ["coverage", "observe:aws-test"])
  it "refuses an unseen positive control before create" $ do
    let initial = field AuditAwsTest [] AuditControlMissing Nothing
    (boundary, events) <- scriptedBoundary [initial]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldIncomplete LifecycleBeforeCreate AuditAwsTest))
    events >>= (`shouldBe` ["coverage", "observe:aws-test"])
  it "requires presence after create rather than accepting a no-op cycle" $ do
    (boundary, events) <- scriptedBoundary [cleanField AuditAwsTest, cleanField AuditAwsTest]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldWrongVerdict LifecycleAfterCreate AuditAwsTest "Clean"))
    events >>= (`shouldBe` ["coverage", "observe:aws-test", "create:aws-test", "observe:aws-test"])
  it "refuses an unanswered class even when a found row gives the verdict Residue" $ do
    let partial = field AuditAwsTest [mkAuditRow AuditVpc "vpc-fixture" ""] AuditControlSeen (Just AuditSubnet)
    auditVerdict (fieldAuditObservation partial) `shouldSatisfy` isResidue
    (boundary, _) <- scriptedBoundary [cleanField AuditAwsTest, partial]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldIncomplete LifecycleAfterCreate AuditAwsTest))
  it "requires the final independent inventory to be Clean" $ do
    (boundary, _) <-
      scriptedBoundary [cleanField AuditAwsTest, presentField AuditAwsTest, presentField AuditAwsTest]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldWrongVerdict LifecycleAfterDestroy AuditAwsTest "Residue"))
  it "refuses a clean first inventory from an account outside the registered run before create" $ do
    let changed =
          (cleanField AuditAwsTest)
            { fieldAuditBinding = AuditBinding "111122223333" (fixtureAwsRegion FixtureCaCentral1)
            }
    (boundary, events) <- scriptedBoundary [changed]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldScopeChanged LifecycleBeforeCreate AuditAwsTest))
    events >>= (`shouldBe` ["coverage", "observe:aws-test"])
  it "refuses a changed provider account instead of accepting its empty field" $ do
    let changed =
          (cleanField AuditAwsTest)
            { fieldAuditBinding = AuditBinding "111122223333" (fixtureAwsRegion FixtureCaCentral1)
            }
    (boundary, _) <- scriptedBoundary [cleanField AuditAwsTest, presentField AuditAwsTest, changed]
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleFieldScopeChanged LifecycleAfterDestroy AuditAwsTest))
  it "binds the second stack to the first stack's account and region" $ do
    let changed =
          (cleanField AuditAwsEks)
            { fieldAuditBinding = AuditBinding "123456789012" (fixtureAwsRegion FixtureUsEast1)
            }
    (boundary, _) <- scriptedBoundary (cycleFields AuditAwsTest ++ [changed])
    runExercise boundary AwsStackCycles
      >>= (`shouldBe` Left (LifecycleFieldScopeChanged LifecycleBeforeCreate AuditAwsEks))
  it "refuses a wrong outer or inner stack binding" $ do
    let outer = cleanField AuditAwsEks
        inner = outer {fieldAuditStack = AuditAwsTest}
    forM_ [outer, inner] $ \mismatched -> do
      (boundary, _) <- scriptedBoundary [mismatched]
      runExercise boundary AwsTestVpcCanary
        >>= (`shouldBe` Left (LifecycleFieldWrongStack LifecycleBeforeCreate AuditAwsTest))
  it "does not promote an unsuccessful destroy through a later empty inventory" $ do
    (boundary, events) <- scriptedBoundary (cycleFields AuditAwsTest)
    let (core, plant) = boundary
        failed = (core {destroyLifecycleStack = const (pure (Right (ExitFailure 4)))}, plant)
    runExercise failed AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleCommandFailed LifecycleDestroy AuditAwsTest (ExitFailure 4)))
    events
      >>= (`shouldBe` ["coverage", "observe:aws-test", "create:aws-test", "observe:aws-test", "plant"])
  it "preserves an unobservable boundary as a failure" $ do
    (boundary, events) <- scriptedBoundary []
    runExercise boundary AwsTestVpcCanary
      >>= (`shouldBe` Left (LifecycleBoundaryFailed LifecycleBeforeCreate AuditAwsTest "no scripted field"))
    events >>= (`shouldBe` ["coverage", "observe:aws-test"])

withOrder :: ([ReconcileStepId] -> IO ()) -> IO ()
withOrder test = case validateComponentGraph defaultComponentGraph of
  Left err -> expectationFailure (show err)
  Right dag -> test (nativeInstallStepOrder dag)

isNotCovered :: LifecycleFieldCoverage -> Bool
isNotCovered coverage = case coverage of
  FieldNotCovered reason -> not (Text.null reason)
  EnumeratedField _ -> False

isResidue :: AuditVerdict -> Bool
isResidue verdict = case verdict of
  AuditResidue _ -> True
  AuditClean -> False
  AuditUnobservable _ _ -> False

field :: AuditStack -> [AuditRow] -> AuditControl -> Maybe AuditClass -> FieldAudit
field stack rows control gap =
  FieldAudit stack (AuditBinding "123456789012" (fixtureAwsRegion FixtureCaCentral1)) observation
 where
  observation = case mkAuditObservation stack answers control of
    Right value -> value
    Left err -> error (show err)
  answers =
    [ ( class'
      , if Just class' == gap
          then auditUnanswered "denied"
          else auditAnswered (filter ((== class') . auditRowClass) rows)
      )
    | class' <- auditStackClasses stack
    ]

cleanField :: AuditStack -> FieldAudit
cleanField stack = field stack [] AuditControlSeen Nothing

presentField :: AuditStack -> FieldAudit
presentField stack = field stack [mkAuditRow AuditVpc "vpc-fixture" ""] AuditControlSeen Nothing

cycleFields :: AuditStack -> [FieldAudit]
cycleFields stack = [cleanField stack, presentField stack, cleanField stack]

cycleEvents :: AwsLifecycleExercise -> AuditStack -> [Text]
cycleEvents exercise stack =
  [event "observe", event "create", event "observe"]
    ++ ["plant" | exercise == AwsTestVpcCanary]
    ++ [event "destroy", event "observe"]
 where
  event label = label <> ":" <> auditStackLabel stack

type ScriptedBoundary = (AwsLifecycleBoundary IO, IO (Either Text ExitCode))

runExercise :: ScriptedBoundary -> AwsLifecycleExercise -> IO (Either AwsLifecycleError ())
runExercise (boundary, plant) exercise = runAwsLifecycleExercise (AuditBinding "123456789012" (fixtureAwsRegion FixtureCaCentral1)) $ case exercise of
  AwsStackCycles -> AwsStackCycleProgram boundary
  AwsTestVpcCanary -> AwsTestVpcCanaryProgram boundary plant

scriptedBoundary :: [FieldAudit] -> IO (ScriptedBoundary, IO [Text])
scriptedBoundary fields = do
  pending <- newIORef fields
  calls <- newIORef []
  let record event = modifyIORef' calls (<> [event])
      command label stack = record (label <> ":" <> auditStackLabel stack) >> pure (Right ExitSuccess)
      boundary =
        AwsLifecycleBoundary
          { emitLifecycleFieldCoverage = \lines' -> do
              length lines' `shouldBe` length ([minBound .. maxBound] :: [LifecycleFieldMember])
              record "coverage"
          , observeLifecycleField = \stack -> do
              record ("observe:" <> auditStackLabel stack)
              remaining <- readIORef pending
              case remaining of
                [] -> pure (Left "no scripted field")
                next : rest -> writeIORef pending rest >> pure (Right next)
          , reconcileLifecycleStack = command "create"
          , destroyLifecycleStack = command "destroy"
          }
  pure ((boundary, record "plant" >> pure (Right ExitSuccess)), readIORef calls)
