{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe source identity for revision-scoped deployment qualification.
--
-- The module deliberately lives below @Prodbox.Test@ and exports no runtime
-- capability.  Callers provide candidate bytes only after enumerating the
-- worktree; this module rejects every path outside the canonical allowlist or
-- inside a secret/build/runtime root before hashing content.
module Prodbox.Test.Qualification.SourceIdentity
  ( GitHead
  , WorktreeState (..)
  , ManifestFileType (..)
  , SourceCandidate (..)
  , SourceIdentity
  , SourceIdentityError (..)
  , SourcePathDisposition (..)
  , SourceManifestPolicyIdentity (..)
  , canonicalSourceManifestPolicyId
  , canonicalSourceManifestPolicyVersion
  , mkGitHead
  , classifySourcePath
  , mkSourceIdentity
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isDigit)
import Data.List (group, sort, sortOn)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)
import Numeric (showHex)
import System.FilePath.Posix (splitDirectories, takeExtension, takeFileName)

newtype GitHead = GitHead Text
  deriving stock (Eq, Ord, Show)

data WorktreeState
  = WorktreeClean
  | WorktreeDirty
  deriving stock (Eq, Ord, Show)

data ManifestFileType
  = ManifestRegularFile
  | ManifestSymbolicLink
  deriving stock (Eq, Ord, Show)

-- | A candidate path and its exact bytes.  The bytes are never retained in a
-- 'SourceIdentity'; only a digest of an admitted non-secret candidate is used.
data SourceCandidate = SourceCandidate
  { sourceCandidatePath :: Text
  , sourceCandidateType :: ManifestFileType
  , sourceCandidateMode :: Word32
  , sourceCandidateBytes :: ByteString
  }
  deriving stock (Eq, Show)

data SourceManifestPolicyIdentity = SourceManifestPolicyIdentity
  { sourcePolicyIdentifier :: Text
  , sourcePolicyVersion :: Word32
  , sourcePolicyDigest :: Text
  }
  deriving stock (Eq, Ord, Show)

data SourceIdentity = SourceIdentity
  { sourceGitHead :: GitHead
  , sourceWorktreeState :: WorktreeState
  , sourceManifestPolicyIdentity :: SourceManifestPolicyIdentity
  , sourceManifestDigest :: Text
  , sourceManifestEntryCount :: Int
  }
  deriving stock (Eq, Show)

data SourceIdentityError
  = GitHeadInvalid Text
  | SourceManifestEmpty
  | SourcePathEmpty
  | SourcePathAbsolute Text
  | SourcePathNotNormalized Text
  | SourcePathNotAllowlisted Text
  | SourcePathExcluded Text
  | SourcePathDuplicate Text
  | SourceModeInvalid Text Word32
  | SecretRootInvalid Text
  deriving stock (Eq, Show)

data SourcePathDisposition
  = SourcePathAdmitted
  | SourcePathExcludedByPolicy
  | SourcePathOutsideAllowlist
  deriving stock (Eq, Show)

canonicalSourceManifestPolicyId :: Text
canonicalSourceManifestPolicyId = "prodbox-source-manifest"

canonicalSourceManifestPolicyVersion :: Word32
canonicalSourceManifestPolicyVersion = 1

mkGitHead :: Text -> Either SourceIdentityError GitHead
mkGitHead value
  | validLength && Text.all isLowerHex value = Right (GitHead value)
  | otherwise = Left (GitHeadInvalid value)
 where
  validLength = Text.length value == 40 || Text.length value == 64
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

-- | Construct a complete source identity.  Configured secret roots extend the
-- unconditional policy exclusions and therefore participate in the policy
-- digest.  An excluded candidate is a hard refusal, never silently omitted.
mkSourceIdentity
  :: GitHead
  -> WorktreeState
  -> [Text]
  -> [SourceCandidate]
  -> Either SourceIdentityError SourceIdentity
