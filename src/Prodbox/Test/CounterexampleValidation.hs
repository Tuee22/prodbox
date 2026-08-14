{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Test.CounterexampleValidation
  ( runControlPlaneCounterexampleValidation
  )
where

import Data.List (intercalate)
import Data.Text qualified as Text
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.Test.Qualification.Evidence
import Prodbox.Test.Qualification.FrozenCounterexample
import Prodbox.Test.Qualification.Invite
  ( CodeLocalQualificationStatus (QualificationPendingLiveEvidence)
  , InviteAssertion
  , InviteFaultPoint
  , canonicalInviteQualificationFixture
  )
import Prodbox.Test.Qualification.SourceIdentity (SourceIdentity, sourceManifestDigest)
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.TemporalQualification
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))

-- | Sprint 5.32: select the repository-owned frozen input. Unset selects the
-- canonical trace — the arm CI and a bare
-- @prodbox test integration control-plane-counterexample@ take — and it does the
-- real work: it reads the disposition file, captures the frozen source
-- identity from git, and pins the trace digest. The @mutated@ arm selects the
-- committed mutation fixture and must fail, which is the sprint's acceptance
-- criterion. An unrecognised value refuses rather than falling back to the
-- canonical fixture, because a typo that silently selected the passing arm is
-- exactly the shape Sprint 5.33 is removing elsewhere in this suite.
resolveFrozenTraceFixture :: IO (Either String FrozenTraceFixture)
resolveFrozenTraceFixture = do
  selector <- lookupEnv "PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE"
  pure $ case selector of
    Nothing -> Right CanonicalFrozenTrace
    Just "canonical" -> Right CanonicalFrozenTrace
    Just "mutated" -> Right MutatedFrozenTrace
    Just other ->
      Left
        ( "PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE="
            ++ other
            ++ " is not a known frozen fixture (expected `canonical` or `mutated`)."
        )

runControlPlaneCounterexampleValidation :: FilePath -> IO ExitCode
runControlPlaneCounterexampleValidation repoRoot = do
  let receipt = mkAuthorityReceiptBinding "receipt-frozen-run-0001"
      generation = mkAuthorityGenerationBinding "generation-frozen-run-0001"
  fixtureResult <- resolveFrozenTraceFixture
  case (fixtureResult, receipt, generation) of
    (Right fixture, Right receiptBinding, Right generationBinding) -> do
      traceResult <-
        loadFrozenCounterexampleTrace
          repoRoot
          fixture
          frozenExpectedImages
          [receiptBinding, generationBinding]
      case traceResult of
        Left err -> failWith ("frozen counterexample refused: " ++ show err)
        Right trace -> do
          replacementSourceResult <- captureSourceIdentity repoRoot []
          let (superseded, replacement) = simulateFrozenCounterexample trace
          case replacementSourceResult of
            Left err -> failWith ("replacement source identity refused: " ++ show err)
            Right replacementSource ->
              -- Sprint 5.32: the closure check runs FIRST, ahead of the
              -- evidence artifact. `mkQualificationEvidence` refuses the same
              -- class through `validateCounterexamples`, so with the artifact
              -- built first this fold could never be the gate that fires — the
              -- cannot-fail shape this sprint exists to remove, one layer up.
              -- Ordering it first makes it load-bearing and lets it name the
              -- offending mechanism; the artifact builder remains the second,
              -- independent gate over the same fact.
              case counterexampleClosureRefusal superseded replacement of
                Just err -> failWith err
                Nothing ->
                  case qualificationArtifact trace replacementSource receiptBinding superseded replacement of
                    Left err -> failWith err
                    Right evidence ->
                      case replacementTemporalProfile of
                        Left err -> failWith err
                        Right temporalProfile ->
                          emitEvidence trace superseded replacement evidence temporalProfile
    (Left err, _, _) -> failWith err
    (_, Left err, _) -> failWith ("frozen receipt binding refused: " ++ show err)
    (_, _, Left err) -> failWith ("frozen generation binding refused: " ++ show err)

