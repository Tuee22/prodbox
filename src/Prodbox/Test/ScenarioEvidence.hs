{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Compare an untrusted scenario report with observations supplied by the
-- outer runner. This module does not perform observations, authenticate their
-- producer, or establish that a real scenario ran.
module Prodbox.Test.ScenarioEvidence
  ( ScenarioBinding (..)
  , ScenarioBudget (..)
  , ScenarioTiming (..)
  , ScenarioPrimary (..)
  , ScenarioCleanup (..)
  , ObservationResult (..)
  , ScenarioObservation (..)
  , ScenarioReport (..)
  , IndependentScenarioObservation (..)
  , EvidenceComparison (..)
  , EvidenceComparisonError (..)
  , ScenarioReportCodecError (..)
  , ScenarioValidationError (..)
  , encodeScenarioReport
  , decodeScenarioReport
  , compareScenarioEvidence
  , validateScenarioReportBytes
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word64)
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (..)
  , DeploymentScope
  , scopeApiPort
  , scopeEnvironment
  , scopeIdentifier
  , scopeKindName
  , scopeKubeconfig
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, publicEvidenceDigestText)
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , SourceManifestPolicyIdentity (..)
  , WorktreeState (..)
  , gitHeadText
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )

-- Digests supplied here must cover public, non-secret projections only. The
-- clock epoch identifies the boot in which monotonic deadlines were measured;
-- the outer runner must independently observe and bind it.
data ScenarioBinding = ScenarioBinding
  { scenarioPhase :: !Word16
  , scenarioCase :: !Word16
  , scenarioScope :: !DeploymentScope
  , scenarioGeneration :: !String
  , scenarioRunId :: !String
  , scenarioOperationId :: !String
  , scenarioClockEpoch :: !String
  , scenarioSource :: !SourceIdentity
  , scenarioBinary :: !PublicEvidenceDigest
  , scenarioArtifacts :: ![(Text, PublicEvidenceDigest)]
  , scenarioPublicConfig :: !PublicEvidenceDigest
  , scenarioPublicCommand :: !PublicEvidenceDigest
  , scenarioBudget :: !ScenarioBudget
  }
  deriving stock (Eq, Show)

-- A zero spend limit is meaningful for an offline/local scenario. The
-- comparison binds these declared limits; it does not enforce them.
data ScenarioBudget = ScenarioBudget
  { primaryDeadlineNanos :: !Word64
  , cleanupDeadlineNanos :: !Word64
  , maximumMemoryBytes :: !Word64
  , maximumCpuMicros :: !Word64
  , maximumSpendMicroUsd :: !Word64
  }
  deriving stock (Eq, Show)

data ScenarioTiming = ScenarioTiming
  { scenarioStartedNanos :: !Word64
  , scenarioPrimaryFinishedNanos :: !Word64
  , scenarioCleanupFinishedNanos :: !Word64
  }
  deriving stock (Eq, Show)

data ScenarioPrimary = PrimarySucceeded | PrimaryFailed | PrimaryIncomplete
  deriving stock (Eq, Show)

data ScenarioCleanup = CleanupConfirmed | CleanupFailed | CleanupUnobservable
  deriving stock (Eq, Show)

data ObservationResult = ObservationSatisfied | ObservationViolated | ObservationUnavailable
  deriving stock (Eq, Show)

data ScenarioObservation = ScenarioObservation
  { scenarioObservationName :: !Text
  , scenarioObservationResult :: !ObservationResult
  }
  deriving stock (Eq, Show)

data ScenarioReport = ScenarioReport
  { reportBinding :: !ScenarioBinding
  , reportTiming :: !ScenarioTiming
  , reportPrimary :: !ScenarioPrimary
  , reportCleanup :: !ScenarioCleanup
  , reportObservations :: ![ScenarioObservation]
  }
  deriving stock (Eq, Show)

-- The caller must obtain these values independently of the report, from the
-- selected scope and actual execution. Constructing this value proves nothing.
data IndependentScenarioObservation = IndependentScenarioObservation
  { independentBinding :: !ScenarioBinding
  , independentTiming :: !ScenarioTiming
  , independentPrimary :: !ScenarioPrimary
  , independentCleanup :: !ScenarioCleanup
  , independentObservations :: ![ScenarioObservation]
  }
  deriving stock (Eq, Show)

