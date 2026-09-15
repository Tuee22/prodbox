{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.99: the canonical provider-evidence codec, on its own.
--
-- These cases are deliberately about the codec rather than about any family
-- that uses it. The six families each authored their own wire format and none
-- of them had a test like this, which is why none of them noticed that the
-- value they produced could not cross the boundary they produced it for.
module ProviderEvidenceCodec
  ( providerEvidenceCodecSuite
  )
where

import Control.Monad (forM_)
import Data.Text qualified as Text
import Prodbox.Lifecycle.ProviderWorker.Evidence
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentEvidenceBound
  , registeredEvidenceFamilies
  )
import TestSupport

family :: ProviderEvidenceFamily
family = providerEvidenceFamily "prodbox-witness-family" 8 64

-- | A bound wide enough that only the codec's own rules can refuse.
wideBound :: ProviderEvidenceBound
wideBound = providerIntentEvidenceBound ObserveProviderAwsScope

providerEvidenceCodecSuite :: SuiteBuilder ()
providerEvidenceCodecSuite =
  describe "Sprint 4.99 canonical provider-evidence codec" $ do
    it "round-trips rows through one renderer and one parser" $ do
      let rows = [["arn:aws:iam::123456789012:role/alpha", "role"], ["zone-1", "hosted-zone"]]
      encoded <- expectRight (encodeProviderEvidence wideBound family rows)
      decodeProviderEvidence family encoded `shouldBe` Right rows

    it "states absence rather than implying it from an empty row set" $ do
      encoded <- expectRight (encodeProviderEvidence wideBound family [])
      providerEvidenceText encoded `shouldBe` "prodbox-witness-family/v2:absent"
      decodeProviderEvidence family encoded `shouldBe` Right []
      -- A present arm carrying nothing is a different claim, and it is refused.
      -- A short listing and a listing of nothing are not the same fact.
      fromWire "prodbox-witness-family/v2:present:" `shouldSatisfy` refusedBy isEmptyRowSet

    it "renders one observation as exactly one string" $ do
      -- Canonicality is what makes the Authority's byte-equality replay
      -- comparison safe.  Two orderings of the same observation must not be two
      -- different retained values.
      let ordered = [["a"], ["b"], ["c"]]
          shuffled = [["c"], ["a"], ["b"]]
          duplicated = [["b"], ["a"], ["b"], ["c"]]
      first <- expectRight (encodeProviderEvidence wideBound family ordered)
      second <- expectRight (encodeProviderEvidence wideBound family shuffled)
      third <- expectRight (encodeProviderEvidence wideBound family duplicated)
      providerEvidenceText first `shouldBe` providerEvidenceText second
      providerEvidenceText first `shouldBe` providerEvidenceText third
      -- ...and bytes that are not canonical are refused rather than sorted on
      -- the way in, because silently re-ordering would hide the drift.
      fromWire "prodbox-witness-family/v2:present:c,a" `shouldSatisfy` refusedBy isNotCanonical

    it "admits every field an AWS tag can legally carry" $ do
      -- The terminal audit carries arbitrary tag text, in which the two
      -- separators and the escape character are all legal.  This is the case
      -- the closed-alphabet families never needed and the audit always did.
      let awkward = [["a,b", "c|d"], ["e%f", "plain"]]
      encoded <- expectRight (encodeProviderEvidence wideBound family awkward)
      providerEvidenceText encoded
        `shouldBe` "prodbox-witness-family/v2:present:a%2Cb|c%7Cd,e%25f|plain"
      decodeProviderEvidence family encoded `shouldBe` Right awkward

    it "refuses a control character at the encoder rather than at the wire" $ do
      encodeProviderEvidence wideBound family [["line\nbreak"]]
        `shouldBe` Left ProviderEvidenceControlCharacter
      encodeProviderEvidence wideBound family [["tab\tseparated"]]
        `shouldBe` Left ProviderEvidenceControlCharacter
      -- This is the whole defect, in one assertion: the superseded encoders
      -- produced exactly these values and nothing told them until a cluster
      -- refused the result.
      fromWire "prodbox-witness-family/v2:present:line\nbreak"
        `shouldBe` Left ProviderEvidenceControlCharacter

    it "refuses a listing over its declared cardinality" $ do
      let tooMany = [[Text.pack (show n)] | n <- [1 :: Int .. 9]]
      encodeProviderEvidence wideBound family tooMany
        `shouldBe` Left (ProviderEvidenceOverCardinality 9 8)

    it "refuses a retired version by name" $ do
      let retired = "prodbox-witness-family/v1:present:alpha"
      case decodeProviderEvidence family (unsafeWire retired) of
        Left (ProviderEvidenceRetiredVersion found expected) -> do
          found `shouldBe` "v1"
          expected `shouldBe` providerEvidenceVersion
          renderProviderEvidenceRefusal (ProviderEvidenceRetiredVersion found expected)
            `shouldSatisfy` Text.isInfixOf "retired"
        other -> expectationFailure ("a retired version decoded as " <> show other)

    it "derives a family's character bound from its cardinality" $ do
      -- The rule this codec exists to establish: a family states how much it
      -- can carry, and the length follows.  The superseded native-family
      -- encoder authored 128 KiB beside a wire that carries 4,096 characters,
      -- and nothing compared the two numbers.
      let header = Text.length "prodbox-witness-family/v2:present:"
      providerEvidenceFamilyBound family `shouldBe` (header + (8 * 64) + 7)
      let singleRowBound = Text.length "p/v2:present:" + 10
      providerEvidenceFamilyBound (providerEvidenceFamily "p" 1 10)
        `shouldBe` singleRowBound

    it "declares no family that cannot fit the wire it is answered on" $ do
      -- This is the assertion the superseded encoders needed and none had.  The
      -- native-family encoder declared a 128 KiB byte maximum and a
      -- 4,096-identity maximum beside a wire carrying 4,096 characters; the two
      -- were mutually unreachable as well as both wrong, and nothing compared
      -- them to the bound that actually applied.
      let sharedBound = providerIntentEvidenceBound ObserveProviderAwsScope
      forM_ registeredEvidenceFamilies $ \declared ->
        providerEvidenceFamilyBound declared
          `shouldSatisfy` fitsWithin sharedBound

    it "keeps the superseded refusal wording greppable" $ do
      -- A live transcript already contains these three sentences.  Changing
      -- them would retire evidence this campaign still reads.
      renderProviderEvidenceRefusal ProviderEvidenceEmpty
        `shouldBe` "the provider returned no evidence"
      renderProviderEvidenceRefusal (ProviderEvidenceOverBound 4649 4096)
        `shouldBe` "provider evidence is 4649 characters, over the maximum of 4096"
      renderProviderEvidenceRefusal ProviderEvidenceControlCharacter
        `shouldBe` "provider evidence carries a control character"
 where
  fromWire value = providerEvidenceFromWire wideBound value >>= decodeProviderEvidence family
  -- A family fits when a full listing still renders inside the intent bound.
  fitsWithin bound declaredBound =
    case providerEvidenceFromWire bound (Text.replicate declaredBound "x") of
      Right _ -> True
      Left _ -> False
  unsafeWire value = case providerEvidenceFromWire wideBound value of
    Right evidence -> evidence
    Left refusal -> error ("fixture refused: " <> show refusal)
  refusedBy predicate result = case result of
    Left refusal -> predicate refusal
    Right _ -> False
  isEmptyRowSet refusal = case refusal of
    ProviderEvidenceEmptyRowSet _ -> True
    _ -> False
  isNotCanonical refusal = case refusal of
    ProviderEvidenceNotCanonical _ -> True
    _ -> False

expectRight :: (Show refusal) => Either refusal value -> IO value
expectRight result = case result of
  Right value -> pure value
  Left refusal -> fail ("unexpected refusal: " <> show refusal)