-- | Sprint 5.32: @Just@ a refusal naming what did not close, @Nothing@ when the
-- two result sets close exactly. Standard P requires the frozen superseded
-- implementation to have *failed* on every mechanism the counterexample names
-- and the replacement to have closed every one of them.
counterexampleClosureRefusal
  :: [CounterexampleResult] -> [CounterexampleResult] -> Maybe String
counterexampleClosureRefusal superseded replacement
  | not (null supersededOffenders) =
      Just
        ( "the frozen superseded implementation is not recorded as failing on: "
            ++ intercalate ", " supersededOffenders
            ++ ". Standard P requires an expected failure against the frozen implementation "
            ++ "for every mechanism the counterexample names."
        )
  | not (null replacementOffenders) =
      Just
        ( "the replacement composition is not recorded as closing: "
            ++ intercalate ", " replacementOffenders
            ++ "."
        )
  | map counterexampleResultMechanism superseded
      /= map counterexampleResultMechanism replacement =
      Just "the frozen and replacement result sets name different mechanisms."
  | otherwise = Nothing
 where
  supersededOffenders = offenders SupersededFailureObserved superseded
  replacementOffenders = offenders ReplacementMechanismClosed replacement
  offenders expected results =
    [ show (counterexampleResultMechanism result)
        ++ "="
        ++ show (counterexampleResultDisposition result)
    | result <- results
    , counterexampleResultDisposition result /= expected
    ]

-- | Sprint 5.32: emit what was measured, then decide.
--
-- The evidence block used to sit inside the success branch, so every line it
-- printed was reachable only when the run had already closed — which is why
-- @NORMALIZED_ENVELOPE_EQUAL=true@ and @TEMPORAL_REPLACEMENT_QUALIFIED=true@
-- could be string literals without anyone noticing. Both are now rendered from
-- the values the verdict is computed from, and the block is emitted before the
-- verdict, so a failing run reports what it observed instead of only that it
-- did not close.
emitEvidence
  :: FrozenCounterexampleTrace
  -> [CounterexampleResult]
  -> [CounterexampleResult]
  -> QualificationEvidence
  -> TemporalReport
  -> IO ExitCode
emitEvidence trace superseded replacement evidence temporalProfile = do
  let envelopeEqual = frozenTraceNormalizedEnvelopeEqual trace
      temporalQualified = temporalReportQualified temporalProfile
  writeOutputLine ("COUNTEREXAMPLE=" ++ Text.unpack frozenCounterexampleId)
  writeOutputLine ("TRACE_DIGEST=" ++ Text.unpack (frozenTraceDigest trace))
  writeOutputLine
    ( "SUPERSEDED_FAILURES="
        ++ show
          (length (filter ((== SupersededFailureObserved) . counterexampleResultDisposition) superseded))
    )
  writeOutputLine
    ( "REPLACEMENT_CLOSURES="
        ++ show
          (length (filter ((== ReplacementMechanismClosed) . counterexampleResultDisposition) replacement))
    )
  writeOutputLine ("NORMALIZED_ENVELOPE_EQUAL=" ++ renderFlag envelopeEqual)
  writeOutputLine ("FAULT_MATRIX=" ++ show (length ([minBound .. maxBound] :: [TemporalFaultPoint])))
  writeOutputLine
    ("INVITE_FAULT_MATRIX=" ++ show (length ([minBound .. maxBound] :: [InviteFaultPoint])))
  writeOutputLine
    ("INVITE_ASSERTIONS=" ++ show (length ([minBound .. maxBound] :: [InviteAssertion])))
  writeOutputLine ("TEMPORAL_REPLACEMENT_QUALIFIED=" ++ renderFlag temporalQualified)
  writeOutputLine ("DEPLOYMENT_QUALIFICATION=" ++ show QualificationPendingLiveEvidence)
  writeOutputLine ("QUALIFICATION_EVIDENCE_DIGEST=" ++ show (qualificationEvidenceDigest evidence))
  -- Both flags are structurally true wherever this line is reached — the trace
  -- constructor refuses diverged envelope totals, and the temporal profile is a
  -- fixed in-module sample. The gate is kept anyway so the rendered values and
  -- the exit code cannot disagree: a change to either computation moves both.
  if envelopeEqual && temporalQualified
    then pure ExitSuccess
    else
      failWith
        ( "the counterexample profile did not qualify: NORMALIZED_ENVELOPE_EQUAL="
            ++ renderFlag envelopeEqual
            ++ " TEMPORAL_REPLACEMENT_QUALIFIED="
            ++ renderFlag temporalQualified
        )
 where
  renderFlag flag = if flag then "true" else "false"

