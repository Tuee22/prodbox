{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Test.CounterexampleValidation
  ( runControlPlaneCounterexampleValidation
  )
where

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
import System.Exit (ExitCode (..))

runControlPlaneCounterexampleValidation :: FilePath -> IO ExitCode
runControlPlaneCounterexampleValidation repoRoot = do
  let receipt = mkAuthorityReceiptBinding "receipt-frozen-run-0001"
      generation = mkAuthorityGenerationBinding "generation-frozen-run-0001"
  case (receipt, generation) of
    (Right receiptBinding, Right generationBinding) -> do
      traceResult <-
        loadFrozenCounterexampleTrace repoRoot frozenExpectedImages [receiptBinding, generationBinding]
      case traceResult of
        Left err -> failWith ("frozen counterexample refused: " ++ show err)
        Right trace -> do
          replacementSourceResult <- captureSourceIdentity repoRoot []
          let (superseded, replacement) = simulateFrozenCounterexample trace
              complete =
                all ((== SupersededFailureObserved) . counterexampleResultDisposition) superseded
                  && all ((== ReplacementMechanismClosed) . counterexampleResultDisposition) replacement
                  && map counterexampleResultMechanism superseded
                    == map counterexampleResultMechanism replacement
          case replacementSourceResult of
            Left err -> failWith ("replacement source identity refused: " ++ show err)
            Right replacementSource ->
              case qualificationArtifact trace replacementSource receiptBinding superseded replacement of
                Left err -> failWith err
                Right evidence ->
                  case replacementTemporalProfile of
                    Left err -> failWith err
                    Right temporalProfile ->
                      emitEvidence trace superseded replacement evidence temporalProfile complete
    (Left err, _) -> failWith ("frozen receipt binding refused: " ++ show err)
    (_, Left err) -> failWith ("frozen generation binding refused: " ++ show err)

emitEvidence
  :: FrozenCounterexampleTrace
  -> [CounterexampleResult]
  -> [CounterexampleResult]
  -> QualificationEvidence
  -> TemporalReport
  -> Bool
  -> IO ExitCode
emitEvidence trace superseded replacement evidence temporalProfile complete =
  if complete && temporalReportQualified temporalProfile
    then do
      writeOutputLine ("COUNTEREXAMPLE=" ++ Text.unpack frozenCounterexampleId)
      writeOutputLine ("TRACE_DIGEST=" ++ Text.unpack (frozenTraceDigest trace))
      writeOutputLine ("SUPERSEDED_FAILURES=" ++ show (length superseded))
      writeOutputLine ("REPLACEMENT_CLOSURES=" ++ show (length replacement))
      writeOutputLine "NORMALIZED_ENVELOPE_EQUAL=true"
      writeOutputLine ("FAULT_MATRIX=" ++ show (length ([minBound .. maxBound] :: [TemporalFaultPoint])))
      writeOutputLine
        ("INVITE_FAULT_MATRIX=" ++ show (length ([minBound .. maxBound] :: [InviteFaultPoint])))
      writeOutputLine
        ("INVITE_ASSERTIONS=" ++ show (length ([minBound .. maxBound] :: [InviteAssertion])))
      writeOutputLine "TEMPORAL_REPLACEMENT_QUALIFIED=true"
      writeOutputLine ("DEPLOYMENT_QUALIFICATION=" ++ show QualificationPendingLiveEvidence)
      writeOutputLine ("QUALIFICATION_EVIDENCE_DIGEST=" ++ show (qualificationEvidenceDigest evidence))
      pure ExitSuccess
    else failWith "frozen and replacement counterexample result sets do not close exactly"

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
