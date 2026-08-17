{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private persistence boundary for complete ownership-manifest
-- evidence.  The public facade exposes capture from an already opaque proof,
-- but raw decoding and restoration stay in this unexposed module so arbitrary
-- fields cannot mint cleanup authority.
module Prodbox.Lifecycle.Teardown.OwnershipManifest.Internal
  ( OwnershipManifestPurposeValue (..)
  , OwnershipManifestDigest (..)
  , ownershipManifestDigestText
  , LegacyAdoptionPlanDigest (..)
  , legacyAdoptionPlanDigestText
  , CompleteOwnershipManifest
  , completeOwnershipManifestStackKey
  , completeOwnershipManifestScope
  , completeOwnershipManifestPurpose
  , completeOwnershipManifestVersion
  , completeOwnershipManifestProvenance
  , completeOwnershipManifestDigest
  , completeOwnershipManifestLegacyPlanDigest
  , mkCompleteOwnershipManifestInternal
  , DurableCompleteOwnershipManifest
  , captureDurableCompleteOwnershipManifest
  , durableCompleteOwnershipManifestBytes
  , durableCompleteOwnershipManifestStackKey
  , durableCompleteOwnershipManifestScope
  , DurableCompleteOwnershipManifestError (..)
  , maximumDurableCompleteOwnershipManifestBytes
  , SomeCompleteOwnershipManifest (..)
  , decodeDurableCompleteOwnershipManifest
  , restoreDurableCompleteOwnershipManifest
  , DurableOwnershipManifestEntryValue (..)
  , DurableWriteAheadOwnershipManifest
  , captureDurableWriteAheadOwnershipManifestInternal
  , durableWriteAheadOwnershipManifestBytes
  , durableWriteAheadOwnershipManifestStackKey
  , durableWriteAheadOwnershipManifestScope
  , durableWriteAheadOwnershipManifestDigest
  , durableWriteAheadOwnershipManifestEntries
  , ObservedDurableWriteAheadOwnershipManifest
  , observedDurableWriteAheadOwnershipManifest
  , observedDurableWriteAheadOwnershipManifestValue
  , observedDurableWriteAheadOwnershipManifestProvenance
  , observedDurableWriteAheadOwnershipManifestVersion
  , DurableWriteAheadOwnershipManifestError (..)
  , maximumDurableWriteAheadOwnershipManifestBytes
  , decodeDurableWriteAheadOwnershipManifest
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl, isDigit, isLower)
import Data.List (nub, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity
  , cleanupTargetKind
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , projectCleanupTarget
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )

data OwnershipManifestPurposeValue
  = WriteAheadOwnershipValue
  | LegacyAdoptionOwnershipValue !CleanupSurface
  deriving (Eq, Ord, Show)

newtype OwnershipManifestDigest = OwnershipManifestDigest Text
  deriving (Eq, Ord, Show)

ownershipManifestDigestText :: OwnershipManifestDigest -> Text
ownershipManifestDigestText (OwnershipManifestDigest digest) = digest

newtype LegacyAdoptionPlanDigest = LegacyAdoptionPlanDigest Text
  deriving (Eq, Ord, Show)

legacyAdoptionPlanDigestText :: LegacyAdoptionPlanDigest -> Text
legacyAdoptionPlanDigestText (LegacyAdoptionPlanDigest digest) = digest

data CompleteOwnershipManifest (surface :: CleanupSurface)
  = CompleteOwnershipManifestInternal
      !(CleanupSurfaceWitness surface)
      !RegisteredResourceKey
      !ObservationEvidenceScope
      !OwnershipManifestPurposeValue
      !OwnershipManifestProvenance
      !OwnershipManifestVersion
      !OwnershipManifestDigest
      !(Maybe LegacyAdoptionPlanDigest)

completeOwnershipManifestStackKey
  :: CompleteOwnershipManifest surface -> RegisteredResourceKey
completeOwnershipManifestStackKey
  (CompleteOwnershipManifestInternal _ key _ _ _ _ _ _) = key

completeOwnershipManifestScope
  :: CompleteOwnershipManifest surface -> ObservationEvidenceScope
completeOwnershipManifestScope
  (CompleteOwnershipManifestInternal _ _ scope _ _ _ _ _) = scope

completeOwnershipManifestPurpose
  :: CompleteOwnershipManifest surface -> OwnershipManifestPurposeValue
completeOwnershipManifestPurpose
  (CompleteOwnershipManifestInternal _ _ _ purpose _ _ _ _) = purpose

completeOwnershipManifestVersion
  :: CompleteOwnershipManifest surface -> OwnershipManifestVersion
completeOwnershipManifestVersion
  (CompleteOwnershipManifestInternal _ _ _ _ _ version _ _) = version

completeOwnershipManifestProvenance
  :: CompleteOwnershipManifest surface -> OwnershipManifestProvenance
completeOwnershipManifestProvenance
  (CompleteOwnershipManifestInternal _ _ _ _ provenance _ _ _) = provenance

completeOwnershipManifestDigest
  :: CompleteOwnershipManifest surface -> OwnershipManifestDigest
completeOwnershipManifestDigest
  (CompleteOwnershipManifestInternal _ _ _ _ _ _ digest _) = digest

completeOwnershipManifestLegacyPlanDigest
  :: CompleteOwnershipManifest surface -> Maybe LegacyAdoptionPlanDigest
completeOwnershipManifestLegacyPlanDigest
  (CompleteOwnershipManifestInternal _ _ _ _ _ _ _ planDigest) = planDigest

mkCompleteOwnershipManifestInternal
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestPurposeValue
  -> OwnershipManifestProvenance
  -> OwnershipManifestVersion
  -> OwnershipManifestDigest
  -> Maybe LegacyAdoptionPlanDigest
  -> CompleteOwnershipManifest surface
mkCompleteOwnershipManifestInternal = CompleteOwnershipManifestInternal

data SomeCompleteOwnershipManifest where
  SomeCompleteOwnershipManifest
    :: CompleteOwnershipManifest surface
    -> SomeCompleteOwnershipManifest

data DurableCompleteOwnershipManifest = DurableCompleteOwnershipManifest
  { internalDurableCompleteOwnershipManifestBytes :: !ByteString
  , internalDurableCompleteOwnershipManifestProof :: !SomeCompleteOwnershipManifest
  }

instance Eq DurableCompleteOwnershipManifest where
  left == right =
    durableCompleteOwnershipManifestBytes left
      == durableCompleteOwnershipManifestBytes right

instance Show DurableCompleteOwnershipManifest where
  show durable =
    "<durable-complete-ownership-manifest:"
      <> show (durableCompleteOwnershipManifestStackKey durable)
      <> ">"

durableCompleteOwnershipManifestBytes
  :: DurableCompleteOwnershipManifest -> ByteString
durableCompleteOwnershipManifestBytes =
  internalDurableCompleteOwnershipManifestBytes

durableCompleteOwnershipManifestStackKey
  :: DurableCompleteOwnershipManifest -> RegisteredResourceKey
durableCompleteOwnershipManifestStackKey durable =
  case internalDurableCompleteOwnershipManifestProof durable of
    SomeCompleteOwnershipManifest complete ->
      completeOwnershipManifestStackKey complete

durableCompleteOwnershipManifestScope
  :: DurableCompleteOwnershipManifest -> ObservationEvidenceScope
durableCompleteOwnershipManifestScope durable =
  case internalDurableCompleteOwnershipManifestProof durable of
    SomeCompleteOwnershipManifest complete ->
      completeOwnershipManifestScope complete

maximumDurableCompleteOwnershipManifestBytes :: Int
maximumDurableCompleteOwnershipManifestBytes = 16 * 1024

data DurableCompleteOwnershipManifestError
  = DurableCompleteOwnershipManifestEmpty
  | DurableCompleteOwnershipManifestTooLarge !Int !Int
  | DurableCompleteOwnershipManifestDecodeFailed !Text
  | DurableCompleteOwnershipManifestNonCanonical
  | DurableCompleteOwnershipManifestVersionUnsupported !Int
  | DurableCompleteOwnershipManifestEnumInvalid !Text !Int
  | DurableCompleteOwnershipManifestFieldInvalid !Text
  | DurableCompleteOwnershipManifestStackUnregistered !RegisteredResourceKey
  | DurableCompleteOwnershipManifestStackNotStack !RegisteredResourceKey !ResourceKind
  | DurableCompleteOwnershipManifestTargetNotAllowed !RegisteredResourceKey !CleanupSurface
  | DurableCompleteOwnershipManifestScopeSurfaceMismatch !CleanupSurface !CleanupSurface
  | DurableCompleteOwnershipManifestScopeOperationInvalid !LifecycleOperation
  | DurableCompleteOwnershipManifestRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | DurableCompleteOwnershipManifestAwsScopeMissing
  | DurableCompleteOwnershipManifestPurposeSurfaceMismatch !CleanupSurface !CleanupSurface
  | DurableCompleteOwnershipManifestWriteAheadPlanUnexpected
  | DurableCompleteOwnershipManifestLegacyPlanMissing
  deriving (Eq, Show)

data DurableCompleteOwnershipManifestWire = DurableCompleteOwnershipManifestWire
  { durableManifestWireVersion :: !Int
  , durableManifestWireSurface :: !Int
  , durableManifestWireStackKey :: !Int
  , durableManifestWireRegistryRevision :: !Text
  , durableManifestWireRunScope :: !Text
  , durableManifestWireFoundation :: !Text
  , durableManifestWireAwsAccount :: !(Maybe Text)
  , durableManifestWireAwsRegion :: !(Maybe Text)
  , durableManifestWireOperation :: !Int
  , durableManifestWirePurposeTag :: !Int
  , durableManifestWirePurposeSurface :: !(Maybe Int)
  , durableManifestWireProvenance :: !Text
  , durableManifestWireManifestVersion :: !Text
  , durableManifestWireDigest :: !Text
  , durableManifestWireLegacyPlanDigest :: !(Maybe Text)
  }
  deriving (Eq, Show, Generic, Serialise)

captureDurableCompleteOwnershipManifest
  :: CompleteOwnershipManifest surface
  -> Either
       DurableCompleteOwnershipManifestError
       DurableCompleteOwnershipManifest
captureDurableCompleteOwnershipManifest complete = do
  let wire = wireFromComplete complete
      bytes = canonicalBytes wire
  when
    (ByteString.length bytes > maximumDurableCompleteOwnershipManifestBytes)
    ( Left
        ( DurableCompleteOwnershipManifestTooLarge
            maximumDurableCompleteOwnershipManifestBytes
            (ByteString.length bytes)
        )
    )
  restored <- restoreWire wire
  pure
    DurableCompleteOwnershipManifest
      { internalDurableCompleteOwnershipManifestBytes = bytes
      , internalDurableCompleteOwnershipManifestProof = restored
      }

decodeDurableCompleteOwnershipManifest
  :: ByteString
  -> Either
       DurableCompleteOwnershipManifestError
       DurableCompleteOwnershipManifest
decodeDurableCompleteOwnershipManifest bytes = do
  when (ByteString.null bytes) (Left DurableCompleteOwnershipManifestEmpty)
  when
    (ByteString.length bytes > maximumDurableCompleteOwnershipManifestBytes)
    ( Left
        ( DurableCompleteOwnershipManifestTooLarge
            maximumDurableCompleteOwnershipManifestBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (DurableCompleteOwnershipManifestDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (canonicalBytes wire == bytes)
    (Left DurableCompleteOwnershipManifestNonCanonical)
  restored <- restoreWire wire
  pure
    DurableCompleteOwnershipManifest
      { internalDurableCompleteOwnershipManifestBytes = bytes
      , internalDurableCompleteOwnershipManifestProof = restored
      }

restoreDurableCompleteOwnershipManifest
  :: DurableCompleteOwnershipManifest -> SomeCompleteOwnershipManifest
restoreDurableCompleteOwnershipManifest =
  internalDurableCompleteOwnershipManifestProof

data DurableOwnershipManifestEntryValue = DurableOwnershipManifestEntryValue
  { durableOwnershipManifestEntryKey :: !RegisteredResourceKey
  , durableOwnershipManifestEntryCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , durableOwnershipManifestEntryObservedIdentities
      :: ![ObservedResourceIdentity]
  }
  deriving (Eq, Ord, Show)

data DurableWriteAheadOwnershipManifest = DurableWriteAheadOwnershipManifest
  { internalDurableWriteAheadOwnershipManifestBytes :: !ByteString
  , internalDurableWriteAheadOwnershipManifestStackKey
      :: !RegisteredResourceKey
  , internalDurableWriteAheadOwnershipManifestScope
      :: !ObservationEvidenceScope
  , internalDurableWriteAheadOwnershipManifestDigest
      :: !OwnershipManifestDigest
  , internalDurableWriteAheadOwnershipManifestEntries
      :: ![DurableOwnershipManifestEntryValue]
  }

instance Eq DurableWriteAheadOwnershipManifest where
  left == right =
    durableWriteAheadOwnershipManifestBytes left
      == durableWriteAheadOwnershipManifestBytes right

instance Show DurableWriteAheadOwnershipManifest where
  show durable =
    "<durable-write-ahead-ownership-manifest:"
      <> show (durableWriteAheadOwnershipManifestStackKey durable)
      <> ">"

durableWriteAheadOwnershipManifestBytes
  :: DurableWriteAheadOwnershipManifest -> ByteString
durableWriteAheadOwnershipManifestBytes =
  internalDurableWriteAheadOwnershipManifestBytes

durableWriteAheadOwnershipManifestStackKey
  :: DurableWriteAheadOwnershipManifest -> RegisteredResourceKey
durableWriteAheadOwnershipManifestStackKey =
  internalDurableWriteAheadOwnershipManifestStackKey

durableWriteAheadOwnershipManifestScope
  :: DurableWriteAheadOwnershipManifest -> ObservationEvidenceScope
durableWriteAheadOwnershipManifestScope =
  internalDurableWriteAheadOwnershipManifestScope

durableWriteAheadOwnershipManifestDigest
  :: DurableWriteAheadOwnershipManifest -> OwnershipManifestDigest
durableWriteAheadOwnershipManifestDigest =
  internalDurableWriteAheadOwnershipManifestDigest

durableWriteAheadOwnershipManifestEntries
  :: DurableWriteAheadOwnershipManifest -> [DurableOwnershipManifestEntryValue]
durableWriteAheadOwnershipManifestEntries =
  internalDurableWriteAheadOwnershipManifestEntries

data ObservedDurableWriteAheadOwnershipManifest
  = ObservedDurableWriteAheadOwnershipManifest
      !DurableWriteAheadOwnershipManifest
      !Text
      !Text

observedDurableWriteAheadOwnershipManifest
  :: Text
  -> Text
  -> DurableWriteAheadOwnershipManifest
  -> Either
       DurableWriteAheadOwnershipManifestError
       ObservedDurableWriteAheadOwnershipManifest
observedDurableWriteAheadOwnershipManifest provenance version durable = do
  checkedProvenance <- checkedWriteAheadText "provenance" 1024 provenance
  checkedVersion <- checkedWriteAheadText "version" 512 version
  Right
    ( ObservedDurableWriteAheadOwnershipManifest
        durable
        checkedProvenance
        checkedVersion
    )

observedDurableWriteAheadOwnershipManifestValue
  :: ObservedDurableWriteAheadOwnershipManifest
  -> DurableWriteAheadOwnershipManifest
observedDurableWriteAheadOwnershipManifestValue
  (ObservedDurableWriteAheadOwnershipManifest durable _ _) = durable

observedDurableWriteAheadOwnershipManifestProvenance
  :: ObservedDurableWriteAheadOwnershipManifest -> Text
observedDurableWriteAheadOwnershipManifestProvenance
  (ObservedDurableWriteAheadOwnershipManifest _ provenance _) = provenance

observedDurableWriteAheadOwnershipManifestVersion
  :: ObservedDurableWriteAheadOwnershipManifest -> Text
observedDurableWriteAheadOwnershipManifestVersion
  (ObservedDurableWriteAheadOwnershipManifest _ _ version) = version

maximumDurableWriteAheadOwnershipManifestBytes :: Int
maximumDurableWriteAheadOwnershipManifestBytes = 32 * 1024

data DurableWriteAheadOwnershipManifestError
  = DurableWriteAheadOwnershipManifestEmpty
  | DurableWriteAheadOwnershipManifestTooLarge !Int !Int
  | DurableWriteAheadOwnershipManifestDecodeFailed !Text
  | DurableWriteAheadOwnershipManifestNonCanonical
  | DurableWriteAheadOwnershipManifestVersionUnsupported !Int
  | DurableWriteAheadOwnershipManifestFieldInvalid !Text
  | DurableWriteAheadOwnershipManifestStackUnregistered !RegisteredResourceKey
  | DurableWriteAheadOwnershipManifestStackNotStack
      !RegisteredResourceKey
      !ResourceKind
  | DurableWriteAheadOwnershipManifestTargetNotAllowed
      !RegisteredResourceKey
      !CleanupSurface
  | DurableWriteAheadOwnershipManifestScopeOperationInvalid !LifecycleOperation
  | DurableWriteAheadOwnershipManifestRegistryRevisionMismatch
      !RegistryRevision
      !RegistryRevision
  | DurableWriteAheadOwnershipManifestAwsScopeMissing
  | DurableWriteAheadOwnershipManifestEntryUnregistered !RegisteredResourceKey
  | DurableWriteAheadOwnershipManifestEntryCoordinateMismatch
      !RegisteredResourceKey
  | DurableWriteAheadOwnershipManifestEntriesNonCanonical
  deriving (Eq, Show)

data DurableOwnershipManifestEntryWire = DurableOwnershipManifestEntryWire
  { durableEntryWireKey :: !Int
  , durableEntryWireCoordinateDigest :: !Text
  , durableEntryWireObservedIdentities :: ![Text]
  }
  deriving (Eq, Show, Generic, Serialise)

data DurableWriteAheadOwnershipManifestWire
  = DurableWriteAheadOwnershipManifestWire
  { durableWriteAheadWireVersion :: !Int
  , durableWriteAheadWireSurface :: !Int
  , durableWriteAheadWireStackKey :: !Int
  , durableWriteAheadWireRegistryRevision :: !Text
  , durableWriteAheadWireRunScope :: !Text
  , durableWriteAheadWireFoundation :: !Text
  , durableWriteAheadWireAwsAccount :: !(Maybe Text)
  , durableWriteAheadWireAwsRegion :: !(Maybe Text)
  , durableWriteAheadWireOperation :: !Int
  , durableWriteAheadWireDigest :: !Text
  , durableWriteAheadWireEntries :: ![DurableOwnershipManifestEntryWire]
  }
  deriving (Eq, Show, Generic, Serialise)

captureDurableWriteAheadOwnershipManifestInternal
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestDigest
  -> [DurableOwnershipManifestEntryValue]
  -> Either
       DurableWriteAheadOwnershipManifestError
       DurableWriteAheadOwnershipManifest
captureDurableWriteAheadOwnershipManifestInternal key scope digest entries = do
  validateWriteAheadBinding key scope entries
  _ <- checkedWriteAheadDigest "manifest digest" (ownershipManifestDigestText digest)
  let wire = writeAheadWireFromValues key scope digest entries
      bytes = canonicalWriteAheadBytes wire
  when
    (ByteString.length bytes > maximumDurableWriteAheadOwnershipManifestBytes)
    ( Left
        ( DurableWriteAheadOwnershipManifestTooLarge
            maximumDurableWriteAheadOwnershipManifestBytes
            (ByteString.length bytes)
        )
    )
  Right
    DurableWriteAheadOwnershipManifest
      { internalDurableWriteAheadOwnershipManifestBytes = bytes
      , internalDurableWriteAheadOwnershipManifestStackKey = key
      , internalDurableWriteAheadOwnershipManifestScope = scope
      , internalDurableWriteAheadOwnershipManifestDigest = digest
      , internalDurableWriteAheadOwnershipManifestEntries = entries
      }

decodeDurableWriteAheadOwnershipManifest
  :: ByteString
  -> Either
       DurableWriteAheadOwnershipManifestError
       DurableWriteAheadOwnershipManifest
decodeDurableWriteAheadOwnershipManifest bytes = do
  when
    (ByteString.null bytes)
    (Left DurableWriteAheadOwnershipManifestEmpty)
  when
    (ByteString.length bytes > maximumDurableWriteAheadOwnershipManifestBytes)
    ( Left
        ( DurableWriteAheadOwnershipManifestTooLarge
            maximumDurableWriteAheadOwnershipManifestBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (DurableWriteAheadOwnershipManifestDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (canonicalWriteAheadBytes wire == bytes)
    (Left DurableWriteAheadOwnershipManifestNonCanonical)
  unless
    (durableWriteAheadWireVersion wire == 1)
    ( Left
        ( DurableWriteAheadOwnershipManifestVersionUnsupported
            (durableWriteAheadWireVersion wire)
        )
    )
  surface <-
    decodeWriteAheadBoundedEnum
      "surface"
      (durableWriteAheadWireSurface wire)
  key <-
    decodeWriteAheadBoundedEnum
      "stack key"
      (durableWriteAheadWireStackKey wire)
  revision <-
    RegistryRevision
      <$> checkedWriteAheadText
        "registry revision"
        512
        (durableWriteAheadWireRegistryRevision wire)
  runScope <-
    DurableObservationRunScope
      <$> checkedWriteAheadText
        "run scope"
        512
        (durableWriteAheadWireRunScope wire)
  foundation <-
    LinuxRke2FoundationId
      <$> checkedWriteAheadText
        "foundation"
        512
        (durableWriteAheadWireFoundation wire)
  awsScope <- decodeWriteAheadAwsScope wire
  operation <-
    decodeWriteAheadLifecycleOperation
      (durableWriteAheadWireOperation wire)
  digest <-
    OwnershipManifestDigest
      <$> checkedWriteAheadDigest
        "manifest digest"
        (durableWriteAheadWireDigest wire)
  entries <- mapM writeAheadEntryFromWire (durableWriteAheadWireEntries wire)
  let scope =
        mkObservationEvidenceScope
          surface
          revision
          runScope
          foundation
          awsScope
          operation
  validateWriteAheadBinding key scope entries
  Right
    DurableWriteAheadOwnershipManifest
      { internalDurableWriteAheadOwnershipManifestBytes = bytes
      , internalDurableWriteAheadOwnershipManifestStackKey = key
      , internalDurableWriteAheadOwnershipManifestScope = scope
      , internalDurableWriteAheadOwnershipManifestDigest = digest
      , internalDurableWriteAheadOwnershipManifestEntries = entries
      }

wireFromComplete
  :: CompleteOwnershipManifest surface -> DurableCompleteOwnershipManifestWire
wireFromComplete complete =
  DurableCompleteOwnershipManifestWire
    { durableManifestWireVersion = 1
    , durableManifestWireSurface = fromEnum (evidenceCleanupSurface scope)
    , durableManifestWireStackKey = fromEnum (completeOwnershipManifestStackKey complete)
    , durableManifestWireRegistryRevision = registryRevisionText (evidenceRegistryRevision scope)
    , durableManifestWireRunScope = runScopeText (evidenceDurableRunScope scope)
    , durableManifestWireFoundation = foundationText (evidenceLinuxRke2Foundation scope)
    , durableManifestWireAwsAccount = accountText <$> evidenceAwsScope scope
    , durableManifestWireAwsRegion = regionText <$> evidenceAwsScope scope
    , durableManifestWireOperation = fromEnumLifecycleOperation (evidenceLifecycleOperation scope)
    , durableManifestWirePurposeTag = purposeTag purpose
    , durableManifestWirePurposeSurface = purposeSurface purpose
    , durableManifestWireProvenance = provenanceText (completeOwnershipManifestProvenance complete)
    , durableManifestWireManifestVersion = manifestVersionText (completeOwnershipManifestVersion complete)
    , durableManifestWireDigest = ownershipManifestDigestText (completeOwnershipManifestDigest complete)
    , durableManifestWireLegacyPlanDigest =
        legacyAdoptionPlanDigestText
          <$> completeOwnershipManifestLegacyPlanDigest complete
    }
 where
  scope = completeOwnershipManifestScope complete
  purpose = completeOwnershipManifestPurpose complete

restoreWire
  :: DurableCompleteOwnershipManifestWire
  -> Either
       DurableCompleteOwnershipManifestError
       SomeCompleteOwnershipManifest
restoreWire wire = do
  unless
    (durableManifestWireVersion wire == 1)
    ( Left
        ( DurableCompleteOwnershipManifestVersionUnsupported
            (durableManifestWireVersion wire)
        )
    )
  surface <- decodeBoundedEnum "surface" (durableManifestWireSurface wire)
  key <- decodeBoundedEnum "stack-key" (durableManifestWireStackKey wire)
  operation <- decodeLifecycleOperation (durableManifestWireOperation wire)
  purpose <- decodePurpose wire
  revision <-
    RegistryRevision <$> checkedText "registry revision" 512 (durableManifestWireRegistryRevision wire)
  runScope <-
    DurableObservationRunScope <$> checkedText "run scope" 512 (durableManifestWireRunScope wire)
  foundation <-
    LinuxRke2FoundationId <$> checkedText "foundation" 512 (durableManifestWireFoundation wire)
  awsScope <- decodeAwsScope wire
  provenance <-
    OwnershipManifestProvenance
      <$> checkedText "manifest provenance" 1024 (durableManifestWireProvenance wire)
  manifestVersion <-
    OwnershipManifestVersion
      <$> checkedText "manifest version" 512 (durableManifestWireManifestVersion wire)
  digest <-
    OwnershipManifestDigest
      <$> checkedDigest "manifest digest" (durableManifestWireDigest wire)
  legacyPlan <-
    traverse
      (fmap LegacyAdoptionPlanDigest . checkedDigest "legacy plan digest")
      (durableManifestWireLegacyPlanDigest wire)
  let scope =
        mkObservationEvidenceScope
          surface
          revision
          runScope
          foundation
          awsScope
          operation
  validateStaticBinding surface key scope purpose legacyPlan
  case surface of
    LocalOnly -> restoreWith LocalOnlySurface key scope purpose provenance manifestVersion digest legacyPlan
    Cascade -> restoreWith CascadeSurface key scope purpose provenance manifestVersion digest legacyPlan
    ExplicitPerRun -> restoreWith ExplicitPerRunSurface key scope purpose provenance manifestVersion digest legacyPlan
    OperationalTeardown ->
      restoreWith
        OperationalTeardownSurface
        key
        scope
        purpose
        provenance
        manifestVersion
        digest
        legacyPlan
    ExplicitLongLived ->
      restoreWith ExplicitLongLivedSurface key scope purpose provenance manifestVersion digest legacyPlan
    TotalDecommission ->
      restoreWith TotalDecommissionSurface key scope purpose provenance manifestVersion digest legacyPlan

restoreWith
  :: CleanupSurfaceWitness surface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestPurposeValue
  -> OwnershipManifestProvenance
  -> OwnershipManifestVersion
  -> OwnershipManifestDigest
  -> Maybe LegacyAdoptionPlanDigest
  -> Either DurableCompleteOwnershipManifestError SomeCompleteOwnershipManifest
restoreWith witness key scope purpose provenance version digest legacyPlan =
  pure
    ( SomeCompleteOwnershipManifest
        ( mkCompleteOwnershipManifestInternal
            witness
            key
            scope
            purpose
            provenance
            version
            digest
            legacyPlan
        )
    )

validateStaticBinding
  :: CleanupSurface
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestPurposeValue
  -> Maybe LegacyAdoptionPlanDigest
  -> Either DurableCompleteOwnershipManifestError ()
validateStaticBinding surface key scope purpose legacyPlan = do
  identity <-
    maybe
      (Left (DurableCompleteOwnershipManifestStackUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  unless
    (registeredIdentityKind identity == Stack)
    ( Left
        ( DurableCompleteOwnershipManifestStackNotStack
            key
            (registeredIdentityKind identity)
        )
    )
  unless
    (targetAllowed surface identity)
    (Left (DurableCompleteOwnershipManifestTargetNotAllowed key surface))
  unless
    (evidenceCleanupSurface scope == surface)
    ( Left
        ( DurableCompleteOwnershipManifestScopeSurfaceMismatch
            surface
            (evidenceCleanupSurface scope)
        )
    )
  unless
    (evidenceLifecycleOperation scope == ReconcileDesiredAbsent)
    ( Left
        ( DurableCompleteOwnershipManifestScopeOperationInvalid
            (evidenceLifecycleOperation scope)
        )
    )
  unless
    (evidenceRegistryRevision scope == lifecycleRegistryRevision)
    ( Left
        ( DurableCompleteOwnershipManifestRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
    )
  when
    (evidenceAwsScope scope == Nothing)
    (Left DurableCompleteOwnershipManifestAwsScopeMissing)
  case purpose of
    WriteAheadOwnershipValue ->
      when
        (legacyPlan /= Nothing)
        (Left DurableCompleteOwnershipManifestWriteAheadPlanUnexpected)
    LegacyAdoptionOwnershipValue purposeSurfaceValue -> do
      unless
        (purposeSurfaceValue == surface)
        ( Left
            ( DurableCompleteOwnershipManifestPurposeSurfaceMismatch
                surface
                purposeSurfaceValue
            )
        )
      when
        (legacyPlan == Nothing)
        (Left DurableCompleteOwnershipManifestLegacyPlanMissing)

targetAllowed :: CleanupSurface -> RegisteredIdentity -> Bool
targetAllowed surface identity = case surface of
  LocalOnly -> allowed LocalOnlySurface
  Cascade -> allowed CascadeSurface
  ExplicitPerRun -> allowed ExplicitPerRunSurface
  OperationalTeardown -> allowed OperationalTeardownSurface
  ExplicitLongLived -> allowed ExplicitLongLivedSurface
  TotalDecommission -> allowed TotalDecommissionSurface
 where
  allowed :: CleanupSurfaceWitness selected -> Bool
  allowed witness = case projectCleanupTarget witness identity of
    Right target -> cleanupTargetKind target == Stack
    Left _ -> False

decodePurpose
  :: DurableCompleteOwnershipManifestWire
  -> Either DurableCompleteOwnershipManifestError OwnershipManifestPurposeValue
decodePurpose wire = case durableManifestWirePurposeTag wire of
  0 -> case durableManifestWirePurposeSurface wire of
    Nothing -> Right WriteAheadOwnershipValue
    Just _ -> Left (DurableCompleteOwnershipManifestFieldInvalid "write-ahead purpose carried a surface")
  1 -> case durableManifestWirePurposeSurface wire of
    Nothing -> Left (DurableCompleteOwnershipManifestFieldInvalid "legacy purpose omitted its surface")
    Just raw -> LegacyAdoptionOwnershipValue <$> decodeBoundedEnum "purpose surface" raw
  other -> Left (DurableCompleteOwnershipManifestEnumInvalid "purpose" other)

decodeAwsScope
  :: DurableCompleteOwnershipManifestWire
  -> Either DurableCompleteOwnershipManifestError (Maybe AwsScope)
decodeAwsScope wire = case (durableManifestWireAwsAccount wire, durableManifestWireAwsRegion wire) of
  (Nothing, Nothing) -> Right Nothing
  (Just account, Just region) -> do
    accountId <- AwsAccountId <$> checkedText "AWS account" 128 account
    awsRegion <- AwsRegion <$> checkedText "AWS region" 128 region
    Right (Just (AwsScope accountId awsRegion))
  _ -> Left (DurableCompleteOwnershipManifestFieldInvalid "AWS scope was only partially encoded")

decodeBoundedEnum
  :: forall value
   . (Bounded value, Enum value)
  => Text
  -> Int
  -> Either DurableCompleteOwnershipManifestError value
decodeBoundedEnum label raw
  | raw < fromEnum (minBound :: value) || raw > fromEnum (maxBound :: value) =
      Left (DurableCompleteOwnershipManifestEnumInvalid label raw)
  | otherwise = Right (toEnum raw)

decodeLifecycleOperation
  :: Int -> Either DurableCompleteOwnershipManifestError LifecycleOperation
decodeLifecycleOperation raw = case raw of
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  _ -> Left (DurableCompleteOwnershipManifestEnumInvalid "lifecycle operation" raw)

fromEnumLifecycleOperation :: LifecycleOperation -> Int
fromEnumLifecycleOperation operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

purposeTag :: OwnershipManifestPurposeValue -> Int
purposeTag purpose = case purpose of
  WriteAheadOwnershipValue -> 0
  LegacyAdoptionOwnershipValue _ -> 1

purposeSurface :: OwnershipManifestPurposeValue -> Maybe Int
purposeSurface purpose = case purpose of
  WriteAheadOwnershipValue -> Nothing
  LegacyAdoptionOwnershipValue surface -> Just (fromEnum surface)

checkedText
  :: Text
  -> Int
  -> Text
  -> Either DurableCompleteOwnershipManifestError Text
checkedText label maximumLength value
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "was too long"
  | Text.any (\character -> not (isAscii character) || isControl character) value =
      invalid "contained a non-printable character"
  | otherwise = Right value
 where
  invalid detail =
    Left
      ( DurableCompleteOwnershipManifestFieldInvalid
          (label <> " " <> detail)
      )

checkedDigest
  :: Text -> Text -> Either DurableCompleteOwnershipManifestError Text
checkedDigest label value
  | Text.length value == 64 && Text.all isLowerHex value = Right value
  | otherwise =
      Left
        ( DurableCompleteOwnershipManifestFieldInvalid
            (label <> " was not a canonical SHA-256 digest")
        )
 where
  isLowerHex character =
    isDigit character || (isLower character && character >= 'a' && character <= 'f')

writeAheadWireFromValues
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> OwnershipManifestDigest
  -> [DurableOwnershipManifestEntryValue]
  -> DurableWriteAheadOwnershipManifestWire
writeAheadWireFromValues key scope digest entries =
  DurableWriteAheadOwnershipManifestWire
    { durableWriteAheadWireVersion = 1
    , durableWriteAheadWireSurface = fromEnum (evidenceCleanupSurface scope)
    , durableWriteAheadWireStackKey = fromEnum key
    , durableWriteAheadWireRegistryRevision =
        registryRevisionText (evidenceRegistryRevision scope)
    , durableWriteAheadWireRunScope =
        runScopeText (evidenceDurableRunScope scope)
    , durableWriteAheadWireFoundation =
        foundationText (evidenceLinuxRke2Foundation scope)
    , durableWriteAheadWireAwsAccount =
        accountText <$> evidenceAwsScope scope
    , durableWriteAheadWireAwsRegion =
        regionText <$> evidenceAwsScope scope
    , durableWriteAheadWireOperation =
        fromEnumLifecycleOperation (evidenceLifecycleOperation scope)
    , durableWriteAheadWireDigest = ownershipManifestDigestText digest
    , durableWriteAheadWireEntries = map writeAheadEntryToWire entries
    }

writeAheadEntryToWire
  :: DurableOwnershipManifestEntryValue
  -> DurableOwnershipManifestEntryWire
writeAheadEntryToWire entry =
  DurableOwnershipManifestEntryWire
    { durableEntryWireKey = fromEnum (durableOwnershipManifestEntryKey entry)
    , durableEntryWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (durableOwnershipManifestEntryCoordinateDigest entry)
    , durableEntryWireObservedIdentities =
        [ identity
        | ObservedResourceIdentity identity <-
            durableOwnershipManifestEntryObservedIdentities entry
        ]
    }

writeAheadEntryFromWire
  :: DurableOwnershipManifestEntryWire
  -> Either
       DurableWriteAheadOwnershipManifestError
       DurableOwnershipManifestEntryValue
writeAheadEntryFromWire wire = do
  key <- decodeWriteAheadBoundedEnum "entry key" (durableEntryWireKey wire)
  identity <-
    maybe
      (Left (DurableWriteAheadOwnershipManifestEntryUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  let coordinate = registeredIdentityCoordinateDigest identity
  unless
    ( durableEntryWireCoordinateDigest wire
        == managedResourceCoordinateDigestText coordinate
    )
    ( Left
        (DurableWriteAheadOwnershipManifestEntryCoordinateMismatch key)
    )
  observed <-
    mapM
      ( fmap ObservedResourceIdentity
          . checkedWriteAheadText "observed identity" 1024
      )
      (durableEntryWireObservedIdentities wire)
  Right
    DurableOwnershipManifestEntryValue
      { durableOwnershipManifestEntryKey = key
      , durableOwnershipManifestEntryCoordinateDigest = coordinate
      , durableOwnershipManifestEntryObservedIdentities = observed
      }

validateWriteAheadBinding
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> [DurableOwnershipManifestEntryValue]
  -> Either DurableWriteAheadOwnershipManifestError ()
validateWriteAheadBinding key scope entries = do
  identity <-
    maybe
      (Left (DurableWriteAheadOwnershipManifestStackUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  unless
    (registeredIdentityKind identity == Stack)
    ( Left
        ( DurableWriteAheadOwnershipManifestStackNotStack
            key
            (registeredIdentityKind identity)
        )
    )
  unless
    (targetAllowed (evidenceCleanupSurface scope) identity)
    ( Left
        ( DurableWriteAheadOwnershipManifestTargetNotAllowed
            key
            (evidenceCleanupSurface scope)
        )
    )
  unless
    (evidenceLifecycleOperation scope == ReconcileDesiredPresent)
    ( Left
        ( DurableWriteAheadOwnershipManifestScopeOperationInvalid
            (evidenceLifecycleOperation scope)
        )
    )
  unless
    (evidenceRegistryRevision scope == lifecycleRegistryRevision)
    ( Left
        ( DurableWriteAheadOwnershipManifestRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
    )
  when
    (evidenceAwsScope scope == Nothing)
    (Left DurableWriteAheadOwnershipManifestAwsScopeMissing)
  when
    ( null entries
        || length entries > 32
        || entries /= sortOn durableOwnershipManifestEntryKey entries
        || map durableOwnershipManifestEntryKey entries
          /= nub (map durableOwnershipManifestEntryKey entries)
        || any nonCanonicalIdentities entries
    )
    (Left DurableWriteAheadOwnershipManifestEntriesNonCanonical)
  mapM_ validateEntry entries
 where
  nonCanonicalIdentities entry =
    let identities = durableOwnershipManifestEntryObservedIdentities entry
     in length identities > 128
          || identities /= sort identities
          || identities /= nub identities

  validateEntry entry = do
    identity <-
      maybe
        ( Left
            ( DurableWriteAheadOwnershipManifestEntryUnregistered
                (durableOwnershipManifestEntryKey entry)
            )
        )
        Right
        (lookupRegisteredIdentity (durableOwnershipManifestEntryKey entry))
    unless
      ( durableOwnershipManifestEntryCoordinateDigest entry
          == registeredIdentityCoordinateDigest identity
      )
      ( Left
          ( DurableWriteAheadOwnershipManifestEntryCoordinateMismatch
              (durableOwnershipManifestEntryKey entry)
          )
      )
    mapM_
      ( \(ObservedResourceIdentity value) ->
          checkedWriteAheadText "observed identity" 1024 value >> Right ()
      )
      (durableOwnershipManifestEntryObservedIdentities entry)

decodeWriteAheadAwsScope
  :: DurableWriteAheadOwnershipManifestWire
  -> Either DurableWriteAheadOwnershipManifestError (Maybe AwsScope)
decodeWriteAheadAwsScope wire =
  case ( durableWriteAheadWireAwsAccount wire
       , durableWriteAheadWireAwsRegion wire
       ) of
    (Nothing, Nothing) -> Right Nothing
    (Just account, Just region) -> do
      accountId <-
        AwsAccountId <$> checkedWriteAheadText "AWS account" 128 account
      awsRegion <-
        AwsRegion <$> checkedWriteAheadText "AWS region" 128 region
      Right (Just (AwsScope accountId awsRegion))
    _ ->
      Left
        ( DurableWriteAheadOwnershipManifestFieldInvalid
            "AWS scope was only partially encoded"
        )

decodeWriteAheadLifecycleOperation
  :: Int
  -> Either DurableWriteAheadOwnershipManifestError LifecycleOperation
decodeWriteAheadLifecycleOperation raw = case raw of
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  _ ->
    Left
      ( DurableWriteAheadOwnershipManifestFieldInvalid
          "lifecycle operation was outside the closed enum"
      )

decodeWriteAheadBoundedEnum
  :: forall value
   . (Bounded value, Enum value)
  => Text
  -> Int
  -> Either DurableWriteAheadOwnershipManifestError value
decodeWriteAheadBoundedEnum label raw
  | raw < fromEnum (minBound :: value)
      || raw > fromEnum (maxBound :: value) =
      Left
        ( DurableWriteAheadOwnershipManifestFieldInvalid
            (label <> " was outside the closed enum")
        )
  | otherwise = Right (toEnum raw)

checkedWriteAheadText
  :: Text
  -> Int
  -> Text
  -> Either DurableWriteAheadOwnershipManifestError Text
checkedWriteAheadText label maximumLength value
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "was too long"
  | Text.any (\character -> not (isAscii character) || isControl character) value =
      invalid "contained a non-printable character"
  | otherwise = Right value
 where
  invalid detail =
    Left
      ( DurableWriteAheadOwnershipManifestFieldInvalid
          (label <> " " <> detail)
      )

checkedWriteAheadDigest
  :: Text
  -> Text
  -> Either DurableWriteAheadOwnershipManifestError Text
checkedWriteAheadDigest label value
  | Text.length value == 64 && Text.all isLowerHex value = Right value
  | otherwise =
      Left
        ( DurableWriteAheadOwnershipManifestFieldInvalid
            (label <> " was not a canonical SHA-256 digest")
        )
 where
  isLowerHex character =
    isDigit character
      || (isLower character && character >= 'a' && character <= 'f')

canonicalWriteAheadBytes
  :: DurableWriteAheadOwnershipManifestWire -> ByteString
canonicalWriteAheadBytes = LazyByteString.toStrict . serialise

canonicalBytes :: DurableCompleteOwnershipManifestWire -> ByteString
canonicalBytes = LazyByteString.toStrict . serialise

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

accountText :: AwsScope -> Text
accountText (AwsScope (AwsAccountId value) _) = value

regionText :: AwsScope -> Text
regionText (AwsScope _ (AwsRegion value)) = value

provenanceText :: OwnershipManifestProvenance -> Text
provenanceText (OwnershipManifestProvenance value) = value

manifestVersionText :: OwnershipManifestVersion -> Text
manifestVersionText (OwnershipManifestVersion value) = value