data EvidenceComparison = EvidenceChecksSatisfied | EvidenceChecksUnmet
  deriving stock (Eq, Show)

data EvidenceComparisonError
  = EvidenceInvalidExpectedBinding
  | EvidenceInvalidRequirements
  | EvidenceReportMissing
  | EvidenceIndependentObservationMissing
  | EvidenceReportBindingMismatch
  | EvidenceIndependentBindingMismatch
  | EvidenceTimingMismatch
  | EvidenceTimingInvalid
  | EvidenceOutcomeMismatch
  | EvidenceObservationNamesInvalid
  | EvidenceObservationSetMismatch
  | EvidenceObservationMismatch
  deriving stock (Eq, Show)

data ScenarioReportCodecError
  = ScenarioReportInvalidBinding
  | ScenarioReportInvalidObservations
  | ScenarioReportTooLarge
  | ScenarioReportMalformed
  | ScenarioReportBindingMismatch
  deriving stock (Eq, Show)

data ScenarioValidationError
  = ScenarioValidationCodec !ScenarioReportCodecError
  | ScenarioValidationComparison !EvidenceComparisonError
  deriving stock (Eq, Show)

-- | Decode against the caller's expected binding and compare against the
-- separately supplied observation. This does not establish the observation's
-- authenticity, perform effects, or replace the real scenario runner.
validateScenarioReportBytes
  :: ScenarioBinding
  -> [Text]
  -> Maybe ByteString.ByteString
  -> Maybe IndependentScenarioObservation
  -> Either ScenarioValidationError EvidenceComparison
validateScenarioReportBytes expected required maybeBytes independent = do
  bytes <- maybe (Left (ScenarioValidationComparison EvidenceReportMissing)) Right maybeBytes
  report <- either (Left . ScenarioValidationCodec) Right (decodeScenarioReport expected bytes)
  either
    (Left . ScenarioValidationComparison)
    Right
    (compareScenarioEvidence expected required (Just report) independent)

-- | Encode only the structured public fields. Failure and incomplete outcomes
-- remain encodable so their records need not be replaced with success.
encodeScenarioReport :: ScenarioReport -> Either ScenarioReportCodecError ByteString.ByteString
encodeScenarioReport report = do
  require (validBinding (reportBinding report)) ScenarioReportInvalidBinding
  require (validReportObservations (reportObservations report)) ScenarioReportInvalidObservations
  let bytes = LazyByteString.toStrict (Aeson.encode (reportValue report))
  require (ByteString.length bytes <= maximumReportBytes) ScenarioReportTooLarge
  pure bytes

-- | Decode canonical bounded JSON against an independently chosen binding.
-- The report cannot construct or replace the trusted source/scope identity.
-- Comparison with fresh independent observations is a separate step.
decodeScenarioReport
  :: ScenarioBinding -> ByteString.ByteString -> Either ScenarioReportCodecError ScenarioReport