mkSourceIdentity gitHead worktreeState configuredSecretRoots candidates = do
  normalizedSecretRoots <- traverse normalizeSecretRoot configuredSecretRoots
  let secretRoots = sort (Set.toList (Set.fromList normalizedSecretRoots))
  admitted <- traverse (admitCandidate secretRoots) candidates
  case admitted of
    [] -> Left SourceManifestEmpty
    _ -> do
      rejectDuplicatePaths admitted
      let policyBytes = canonicalPolicyBytes secretRoots
          manifestBytes = BS.concat (map encodeManifestEntry (sortOn admittedPath admitted))
      pure
        SourceIdentity
          { sourceGitHead = gitHead
          , sourceWorktreeState = worktreeState
          , sourceManifestPolicyIdentity =
              SourceManifestPolicyIdentity
                { sourcePolicyIdentifier = canonicalSourceManifestPolicyId
                , sourcePolicyVersion = canonicalSourceManifestPolicyVersion
                , sourcePolicyDigest = sha256Hex policyBytes
                }
          , sourceManifestDigest = sha256Hex manifestBytes
          , sourceManifestEntryCount = length admitted
          }

data AdmittedEntry = AdmittedEntry
  { admittedPath :: Text
  , admittedType :: ManifestFileType
  , admittedMode :: Word32
  , admittedContentDigest :: Text
  }

admitCandidate :: [Text] -> SourceCandidate -> Either SourceIdentityError AdmittedEntry
admitCandidate secretRoots candidate = do
  path <- normalizeCandidatePath (sourceCandidatePath candidate)
  disposition <- classifyNormalizedSourcePath secretRoots path
  case disposition of
    SourcePathAdmitted -> pure ()
    SourcePathExcludedByPolicy -> Left (SourcePathExcluded path)
    SourcePathOutsideAllowlist -> Left (SourcePathNotAllowlisted path)
  if sourceCandidateMode candidate <= 0o777
    then pure ()
    else Left (SourceModeInvalid path (sourceCandidateMode candidate))
  pure
    AdmittedEntry
      { admittedPath = path
      , admittedType = sourceCandidateType candidate
      , admittedMode = sourceCandidateMode candidate
      , admittedContentDigest = sha256Hex (sourceCandidateBytes candidate)
      }

normalizeCandidatePath :: Text -> Either SourceIdentityError Text
normalizeCandidatePath path
  | Text.null path = Left SourcePathEmpty
  | Text.isPrefixOf "/" path = Left (SourcePathAbsolute path)
  | Text.any (== '\\') path = Left (SourcePathNotNormalized path)
  | any invalidSegment segments = Left (SourcePathNotNormalized path)
  | Text.intercalate "/" (map Text.pack segments) /= path = Left (SourcePathNotNormalized path)
  | otherwise = Right path
 where
  segments = splitDirectories (Text.unpack path)
  invalidSegment segment = null segment || segment == "." || segment == ".."

normalizeSecretRoot :: Text -> Either SourceIdentityError Text
normalizeSecretRoot root = do
  normalized <- normalizeCandidatePath root
  if normalized `elem` unconditionalExcludedRoots
    then Left (SecretRootInvalid root)
    else Right normalized

-- | Classify a path before its bytes are opened. This is the load-bearing
-- ordering used by the filesystem recorder: excluded secret/build/runtime
-- candidates are refused without reading or hashing their content, while paths
-- outside the positive allowlist are simply not manifest inputs.
classifySourcePath
  :: [Text]
  -> Text
  -> Either SourceIdentityError SourcePathDisposition
classifySourcePath configuredSecretRoots rawPath = do
  secretRoots <- traverse normalizeSecretRoot configuredSecretRoots
  path <- normalizeCandidatePath rawPath
  classifyNormalizedSourcePath secretRoots path

classifyNormalizedSourcePath
  :: [Text]
  -> Text
  -> Either SourceIdentityError SourcePathDisposition
classifyNormalizedSourcePath secretRoots path
  | pathExcluded secretRoots path = Right SourcePathExcludedByPolicy
  | pathAllowlisted path = Right SourcePathAdmitted
  | otherwise = Right SourcePathOutsideAllowlist

