{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionManifest (decommissionManifestSuite) where

import Codec.Serialise (Serialise)
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (fromJust)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
  ( appendPayload
  , contentDigest
  , mkFrameAttemptId
  , mkFrameNodeId
  )
import Prodbox.Lifecycle.Decommission.Journal
  ( JournalRecoveryError (JournalChainDrift)
  , ReceiptRecovery (recoveryOutcome)
  , RecoveryOutcome (RecoveryComplete, RecoveryRefused)
  , encodeJournal
  , recoverReceipt
  )
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.Verifier
import TestSupport

newtype ReceiptPayload = ReceiptPayload Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionManifestSuite :: SuiteBuilder ()
decommissionManifestSuite =
  describe "Sprint 4.50 decommission manifest" $ do
    it "builds a validated manifest and exposes its inventory" $ do
      manifestVersion validManifest `shouldBe` currentManifestVersion
      manifestClusterId validManifest `shouldBe` "home"
      manifestNodes validManifest `shouldBe` nodes
    it "rejects an empty, duplicated, or malformed inventory" $ do
      mkDecommissionManifest "home" [] `shouldBe` Left ManifestNodesEmpty
      mkDecommissionManifest "home" [SharedObjectBucket, SharedObjectBucket]
        `shouldBe` Left ManifestNodesDuplicated
      mkDecommissionManifest "" nodes `shouldBe` Left ManifestClusterIdInvalid
      mkDecommissionManifest "home" [TargetGeneration "" targetGenerationOne]
        `shouldBe` Left ManifestTargetRefInvalid
      mkDecommissionTargetGeneration 0
        `shouldBe` Left DecommissionTargetGenerationMustBePositive
      mkDecommissionManifest
        "home"
        [ TargetGeneration "vscode" targetGenerationOne
        , TargetGeneration "vscode" targetGenerationTwo
        ]
        `shouldBe` Left ManifestTargetRefDuplicated
    it "digests deterministically and distinctly per plan" $ do
      decommissionManifestDigest validManifest
        `shouldBe` decommissionManifestDigest validManifest
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest otherManifest
    it "changes the digest when the cluster identity or node order changes" $ do
      let renamed = mustRight (mkDecommissionManifest "aws" nodes)
          reordered = mustRight (mkDecommissionManifest "home" (reverse nodes))
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest renamed
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest reordered
    it "round-trips bounded canonical base-manifest bytes and refuses malformed input" $ do
      decodeDecommissionManifest 65536 (encodeDecommissionManifest validManifest)
        `shouldBe` Right validManifest
      decodeDecommissionManifest 1 (encodeDecommissionManifest validManifest)
        `shouldBe` Left ManifestEnvelopeTooLarge
      decodeDecommissionManifest 65536 "not-a-manifest"
        `shouldBe` Left ManifestEnvelopeInvalid
    it "derives one deterministic receipt node ID per exact typed coordinate" $ do
      decommissionNodeFrameId SesProviderStack
        `shouldBe` decommissionNodeFrameId SesProviderStack
      decommissionNodeFrameId SesProviderStack
        `shouldNotBe` decommissionNodeFrameId SesSmtpIam
      decommissionNodeFrameId (TargetGeneration "vscode" targetGenerationOne)
        `shouldNotBe` decommissionNodeFrameId (TargetGeneration "api" targetGenerationOne)
      decommissionNodeFrameId (TargetGeneration "vscode" targetGenerationOne)
        `shouldNotBe` decommissionNodeFrameId (TargetGeneration "vscode" targetGenerationTwo)
    it "binds a receipt to exactly its manifest digest" $ do
      recoveryOutcome (recover (decommissionManifestDigest validManifest))
        `shouldBe` RecoveryComplete
      recoveryOutcome (recover (decommissionManifestDigest otherManifest))
        `shouldBe` RecoveryRefused (JournalChainDrift 0)
    it "authenticates the complete plan plus exact verifier binding under the pinned signer" $ do
      verifySignedDecommissionManifest signerDigest signedManifest
        `shouldBe` Right verifiedManifest
      verifySignedDecommissionManifest otherSignerDigest signedManifest
        `shouldBe` Left SignedManifestSignerDigestMismatch
      decodeSignedDecommissionManifest
        65536
        signerDigest
        (encodeSignedDecommissionManifest signedManifest)
        `shouldBe` Right signedManifest
    it "refuses oversized, malformed, and signature-tampered complete manifests" $ do
      let encoded = encodeSignedDecommissionManifest signedManifest
          tampered =
            LazyByteString.fromStrict
              (flipLastByte (LazyByteString.toStrict encoded))
      decodeSignedDecommissionManifest 1 signerDigest encoded
        `shouldBe` Left SignedManifestEnvelopeTooLarge
      decodeSignedDecommissionManifest 65536 signerDigest "not-a-signed-manifest"
        `shouldBe` Left SignedManifestEnvelopeInvalid
      decodeSignedDecommissionManifest 65536 signerDigest tampered
        `shouldBe` Left
          ( SignedManifestEnvelopeVerificationFailed
              SignedManifestAuthenticationFailed
          )
    it "changes the authenticated manifest when the exact runner build/path binding changes" $ do
      let otherPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/other-runner")
          otherArtifact =
            mustRight (mkVerifierArtifact "runner-build-v2" dependencyBytes metadata)
          rebound = signDecommissionManifest signingKey validManifest (verifierBindingOf otherPath otherArtifact)
      signedDecommissionManifestDigest signedManifest
        `shouldNotBe` signedDecommissionManifestDigest rebound
    it "keeps private signing and admin-shaped secret bytes out of the signed manifest" $ do
      let encoded = LazyByteString.toStrict (encodeSignedDecommissionManifest signedManifest)
      ByteString.isInfixOf signingSeed encoded `shouldBe` False
      ByteString.isInfixOf "AWS_SECRET_ACCESS_KEY=fixture-secret" encoded `shouldBe` False
 where
  nodes =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , TargetGeneration "vscode" targetGenerationOne
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]
  validManifest = mustRight (mkDecommissionManifest "home" nodes)
  otherManifest = mustRight (mkDecommissionManifest "aws" [SesProviderStack, SharedObjectBucket])
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  journal manifestDigest =
    let frame0 = appendPayload manifestDigest Nothing nodeId attemptId (ReceiptPayload "intent")
        frame1 = appendPayload manifestDigest (Just frame0) nodeId attemptId (ReceiptPayload "result")
     in encodeJournal [frame0, frame1]
  boundJournal = journal (decommissionManifestDigest validManifest)
  recover expectedDigest = recoverReceipt 8192 expectedDigest boundJournal :: ReceiptRecovery ReceiptPayload
  dependencyBytes = "dependency closure v1"
  metadata =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyBytes)
          1
          (contentDigest "manifest-schema-v1")
          1
          (contentDigest "interpreter-registry-v1")
      )
  artifact = mustRight (mkVerifierArtifact "runner-build-v1" dependencyBytes metadata)
  artifactPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")
  signingSeed = ByteString.pack [0 .. 31]
  signingKey = mustRight (mkManifestSigningKey signingSeed)
  signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)
  otherSignerDigest =
    manifestPublicKeyDigest
      (manifestSigningPublicKey (mustRight (mkManifestSigningKey (ByteString.pack [32 .. 63]))))
  signedManifest =
    signDecommissionManifest signingKey validManifest (verifierBindingOf artifactPath artifact)
  verifiedManifest = mustRight (verifySignedDecommissionManifest signerDigest signedManifest)

  targetGenerationOne = mustRight (mkDecommissionTargetGeneration 1)
  targetGenerationTwo = mustRight (mkDecommissionTargetGeneration 2)

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id

flipLastByte :: ByteString.ByteString -> ByteString.ByteString
flipLastByte bytes =
  ByteString.snoc
    (ByteString.init bytes)
    (ByteString.last bytes `xor` 0xFF)