decodeScenarioReport expected bytes = do
  require (validBinding expected) ScenarioReportInvalidBinding
  require (ByteString.length bytes <= maximumReportBytes) ScenarioReportTooLarge
  value <- either (const (Left ScenarioReportMalformed)) Right (Aeson.eitherDecodeStrict' bytes)
  require (LazyByteString.toStrict (Aeson.encode value) == bytes) ScenarioReportMalformed
  (binding, timing, primary, cleanup, observed) <-
    either (const (Left ScenarioReportMalformed)) Right (parseEither parseReport value)
  require (binding == bindingValue expected) ScenarioReportBindingMismatch
  require (validReportObservations observed) ScenarioReportInvalidObservations
  pure (ScenarioReport expected timing primary cleanup observed)

-- An empty list records a run that produced no observation; comparison still
-- refuses it against a nonempty required set.
validReportObservations :: [ScenarioObservation] -> Bool
validReportObservations values = null values || either (const False) (const True) (observations values)

maximumReportBytes :: Int
maximumReportBytes = 65536

reportValue :: ScenarioReport -> Aeson.Value
reportValue report =
  Aeson.object
    [ "schema" Aeson..= (1 :: Int)
    , "binding" Aeson..= bindingValue (reportBinding report)
    , "timing" Aeson..= timingValue (reportTiming report)
    , "primary" Aeson..= primaryText (reportPrimary report)
    , "cleanup" Aeson..= cleanupText (reportCleanup report)
    , "observations" Aeson..= map observationValue (reportObservations report)
    ]

bindingValue :: ScenarioBinding -> Aeson.Value
bindingValue binding =
  Aeson.object
    [ "phase" Aeson..= scenarioPhase binding
    , "case" Aeson..= scenarioCase binding
    , "scope" Aeson..= scopeValue (scenarioScope binding)
    , "generation" Aeson..= scenarioGeneration binding
    , "run_id" Aeson..= scenarioRunId binding
    , "operation_id" Aeson..= scenarioOperationId binding
    , "clock_epoch" Aeson..= scenarioClockEpoch binding
    , "source" Aeson..= sourceValue (scenarioSource binding)
    , "binary" Aeson..= publicEvidenceDigestText (scenarioBinary binding)
    , "artifacts" Aeson..= map artifactValue (scenarioArtifacts binding)
    , "public_config" Aeson..= publicEvidenceDigestText (scenarioPublicConfig binding)
    , "public_command" Aeson..= publicEvidenceDigestText (scenarioPublicCommand binding)
    , "budget" Aeson..= budgetValue (scenarioBudget binding)
    ]
 where
  artifactValue (label, digest) = Aeson.object ["name" Aeson..= label, "digest" Aeson..= publicEvidenceDigestText digest]

scopeValue :: DeploymentScope -> Aeson.Value
scopeValue scope =
  Aeson.object
    [ "environment" Aeson..= case scopeEnvironment scope of Production -> ("production" :: Text); Test -> "test"
    , "deployment_id" Aeson..= scopeIdentifier scope
    , "root" Aeson..= scopeRoot scope
    , "kind_name" Aeson..= scopeKindName scope
    , "kubeconfig" Aeson..= scopeKubeconfig scope
    , "api_port" Aeson..= scopeApiPort scope
    ]

sourceValue :: SourceIdentity -> Aeson.Value
sourceValue source =
  Aeson.object
    [ "git_head" Aeson..= gitHeadText (sourceGitHead source)
    , "worktree" Aeson..= case sourceWorktreeState source of WorktreeClean -> ("clean" :: Text); WorktreeDirty -> "dirty"
    , "policy_id" Aeson..= sourcePolicyIdentifier policy
    , "policy_version" Aeson..= sourcePolicyVersion policy
    , "policy_digest" Aeson..= sourcePolicyDigest policy
    , "manifest_digest" Aeson..= sourceManifestDigest source
    , "entry_count" Aeson..= sourceManifestEntryCount source
    ]
 where
  policy = sourceManifestPolicyIdentity source

budgetValue :: ScenarioBudget -> Aeson.Value
budgetValue budget =
  Aeson.object
    [ "primary_deadline_nanos" Aeson..= primaryDeadlineNanos budget
    , "cleanup_deadline_nanos" Aeson..= cleanupDeadlineNanos budget
    , "memory_bytes" Aeson..= maximumMemoryBytes budget
    , "cpu_micros" Aeson..= maximumCpuMicros budget
    , "spend_micro_usd" Aeson..= maximumSpendMicroUsd budget
    ]

timingValue :: ScenarioTiming -> Aeson.Value
timingValue timing =
  Aeson.object
    [ "started_nanos" Aeson..= scenarioStartedNanos timing
    , "primary_finished_nanos" Aeson..= scenarioPrimaryFinishedNanos timing
    , "cleanup_finished_nanos" Aeson..= scenarioCleanupFinishedNanos timing
    ]

observationValue :: ScenarioObservation -> Aeson.Value
observationValue observed =
  Aeson.object
    [ "name" Aeson..= scenarioObservationName observed
    , "result" Aeson..= observationText (scenarioObservationResult observed)
    ]

primaryText :: ScenarioPrimary -> Text
primaryText value = case value of
  PrimarySucceeded -> "succeeded"
  PrimaryFailed -> "failed"
  PrimaryIncomplete -> "incomplete"

cleanupText :: ScenarioCleanup -> Text
cleanupText value = case value of
  CleanupConfirmed -> "confirmed"
  CleanupFailed -> "failed"
  CleanupUnobservable -> "unobservable"

observationText :: ObservationResult -> Text
observationText value = case value of
  ObservationSatisfied -> "satisfied"
  ObservationViolated -> "violated"
  ObservationUnavailable -> "unavailable"

parseReport
  :: Aeson.Value
  -> Parser (Aeson.Value, ScenarioTiming, ScenarioPrimary, ScenarioCleanup, [ScenarioObservation])
parseReport = Aeson.withObject "scenario report" $ \object -> do
  exactKeys ["schema", "binding", "timing", "primary", "cleanup", "observations"] object
  schema <- object .: "schema" :: Parser Int
  if schema /= 1 then fail "unsupported schema" else pure ()
  binding <- object .: "binding"
  timing <- object .: "timing" >>= parseTiming
  primary <- object .: "primary" >>= parsePrimary
  cleanup <- object .: "cleanup" >>= parseCleanup
  observed <- object .: "observations" >>= traverse parseObservation
  pure (binding, timing, primary, cleanup, observed)

parseTiming :: Aeson.Value -> Parser ScenarioTiming
parseTiming = Aeson.withObject "scenario timing" $ \object -> do
  exactKeys ["started_nanos", "primary_finished_nanos", "cleanup_finished_nanos"] object
  ScenarioTiming
    <$> object .: "started_nanos"
    <*> object .: "primary_finished_nanos"
    <*> object .: "cleanup_finished_nanos"

parsePrimary :: Text -> Parser ScenarioPrimary
parsePrimary value = case value of
  "succeeded" -> pure PrimarySucceeded
  "failed" -> pure PrimaryFailed
  "incomplete" -> pure PrimaryIncomplete
  _ -> fail "unknown primary outcome"

parseCleanup :: Text -> Parser ScenarioCleanup
parseCleanup value = case value of
  "confirmed" -> pure CleanupConfirmed
  "failed" -> pure CleanupFailed
  "unobservable" -> pure CleanupUnobservable
  _ -> fail "unknown cleanup outcome"

parseObservation :: Aeson.Value -> Parser ScenarioObservation
parseObservation = Aeson.withObject "scenario observation" $ \object -> do
  exactKeys ["name", "result"] object
  name <- object .: "name"
  result <- object .: "result" >>= parseObservationResult
  pure (ScenarioObservation name result)

parseObservationResult :: Text -> Parser ObservationResult
parseObservationResult value = case value of
  "satisfied" -> pure ObservationSatisfied
  "violated" -> pure ObservationViolated
  "unavailable" -> pure ObservationUnavailable
  _ -> fail "unknown observation result"

exactKeys :: [Text] -> Aeson.Object -> Parser ()
exactKeys expected object =
  if Set.fromList (map Key.toText (KeyMap.keys object)) == Set.fromList expected
    then pure ()
    else fail "unexpected object fields"

-- A satisfied comparison is only a match to the supplied independent
-- observation. Acceptance additionally requires a real runner and observers,
-- negative controls, exact resource coverage and terminal cleanup.
compareScenarioEvidence
  :: ScenarioBinding
  -> [Text]
  -> Maybe ScenarioReport
  -> Maybe IndependentScenarioObservation
  -> Either EvidenceComparisonError EvidenceComparison
compareScenarioEvidence expected required maybeReport maybeIndependent = do
  require (validBinding expected) EvidenceInvalidExpectedBinding
  requiredSet <- names required EvidenceInvalidRequirements
  report <- maybe (Left EvidenceReportMissing) Right maybeReport
  independent <- maybe (Left EvidenceIndependentObservationMissing) Right maybeIndependent
  require (reportBinding report == expected) EvidenceReportBindingMismatch
  require (independentBinding independent == expected) EvidenceIndependentBindingMismatch
  require
    (validTiming (reportTiming report) && validTiming (independentTiming independent))
    EvidenceTimingInvalid
  require (timingWithin (reportTiming report) (independentTiming independent)) EvidenceTimingMismatch
  require
    ( reportPrimary report == independentPrimary independent
        && reportCleanup report == independentCleanup independent
    )
    EvidenceOutcomeMismatch
  reported <- observations (reportObservations report)
  observed <- observations (independentObservations independent)
  require
    (Map.keysSet reported == requiredSet && Map.keysSet observed == requiredSet)
    EvidenceObservationSetMismatch
  require (reported == observed) EvidenceObservationMismatch
  pure $
    if independentPrimary independent == PrimarySucceeded
      && independentCleanup independent == CleanupConfirmed
      && all (== ObservationSatisfied) (Map.elems observed)
      && withinDeadlines expected (independentTiming independent)
      then EvidenceChecksSatisfied
      else EvidenceChecksUnmet

validBinding :: ScenarioBinding -> Bool
validBinding binding =
  scenarioPhase binding <= 10
    && scenarioCase binding > 0
    && validRootGeneration (scenarioGeneration binding)
    && validRootGeneration (scenarioRunId binding)
    && validRootGeneration (scenarioOperationId binding)
    && validRootGeneration (scenarioClockEpoch binding)
    && validArtifacts (scenarioArtifacts binding)
    && primaryDeadlineNanos budget > 0
    && cleanupDeadlineNanos budget > primaryDeadlineNanos budget
    && maximumMemoryBytes budget > 0
    && maximumCpuMicros budget > 0
 where
  budget = scenarioBudget binding

validArtifacts :: [(Text, PublicEvidenceDigest)] -> Bool
validArtifacts values =
  let bounded = take 65 values
      labels = map fst bounded
   in length bounded <= 64 && all validName labels && Set.size (Set.fromList labels) == length labels

validTiming :: ScenarioTiming -> Bool
validTiming timing =
  scenarioStartedNanos timing > 0
    && scenarioStartedNanos timing <= scenarioPrimaryFinishedNanos timing
    && scenarioPrimaryFinishedNanos timing <= scenarioCleanupFinishedNanos timing

-- A late observation is valid evidence of a missed budget, never a pass.
withinDeadlines :: ScenarioBinding -> ScenarioTiming -> Bool
withinDeadlines binding timing =
  scenarioPrimaryFinishedNanos timing <= primaryDeadlineNanos (scenarioBudget binding)
    && scenarioCleanupFinishedNanos timing <= cleanupDeadlineNanos (scenarioBudget binding)

-- The outer runner brackets the report; independently sampled timestamps do
-- not have to be identical to the timestamps recorded by the scenario.
timingWithin :: ScenarioTiming -> ScenarioTiming -> Bool
timingWithin reported outer =
  scenarioStartedNanos outer <= scenarioStartedNanos reported
    && scenarioPrimaryFinishedNanos reported <= scenarioPrimaryFinishedNanos outer
    && scenarioCleanupFinishedNanos reported <= scenarioCleanupFinishedNanos outer

names :: [Text] -> EvidenceComparisonError -> Either EvidenceComparisonError (Set.Set Text)
names values failure = do
  let bounded = take 257 values
      result = Set.fromList bounded
  require
    ( not (null bounded)
        && length bounded <= 256
        && all validName bounded
        && Set.size result == length bounded
    )
    failure
  pure result

observations
  :: [ScenarioObservation] -> Either EvidenceComparisonError (Map.Map Text ObservationResult)
observations values = do
  _ <- names (map scenarioObservationName values) EvidenceObservationNamesInvalid
  pure
    (Map.fromList [(scenarioObservationName value, scenarioObservationResult value) | value <- values])

validName :: Text -> Bool
validName value =
  not (Text.null value)
    && Text.length value <= 96
    && Text.all
      ( \character ->
          isAsciiLower character
            || (isDigit character && character <= '9')
            || character `elem` ("-_." :: String)
      )
      value

require :: Bool -> error -> Either error ()
require condition failure = if condition then Right () else Left failure