rejectDuplicatePaths :: [AdmittedEntry] -> Either SourceIdentityError ()
rejectDuplicatePaths entries =
  case [first | duplicate@(first : _) <- group (sort (map admittedPath entries)), length duplicate > 1] of
    duplicate : _ -> Left (SourcePathDuplicate duplicate)
    [] -> Right ()

pathExcluded :: [Text] -> Text -> Bool
pathExcluded configuredSecretRoots path =
  any (`pathWithin` path) (unconditionalExcludedRoots ++ configuredSecretRoots)
    || Text.toLower (Text.pack (takeFileName unpacked)) `Set.member` excludedBaseNames
    || Text.toLower (Text.pack (takeExtension unpacked)) `Set.member` excludedExtensions
 where
  unpacked = Text.unpack path

pathWithin :: Text -> Text -> Bool
pathWithin root path = path == root || (root <> "/") `Text.isPrefixOf` path

unconditionalExcludedRoots :: [Text]
unconditionalExcludedRoots =
  [ ".build"
  , ".data"
  , ".git"
  , ".prodbox-state"
  , ".secrets"
  , "dist-newstyle"
  , "result"
  , "runtime"
  , "secrets"
  , "tmp"
  ]

excludedBaseNames :: Set.Set Text
excludedBaseNames =
  Set.fromList
    [ "prodbox-config.dhall"
    , "prodbox.dhall"
    , "test-config.dhall"
    , "test-secrets.dhall"
    ]

excludedExtensions :: Set.Set Text
excludedExtensions = Set.fromList [".age", ".jks", ".key", ".p12", ".pem"]

pathAllowlisted :: Text -> Bool
pathAllowlisted path =
  rootFileAllowlisted path
    || (any (`pathWithin` path) haskellCodeRoots && extension `Set.member` haskellCodeExtensions)
    || ("test" `pathWithin` path && extension `Set.member` testCodeExtensions)
    || (any (`pathWithin` path) documentationRoots && extension `Set.member` documentationExtensions)
    || ("dhall" `pathWithin` path && extension `Set.member` dhallSchemaExtensions)
    || ("charts" `pathWithin` path && extension `Set.member` chartTemplateExtensions)
    || ( "docker" `pathWithin` path
           && ( extension `Set.member` dockerSourceExtensions
                  || any (`Text.isSuffixOf` path) dockerSpecialSuffixes
              )
       )
    || ("pulumi" `pathWithin` path && extension `Set.member` pulumiSourceExtensions)
 where
  extension = Text.toLower (Text.pack (takeExtension (Text.unpack path)))

haskellCodeRoots :: [Text]
haskellCodeRoots = ["app", "src"]

haskellCodeExtensions :: Set.Set Text
haskellCodeExtensions = Set.fromList [".hs"]

testCodeExtensions :: Set.Set Text
testCodeExtensions =
  Set.fromList [".dhall", ".golden", ".hs", ".html", ".json", ".sh", ".tpl", ".txt", ".yaml", ".yml"]

documentationRoots :: [Text]
documentationRoots = ["DEVELOPMENT_PLAN", "documents"]

documentationExtensions :: Set.Set Text
documentationExtensions = Set.fromList [".md"]

dhallSchemaExtensions :: Set.Set Text
dhallSchemaExtensions = Set.fromList [".dhall"]

chartTemplateExtensions :: Set.Set Text
chartTemplateExtensions = Set.fromList [".json", ".md", ".tpl", ".yaml", ".yml"]

dockerSourceExtensions :: Set.Set Text
dockerSourceExtensions = Set.fromList [".conf", ".dockerfile", ".sh", ".yaml", ".yml"]

dockerSpecialSuffixes :: [Text]
dockerSpecialSuffixes = ["Dockerfile"]

pulumiSourceExtensions :: Set.Set Text
pulumiSourceExtensions = Set.fromList [".json", ".yaml", ".yml"]

