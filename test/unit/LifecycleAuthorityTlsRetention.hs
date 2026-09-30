{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityTlsRetention
  ( lifecycleAuthorityTlsRetentionSuite
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError (..)
  )
import Prodbox.ControlPlane.Client (ControlPlaneClientError (..))
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
import Prodbox.ControlPlane.TlsRetentionAuthorityClient
  ( TlsRetentionAuthorityClientError (..)
  , renderTlsRetentionAuthorityClientCause
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.Authority.TlsRetention
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import TestSupport

data LegacyTlsRetentionState
  = LegacyTlsRetentionEmpty
  | LegacyTlsRetentionCurrent !RetainedTlsRef
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyTlsSealedEnvelope
  = LegacyTlsSealedEnvelope
      !ByteString.ByteString
      !ByteString.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LegacyTlsAuthorityResponse
  = LegacyTlsAuthorityObserved !TlsRetentionState
  | LegacyTlsAuthorityPromotionApplied !TlsRetentionState
  | LegacyTlsAuthorityPromotionNoop !TlsRetentionState
  | LegacyTlsAuthorityPromotionRefused !Text
  | LegacyTlsAuthorityConcurrentWrite
  | LegacyTlsAuthorityUnavailable
  | LegacyTlsAuthorityRequestRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- The exact pre-terminal-replacement staging request.  Its generic encoding is
-- the byte-level rolling peer the production compatibility instance preserves.
data LegacyTlsAuthorityStageRequest
  = LegacyTlsAuthorityStageRequest
      !Text
      !Text
      !KeyRotationApproval
      !(Maybe TlsPendingCollisionRecovery)
      !RetainedTlsRef
      !TlsSealedEnvelope
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

lifecycleAuthorityTlsRetentionSuite :: SuiteBuilder ()
lifecycleAuthorityTlsRetentionSuite =
  describe "Sprint 4.48 Lifecycle Authority TLS-retention promotion/restore fold" $ do
    it
      "CASCADE-QUALIFICATION-TLS-AUTHORITY-CLIENT-CAUSE-DISCARDED-2026-09-24 retains one closed value-free client cause"
      $ do
        let transport = TlsRetentionAuthorityClientTransportFailed
            nestedTransport = transport . AuthenticatedClientTransportFailed
            nestedHttp = nestedTransport . ControlPlaneTransportFailed
            cases =
              [
                ( TlsRetentionAuthorityClientSlotInvalid
                    TlsRetentionSlotSubstrateInvalid
                , "slot/substrate-invalid"
                )
              ,
                ( TlsRetentionAuthorityClientSlotInvalid
                    TlsRetentionSlotScopeEmpty
                , "slot/scope-empty"
                )
              ,
                ( TlsRetentionAuthorityClientSlotInvalid
                    TlsRetentionSlotScopeContainsControl
                , "slot/scope-control"
                )
              ,
                ( TlsRetentionAuthorityClientSlotInvalid
                    TlsRetentionSlotScopeContainsWhitespace
                , "slot/scope-whitespace"
                )
              ,
                ( TlsRetentionAuthorityClientSlotInvalid
                    (TlsRetentionSlotScopeTooLong 999 1)
                , "slot/scope-too-long"
                )
              ,
                ( transport (AuthenticatedClientSignerUnavailable "secret signer detail")
                , "authenticated/signer-unavailable"
                )
              ,
                ( transport (AuthenticatedClientScopeUnavailable "secret scope detail")
                , "authenticated/scope-unavailable"
                )
              ,
                ( transport (AuthenticatedClientEpochUnavailable "secret epoch detail")
                , "authenticated/epoch-unavailable"
                )
              ,
                ( transport (AuthenticatedClientDeadlineUnavailable "secret deadline detail")
                , "authenticated/deadline-unavailable"
                )
              ,
                ( transport (AuthenticatedClientNonceUnavailable "secret nonce detail")
                , "authenticated/nonce-unavailable"
                )
              ,
                ( nestedTransport ControlPlaneEndpointEmpty
                , "authenticated/transport/endpoint-empty"
                )
              ,
                ( nestedTransport ControlPlaneEndpointContainsWhitespace
                , "authenticated/transport/endpoint-whitespace"
                )
              ,
                ( nestedTransport ControlPlaneEndpointContainsControl
                , "authenticated/transport/endpoint-control"
                )
              ,
                ( nestedTransport (ControlPlaneEndpointTooLong 999 1)
                , "authenticated/transport/endpoint-too-long"
                )
              ,
                ( nestedTransport ControlPlaneEndpointSchemeUnsupported
                , "authenticated/transport/endpoint-scheme-unsupported"
                )
              ,
                ( nestedTransport ControlPlaneEndpointAuthorityInvalid
                , "authenticated/transport/endpoint-authority-invalid"
                )
              ,
                ( nestedTransport ControlPlaneResponseLimitMustBePositive
                , "authenticated/transport/response-limit-invalid"
                )
              ,
                ( nestedHttp (HttpConnectionFailure "secret connection detail")
                , "authenticated/transport/http/connection-failed"
                )
              ,
                ( nestedHttp (HttpTimeout "secret timeout detail")
                , "authenticated/transport/http/timeout"
                )
              ,
                ( nestedHttp (HttpStatus 503 "secret status detail")
                , "authenticated/transport/http/status/server"
                )
              ,
                ( nestedHttp (HttpDecode "secret decode detail")
                , "authenticated/transport/http/decode-failed"
                )
              ,
                ( nestedTransport (ControlPlaneResponseTooLarge 999 1)
                , "authenticated/transport/response-too-large"
                )
              ,
                ( TlsRetentionAuthorityClientResponseInvalid
                    ControlPlaneRequestTooLarge
                , "response-codec/too-large"
                )
              ,
                ( TlsRetentionAuthorityClientResponseInvalid
                    ControlPlaneRequestInvalid
                , "response-codec/invalid"
                )
              ,
                ( TlsRetentionAuthorityClientResponseInvalid
                    ControlPlaneRequestUnsupportedVersion
                , "response-codec/unsupported-version"
                )
              ,
                ( TlsRetentionAuthorityClientResponseInvalid
                    ControlPlaneRequestNonCanonical
                , "response-codec/non-canonical"
                )
              ,
                ( TlsRetentionAuthorityClientHttpStatus 400
                , "response-status/bad-request"
                )
              ,
                ( TlsRetentionAuthorityClientHttpStatus 429
                , "response-status/too-many-requests"
                )
              ,
                ( TlsRetentionAuthorityClientHttpStatus 503
                , "response-status/server"
                )
              ,
                ( TlsRetentionAuthorityClientRemoteRefused "request-refused"
                , "remote-refusal/request-refused"
                )
              ,
                ( TlsRetentionAuthorityClientRemoteRefused "secret remote detail"
                , "remote-refusal/other"
                )
              ,
                ( TlsRetentionAuthorityClientUnavailable
                , "remote-unavailable"
                )
              ,
                ( TlsRetentionAuthorityClientConcurrentWrite
                , "remote-concurrent-write"
                )
              ,
                ( TlsRetentionAuthorityClientResponseShapeMismatch
                , "response-shape-mismatch"
                )
              ]
        forM_ cases $ \(failure, expected) ->
          renderTlsRetentionAuthorityClientCause failure `shouldBe` expected
    it
      "CASCADE-QUALIFICATION-TLS-AUTHORITY-REMOTE-REFUSAL-OTHER-2026-09-24 retains every endpoint-authored refusal and rejects arbitrary detail"
      $ do
        let authoredRefusals =
              [ "request-refused"
              , "source-not-reobserved"
              , "adapter-readback-mismatch"
              , "stale-version"
              , "validity-regression"
              , "unapproved-key-change"
              , "pending-missing"
              , "pending-mismatch"
              , "envelope-invalid"
              , "reference-invalid"
              , "digest-mismatch"
              , "version-mismatch"
              , "concurrent-pending"
              , "pending-collision-state-not-pending"
              , "pending-collision-concurrent-pending"
              , "pending-collision-evidence-invalid"
              , "pending-collision-envelope-invalid"
              , "pending-collision-reference-invalid"
              , "pending-collision-digest-mismatch"
              , "terminal-replacement-state-not-successor"
              , "terminal-replacement-concurrent-pending"
              , "terminal-replacement-evidence-invalid"
              , "terminal-replacement-evidence-invalid/malformed"
              , "terminal-replacement-evidence-invalid/version-lineage"
              , "terminal-replacement-evidence-invalid/digest-lineage"
              , "terminal-replacement-evidence-invalid/approval-lineage"
              , "terminal-replacement-evidence-invalid/certificate-lineage"
              , "terminal-replacement-evidence-invalid/source-lineage"
              , "terminal-replacement-evidence-invalid/source-uid-lineage"
              , "terminal-replacement-evidence-invalid/source-resource-version-lineage"
              , "terminal-replacement-evidence-invalid/recovery-disposition"
              , "terminal-replacement-envelope-invalid"
              , "terminal-replacement-reference-invalid"
              , "terminal-replacement-digest-mismatch"
              , "legacy-recovery-state-not-empty"
              , "legacy-recovery-concurrent-pending"
              , "legacy-recovery-evidence-invalid"
              , "legacy-recovery-envelope-invalid"
              , "legacy-recovery-reference-invalid"
              , "legacy-recovery-digest-mismatch"
              , "legacy-recovery-version-mismatch"
              , "legacy-recovery-collision-evidence-invalid"
              , "unopenable-successor-evidence-invalid"
              , "unopenable-successor-skipped-version-mismatch"
              , "unopenable-successor-skipped-digest-reused"
              , "unopenable-successor-envelope-invalid"
              , "unopenable-successor-reference-invalid"
              , "unopenable-successor-digest-mismatch"
              , "unopenable-successor-version-mismatch"
              , "unopenable-successor-state-not-current"
              , "unopenable-successor-concurrent-pending"
              , "unopenable-successor-validity-regression"
              , "unopenable-successor-unapproved-key-change"
              ]
        forM_ authoredRefusals $ \detail ->
          renderTlsRetentionAuthorityClientCause
            (TlsRetentionAuthorityClientRemoteRefused detail)
            `shouldBe` ("remote-refusal/" <> detail)
        renderTlsRetentionAuthorityClientCause
          (TlsRetentionAuthorityClientRemoteRefused "secret remote detail")
          `shouldBe` "remote-refusal/other"
    it
      "CASCADE-QUALIFICATION-TLS-AUTHORITY-REPOSITORY-CAUSE-DISCARDED-2026-09-24 retains one closed value-free repository cause"
      $ do
        diagnostics <- newIORef ([] :: [Text])
        let observeCases =
              [ (TlsRetentionAuthorityReadCorrupt, "read/corrupt")
              , (TlsRetentionAuthorityReadEndpointUnready, "read/endpoint-unready")
              , (TlsRetentionAuthorityReadUnobservable, "read/unobservable")
              ]
            writeCases =
              [ (TlsRetentionAuthorityWriteRefusedCorrupt, "write/refused-corrupt")
              , (TlsRetentionAuthorityWriteEndpointUnready, "write/endpoint-unready")
              , (TlsRetentionAuthorityWriteUnobservable, "write/unobservable")
              ]
            repositoryFor
              :: Either
                   TlsRetentionAuthorityReadFailure
                   (Maybe (StoredTlsRetentionState Int))
              -> Either TlsRetentionAuthorityWriteFailure Bool
              -> TlsRetentionAuthorityRepository IO Int
            repositoryFor readResult writeResult =
              diagnoseTlsRetentionAuthorityRepository
                (\diagnostic -> modifyIORef' diagnostics (<> [diagnostic]))
                TlsRetentionAuthorityRepository
                  { readTlsRetentionState = pure readResult
                  , compareAndSwapTlsRetentionState = \_ _ -> pure writeResult
                  }
        forM_ observeCases $ \(failure, expected) -> do
          writeIORef diagnostics []
          let repository =
                repositoryFor
                  (Left failure)
                  (Left TlsRetentionAuthorityWriteUnobservable)
          readTlsRetentionState repository
            `shouldReturn` Left failure
          readIORef diagnostics `shouldReturn` [expected]
        forM_ writeCases $ \(failure, expected) -> do
          writeIORef diagnostics []
          let repository = repositoryFor (Right Nothing) (Left failure)
          compareAndSwapTlsRetentionState repository Nothing initialTlsRetentionState
            `shouldReturn` Left failure
          readIORef diagnostics `shouldReturn` [expected]
    it "durably stages the first exact envelope before promotion" $ do
      let (staging, pending) =
            stepTlsStaging
              KeyRotationNotApproved
              initialTlsRetentionState
              ref1
              envelope1
      staging
        `shouldBe` TlsStaged
          ( TlsRetentionPending
              Nothing
              KeyRotationNotApproved
              ref1
              envelope1
          )
      currentRetainedRef pending `shouldBe` Nothing
      pendingTlsRetention pending `shouldSatisfy` isJust
      let (promotion, committed) =
            stepTlsPromotion KeyRotationNotApproved goodEvidence pending ref1
      promotion `shouldBe` TlsPromoted ref1
      committed `shouldBe` TlsRetentionCurrent ref1

    it "replays the exact pending bytes as a no-op and refuses divergent pending intent" $ do
      decideTlsStaging KeyRotationNotApproved pending1 ref1 envelope1
        `shouldBe` TlsStagingNoop pendingRecord1
      decideTlsStaging KeyRotationNotApproved pending1 ref1Alternate envelope1Alternate
        `shouldBe` TlsStagingRefused TlsStageConcurrentPending

    it "rebases an ordinary pending only onto its exact authenticated collision occupant" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              pending2
              ordinaryCollisionAdoption
              ref2Collision
              envelope2Collision
          state = applyTlsPendingCollisionStaging decision pending2
      decision
        `shouldBe` TlsPendingCollisionRebased
          ordinaryCollisionAdoption
          ordinaryDisplacedIdentityRecord
          ordinaryCollisionPendingRecord
      state `shouldBe` ordinaryCollisionRebasedState
      currentRetainedRef state `shouldBe` Just ref1
      pendingTlsRetention state `shouldBe` Just ordinaryCollisionPendingRecord
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        ordinaryCollisionAdoption
        ref2Collision
        envelope2Collision
        `shouldBe` TlsPendingCollisionStagingNoop ordinaryCollisionPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref2Collision
        `shouldBe` TlsPromoted ref2Collision

    it "steps an ordinary pending past one proven-unopenable collision and no farther" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              pending2
              ordinaryCollisionSuccessor
              ref3Recovery
              envelope3Recovery
          state = applyTlsPendingCollisionStaging decision pending2
      decision
        `shouldBe` TlsPendingCollisionSuccessorStaged
          ordinaryCollisionSuccessor
          ordinaryDisplacedIdentityRecord
          ordinaryCollisionSuccessorPendingRecord
      state `shouldBe` ordinaryCollisionSuccessorState
      currentRetainedRef state `shouldBe` Just ref1
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref3Recovery
        `shouldBe` TlsPromoted ref3Recovery
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        ordinaryCollisionSuccessor
        (ref3Recovery {retainedVersion = RetentionVersion 4})
        envelope3Recovery
        `shouldBe` TlsPendingCollisionStagingRefused TlsPendingCollisionStageConcurrentPending

    it "rebases the current-backed bounded successor only at its exact version" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              ordinaryCollisionSuccessorState
              recoverySuccessorCollisionAdoption
              ref3Collision
              envelope3Collision
          state = applyTlsPendingCollisionStaging decision ordinaryCollisionSuccessorState
      decision
        `shouldBe` TlsPendingCollisionBoundedSuccessorRebased
          ordinaryCollisionSuccessor
          ordinaryDisplacedIdentityRecord
          recoverySuccessorCollisionAdoption
          ordinarySuccessorDisplacedIdentity
          ordinarySuccessorCollisionPendingRecord
      state `shouldBe` ordinarySuccessorCollisionRebasedState
      currentRetainedRef state `shouldBe` Just ref1
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        recoverySuccessorCollisionAdoption
        ref3Collision
        envelope3Collision
        `shouldBe` TlsPendingCollisionStagingNoop ordinarySuccessorCollisionPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref3Collision
        `shouldBe` TlsPromoted ref3Collision

    it "refuses a second skip from the current-backed bounded successor" $ do
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        ordinaryCollisionSuccessorState
        ( recoverySuccessorCollisionAdoption
            { tlsPendingCollisionDisposition = TlsPendingCollisionStepPastUnopenable
            }
        )
        (ref3Collision {retainedVersion = RetentionVersion 4})
        envelope3Collision
        `shouldBe` TlsPendingCollisionStagingRefused TlsPendingCollisionStageEvidenceInvalid

    it "rebases an already-skipped successor only onto its authenticated exact occupant" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              unopenableSuccessorPending4
              unopenableSuccessorCollisionAdoption
              ref4Collision
              envelope4Collision
          state = applyTlsPendingCollisionStaging decision unopenableSuccessorPending4
      decision
        `shouldBe` TlsPendingCollisionUnopenableSuccessorRebased
          unopenableEvidence3
          unopenableSuccessorCollisionAdoption
          unopenableSuccessorDisplacedIdentity
          unopenableSuccessorCollisionPendingRecord
      state `shouldBe` unopenableSuccessorCollisionRebasedState
      currentRetainedRef state `shouldBe` Just ref2
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        unopenableSuccessorCollisionAdoption
        ref4Collision
        envelope4Collision
        `shouldBe` TlsPendingCollisionStagingNoop unopenableSuccessorCollisionPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref4Collision
        `shouldBe` TlsPromoted ref4Collision

    it "never admits a second skip from an already-skipped successor collision" $ do
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        unopenableSuccessorPending4
        ( unopenableSuccessorCollisionAdoption
            { tlsPendingCollisionDisposition = TlsPendingCollisionStepPastUnopenable
            }
        )
        (ref4Collision {retainedVersion = RetentionVersion 5})
        envelope4Collision
        `shouldBe` TlsPendingCollisionStagingRefused TlsPendingCollisionStageEvidenceInvalid

    it "stages an unopenable pre-outbox version and its fresh successor in one CAS-safe state" $ do
      let decision =
            decideTlsLegacyRecoveryStaging
              KeyRotationNotApproved
              initialTlsRetentionState
              legacyRecoveryEvidence
              Nothing
              ref2
              envelope2
          state =
            applyTlsLegacyRecoveryStaging
              legacyRecoveryEvidence
              decision
              initialTlsRetentionState
      decision `shouldBe` TlsLegacyRecoveryStaged recoveryPendingRecord
      state `shouldBe` recoveryPending2
      currentRetainedRef state `shouldBe` Nothing
      pendingTlsRetention state `shouldBe` Just recoveryPendingRecord
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        state
        legacyRecoveryEvidence
        Nothing
        ref2
        envelope2
        `shouldBe` TlsLegacyRecoveryStagingNoop recoveryPendingRecord
      decideTlsRestore state RestoreCommittedAbsent
        `shouldBe` TlsRestoreRefused TlsRestoreRecoveryPending
      decideTlsTerminalReplacementStaging
        KeyRotationNotApproved
        recoveryTerminalState
        recoveryTerminalEvidence
        terminalReplacementEvidence
        ref4Successor
        envelope4Successor
        `shouldBe` TlsTerminalReplacementStaged
          legacyRecoveryEvidence
          recoverySuccessorEvidence
          recoveryTerminalEvidence
          recoverySuccessorDisplacedIdentity
          terminalReplacementEvidence
          recoveryTerminalPendingRecord
      decideTlsTerminalReplacementStaging
        KeyRotationNotApproved
        recoverySuccessorPending3
        recoveryTerminalEvidence
        (terminalReplacementEvidence {tlsTerminalReplacementVersion = RetentionVersion 5})
        (ref4Replacement {retainedVersion = RetentionVersion 5})
        envelope4Replacement
        `shouldBe` TlsTerminalReplacementStagingRefused
          ( TlsTerminalReplacementStageEvidenceInvalid
              TlsTerminalReplacementVersionLineageInvalid
          )
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref2
        `shouldBe` TlsPromoted ref2

    it
      "CASCADE-QUALIFICATION-TLS-TERMINAL-REPLACEMENT-EVIDENCE-INVALID-2026-09-24 distinguishes every closed evidence-invariant family"
      $ do
        let decideFrom state approval recovery terminalEvidence candidate =
              decideTlsTerminalReplacementStaging
                approval
                state
                recovery
                terminalEvidence
                candidate
                envelope4Replacement
            decide = decideFrom recoverySuccessorPending3
            expectCauseFrom state approval recovery terminalEvidence candidate cause =
              decideFrom state approval recovery terminalEvidence candidate
                `shouldBe` TlsTerminalReplacementStagingRefused
                  (TlsTerminalReplacementStageEvidenceInvalid cause)
            expectCause approval recovery terminalEvidence candidate cause =
              decide approval recovery terminalEvidence candidate
                `shouldBe` TlsTerminalReplacementStagingRefused
                  (TlsTerminalReplacementStageEvidenceInvalid cause)
        expectCause
          KeyRotationNotApproved
          recoveryTerminalEvidence
          ( terminalReplacementEvidence
              { tlsTerminalReplacementOccupantEnvelopeDigest = "not-a-digest"
              }
          )
          ref4Replacement
          TlsTerminalReplacementEvidenceMalformed
        expectCause
          KeyRotationNotApproved
          recoveryTerminalEvidence
          (terminalReplacementEvidence {tlsTerminalReplacementVersion = RetentionVersion 5})
          ref4Replacement
          TlsTerminalReplacementVersionLineageInvalid
        expectCause
          KeyRotationNotApproved
          ( recoveryTerminalEvidence
              { tlsPendingCollisionObservedEnvelopeDigest =
                  tlsPendingCollisionDisplacedEnvelopeDigest recoveryTerminalEvidence
              }
          )
          terminalReplacementEvidence
          ref4Replacement
          TlsTerminalReplacementDigestLineageInvalid
        expectCause
          KeyRotationApproved
          recoveryTerminalEvidence
          terminalReplacementEvidence
          ref4Replacement
          TlsTerminalReplacementApprovalLineageInvalid
        expectCause
          KeyRotationNotApproved
          recoveryTerminalEvidence
          terminalReplacementEvidence
          (ref4Replacement {retainedCert = CertIdentity "other" "spki-A" 2000})
          TlsTerminalReplacementCertificateLineageInvalid
        expectCause
          KeyRotationNotApproved
          recoveryTerminalEvidence
          terminalReplacementEvidence
          (ref4Replacement {retainedSourceSecret = SourceSecretRef "uid-other" "rv-1"})
          TlsTerminalReplacementSourceUidLineageInvalid
        let priorResourceVersionCandidate =
              ref3Recovery
                { retainedSourceSecret = SourceSecretRef "uid-1" "rv-prior-drift"
                }
            priorResourceVersionState =
              TlsRetentionLegacyRecoverySuccessorPendingState
                legacyRecoveryEvidence
                recoverySuccessorEvidence
                ( recoverySuccessorPendingRecord
                    { tlsPendingCandidate = priorResourceVersionCandidate
                    }
                )
        expectCauseFrom
          priorResourceVersionState
          KeyRotationNotApproved
          recoveryTerminalEvidence
          terminalReplacementEvidence
          (ref4Replacement {retainedSourceSecret = SourceSecretRef "uid-1" "rv-terminal"})
          TlsTerminalReplacementSourceResourceVersionLineageInvalid
        expectCause
          KeyRotationNotApproved
          ( recoveryTerminalEvidence
              { tlsPendingCollisionDisposition = TlsPendingCollisionAdoptObserved
              }
          )
          terminalReplacementEvidence
          ref4Replacement
          TlsTerminalReplacementRecoveryDispositionInvalid

    it "durably rebases only an exact immutable recovery collision and still refuses restore" $ do
      let decision =
            decideTlsLegacyRecoveryStaging
              KeyRotationNotApproved
              recoveryPending2
              legacyRecoveryEvidence
              (Just recoveryCollisionEvidence)
              ref2Collision
              envelope2Collision
          state =
            applyTlsLegacyRecoveryStaging
              legacyRecoveryEvidence
              decision
              recoveryPending2
      decision
        `shouldBe` TlsLegacyRecoveryCollisionRebased
          recoveryCollisionEvidence
          recoveryCollisionPendingRecord
      state `shouldBe` recoveryCollisionPending2
      currentRetainedRef state `shouldBe` Nothing
      pendingTlsRetention state `shouldBe` Just recoveryCollisionPendingRecord
      decideTlsRestore state RestoreCommittedAbsent
        `shouldBe` TlsRestoreRefused TlsRestoreRecoveryPending
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref2Collision
        `shouldBe` TlsPromoted ref2Collision
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        state
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        ref2Collision
        envelope2Collision
        `shouldBe` TlsLegacyRecoveryStagingNoop recoveryCollisionPendingRecord

    it
      "TLS-LEGACY-RECOVERY-V2-COLLISION-CIPHERTEXT-AUTHENTICATION-FAILED-2026-09-08 stages only one fixed successor"
      $ do
        let decision =
              decideTlsLegacyRecoveryStaging
                KeyRotationNotApproved
                recoveryPending2
                legacyRecoveryEvidence
                (Just recoveryCollisionEvidence)
                ref3Recovery
                envelope3Recovery
            state =
              applyTlsLegacyRecoveryStaging
                legacyRecoveryEvidence
                decision
                recoveryPending2
        decision
          `shouldBe` TlsLegacyRecoveryCollisionSuccessorStaged
            recoverySuccessorEvidence
            recoverySuccessorPendingRecord
        state `shouldBe` recoverySuccessorPending3
        currentRetainedRef state `shouldBe` Nothing
        pendingTlsRetention state `shouldBe` Just recoverySuccessorPendingRecord
        decideTlsRestore state RestoreCommittedAbsent
          `shouldBe` TlsRestoreRefused TlsRestoreRecoveryPending
        decideTlsPromotion KeyRotationNotApproved goodEvidence state ref3Recovery
          `shouldBe` TlsPromoted ref3Recovery
        decideTlsLegacyRecoveryStaging
          KeyRotationNotApproved
          state
          legacyRecoveryEvidence
          (Just recoveryCollisionEvidence)
          ref3Recovery
          envelope3Recovery
          `shouldBe` TlsLegacyRecoveryStagingNoop recoverySuccessorPendingRecord

    it "rebases the fixed legacy-recovery successor only at version 3" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              recoverySuccessorPending3
              recoverySuccessorCollisionAdoption
              ref3Collision
              envelope3Collision
          state = applyTlsPendingCollisionStaging decision recoverySuccessorPending3
      decision
        `shouldBe` TlsPendingCollisionLegacyRecoverySuccessorRebased
          legacyRecoveryEvidence
          recoverySuccessorEvidence
          recoverySuccessorCollisionAdoption
          recoverySuccessorDisplacedIdentity
          recoverySuccessorCollisionPendingRecord
      state `shouldBe` recoverySuccessorCollisionRebasedState
      currentRetainedRef state `shouldBe` Nothing
      pendingTlsRetention state `shouldBe` Just recoverySuccessorCollisionPendingRecord
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        recoverySuccessorCollisionAdoption
        ref3Collision
        envelope3Collision
        `shouldBe` TlsPendingCollisionStagingNoop recoverySuccessorCollisionPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref3Collision
        `shouldBe` TlsPromoted ref3Collision
      mapM_
        ( \forged ->
            encodeModelBValue tlsRetentionStateCodec forged `shouldSatisfy` isLeft
        )
        [ TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
            legacyRecoveryEvidence
            recoverySuccessorEvidence
            ( recoverySuccessorCollisionAdoption
                { tlsPendingCollisionVersion = RetentionVersion 4
                }
            )
            recoverySuccessorDisplacedIdentity
            recoverySuccessorCollisionPendingRecord
        , TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
            legacyRecoveryEvidence
            recoverySuccessorEvidence
            recoverySuccessorCollisionAdoption
            ( recoverySuccessorDisplacedIdentity
                { tlsDisplacedPendingPrevious = Just ref2
                }
            )
            recoverySuccessorCollisionPendingRecord
        ]

    it "stages the fixed terminal version 4 after the exact legacy v1/v2/v3 chain" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              recoverySuccessorPending3
              recoveryTerminalEvidence
              ref4Successor
              envelope4Successor
          state = applyTlsPendingCollisionStaging decision recoverySuccessorPending3
      decision
        `shouldBe` TlsPendingCollisionLegacyRecoveryTerminalSuccessorStaged
          legacyRecoveryEvidence
          recoverySuccessorEvidence
          recoveryTerminalEvidence
          recoverySuccessorDisplacedIdentity
          recoveryTerminalPendingRecord
      state `shouldBe` recoveryTerminalState
      currentRetainedRef state `shouldBe` Nothing
      pendingTlsRetention state `shouldBe` Just recoveryTerminalPendingRecord
      decideTlsRestore state RestoreCommittedAbsent
        `shouldBe` TlsRestoreRefused TlsRestoreRecoveryPending
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        recoveryTerminalEvidence
        ref4Successor
        envelope4Successor
        `shouldBe` TlsPendingCollisionStagingNoop recoveryTerminalPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref4Successor
        `shouldBe` TlsPromoted ref4Successor

    it "rebases the terminal legacy-recovery successor only at version 4" $ do
      let decision =
            decideTlsPendingCollisionStaging
              KeyRotationNotApproved
              recoveryTerminalState
              recoveryTerminalCollisionAdoption
              ref4Collision
              envelope4Collision
          state = applyTlsPendingCollisionStaging decision recoveryTerminalState
      decision
        `shouldBe` TlsPendingCollisionLegacyRecoveryTerminalSuccessorRebased
          legacyRecoveryEvidence
          recoverySuccessorEvidence
          recoveryTerminalEvidence
          recoverySuccessorDisplacedIdentity
          recoveryTerminalCollisionAdoption
          recoveryTerminalDisplacedIdentity
          recoveryTerminalCollisionPendingRecord
      state `shouldBe` recoveryTerminalCollisionRebasedState
      currentRetainedRef state `shouldBe` Nothing
      pendingTlsRetention state `shouldBe` Just recoveryTerminalCollisionPendingRecord
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        state
        recoveryTerminalCollisionAdoption
        ref4Collision
        envelope4Collision
        `shouldBe` TlsPendingCollisionStagingNoop recoveryTerminalCollisionPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref4Collision
        `shouldBe` TlsPromoted ref4Collision

    it "refuses a recursive successor after terminal legacy-recovery version 4" $ do
      decideTlsPendingCollisionStaging
        KeyRotationNotApproved
        recoveryTerminalState
        ( recoveryTerminalCollisionAdoption
            { tlsPendingCollisionDisposition = TlsPendingCollisionStepPastUnopenable
            }
        )
        (ref4Collision {retainedVersion = RetentionVersion 5})
        envelope4Collision
        `shouldBe` TlsPendingCollisionStagingRefused TlsPendingCollisionStageEvidenceInvalid
      mapM_
        ( \forged ->
            encodeModelBValue tlsRetentionStateCodec forged `shouldSatisfy` isLeft
        )
        [ TlsRetentionLegacyRecoveryTerminalSuccessorState
            legacyRecoveryEvidence
            recoverySuccessorEvidence
            recoveryTerminalEvidence
            recoverySuccessorDisplacedIdentity
            ( recoveryTerminalPendingRecord
                { tlsPendingCandidate = ref4Successor {retainedVersion = RetentionVersion 5}
                }
            )
        , TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
            legacyRecoveryEvidence
            recoverySuccessorEvidence
            recoveryTerminalEvidence
            recoverySuccessorDisplacedIdentity
            recoveryTerminalCollisionAdoption
            recoveryTerminalDisplacedIdentity
            ( recoveryTerminalCollisionPendingRecord
                { tlsPendingCandidate =
                    ref4Collision
                      { retainedSourceSecret = SourceSecretRef "forged" "source"
                      }
                }
            )
        ]

    it "refuses forged successor metadata and any recovery advance beyond version 3" $ do
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoveryPending2
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        (ref3Recovery {retainedSourceSecret = SourceSecretRef "different" "source"})
        envelope3Recovery
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageCollisionEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationApproved
        recoveryPending2
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        ref3Recovery
        envelope3Recovery
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageCollisionEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoverySuccessorPending3
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        (ref3Recovery {retainedVersion = RetentionVersion 4})
        envelope3Recovery
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageVersionMismatch
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoveryCollisionPending2
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        ref3Recovery
        envelope3Recovery
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageConcurrentPending
      encodeModelBValue
        tlsRetentionStateCodec
        ( TlsRetentionLegacyRecoverySuccessorPendingState
            legacyRecoveryEvidence
            ( recoverySuccessorEvidence
                { tlsLegacyRecoveryDisplacedCandidate =
                    ref2 {retainedSourceSecret = SourceSecretRef "forged" "source"}
                }
            )
            recoverySuccessorPendingRecord
        )
        `shouldSatisfy` isLeft

    it "refuses unproved or metadata-changing recovery collision rebases" $ do
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoveryPending2
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence {tlsLegacyRecoveryPendingEnvelopeDigest = "wrong"})
        ref2Collision
        envelope2Collision
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageCollisionEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoveryPending2
        legacyRecoveryEvidence
        (Just recoveryCollisionEvidence)
        (ref2Collision {retainedSourceSecret = SourceSecretRef "different" "source"})
        envelope2Collision
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageCollisionEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        recoveryPending2
        legacyRecoveryEvidence
        Nothing
        ref2Collision
        envelope2Collision
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageConcurrentPending

    it "refuses every unbound legacy-recovery staging variant" $ do
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        initialTlsRetentionState
        legacyRecoveryEvidence {tlsLegacyRecoveryEnvelopeDigest = "wrong"}
        Nothing
        ref2
        envelope2
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        initialTlsRetentionState
        legacyRecoveryEvidence {tlsLegacyRecoveryVersion = RetentionVersion 2}
        Nothing
        ref2
        envelope2
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageEvidenceInvalid
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        initialTlsRetentionState
        legacyRecoveryEvidence
        Nothing
        ref1
        envelope1
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageVersionMismatch
      decideTlsLegacyRecoveryStaging
        KeyRotationNotApproved
        current1
        legacyRecoveryEvidence
        Nothing
        ref2
        envelope2
        `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageStateNotEmpty

    it "refuses a digest or version mismatch before staging" $ do
      decideTlsStaging
        KeyRotationNotApproved
        initialTlsRetentionState
        ref1 {retainedCiphertextDigest = "wrong"}
        envelope1
        `shouldBe` TlsStagingRefused TlsStageDigestMismatch
      decideTlsStaging KeyRotationNotApproved current1 ref1 envelope1
        `shouldBe` TlsStagingRefused TlsStageVersionMismatch
      decideTlsStaging
        KeyRotationNotApproved
        initialTlsRetentionState
        ref1 {retainedSourceSecret = SourceSecretRef "" "rv-1"}
        envelope1
        `shouldBe` TlsStagingRefused TlsStageReferenceInvalid

    it "fails closed without source re-observation or adapter read-back" $ do
      decideTlsPromotion
        KeyRotationNotApproved
        (PromotionEvidence False True)
        pending1
        ref1
        `shouldBe` TlsPromotionRefused TlsSourceNotReobserved
      decideTlsPromotion
        KeyRotationNotApproved
        (PromotionEvidence True False)
        pending1
        ref1
        `shouldBe` TlsPromotionRefused TlsAdapterReadBackMismatch

    it "promotes a strictly-newer, staged, non-regressing, same-key candidate" $
      decideTlsPromotion KeyRotationNotApproved goodEvidence pending2 ref2
        `shouldBe` TlsPromoted ref2

    it "refuses a forged out-of-order pending candidate as stale" $
      decideTlsPromotion KeyRotationNotApproved goodEvidence forgedStalePending ref1
        `shouldBe` TlsPromotionRefused TlsStaleVersion

    it
      "requires pending for a new version but preserves exact-current response-loss recovery"
      $ do
        decideTlsPromotion KeyRotationNotApproved goodEvidence current1 ref2
          `shouldBe` TlsPromotionRefused TlsPendingMissing
        decideTlsPromotion KeyRotationNotApproved goodEvidence current1 ref1
          `shouldBe` TlsPromotionNoop ref1
        decideTlsPromotion
          KeyRotationNotApproved
          goodEvidence
          current1
          ref1 {retainedCiphertextDigest = "ct-divergent"}
          `shouldBe` TlsPromotionRefused TlsStaleVersion
        decideTlsPromotion
          KeyRotationNotApproved
          goodEvidence
          current1
          ref1 {retainedSourceSecret = SourceSecretRef "uid-other" "rv-other"}
          `shouldBe` TlsPromotionRefused TlsStaleVersion

    it "refuses a certificate validity regression before the immutable effect" $
      decideTlsStaging KeyRotationNotApproved current2 refRegress envelopeRegress
        `shouldBe` TlsStagingRefused TlsStageValidityRegression

    it "refuses an unapproved key change before effect and promotes the approved staged change" $ do
      decideTlsStaging KeyRotationNotApproved current1 refKeyChange envelopeKeyChange
        `shouldBe` TlsStagingRefused TlsStageUnapprovedKeyChange
      let approvedPending =
            applyTlsStaging
              (decideTlsStaging KeyRotationApproved current1 refKeyChange envelopeKeyChange)
              current1
      decideTlsPromotion KeyRotationApproved goodEvidence approvedPending refKeyChange
        `shouldBe` TlsPromoted refKeyChange

    it "requires the exact staged candidate and approval at promotion" $ do
      decideTlsPromotion KeyRotationNotApproved goodEvidence pending1 ref1Alternate
        `shouldBe` TlsPromotionRefused TlsPendingMismatch
      decideTlsPromotion KeyRotationApproved goodEvidence pending1 ref1
        `shouldBe` TlsPromotionRefused TlsPendingMismatch

    it "restores the exact committed reference on an intact read-back, and rejects a mismatched one" $ do
      decideTlsRestore current1 (RestoreCommittedIntact ref1) `shouldBe` TlsRestoreApply ref1
      decideTlsRestore current1 (RestoreCommittedIntact ref2)
        `shouldBe` TlsRestoreRefused TlsRestoreReferenceMismatch
      decideTlsRestore initialTlsRetentionState (RestoreCommittedIntact ref1)
        `shouldBe` TlsRestoreRefused TlsRestoreReferenceMismatch

    it "keeps the previous committed reference restorable while a successor is pending" $ do
      currentRetainedRef pending2 `shouldBe` Just ref1
      decideTlsRestore pending2 (RestoreCommittedIntact ref1)
        `shouldBe` TlsRestoreApply ref1
      decideTlsRestore pending2 (RestoreCommittedIntact ref2)
        `shouldBe` TlsRestoreRefused TlsRestoreReferenceMismatch

    it "permits issuance only on positive absence or trusted-time expiry" $ do
      decideTlsRestore current1 RestoreCommittedAbsent `shouldBe` TlsRestoreIssue
      decideTlsRestore current1 RestoreTrustedTimeExpired `shouldBe` TlsRestoreIssue

    it "fails closed on corrupt or unobservable committed state" $ do
      decideTlsRestore current1 RestoreCommittedCorrupt
        `shouldBe` TlsRestoreRefused TlsRestoreCorrupt
      decideTlsRestore current1 RestoreCommittedUnobservable
        `shouldBe` TlsRestoreRefused TlsRestoreUnobservable

    it "commits the pending outbox through CAS and does not rewrite an exact replay" $ do
      stored <- newIORef (Nothing :: Maybe (StoredTlsRetentionState Int))
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
      first <-
        stageTlsRetentionAuthority
          repository
          KeyRotationNotApproved
          ref1
          envelope1
      first
        `shouldBe` Right
          TlsRetentionStagingResult
            { tlsRetentionStagingState = pending1
            , tlsRetentionStagingDecision = TlsStaged pendingRecord1
            }
      readIORef writes `shouldReturn` [pending1]

      replay <-
        stageTlsRetentionAuthority
          repository
          KeyRotationNotApproved
          ref1
          envelope1
      replay
        `shouldBe` Right
          TlsRetentionStagingResult
            { tlsRetentionStagingState = pending1
            , tlsRetentionStagingDecision = TlsStagingNoop pendingRecord1
            }
      readIORef writes `shouldReturn` [pending1]

      promoted <-
        promoteTlsRetentionAuthority
          repository
          KeyRotationNotApproved
          goodEvidence
          ref1
      promoted
        `shouldBe` Right
          TlsRetentionPromotionResult
            { tlsRetentionPromotionState = current1
            , tlsRetentionPromotionDecision = TlsPromoted ref1
            }
      readIORef writes `shouldReturn` [pending1, current1]

    it "surfaces a lost staging CAS race without manufacturing pending state" $ do
      let repository =
            TlsRetentionAuthorityRepository
              { readTlsRetentionState = pure (Right Nothing)
              , compareAndSwapTlsRetentionState = \_ _ -> pure (Right False)
              }
      stageTlsRetentionAuthority
        repository
        KeyRotationNotApproved
        ref1
        envelope1
        `shouldReturn` Left TlsRetentionAuthorityConcurrentWrite

    it "serves the staged outbox and exact replay through the Authority endpoint" $ do
      stored <- newIORef (Nothing :: Maybe (StoredTlsRetentionState Int))
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision = Nothing
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref1
                , tlsAuthorityStageEnvelope = envelope1
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied pending1
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop pending1
      readIORef writes `shouldReturn` [pending1]

    it "keeps ordinary stage requests byte-compatible while round-tripping replacement evidence" $ do
      let ordinary =
            TlsAuthorityStageRequest
              { tlsAuthorityStageSubstrate = "home-local"
              , tlsAuthorityStageScope = "*.example.com"
              , tlsAuthorityStageApproval = KeyRotationNotApproved
              , tlsAuthorityStagePendingCollision = Nothing
              , tlsAuthorityStageTerminalReplacement = Nothing
              , tlsAuthorityStageCandidate = ref1
              , tlsAuthorityStageEnvelope = envelope1
              }
          legacy =
            LegacyTlsAuthorityStageRequest
              "home-local"
              "*.example.com"
              KeyRotationNotApproved
              Nothing
              ref1
              envelope1
          replacement =
            ordinary
              { tlsAuthorityStagePendingCollision = Just recoveryTerminalEvidence
              , tlsAuthorityStageTerminalReplacement = Just terminalReplacementEvidence
              , tlsAuthorityStageCandidate = ref4Replacement
              , tlsAuthorityStageEnvelope = envelope4Replacement
              }
      serialise ordinary `shouldBe` serialise legacy
      deserialiseOrFail (serialise legacy) `shouldBe` Right ordinary
      deserialiseOrFail (serialise replacement) `shouldBe` Right replacement

    it "serves legacy recovery staging as one durable CAS and exact replay" $ do
      stored <- newIORef (Nothing :: Maybe (StoredTlsRetentionState Int))
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityLegacyRecoveryStageRequest
                { tlsAuthorityLegacyRecoveryStageSubstrate = "home-local"
                , tlsAuthorityLegacyRecoveryStageScope = "*.example.com"
                , tlsAuthorityLegacyRecoveryStageApproval = KeyRotationNotApproved
                , tlsAuthorityLegacyRecoveryStageEvidence = legacyRecoveryEvidence
                , tlsAuthorityLegacyRecoveryStageCollision = Nothing
                , tlsAuthorityLegacyRecoveryStageCandidate = ref2
                , tlsAuthorityLegacyRecoveryStageEnvelope = envelope2
                }
          collisionBody =
            encodeControlPlaneRequest
              TlsAuthorityLegacyRecoveryStageRequest
                { tlsAuthorityLegacyRecoveryStageSubstrate = "home-local"
                , tlsAuthorityLegacyRecoveryStageScope = "*.example.com"
                , tlsAuthorityLegacyRecoveryStageApproval = KeyRotationNotApproved
                , tlsAuthorityLegacyRecoveryStageEvidence = legacyRecoveryEvidence
                , tlsAuthorityLegacyRecoveryStageCollision = Just recoveryCollisionEvidence
                , tlsAuthorityLegacyRecoveryStageCandidate = ref2Collision
                , tlsAuthorityLegacyRecoveryStageEnvelope = envelope2Collision
                }
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied recoveryPending2
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop recoveryPending2
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve collisionBody
        `shouldReturn` TlsAuthorityStagingApplied recoveryCollisionPending2
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve collisionBody
        `shouldReturn` TlsAuthorityStagingNoop recoveryCollisionPending2
      readIORef writes `shouldReturn` [recoveryPending2, recoveryCollisionPending2]

    it "serves the fixed recovery successor as one durable CAS and exact replay" $ do
      stored <-
        newIORef
          (Just (StoredTlsRetentionState 1 recoveryPending2) :: Maybe (StoredTlsRetentionState Int))
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityLegacyRecoveryStageRequest
                { tlsAuthorityLegacyRecoveryStageSubstrate = "home-local"
                , tlsAuthorityLegacyRecoveryStageScope = "*.example.com"
                , tlsAuthorityLegacyRecoveryStageApproval = KeyRotationNotApproved
                , tlsAuthorityLegacyRecoveryStageEvidence = legacyRecoveryEvidence
                , tlsAuthorityLegacyRecoveryStageCollision = Just recoveryCollisionEvidence
                , tlsAuthorityLegacyRecoveryStageCandidate = ref3Recovery
                , tlsAuthorityLegacyRecoveryStageEnvelope = envelope3Recovery
                }
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied recoverySuccessorPending3
      serveTlsAuthorityLegacyRecoveryStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop recoverySuccessorPending3
      readIORef writes `shouldReturn` [recoverySuccessorPending3]

    it "serves the unopenable successor as one durable CAS and exact replay" $ do
      stored <-
        newIORef
          (Just (StoredTlsRetentionState 1 current2) :: Maybe (StoredTlsRetentionState Int))
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityUnopenableSuccessorStageRequest
                { tlsAuthorityUnopenableSuccessorStageSubstrate = "home-local"
                , tlsAuthorityUnopenableSuccessorStageScope = "*.example.com"
                , tlsAuthorityUnopenableSuccessorStageApproval = KeyRotationNotApproved
                , tlsAuthorityUnopenableSuccessorStageEvidence = unopenableEvidence3
                , tlsAuthorityUnopenableSuccessorStageCandidate = ref4Successor
                , tlsAuthorityUnopenableSuccessorStageEnvelope = envelope4Successor
                }
          refusedBody =
            encodeControlPlaneRequest
              TlsAuthorityUnopenableSuccessorStageRequest
                { tlsAuthorityUnopenableSuccessorStageSubstrate = "home-local"
                , tlsAuthorityUnopenableSuccessorStageScope = "*.example.com"
                , tlsAuthorityUnopenableSuccessorStageApproval = KeyRotationNotApproved
                , tlsAuthorityUnopenableSuccessorStageEvidence =
                    TlsUnopenableVersionEvidence
                      (RetentionVersion 5)
                      (tlsSealedEnvelopeDigest envelope4Successor)
                , tlsAuthorityUnopenableSuccessorStageCandidate =
                    reference 6 (CertIdentity "serial-2" "spki-A" 2000) envelope2
                , tlsAuthorityUnopenableSuccessorStageEnvelope = envelope2
                }
      serveTlsAuthorityUnopenableSuccessorStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied unopenableSuccessorPending4
      serveTlsAuthorityUnopenableSuccessorStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop unopenableSuccessorPending4
      -- A second skip stacked on the first crosses the wire as its own closed
      -- token and writes nothing.
      serveTlsAuthorityUnopenableSuccessorStageRequest (1024 * 1024) resolve refusedBody
        `shouldReturn` TlsAuthorityStagingRefused "unopenable-successor-concurrent-pending"
      readIORef writes `shouldReturn` [unopenableSuccessorPending4]

    it "serves the already-skipped successor collision as one durable CAS and exact replay" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 unopenableSuccessorPending4)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision =
                    Just unopenableSuccessorCollisionAdoption
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref4Collision
                , tlsAuthorityStageEnvelope = envelope4Collision
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied unopenableSuccessorCollisionRebasedState
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop unopenableSuccessorCollisionRebasedState
      readIORef writes `shouldReturn` [unopenableSuccessorCollisionRebasedState]

    it "serves the fixed legacy-recovery successor collision as one CAS and replay" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 recoverySuccessorPending3)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision =
                    Just recoverySuccessorCollisionAdoption
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref3Collision
                , tlsAuthorityStageEnvelope = envelope3Collision
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied recoverySuccessorCollisionRebasedState
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop recoverySuccessorCollisionRebasedState
      readIORef writes `shouldReturn` [recoverySuccessorCollisionRebasedState]

    it "serves the terminal legacy-recovery successor as one CAS and replay" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 recoverySuccessorPending3)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision = Just recoveryTerminalEvidence
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref4Successor
                , tlsAuthorityStageEnvelope = envelope4Successor
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied recoveryTerminalState
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop recoveryTerminalState
      readIORef writes `shouldReturn` [recoveryTerminalState]

    it "serves the terminal version-4 collision rebase as one CAS and replay" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 recoveryTerminalState)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision = Just recoveryTerminalCollisionAdoption
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref4Collision
                , tlsAuthorityStageEnvelope = envelope4Collision
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied recoveryTerminalCollisionRebasedState
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop recoveryTerminalCollisionRebasedState
      readIORef writes `shouldReturn` [recoveryTerminalCollisionRebasedState]

    it "stages the exact terminal version-4 replacement before the compare-and-swap effect" $ do
      let decision =
            decideTlsTerminalReplacementStaging
              KeyRotationNotApproved
              recoverySuccessorPending3
              recoveryTerminalEvidence
              terminalReplacementEvidence
              ref4Replacement
              envelope4Replacement
          state = applyTlsTerminalReplacementStaging decision recoverySuccessorPending3
      decision
        `shouldBe` TlsTerminalReplacementStaged
          legacyRecoveryEvidence
          recoverySuccessorEvidence
          recoveryTerminalEvidence
          recoverySuccessorDisplacedIdentity
          terminalReplacementEvidence
          terminalReplacementPendingRecord
      state `shouldBe` terminalReplacementState
      encodeModelBValue tlsRetentionStateCodec state `shouldSatisfy` isRight
      decideTlsTerminalReplacementStaging
        KeyRotationNotApproved
        state
        recoveryTerminalEvidence
        terminalReplacementEvidence
        ref4Replacement
        envelope4Replacement
        `shouldBe` TlsTerminalReplacementStagingNoop terminalReplacementPendingRecord
      decideTlsPromotion KeyRotationNotApproved goodEvidence state ref4Replacement
        `shouldBe` TlsPromoted ref4Replacement
      decideTlsRestore state RestoreCommittedAbsent
        `shouldBe` TlsRestoreRefused TlsRestoreRecoveryPending

    it "serves terminal replacement as one durable CAS, exact replay, and no version search" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 recoverySuccessorPending3)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body evidence candidate envelope =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision = Just recoveryTerminalEvidence
                , tlsAuthorityStageTerminalReplacement = Just evidence
                , tlsAuthorityStageCandidate = candidate
                , tlsAuthorityStageEnvelope = envelope
                }
      serveTlsAuthorityStageRequest
        (1024 * 1024)
        resolve
        (body terminalReplacementEvidence ref4Replacement envelope4Replacement)
        `shouldReturn` TlsAuthorityStagingApplied terminalReplacementState
      serveTlsAuthorityStageRequest
        (1024 * 1024)
        resolve
        (body terminalReplacementEvidence ref4Replacement envelope4Replacement)
        `shouldReturn` TlsAuthorityStagingNoop terminalReplacementState
      let versionFive = ref4Replacement {retainedVersion = RetentionVersion 5}
      serveTlsAuthorityStageRequest
        (1024 * 1024)
        resolve
        ( body
            (terminalReplacementEvidence {tlsTerminalReplacementVersion = RetentionVersion 5})
            versionFive
            envelope4Replacement
        )
        `shouldReturn` TlsAuthorityStagingRefused "terminal-replacement-concurrent-pending"
      readIORef writes `shouldReturn` [terminalReplacementState]

    it "serves the current-backed bounded successor collision as one CAS and replay" $ do
      stored <-
        newIORef
          ( Just (StoredTlsRetentionState 1 ordinaryCollisionSuccessorState)
              :: Maybe (StoredTlsRetentionState Int)
          )
      writes <- newIORef ([] :: [TlsRetentionState])
      let repository = memoryRepository stored writes
          resolve _ = Right repository
          body =
            encodeControlPlaneRequest
              TlsAuthorityStageRequest
                { tlsAuthorityStageSubstrate = "home-local"
                , tlsAuthorityStageScope = "*.example.com"
                , tlsAuthorityStageApproval = KeyRotationNotApproved
                , tlsAuthorityStagePendingCollision =
                    Just recoverySuccessorCollisionAdoption
                , tlsAuthorityStageTerminalReplacement = Nothing
                , tlsAuthorityStageCandidate = ref3Collision
                , tlsAuthorityStageEnvelope = envelope3Collision
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied ordinarySuccessorCollisionRebasedState
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop ordinarySuccessorCollisionRebasedState
      readIORef writes `shouldReturn` [ordinarySuccessorCollisionRebasedState]

    it
      "TLS-AUTHORITY-UNOPENABLE-VERSION-PERMANENT-RETAIN-STOP-2026-09-15 admits exactly one successor"
      $ do
        -- The two-sided reproducer for the condition that stopped Sprint 6.5's
        -- live campaign for five consecutive cycles. The causal profile is one
        -- constructed durable state: a committed current at v2 and an
        -- Authority-lane object at v3 that is well formed and whose wrapped DEK
        -- does not open under the retained-home Transit key.

        -- The frozen superseded answer, asserted rather than described: without
        -- evidence, the ordinary transition cannot reach past v3 at all.
        -- `nextRetentionVersion` selects v3 on every future retain and the
        -- envelope is never reproducible, so this refusal is permanent.
        nextRetentionVersion current2 `shouldBe` RetentionVersion 3
        decideTlsStaging KeyRotationNotApproved current2 ref4Successor envelope4Successor
          `shouldBe` TlsStagingRefused TlsStageVersionMismatch
        -- And the pre-Authority recovery lane cannot be borrowed for it: its
        -- fixed-successor transition refuses a committed current outright,
        -- which is what keeps the two lanes disjoint.
        decideTlsLegacyRecoveryStaging
          KeyRotationNotApproved
          current2
          legacyRecoveryEvidence
          Nothing
          ref3Recovery
          envelope3Recovery
          `shouldBe` TlsLegacyRecoveryStagingRefused TlsLegacyRecoveryStageStateNotEmpty

        -- The replacement passes: one successor at v4, staged under durable
        -- evidence naming the version it skipped and the bytes that occupied it.
        stageUnopenableSuccessor current2 unopenableEvidence3 ref4Successor envelope4Successor
          `shouldBe` TlsUnopenableSuccessorStaged unopenableSuccessorPendingRecord
        applyTlsUnopenableSuccessorStaging
          unopenableEvidence3
          (stageUnopenableSuccessor current2 unopenableEvidence3 ref4Successor envelope4Successor)
          current2
          `shouldBe` unopenableSuccessorPending4

        -- The predecessor stays restorable throughout, which is the property
        -- that separates this outbox from every legacy-recovery one.
        currentRetainedRef unopenableSuccessorPending4 `shouldBe` Just ref2
        decideTlsRestore unopenableSuccessorPending4 (RestoreCommittedIntact ref2)
          `shouldBe` TlsRestoreApply ref2
        decideTlsRestore unopenableSuccessorPending4 RestoreCommittedAbsent
          `shouldBe` TlsRestoreIssue

        -- Promotion is still judged against that predecessor: strictly newer,
        -- no validity regression, approval still required for a key change.
        decideTlsPromotion
          KeyRotationNotApproved
          goodEvidence
          unopenableSuccessorPending4
          ref4Successor
          `shouldBe` TlsPromoted ref4Successor
        applyTlsPromotion
          (decideTlsPromotion KeyRotationNotApproved goodEvidence unopenableSuccessorPending4 ref4Successor)
          unopenableSuccessorPending4
          `shouldBe` TlsRetentionCurrent ref4Successor

    it "admits one successor version past an unopenable object and never a search" $ do
      -- An exact replay is a no-op rather than a second CAS.
      stageUnopenableSuccessor
        unopenableSuccessorPending4
        unopenableEvidence3
        ref4Successor
        envelope4Successor
        `shouldBe` TlsUnopenableSuccessorStagingNoop unopenableSuccessorPendingRecord
      -- Two successors in a row: a second skip stacked on the first is refused,
      -- with no advance and no fresh version probed.
      mapM_
        ( \(state, evidence, candidate, envelope, expected) ->
            stageUnopenableSuccessor state evidence candidate envelope
              `shouldBe` TlsUnopenableSuccessorStagingRefused expected
        )
        [
          ( unopenableSuccessorPending4
          , TlsUnopenableVersionEvidence
              (RetentionVersion 5)
              (tlsSealedEnvelopeDigest envelope4Successor)
          , reference 6 (CertIdentity "serial-2" "spki-A" 2000) envelope2
          , envelope2
          , TlsUnopenableSuccessorStageConcurrentPending
          )
        , -- Evidence about any version but the one this reference was about to
          -- claim authorizes nothing: the lane cannot walk forward looking for
          -- a free slot.

          ( current2
          , TlsUnopenableVersionEvidence
              (RetentionVersion 4)
              (tlsSealedEnvelopeDigest envelopeUnopenable3)
          , reference 5 (CertIdentity "serial-2" "spki-A" 2000) envelope4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageSkippedVersionMismatch
          )
        , -- One version, not two.

          ( current2
          , unopenableEvidence3
          , reference 5 (CertIdentity "serial-2" "spki-A" 2000) envelope4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageVersionMismatch
          )
        , -- The lane is entered only from a committed reference; the pre-outbox
          -- states are the other lane's and stay disjoint from this one.

          ( TlsRetentionEmpty
          , TlsUnopenableVersionEvidence
              (RetentionVersion 1)
              (tlsSealedEnvelopeDigest envelope1)
          , ref2
          , envelope2
          , TlsUnopenableSuccessorStageStateNotCurrent
          )
        ,
          ( recoveryPending2
          , unopenableEvidence3
          , ref4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageConcurrentPending
          )
        , -- A successor that re-asserted the skipped object's own digest would
          -- launder the unopenable envelope into a fresh version.

          ( current2
          , TlsUnopenableVersionEvidence
              (RetentionVersion 3)
              (tlsSealedEnvelopeDigest envelope4Successor)
          , ref4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageSkippedDigestReused
          )
        ,
          ( current2
          , TlsUnopenableVersionEvidence (RetentionVersion 0) (tlsSealedEnvelopeDigest envelopeUnopenable3)
          , ref4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageEvidenceInvalid
          )
        ,
          ( current2
          , TlsUnopenableVersionEvidence (RetentionVersion 3) "not-a-digest"
          , ref4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageEvidenceInvalid
          )
        ,
          ( current2
          , unopenableEvidence3
          , ref4Successor {retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope2}
          , envelope4Successor
          , TlsUnopenableSuccessorStageDigestMismatch
          )
        , -- Nothing about the Authority's own rules is relaxed by the skip.

          ( current2
          , unopenableEvidence3
          , reference 4 (CertIdentity "serial-4" "spki-A" 500) envelope4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageValidityRegression
          )
        ,
          ( current2
          , unopenableEvidence3
          , reference 4 (CertIdentity "serial-4" "spki-B" 2000) envelope4Successor
          , envelope4Successor
          , TlsUnopenableSuccessorStageUnapprovedKeyChange
          )
        ]
      -- An approved key change past an unopenable version still stages.
      decideTlsUnopenableSuccessorStaging
        KeyRotationApproved
        current2
        unopenableEvidence3
        (reference 4 (CertIdentity "serial-4" "spki-B" 2000) envelope4Successor)
        envelope4Successor
        `shouldBe` TlsUnopenableSuccessorStaged
          ( TlsRetentionPending
              (Just ref2)
              KeyRotationApproved
              (reference 4 (CertIdentity "serial-4" "spki-B" 2000) envelope4Successor)
              envelope4Successor
          )

    it "refuses a durable successor whose evidence does not name the version it skipped" $ do
      -- The codec boundary re-runs the whole decision from the record alone, so
      -- a version jump cannot be authorized by a token the validator never saw.
      encodeModelBValue tlsRetentionStateCodec unopenableSuccessorPending4
        `shouldSatisfy` isRight
      mapM_
        ( \state ->
            encodeModelBValue tlsRetentionStateCodec state `shouldSatisfy` isLeft
        )
        [ -- Evidence naming a version this predecessor would not have claimed.
          TlsRetentionUnopenableSuccessorPendingState
            (TlsUnopenableVersionEvidence (RetentionVersion 4) (tlsSealedEnvelopeDigest envelopeUnopenable3))
            unopenableSuccessorPendingRecord
        , -- Evidence whose digest is the successor's own bytes.
          TlsRetentionUnopenableSuccessorPendingState
            (TlsUnopenableVersionEvidence (RetentionVersion 3) (tlsSealedEnvelopeDigest envelope4Successor))
            unopenableSuccessorPendingRecord
        , -- A candidate two versions past the skip.
          TlsRetentionUnopenableSuccessorPendingState
            unopenableEvidence3
            ( TlsRetentionPending
                (Just ref2)
                KeyRotationNotApproved
                (reference 5 (CertIdentity "serial-2" "spki-A" 2000) envelope4Successor)
                envelope4Successor
            )
        , -- No predecessor to reconstruct the skip from.
          TlsRetentionUnopenableSuccessorPendingState
            unopenableEvidence3
            (TlsRetentionPending Nothing KeyRotationNotApproved ref4Successor envelope4Successor)
        , -- An unapproved key change laundered through the skip.
          TlsRetentionUnopenableSuccessorPendingState
            unopenableEvidence3
            ( TlsRetentionPending
                (Just ref2)
                KeyRotationNotApproved
                (reference 4 (CertIdentity "serial-4" "spki-B" 2000) envelope4Successor)
                envelope4Successor
            )
        ]

    it "round-trips every durable legacy-recovery outbox state" $ do
      mapM_
        ( \state -> do
            encoded <- expectRight (encodeModelBValue tlsRetentionStateCodec state)
            decodeModelBValue tlsRetentionStateCodec encoded `shouldBe` Right state
        )
        [ recoveryPending2
        , recoveryCollisionPending2
        , recoverySuccessorPending3
        , unopenableSuccessorPending4
        , ordinaryCollisionRebasedState
        , ordinaryCollisionSuccessorState
        , unopenableSuccessorCollisionRebasedState
        , recoverySuccessorCollisionRebasedState
        , ordinarySuccessorCollisionRebasedState
        , recoveryTerminalState
        , recoveryTerminalCollisionRebasedState
        , terminalReplacementState
        ]

    it "round-trips pending maximum-size ciphertext without exceeding the state bound" $ do
      let maximumEnvelope =
            mustRight
              ( mkTlsSealedEnvelope
                  (ByteString.replicate tlsMaximumCertificateCiphertextBytes 97)
                  (ByteString.replicate tlsMaximumWrappedDekBytes 98)
              )
          maximumRef =
            reference
              1
              (CertIdentity "serial-maximum" "spki-maximum" 1000)
              maximumEnvelope
          maximumState =
            TlsRetentionPendingState
              ( TlsRetentionPending
                  Nothing
                  KeyRotationNotApproved
                  maximumRef
                  maximumEnvelope
              )
      encoded <- expectRight (encodeModelBValue tlsRetentionStateCodec maximumState)
      ByteString.length encoded `shouldSatisfy` (<= tlsRetentionStateMaximumBytes)
      decodeModelBValue tlsRetentionStateCodec encoded `shouldBe` Right maximumState
      decodeModelBValue
        tlsRetentionStateCodec
        (ByteString.replicate (tlsRetentionStateMaximumBytes + 1) 0)
        `shouldSatisfy` isLeft
      encodeModelBValue
        tlsRetentionStateCodec
        ( TlsRetentionCurrent
            (ref1 {retainedSourceSecret = SourceSecretRef "" "rv-1"})
        )
        `shouldSatisfy` isLeft
      encodeModelBValue
        tlsRetentionStateCodec
        ( TlsRetentionPendingState
            ( pendingRecord1
                { tlsPendingCandidate =
                    ref1 {retainedVersion = RetentionVersion 2}
                }
            )
        )
        `shouldSatisfy` isLeft

    it "preserves the pre-outbox Empty and Current canonical CBOR encodings" $ do
      let legacyPairs =
            [
              ( LegacyTlsRetentionEmpty
              , TlsRetentionEmpty
              )
            ,
              ( LegacyTlsRetentionCurrent ref1
              , current1
              )
            ]
      forM_ legacyPairs $ \(legacy, current) -> do
        let legacyBytes = LazyByteString.toStrict (serialise legacy)
        encodeModelBValue tlsRetentionStateCodec current `shouldBe` Right legacyBytes
        decodeModelBValue tlsRetentionStateCodec legacyBytes `shouldBe` Right current

    it "preserves the pre-outbox immutable envelope encoding after moving its owner" $ do
      let legacyBytes =
            serialise
              (LegacyTlsSealedEnvelope "ciphertext-1" "wrapped-1")
      serialise envelope1 `shouldBe` legacyBytes
      deserialiseOrFail legacyBytes `shouldBe` Right envelope1

    it "appends staging responses without shifting existing Authority wire tags" $ do
      let legacyPairs =
            [
              ( LegacyTlsAuthorityObserved current1
              , TlsAuthorityObserved current1
              )
            ,
              ( LegacyTlsAuthorityPromotionApplied current1
              , TlsAuthorityPromotionApplied current1
              )
            ,
              ( LegacyTlsAuthorityPromotionNoop current1
              , TlsAuthorityPromotionNoop current1
              )
            ,
              ( LegacyTlsAuthorityPromotionRefused "stale-version"
              , TlsAuthorityPromotionRefused "stale-version"
              )
            ,
              ( LegacyTlsAuthorityConcurrentWrite
              , TlsAuthorityConcurrentWrite
              )
            ,
              ( LegacyTlsAuthorityUnavailable
              , TlsAuthorityUnavailable
              )
            ,
              ( LegacyTlsAuthorityRequestRefused
              , TlsAuthorityRequestRefused
              )
            ]
      forM_ legacyPairs $ \(legacy, current) ->
        serialise current `shouldBe` serialise legacy
 where
  goodEvidence = PromotionEvidence True True
  src = SourceSecretRef "uid-1" "rv-1"
  envelope1 = mustRight (mkTlsSealedEnvelope "ciphertext-1" "wrapped-1")
  envelope1Alternate = mustRight (mkTlsSealedEnvelope "ciphertext-1b" "wrapped-1b")
  envelope2 = mustRight (mkTlsSealedEnvelope "ciphertext-2" "wrapped-2")
  envelope2Collision = mustRight (mkTlsSealedEnvelope "ciphertext-2-old" "wrapped-2-old")
  envelope3Recovery = mustRight (mkTlsSealedEnvelope "ciphertext-3-recovery" "wrapped-3-recovery")
  envelope3Collision = mustRight (mkTlsSealedEnvelope "ciphertext-3-collision" "wrapped-3-collision")
  envelopeRegress = mustRight (mkTlsSealedEnvelope "ciphertext-3" "wrapped-3")
  envelopeKeyChange = mustRight (mkTlsSealedEnvelope "ciphertext-key" "wrapped-key")
  ref1 = reference 1 (CertIdentity "serial-1" "spki-A" 1000) envelope1
  ref1Alternate = reference 1 (CertIdentity "serial-1b" "spki-A" 1000) envelope1Alternate
  ref2 = reference 2 (CertIdentity "serial-2" "spki-A" 2000) envelope2
  ref2Collision = ref2 {retainedCiphertextDigest = tlsSealedEnvelopeDigest envelope2Collision}
  ref3Recovery = reference 3 (CertIdentity "serial-2" "spki-A" 2000) envelope3Recovery
  ref3Collision = reference 3 (CertIdentity "serial-2" "spki-A" 2000) envelope3Collision
  refRegress = reference 3 (CertIdentity "serial-3" "spki-A" 500) envelopeRegress
  refKeyChange = reference 2 (CertIdentity "serial-2" "spki-B" 2000) envelopeKeyChange
  current1 = TlsRetentionCurrent ref1
  current2 = TlsRetentionCurrent ref2
  pendingRecord1 =
    TlsRetentionPending Nothing KeyRotationNotApproved ref1 envelope1
  pending1 = TlsRetentionPendingState pendingRecord1
  pending2 =
    applyTlsStaging
      (decideTlsStaging KeyRotationNotApproved current1 ref2 envelope2)
      current1
  ordinaryDisplacedIdentityRecord =
    TlsDisplacedPendingIdentity
      (Just ref1)
      KeyRotationNotApproved
      ref2
  ordinaryCollisionAdoption =
    TlsPendingCollisionRecovery
      (RetentionVersion 2)
      (tlsSealedEnvelopeDigest envelope2)
      (tlsSealedEnvelopeDigest envelope2Collision)
      TlsPendingCollisionAdoptObserved
  ordinaryCollisionSuccessor =
    ordinaryCollisionAdoption
      { tlsPendingCollisionDisposition = TlsPendingCollisionStepPastUnopenable
      }
  ordinaryCollisionPendingRecord =
    TlsRetentionPending (Just ref1) KeyRotationNotApproved ref2Collision envelope2Collision
  ordinaryCollisionSuccessorPendingRecord =
    TlsRetentionPending (Just ref1) KeyRotationNotApproved ref3Recovery envelope3Recovery
  ordinaryCollisionRebasedState =
    TlsRetentionPendingCollisionRebasedState
      ordinaryCollisionAdoption
      ordinaryDisplacedIdentityRecord
      ordinaryCollisionPendingRecord
  ordinaryCollisionSuccessorState =
    TlsRetentionPendingCollisionSuccessorState
      ordinaryCollisionSuccessor
      ordinaryDisplacedIdentityRecord
      ordinaryCollisionSuccessorPendingRecord
  ordinarySuccessorDisplacedIdentity =
    TlsDisplacedPendingIdentity
      (Just ref1)
      KeyRotationNotApproved
      ref3Recovery
  ordinarySuccessorCollisionPendingRecord =
    TlsRetentionPending (Just ref1) KeyRotationNotApproved ref3Collision envelope3Collision
  ordinarySuccessorCollisionRebasedState =
    TlsRetentionPendingCollisionSuccessorRebasedState
      ordinaryCollisionSuccessor
      ordinaryDisplacedIdentityRecord
      recoverySuccessorCollisionAdoption
      ordinarySuccessorDisplacedIdentity
      ordinarySuccessorCollisionPendingRecord
  legacyRecoveryEvidence =
    TlsLegacyRecoveryEvidence
      (RetentionVersion 1)
      (tlsSealedEnvelopeDigest envelope1)
  recoveryPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref2 envelope2
  recoveryPending2 =
    TlsRetentionLegacyRecoveryPendingState
      legacyRecoveryEvidence
      recoveryPendingRecord
  recoveryCollisionEvidence =
    TlsLegacyRecoveryCollisionEvidence
      (RetentionVersion 2)
      (tlsSealedEnvelopeDigest envelope2)
      (tlsSealedEnvelopeDigest envelope2Collision)
  recoveryCollisionPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref2Collision envelope2Collision
  recoveryCollisionPending2 =
    TlsRetentionLegacyRecoveryCollisionPendingState
      legacyRecoveryEvidence
      recoveryCollisionEvidence
      recoveryCollisionPendingRecord
  recoverySuccessorEvidence =
    TlsLegacyRecoverySuccessorEvidence
      recoveryCollisionEvidence
      KeyRotationNotApproved
      ref2
  recoverySuccessorPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref3Recovery envelope3Recovery
  recoverySuccessorPending3 =
    TlsRetentionLegacyRecoverySuccessorPendingState
      legacyRecoveryEvidence
      recoverySuccessorEvidence
      recoverySuccessorPendingRecord
  recoverySuccessorCollisionAdoption =
    TlsPendingCollisionRecovery
      (RetentionVersion 3)
      (tlsSealedEnvelopeDigest envelope3Recovery)
      (tlsSealedEnvelopeDigest envelope3Collision)
      TlsPendingCollisionAdoptObserved
  recoverySuccessorDisplacedIdentity =
    TlsDisplacedPendingIdentity
      Nothing
      KeyRotationNotApproved
      ref3Recovery
  recoverySuccessorCollisionPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref3Collision envelope3Collision
  recoverySuccessorCollisionRebasedState =
    TlsRetentionLegacyRecoverySuccessorCollisionRebasedState
      legacyRecoveryEvidence
      recoverySuccessorEvidence
      recoverySuccessorCollisionAdoption
      recoverySuccessorDisplacedIdentity
      recoverySuccessorCollisionPendingRecord
  recoveryTerminalEvidence =
    recoverySuccessorCollisionAdoption
      { tlsPendingCollisionDisposition = TlsPendingCollisionStepPastUnopenable
      }
  recoveryTerminalPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref4Successor envelope4Successor
  recoveryTerminalState =
    TlsRetentionLegacyRecoveryTerminalSuccessorState
      legacyRecoveryEvidence
      recoverySuccessorEvidence
      recoveryTerminalEvidence
      recoverySuccessorDisplacedIdentity
      recoveryTerminalPendingRecord
  recoveryTerminalCollisionAdoption =
    TlsPendingCollisionRecovery
      (RetentionVersion 4)
      (tlsSealedEnvelopeDigest envelope4Successor)
      (tlsSealedEnvelopeDigest envelope4Collision)
      TlsPendingCollisionAdoptObserved
  recoveryTerminalDisplacedIdentity =
    TlsDisplacedPendingIdentity
      Nothing
      KeyRotationNotApproved
      ref4Successor
  recoveryTerminalCollisionPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref4Collision envelope4Collision
  recoveryTerminalCollisionRebasedState =
    TlsRetentionLegacyRecoveryTerminalSuccessorRebasedState
      legacyRecoveryEvidence
      recoverySuccessorEvidence
      recoveryTerminalEvidence
      recoverySuccessorDisplacedIdentity
      recoveryTerminalCollisionAdoption
      recoveryTerminalDisplacedIdentity
      recoveryTerminalCollisionPendingRecord
  forgedStalePending =
    TlsRetentionPendingState
      (TlsRetentionPending (Just ref2) KeyRotationNotApproved ref1 envelope1)

  -- The live 2026-09-15 shape: a committed current at v2, an Authority-lane
  -- object at v3 that is well formed and does not open, and the one successor
  -- at v4 that stepping past it admits.
  envelopeUnopenable3 =
    mustRight (mkTlsSealedEnvelope "ciphertext-3-unopenable" "wrapped-3-unopenable")
  envelope4Successor =
    mustRight (mkTlsSealedEnvelope "ciphertext-4-successor" "wrapped-4-successor")
  envelope4Collision =
    mustRight (mkTlsSealedEnvelope "ciphertext-4-collision" "wrapped-4-collision")
  envelope4Replacement =
    mustRight (mkTlsSealedEnvelope "ciphertext-4-replacement" "wrapped-4-replacement")
  ref4Successor = reference 4 (CertIdentity "serial-2" "spki-A" 2000) envelope4Successor
  ref4Collision = reference 4 (CertIdentity "serial-2" "spki-A" 2000) envelope4Collision
  ref4Replacement = reference 4 (CertIdentity "serial-2" "spki-A" 2000) envelope4Replacement
  terminalReplacementEvidence =
    TlsTerminalReplacementEvidence
      (RetentionVersion 4)
      (tlsSealedEnvelopeDigest envelope4Collision)
  terminalReplacementPendingRecord =
    TlsRetentionPending Nothing KeyRotationNotApproved ref4Replacement envelope4Replacement
  terminalReplacementState =
    TlsRetentionLegacyRecoveryTerminalReplacementState
      legacyRecoveryEvidence
      recoverySuccessorEvidence
      recoveryTerminalEvidence
      recoverySuccessorDisplacedIdentity
      terminalReplacementEvidence
      terminalReplacementPendingRecord
  unopenableEvidence3 =
    TlsUnopenableVersionEvidence
      (RetentionVersion 3)
      (tlsSealedEnvelopeDigest envelopeUnopenable3)
  unopenableSuccessorPendingRecord =
    TlsRetentionPending (Just ref2) KeyRotationNotApproved ref4Successor envelope4Successor
  unopenableSuccessorPending4 =
    TlsRetentionUnopenableSuccessorPendingState
      unopenableEvidence3
      unopenableSuccessorPendingRecord
  unopenableSuccessorDisplacedIdentity =
    TlsDisplacedPendingIdentity
      (Just ref2)
      KeyRotationNotApproved
      ref4Successor
  unopenableSuccessorCollisionAdoption =
    TlsPendingCollisionRecovery
      (RetentionVersion 4)
      (tlsSealedEnvelopeDigest envelope4Successor)
      (tlsSealedEnvelopeDigest envelope4Collision)
      TlsPendingCollisionAdoptObserved
  unopenableSuccessorCollisionPendingRecord =
    TlsRetentionPending
      (Just ref2)
      KeyRotationNotApproved
      ref4Collision
      envelope4Collision
  unopenableSuccessorCollisionRebasedState =
    TlsRetentionUnopenableSuccessorCollisionRebasedState
      unopenableEvidence3
      unopenableSuccessorCollisionAdoption
      unopenableSuccessorDisplacedIdentity
      unopenableSuccessorCollisionPendingRecord
  stageUnopenableSuccessor state evidence candidate envelope =
    decideTlsUnopenableSuccessorStaging
      KeyRotationNotApproved
      state
      evidence
      candidate
      envelope

  reference version certificate envelope =
    RetainedTlsRef
      (RetentionVersion version)
      certificate
      (tlsSealedEnvelopeDigest envelope)
      src

  isJust value = case value of
    Just _ -> True
    Nothing -> False

  mustRight = either (error . show) id

  expectRight result = case result of
    Left detail -> expectationFailure (show detail) >> pure ByteString.empty
    Right value -> pure value

  memoryRepository stored writes =
    TlsRetentionAuthorityRepository
      { readTlsRetentionState = Right <$> readIORef stored
      , compareAndSwapTlsRetentionState = \expected state -> do
          observed <- readIORef stored
          if (storedTlsRetentionRevision <$> observed) == expected
            then do
              let nextRevision = maybe 1 ((+ 1) . storedTlsRetentionRevision) observed
              writeIORef stored (Just (StoredTlsRetentionState nextRevision state))
              modifyIORef' writes (<> [state])
              pure (Right True)
            else pure (Right False)
      }
