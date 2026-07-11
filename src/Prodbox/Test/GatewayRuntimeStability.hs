{-# LANGUAGE OverloadedStrings #-}

-- | Pure, fail-closed runtime-stability observations for gateway Pods.
--
-- Kubernetes reads belong at an interpreter boundary.  This module accepts
-- their JSON values, projects them into a finite observation type, and folds
-- those observations without performing IO.  A fatal observation is retained
-- for the rest of the run; the independently tracked healthy window may be
-- restarted only by an explicit planned-rollout transition.
module Prodbox.Test.GatewayRuntimeStability
  ( -- * Policy derived from the validated runtime-memory plan
    GatewayStabilityPolicy
  , GatewayStabilityPolicyError (..)
  , GatewayMemoryThresholds (..)
  , mkGatewayStabilityPolicy
  , gatewayPolicyExpectedReplicaCount
  , gatewayPolicyRequiredStableSamples
  , gatewayPolicyMemoryThresholds

    -- * Typed observations
  , GatewayPodPhase (..)
  , GatewayTerminationSource (..)
  , GatewayTerminationReason (..)
  , GatewayTerminationEvidence (..)
  , GatewayPodSample (..)
  , GatewayMemoryPressure (..)
  , GatewayUnobservableReason (..)
  , GatewayPodDiagnostic (..)
  , GatewayPodHealthObservation (..)
  , classifyGatewayPodHealth

    -- * Kubernetes payload projection
  , GatewayPayloadSource (..)
  , GatewayPayloadError (..)
  , GatewayRuntimeSnapshot (..)
  , parseGatewayRuntimePayloads

    -- * Run-wide and healthy-window folds
  , GatewayStabilityState
  , GatewayRuntimeStabilityReport (..)
  , GatewayStabilityUnreachableReason (..)
  , initialGatewayStabilityState
  , foldGatewayRuntimeSnapshot
  , observeGatewayRuntimePayloads
  , observeGatewayRuntimeFailure
  , noteGatewayPodDeleted
  , beginPlannedGatewayRollout
  , gatewayRuntimeStabilityReport
  , renderGatewayPodDiagnostic
  , renderGatewayRuntimeStabilityReport
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Scientific qualified as Scientific
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory

-- | The two observation thresholds and the authored container limit, all
-- projected from one validated Sprint-1.60 runtime-memory plan.
--
-- Warning begins at the planned outer runtime demand before its safety margin.
-- Failure begins at the plan's cgroup high-water boundary (limit minus safety
-- margin).  The validated outer inequality proves warning <= failure < limit.
data GatewayMemoryThresholds = GatewayMemoryThresholds
  { gatewayMemoryWarningBytes :: Natural
  , gatewayMemoryFailureBytes :: Natural
  , gatewayMemoryPlannedLimitBytes :: Natural
  }
  deriving (Eq, Show)

data GatewayStabilityPolicy = GatewayStabilityPolicy
  { policyExpectedReplicaCount :: Natural
  , policyRequiredStableSamples :: Natural
  , policyMemoryThresholds :: GatewayMemoryThresholds
  }
  deriving (Eq, Show)

data GatewayStabilityPolicyError
  = GatewayExpectedReplicaCountMustBePositive
  | GatewayRequiredStableSamplesMustBePositive
  deriving (Eq, Show)

-- | Build a stability policy without duplicating memory constants outside the
-- validated runtime-memory plan.
mkGatewayStabilityPolicy
  :: Natural
  -- ^ Intended gateway replica count.
  -> Natural
  -- ^ Consecutive complete snapshots required for success.
  -> RuntimeMemory.RuntimeMemoryPlan
  -> Either GatewayStabilityPolicyError GatewayStabilityPolicy
mkGatewayStabilityPolicy expectedReplicas requiredSamples runtimePlan
  | expectedReplicas == 0 = Left GatewayExpectedReplicaCountMustBePositive
  | requiredSamples == 0 = Left GatewayRequiredStableSamplesMustBePositive
  | otherwise =
      Right
        GatewayStabilityPolicy
          { policyExpectedReplicaCount = expectedReplicas
          , policyRequiredStableSamples = requiredSamples
          , policyMemoryThresholds = memoryThresholdsFromPlan runtimePlan
          }

gatewayPolicyExpectedReplicaCount :: GatewayStabilityPolicy -> Natural
gatewayPolicyExpectedReplicaCount = policyExpectedReplicaCount

gatewayPolicyRequiredStableSamples :: GatewayStabilityPolicy -> Natural
gatewayPolicyRequiredStableSamples = policyRequiredStableSamples

gatewayPolicyMemoryThresholds :: GatewayStabilityPolicy -> GatewayMemoryThresholds
gatewayPolicyMemoryThresholds = policyMemoryThresholds

memoryThresholdsFromPlan
  :: RuntimeMemory.RuntimeMemoryPlan
  -> GatewayMemoryThresholds
memoryThresholdsFromPlan runtimePlan =
  GatewayMemoryThresholds
    { gatewayMemoryWarningBytes = outerRequired - safetyMargin
    , gatewayMemoryFailureBytes = highWater
    , gatewayMemoryPlannedLimitBytes = containerLimit
    }
 where
  outerRequired =
    RuntimeMemory.positiveBytesValue
      (RuntimeMemory.runtimeMemoryOuterRequiredBytes runtimePlan)
  safetyMargin =
    RuntimeMemory.positiveBytesValue
      (RuntimeMemory.runtimeMemorySafetyMarginBytes runtimePlan)
  highWater =
    RuntimeMemory.positiveBytesValue
      (RuntimeMemory.runtimeMemoryHighWaterBytes runtimePlan)
  containerLimit =
    RuntimeMemory.positiveBytesValue
      (RuntimeMemory.runtimeMemoryContainerLimitBytes runtimePlan)

data GatewayPodPhase
  = GatewayPodRunning
  | GatewayPodPendingPhase
  | GatewayPodSucceeded
  | GatewayPodFailed
  | GatewayPodUnknown
  deriving (Eq, Show)

data GatewayTerminationSource
  = GatewayCurrentContainerState
  | GatewayLastContainerState
  | GatewayKubernetesEvent
  deriving (Eq, Show)

data GatewayTerminationReason
  = GatewayOomKilled
  | GatewayOtherTermination Text
  deriving (Eq, Show)

data GatewayTerminationEvidence = GatewayTerminationEvidence
  { gatewayTerminationSource :: GatewayTerminationSource
  , gatewayTerminationReason :: GatewayTerminationReason
  , gatewayTerminationTime :: Maybe Text
  }
  deriving (Eq, Show)

-- | One effect-boundary observation of the gateway container in one Pod.
-- Missing fields remain explicit so the classifier can fail closed rather than
-- manufacture a healthy value.
data GatewayPodSample = GatewayPodSample
  { gatewaySamplePodName :: Text
  , gatewaySamplePodUid :: Text
  , gatewaySamplePhase :: Maybe GatewayPodPhase
  , gatewaySampleReady :: Maybe Bool
  , gatewaySampleRestartCount :: Maybe Natural
  , gatewaySampleTerminationEvidence :: [GatewayTerminationEvidence]
  , gatewaySampleCurrentLimitBytes :: Maybe Natural
  , gatewaySampleWorkingSetBytes :: Maybe Natural
  , gatewaySampleObservedAt :: Text
  }
  deriving (Eq, Show)

data GatewayMemoryPressure
  = GatewayMemoryWarning
  | GatewayMemoryFailure
  deriving (Eq, Show)

data GatewayUnobservableReason
  = GatewayPhaseUnobservable
  | GatewayReadinessUnobservable
  | GatewayRestartCountUnobservable
  | GatewayRestartCountRegressed
      { gatewayPreviousRestartCount :: Natural
      , gatewayCurrentRestartCount :: Natural
      }
  | GatewayContainerLimitUnobservable
  | GatewayMemoryReadingUnobservable
  deriving (Eq, Show)

-- | The single diagnostic record used by every classifier outcome.  Optional
-- fields remain visible as @unobservable@ in the renderer.
data GatewayPodDiagnostic = GatewayPodDiagnostic
  { gatewayDiagnosticPodName :: Text
  , gatewayDiagnosticPodUid :: Text
  , gatewayDiagnosticRestartDelta :: Natural
  , gatewayDiagnosticTerminationReason :: Maybe Text
  , gatewayDiagnosticTerminationTime :: Maybe Text
  , gatewayDiagnosticCurrentLimitBytes :: Maybe Natural
  , gatewayDiagnosticSampledHighWaterBytes :: Maybe Natural
  , gatewayDiagnosticWarningThresholdBytes :: Natural
  , gatewayDiagnosticFailureThresholdBytes :: Natural
  , gatewayDiagnosticObservedAt :: Text
  }
  deriving (Eq, Show)

-- | Flat and exhaustive pod-health projection.  Constructor order does not
-- encode severity; 'classifyGatewayPodHealth' defines the explicit precedence.
data GatewayPodHealthObservation
  = GatewayRestartFreeReady GatewayPodDiagnostic
  | GatewayRestartDelta GatewayPodDiagnostic
  | GatewayOomKilledResidue GatewayPodDiagnostic
  | GatewayMemoryPressure GatewayMemoryPressure GatewayPodDiagnostic
  | GatewayPodPending GatewayPodDiagnostic
  | GatewayPodUnobservable GatewayUnobservableReason GatewayPodDiagnostic
  deriving (Eq, Show)

-- | Project one typed sample.  An absent baseline means the first sample for a
-- Pod UID; its existing restart count is therefore compared with zero rather
-- than accepted as a new healthy baseline.
classifyGatewayPodHealth
  :: GatewayMemoryThresholds
  -> Maybe Natural
  -- ^ Previous restart count for the same Pod UID.
  -> Maybe Natural
  -- ^ Maximum memory observed for this UID in the current healthy window.
  -> GatewayPodSample
  -> GatewayPodHealthObservation
classifyGatewayPodHealth thresholds previousRestart sampledHighWater sample =
  case findOomEvidence (gatewaySampleTerminationEvidence sample) of
    Just oomEvidence ->
      GatewayOomKilledResidue
        (diagnosticFor thresholds restartDelta sampledHighWater (Just oomEvidence) sample)
    Nothing ->
      case restartClassification previousRestart (gatewaySampleRestartCount sample) of
        RestartRegressed previous current ->
          GatewayPodUnobservable
            (GatewayRestartCountRegressed previous current)
            (diagnosticFor thresholds 0 sampledHighWater selectedTermination sample)
        RestartAdvanced delta ->
          GatewayRestartDelta
            (diagnosticFor thresholds delta sampledHighWater selectedTermination sample)
        RestartUnchanged delta ->
          classifyWithoutRestart
            thresholds
            delta
            sampledHighWater
            selectedTermination
            sample
        RestartUnavailable ->
          classifyWithoutRestart
            thresholds
            0
            sampledHighWater
            selectedTermination
            sample
 where
  selectedTermination = firstTerminationEvidence (gatewaySampleTerminationEvidence sample)
  restartDelta =
    case restartClassification previousRestart (gatewaySampleRestartCount sample) of
      RestartAdvanced delta -> delta
      RestartUnchanged delta -> delta
      RestartRegressed _ _ -> 0
      RestartUnavailable -> 0

data RestartClassification
  = RestartUnavailable
  | RestartUnchanged Natural
  | RestartAdvanced Natural
  | RestartRegressed Natural Natural

restartClassification :: Maybe Natural -> Maybe Natural -> RestartClassification
restartClassification _ Nothing = RestartUnavailable
restartClassification maybePrevious (Just current) =
  let previous = maybe 0 id maybePrevious
   in case compare current previous of
        LT -> RestartRegressed previous current
        EQ -> RestartUnchanged 0
        GT -> RestartAdvanced (current - previous)

classifyWithoutRestart
  :: GatewayMemoryThresholds
  -> Natural
  -> Maybe Natural
  -> Maybe GatewayTerminationEvidence
  -> GatewayPodSample
  -> GatewayPodHealthObservation
classifyWithoutRestart thresholds restartDelta sampledHighWater termination sample =
  case gatewaySamplePhase sample of
    Nothing -> unobservable GatewayPhaseUnobservable
    Just phase ->
      case gatewaySampleReady sample of
        Nothing ->
          if phase == GatewayPodPendingPhase
            then pending
            else unobservable GatewayReadinessUnobservable
        Just False -> pending
        Just True
          | phase /= GatewayPodRunning -> pending
          | otherwise -> classifyReadyStatus
 where
  diagnostic = diagnosticFor thresholds restartDelta sampledHighWater termination sample
  unobservable reason = GatewayPodUnobservable reason diagnostic
  pending = GatewayPodPending diagnostic
  classifyReadyStatus =
    case gatewaySampleRestartCount sample of
      Nothing -> unobservable GatewayRestartCountUnobservable
      Just _ ->
        case gatewaySampleCurrentLimitBytes sample of
          Nothing -> unobservable GatewayContainerLimitUnobservable
          Just _ ->
            case sampledHighWater of
              Nothing -> unobservable GatewayMemoryReadingUnobservable
              Just highWater
                | highWater >= gatewayMemoryFailureBytes thresholds ->
                    GatewayMemoryPressure GatewayMemoryFailure diagnostic
                | highWater >= gatewayMemoryWarningBytes thresholds ->
                    GatewayMemoryPressure GatewayMemoryWarning diagnostic
                | otherwise -> GatewayRestartFreeReady diagnostic

diagnosticFor
  :: GatewayMemoryThresholds
  -> Natural
  -> Maybe Natural
  -> Maybe GatewayTerminationEvidence
  -> GatewayPodSample
  -> GatewayPodDiagnostic
diagnosticFor thresholds restartDelta sampledHighWater termination sample =
  GatewayPodDiagnostic
    { gatewayDiagnosticPodName = gatewaySamplePodName sample
    , gatewayDiagnosticPodUid = gatewaySamplePodUid sample
    , gatewayDiagnosticRestartDelta = restartDelta
    , gatewayDiagnosticTerminationReason =
        terminationReasonText . gatewayTerminationReason <$> termination
    , gatewayDiagnosticTerminationTime = termination >>= gatewayTerminationTime
    , gatewayDiagnosticCurrentLimitBytes = gatewaySampleCurrentLimitBytes sample
    , gatewayDiagnosticSampledHighWaterBytes = sampledHighWater
    , gatewayDiagnosticWarningThresholdBytes = gatewayMemoryWarningBytes thresholds
    , gatewayDiagnosticFailureThresholdBytes = gatewayMemoryFailureBytes thresholds
    , gatewayDiagnosticObservedAt = gatewaySampleObservedAt sample
    }

terminationReasonText :: GatewayTerminationReason -> Text
terminationReasonText reason =
  case reason of
    GatewayOomKilled -> "OOMKilled"
    GatewayOtherTermination rawReason -> rawReason

findOomEvidence :: [GatewayTerminationEvidence] -> Maybe GatewayTerminationEvidence
findOomEvidence = find ((== GatewayOomKilled) . gatewayTerminationReason)

firstTerminationEvidence :: [GatewayTerminationEvidence] -> Maybe GatewayTerminationEvidence
firstTerminationEvidence evidence =
  case evidence of
    [] -> Nothing
    firstEvidence : _ -> Just firstEvidence

data GatewayPayloadSource
  = GatewayPodsPayload
  | GatewayEventsPayload
  | GatewayMetricsPayload
  deriving (Eq, Show)

data GatewayPayloadError = GatewayPayloadError
  { gatewayPayloadErrorSource :: GatewayPayloadSource
  , gatewayPayloadErrorMessage :: Text
  }
  deriving (Eq, Show)

data GatewayRuntimeSnapshot = GatewayRuntimeSnapshot
  { gatewaySnapshotMemoryThresholds :: GatewayMemoryThresholds
  , gatewaySnapshotSamples :: [GatewayPodSample]
  }
  deriving (Eq, Show)

data ParsedGatewayPod = ParsedGatewayPod
  { parsedGatewayPodName :: Text
  , parsedGatewayPodUid :: Text
  , parsedGatewayPodPhase :: Maybe GatewayPodPhase
  , parsedGatewayPodReady :: Maybe Bool
  , parsedGatewayPodRestartCount :: Maybe Natural
  , parsedGatewayPodTerminations :: [GatewayTerminationEvidence]
  , parsedGatewayPodLimitBytes :: Maybe Natural
  }

-- | Parse one complete Kubernetes list observation.  The three payloads are
-- the Pod list, Event list, and metrics/cgroup list respectively.  Malformed
-- relevant entries fail the whole observation; unrelated namespace objects are
-- ignored.
parseGatewayRuntimePayloads
  :: GatewayStabilityPolicy
  -> Text
  -- ^ Effect-boundary sample time.
  -> Value
  -- ^ Kubernetes Pod-list JSON.
  -> Value
  -- ^ Kubernetes Event-list JSON.
  -> Value
  -- ^ Metrics/cgroup-list JSON.
  -> Either GatewayPayloadError GatewayRuntimeSnapshot
parseGatewayRuntimePayloads policy observedAt podsValue eventsValue metricsValue = do
  pods <- first (GatewayPayloadError GatewayPodsPayload) (parseGatewayPods podsValue)
  if null pods
    then
      Left
        GatewayPayloadError
          { gatewayPayloadErrorSource = GatewayPodsPayload
          , gatewayPayloadErrorMessage = "no Pods containing the gateway container were observable"
          }
    else do
      let podNames = Set.fromList (map parsedGatewayPodName pods)
          podUids = Set.fromList (map parsedGatewayPodUid pods)
      events <-
        first
          (GatewayPayloadError GatewayEventsPayload)
          (parseGatewayEvents podNames podUids eventsValue)
      memoryReadings <-
        first
          (GatewayPayloadError GatewayMetricsPayload)
          (parseGatewayMetrics podNames metricsValue)
      let eventEvidence =
            Map.fromListWith
              (++)
              [ (eventUid, [evidence])
              | (_, eventUid, evidence) <- events
              ]
          currentPodUids = Set.fromList (map parsedGatewayPodUid pods)
          detachedEventSamples =
            [ eventOnlySample observedAt eventPodName eventUid evidence
            | (eventPodName, eventUid, evidence) <- events
            , eventUid `Set.notMember` currentPodUids
            ]
          samples =
            map
              (parsedPodToSample observedAt eventEvidence memoryReadings)
              pods
              ++ detachedEventSamples
      Right
        GatewayRuntimeSnapshot
          { gatewaySnapshotMemoryThresholds = policyMemoryThresholds policy
          , gatewaySnapshotSamples = samples
          }

parsedPodToSample
  :: Text
  -> Map Text [GatewayTerminationEvidence]
  -> Map Text Natural
  -> ParsedGatewayPod
  -> GatewayPodSample
parsedPodToSample observedAt eventEvidence memoryReadings pod =
  GatewayPodSample
    { gatewaySamplePodName = parsedGatewayPodName pod
    , gatewaySamplePodUid = parsedGatewayPodUid pod
    , gatewaySamplePhase = parsedGatewayPodPhase pod
    , gatewaySampleReady = parsedGatewayPodReady pod
    , gatewaySampleRestartCount = parsedGatewayPodRestartCount pod
    , gatewaySampleTerminationEvidence =
        parsedGatewayPodTerminations pod
          ++ Map.findWithDefault [] (parsedGatewayPodUid pod) eventEvidence
    , gatewaySampleCurrentLimitBytes = parsedGatewayPodLimitBytes pod
    , gatewaySampleWorkingSetBytes = Map.lookup (parsedGatewayPodName pod) memoryReadings
    , gatewaySampleObservedAt = observedAt
    }

eventOnlySample
  :: Text
  -> Text
  -> Text
  -> GatewayTerminationEvidence
  -> GatewayPodSample
eventOnlySample observedAt podName podUid evidence =
  GatewayPodSample
    { gatewaySamplePodName = podName
    , gatewaySamplePodUid = podUid
    , gatewaySamplePhase = Nothing
    , gatewaySampleReady = Nothing
    , gatewaySampleRestartCount = Nothing
    , gatewaySampleTerminationEvidence = [evidence]
    , gatewaySampleCurrentLimitBytes = Nothing
    , gatewaySampleWorkingSetBytes = Nothing
    , gatewaySampleObservedAt = observedAt
    }

parseGatewayPods :: Value -> Either Text [ParsedGatewayPod]
parseGatewayPods value = do
  items <- listItems "Pod list" value
  parsed <- traverse parseGatewayPodCandidate (zip [0 :: Int ..] items)
  let pods = mapMaybe id parsed
      names = map parsedGatewayPodName pods
      uids = map parsedGatewayPodUid pods
  requireUnique "gateway Pod name" names
  requireUnique "gateway Pod UID" uids
  pure pods

parseGatewayPodCandidate :: (Int, Value) -> Either Text (Maybe ParsedGatewayPod)
parseGatewayPodCandidate (index, value) = do
  objectValue <- valueObject (indexed "Pod" index) value
  case optionalObjectField "spec" objectValue >>= optionalArrayField "containers" of
    Nothing -> Right Nothing
    Just containers ->
      case findNamedObject gatewayContainerName containers of
        Left err -> Left (indexed "Pod" index <> ": " <> err)
        Right Nothing -> Right Nothing
        Right (Just containerObject) -> do
          metadata <- requiredObjectField "metadata" objectValue
          podName <- requiredTextField "name" metadata
          podUid <- requiredTextField "uid" metadata
          let status = optionalObjectField "status" objectValue
          phase <- traverse parsePodPhase (status >>= optionalTextField "phase")
          ready <- maybe (Right Nothing) parseReadyCondition status
          (restartCount, terminations) <- maybe (Right (Nothing, [])) parseContainerStatus status
          limitBytes <- parseContainerLimit containerObject
          Right
            ( Just
                ParsedGatewayPod
                  { parsedGatewayPodName = podName
                  , parsedGatewayPodUid = podUid
                  , parsedGatewayPodPhase = phase
                  , parsedGatewayPodReady = ready
                  , parsedGatewayPodRestartCount = restartCount
                  , parsedGatewayPodTerminations = terminations
                  , parsedGatewayPodLimitBytes = limitBytes
                  }
            )

gatewayContainerName :: Text
gatewayContainerName = "gateway"

parsePodPhase :: Text -> Either Text GatewayPodPhase
parsePodPhase phase =
  case phase of
    "Running" -> Right GatewayPodRunning
    "Pending" -> Right GatewayPodPendingPhase
    "Succeeded" -> Right GatewayPodSucceeded
    "Failed" -> Right GatewayPodFailed
    "Unknown" -> Right GatewayPodUnknown
    _ -> Left ("unsupported gateway Pod phase: " <> phase)

parseReadyCondition :: KeyMap.KeyMap Value -> Either Text (Maybe Bool)
parseReadyCondition status =
  case optionalArrayField "conditions" status of
    Nothing -> Right Nothing
    Just conditions -> do
      readyConditions <- mapMaybeM readyConditionValue conditions
      case readyConditions of
        [] -> Right Nothing
        [ready] -> Right (Just ready)
        _ -> Left "gateway Pod has duplicate Ready conditions"

readyConditionValue :: Value -> Either Text (Maybe Bool)
readyConditionValue value = do
  objectValue <- valueObject "Pod condition" value
  case optionalTextField "type" objectValue of
    Just "Ready" ->
      case optionalTextField "status" objectValue of
        Just "True" -> Right (Just True)
        Just "False" -> Right (Just False)
        Just "Unknown" -> Right (Just False)
        Just status -> Left ("unsupported Ready condition status: " <> status)
        Nothing -> Left "Ready condition is missing status"
    _ -> Right Nothing

parseContainerStatus
  :: KeyMap.KeyMap Value
  -> Either Text (Maybe Natural, [GatewayTerminationEvidence])
parseContainerStatus status =
  case optionalArrayField "containerStatuses" status of
    Nothing -> Right (Nothing, [])
    Just statuses -> do
      maybeContainer <- findNamedObject gatewayContainerName statuses
      case maybeContainer of
        Nothing -> Right (Nothing, [])
        Just container -> do
          restartCount <- traverse valueNatural (lookupField "restartCount" container)
          currentTermination <-
            parseStateTermination
              GatewayCurrentContainerState
              (optionalObjectField "state" container)
          lastTermination <-
            parseStateTermination
              GatewayLastContainerState
              (optionalObjectField "lastState" container)
          Right (restartCount, mapMaybe id [currentTermination, lastTermination])

parseStateTermination
  :: GatewayTerminationSource
  -> Maybe (KeyMap.KeyMap Value)
  -> Either Text (Maybe GatewayTerminationEvidence)
parseStateTermination _ Nothing = Right Nothing
parseStateTermination source (Just state) =
  case optionalObjectField "terminated" state of
    Nothing -> Right Nothing
    Just terminated ->
      case optionalTextField "reason" terminated of
        Nothing -> Right Nothing
        Just reason ->
          Right
            ( Just
                GatewayTerminationEvidence
                  { gatewayTerminationSource = source
                  , gatewayTerminationReason = parseTerminationReason reason
                  , gatewayTerminationTime = optionalTextField "finishedAt" terminated
                  }
            )

parseTerminationReason :: Text -> GatewayTerminationReason
parseTerminationReason reason
  | reason `elem` ["OOMKilled", "OOMKilling", "ContainerOOM"] = GatewayOomKilled
  | otherwise = GatewayOtherTermination reason

parseContainerLimit :: KeyMap.KeyMap Value -> Either Text (Maybe Natural)
parseContainerLimit container =
  case optionalObjectField "resources" container >>= optionalObjectField "limits" of
    Nothing -> Right Nothing
    Just limits -> traverse memoryValueBytes (lookupField "memory" limits)

parseGatewayEvents
  :: Set Text
  -> Set Text
  -> Value
  -> Either Text [(Text, Text, GatewayTerminationEvidence)]
parseGatewayEvents podNames podUids value = do
  items <- listItems "Event list" value
  mapMaybeM parseEvent (zip [0 :: Int ..] items)
 where
  parseEvent (index, eventValue) = do
    event <- valueObject (indexed "Event" index) eventValue
    case optionalObjectField "involvedObject" event of
      Nothing -> Right Nothing
      Just involved -> do
        let maybeName = optionalTextField "name" involved
            maybeUid = optionalTextField "uid" involved
            relevant =
              maybe False (`Set.member` podNames) maybeName
                || maybe False (`Set.member` podUids) maybeUid
                || maybe False (Text.isPrefixOf "gateway-") maybeName
        if not relevant
          then Right Nothing
          else case optionalTextField "reason" event of
            Just reason
              | parseTerminationReason reason == GatewayOomKilled ->
                  case (maybeName, maybeUid) of
                    (Just podName, Just podUid) ->
                      Right (Just (podName, podUid, oomEvent event))
                    _ ->
                      Left
                        ( indexed "Event" index
                            <> " has gateway OOM evidence but lacks Pod name or UID"
                        )
            _ -> Right Nothing

  oomEvent event =
    GatewayTerminationEvidence
      { gatewayTerminationSource = GatewayKubernetesEvent
      , gatewayTerminationReason = GatewayOomKilled
      , gatewayTerminationTime = eventTimestamp event
      }

eventTimestamp :: KeyMap.KeyMap Value -> Maybe Text
eventTimestamp event =
  optionalTextField "eventTime" event
    <|> optionalTextField "lastTimestamp" event
    <|> optionalTextField "firstTimestamp" event
    <|> (optionalObjectField "metadata" event >>= optionalTextField "creationTimestamp")

parseGatewayMetrics :: Set Text -> Value -> Either Text (Map Text Natural)
parseGatewayMetrics podNames value = do
  items <- listItems "metrics list" value
  pairs <- mapMaybeM parseMetric (zip [0 :: Int ..] items)
  requireUnique "gateway metrics Pod name" (map fst pairs)
  pure (Map.fromList pairs)
 where
  parseMetric (index, metricValue) = do
    metric <- valueObject (indexed "metrics item" index) metricValue
    case optionalObjectField "metadata" metric >>= optionalTextField "name" of
      Nothing -> Right Nothing
      Just podName
        | podName `Set.notMember` podNames -> Right Nothing
        | otherwise -> do
            containers <- requiredArrayField "containers" metric
            maybeContainer <- findNamedObject gatewayContainerName containers
            case maybeContainer of
              Nothing ->
                Left (indexed "metrics item" index <> " is missing the gateway container")
              Just container -> do
                usage <- requiredObjectField "usage" container
                memoryValue <-
                  case lookupField "memoryHighWater" usage of
                    Just highWaterValue -> Right highWaterValue
                    Nothing -> requiredField "memory" usage
                memoryBytes <- memoryValueBytes memoryValue
                Right (Just (podName, memoryBytes))

data GatewayHealthyWindow = GatewayHealthyWindow
  { healthyWindowRestartCounts :: Map Text Natural
  , healthyWindowHighWaterBytes :: Map Text Natural
  , healthyWindowStableSamples :: Natural
  }
  deriving (Eq, Show)

data GatewayStabilityUnreachableReason
  = GatewayPayloadUnreachable GatewayPayloadError
  | GatewayPodObservationUnreachable
      GatewayUnobservableReason
      GatewayPodDiagnostic
  | GatewaySnapshotPolicyMismatch
      GatewayMemoryThresholds
      GatewayMemoryThresholds
  deriving (Eq, Show)

data GatewayAbsorbingOutcome
  = AbsorbedRuntimeUnhealthy GatewayPodHealthObservation
  | AbsorbedStabilityUnreachable GatewayStabilityUnreachableReason
  deriving (Eq, Show)

data GatewayStabilityState = GatewayStabilityState
  { stabilityStatePolicy :: GatewayStabilityPolicy
  , stabilityStateAbsorbingOutcome :: Maybe GatewayAbsorbingOutcome
  , stabilityStateHealthyWindow :: GatewayHealthyWindow
  }
  deriving (Eq, Show)

data GatewayRuntimeStabilityReport
  = StableObserved
      { gatewayStableSampleCount :: Natural
      }
  | NotStableYet
      { gatewayStableSampleCount :: Natural
      , gatewayRequiredStableSampleCount :: Natural
      }
  | RuntimeUnhealthy GatewayPodHealthObservation
  | StabilityUnreachable GatewayStabilityUnreachableReason
  deriving (Eq, Show)

initialGatewayStabilityState :: GatewayStabilityPolicy -> GatewayStabilityState
initialGatewayStabilityState policy =
  GatewayStabilityState
    { stabilityStatePolicy = policy
    , stabilityStateAbsorbingOutcome = Nothing
    , stabilityStateHealthyWindow = emptyHealthyWindow
    }

emptyHealthyWindow :: GatewayHealthyWindow
emptyHealthyWindow =
  GatewayHealthyWindow
    { healthyWindowRestartCounts = Map.empty
    , healthyWindowHighWaterBytes = Map.empty
    , healthyWindowStableSamples = 0
    }

-- | Fold one complete replica-set sample.  Fatal evidence is retained once;
-- later green snapshots, UID replacement, and deletion cannot clear it.
foldGatewayRuntimeSnapshot
  :: GatewayRuntimeSnapshot
  -> GatewayStabilityState
  -> GatewayStabilityState
foldGatewayRuntimeSnapshot snapshot state
  | Just _ <- stabilityStateAbsorbingOutcome state = state
  | snapshotThresholds /= policyThresholds =
      state
        { stabilityStateAbsorbingOutcome =
            Just
              ( AbsorbedStabilityUnreachable
                  (GatewaySnapshotPolicyMismatch policyThresholds snapshotThresholds)
              )
        }
  | otherwise =
      state
        { stabilityStateAbsorbingOutcome = firstAbsorbingOutcome observations
        , stabilityStateHealthyWindow = nextWindow
        }
 where
  policy = stabilityStatePolicy state
  policyThresholds = policyMemoryThresholds policy
  snapshotThresholds = gatewaySnapshotMemoryThresholds snapshot
  previousWindow = stabilityStateHealthyWindow state
  samples = gatewaySnapshotSamples snapshot
  currentUids = Set.fromList (map gatewaySamplePodUid samples)
  previousRestarts = healthyWindowRestartCounts previousWindow
  previousHighWater = healthyWindowHighWaterBytes previousWindow
  highWaterFor sample =
    maximumMaybe
      [ Map.lookup (gatewaySamplePodUid sample) previousHighWater
      , gatewaySampleWorkingSetBytes sample
      ]
  observations =
    map
      ( \sample ->
          classifyGatewayPodHealth
            policyThresholds
            (Map.lookup (gatewaySamplePodUid sample) previousRestarts)
            (highWaterFor sample)
            sample
      )
      samples
  completeReplicaSet =
    fromIntegral (length samples) == policyExpectedReplicaCount policy
      && Set.size currentUids == length samples
  previousUids = Map.keysSet previousRestarts
  podSetContinuous = Map.null previousRestarts || currentUids == previousUids
  snapshotStable =
    completeReplicaSet
      && podSetContinuous
      && all observationIsStable observations
  retainedRestarts =
    Map.fromList
      [ (uid, restartCount)
      | sample <- samples
      , let uid = gatewaySamplePodUid sample
      , Just restartCount <- [gatewaySampleRestartCount sample]
      ]
  retainedHighWater =
    Map.fromList
      [ (gatewaySamplePodUid sample, highWater)
      | sample <- samples
      , Just highWater <- [highWaterFor sample]
      ]
  nextWindow =
    GatewayHealthyWindow
      { healthyWindowRestartCounts = retainedRestarts
      , healthyWindowHighWaterBytes = retainedHighWater
      , healthyWindowStableSamples =
          if snapshotStable
            then healthyWindowStableSamples previousWindow + 1
            else 0
      }

maximumMaybe :: [Maybe Natural] -> Maybe Natural
maximumMaybe values =
  case mapMaybe id values of
    [] -> Nothing
    present -> Just (maximum present)

observationIsStable :: GatewayPodHealthObservation -> Bool
observationIsStable observation =
  case observation of
    GatewayRestartFreeReady _ -> True
    GatewayRestartDelta _ -> False
    GatewayOomKilledResidue _ -> False
    GatewayMemoryPressure _ _ -> False
    GatewayPodPending _ -> False
    GatewayPodUnobservable _ _ -> False

firstAbsorbingOutcome :: [GatewayPodHealthObservation] -> Maybe GatewayAbsorbingOutcome
firstAbsorbingOutcome observations =
  case find isRuntimeUnhealthy observations of
    Just unhealthy -> Just (AbsorbedRuntimeUnhealthy unhealthy)
    Nothing ->
      case mapMaybe unobservableOutcome observations of
        [] -> Nothing
        unreachable : _ -> Just (AbsorbedStabilityUnreachable unreachable)
 where
  isRuntimeUnhealthy observation =
    case observation of
      GatewayRestartDelta _ -> True
      GatewayOomKilledResidue _ -> True
      GatewayMemoryPressure GatewayMemoryFailure _ -> True
      GatewayRestartFreeReady _ -> False
      GatewayMemoryPressure GatewayMemoryWarning _ -> False
      GatewayPodPending _ -> False
      GatewayPodUnobservable _ _ -> False
  unobservableOutcome observation =
    case observation of
      GatewayPodUnobservable reason diagnostic ->
        Just (GatewayPodObservationUnreachable reason diagnostic)
      _ -> Nothing

-- | Parse and fold a payload set, absorbing any decode/read-shape failure as
-- 'StabilityUnreachable'.
observeGatewayRuntimePayloads
  :: Text
  -> Value
  -> Value
  -> Value
  -> GatewayStabilityState
  -> GatewayStabilityState
observeGatewayRuntimePayloads observedAt podsValue eventsValue metricsValue state =
  case parseGatewayRuntimePayloads
    (stabilityStatePolicy state)
    observedAt
    podsValue
    eventsValue
    metricsValue of
    Left err ->
      absorbIfEmpty
        (AbsorbedStabilityUnreachable (GatewayPayloadUnreachable err))
        state
    Right snapshot -> foldGatewayRuntimeSnapshot snapshot state

-- | Absorb a failed effect-boundary observation (for example a timed-out
-- @kubectl get pods@) without inventing a malformed JSON payload.
observeGatewayRuntimeFailure
  :: GatewayPayloadSource
  -> Text
  -> GatewayStabilityState
  -> GatewayStabilityState
observeGatewayRuntimeFailure source message =
  absorbIfEmpty
    ( AbsorbedStabilityUnreachable
        (GatewayPayloadUnreachable (GatewayPayloadError source message))
    )

absorbIfEmpty :: GatewayAbsorbingOutcome -> GatewayStabilityState -> GatewayStabilityState
absorbIfEmpty outcome state =
  case stabilityStateAbsorbingOutcome state of
    Just _ -> state
    Nothing -> state {stabilityStateAbsorbingOutcome = Just outcome}

-- | Record a watched Pod deletion.  Only that UID's restart/high-water
-- baseline is removed and the consecutive-success counter is interrupted.
-- Run-wide fatal evidence is deliberately untouched.
noteGatewayPodDeleted :: Text -> GatewayStabilityState -> GatewayStabilityState
noteGatewayPodDeleted podUid state =
  state
    { stabilityStateHealthyWindow =
        window
          { healthyWindowRestartCounts =
              Map.delete podUid (healthyWindowRestartCounts window)
          , healthyWindowHighWaterBytes =
              Map.delete podUid (healthyWindowHighWaterBytes window)
          , healthyWindowStableSamples = 0
          }
    }
 where
  window = stabilityStateHealthyWindow state

-- | Planned rollout transition.  This is the only operation that replaces the
-- entire healthy-window baseline.  It never touches the absorbing run result.
beginPlannedGatewayRollout :: GatewayStabilityState -> GatewayStabilityState
beginPlannedGatewayRollout state =
  state {stabilityStateHealthyWindow = emptyHealthyWindow}

gatewayRuntimeStabilityReport :: GatewayStabilityState -> GatewayRuntimeStabilityReport
gatewayRuntimeStabilityReport state =
  case stabilityStateAbsorbingOutcome state of
    Just (AbsorbedRuntimeUnhealthy observation) -> RuntimeUnhealthy observation
    Just (AbsorbedStabilityUnreachable reason) -> StabilityUnreachable reason
    Nothing
      | stableSamples >= policyRequiredStableSamples policy ->
          StableObserved stableSamples
      | otherwise ->
          NotStableYet stableSamples (policyRequiredStableSamples policy)
 where
  policy = stabilityStatePolicy state
  stableSamples =
    healthyWindowStableSamples (stabilityStateHealthyWindow state)

renderGatewayPodDiagnostic :: GatewayPodDiagnostic -> String
renderGatewayPodDiagnostic diagnostic =
  unwords
    [ "pod=" ++ Text.unpack (gatewayDiagnosticPodName diagnostic)
    , "uid=" ++ Text.unpack (gatewayDiagnosticPodUid diagnostic)
    , "restart_delta=" ++ show (gatewayDiagnosticRestartDelta diagnostic)
    , "termination_reason=" ++ renderMaybeText (gatewayDiagnosticTerminationReason diagnostic)
    , "termination_time=" ++ renderMaybeText (gatewayDiagnosticTerminationTime diagnostic)
    , "current_limit_bytes=" ++ renderMaybeNatural (gatewayDiagnosticCurrentLimitBytes diagnostic)
    , "sampled_high_water_bytes="
        ++ renderMaybeNatural (gatewayDiagnosticSampledHighWaterBytes diagnostic)
    , "warning_threshold_bytes=" ++ show (gatewayDiagnosticWarningThresholdBytes diagnostic)
    , "failure_threshold_bytes=" ++ show (gatewayDiagnosticFailureThresholdBytes diagnostic)
    , "observed_at=" ++ Text.unpack (gatewayDiagnosticObservedAt diagnostic)
    ]

renderGatewayRuntimeStabilityReport :: GatewayRuntimeStabilityReport -> String
renderGatewayRuntimeStabilityReport report =
  case report of
    StableObserved samples -> "StableObserved stable_samples=" ++ show samples
    NotStableYet samples required ->
      "NotStableYet stable_samples=" ++ show samples ++ " required_samples=" ++ show required
    RuntimeUnhealthy observation ->
      "RuntimeUnhealthy " ++ renderObservation observation
    StabilityUnreachable reason ->
      "StabilityUnreachable " ++ renderUnreachable reason

renderObservation :: GatewayPodHealthObservation -> String
renderObservation observation =
  case observation of
    GatewayRestartFreeReady diagnostic ->
      "restart-free-ready " ++ renderGatewayPodDiagnostic diagnostic
    GatewayRestartDelta diagnostic ->
      "restart-delta " ++ renderGatewayPodDiagnostic diagnostic
    GatewayOomKilledResidue diagnostic ->
      "oom-killed-residue " ++ renderGatewayPodDiagnostic diagnostic
    GatewayMemoryPressure pressure diagnostic ->
      memoryPressureLabel pressure ++ " " ++ renderGatewayPodDiagnostic diagnostic
    GatewayPodPending diagnostic ->
      "pending " ++ renderGatewayPodDiagnostic diagnostic
    GatewayPodUnobservable reason diagnostic ->
      "unobservable=" ++ show reason ++ " " ++ renderGatewayPodDiagnostic diagnostic

memoryPressureLabel :: GatewayMemoryPressure -> String
memoryPressureLabel pressure =
  case pressure of
    GatewayMemoryWarning -> "memory-warning"
    GatewayMemoryFailure -> "memory-failure"

renderUnreachable :: GatewayStabilityUnreachableReason -> String
renderUnreachable reason =
  case reason of
    GatewayPayloadUnreachable err ->
      "payload="
        ++ show (gatewayPayloadErrorSource err)
        ++ " error="
        ++ Text.unpack (gatewayPayloadErrorMessage err)
    GatewayPodObservationUnreachable observationReason diagnostic ->
      "observation="
        ++ show observationReason
        ++ " "
        ++ renderGatewayPodDiagnostic diagnostic
    GatewaySnapshotPolicyMismatch expected actual ->
      "snapshot-policy-mismatch expected=" ++ show expected ++ " actual=" ++ show actual

renderMaybeText :: Maybe Text -> String
renderMaybeText = maybe "unobservable" Text.unpack

renderMaybeNatural :: Maybe Natural -> String
renderMaybeNatural = maybe "unobservable" show

listItems :: Text -> Value -> Either Text [Value]
listItems label value = do
  objectValue <- valueObject label value
  requiredArrayField "items" objectValue

valueObject :: Text -> Value -> Either Text (KeyMap.KeyMap Value)
valueObject _ (Object objectValue) = Right objectValue
valueObject label _ = Left (label <> " must be a JSON object")

requiredField :: Text -> KeyMap.KeyMap Value -> Either Text Value
requiredField fieldName objectValue =
  case lookupField fieldName objectValue of
    Nothing -> Left ("missing required field " <> fieldName)
    Just value -> Right value

lookupField :: Text -> KeyMap.KeyMap Value -> Maybe Value
lookupField fieldName = KeyMap.lookup (Key.fromText fieldName)

requiredObjectField :: Text -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
requiredObjectField fieldName objectValue =
  requiredField fieldName objectValue >>= valueObject fieldName

optionalObjectField :: Text -> KeyMap.KeyMap Value -> Maybe (KeyMap.KeyMap Value)
optionalObjectField fieldName objectValue =
  case lookupField fieldName objectValue of
    Just (Object nested) -> Just nested
    _ -> Nothing

requiredArrayField :: Text -> KeyMap.KeyMap Value -> Either Text [Value]
requiredArrayField fieldName objectValue =
  case lookupField fieldName objectValue of
    Just (Array values) -> Right (Vector.toList values)
    Just _ -> Left ("field " <> fieldName <> " must be an array")
    Nothing -> Left ("missing required array field " <> fieldName)

optionalArrayField :: Text -> KeyMap.KeyMap Value -> Maybe [Value]
optionalArrayField fieldName objectValue =
  case lookupField fieldName objectValue of
    Just (Array values) -> Just (Vector.toList values)
    _ -> Nothing

requiredTextField :: Text -> KeyMap.KeyMap Value -> Either Text Text
requiredTextField fieldName objectValue =
  case lookupField fieldName objectValue of
    Just (String value) | not (Text.null value) -> Right value
    Just (String _) -> Left ("field " <> fieldName <> " must not be empty")
    Just _ -> Left ("field " <> fieldName <> " must be text")
    Nothing -> Left ("missing required text field " <> fieldName)

optionalTextField :: Text -> KeyMap.KeyMap Value -> Maybe Text
optionalTextField fieldName objectValue =
  case lookupField fieldName objectValue of
    Just (String value) -> Just value
    _ -> Nothing

findNamedObject
  :: Text
  -> [Value]
  -> Either Text (Maybe (KeyMap.KeyMap Value))
findNamedObject wantedName values = do
  objects <- traverse (valueObject "named list item") values
  let matching = filter ((== Just wantedName) . optionalTextField "name") objects
  case matching of
    [] -> Right Nothing
    [matched] -> Right (Just matched)
    _ -> Left ("duplicate named item: " <> wantedName)

valueNatural :: Value -> Either Text Natural
valueNatural value =
  case value of
    Number number ->
      case (Scientific.floatingOrInteger number :: Either Double Integer) of
        Right integer | integer >= 0 -> Right (fromInteger integer)
        _ -> Left "numeric value must be a non-negative integer"
    _ -> Left "value must be a JSON number"

memoryValueBytes :: Value -> Either Text Natural
memoryValueBytes value =
  case value of
    Number _ -> valueNatural value
    String quantity -> parseMemoryQuantity quantity
    _ -> Left "memory quantity must be text or a non-negative integer"

parseMemoryQuantity :: Text -> Either Text Natural
parseMemoryQuantity quantity = do
  let (numericText, suffix) = Text.span isQuantityNumberCharacter quantity
  if Text.null numericText
    then Left ("invalid memory quantity: " <> quantity)
    else do
      numeric <-
        case TextRead.rational numericText of
          Right (parsed, rest) | Text.null rest -> Right (parsed :: Rational)
          _ -> Left ("invalid memory quantity number: " <> quantity)
      multiplier <- quantityMultiplier suffix
      let bytes = numeric * multiplier
      if bytes < 0
        then Left ("memory quantity must not be negative: " <> quantity)
        else Right (fromInteger (ceiling bytes))

isQuantityNumberCharacter :: Char -> Bool
isQuantityNumberCharacter character =
  character `elem` ['0' .. '9'] || character `elem` ['.', '+', '-', 'e', 'E']

quantityMultiplier :: Text -> Either Text Rational
quantityMultiplier suffix =
  case suffix of
    "" -> Right 1
    "Ki" -> Right (1024 ^ (1 :: Int))
    "Mi" -> Right (1024 ^ (2 :: Int))
    "Gi" -> Right (1024 ^ (3 :: Int))
    "Ti" -> Right (1024 ^ (4 :: Int))
    "Pi" -> Right (1024 ^ (5 :: Int))
    "Ei" -> Right (1024 ^ (6 :: Int))
    "k" -> Right (1000 ^ (1 :: Int))
    "K" -> Right (1000 ^ (1 :: Int))
    "M" -> Right (1000 ^ (2 :: Int))
    "G" -> Right (1000 ^ (3 :: Int))
    "T" -> Right (1000 ^ (4 :: Int))
    "P" -> Right (1000 ^ (5 :: Int))
    "E" -> Right (1000 ^ (6 :: Int))
    "m" -> Right (1 / 1000)
    _ -> Left ("unsupported memory quantity suffix: " <> suffix)

requireUnique :: (Ord value) => Text -> [value] -> Either Text ()
requireUnique label values =
  if Set.size (Set.fromList values) == length values
    then Right ()
    else Left ("duplicate " <> label)

mapMaybeM :: (a -> Either err (Maybe b)) -> [a] -> Either err [b]
mapMaybeM action values = mapMaybe id <$> traverse action values

indexed :: Text -> Int -> Text
indexed label index = label <> "[" <> Text.pack (show index) <> "]"
