{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Prodbox.Registry.Retention
  ( RegistryAccessMode (..)
  , RegistryGarbageCollectionEvidence
  , RegistryGarbageCollectionError (..)
  , RegistryManifestMediaType (..)
  , RegistryReferenceObservationError (..)
  , RegistryReferenceSnapshot
  , RegistryRepositoryReferences (..)
  , RegistryTagReference (..)
  , decodeRegistryCatalogPage
  , decodeRegistryManifestHeaders
  , decodeRegistryTagsPage
  , mkRegistryReferenceSnapshot
  , registryManifestAcceptHeader
  , registryReferencePageLimit
  , renderRegistryAccessMode
  , renderRegistryGarbageCollectionError
  , renderRegistryReferenceObservationError
  , selectUntaggedManifestDigests
  , validateRegistryGarbageCollectionResult
  , validateRegistryGarbageCollectionReplay
  , validateRegistryReferenceReadBack
  )
where

import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, isSpace, toLower)
import Data.Foldable (traverse_)
import Data.List (sort, sortOn, stripPrefix)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

data RegistryAccessMode
  = RegistryReadWrite
  | RegistryReadOnly
  deriving (Eq, Show)

renderRegistryAccessMode :: RegistryAccessMode -> String
renderRegistryAccessMode mode = case mode of
  RegistryReadWrite -> "read-write"
  RegistryReadOnly -> "read-only"

data RegistryManifestMediaType
  = RegistryDockerV2Manifest
  | RegistryOciV1Manifest
  deriving (Eq, Ord, Show)

data RegistryTagReference = RegistryTagReference
  { registryTagReferenceName :: String
  , registryTagReferenceDigest :: String
  , registryTagReferenceMediaType :: RegistryManifestMediaType
  }
  deriving (Eq, Ord, Show)

data RegistryRepositoryReferences = RegistryRepositoryReferences
  { registryReferenceRepository :: String
  , registryReferenceTags :: [RegistryTagReference]
  }
  deriving (Eq, Ord, Show)

newtype RegistryReferenceSnapshot = RegistryReferenceSnapshot
  { registryReferenceRepositories :: [RegistryRepositoryReferences]
  }
  deriving (Eq, Show)

data RegistryReferenceObservationError
  = RegistryReferenceJsonInvalid
  | RegistryReferenceShapeInvalid
  | RegistryReferencePageIncomplete
  | RegistryReferenceRepositoryInvalid
  | RegistryReferenceTagInvalid
  | RegistryReferenceDuplicateRepository
  | RegistryReferenceDuplicateTag
  | RegistryReferenceDigestInvalid
  | RegistryReferenceHeaderMissing
  | RegistryReferenceHeaderAmbiguous
  | RegistryReferenceMediaTypeUnsupported
  | RegistryReferenceRevisionDuplicate
  | RegistryReferenceReadBackChanged
  deriving (Eq, Show)

data RegistryGarbageCollectionError
  = RegistryGarbageCollectionProcessFailed
  | RegistryGarbageCollectionStderrObserved
  | RegistryGarbageCollectionManifestEvidenceInvalid
  | RegistryGarbageCollectionManifestEvidenceChanged
  | RegistryGarbageCollectionReplayChanged
  deriving (Eq, Show)

data RegistryGarbageCollectionEvidence = RegistryGarbageCollectionEvidence
  { registryGarbageCollectionRepositories :: !(Set.Set String)
  , registryGarbageCollectionMarkedManifests :: !(Set.Set (String, String))
  , registryGarbageCollectionMarkedBlobs :: !(Set.Set (String, String))
  , registryGarbageCollectionEligibleManifests :: !(Set.Set (String, String))
  , registryGarbageCollectionEligibleBlobs :: !(Set.Set String)
  }
  deriving (Eq, Show)

data RegistryGarbageCollectionAccumulator = RegistryGarbageCollectionAccumulator
  { accumulatedRepositories :: ![String]
  , accumulatedMarkedManifests :: ![(String, String)]
  , accumulatedMarkedBlobs :: ![(String, String)]
  , accumulatedEligibleManifests :: ![(String, String)]
  }

