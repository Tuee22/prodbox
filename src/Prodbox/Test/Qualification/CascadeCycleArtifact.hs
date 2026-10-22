{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The artifact one qualification cycle writes, and the one codec that writes
-- and reads it.
--
-- Rendering and attestation live together so a writer and a reader cannot drift:
-- every identity-bearing line is explicit, and nothing is recovered by parsing
-- the @show@ of an abstract value. The self-digest on the last line detects an
-- accident, an edit or a reordering; it is not authentication, and a local
-- writer who rewrites the lines and the digest together is not stopped by it.
module Prodbox.Test.Qualification.CascadeCycleArtifact
  ( CycleLabel
  , CycleLabelError (..)
  , mkCycleLabel
  , cycleLabelText
  , CascadeArtifactFields (..)
  , ArtifactRenderError (..)
  , ArtifactFact (..)
  , ArtifactDefect (..)
  , cascadeArtifactFormatVersion
  , cascadeArtifactFileName
  , renderCascadeArtifact
  , attestCascadeArtifact
  , componentImageInventoryDigests
  )
where

import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CycleAnnotations (..)
  , CycleIdentityParts (..)
  , IdentityKey
  , identityKeyOfParts
  , identityKeyText
  , imageSetDigest
  , mkIdentityKey
  )
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , mkPublicEvidenceDigest
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceManifestPolicyIdentity (..)
  , WorktreeState (..)
  )

-- Cycle label ---------------------------------------------------------------------

-- | The stable name of a qualification cycle. It becomes part of cleanup run,
-- owner and permit identifiers and of an artifact file name, so it is restricted
-- to characters none of them needs to escape.
newtype CycleLabel = CycleLabel Text
  deriving stock (Eq, Ord, Show)

data CycleLabelError
  = CycleLabelEmpty
  | CycleLabelTooLong !Int
  | CycleLabelCharacterInvalid !Char
  deriving stock (Eq, Show)

mkCycleLabel :: Text -> Either CycleLabelError CycleLabel
mkCycleLabel raw
  | Text.null raw = Left CycleLabelEmpty
  | Text.length raw > cycleLabelMaximumLength = Left (CycleLabelTooLong (Text.length raw))
  | otherwise = case Text.find (not . validLabelCharacter) raw of
      Just character -> Left (CycleLabelCharacterInvalid character)
      Nothing -> Right (CycleLabel raw)
 where
  validLabelCharacter character =
    isAscii character
      && (isAsciiLower character || isAsciiUpper character || isDigit character)
      || character `elem` ("._-" :: String)

cycleLabelMaximumLength :: Int
cycleLabelMaximumLength = 64

cycleLabelText :: CycleLabel -> Text
cycleLabelText (CycleLabel value) = value

-- Fields and facts ------------------------------------------------------------------

cascadeArtifactFormatVersion :: Text
cascadeArtifactFormatVersion = "2"

-- | Everything a writer supplies. The frozen lines are the superseded-side and
-- counterexample facts, which the cycle runner owns; the codec carries them in
-- order and checks only that they do not collide with a line it owns.
data CascadeArtifactFields = CascadeArtifactFields
  { fieldsLabel :: !CycleLabel
  , fieldsAttempt :: !Int
  , fieldsCanonicalCommand :: !Text
  , fieldsStartedAt :: !Text
  , fieldsCompletedAt :: !Text
  , fieldsAwsAccount :: !Text
  , fieldsAwsRegion :: !Text
  , fieldsCleanupRunId :: !Text
  , fieldsParts :: !CycleIdentityParts
  , fieldsAnnotations :: !CycleAnnotations
  , fieldsComponentImages :: ![Text]
  -- ^ The observed inventory, one @component=sha256:hex@ per container.
  , fieldsRunScopedTopologyDigest :: !Text
  , fieldsRunScopedWiringDigest :: !Text
  -- ^ Provenance of this run's own plan. They name the run, so they differ
  -- between cycles and are never part of the identity.
  , fieldsInForceConfigDigest :: !Text
  , fieldsFrozenLines :: ![(Text, Text)]
  , fieldsAggregateSucceeded :: !Bool
  , fieldsResidueAbsent :: !Bool
  , fieldsLifecycleSucceeded :: !Bool
  , fieldsLifecycleResult :: !Text
  }

data ArtifactRenderError
  = ArtifactFrozenKeyInvalid !Text
  | ArtifactFrozenKeyCollides !Text
  deriving stock (Eq, Show)

