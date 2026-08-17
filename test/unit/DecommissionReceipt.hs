{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionReceipt (decommissionReceiptSuite) where

import Codec.Serialise (Serialise, serialise)
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
import Prodbox.Lifecycle.Decommission.Journal
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.Receipt
import Prodbox.Lifecycle.Decommission.Verifier
import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

data TestEntry
  = TestIntent !Text
  | TestObservation !Text
  | TestResult !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- A wire-compatible test-only shape used to exercise invalid persisted headers.
-- The production constructor remains opaque.
data ReceiptHeaderWire = ReceiptHeaderWire
  { wireVersion :: !Word
  , wireManifestDigest :: !FrameDigest
  , wirePlanDigest :: !FrameDigest
  , wireSignatureDigest :: !FrameDigest
  , wireSignerDigest :: !FrameDigest
  , wireVerifierBinding :: !VerifierBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionReceiptSuite :: SuiteBuilder ()
decommissionReceiptSuite =
  describe "Sprint 4.50 decommission receipt durable barrier" $ do
    it "appends frames durably and reopens the complete chain" $
      withSystemTempDirectory "prodbox-decommission-receipt" $ \dir -> do
        let path = dir </> "receipt.log"
        mapM_ (appendReceiptFrame path) chain
        reopen <- reopen' path
        reopenFrames reopen `shouldBe` chain
        reopenOutcome reopen `shouldBe` RecoveryComplete
        reopenTruncatedTo reopen `shouldBe` Nothing
    it "truncates a torn tail on reopen and resumes cleanly" $
      withSystemTempDirectory "prodbox-decommission-receipt-torn" $ \dir -> do
        let path = dir </> "receipt.log"
        appendReceiptFrame path frame0
        appendReceiptFrame path frame1
        -- Simulate a crash mid-append of frame2: a partial record lands undurably.
        ByteString.appendFile path (ByteString.take 5 (encodeRecord frame2))
        reopen <- reopen' path
        reopenOutcome reopen `shouldBe` RecoveryTruncatableTorn
        reopenFrames reopen `shouldBe` [frame0, frame1]
        reopenTruncatedTo reopen `shouldSatisfy` isJust
        -- Resume: the real frame2 append now lands after the recovered prefix.
        appendReceiptFrame path frame2
        resumed <- reopen' path
        reopenOutcome resumed `shouldBe` RecoveryComplete
        reopenFrames resumed `shouldBe` chain
    it "refuses a fully written corrupt frame without truncating" $
      withSystemTempDirectory "prodbox-decommission-receipt-corrupt" $ \dir -> do
        let path = dir </> "receipt.log"
        mapM_ (appendReceiptFrame path) [frame0, frame1]
        corruptFileByteAt path (ByteString.length (encodeJournal [frame0]) + 4)
        reopen <- reopen' path
        reopenTruncatedTo reopen `shouldBe` Nothing
        case reopenOutcome reopen of
          RecoveryRefused _ -> pure ()
          other -> expectationFailure ("expected a refusal, got " <> show other)
    it "reopens a missing receipt as an empty complete chain" $
      withSystemTempDirectory "prodbox-decommission-receipt-missing" $ \dir -> do
        reopen <- reopen' (dir </> "absent.log")
        reopenFrames reopen `shouldBe` []
        reopenOutcome reopen `shouldBe` RecoveryComplete
    it "creates and idempotently reopens an authenticated public receipt header" $
      withSystemTempDirectory "prodbox-bound-receipt" $ \dir -> do
        let path = dir </> "receipt.log"
        initializeBoundReceipt path verified
          `shouldReturn` Right BoundReceiptCreated
        initializeBoundReceipt path verified
          `shouldReturn` Right BoundReceiptAlreadyInitialized
        let header = mkReceiptHeader verified
        decodeReceiptHeader 65536 (encodeReceiptHeader header) `shouldBe` Right header
        reopened <-
          reopenBoundReceipt 8192 verified path
            :: IO (Either BoundReceiptRefusal (BoundReceiptReopen TestEntry))
        case reopened of
          Left err -> expectationFailure ("expected bound receipt, got " <> show err)
          Right ready -> do
            boundReopenHeader ready `shouldBe` header
            boundReopenFrames ready `shouldBe` []
            boundReopenOutcome ready `shouldBe` RecoveryComplete
    it "requires an exact path-and-header acknowledgement after durable receipt creation" $
      withSystemTempDirectory "prodbox-external-receipt-ack" $ \dir -> do
        canonicalTemporaryRoot <- canonicalizePath "/tmp"
        let canonicalArtifactPath =
              mustRight
                ( mkExternalArtifactPath
                    (canonicalTemporaryRoot </> "prodbox-export" </> "decommission-runner")
                )
            canonicalVerified =
              verifiedWith plan (verifierBindingOf canonicalArtifactPath artifact)
            receiptPath = mustRight (mkExternalReceiptPath (dir </> "receipt.log"))
            deletionRoot = mustRight (mkDeletionRootPath (dir </> "deleted-cluster"))
        durablePaths <-
          mustRight
            <$> validateExternalDurablePathsOnHost
              [deletionRoot]
              canonicalArtifactPath
              receiptPath
        prepared <- prepareExternalReceiptAcknowledgement durablePaths canonicalVerified
        pending <- case prepared of
          Left refusal -> expectationFailure ("expected receipt preparation, got " <> show refusal) >> fail "unreachable"
          Right value -> pure value
        pendingExternalReceiptPath pending `shouldBe` receiptPath
        acknowledgeExternalReceipt "ACK DECOMMISSION RECEIPT wrong" pending
          `shouldBe` Left ExternalReceiptAcknowledgementMismatch
        let literal = receiptAcknowledgementLiteral pending
            acknowledged = mustRight (acknowledgeExternalReceipt literal pending)
        acknowledgedExternalReceiptPath acknowledged `shouldBe` receiptPath
        acknowledgedExternalReceiptHeader acknowledged `shouldBe` mkReceiptHeader canonicalVerified
        initializeBoundReceipt (externalReceiptPath receiptPath) canonicalVerified
          `shouldReturn` Right BoundReceiptAlreadyInitialized
        let otherArtifactPath =
              mustRight
                ( mkExternalArtifactPath
                    (canonicalTemporaryRoot </> "prodbox-export" </> "other-artifact")
                )
        wrongPaths <-
          mustRight
            <$> validateExternalDurablePathsOnHost [deletionRoot] otherArtifactPath receiptPath
        prepareExternalReceiptAcknowledgement wrongPaths verified
          `shouldReturn` Left ExternalReceiptArtifactBindingMismatch
    it "keeps the header codec bounded and rejects malformed semantic fixtures" $ do
      let header = mkReceiptHeader verified
          encoded = encodeReceiptHeader header
          wire = headerWire header
      decodeReceiptHeader 1 encoded `shouldBe` Left ReceiptHeaderTooLarge
      decodeReceiptHeader 65536 "not-a-receipt-header" `shouldBe` Left ReceiptHeaderInvalid
      decodeReceiptHeader 65536 (encodeHeaderWire wire) `shouldBe` Right header
      decodeReceiptHeader 65536 (encodeHeaderWire (wire {wireVersion = 2}))
        `shouldBe` Left ReceiptHeaderUnsupportedVersion
      decodeReceiptHeader
        65536
        (encodeHeaderWire (wire {wireManifestDigest = FrameDigest "short"}))
        `shouldBe` Left ReceiptHeaderDigestInvalid
    it "refuses an absent, torn, or corrupt authenticated header without journal recovery" $
      withSystemTempDirectory "prodbox-bound-receipt-invalid-header" $ \dir -> do
        let path = dir </> "receipt.log"
        reopenBoundReceipt 8192 verified path
          `shouldReturn` (Left BoundReceiptAbsent :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry))
        ByteString.writeFile path "torn"
        reopenBoundReceipt 8192 verified path
          `shouldReturn` (Left BoundReceiptHeaderTorn :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry))
        ByteString.writeFile path (ByteString.replicate 128 0xFF)
        reopenBoundReceipt 8192 verified path
          `shouldReturn` ( Left (BoundReceiptHeaderCodecRefused ReceiptHeaderInvalid)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
    it "validates the whole bound chain before and after each durable append" $
      withSystemTempDirectory "prodbox-bound-receipt-append" $ \dir -> do
        let path = dir </> "receipt.log"
        _ <- initializeBoundReceipt path verified
        appendBoundReceiptFrame 8192 verified path boundFrame0
          `shouldReturn` Right (frameDigest boundFrame0)
        appendBoundReceiptFrame 8192 verified path boundFrame1
          `shouldReturn` Right (frameDigest boundFrame1)
        reopened <-
          reopenBoundReceipt 8192 verified path
            :: IO (Either BoundReceiptRefusal (BoundReceiptReopen TestEntry))
        fmap boundReopenFrames reopened `shouldBe` Right [boundFrame0, boundFrame1]
    it "truncates a torn frame relative to the authenticated header and resumes" $
      withSystemTempDirectory "prodbox-bound-receipt-torn" $ \dir -> do
        let path = dir </> "receipt.log"
        _ <- initializeBoundReceipt path verified
        _ <- appendBoundReceiptFrame 8192 verified path boundFrame0
        ByteString.appendFile path (ByteString.take 5 (encodeRecord boundFrame1))
        reopened <-
          reopenBoundReceipt 8192 verified path
            :: IO (Either BoundReceiptRefusal (BoundReceiptReopen TestEntry))
        case reopened of
          Left err -> expectationFailure ("expected torn-tail recovery, got " <> show err)
          Right ready -> do
            boundReopenOutcome ready `shouldBe` RecoveryTruncatableTorn
            boundReopenFrames ready `shouldBe` [boundFrame0]
            boundReopenTruncatedTo ready `shouldSatisfy` isJust
        appendBoundReceiptFrame 8192 verified path boundFrame1
          `shouldReturn` Right (frameDigest boundFrame1)
    it "refuses artifact/schema/new-manifest header drift before reading frames" $
      withSystemTempDirectory "prodbox-bound-receipt-drift" $ \dir -> do
        let path = dir </> "receipt.log"
        _ <- initializeBoundReceipt path verified
        reopenBoundReceipt 8192 artifactDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptArtifactDigestMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 schemaDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptManifestSchemaIdentityMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 otherPlanVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptPlanDigestMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 pathDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptArtifactPathMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 dependencyDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptDependencyIdentityMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 registryDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptInterpreterRegistryIdentityMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        reopenBoundReceipt 8192 signerDriftVerified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptManifestSignerMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
    it "refuses persisted signature or aggregate-manifest digest tampering" $
      withSystemTempDirectory "prodbox-bound-receipt-auth-drift" $ \dir -> do
        let path = dir </> "receipt.log"
            header = mkReceiptHeader verified
            wire = headerWire header
        _ <- initializeBoundReceipt path verified
        original <- ByteString.readFile path
        overwriteHeader
          path
          original
          header
          (encodeHeaderWire (wire {wireSignatureDigest = contentDigest "forged-signature"}))
        reopenBoundReceipt 8192 verified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptManifestSignatureMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
        ByteString.writeFile path original
        overwriteHeader
          path
          original
          header
          (encodeHeaderWire (wire {wireManifestDigest = contentDigest "forged-complete-manifest"}))
        reopenBoundReceipt 8192 verified path
          `shouldReturn` ( Left (BoundReceiptHeaderDrift ReceiptManifestDigestMismatch)
                             :: Either BoundReceiptRefusal (BoundReceiptReopen TestEntry)
                         )
    it "keeps the private signer seed and admin credentials out of the receipt header" $ do
      let encoded = encodeReceiptHeader (mkReceiptHeader verified)
      ByteString.isInfixOf signingSeed encoded `shouldBe` False
      ByteString.isInfixOf "AWS_SECRET_ACCESS_KEY=fixture-secret" encoded `shouldBe` False
 where
  manifest = FrameDigest "manifest-alpha"
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  frame0 = appendPayload manifest Nothing nodeId attemptId (TestIntent "destroy")
  frame1 = appendPayload manifest (Just frame0) nodeId attemptId (TestObservation "absent")
  frame2 = appendPayload manifest (Just frame1) nodeId attemptId (TestResult "done")
  chain = [frame0, frame1, frame2]
  reopen' path = reopenReceipt 8192 manifest path :: IO (ReceiptReopen TestEntry)
  dependencyBytes = "dependency closure v1"
  metadata = metadataWith 1
  metadataWith schemaVersion =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyBytes)
          schemaVersion
          (contentDigest ("manifest-schema-v" <> ByteString.singleton (fromIntegral schemaVersion)))
          1
          (contentDigest "interpreter-registry-v1")
      )
  artifact = mustRight (mkVerifierArtifact "runner-build-v1" dependencyBytes metadata)
  artifactPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")
  signingSeed = ByteString.pack [0 .. 31]
  signingKey = mustRight (mkManifestSigningKey signingSeed)
  plan = mustRight (mkDecommissionManifest "home" [SesProviderStack])
  otherPlan = mustRight (mkDecommissionManifest "other" [SesProviderStack])
  signed = signDecommissionManifest signingKey plan (verifierBindingOf artifactPath artifact)
  verified = mustRight (verifySignedDecommissionManifest signerDigest signed)
  signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)
  artifactDriftArtifact = mustRight (mkVerifierArtifact "runner-build-v2" dependencyBytes metadata)
  artifactDriftVerified =
    verifiedWith plan (verifierBindingOf artifactPath artifactDriftArtifact)
  schemaDriftArtifact =
    mustRight (mkVerifierArtifact "runner-build-v1" dependencyBytes (metadataWith 2))
  schemaDriftVerified =
    verifiedWith plan (verifierBindingOf artifactPath schemaDriftArtifact)
  pathDriftVerified =
    verifiedWith
      plan
      ( verifierBindingOf
          (mustRight (mkExternalArtifactPath "/tmp/prodbox-export/other-decommission-runner"))
          artifact
      )
  dependencyDriftBytes = "dependency closure v2"
  dependencyDriftMetadata =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyDriftBytes)
          1
          (contentDigest ("manifest-schema-v" <> ByteString.singleton 1))
          1
          (contentDigest "interpreter-registry-v1")
      )
  dependencyDriftArtifact =
    mustRight
      (mkVerifierArtifact "runner-build-v1" dependencyDriftBytes dependencyDriftMetadata)
  dependencyDriftVerified =
    verifiedWith plan (verifierBindingOf artifactPath dependencyDriftArtifact)
  registryDriftMetadata =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyBytes)
          1
          (contentDigest ("manifest-schema-v" <> ByteString.singleton 1))
          2
          (contentDigest "interpreter-registry-v2")
      )
  registryDriftArtifact =
    mustRight (mkVerifierArtifact "runner-build-v1" dependencyBytes registryDriftMetadata)
  registryDriftVerified =
    verifiedWith plan (verifierBindingOf artifactPath registryDriftArtifact)
  otherSigningKey = mustRight (mkManifestSigningKey (ByteString.pack [32 .. 63]))
  otherSignerDigest = manifestPublicKeyDigest (manifestSigningPublicKey otherSigningKey)
  signerDriftVerified =
    mustRight
      ( verifySignedDecommissionManifest
          otherSignerDigest
          (signDecommissionManifest otherSigningKey plan (verifierBindingOf artifactPath artifact))
      )
  otherPlanVerified = verifiedWith otherPlan (verifierBindingOf artifactPath artifact)
  verifiedWith manifestPlan binding =
    mustRight
      ( verifySignedDecommissionManifest
          signerDigest
          (signDecommissionManifest signingKey manifestPlan binding)
      )
  boundFrame0 =
    appendPayload
      (verifiedManifestDigest verified)
      Nothing
      nodeId
      attemptId
      (TestIntent "destroy")
  boundFrame1 =
    appendPayload
      (verifiedManifestDigest verified)
      (Just boundFrame0)
      nodeId
      attemptId
      (TestObservation "absent")

