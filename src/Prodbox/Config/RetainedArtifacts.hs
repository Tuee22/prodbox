{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the retained-artifact vocabulary, as configuration.
--
-- An ordinary-teardown repair reinstalls the local substrate and loads the
-- recovery closure's images from bytes this repository retained ahead of time,
-- and every fact about those bytes — which kinds exist, which architecture they
-- were retained for, what they are pinned to, where they live under the
-- retained root, and where they may be acquired from — is operator-declared
-- configuration rather than lifecycle behaviour.
--
-- This module is a deliberate leaf.  The vocabulary began inside
-- "Prodbox.Config.OrdinaryTeardownRepair", which also owns the repair matrix
-- and therefore reaches the observed local substrate state and, through it, the
-- lifecycle surface.  Tier-0 config cannot import that, so the vocabulary could
-- not be declared in the config the repair reads — and a declaration a repair
-- cannot be built from is a repair that can only ever be driven by a fixture.
-- Splitting it out is what lets the operator's declaration live in
-- @prodbox.dhall@ and be validated at config load rather than at the moment a
-- control plane is already gone.
--
-- "Prodbox.Config.OrdinaryTeardownRepair" re-exports everything here, so the
-- split is invisible to every consumer of the repair surface.
module Prodbox.Config.RetainedArtifacts
  ( -- * Versioned retained artifact inventory
    RetainedArtifactArchitecture (..)
  , retainedArtifactArchitectureText
  , RetainedArtifactKind (..)
  , retainedArtifactKindText
  , RetainedArtifactRole (..)
  , retainedArtifactRole
  , RetainedArtifactEntry (..)
  , RetainedArtifactInventory
  , retainedArtifactInventoryArchitecture
  , retainedArtifactInventoryKinds
  , RetainedArtifactRef
  , retainedArtifactRefKind
  , retainedArtifactRefArchitecture
  , retainedArtifactRefVersion
  , retainedArtifactRefDigest
  , retainedArtifactRefRelativePath
  , RetainedArtifactInventoryError (..)
  , renderRetainedArtifactInventoryError
  , retainedArtifactInventory
  , lookupRetainedArtifact

    -- * Pinned acquisition sources
  , RetainedArtifactLocator (..)
  , retainedArtifactLocatorText
  , RetainedArtifactSourceEntry (..)
  , RetainedArtifactSource
  , retainedArtifactSourceKind
  , retainedArtifactSourceArchitecture
  , retainedArtifactSourceDigest
  , retainedArtifactSourceLocator
  , RetainedArtifactSourceCatalog
  , retainedArtifactSourceCatalogArchitecture
  , retainedArtifactSourceCatalogKinds
  , RetainedArtifactSourceError (..)
  , renderRetainedArtifactSourceError
  , retainedArtifactSourceCatalog
  , lookupRetainedArtifactSource

    -- * The operator-declared Tier-0 section
  , RetainedArtifactDeclaration (..)
  , RetainedArtifactsSection (..)
  , emptyRetainedArtifactsSection
  , DeclaredRetainedArtifacts
  , declaredRetainedArtifactInventory
  , declaredRetainedArtifactCatalog
  , RetainedArtifactDeclarationError (..)
  , renderRetainedArtifactDeclarationError
  , declaredRetainedArtifacts
  )
where

import Data.Char (isHexDigit, isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall (..), ToDhall (..))
import Dhall qualified
import GHC.Generics (Generic)

-- ---------------------------------------------------------------------------
-- Versioned retained artifact inventory
-- ---------------------------------------------------------------------------

-- | Retained artifacts are architecture-specific.  A repair plan is rendered
-- for exactly one architecture, and an entry declaring a different one is
-- refused rather than coerced.
data RetainedArtifactArchitecture
  = RetainedArtifactAmd64
  | RetainedArtifactArm64
  deriving (Bounded, Enum, Eq, Ord, Show)

retainedArtifactArchitectureText :: RetainedArtifactArchitecture -> String
retainedArtifactArchitectureText = \case
  RetainedArtifactAmd64 -> "amd64"
  RetainedArtifactArm64 -> "arm64"

-- | The closed set of artifact kinds an ordinary-teardown repair may consume.
-- The set is closed so that admitting a new recovery component without also
-- declaring where its bytes come from is a compile-time or refusal event, never
-- a silent network fetch.
data RetainedArtifactKind
  = -- | The pinned local substrate installer script.
    RetainedSubstrateInstaller
  | -- | The pinned local substrate release tarball the installer unpacks.
    --
    -- Separate from the installer because the offline install reads them as
    -- two files in one artifact directory, and one entry cannot carry two
    -- digests.
    RetainedSubstrateReleaseTarball
  | -- | The pinned checksum file the installer verifies the release tarball
    -- against.
    --
    -- Retained rather than recomputed: the installer performs the check itself
    -- and refuses without this file, so a recovery that omitted it would fail
    -- at its first step on a real host.
    RetainedSubstrateChecksum
  | -- | The pinned local substrate system-images archive.
    RetainedSubstrateSystemImages
  | -- | The retained object-store (MinIO) runtime image.
    RetainedObjectStoreImage
  | -- | The retained secret-store (Vault) runtime image.
    RetainedSecretStoreImage
  | -- | The retained prodbox runtime image every control-plane chart runs.
    RetainedProdboxRuntimeImage
  deriving (Bounded, Enum, Eq, Ord, Show)

retainedArtifactKindText :: RetainedArtifactKind -> String
retainedArtifactKindText = \case
  RetainedSubstrateInstaller -> "substrate_installer"
  RetainedSubstrateReleaseTarball -> "substrate_release_tarball"
  RetainedSubstrateChecksum -> "substrate_checksum"
  RetainedSubstrateSystemImages -> "substrate_system_images"
  RetainedObjectStoreImage -> "object_store_image"
  RetainedSecretStoreImage -> "secret_store_image"
  RetainedProdboxRuntimeImage -> "prodbox_runtime_image"

-- | How a kind participates in a repair.  Substrate artifacts reinstall the
-- local substrate itself; image artifacts are loaded into the node's content
-- store because the recovery closure has no image Registry to pull from.
data RetainedArtifactRole
  = RetainedSubstrateArtifact
  | RetainedImageArtifact
  deriving (Bounded, Enum, Eq, Ord, Show)

retainedArtifactRole :: RetainedArtifactKind -> RetainedArtifactRole
retainedArtifactRole = \case
  RetainedSubstrateInstaller -> RetainedSubstrateArtifact
  RetainedSubstrateReleaseTarball -> RetainedSubstrateArtifact
  RetainedSubstrateChecksum -> RetainedSubstrateArtifact
  RetainedSubstrateSystemImages -> RetainedSubstrateArtifact
  RetainedObjectStoreImage -> RetainedImageArtifact
  RetainedSecretStoreImage -> RetainedImageArtifact
  RetainedProdboxRuntimeImage -> RetainedImageArtifact

-- | An operator-declared inventory entry, before validation.
data RetainedArtifactEntry = RetainedArtifactEntry
  { retainedArtifactEntryKind :: !RetainedArtifactKind
  , retainedArtifactEntryArchitecture :: !RetainedArtifactArchitecture
  , retainedArtifactEntryVersion :: !String
  , retainedArtifactEntryDigest :: !String
  , retainedArtifactEntryRelativePath :: !FilePath
  -- ^ Location under the retained root.  Deliberately relative: the retained
  -- root itself is bound by "Prodbox.Config.LocalRetainedRoot", so an entry
  -- cannot name a second storage root.
  }
  deriving (Eq, Show)

-- | A validated reference to one retained artifact.  Opaque: the only way to
-- obtain one is through a validated inventory, so a repair step cannot name an
-- artifact whose version, digest, and location were never checked.
data RetainedArtifactRef = RetainedArtifactRef
  { retainedArtifactRefKind :: !RetainedArtifactKind
  , retainedArtifactRefArchitecture :: !RetainedArtifactArchitecture
  , retainedArtifactRefVersion :: !String
  , retainedArtifactRefDigest :: !String
  , retainedArtifactRefRelativePath :: !FilePath
  }
  deriving (Eq, Ord, Show)

-- | Opaque, validated inventory.  Construction proves the declared
-- architecture is uniform, every kind appears at most once, and every version,
-- digest, and retained location is well formed.
data RetainedArtifactInventory = RetainedArtifactInventory
  { retainedArtifactInventoryArchitecture :: !RetainedArtifactArchitecture
  , inventoryEntries :: !(Map RetainedArtifactKind RetainedArtifactRef)
  }
  deriving (Eq, Show)

-- | The kinds this inventory retains, in canonical kind order.
retainedArtifactInventoryKinds :: RetainedArtifactInventory -> [RetainedArtifactKind]
retainedArtifactInventoryKinds = Map.keys . inventoryEntries

data RetainedArtifactInventoryError
  = RetainedArtifactInventoryDuplicateKind !RetainedArtifactKind
  | RetainedArtifactInventoryForeignArchitecture
      !RetainedArtifactKind
      !RetainedArtifactArchitecture
      !RetainedArtifactArchitecture
  | RetainedArtifactInventoryUnversioned !RetainedArtifactKind !String
  | RetainedArtifactInventoryMalformedDigest !RetainedArtifactKind !String
  | RetainedArtifactInventoryUnsafeRetainedPath !RetainedArtifactKind !FilePath
  deriving (Eq, Show)

renderRetainedArtifactInventoryError :: RetainedArtifactInventoryError -> String
renderRetainedArtifactInventoryError = \case
  RetainedArtifactInventoryDuplicateKind kind ->
    "Retained artifact inventory declares `"
      ++ retainedArtifactKindText kind
      ++ "` more than once; exactly one retained artifact may answer a kind."
  RetainedArtifactInventoryForeignArchitecture kind expected declared ->
    "Retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` declares architecture `"
      ++ retainedArtifactArchitectureText declared
      ++ "` in an inventory rendered for `"
      ++ retainedArtifactArchitectureText expected
      ++ "`."
  RetainedArtifactInventoryUnversioned kind version ->
    "Retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` carries no usable pinned version (`"
      ++ version
      ++ "`); a floating or empty version cannot identify retained bytes."
  RetainedArtifactInventoryMalformedDigest kind digest ->
    "Retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` carries digest `"
      ++ digest
      ++ "`, which is not a canonical `sha256:` hex digest."
  RetainedArtifactInventoryUnsafeRetainedPath kind path ->
    "Retained artifact `"
      ++ retainedArtifactKindText kind
      ++ "` declares retained location `"
      ++ path
      ++ "`, which is not a normalized location under the retained root."

-- | Validate an operator-declared inventory for one architecture.  An empty
-- declaration is a valid inventory: it says the repository retains nothing,
-- and the refusal then lands where it belongs, on the repair plan that needed
-- an artifact.
retainedArtifactInventory
  :: RetainedArtifactArchitecture
  -> [RetainedArtifactEntry]
  -> Either RetainedArtifactInventoryError RetainedArtifactInventory
retainedArtifactInventory architecture entries = do
  indexed <- foldl' step (Right Map.empty) entries
  pure
    RetainedArtifactInventory
      { retainedArtifactInventoryArchitecture = architecture
      , inventoryEntries = indexed
      }
 where
  step acc entry = do
    indexed <- acc
    ref <- validateEntry architecture entry
    if Map.member (retainedArtifactRefKind ref) indexed
      then Left (RetainedArtifactInventoryDuplicateKind (retainedArtifactRefKind ref))
      else Right (Map.insert (retainedArtifactRefKind ref) ref indexed)

validateEntry
  :: RetainedArtifactArchitecture
  -> RetainedArtifactEntry
  -> Either RetainedArtifactInventoryError RetainedArtifactRef
validateEntry architecture entry
  | declaredArchitecture /= architecture =
      Left
        ( RetainedArtifactInventoryForeignArchitecture
            kind
            architecture
            declaredArchitecture
        )
  | not (isPinnedVersion version) =
      Left (RetainedArtifactInventoryUnversioned kind version)
  | not (isCanonicalSha256Digest digest) =
      Left (RetainedArtifactInventoryMalformedDigest kind digest)
  | not (isNormalizedRetainedPath path) =
      Left (RetainedArtifactInventoryUnsafeRetainedPath kind path)
  | otherwise =
      Right
        RetainedArtifactRef
          { retainedArtifactRefKind = kind
          , retainedArtifactRefArchitecture = declaredArchitecture
          , retainedArtifactRefVersion = version
          , retainedArtifactRefDigest = digest
          , retainedArtifactRefRelativePath = path
          }
 where
  kind = retainedArtifactEntryKind entry
  declaredArchitecture = retainedArtifactEntryArchitecture entry
  version = retainedArtifactEntryVersion entry
  digest = retainedArtifactEntryDigest entry
  path = retainedArtifactEntryRelativePath entry

-- | A pinned version is non-empty and contains no whitespace.  A moving tag is
-- not excluded here by name; the digest is what makes an entry immutable, and
-- the version exists so an operator can read the inventory.
isPinnedVersion :: String -> Bool
isPinnedVersion version =
  not (null version) && not (any isSpace version)

isCanonicalSha256Digest :: String -> Bool
isCanonicalSha256Digest digest = case splitAt 7 digest of
  ("sha256:", hex) ->
    length hex == 64 && all isLowerHexDigit hex
  _ -> False

isLowerHexDigit :: Char -> Bool
isLowerHexDigit character =
  isHexDigit character && character `notElem` ['A' .. 'F']

-- | A retained location is relative, non-empty, and free of empty, current-,
-- or parent-directory segments, so it cannot escape the retained root or
-- depend on path normalization at execution time.
isNormalizedRetainedPath :: FilePath -> Bool
isNormalizedRetainedPath path = case path of
  [] -> False
  '/' : _ -> False
  _ ->
    not (any isSpace path)
      && not (null segments)
      && all usableSegment segments
 where
  segments = splitOnSlash path
  usableSegment segment =
    not (null segment) && segment /= "." && segment /= ".."

splitOnSlash :: FilePath -> [String]
splitOnSlash path = case break (== '/') path of
  (segment, []) -> [segment]
  (segment, _ : remaining) -> segment : splitOnSlash remaining

lookupRetainedArtifact
  :: RetainedArtifactKind -> RetainedArtifactInventory -> Maybe RetainedArtifactRef
lookupRetainedArtifact kind = Map.lookup kind . inventoryEntries

-- ---------------------------------------------------------------------------
-- Pinned acquisition sources
-- ---------------------------------------------------------------------------

-- | Where bytes may be delivered from.
--
-- There is exactly one arm, and the reason is the pinned-digest rule rather
-- than a shortage of imagination.  A delivery mechanism can be admitted here
-- only if the bytes it produces are a stable stream that a digest fixed ahead
-- of time can describe.  Exporting a registry image to an archive, for
-- instance, is not such a mechanism: the image content is immutable but its
-- archive serialization is not byte-stable, so an export could only ever be
-- checked against a digest recorded from a previous export — which is a
-- transport deciding what is retained.  Retaining image bytes is therefore a
-- content-addressed mechanism this type does not yet have an arm for, and
-- declaring one is a decision that lands here rather than in a free string an
-- operator can widen.
newtype RetainedArtifactLocator
  = -- | An immutable archive addressed by @https@ URL.
    RetainedArtifactPinnedArchive Text
  deriving (Eq, Ord, Show)

retainedArtifactLocatorText :: RetainedArtifactLocator -> Text
retainedArtifactLocatorText (RetainedArtifactPinnedArchive url) = url

-- | An operator-declared source, before validation.
data RetainedArtifactSourceEntry = RetainedArtifactSourceEntry
  { retainedArtifactSourceEntryKind :: !RetainedArtifactKind
  , retainedArtifactSourceEntryArchitecture :: !RetainedArtifactArchitecture
  , retainedArtifactSourceEntryDigest :: !Text
  -- ^ The digest the declaration claims the locator delivers.  It is checked
  -- against the inventory when the catalog is bound to one, and against the
  -- delivered bytes when the acquisition runs.
  , retainedArtifactSourceEntryLocator :: !RetainedArtifactLocator
  }
  deriving (Eq, Show)

-- | A validated source.  Opaque, so an acquisition step cannot name a locator
-- whose shape and digest were never checked.
data RetainedArtifactSource = RetainedArtifactSource
  { retainedArtifactSourceKind :: !RetainedArtifactKind
  , retainedArtifactSourceArchitecture :: !RetainedArtifactArchitecture
  , retainedArtifactSourceDigest :: !Text
  , retainedArtifactSourceLocator :: !RetainedArtifactLocator
  }
  deriving (Eq, Ord, Show)

-- | Sources for exactly one architecture, at most one per kind.
data RetainedArtifactSourceCatalog = RetainedArtifactSourceCatalog
  { catalogArchitecture :: !RetainedArtifactArchitecture
  , catalogSources :: !(Map RetainedArtifactKind RetainedArtifactSource)
  }
  deriving (Eq, Show)

-- | The one architecture every source in the catalog was declared for.
retainedArtifactSourceCatalogArchitecture
  :: RetainedArtifactSourceCatalog -> RetainedArtifactArchitecture
retainedArtifactSourceCatalogArchitecture = catalogArchitecture

retainedArtifactSourceCatalogKinds
  :: RetainedArtifactSourceCatalog -> [RetainedArtifactKind]
retainedArtifactSourceCatalogKinds = Map.keys . catalogSources

data RetainedArtifactSourceError
  = RetainedArtifactSourceDuplicateKind !RetainedArtifactKind
  | RetainedArtifactSourceForeignArchitecture
      !RetainedArtifactKind
      !RetainedArtifactArchitecture
      !RetainedArtifactArchitecture
  | RetainedArtifactSourceMalformedDigest !RetainedArtifactKind !Text
  | RetainedArtifactSourceMalformedLocator !RetainedArtifactKind !Text !Text
  deriving (Eq, Show)

renderRetainedArtifactSourceError :: RetainedArtifactSourceError -> String
renderRetainedArtifactSourceError = \case
  RetainedArtifactSourceDuplicateKind kind ->
    "Retained artifact source catalog declares `"
      ++ retainedArtifactKindText kind
      ++ "` more than once; exactly one source may answer a kind."
  RetainedArtifactSourceForeignArchitecture kind expected declared ->
    "Retained artifact source `"
      ++ retainedArtifactKindText kind
      ++ "` declares architecture `"
      ++ retainedArtifactArchitectureText declared
      ++ "` in a catalog rendered for `"
      ++ retainedArtifactArchitectureText expected
      ++ "`."
  RetainedArtifactSourceMalformedDigest kind digest ->
    "Retained artifact source `"
      ++ retainedArtifactKindText kind
      ++ "` declares digest `"
      ++ Text.unpack digest
      ++ "`, which is not a canonical `sha256:` hex digest."
  RetainedArtifactSourceMalformedLocator kind locator detail ->
    "Retained artifact source `"
      ++ retainedArtifactKindText kind
      ++ "` declares locator `"
      ++ Text.unpack locator
      ++ "`, which is unusable: "
      ++ Text.unpack detail
      ++ "."

-- | Validate an operator-declared source catalog for one architecture.
retainedArtifactSourceCatalog
  :: RetainedArtifactArchitecture
  -> [RetainedArtifactSourceEntry]
  -> Either RetainedArtifactSourceError RetainedArtifactSourceCatalog
retainedArtifactSourceCatalog architecture entries = do
  indexed <- foldl' step (Right Map.empty) entries
  pure
    RetainedArtifactSourceCatalog
      { catalogArchitecture = architecture
      , catalogSources = indexed
      }
 where
  step accumulated entry = do
    indexed <- accumulated
    source <- validateSourceEntry architecture entry
    if Map.member (retainedArtifactSourceKind source) indexed
      then Left (RetainedArtifactSourceDuplicateKind (retainedArtifactSourceKind source))
      else Right (Map.insert (retainedArtifactSourceKind source) source indexed)

validateSourceEntry
  :: RetainedArtifactArchitecture
  -> RetainedArtifactSourceEntry
  -> Either RetainedArtifactSourceError RetainedArtifactSource
validateSourceEntry architecture entry
  | declaredArchitecture /= architecture =
      Left
        ( RetainedArtifactSourceForeignArchitecture
            kind
            architecture
            declaredArchitecture
        )
  | not (isCanonicalSha256Digest (Text.unpack digest)) =
      Left (RetainedArtifactSourceMalformedDigest kind digest)
  | otherwise = do
      validateLocator kind locator
      Right
        RetainedArtifactSource
          { retainedArtifactSourceKind = kind
          , retainedArtifactSourceArchitecture = declaredArchitecture
          , retainedArtifactSourceDigest = digest
          , retainedArtifactSourceLocator = locator
          }
 where
  kind = retainedArtifactSourceEntryKind entry
  declaredArchitecture = retainedArtifactSourceEntryArchitecture entry
  digest = retainedArtifactSourceEntryDigest entry
  locator = retainedArtifactSourceEntryLocator entry

-- | Check a locator's shape.
validateLocator
  :: RetainedArtifactKind
  -> RetainedArtifactLocator
  -> Either RetainedArtifactSourceError ()
validateLocator kind (RetainedArtifactPinnedArchive url)
  | not ("https://" `Text.isPrefixOf` url) =
      malformed "an artifact archive must be addressed over `https`"
  | Text.any isUnsafeLocatorCharacter url =
      malformed "a locator may not contain whitespace or control characters"
  | Text.isInfixOf "@" (Text.drop (Text.length "https://") url) =
      malformed "a locator may not carry userinfo"
  | Text.isInfixOf ".." url =
      malformed "a locator may not contain a parent-directory segment"
  | otherwise = Right ()
 where
  malformed detail =
    Left (RetainedArtifactSourceMalformedLocator kind url detail)

isUnsafeLocatorCharacter :: Char -> Bool
isUnsafeLocatorCharacter character =
  character <= ' ' || character == '\DEL'

lookupRetainedArtifactSource
  :: RetainedArtifactKind
  -> RetainedArtifactSourceCatalog
  -> Maybe RetainedArtifactSource
lookupRetainedArtifactSource kind = Map.lookup kind . catalogSources

-- ---------------------------------------------------------------------------
-- The operator-declared Tier-0 section
-- ---------------------------------------------------------------------------

-- | Sprint 4.86: one operator-declared retained artifact, before validation.
--
-- An artifact is declared /once/.  The same digest is what the acquisition
-- promises the locator delivers and what the retained store is measured
-- against, so an inventory and a source catalog projected from one declaration
-- cannot disagree about the bytes.  Two separately authored lists could
-- disagree, and would, exactly when a recovery needed them: the run would
-- acquire one artifact and then refuse the store that now holds it.
--
-- An empty @source_url@ declares an artifact that is retained and has no
-- acquisition.  It is a member of the inventory and not of the source catalog,
-- which is how custody reports it as unsourced rather than inventing somewhere
-- to fetch it from.
--
-- The Haskell selectors carry a @rad@ prefix so they cannot collide with
-- common names; the Dhall document keeps the bare field names.
data RetainedArtifactDeclaration = RetainedArtifactDeclaration
  { radKind :: Text
  , radVersion :: Text
  , radDigest :: Text
  , radRetainedPath :: Text
  , radSourceUrl :: Text
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall RetainedArtifactDeclaration where
  autoWith _ =
    Dhall.genericAutoWith
      Dhall.defaultInterpretOptions {Dhall.fieldModifier = declarationFieldName}

instance ToDhall RetainedArtifactDeclaration where
  injectWith _ =
    Dhall.genericToDhallWith
      Dhall.defaultInterpretOptions {Dhall.fieldModifier = declarationFieldName}

-- | Written out rather than derived from the prefix, so the wire names are
-- readable in one place and a renamed selector is a visible edit here.
declarationFieldName :: Text -> Text
declarationFieldName = \case
  "radKind" -> "kind"
  "radVersion" -> "version"
  "radDigest" -> "digest"
  "radRetainedPath" -> "retained_path"
  "radSourceUrl" -> "source_url"
  other -> other

-- | Sprint 4.86: the retained artifacts an ordinary-teardown repair may
-- reinstall the local substrate and the recovery closure's images from.
--
-- Non-secret, and deliberately Tier-0: the repair that consumes it runs while
-- the Lifecycle Authority is absent and Vault may be sealed, so an inventory
-- reachable only through the control plane would be unreadable exactly when it
-- is needed.
--
-- An empty artifact list is a valid declaration — it says the repository
-- retains nothing — and the refusal then lands where it belongs, on the repair
-- plan that needed an artifact.
data RetainedArtifactsSection = RetainedArtifactsSection
  { rasArchitecture :: Text
  , rasArtifacts :: [RetainedArtifactDeclaration]
  }
  deriving stock (Eq, Show, Generic)

instance FromDhall RetainedArtifactsSection where
  autoWith _ =
    Dhall.genericAutoWith
      Dhall.defaultInterpretOptions {Dhall.fieldModifier = sectionFieldName}

instance ToDhall RetainedArtifactsSection where
  injectWith _ =
    Dhall.genericToDhallWith
      Dhall.defaultInterpretOptions {Dhall.fieldModifier = sectionFieldName}

sectionFieldName :: Text -> Text
sectionFieldName = \case
  "rasArchitecture" -> "architecture"
  "rasArtifacts" -> "artifacts"
  other -> other

-- | The declaration a repository that retains nothing carries.
--
-- Empty rather than pre-populated: a compiled default carrying versions,
-- digests, and paths would be a claim about bytes this repository has never
-- observed, and a repair admitted against it would refuse on a real host after
-- the store had already been called complete.
emptyRetainedArtifactsSection :: RetainedArtifactsSection
emptyRetainedArtifactsSection =
  RetainedArtifactsSection
    { rasArchitecture = "amd64"
    , rasArtifacts = []
    }

-- | Both projections of one declaration, validated together.
--
-- They are returned as a pair rather than by two separate functions because a
-- caller that could take one without the other could hold an inventory whose
-- catalog was never checked, which is the drift this type exists to prevent.
data DeclaredRetainedArtifacts = DeclaredRetainedArtifacts
  { declaredRetainedArtifactInventory :: !RetainedArtifactInventory
  , declaredRetainedArtifactCatalog :: !RetainedArtifactSourceCatalog
  }
  deriving stock (Eq, Show)

data RetainedArtifactDeclarationError
  = RetainedArtifactDeclarationUnknownArchitecture !Text
  | RetainedArtifactDeclarationUnknownKind !Text
  | RetainedArtifactDeclarationInventoryInvalid !RetainedArtifactInventoryError
  | RetainedArtifactDeclarationSourceInvalid !RetainedArtifactSourceError
  deriving stock (Eq, Show)

renderRetainedArtifactDeclarationError
  :: RetainedArtifactDeclarationError -> String
renderRetainedArtifactDeclarationError = \case
  RetainedArtifactDeclarationUnknownArchitecture value ->
    "Retained artifact declaration names architecture `"
      ++ Text.unpack value
      ++ "`, which is not one of "
      ++ renderKnownArchitectures
      ++ "."
  RetainedArtifactDeclarationUnknownKind value ->
    "Retained artifact declaration names kind `"
      ++ Text.unpack value
      ++ "`, which is not one of "
      ++ renderKnownKinds
      ++ "."
  RetainedArtifactDeclarationInventoryInvalid err ->
    renderRetainedArtifactInventoryError err
  RetainedArtifactDeclarationSourceInvalid err ->
    renderRetainedArtifactSourceError err

renderKnownArchitectures :: String
renderKnownArchitectures =
  renderTokens (map retainedArtifactArchitectureText [minBound .. maxBound])

renderKnownKinds :: String
renderKnownKinds =
  renderTokens (map retainedArtifactKindText [minBound .. maxBound])

renderTokens :: [String] -> String
renderTokens tokens = case tokens of
  [] -> "(none)"
  _ -> foldr1 (\left right -> left ++ ", " ++ right) (map quoted tokens)
 where
  quoted token = "`" ++ token ++ "`"

-- | Project one operator declaration onto the inventory and the source
-- catalog.
--
-- An unrecognized architecture or kind is named rather than dropped: a
-- declaration the operator believes is retained must not become an empty
-- inventory that reports "nothing is retained" and then refuses a repair for a
-- reason that says nothing about the typo.
declaredRetainedArtifacts
  :: RetainedArtifactsSection
  -> Either RetainedArtifactDeclarationError DeclaredRetainedArtifacts
declaredRetainedArtifacts section = do
  architecture <- parseArchitecture (rasArchitecture section)
  parsed <- traverse (parseDeclaration architecture) (rasArtifacts section)
  inventory <-
    first
      RetainedArtifactDeclarationInventoryInvalid
      (retainedArtifactInventory architecture (map fst parsed))
  catalog <-
    first
      RetainedArtifactDeclarationSourceInvalid
      (retainedArtifactSourceCatalog architecture [source | (_, Just source) <- parsed])
  pure
    DeclaredRetainedArtifacts
      { declaredRetainedArtifactInventory = inventory
      , declaredRetainedArtifactCatalog = catalog
      }
 where
  first f = either (Left . f) Right

parseArchitecture
  :: Text -> Either RetainedArtifactDeclarationError RetainedArtifactArchitecture
parseArchitecture value =
  case [ architecture
       | architecture <- [minBound .. maxBound]
       , Text.pack (retainedArtifactArchitectureText architecture) == value
       ] of
    (architecture : _) -> Right architecture
    [] -> Left (RetainedArtifactDeclarationUnknownArchitecture value)

parseKind :: Text -> Either RetainedArtifactDeclarationError RetainedArtifactKind
parseKind value =
  case [ kind
       | kind <- [minBound .. maxBound]
       , Text.pack (retainedArtifactKindText kind) == value
       ] of
    (kind : _) -> Right kind
    [] -> Left (RetainedArtifactDeclarationUnknownKind value)

-- | One declaration becomes one inventory entry and, when it names a source,
-- one source entry carrying the same digest.
parseDeclaration
  :: RetainedArtifactArchitecture
  -> RetainedArtifactDeclaration
  -> Either
       RetainedArtifactDeclarationError
       (RetainedArtifactEntry, Maybe RetainedArtifactSourceEntry)
parseDeclaration architecture declaration = do
  kind <- parseKind (radKind declaration)
  let entry =
        RetainedArtifactEntry
          { retainedArtifactEntryKind = kind
          , retainedArtifactEntryArchitecture = architecture
          , retainedArtifactEntryVersion = Text.unpack (radVersion declaration)
          , retainedArtifactEntryDigest = Text.unpack (radDigest declaration)
          , retainedArtifactEntryRelativePath =
              Text.unpack (radRetainedPath declaration)
          }
      source
        | Text.null (radSourceUrl declaration) = Nothing
        | otherwise =
            Just
              RetainedArtifactSourceEntry
                { retainedArtifactSourceEntryKind = kind
                , retainedArtifactSourceEntryArchitecture = architecture
                , retainedArtifactSourceEntryDigest = radDigest declaration
                , retainedArtifactSourceEntryLocator =
                    RetainedArtifactPinnedArchive (radSourceUrl declaration)
                }
  pure (entry, source)