data RegistryGarbageCollectionSummary = RegistryGarbageCollectionSummary
  { summarizedMarkedBlobs :: !Int
  , summarizedEligibleBlobs :: !Int
  , summarizedEligibleManifests :: !Int
  }

renderRegistryGarbageCollectionError :: RegistryGarbageCollectionError -> String
renderRegistryGarbageCollectionError err = case err of
  RegistryGarbageCollectionProcessFailed -> "registry collector process failed"
  RegistryGarbageCollectionStderrObserved -> "registry collector wrote to stderr"
  RegistryGarbageCollectionManifestEvidenceInvalid ->
    "registry collector emitted malformed collection evidence"
  RegistryGarbageCollectionManifestEvidenceChanged ->
    "registry collector manifest-mark evidence differs from the current-reference snapshot"
  RegistryGarbageCollectionReplayChanged ->
    "registry collector delete evidence differs from its read-only dry run"

renderRegistryReferenceObservationError :: RegistryReferenceObservationError -> String
renderRegistryReferenceObservationError err = case err of
  RegistryReferenceJsonInvalid -> "registry response is not valid JSON"
  RegistryReferenceShapeInvalid -> "registry response has an unexpected shape"
  RegistryReferencePageIncomplete -> "registry reference page reached its closed page limit"
  RegistryReferenceRepositoryInvalid -> "registry response contains an invalid repository name"
  RegistryReferenceTagInvalid -> "registry response contains an invalid tag"
  RegistryReferenceDuplicateRepository -> "registry response contains a duplicate repository"
  RegistryReferenceDuplicateTag -> "registry response contains a duplicate repository tag"
  RegistryReferenceDigestInvalid -> "registry response contains a noncanonical manifest digest"
  RegistryReferenceHeaderMissing -> "registry manifest response is missing a required header"
  RegistryReferenceHeaderAmbiguous -> "registry manifest response repeats a required header"
  RegistryReferenceMediaTypeUnsupported -> "registry tag resolves to an unsupported manifest media type"
  RegistryReferenceRevisionDuplicate -> "registry revision inventory contains a duplicate manifest digest"
  RegistryReferenceReadBackChanged -> "registry current-reference read-back changed across retention"

registryReferencePageLimit :: Int
registryReferencePageLimit = 1000

registryManifestAcceptHeader :: String
registryManifestAcceptHeader =
  "application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"

decodeRegistryCatalogPage
  :: String -> Either RegistryReferenceObservationError [String]
