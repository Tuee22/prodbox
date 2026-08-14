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
      traceResult <- loadFrozenCounterexampleTrace repoRoot CanonicalFrozenTrace images bindings
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

    it "Sprint 5.32: the simulator consumes its trace rather than a composition constant" $ do
      -- The mutation exercise as a unit case: the committed mutation fixture
      -- records the superseded implementation as having CLOSED
      -- `GatewayDeadlineUnderThrottle` rather than failed on it. Before Sprint
      -- 5.32 `simulateFrozenCounterexample` discarded its argument, so this
      -- trace and the canonical one produced identical output.
      repoRoot <- getCurrentDirectory
      bindings <- acceptedBindings
      mutatedResult <-
        loadFrozenCounterexampleTrace repoRoot MutatedFrozenTrace frozenExpectedImages bindings
      mutated <- case mutatedResult of
        Left err -> fail ("mutation fixture must load so its dispositions decide: " ++ show err)
        Right value -> pure value
      canonicalResult <-
        loadFrozenCounterexampleTrace repoRoot CanonicalFrozenTrace frozenExpectedImages bindings
      canonical <- case canonicalResult of
        Left err -> fail (show err)
        Right value -> pure value
      let (mutatedSuperseded, _) = simulateFrozenCounterexample mutated
          (canonicalSuperseded, _) = simulateFrozenCounterexample canonical
      assertBool
        "the two fixtures must not produce the same superseded dispositions"
        (mutatedSuperseded /= canonicalSuperseded)
      map counterexampleResultDisposition mutatedSuperseded
        @?= [ SupersededFailureObserved
            , ReplacementMechanismClosed
            , SupersededFailureObserved
            , SupersededFailureObserved
            , SupersededFailureObserved
            ]
      -- The digest binds the canonical dispositions, so the two traces differ
      -- in identity as well as in content.
      assertBool
        "the mutated trace digest differs from the canonical one"
        (frozenTraceDigest mutated /= frozenTraceDigest canonical)

    it "Sprint 5.32: the disposition parser is total over the mechanism enumeration" $ do
      let mechanisms = [minBound .. maxBound] :: [CounterexampleMechanism]
          canonicalRows =
            Text.unlines
              [ Text.pack (show mechanism) <> " superseded-failure-observed replacement-mechanism-closed"
              | mechanism <- mechanisms
              ]
      case parseFrozenDispositions canonicalRows of
        Left err -> fail (show err)
        Right rows -> map frozenMechanism rows @?= mechanisms
      assertBool
        "a missing mechanism refuses"
        (isLeft (parseFrozenDispositions (Text.unlines (drop 1 (Text.lines canonicalRows)))))
      assertBool
        "a duplicated mechanism refuses"
        (isLeft (parseFrozenDispositions (canonicalRows <> Text.unlines (take 1 (Text.lines canonicalRows)))))
      assertBool
        "an unknown mechanism name refuses"
        ( isLeft
            ( parseFrozenDispositions
                (canonicalRows <> "NoSuchMechanism superseded-failure-observed replacement-mechanism-closed\n")
            )
        )
      assertBool
        "an unknown disposition name refuses"
        ( isLeft
            ( parseFrozenDispositions
                (Text.unlines (drop 1 (Text.lines canonicalRows)) <> "AbsentGetAuthorityCasMismatch yes no\n")
            )
        )
      assertBool
        "a malformed row refuses"
        (isLeft (parseFrozenDispositions "AbsentGetAuthorityCasMismatch superseded-failure-observed\n"))

    it "Sprint 5.32: comments and blank lines are ignored, and row order does not change the digest" $ do
      let mechanisms = [minBound .. maxBound] :: [CounterexampleMechanism]
          row mechanism =
            Text.pack (show mechanism) <> "  superseded-failure-observed  replacement-mechanism-closed"
          shuffled =
            Text.unlines
              ( ["# a comment", ""]
                  ++ reverse (map row mechanisms)
                  ++ ["   ", "# trailing comment"]
              )
      case parseFrozenDispositions shuffled of
        Left err -> fail (show err)
        Right rows -> do
          map frozenMechanism rows @?= mechanisms
          map renderFrozenDisposition rows
            @?= [ Text.pack (show mechanism)
                    <> " superseded-failure-observed replacement-mechanism-closed"
                | mechanism <- mechanisms
                ]

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
      result <-
        loadFrozenCounterexampleTrace
          repoRoot
          CanonicalFrozenTrace
          (altered : drop 1 frozenExpectedImages)
          bindings
      assertBool "unrelated OCI identity refuses" (isLeft result)

    it "rejects a validly shaped but relabelled opaque fixture binding" $ do
      repoRoot <- getCurrentDirectory
      receipt <- accepted (mkAuthorityReceiptBinding "receipt-frozen-run-0002")
      generation <- accepted (mkAuthorityGenerationBinding "generation-frozen-run-0001")
      result <-
        loadFrozenCounterexampleTrace
          repoRoot
          CanonicalFrozenTrace
          frozenExpectedImages
          [receipt, generation]
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
