{-# LANGUAGE OverloadedStrings #-}

module QualificationFrozenCounterexample (qualificationFrozenCounterexampleSuite) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.FrozenCounterexample
import System.Directory (getCurrentDirectory)
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport (SuiteBuilder, describe, it)

qualificationFrozenCounterexampleSuite :: SuiteBuilder ()
qualificationFrozenCounterexampleSuite =
  describe "frozen LCPC-2026-07-11 counterexample" $ do
    it "binds the exact historical source and closes every signature only in the replacement" $ do
      repoRoot <- getCurrentDirectory
      images <- acceptedImages
      bindings <- acceptedBindings
      traceResult <- loadFrozenCounterexampleTrace repoRoot images bindings
      trace <- case traceResult of
        Left err -> fail (show err)
        Right value -> pure value
      let (supersededResults, replacementResults) = simulateFrozenCounterexample trace
          mechanisms = [minBound .. maxBound]
      map counterexampleResultMechanism supersededResults @?= mechanisms
      map counterexampleResultMechanism replacementResults @?= mechanisms
      map counterexampleResultDisposition supersededResults
        @?= replicate (length mechanisms) SupersededFailureObserved
      map counterexampleResultDisposition replacementResults
        @?= replicate (length mechanisms) ReplacementMechanismClosed
      frozenTraceDigest trace @?= frozenExpectedTraceDigest

    it "keeps the normalized superseded and replacement envelopes exactly equal" $
      case frozenTraceEnvelopeTotals of
        Left err -> fail (show err)
        Right (superseded, replacement) -> superseded @?= replacement

    it "accepts only complete OCI SHA-256 values and opaque secret bindings" $ do
      assertBool "short image digest refuses" (isLeft (mkFrozenComponentImage FrozenMinio "sha256:abc"))
      assertBool "raw public secret hash cannot impersonate a receipt" $
        isLeft (mkAuthorityReceiptBinding ("receipt-" <> replicateText 64 "a"))
      assertBool "untyped HMAC refuses" (isLeft (mkVaultHmacBinding (replicateText 64 "a")))

    it "rejects a complete but different component-image inventory" $ do
      repoRoot <- getCurrentDirectory
      bindings <- acceptedBindings
      altered <- acceptedImage FrozenProdboxRuntime (replicateText 64 "f")
      result <- loadFrozenCounterexampleTrace repoRoot (altered : drop 1 frozenExpectedImages) bindings
      assertBool "unrelated OCI identity refuses" (isLeft result)

    it "rejects a validly shaped but relabelled opaque fixture binding" $ do
      repoRoot <- getCurrentDirectory
      receipt <- accepted (mkAuthorityReceiptBinding "receipt-frozen-run-0002")
      generation <- accepted (mkAuthorityGenerationBinding "generation-frozen-run-0001")
      result <- loadFrozenCounterexampleTrace repoRoot frozenExpectedImages [receipt, generation]
      assertBool "opaque binding relabel refuses" (isLeft result)

acceptedImages :: IO [FrozenComponentImage]
acceptedImages = pure frozenExpectedImages

acceptedImage :: FrozenComponent -> Text -> IO FrozenComponentImage
acceptedImage component digest =
  case mkFrozenComponentImage component ("sha256:" <> digest) of
    Left err -> fail (show err)
    Right value -> pure value

acceptedBindings :: IO [OpaqueFixtureBinding]
acceptedBindings = do
  receipt <- accepted (mkAuthorityReceiptBinding "receipt-frozen-run-0001")
  generation <- accepted (mkAuthorityGenerationBinding "generation-frozen-run-0001")
  pure [receipt, generation]

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value

replicateText :: Int -> Text -> Text
replicateText count value = Text.concat (replicate count value)
