{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 6.5: the artifact one qualification cycle writes, and the one codec
-- that writes and reads it.
--
-- The failure cases rebuild the self-digest after each edit, so a mutation is
-- judged by the check it targets and not by the digest it happened to break.
module CascadeCycleArtifactTests
  ( cascadeCycleArtifactSuite
  )
where

import CycleIdentityFixtures
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.CascadeCycleArtifact
import Prodbox.Test.Qualification.CascadeCycleIdentity
import Prodbox.Test.Qualification.Evidence (hashPublicEvidence, publicEvidenceDigestText)
import TestSupport

cascadeCycleArtifactSuite :: SuiteBuilder ()
cascadeCycleArtifactSuite =
  describe "Sprint 6.5 cascade cycle artifact" $ do
    labelCases
    roundTripCases
    defectCases
    frozenLineCases

labelCases :: SuiteBuilder ()
labelCases = do
  it "accepts a stable cycle name and refuses one no identifier can carry" $ do
    fmap cycleLabelText (mkCycleLabel "pre-1") `shouldBe` Right "pre-1"
    fmap cycleLabelText (mkCycleLabel "post.2_a") `shouldBe` Right "post.2_a"
    mkCycleLabel "" `shouldBe` Left CycleLabelEmpty
    mkCycleLabel (Text.replicate 65 "a") `shouldBe` Left (CycleLabelTooLong 65)
    mkCycleLabel "pre 1" `shouldBe` Left (CycleLabelCharacterInvalid ' ')
    mkCycleLabel "pre/1" `shouldBe` Left (CycleLabelCharacterInvalid '/')
    mkCycleLabel "pré" `shouldBe` Left (CycleLabelCharacterInvalid 'é')

  it "names the file from the label alone" $ do
    let name = cascadeArtifactFileName fixtureLabel
        expected = Text.unpack (Text.take 24 (publicEvidenceDigestText (hashPublicEvidence "pre-1")))
    name `shouldBe` ("cascade-" ++ expected ++ ".evidence")
    cascadeArtifactFileName (labelOf "pre-2") `shouldNotBe` name

roundTripCases :: SuiteBuilder ()
roundTripCases = do
  it "reads back exactly what it wrote" $ do
    (text, digest) <- rendered fixtureArtifactFields
    case attestCascadeArtifact text of
      Left defect -> expectationFailure ("a rendered artifact did not attest: " ++ show defect)
      Right fact -> do
        factLabel fact `shouldBe` fixtureLabel
        factAttempt fact `shouldBe` 1
        factEvidenceDigest fact `shouldBe` digest
        factParts fact `shouldBe` fixtureParts
        factKey fact `shouldBe` identityKeyOfParts fixtureParts
        factAnnotations fact `shouldBe` fixtureAnnotations
        factComponentImages fact `shouldBe` fixtureInventory
        factCleanupRunId fact `shouldBe` "cascade-qualification-pre-1"
        factAwsAccount fact `shouldBe` "111122223333"
        factSucceeded fact `shouldBe` True
        factLifecycleResult fact `shouldBe` "LifecycleCleanupSucceeded"

  it "collapses two containers over one image into one digest" $ do
    (text, _) <- rendered fixtureArtifactFields
    fmap (length . partsComponentImages . factParts) (attestCascadeArtifact text) `shouldBe` Right 2

  it "gives two cycles of one deployment one key although their own plans differ" $ do
    -- The defect this codec exists to remove: the run-scoped digests name the
    -- cycle, so they cannot be equal, and the key must not depend on them.
    (first, _) <- rendered fixtureArtifactFields
    (second, _) <- rendered (sameCycleUnderLabel "pre-2" fixtureArtifactFields)
    case (attestCascadeArtifact first, attestCascadeArtifact second) of
      (Right one, Right two) -> do
        factKey one `shouldBe` factKey two
        diffParts (factParts one) (factParts two) `shouldBe` []
        factRunScopedTopologyDigest one `shouldNotBe` factRunScopedTopologyDigest two
        factRunScopedWiringDigest one `shouldNotBe` factRunScopedWiringDigest two
        factLabel one `shouldNotBe` factLabel two
      other -> expectationFailure ("expected two attested artifacts, got " ++ show other)

  it "keeps the identity of a cycle that ran on a different deployment apart" $ do
    let otherDeployment =
          fixtureArtifactFields
            { fieldsParts = fixtureParts {partsGeneratedConfig = digestOf 'Z'}
            }
    (first, _) <- rendered fixtureArtifactFields
    (second, _) <- rendered otherDeployment
    case (attestCascadeArtifact first, attestCascadeArtifact second) of
      (Right one, Right two) -> do
        factKey one `shouldNotBe` factKey two
        diffParts (factParts one) (factParts two) `shouldBe` [ComponentGeneratedConfig]
      other -> expectationFailure ("expected two attested artifacts, got " ++ show other)

  it "keeps a line break in a value from breaking the artifact" $ do
    (text, _) <- rendered fixtureArtifactFields {fieldsLifecycleResult = "first\nsecond\rthird"}
    fmap factLifecycleResult (attestCascadeArtifact text) `shouldBe` Right "first\\nsecond\\rthird"

defectCases :: SuiteBuilder ()
defectCases = do
  it "refuses an edit it can detect from the digest alone" $ do
    (text, _) <- rendered fixtureArtifactFields
    -- Any changed byte, a reordering, a dropped line, and a missing digest line.
    attestCascadeArtifact (Text.replace "aws_account=111122223333" "aws_account=111122223334" text)
      `shouldBe` Left ArtifactDigestLineMismatch
    attestCascadeArtifact (reorderFirstTwoLines text) `shouldBe` Left ArtifactDigestLineMismatch
    attestCascadeArtifact
      (Text.unlines (filter (not . Text.isPrefixOf "aws_region=") (Text.lines text)))
      `shouldBe` Left ArtifactDigestLineMismatch
    attestCascadeArtifact (Text.unlines (init (Text.lines text)))
      `shouldBe` Left (ArtifactLineMissing "evidence_digest")
    attestCascadeArtifact (Text.replace (lastLine text) "evidence_digest=abc" text)
      `shouldBe` Left (ArtifactLineMalformed "evidence_digest")

  it "refuses an artifact written by another format" $ do
    (text, _) <- rendered fixtureArtifactFields
    attestCascadeArtifact (resealed (Text.replace "format_version=2" "format_version=1") text)
      `shouldBe` Left (ArtifactFormatUnsupported "1")

  it "refuses a missing, a duplicated and a malformed line, whatever the digest says" $ do
    (text, _) <- rendered fixtureArtifactFields
    attestCascadeArtifact (resealed (dropLines "aws_region=") text)
      `shouldBe` Left (ArtifactLineMissing "aws_region")
    attestCascadeArtifact (resealed (addLine "aws_region=again") text)
      `shouldBe` Left (ArtifactLineDuplicated "aws_region")
    attestCascadeArtifact (resealed (mapLine "attempt=" "attempt=one") text)
      `shouldBe` Left (ArtifactIdentityUnparsable "attempt")
    attestCascadeArtifact
      ( resealed
          (mapLine "replacement_generated_config_digest=" "replacement_generated_config_digest=short")
          text
      )
      `shouldBe` Left (ArtifactIdentityUnparsable "replacement_generated_config_digest")
    attestCascadeArtifact (resealed (addLine "no equals sign here") text)
      `shouldBe` Left (ArtifactLineMalformed "no equals sign here")

  it "refuses success flags that disagree" $ do
    (text, _) <- rendered fixtureArtifactFields
    attestCascadeArtifact
      (resealed (mapLine "cleanup_residue_absent=" "cleanup_residue_absent=false") text)
      `shouldBe` Left ArtifactFlagsDisagree
    attestCascadeArtifact (resealed (mapLine "lifecycle_succeeded=" "lifecycle_succeeded=maybe") text)
      `shouldBe` Left (ArtifactIdentityUnparsable "lifecycle_succeeded")

  it "refuses an inventory that is empty or that disagrees with the digests recorded for it" $ do
    (text, _) <- rendered fixtureArtifactFields
    attestCascadeArtifact (resealed (dropLines "component_image=") text)
      `shouldBe` Left ArtifactImageInventoryEmpty
    -- A swapped image digest, with the recorded inventory digest left alone.
    attestCascadeArtifact
      (resealed (Text.replace (Text.replicate 64 "a") (Text.replicate 64 "c")) text)
      `shouldBe` Left ArtifactImageInventoryMismatch
    attestCascadeArtifact
      (resealed (mapLine "component_image=gateway" "component_image=gateway=notadigest") text)
      `shouldBe` Left (ArtifactIdentityUnparsable "component_image")

  it "refuses an identity key that is not the key of the parts beside it" $ do
    (text, _) <- rendered fixtureArtifactFields
    attestCascadeArtifact
      (resealed (mapLine "identity_key=" ("identity_key=" <> Text.replicate 64 "0")) text)
      `shouldBe` Left ArtifactIdentityKeyDisagrees
    attestCascadeArtifact
      ( resealed
          (mapLine "replacement_load_fault_digest=" ("replacement_load_fault_digest=" <> Text.replicate 64 "0"))
          text
      )
      `shouldBe` Left ArtifactIdentityKeyDisagrees

frozenLineCases :: SuiteBuilder ()
frozenLineCases = do
  it "carries the runner's lines in order, repeated keys included" $ do
    (text, _) <- rendered fixtureArtifactFields
    fmap factFrozenLines (attestCascadeArtifact text)
      `shouldBe` Right (fieldsFrozenLines fixtureArtifactFields)

  it "refuses a runner line that would shadow a line the codec owns, or that has no valid key" $ do
    renderCascadeArtifact fixtureArtifactFields {fieldsFrozenLines = [("aws_region", "elsewhere")]}
      `shouldBe` Left (ArtifactFrozenKeyCollides "aws_region")
    renderCascadeArtifact fixtureArtifactFields {fieldsFrozenLines = [("evidence_digest", "x")]}
      `shouldBe` Left (ArtifactFrozenKeyCollides "evidence_digest")
    renderCascadeArtifact fixtureArtifactFields {fieldsFrozenLines = [("component_image", "x")]}
      `shouldBe` Left (ArtifactFrozenKeyCollides "component_image")
    renderCascadeArtifact fixtureArtifactFields {fieldsFrozenLines = [("Bad-Key", "x")]}
      `shouldBe` Left (ArtifactFrozenKeyInvalid "Bad-Key")
    renderCascadeArtifact fixtureArtifactFields {fieldsFrozenLines = [("", "x")]}
      `shouldBe` Left (ArtifactFrozenKeyInvalid "")

-- Helpers ----------------------------------------------------------------------

rendered :: CascadeArtifactFields -> IO (Text, Text)
rendered fields = case renderCascadeArtifact fields of
  Left err -> fail ("the fixture did not render: " ++ show err)
  Right pair -> pure pair

labelOf :: Text -> CycleLabel
labelOf raw = either (error . show) id (mkCycleLabel raw)

lastLine :: Text -> Text
lastLine = last . Text.lines

-- | Apply an edit to the body and seal the result again, so the digest is
-- correct and the edit is judged by the check it targets.
resealed :: (Text -> Text) -> Text -> Text
resealed edit original =
  let body = Text.unlines (init (Text.lines (edit original)))
      digest = publicEvidenceDigestText (hashPublicEvidence body)
   in body <> "evidence_digest=" <> digest <> "\n"

dropLines :: Text -> Text -> Text
dropLines prefix = Text.unlines . filter (not . Text.isPrefixOf prefix) . Text.lines

-- | Insert a line before the digest line.
addLine :: Text -> Text -> Text
addLine new text = Text.unlines (init (Text.lines text) ++ [new, lastLine text])

-- | Replace the first line that starts with a prefix, wholesale.
mapLine :: Text -> Text -> Text -> Text
mapLine prefix replacement = Text.unlines . go . Text.lines
 where
  go [] = []
  go (current : rest)
    | prefix `Text.isPrefixOf` current = replacement : rest
    | otherwise = current : go rest

reorderFirstTwoLines :: Text -> Text
reorderFirstTwoLines text = case Text.lines text of
  first : second : rest -> Text.unlines (second : first : rest)
  other -> Text.unlines other