decodeRegistryCatalogPage body = do
  value <- maybe (Left RegistryReferenceJsonInvalid) Right (decodeStrict' (BS8.pack body))
  repositories <- stringArrayField "repositories" value
  validateCompletePage repositories
  traverse_ validateRepository repositories
  requireDistinct RegistryReferenceDuplicateRepository repositories
  pure (sort repositories)

decodeRegistryTagsPage
  :: String -> String -> Either RegistryReferenceObservationError [String]
decodeRegistryTagsPage expectedRepository body = do
  value <- maybe (Left RegistryReferenceJsonInvalid) Right (decodeStrict' (BS8.pack body))
  (repository, tags) <- case value of
    Object fields -> do
      repository <- stringField "name" fields
      tags <- case KeyMap.lookup (Key.fromString "tags") fields of
        Just Null -> Right []
        Just (Array values) -> traverse stringValue (Vector.toList values)
        _ -> Left RegistryReferenceShapeInvalid
      Right (repository, tags)
    _ -> Left RegistryReferenceShapeInvalid
  if repository == expectedRepository
    then Right ()
    else Left RegistryReferenceShapeInvalid
  _ <- validateRepository repository
  validateCompletePage tags
  traverse_ validateTag tags
  requireDistinct RegistryReferenceDuplicateTag tags
  pure (sort tags)

decodeRegistryManifestHeaders
  :: String
  -> Either
       RegistryReferenceObservationError
       (String, RegistryManifestMediaType)
decodeRegistryManifestHeaders response = do
  digest <- uniqueHeader "docker-content-digest" response
  if isCanonicalSha256Digest digest
    then Right ()
    else Left RegistryReferenceDigestInvalid
  rawMediaType <- uniqueHeader "content-type" response
  mediaType <- case trim (takeWhile (/= ';') rawMediaType) of
    "application/vnd.docker.distribution.manifest.v2+json" -> Right RegistryDockerV2Manifest
    "application/vnd.oci.image.manifest.v1+json" -> Right RegistryOciV1Manifest
    _ -> Left RegistryReferenceMediaTypeUnsupported
  pure (digest, mediaType)

mkRegistryReferenceSnapshot
  :: [RegistryRepositoryReferences]
  -> Either RegistryReferenceObservationError RegistryReferenceSnapshot
mkRegistryReferenceSnapshot repositories = do
  let sortedRepositories = sortOn registryReferenceRepository repositories
      repositoryNames = map registryReferenceRepository sortedRepositories
  traverse_ validateRepository repositoryNames
  requireDistinct RegistryReferenceDuplicateRepository repositoryNames
  normalized <- traverse normalizeRepository sortedRepositories
  pure (RegistryReferenceSnapshot normalized)
 where
  normalizeRepository repository = do
    let tags = sortOn registryTagReferenceName (registryReferenceTags repository)
        tagNames = map registryTagReferenceName tags
    traverse_ validateTag tagNames
    requireDistinct RegistryReferenceDuplicateTag tagNames
    traverse_ validateReference tags
    pure repository {registryReferenceTags = tags}

  validateReference reference =
    if isCanonicalSha256Digest (registryTagReferenceDigest reference)
      then Right ()
      else Left RegistryReferenceDigestInvalid

validateRegistryReferenceReadBack
  :: RegistryReferenceSnapshot
  -> RegistryReferenceSnapshot
  -> Either RegistryReferenceObservationError ()
validateRegistryReferenceReadBack before after =
  if before == after
    then Right ()
    else Left RegistryReferenceReadBackChanged

-- | Validate the process boundary separately from the post-collection API
-- read-back. The pinned Distribution CLI returns exit zero for usage errors,
-- so exit status alone cannot prove that the collector ran. The command-local
-- error log level makes an accepted collection write evidence only to stdout;
-- that evidence includes one manifest-mark record for each distinct current
-- repository/digest pair observed before the read-only fence.
validateRegistryGarbageCollectionResult
  :: RegistryReferenceSnapshot
  -> ExitCode
  -> String
  -> String
  -> Either RegistryGarbageCollectionError RegistryGarbageCollectionEvidence
validateRegistryGarbageCollectionResult snapshot exitCode stdoutText stderrText = do
  case exitCode of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left RegistryGarbageCollectionProcessFailed
  if null stderrText
    then Right ()
    else Left RegistryGarbageCollectionStderrObserved
  evidence <- parseRegistryGarbageCollectionStdout stdoutText
  if registryGarbageCollectionRepositories evidence == expectedRepositories
    && registryGarbageCollectionMarkedManifests evidence == expectedMarkers
    then Right evidence
    else Left RegistryGarbageCollectionManifestEvidenceChanged
 where
  expectedRepositories =
    Set.fromList (map registryReferenceRepository (registryReferenceRepositories snapshot))
  expectedMarkers =
    Set.fromList
      [ (registryReferenceRepository repository, registryTagReferenceDigest reference)
      | repository <- registryReferenceRepositories snapshot
      , reference <- registryReferenceTags repository
      ]

validateRegistryGarbageCollectionReplay
  :: RegistryGarbageCollectionEvidence
  -> RegistryGarbageCollectionEvidence
  -> Either RegistryGarbageCollectionError ()
validateRegistryGarbageCollectionReplay dryRunEvidence deleteEvidence =
  if dryRunEvidence == deleteEvidence
    then Right ()
    else Left RegistryGarbageCollectionReplayChanged

parseRegistryGarbageCollectionStdout
  :: String
  -> Either RegistryGarbageCollectionError RegistryGarbageCollectionEvidence
parseRegistryGarbageCollectionStdout stdoutText
  | null stdoutText || last stdoutText /= '\n' = invalidGarbageCollectionEvidence
  | otherwise =
      parseMarkPhase
        Nothing
        RegistryGarbageCollectionAccumulator
          { accumulatedRepositories = []
          , accumulatedMarkedManifests = []
          , accumulatedMarkedBlobs = []
          , accumulatedEligibleManifests = []
          }
        (lines stdoutText)

parseMarkPhase
  :: Maybe String
  -> RegistryGarbageCollectionAccumulator
  -> [String]
  -> Either RegistryGarbageCollectionError RegistryGarbageCollectionEvidence
parseMarkPhase _ _ [] = invalidGarbageCollectionEvidence
parseMarkPhase _ accumulator ("" : summaryLine : sweepLines) = do
  summary <- parseGarbageCollectionSummary summaryLine
  eligibleBlobs <- traverse parseEligibleBlobLine sweepLines
  finalizeGarbageCollectionEvidence accumulator summary eligibleBlobs
parseMarkPhase _ _ ("" : _) = invalidGarbageCollectionEvidence
parseMarkPhase currentRepository accumulator (line : remaining) =
  case exactDigestAfter "manifest eligible for deletion: " line of
    Just digest ->
      withCurrentRepository $ \repository ->
        continue
          currentRepository
          accumulator
            { accumulatedEligibleManifests =
                (repository, digest) : accumulatedEligibleManifests accumulator
            }
    Nothing ->
      case currentRepository >>= \repository ->
        (repository,) <$> exactScopedDigest repository "marking manifest" True line of
        Just marker ->
          continue
            currentRepository
            accumulator
              { accumulatedMarkedManifests = marker : accumulatedMarkedManifests accumulator
              }
        Nothing ->
          case currentRepository >>= \repository ->
            (repository,) <$> exactScopedDigest repository "marking blob" False line of
            Just marker ->
              continue
                currentRepository
                accumulator
                  { accumulatedMarkedBlobs = marker : accumulatedMarkedBlobs accumulator
                  }
            Nothing ->
              case validateRepository line of
                Left _ -> invalidGarbageCollectionEvidence
                Right repository ->
                  continue
                    (Just repository)
                    accumulator
                      { accumulatedRepositories = repository : accumulatedRepositories accumulator
                      }
 where
  continue repository updated = parseMarkPhase repository updated remaining
  withCurrentRepository useRepository =
    case currentRepository of
      Nothing -> invalidGarbageCollectionEvidence
      Just repository -> useRepository repository

parseGarbageCollectionSummary
  :: String -> Either RegistryGarbageCollectionError RegistryGarbageCollectionSummary
parseGarbageCollectionSummary summaryLine =
  case words summaryLine of
    [ markedRaw
      , "blobs"
      , "marked,"
      , eligibleBlobsRaw
      , "blobs"
      , "and"
      , eligibleManifestsRaw
      , "manifests"
      , "eligible"
      , "for"
      , "deletion"
      ] -> do
        marked <- parseCanonicalCount markedRaw
        eligibleBlobs <- parseCanonicalCount eligibleBlobsRaw
        eligibleManifests <- parseCanonicalCount eligibleManifestsRaw
        Right
          RegistryGarbageCollectionSummary
            { summarizedMarkedBlobs = marked
            , summarizedEligibleBlobs = eligibleBlobs
            , summarizedEligibleManifests = eligibleManifests
            }
    _ -> invalidGarbageCollectionEvidence

parseCanonicalCount :: String -> Either RegistryGarbageCollectionError Int
parseCanonicalCount raw =
  case readMaybe raw of
    Just count
      | count >= 0 && show count == raw -> Right count
    _ -> invalidGarbageCollectionEvidence

parseEligibleBlobLine :: String -> Either RegistryGarbageCollectionError String
parseEligibleBlobLine line =
  maybe invalidGarbageCollectionEvidence Right (exactDigestAfter "blob eligible for deletion: " line)

exactScopedDigest :: String -> String -> Bool -> String -> Maybe String
exactScopedDigest repository action hasTrailingSpace line = do
  digestAndSuffix <- stripPrefix (repository ++ ": " ++ action ++ " ") line
  let expectedSuffix = if hasTrailingSpace then " " else ""
      digestLength = length digestAndSuffix - length expectedSuffix
      (digest, suffix) = splitAt digestLength digestAndSuffix
  if digestLength > 0
    && suffix == expectedSuffix
    && isCanonicalSha256Digest digest
    then Just digest
    else Nothing

exactDigestAfter :: String -> String -> Maybe String
exactDigestAfter prefix line = do
  digest <- stripPrefix prefix line
  if isCanonicalSha256Digest digest
    then Just digest
    else Nothing

finalizeGarbageCollectionEvidence
  :: RegistryGarbageCollectionAccumulator
  -> RegistryGarbageCollectionSummary
  -> [String]
  -> Either RegistryGarbageCollectionError RegistryGarbageCollectionEvidence
finalizeGarbageCollectionEvidence accumulator summary eligibleBlobs = do
  let repositories = accumulatedRepositories accumulator
      markedManifests = accumulatedMarkedManifests accumulator
      markedBlobs = accumulatedMarkedBlobs accumulator
      eligibleManifests = accumulatedEligibleManifests accumulator
      repositorySet = Set.fromList repositories
      markedManifestSet = Set.fromList markedManifests
      markedBlobSet = Set.fromList markedBlobs
      eligibleManifestSet = Set.fromList eligibleManifests
      eligibleBlobSet = Set.fromList eligibleBlobs
      globallyMarkedDigests =
        Set.map snd markedManifestSet `Set.union` Set.map snd markedBlobSet
      everyRecordDistinct =
        and
          [ length repositories == Set.size repositorySet
          , length markedManifests == Set.size markedManifestSet
          , length markedBlobs == Set.size markedBlobSet
          , length eligibleManifests == Set.size eligibleManifestSet
          , length eligibleBlobs == Set.size eligibleBlobSet
          ]
      summaryMatches =
        summarizedMarkedBlobs summary == Set.size globallyMarkedDigests
          && summarizedEligibleBlobs summary == Set.size eligibleBlobSet
          && summarizedEligibleManifests summary == Set.size eligibleManifestSet
      eligibilityIsUnmarked =
        Set.null (Set.intersection markedManifestSet eligibleManifestSet)
          && Set.null (Set.intersection globallyMarkedDigests eligibleBlobSet)
  if everyRecordDistinct && summaryMatches && eligibilityIsUnmarked
    then
      Right
        RegistryGarbageCollectionEvidence
          { registryGarbageCollectionRepositories = repositorySet
          , registryGarbageCollectionMarkedManifests = markedManifestSet
          , registryGarbageCollectionMarkedBlobs = markedBlobSet
          , registryGarbageCollectionEligibleManifests = eligibleManifestSet
          , registryGarbageCollectionEligibleBlobs = eligibleBlobSet
          }
    else invalidGarbageCollectionEvidence

invalidGarbageCollectionEvidence :: Either RegistryGarbageCollectionError value
invalidGarbageCollectionEvidence = Left RegistryGarbageCollectionManifestEvidenceInvalid

-- | Model the exact @--delete-untagged@ selection used by Distribution. This
-- keeps the retention counterexample independently reproducible without
-- teaching production code how to delete backend objects itself.
selectUntaggedManifestDigests
  :: [String]
  -> RegistryReferenceSnapshot
  -> Either RegistryReferenceObservationError [String]
selectUntaggedManifestDigests revisions (RegistryReferenceSnapshot repositories) = do
  traverse_ validateRevision revisions
  requireDistinct RegistryReferenceRevisionDuplicate revisions
  let tagged =
        Set.fromList
          [ registryTagReferenceDigest reference
          | repository <- repositories
          , reference <- registryReferenceTags repository
          ]
  pure (sort (filter (`Set.notMember` tagged) revisions))
 where
  validateRevision digest =
    if isCanonicalSha256Digest digest
      then Right ()
      else Left RegistryReferenceDigestInvalid

stringArrayField
  :: String -> Value -> Either RegistryReferenceObservationError [String]
stringArrayField fieldName value = case value of
  Object fields -> case KeyMap.lookup (Key.fromString fieldName) fields of
    Just (Array values) -> traverse stringValue (Vector.toList values)
    _ -> Left RegistryReferenceShapeInvalid
  _ -> Left RegistryReferenceShapeInvalid

stringField
  :: String -> KeyMap.KeyMap Value -> Either RegistryReferenceObservationError String
stringField fieldName fields =
  case KeyMap.lookup (Key.fromString fieldName) fields of
    Just value -> stringValue value
    Nothing -> Left RegistryReferenceShapeInvalid

stringValue :: Value -> Either RegistryReferenceObservationError String
stringValue value = case value of
  String textValue -> Right (Text.unpack textValue)
  _ -> Left RegistryReferenceShapeInvalid

validateCompletePage
  :: [value] -> Either RegistryReferenceObservationError ()
validateCompletePage values =
  if length values < registryReferencePageLimit
    then Right ()
    else Left RegistryReferencePageIncomplete

validateRepository
  :: String -> Either RegistryReferenceObservationError String
validateRepository repository = case (repository, reverse repository) of
  (first : _, final : _)
    | first /= '/'
        && final /= '/'
        && all validRepositoryCharacter repository
        && not ("//" `contains` repository)
        && not (".." `contains` repository) ->
        Right repository
  _ -> Left RegistryReferenceRepositoryInvalid
 where
  validRepositoryCharacter character =
    isAsciiLower character || isDigit character || character `elem` ("._-/" :: String)

validateTag :: String -> Either RegistryReferenceObservationError String
validateTag tag = case tag of
  first : _
    | length tag <= 128
        && validTagStart first
        && all validTagCharacter tag ->
        Right tag
  _ -> Left RegistryReferenceTagInvalid
 where
  validTagStart character = isAlphaNum character || character == '_'
  validTagCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ("_.-" :: String)

requireDistinct
  :: (Ord value)
  => RegistryReferenceObservationError
  -> [value]
  -> Either RegistryReferenceObservationError ()
requireDistinct err values =
  if Set.size (Set.fromList values) == length values
    then Right ()
    else Left err

uniqueHeader
  :: String -> String -> Either RegistryReferenceObservationError String
uniqueHeader expectedName response =
  case [ trim value
       | line <- lines response
       , let (name, suffix) = break (== ':') line
       , map toLower name == expectedName
       , ':' : value <- [suffix]
       ] of
    [value] | not (null value) -> Right value
    [] -> Left RegistryReferenceHeaderMissing
    _ -> Left RegistryReferenceHeaderAmbiguous

isCanonicalSha256Digest :: String -> Bool
isCanonicalSha256Digest digest =
  case splitAt 7 digest of
    ("sha256:", payload) ->
      length payload == 64
        && all isHexDigit payload
        && all (not . isAsciiUpper) payload
    _ -> False

trim :: String -> String
trim = dropWhileEndSpace . dropWhile isSpace
 where
  dropWhileEndSpace = reverse . dropWhile isSpace . reverse

contains :: String -> String -> Bool
contains needle haystack = any (needle `prefixOf`) (tails haystack)
 where
  prefixOf [] _ = True
  prefixOf _ [] = False
  prefixOf (left : leftRest) (right : rightRest) = left == right && prefixOf leftRest rightRest

  tails [] = [[]]
  tails remaining@(_ : rest) = remaining : tails rest