rootFileAllowlisted :: Text -> Bool
rootFileAllowlisted path =
  not (Text.any (== '/') path)
    && ( path `Set.member` explicitRootFiles
           || Text.toLower (Text.pack (takeExtension (Text.unpack path)))
             `Set.member` rootSchemaExtensions
       )

explicitRootFiles :: Set.Set Text
explicitRootFiles =
  Set.fromList
    [ ".dockerignore"
    , ".editorconfig"
    , ".gitignore"
    , ".hlint.yaml"
    , "AGENTS.md"
    , "CLAUDE.md"
    , "LICENSE"
    , "README.md"
    , "cabal.project"
    , "fourmolu.yaml"
    , "hie.yaml"
    , "prodbox.cabal"
    ]

rootSchemaExtensions :: Set.Set Text
rootSchemaExtensions = Set.fromList [".dhall"]

canonicalPolicyBytes :: [Text] -> ByteString
canonicalPolicyBytes configuredSecretRoots =
  BS.concat
    [ encodePolicyClause "policy-id" [canonicalSourceManifestPolicyId]
    , encodePolicyClause "policy-version" [Text.pack (show canonicalSourceManifestPolicyVersion)]
    , encodePolicyClause "haskell-roots" haskellCodeRoots
    , encodePolicyClause "haskell-extensions" (Set.toList haskellCodeExtensions)
    , encodePolicyClause "test-roots" ["test"]
    , encodePolicyClause "test-extensions" (Set.toList testCodeExtensions)
    , encodePolicyClause "documentation-roots" documentationRoots
    , encodePolicyClause "documentation-extensions" (Set.toList documentationExtensions)
    , encodePolicyClause "schema-roots" ["dhall"]
    , encodePolicyClause "schema-extensions" (Set.toList dhallSchemaExtensions)
    , encodePolicyClause "chart-roots" ["charts"]
    , encodePolicyClause "chart-extensions" (Set.toList chartTemplateExtensions)
    , encodePolicyClause "docker-roots" ["docker"]
    , encodePolicyClause "docker-extensions" (Set.toList dockerSourceExtensions)
    , encodePolicyClause "docker-special-suffixes" dockerSpecialSuffixes
    , encodePolicyClause "pulumi-roots" ["pulumi"]
    , encodePolicyClause "pulumi-extensions" (Set.toList pulumiSourceExtensions)
    , encodePolicyClause "root-files" (Set.toList explicitRootFiles)
    , encodePolicyClause "root-schema-extensions" (Set.toList rootSchemaExtensions)
    , encodePolicyClause "unconditional-excluded-roots" unconditionalExcludedRoots
    , encodePolicyClause "excluded-base-names" (Set.toList excludedBaseNames)
    , encodePolicyClause "excluded-extensions" (Set.toList excludedExtensions)
    , encodePolicyClause "configured-secret-roots" configuredSecretRoots
    ]

encodePolicyClause :: Text -> [Text] -> ByteString
encodePolicyClause label values = encodeText label <> encodeTexts (sort values)

encodeManifestEntry :: AdmittedEntry -> ByteString
encodeManifestEntry entry =
  BS.concat
    [ encodeText (admittedPath entry)
    , encodeText (renderFileType (admittedType entry))
    , encodeText (Text.pack (show (admittedMode entry)))
    , encodeText (admittedContentDigest entry)
    ]

renderFileType :: ManifestFileType -> Text
renderFileType ManifestRegularFile = "regular"
renderFileType ManifestSymbolicLink = "symlink"

encodeTexts :: [Text] -> ByteString
encodeTexts values = BS.concat (encodeText (Text.pack (show (length values))) : map encodeText values)

encodeText :: Text -> ByteString
encodeText value =
  let bytes = TextEncoding.encodeUtf8 value
   in BS8.pack (show (BS.length bytes)) <> ":" <> bytes

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . BS.unpack . SHA256.hash
 where
  renderByte byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered
