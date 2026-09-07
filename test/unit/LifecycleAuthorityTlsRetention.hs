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
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.TlsRetentionAuthority
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
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

lifecycleAuthorityTlsRetentionSuite :: SuiteBuilder ()
lifecycleAuthorityTlsRetentionSuite =
  describe "Sprint 4.48 Lifecycle Authority TLS-retention promotion/restore fold" $ do
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
                , tlsAuthorityStageCandidate = ref1
                , tlsAuthorityStageEnvelope = envelope1
                }
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingApplied pending1
      serveTlsAuthorityStageRequest (1024 * 1024) resolve body
        `shouldReturn` TlsAuthorityStagingNoop pending1
      readIORef writes `shouldReturn` [pending1]

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
  envelopeRegress = mustRight (mkTlsSealedEnvelope "ciphertext-3" "wrapped-3")
  envelopeKeyChange = mustRight (mkTlsSealedEnvelope "ciphertext-key" "wrapped-key")
  ref1 = reference 1 (CertIdentity "serial-1" "spki-A" 1000) envelope1
  ref1Alternate = reference 1 (CertIdentity "serial-1b" "spki-A" 1000) envelope1Alternate
  ref2 = reference 2 (CertIdentity "serial-2" "spki-A" 2000) envelope2
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
  forgedStalePending =
    TlsRetentionPendingState
      (TlsRetentionPending (Just ref2) KeyRotationNotApproved ref1 envelope1)

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