corruptFileByteAt :: FilePath -> Int -> IO ()
corruptFileByteAt path index = do
  bytes <- ByteString.readFile path
  let corrupted =
        ByteString.concat
          [ ByteString.take index bytes
          , ByteString.singleton (ByteString.index bytes index `xor` 0xFF)
          , ByteString.drop (index + 1) bytes
          ]
  ByteString.writeFile path corrupted

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id

headerWire :: ReceiptHeader -> ReceiptHeaderWire
headerWire header =
  ReceiptHeaderWire
    { wireVersion = 1
    , wireManifestDigest = receiptHeaderManifestDigest header
    , wirePlanDigest = receiptHeaderPlanDigest header
    , wireSignatureDigest = receiptHeaderSignatureDigest header
    , wireSignerDigest = receiptHeaderSignerDigest header
    , wireVerifierBinding = receiptHeaderVerifierBinding header
    }

encodeHeaderWire :: ReceiptHeaderWire -> ByteString.ByteString
encodeHeaderWire = LazyByteString.toStrict . serialise

overwriteHeader
  :: FilePath
  -> ByteString.ByteString
  -> ReceiptHeader
  -> ByteString.ByteString
  -> IO ()
overwriteHeader path original expected replacement = do
  let expectedBytes = encodeReceiptHeader expected
      prefixBytes = ByteString.length original - ByteString.length expectedBytes
  ByteString.length replacement `shouldBe` ByteString.length expectedBytes
  ByteString.writeFile path (ByteString.take prefixBytes original <> replacement)