-- | What an artifact says, after its self-digest, flags, inventory and identity
-- key have been checked against one another.
data ArtifactFact = ArtifactFact
  { factLabel :: !CycleLabel
  , factAttempt :: !Int
  , factEvidenceDigest :: !Text
  , factStartedAt :: !Text
  , factCompletedAt :: !Text
  , factAwsAccount :: !Text
  , factAwsRegion :: !Text
  , factCleanupRunId :: !Text
  , factParts :: !CycleIdentityParts
  , factKey :: !IdentityKey
  , factAnnotations :: !CycleAnnotations
  , factComponentImages :: ![Text]
  , factRunScopedTopologyDigest :: !Text
  , factRunScopedWiringDigest :: !Text
  , factInForceConfigDigest :: !Text
  , factSucceeded :: !Bool
  -- ^ The three success flags, which agree.
  , factLifecycleResult :: !Text
  , factFrozenLines :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

data ArtifactDefect
  = ArtifactFormatUnsupported !Text
  | ArtifactLineMissing !Text
  | ArtifactLineDuplicated !Text
  | ArtifactLineMalformed !Text
  | ArtifactDigestLineMismatch
  | ArtifactFlagsDisagree
  | ArtifactImageInventoryEmpty
  | ArtifactImageInventoryMismatch
  | ArtifactIdentityUnparsable !Text
  | ArtifactIdentityKeyDisagrees
  deriving stock (Eq, Show)

-- | One file per label. The name is a function of the label alone, so a later
-- attempt of a label replaces the earlier attempt's file, and a label that has
-- passed is never run again.
cascadeArtifactFileName :: CycleLabel -> FilePath
cascadeArtifactFileName label =
  "cascade-"
    ++ Text.unpack (Text.take 24 (publicEvidenceDigestText (hashPublicEvidence (cycleLabelText label))))
    ++ ".evidence"

-- Rendering -------------------------------------------------------------------------

-- | The artifact text and its evidence digest.
renderCascadeArtifact :: CascadeArtifactFields -> Either ArtifactRenderError (Text, Text)
renderCascadeArtifact fields = do
  mapM_ (checkFrozenKey . fst) (fieldsFrozenLines fields)
  let baseLines = identityLines ++ frozenLines ++ outcomeLines ++ imageLines
      digest = digestOfLines baseLines
  Right (Text.unlines (baseLines ++ ["evidence_digest=" <> digest]), digest)
 where
  parts = fieldsParts fields
  annotations = fieldsAnnotations fields
  policy = partsSourcePolicy parts
  label = cycleLabelText (fieldsLabel fields)
  line key value = key <> "=" <> escapeLine value
  digestLine key = line key . publicEvidenceDigestText

  identityLines =
    [ line "format_version" cascadeArtifactFormatVersion
    , line "qualification_kind" "typed-recover-to-clean-cascade"
    , line "cycle" label
    , line "attempt" (Text.pack (show (fieldsAttempt fields)))
    , line "control_plane_substrate" "home-local"
    , line "managed_target_substrate" "aws"
    , line "canonical_command" (fieldsCanonicalCommand fields)
    , line "started_at" (fieldsStartedAt fields)
    , line "completed_at" (fieldsCompletedAt fields)
    , line "aws_account" (fieldsAwsAccount fields)
    , line "aws_region" (fieldsAwsRegion fields)
    , line "cleanup_run_id" (fieldsCleanupRunId fields)
    , line "key_policy_digest" (partsKeyPolicyDigest parts)
    , line "identity_key" (identityKeyText (identityKeyOfParts parts))
    , line "replacement_source_manifest_digest" (partsSourceManifestDigest parts)
    , line "replacement_source_policy_identifier" (sourcePolicyIdentifier policy)
    , line "replacement_source_policy_version" (Text.pack (show (sourcePolicyVersion policy)))
    , line "replacement_source_policy_digest" (sourcePolicyDigest policy)
    , line "replacement_source_entry_count" (Text.pack (show (partsSourceEntryCount parts)))
    , line "replacement_git_provenance" (maybe "unkeyed" renderProvenance (partsGitProvenance parts))
    , digestLine "replacement_generated_config_digest" (partsGeneratedConfig parts)
    , line
        "replacement_component_image_inventory_digest"
        (publicEvidenceDigestText (inventoryDigest (fieldsComponentImages fields)))
    , line "replacement_component_image_set_digest" (imageSetDigest (partsComponentImages parts))
    , digestLine "replacement_topology_wiring_shape_digest" (partsTopologyWiring parts)
    , digestLine "replacement_resource_envelope_digest" (partsResourceEnvelope parts)
    , digestLine "replacement_load_fault_digest" (partsLoadFault parts)
    , digestLine "replacement_interpreter_digest" (partsInterpreter parts)
    , digestLine "replacement_persistence_digest" (partsPersistence parts)
    , digestLine "replacement_cleanup_schema_digest" (partsCleanupSchema parts)
    , line "run_scoped_topology_digest" (fieldsRunScopedTopologyDigest fields)
    , line "run_scoped_wiring_digest" (fieldsRunScopedWiringDigest fields)
    , line "in_force_config_digest" (fieldsInForceConfigDigest fields)
    , line "annotation_git_head" (annotationGitHead annotations)
    , line "annotation_worktree" (renderWorktree (annotationWorktree annotations))
    , line "annotation_full_manifest_digest" (annotationFullManifestDigest annotations)
    , line "annotation_full_entry_count" (Text.pack (show (annotationFullEntryCount annotations)))
    , line "annotation_binary_digest" (fromMaybe "unknown" (annotationBinaryDigest annotations))
    ]
  frozenLines = [line key value | (key, value) <- fieldsFrozenLines fields]
  outcomeLines =
    [ line "aggregate_succeeded" (renderBool (fieldsAggregateSucceeded fields))
    , line "cleanup_residue_absent" (renderBool (fieldsResidueAbsent fields))
    , line "lifecycle_succeeded" (renderBool (fieldsLifecycleSucceeded fields))
    , line "lifecycle_result" (fieldsLifecycleResult fields)
    ]
  imageLines = map (line "component_image") (fieldsComponentImages fields)

  checkFrozenKey key
    | Text.null key || not (Text.all validKeyCharacter key) = Left (ArtifactFrozenKeyInvalid key)
    | key `elem` codecOwnedKeys = Left (ArtifactFrozenKeyCollides key)
    | otherwise = Right ()

-- Attestation -----------------------------------------------------------------------

-- | Read an artifact back, checking that it is what its own digest, flags,
-- inventory and identity key say it is.
attestCascadeArtifact :: Text -> Either ArtifactDefect ArtifactFact
attestCascadeArtifact text = do
  let allLines = Text.lines text
  (body, recordedDigest) <- splitDigestLine allLines
  if digestOfLines body == recordedDigest
    then Right ()
    else Left ArtifactDigestLineMismatch
  pairs <- traverse splitPair body
  let single key = case [value | (name, value) <- pairs, name == key] of
        [value] -> Right value
        [] -> Left (ArtifactLineMissing key)
        _ -> Left (ArtifactLineDuplicated key)
      unparsable key = Left (ArtifactIdentityUnparsable key)
      digestAt key = do
        raw <- single key
        maybe (unparsable key) Right (mkPublicEvidenceDigest raw)
      naturalAt key = do
        raw <- single key
        maybe (unparsable key) Right (readNatural raw)
  version <- single "format_version"
  if version == cascadeArtifactFormatVersion
    then Right ()
    else Left (ArtifactFormatUnsupported version)
  labelText <- single "cycle"
  label <- either (const (unparsable "cycle")) Right (mkCycleLabel labelText)
  attempt <- naturalAt "attempt"
  policyVersion <- naturalAt "replacement_source_policy_version"
  entryCount <- naturalAt "replacement_source_entry_count"
  fullEntryCount <- naturalAt "annotation_full_entry_count"
  manifestDigest <- hexAt single "replacement_source_manifest_digest"
  policyDigest <- hexAt single "replacement_source_policy_digest"
  policyIdentifier <- single "replacement_source_policy_identifier"
  recordedPolicyDigest <- hexAt single "key_policy_digest"
  provenanceRaw <- single "replacement_git_provenance"
  provenance <- parseProvenance provenanceRaw
  generatedConfig <- digestAt "replacement_generated_config_digest"
  topologyWiring <- digestAt "replacement_topology_wiring_shape_digest"
  resourceEnvelope <- digestAt "replacement_resource_envelope_digest"
  loadFault <- digestAt "replacement_load_fault_digest"
  interpreter <- digestAt "replacement_interpreter_digest"
  persistence <- digestAt "replacement_persistence_digest"
  cleanupSchema <- digestAt "replacement_cleanup_schema_digest"
  gitHead <- single "annotation_git_head"
  worktree <- single "annotation_worktree" >>= parseWorktree
  fullManifestDigest <- hexAt single "annotation_full_manifest_digest"
  binaryRaw <- single "annotation_binary_digest"
  let inventory = [value | (name, value) <- pairs, name == "component_image"]
  images <- componentImageInventoryDigests inventory
  if null inventory then Left ArtifactImageInventoryEmpty else Right ()
  recordedInventoryDigest <- single "replacement_component_image_inventory_digest"
  recordedSetDigest <- single "replacement_component_image_set_digest"
  let imageSet = nub (sort images)
  if recordedInventoryDigest == publicEvidenceDigestText (inventoryDigest inventory)
    && recordedSetDigest == imageSetDigest imageSet
    then Right ()
    else Left ArtifactImageInventoryMismatch
  flags <- traverse (\key -> single key >>= parseBool key) flagKeys
  succeeded <- case nub flags of
    [flag] -> Right flag
    _ -> Left ArtifactFlagsDisagree
  let parts =
        CycleIdentityParts
          { partsKeyPolicyDigest = recordedPolicyDigest
          , partsSourceManifestDigest = manifestDigest
          , partsSourcePolicy =
              SourceManifestPolicyIdentity
                { sourcePolicyIdentifier = policyIdentifier
                , sourcePolicyVersion = fromIntegral policyVersion
                , sourcePolicyDigest = policyDigest
                }
          , partsSourceEntryCount = entryCount
          , partsGitProvenance = provenance
          , partsGeneratedConfig = generatedConfig
          , partsComponentImages = imageSet
          , partsTopologyWiring = topologyWiring
          , partsResourceEnvelope = resourceEnvelope
          , partsLoadFault = loadFault
          , partsInterpreter = interpreter
          , partsPersistence = persistence
          , partsCleanupSchema = cleanupSchema
          }
      key = identityKeyOfParts parts
  recordedKey <- single "identity_key" >>= maybe (unparsable "identity_key") Right . mkIdentityKey
  if recordedKey == key then Right () else Left ArtifactIdentityKeyDisagrees
  startedAt <- single "started_at"
  completedAt <- single "completed_at"
  awsAccount <- single "aws_account"
  awsRegion <- single "aws_region"
  runId <- single "cleanup_run_id"
  topologyRun <- single "run_scoped_topology_digest"
  wiringRun <- single "run_scoped_wiring_digest"
  inForce <- single "in_force_config_digest"
  lifecycleResult <- single "lifecycle_result"
  Right
    ArtifactFact
      { factLabel = label
      , factAttempt = attempt
      , factEvidenceDigest = recordedDigest
      , factStartedAt = startedAt
      , factCompletedAt = completedAt
      , factAwsAccount = awsAccount
      , factAwsRegion = awsRegion
      , factCleanupRunId = runId
      , factParts = parts
      , factKey = key
      , factAnnotations =
          CycleAnnotations
            { annotationGitHead = gitHead
            , annotationWorktree = worktree
            , annotationFullManifestDigest = fullManifestDigest
            , annotationFullEntryCount = fullEntryCount
            , annotationBinaryDigest = if binaryRaw == "unknown" then Nothing else Just binaryRaw
            }
      , factComponentImages = inventory
      , factRunScopedTopologyDigest = topologyRun
      , factRunScopedWiringDigest = wiringRun
      , factInForceConfigDigest = inForce
      , factSucceeded = succeeded
      , factLifecycleResult = lifecycleResult
      , factFrozenLines = [pair | pair@(name, _) <- pairs, name `notElem` codecOwnedKeys]
      }
 where
  splitDigestLine allLines = case reverse allLines of
    lastLine : earlier -> case Text.stripPrefix "evidence_digest=" lastLine of
      Just recorded
        | isHex64 recorded -> Right (reverse earlier, recorded)
        | otherwise -> Left (ArtifactLineMalformed "evidence_digest")
      Nothing -> Left (ArtifactLineMissing "evidence_digest")
    [] -> Left (ArtifactLineMissing "evidence_digest")
  splitPair rawLine = case Text.breakOn "=" rawLine of
    (key, rest)
      | Text.null key || Text.null rest -> Left (ArtifactLineMalformed (Text.take 40 rawLine))
      | otherwise -> Right (key, Text.drop 1 rest)
  hexAt single key = do
    raw <- single key
    if isHex64 raw then Right raw else Left (ArtifactIdentityUnparsable key)
  parseProvenance raw
    | raw == "unkeyed" = Right Nothing
    | otherwise = case Text.splitOn ":" raw of
        [gitHead, worktreeRaw] -> do
          worktree <- parseWorktree worktreeRaw
          Right (Just (gitHead, worktree))
        _ -> Left (ArtifactIdentityUnparsable "replacement_git_provenance")
  parseWorktree raw = case raw of
    "clean" -> Right WorktreeClean
    "dirty" -> Right WorktreeDirty
    _ -> Left (ArtifactIdentityUnparsable "annotation_worktree")
  parseBool key raw = case raw of
    "true" -> Right True
    "false" -> Right False
    _ -> Left (ArtifactIdentityUnparsable key)

-- Shared pieces ----------------------------------------------------------------------

-- | The keys the codec writes once each, in the order it writes them, plus the
-- repeated inventory key and the digest line. A frozen line may use none of them.
codecOwnedKeys :: [Text]
codecOwnedKeys =
  [ "format_version"
  , "qualification_kind"
  , "cycle"
  , "attempt"
  , "control_plane_substrate"
  , "managed_target_substrate"
  , "canonical_command"
  , "started_at"
  , "completed_at"
  , "aws_account"
  , "aws_region"
  , "cleanup_run_id"
  , "key_policy_digest"
  , "identity_key"
  , "replacement_source_manifest_digest"
  , "replacement_source_policy_identifier"
  , "replacement_source_policy_version"
  , "replacement_source_policy_digest"
  , "replacement_source_entry_count"
  , "replacement_git_provenance"
  , "replacement_generated_config_digest"
  , "replacement_component_image_inventory_digest"
  , "replacement_component_image_set_digest"
  , "replacement_topology_wiring_shape_digest"
  , "replacement_resource_envelope_digest"
  , "replacement_load_fault_digest"
  , "replacement_interpreter_digest"
  , "replacement_persistence_digest"
  , "replacement_cleanup_schema_digest"
  , "run_scoped_topology_digest"
  , "run_scoped_wiring_digest"
  , "in_force_config_digest"
  , "annotation_git_head"
  , "annotation_worktree"
  , "annotation_full_manifest_digest"
  , "annotation_full_entry_count"
  , "annotation_binary_digest"
  , "aggregate_succeeded"
  , "cleanup_residue_absent"
  , "lifecycle_succeeded"
  , "lifecycle_result"
  , "component_image"
  , "evidence_digest"
  ]

flagKeys :: [Text]
flagKeys = ["aggregate_succeeded", "cleanup_residue_absent", "lifecycle_succeeded"]

digestOfLines :: [Text] -> Text
digestOfLines = publicEvidenceDigestText . hashPublicEvidence . Text.unlines

-- | Shared decoder for the actual named, immutable component-image inventory.
-- Recovery preserves these lines; a digest set alone cannot recreate the names.
componentImageInventoryDigests :: [Text] -> Either ArtifactDefect [PublicEvidenceDigest]
componentImageInventoryDigests = traverse parseInventoryLine
 where
  parseInventoryLine rawLine = case Text.breakOn "=sha256:" rawLine of
    (component, rest)
      | not (Text.null component)
      , Just digestRaw <- Text.stripPrefix "=sha256:" rest
      , Just digest <- mkPublicEvidenceDigest digestRaw ->
          Right digest
    _ -> Left (ArtifactIdentityUnparsable "component_image")

inventoryDigest :: [Text] -> PublicEvidenceDigest
inventoryDigest = hashPublicEvidence . Text.unlines

escapeLine :: Text -> Text
escapeLine = Text.replace "\n" "\\n" . Text.replace "\r" "\\r"

renderBool :: Bool -> Text
renderBool value = if value then "true" else "false"

renderWorktree :: WorktreeState -> Text
renderWorktree worktree = case worktree of
  WorktreeClean -> "clean"
  WorktreeDirty -> "dirty"

renderProvenance :: (Text, WorktreeState) -> Text
renderProvenance (gitHead, worktree) = gitHead <> ":" <> renderWorktree worktree

validKeyCharacter :: Char -> Bool
validKeyCharacter character =
  isAsciiLower character || isDigit character || character == '_'

isHex64 :: Text -> Bool
isHex64 raw = Text.length raw == 64 && Text.all isLowerHex raw
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

-- | A natural number written in at most nine decimal digits, so it fits every
-- width it is read into.
readNatural :: Text -> Maybe Int
readNatural raw = case TextRead.decimal raw of
  Right (value, rest) | Text.null rest && Text.length raw <= 9 -> Just value
  _ -> Nothing
