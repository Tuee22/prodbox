{-# LANGUAGE OverloadedStrings #-}

module GatewayRuntimeStability
  ( gatewayRuntimeStabilitySuite
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.CLI.Command (TestScope (..))
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Substrate (Substrate (..))
import Prodbox.Test.GatewayRuntimeStability
import Prodbox.TestPlan
  ( NativeValidation (..)
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import Prodbox.TestRestore (RestoreChart (..), RestoreCycleStep (..))
import Prodbox.TestRunner
  ( GatewayRuntimeValidationBoundary (..)
  , awsSubstrateBootstrapPostMonitorSteps
  , awsSubstrateBootstrapPreMonitorSteps
  , gatewayRuntimeValidationBoundary
  )
import TestSupport

gatewayRuntimeStabilitySuite :: SuiteBuilder ()
gatewayRuntimeStabilitySuite =
  describe "Sprint 5.16 gateway runtime-stability oracle" $ do
    it "derives warning, failure, and limit bytes from the validated runtime plan" $
      gatewayPolicyMemoryThresholds policyTwoSamples
        `shouldBe` GatewayMemoryThresholds 80 100 120

    it "classifies the flat Pod-health outcomes with explicit precedence" $
      mapM_
        ( \(label, previousRestart, highWater, sample, expectedTag) ->
            observationTag
              ( classifyGatewayPodHealth
                  thresholds
                  previousRestart
                  highWater
                  sample
              )
              `shouldBe` (label, expectedTag)
        )
        [ ("ready", Just 0, Just 79, readySample, RestartFreeReadyTag)
        , ("restart", Just 0, Just 79, readySample {gatewaySampleRestartCount = Just 1}, RestartDeltaTag)
        , ("oom", Just 0, Just 79, sampleWithOom readySample, OomKilledTag)
        , ("warning", Just 0, Just 80, readySample, MemoryWarningTag)
        , ("failure", Just 0, Just 100, readySample, MemoryFailureTag)
        ,
          ( "pending"
          , Nothing
          , Nothing
          , readySample
              { gatewaySamplePhase = Just GatewayPodPendingPhase
              , gatewaySampleReady = Nothing
              , gatewaySampleRestartCount = Nothing
              }
          , PendingTag
          )
        , ("unobservable", Just 0, Nothing, readySample, UnobservableTag)
        ]

    it "fails a currently Ready Pod when lastState retains OOMKilled" $ do
      let state =
            observeGatewayRuntimePayloads
              sampleTime
              (podsPayload [podValue "gateway-a" "uid-a" 0 (Just "OOMKilled")])
              emptyListPayload
              (metricsPayload [("gateway-a", 70)])
              (initialGatewayStabilityState policyTwoSamples)
      gatewayRuntimeStabilityReport state `shouldSatisfy` isOomReport

    it "keeps each OOM source absorbing across green samples, UID churn, and planned resets" $ do
      let transitions :: [(String, GatewayStabilityState -> GatewayStabilityState)]
          transitions =
            [ ("later green sample", observeGreen "uid-current")
            ,
              ( "deleted UID and green replacement"
              , observeGreen "uid-replacement"
                  . noteGatewayPodDeleted "uid-current"
              )
            ,
              ( "planned reset and green replacement"
              , observeGreen "uid-planned"
                  . beginPlannedGatewayRollout
              )
            ]
          oomSources :: [(String, GatewayStabilityState)]
          oomSources =
            [
              ( "last container status"
              , observeGatewayRuntimePayloads
                  sampleTime
                  (podsPayload [podValue "gateway-a" "uid-current" 0 (Just "OOMKilled")])
                  emptyListPayload
                  (metricsPayload [("gateway-a", 70)])
                  (initialGatewayStabilityState policyTwoSamples)
              )
            ,
              ( "attached Kubernetes Event"
              , observeGatewayRuntimePayloads
                  sampleTime
                  (podsPayload [podValue "gateway-a" "uid-current" 0 Nothing])
                  (oomEventPayload "gateway-a" "uid-current")
                  (metricsPayload [("gateway-a", 70)])
                  (initialGatewayStabilityState policyTwoSamples)
              )
            ,
              ( "deleted-UID Kubernetes Event residue"
              , observeGatewayRuntimePayloads
                  sampleTime
                  (podsPayload [podValue "gateway-a" "uid-current" 0 Nothing])
                  (oomEventPayload "gateway-a-old" "uid-deleted")
                  (metricsPayload [("gateway-a", 70)])
                  (initialGatewayStabilityState policyTwoSamples)
              )
            ]
      mapM_
        ( \(sourceLabel, oomState) ->
            mapM_
              ( \(transitionLabel, transition) ->
                  ( sourceLabel
                  , transitionLabel
                  , isOomReport
                      (gatewayRuntimeStabilityReport (transition oomState))
                  )
                    `shouldBe` (sourceLabel, transitionLabel, True)
              )
              transitions
        )
        oomSources

    it "opens only after the configured sequence of complete stable snapshots" $ do
      let firstState = observeGreen "uid-a" (initialGatewayStabilityState policyTwoSamples)
          secondState = observeGreen "uid-a" firstState
      gatewayRuntimeStabilityReport firstState `shouldBe` NotStableYet 1 2
      gatewayRuntimeStabilityReport secondState `shouldBe` StableObserved 2

    it "keeps restart evidence across deletion, UID replacement, and planned rollout" $ do
      let restarted =
            observeGatewayRuntimePayloads
              sampleTime
              (podsPayload [podValue "gateway-a" "uid-old" 1 Nothing])
              emptyListPayload
              (metricsPayload [("gateway-a", 70)])
              (initialGatewayStabilityState policyTwoSamples)
          afterDeletion = noteGatewayPodDeleted "uid-old" restarted
          afterReplacement = observeGreen "uid-new" afterDeletion
          afterRollout = beginPlannedGatewayRollout afterReplacement
      gatewayRuntimeStabilityReport restarted `shouldSatisfy` isRestartReport
      gatewayRuntimeStabilityReport afterReplacement `shouldBe` gatewayRuntimeStabilityReport restarted
      gatewayRuntimeStabilityReport afterRollout `shouldBe` gatewayRuntimeStabilityReport restarted

    it "resets only the healthy success window for an explicit planned rollout" $ do
      let beforeRollout = observeGreen "uid-a" (initialGatewayStabilityState policyTwoSamples)
          reset = beginPlannedGatewayRollout beforeRollout
          replacement = observeGreen "uid-b" reset
      gatewayRuntimeStabilityReport beforeRollout `shouldBe` NotStableYet 1 2
      gatewayRuntimeStabilityReport reset `shouldBe` NotStableYet 0 2
      gatewayRuntimeStabilityReport replacement `shouldBe` NotStableYet 1 2

    it "interrupts the healthy window when an unplanned snapshot replaces a Pod UID" $ do
      let firstState = observeGreen "uid-a" (initialGatewayStabilityState policyTwoSamples)
          replacedState = observeGreen "uid-b" firstState
          nextState = observeGreen "uid-b" replacedState
      gatewayRuntimeStabilityReport firstState `shouldBe` NotStableYet 1 2
      gatewayRuntimeStabilityReport replacedState `shouldBe` NotStableYet 0 2
      gatewayRuntimeStabilityReport nextState `shouldBe` NotStableYet 1 2

    it "fails closed when required metrics are unobservable" $ do
      let state =
            observeGatewayRuntimePayloads
              sampleTime
              (podsPayload [podValue "gateway-a" "uid-a" 0 Nothing])
              emptyListPayload
              emptyListPayload
              (initialGatewayStabilityState policyTwoSamples)
      gatewayRuntimeStabilityReport state `shouldSatisfy` isUnreachableReport

    it "fails closed for each unobservable Pod-status field before considering metrics" $ do
      let cases :: [(String, GatewayPodSample, GatewayUnobservableReason)]
          cases =
            [
              ( "phase"
              , readySample {gatewaySamplePhase = Nothing}
              , GatewayPhaseUnobservable
              )
            ,
              ( "Ready condition"
              , readySample {gatewaySampleReady = Nothing}
              , GatewayReadinessUnobservable
              )
            ,
              ( "restart count"
              , readySample {gatewaySampleRestartCount = Nothing}
              , GatewayRestartCountUnobservable
              )
            ,
              ( "container limit"
              , readySample {gatewaySampleCurrentLimitBytes = Nothing}
              , GatewayContainerLimitUnobservable
              )
            ]
      mapM_
        ( \(label, sample, expectedReason) ->
            let state =
                  foldGatewayRuntimeSnapshot
                    GatewayRuntimeSnapshot
                      { gatewaySnapshotMemoryThresholds = thresholds
                      , gatewaySnapshotSamples = [sample]
                      }
                    (initialGatewayStabilityState policyTwoSamples)
             in (label, observationUnreachableReason (gatewayRuntimeStabilityReport state))
                  `shouldBe` (label, Just expectedReason)
        )
        cases

    it "absorbs OOM evidence from Kubernetes Events as well as container status" $ do
      let state =
            observeGatewayRuntimePayloads
              sampleTime
              (podsPayload [podValue "gateway-a" "uid-a" 0 Nothing])
              (oomEventPayload "gateway-a" "uid-a")
              (metricsPayload [("gateway-a", 70)])
              (initialGatewayStabilityState policyTwoSamples)
      gatewayRuntimeStabilityReport state `shouldSatisfy` isOomReport

    it "absorbs an OOM Event for a Pod deleted before the current Pod snapshot" $ do
      let state =
            observeGatewayRuntimePayloads
              sampleTime
              (podsPayload [podValue "gateway-a" "uid-new" 0 Nothing])
              (oomEventPayload "gateway-a-old" "uid-deleted")
              (metricsPayload [("gateway-a", 70)])
              (initialGatewayStabilityState policyTwoSamples)
      gatewayRuntimeStabilityReport state `shouldSatisfy` isOomReport

    it "absorbs effect-boundary failures without manufacturing JSON" $ do
      let state =
            observeGatewayRuntimeFailure
              GatewayPodsPayload
              "kubectl get pods timed out"
              (initialGatewayStabilityState policyTwoSamples)
      renderGatewayRuntimeStabilityReport (gatewayRuntimeStabilityReport state)
        `shouldContain` "kubectl get pods timed out"

    it "absorbs every effect-boundary payload failure across a later planned recovery" $
      mapM_
        ( \source ->
            let failed =
                  observeGatewayRuntimeFailure
                    source
                    "bounded observation failed"
                    (initialGatewayStabilityState policyTwoSamples)
                afterRecovery =
                  observeGreen
                    "uid-recovered"
                    (beginPlannedGatewayRollout failed)
                rendered =
                  renderGatewayRuntimeStabilityReport
                    (gatewayRuntimeStabilityReport afterRecovery)
             in do
                  rendered `shouldContain` show source
                  rendered `shouldContain` "bounded observation failed"
        )
        [GatewayPodsPayload, GatewayEventsPayload, GatewayMetricsPayload]

    it "renders every actionable diagnostic field without consulting logs" $ do
      let observation =
            classifyGatewayPodHealth thresholds (Just 0) (Just 79) readySample
          rendered =
            case observation of
              GatewayRestartFreeReady diagnostic -> renderGatewayPodDiagnostic diagnostic
              _ -> "unexpected observation"
      mapM_
        (rendered `shouldContain`)
        [ "pod=gateway-a"
        , "restart_delta=0"
        , "termination_reason=unobservable"
        , "termination_time=unobservable"
        , "current_limit_bytes=120"
        , "sampled_high_water_bytes=79"
        ]

    it "projects monitor pause/refresh boundaries only for observed-cluster replacement" $ do
      gatewayRuntimeValidationBoundary SubstrateHomeLocal ValidationLifecycle
        `shouldBe` GatewayRuntimePlannedRollout
      gatewayRuntimeValidationBoundary SubstrateAws ValidationLifecycle
        `shouldBe` GatewayRuntimeNoBoundary
      map
        (\substrate -> gatewayRuntimeValidationBoundary substrate ValidationEksVolumeRebind)
        [SubstrateHomeLocal, SubstrateAws]
        `shouldBe` [GatewayRuntimeRecreatedTarget, GatewayRuntimeRecreatedTarget]
      mapM_
        ( \validation ->
            map
              (\substrate -> gatewayRuntimeValidationBoundary substrate validation)
              [SubstrateHomeLocal, SubstrateAws]
              `shouldBe` [GatewayRuntimeNoBoundary, GatewayRuntimeNoBoundary]
        )
        nonDestructiveValidations

    it "starts the AWS monitor at the gateway handoff before dependent charts" $ do
      case testPlanExecutionMode (testExecutionPlan SubstrateAws TestAll) of
        NativeSuite suitePlan -> do
          awsSubstrateBootstrapPreMonitorSteps suitePlan
            `shouldBe` [RestoreReconcileChart RestoreChartGateway]
          case awsSubstrateBootstrapPostMonitorSteps suitePlan of
            RestorePrepareRetainedSes _ : dependentCharts ->
              dependentCharts
                `shouldBe` [ RestoreReconcileChart RestoreChartVscode
                           , RestoreReconcileChart RestoreChartApi
                           , RestoreReconcileChart RestoreChartWebsocket
                           ]
            observed ->
              expectationFailure
                ("expected retained SES preparation at AWS monitor handoff, observed " ++ show observed)
        DelegatedSuite _ -> expectationFailure "expected native aggregate test plan"

nonDestructiveValidations :: [NativeValidation]
nonDestructiveValidations =
  [ ValidationChartsVscode
  , ValidationChartsApi
  , ValidationChartsWebsocket
  , ValidationAdminRoutes
  , ValidationPublicDns
  , ValidationDnsAws
  , ValidationAwsIam
  , ValidationAwsEks
  , ValidationPulumi
  , ValidationHaRke2Aws
  , ValidationGatewayDaemon
  , ValidationGatewayPods
  , ValidationGatewayPartition
  , ValidationChartsPlatform
  , ValidationResourceGuardrails
  , ValidationDaemonBootstrap
  , ValidationPulsarBroker
  , ValidationChartsStorage
  , ValidationKeycloakInvite
  , ValidationSealedVault
  ]

data ObservationTag
  = RestartFreeReadyTag
  | RestartDeltaTag
  | OomKilledTag
  | MemoryWarningTag
  | MemoryFailureTag
  | PendingTag
  | UnobservableTag
  deriving (Eq, Show)

observationTag :: GatewayPodHealthObservation -> (String, ObservationTag)
observationTag observation =
  case observation of
    GatewayRestartFreeReady _ -> ("ready", RestartFreeReadyTag)
    GatewayRestartDelta _ -> ("restart", RestartDeltaTag)
    GatewayOomKilledResidue _ -> ("oom", OomKilledTag)
    GatewayMemoryPressure GatewayMemoryWarning _ -> ("warning", MemoryWarningTag)
    GatewayMemoryPressure GatewayMemoryFailure _ -> ("failure", MemoryFailureTag)
    GatewayPodPending _ -> ("pending", PendingTag)
    GatewayPodUnobservable _ _ -> ("unobservable", UnobservableTag)

thresholds :: GatewayMemoryThresholds
thresholds = gatewayPolicyMemoryThresholds policyTwoSamples

policyTwoSamples :: GatewayStabilityPolicy
policyTwoSamples =
  case mkGatewayStabilityPolicy 1 2 runtimePlan of
    Left err -> error (show err)
    Right policy -> policy

runtimePlan :: RuntimeMemory.RuntimeMemoryPlan
runtimePlan =
  case RuntimeMemory.validateRuntimeMemoryPlan
    RuntimeMemory.RuntimeMemoryInputs
      { RuntimeMemory.runtimeBoundedApplicationState = bytes RuntimeMemory.BoundedApplicationState 10
      , RuntimeMemory.runtimeBoundedPendingPersistenceState =
          bytes RuntimeMemory.BoundedPendingPersistenceState 10
      , RuntimeMemory.runtimeInHeapTransportDecodeScratch =
          bytes RuntimeMemory.InHeapTransportDecodeScratch 10
      , RuntimeMemory.runtimeOtherHeapReserve = bytes RuntimeMemory.OtherHeapReserve 10
      , RuntimeMemory.runtimeHeapCap = bytes RuntimeMemory.HeapCap 50
      , RuntimeMemory.runtimeNativeNonHeapReserve = bytes RuntimeMemory.NativeNonHeapReserve 10
      , RuntimeMemory.runtimeRawChildSchedule =
          RuntimeMemory.BoundedChildSchedule 1 (Just 1000) [10]
      , RuntimeMemory.runtimeKernelCgroupReserve = bytes RuntimeMemory.KernelCgroupReserve 10
      , RuntimeMemory.runtimeSafetyMargin = bytes RuntimeMemory.SafetyMargin 20
      , RuntimeMemory.runtimeContainerMemoryLimit = bytes RuntimeMemory.ContainerMemoryLimit 120
      } of
    Left err -> error (show err)
    Right plan -> plan

bytes :: RuntimeMemory.MemoryTerm -> Natural -> RuntimeMemory.PositiveBytes
bytes term value =
  case RuntimeMemory.mkPositiveBytes term value of
    Left err -> error (show err)
    Right positive -> positive

readySample :: GatewayPodSample
readySample =
  GatewayPodSample
    { gatewaySamplePodName = "gateway-a"
    , gatewaySamplePodUid = "uid-a"
    , gatewaySamplePhase = Just GatewayPodRunning
    , gatewaySampleReady = Just True
    , gatewaySampleRestartCount = Just 0
    , gatewaySampleTerminationEvidence = []
    , gatewaySampleCurrentLimitBytes = Just 120
    , gatewaySampleWorkingSetBytes = Just 79
    , gatewaySampleObservedAt = sampleTime
    }

sampleWithOom :: GatewayPodSample -> GatewayPodSample
sampleWithOom sample =
  sample
    { gatewaySampleTerminationEvidence =
        [ GatewayTerminationEvidence
            { gatewayTerminationSource = GatewayLastContainerState
            , gatewayTerminationReason = GatewayOomKilled
            , gatewayTerminationTime = Just "2026-07-10T10:00:00Z"
            }
        ]
    }

sampleTime :: Text
sampleTime = "2026-07-10T10:01:00Z"

observeGreen :: Text -> GatewayStabilityState -> GatewayStabilityState
observeGreen uid =
  observeGatewayRuntimePayloads
    sampleTime
    (podsPayload [podValue "gateway-a" uid 0 Nothing])
    emptyListPayload
    (metricsPayload [("gateway-a", 70)])

podsPayload :: [Value] -> Value
podsPayload pods = object ["items" .= pods]

podValue :: Text -> Text -> Natural -> Maybe Text -> Value
podValue podName podUid restartCount maybeLastReason =
  object
    [ "metadata" .= object ["name" .= podName, "uid" .= podUid]
    , "spec"
        .= object
          [ "containers"
              .= [ object
                     [ "name" .= ("gateway" :: Text)
                     , "resources"
                         .= object
                           [ "limits" .= object ["memory" .= (120 :: Natural)]
                           ]
                     ]
                 ]
          ]
    , "status"
        .= object
          [ "phase" .= ("Running" :: Text)
          , "conditions"
              .= [ object
                     [ "type" .= ("Ready" :: Text)
                     , "status" .= ("True" :: Text)
                     ]
                 ]
          , "containerStatuses"
              .= [ object
                     [ "name" .= ("gateway" :: Text)
                     , "restartCount" .= restartCount
                     , "lastState" .= lastStateValue maybeLastReason
                     ]
                 ]
          ]
    ]

lastStateValue :: Maybe Text -> Value
lastStateValue maybeReason =
  case maybeReason of
    Nothing -> object []
    Just reason ->
      object
        [ "terminated"
            .= object
              [ "reason" .= reason
              , "finishedAt" .= ("2026-07-10T10:00:00Z" :: Text)
              ]
        ]

metricsPayload :: [(Text, Natural)] -> Value
metricsPayload readings =
  object
    [ "items"
        .= map
          ( \(podName, memoryBytes) ->
              object
                [ "metadata" .= object ["name" .= podName]
                , "containers"
                    .= [ object
                           [ "name" .= ("gateway" :: Text)
                           , "usage" .= object ["memory" .= memoryBytes]
                           ]
                       ]
                ]
          )
          readings
    ]

oomEventPayload :: Text -> Text -> Value
oomEventPayload podName podUid =
  object
    [ "items"
        .= [ object
               [ "involvedObject"
                   .= object
                     [ "kind" .= ("Pod" :: Text)
                     , "name" .= podName
                     , "uid" .= podUid
                     ]
               , "reason" .= ("OOMKilled" :: Text)
               , "lastTimestamp" .= ("2026-07-10T10:00:00Z" :: Text)
               ]
           ]
    ]

emptyListPayload :: Value
emptyListPayload = object ["items" .= ([] :: [Value])]

isOomReport :: GatewayRuntimeStabilityReport -> Bool
isOomReport report =
  case report of
    RuntimeUnhealthy (GatewayOomKilledResidue _) -> True
    _ -> False

isRestartReport :: GatewayRuntimeStabilityReport -> Bool
isRestartReport report =
  case report of
    RuntimeUnhealthy (GatewayRestartDelta _) -> True
    _ -> False

isUnreachableReport :: GatewayRuntimeStabilityReport -> Bool
isUnreachableReport report =
  case report of
    StabilityUnreachable _ -> True
    _ -> False

observationUnreachableReason
  :: GatewayRuntimeStabilityReport
  -> Maybe GatewayUnobservableReason
observationUnreachableReason report =
  case report of
    StabilityUnreachable (GatewayPodObservationUnreachable reason _) -> Just reason
    _ -> Nothing