replacementTemporalProfile :: Either String TemporalReport
replacementTemporalProfile = do
  policy <- either (Left . show) Right (mkTemporalPolicy 20000 8 100000 200000 300000 400000 500000 2)
  let sample =
        TemporalSample
          { temporalSampleService = "replacement-control-plane"
          , temporalSamplePodUid = "replacement-profile-pod"
          , temporalSampleThrottlePpm = Just 10000
          , temporalSampleQueueOccupancy = Just 2
          , temporalSampleQueueWaitMicros = Just 50000
          , temporalSampleServiceMicros = Just 100000
          , temporalSampleP95Micros = Just 200000
          , temporalSampleP99Micros = Just 300000
          , temporalSampleDeadlineMisses = Just 0
          , temporalSampleAdmissionRejections = Just 0
          , temporalSampleCancellationLagMicros = Just 250000
          , temporalSampleSessionRefreshFailures = Just 0
          , temporalSampleRestartDelta = Just 0
          , temporalSampleOomKilled = Just False
          , temporalSampleObservedAt = "replacement-profile"
          }
      observation = classifyTemporalSample policy sample
      first = foldTemporalObservation observation initialTemporalState
      second = foldTemporalObservation observation first
  Right (temporalReport policy second)

qualificationArtifact
  :: FrozenCounterexampleTrace
  -> SourceIdentity
  -> OpaqueFixtureBinding
  -> [CounterexampleResult]
  -> [CounterexampleResult]
  -> Either String QualificationEvidence
qualificationArtifact trace replacementSource receiptBinding superseded replacement = do
  frozenConfig <- digest frozenExpectedGeneratedConfigDigest
  frozenTopology <- digest frozenExpectedTopologyDigest
  frozenEnvelope <- digest frozenExpectedEnvelopeDigest
  frozenLoad <- digest frozenExpectedLoadFaultDigest
  replacementDigest <- digest (sourceManifestDigest replacementSource)
  invite <- either (Left . show) Right canonicalInviteQualificationFixture
  let frozenIdentity =
        QualificationIdentity
          (frozenTraceSourceIdentity trace)
          frozenConfig
          [frozenConfig, frozenTopology, frozenEnvelope, frozenLoad]
          frozenTopology
          frozenEnvelope
          frozenLoad
      replacementIdentity =
        QualificationIdentity
          replacementSource
          replacementDigest
          [replacementDigest, frozenTopology]
          replacementDigest
          frozenEnvelope
          frozenLoad
      input =
        QualificationEvidenceInput
          "home-local"
          ["prodbox test integration control-plane-counterexample"]
          frozenIdentity
          replacementIdentity
          frozenEnvelope
          superseded
          replacement
          runDeterministicTemporalFaultSchedule
          [receiptBinding]
          invite
          True
          True
          "causal-profile-start"
          "replacement-profile-complete"
  either (Left . show) Right (mkQualificationEvidence input)
 where
  digest value =
    maybe
      (Left ("invalid public evidence digest: " ++ Text.unpack value))
      Right
      (mkPublicEvidenceDigest value)

failWith :: String -> IO ExitCode
failWith message = writeDiagnosticLine message >> pure (ExitFailure 1)
