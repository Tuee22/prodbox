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
  , RegisteredOwnershipEdge
  , ownershipEdgeStackKey
  , ownershipEdgeResourceKey
  , registeredOwnershipEdges
  , controllerOwnedFamilies
  , registeredStackClusters
  , controllerOwnedFamiliesWithoutRegisteredStack
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
  , SomeManagedResourceDescriptor (SomeManagedResourceDescriptor)
  , cleanupTargetKind
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , managedResourceCoordinate
  , managedResourceKey
  , managedResourceRegistry
  , projectCleanupTarget
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ScopeWire
  , renderScopeWireError
  , scopeFromWire
  , scopeToWire
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

data RegisteredOwnershipEdge = RegisteredOwnershipEdge
  { internalOwnershipEdgeStackKey :: !RegisteredResourceKey
  , internalOwnershipEdgeResourceKey :: !RegisteredResourceKey
  }
  deriving (Eq, Show)

ownershipEdgeStackKey :: RegisteredOwnershipEdge -> RegisteredResourceKey
ownershipEdgeStackKey = internalOwnershipEdgeStackKey

ownershipEdgeResourceKey :: RegisteredOwnershipEdge -> RegisteredResourceKey
ownershipEdgeResourceKey = internalOwnershipEdgeResourceKey

-- | Which registered stack's controllers own each registered resource family.
--
-- __Derived, not authored.__ This was a one-element literal naming
-- @AwsTestKey@ as the owner of the per-run test EBS family, and it was wrong.
-- That family's registered coordinate is keyed on
-- @kubernetes.io\/cluster\/aws-eks-test-cluster=owned@ — the ownership tag AWS
-- applies to volumes an EKS cluster's controllers provision — and
-- @pulumi\/aws-test\/Main.yaml@ declares no cluster at all, while
-- @pulumi\/aws-eks\/Main.yaml@ declares the cluster __and__ installs the EBS
-- CSI driver that creates them.
--
-- The consequence was not cosmetic. 'initialManifestEntries' seeds a stack's
-- write-ahead ownership manifest with its owned resources, and
-- 'projectRegisteredOwnershipEdge' is what admits a discovered resource into
-- that manifest. So the @aws-eks@ manifest could not record the EBS volumes
-- its own cluster created — the exact recovery evidence the manifest exists to
-- carry when both checkpoint copies are unusable — while the @aws-test@
-- manifest could legally adopt volumes that stack never creates.
--
-- Two registry coordinates already contain the answer, so the relation is
-- computed from them rather than restated beside them: the family names the
-- cluster that owns it, and a stack's Pulumi stack name determines the cluster
-- name its program would give an EKS cluster. A family whose cluster matches
-- no registered stack yields no edge, and @prodbox dev check@ fails on that
-- rather than letting it read as "no owner".
registeredOwnershipEdges :: [RegisteredOwnershipEdge]
registeredOwnershipEdges =
  [ RegisteredOwnershipEdge stackKey resourceKey
  | (resourceKey, ownerCluster) <- controllerOwnedFamilies
  , (stackKey, candidateCluster) <- registeredStackClusters
  , ownerCluster == candidateCluster
  ]

-- | Every registered managed resource that declares a controller owner, with
-- the cluster name it names.
controllerOwnedFamilies :: [(RegisteredResourceKey, Text)]
controllerOwnedFamilies =
  [ (managedResourceKey descriptor, ownerCluster)
  | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
  , Just ownerCluster <-
      [coordinateControllerOwnerCluster (managedResourceCoordinate descriptor)]
  ]

-- | Every registered stack, with the cluster name its provisioning program
-- would give an EKS cluster.
registeredStackClusters :: [(RegisteredResourceKey, Text)]
registeredStackClusters =
  [ (managedResourceKey descriptor, candidateCluster)
  | SomeManagedResourceDescriptor descriptor <- managedResourceRegistry
  , Just candidateCluster <-
      [coordinateProvisionedClusterName (managedResourceCoordinate descriptor)]
  ]

-- | A controller-owned family whose cluster matches no registered stack.
--
-- Reported rather than silently dropped: an unmatched family has no owning
-- stack, so no write-ahead manifest may contain it and no destroy order can be
-- derived for it — which is indistinguishable, at the edge list, from a family
-- that genuinely has no controller owner.
controllerOwnedFamiliesWithoutRegisteredStack :: [(RegisteredResourceKey, Text)]
controllerOwnedFamiliesWithoutRegisteredStack =
  [ family
  | family@(_, ownerCluster) <- controllerOwnedFamilies
  , ownerCluster `notElem` map snd registeredStackClusters
  ]

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

-- | The durable envelope of a complete ownership manifest.
--
-- __Sprint 4.92.__ The evidence scope is carried as one nested 'ScopeWire'
-- rather than flattened into seven of this envelope's own fields. The flattened
-- form had no field for the run's retained DNS hosted zone, and its decoder
-- rebuilt the scope through 'mkObservationEvidenceScope', whose contract
-- hardcodes that zone to absent — so every complete manifest that round-tripped
-- through here came back naming no zone, and the exact scope comparisons that
-- bind a manifest to its run compared a zone-less scope against the run's real
-- one. Nesting states the scope's field set once, in
-- "Prodbox.Lifecycle.Teardown.ScopeCodec", where a field added to the scope is a
-- compile error rather than a silent omission.
data DurableCompleteOwnershipManifestWire = DurableCompleteOwnershipManifestWire
  { durableManifestWireVersion :: !Int
  , durableManifestWireStackKey :: !Int
  , durableManifestWireScope :: !ScopeWire
  , durableManifestWirePurposeTag :: !Int
  , durableManifestWirePurposeSurface :: !(Maybe Int)
  , durableManifestWireProvenance :: !Text
  , durableManifestWireManifestVersion :: !Text
  , durableManifestWireDigest :: !Text
  , durableManifestWireLegacyPlanDigest :: !(Maybe Text)
  }
  deriving (Eq, Show, Generic, Serialise)

-- | Version 2 is the first complete-manifest encoding whose scope carries the
-- run's retained DNS hosted zone.
--
-- Version 1 bytes are refused rather than upgraded, and the refusal is the
-- honest answer: a version-1 object was written without a zone, so an upgrade
-- would have to invent one, and the manifest digest committed beside it was
-- computed over a zone-less scope projection that a version-2 reader no longer
-- produces. An upgraded value would satisfy no check it was originally
-- committed against.
durableCompleteManifestWireFormatVersion :: Int
durableCompleteManifestWireFormatVersion = 2

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

-- | The durable envelope of a write-ahead ownership manifest.
--
-- The scope is nested for the reason recorded on
-- 'DurableCompleteOwnershipManifestWire': this envelope flattened the same seven
-- fields, omitted the same DNS hosted zone, and rebuilt the same zone-less scope
-- on read. A write-ahead manifest is the recovery evidence read back when both
-- checkpoint copies are unusable, so a scope it cannot reproduce exactly is a
-- scope the recovery path refuses.
data DurableWriteAheadOwnershipManifestWire
  = DurableWriteAheadOwnershipManifestWire
  { durableWriteAheadWireVersion :: !Int
  , durableWriteAheadWireStackKey :: !Int
  , durableWriteAheadWireScope :: !ScopeWire
  , durableWriteAheadWireDigest :: !Text
  , durableWriteAheadWireEntries :: ![DurableOwnershipManifestEntryWire]
  }
  deriving (Eq, Show, Generic, Serialise)

-- | Version 2 is the first write-ahead encoding whose scope carries the run's
-- retained DNS hosted zone. Version 1 bytes are refused rather than upgraded,
-- for the reason recorded on 'durableCompleteManifestWireFormatVersion'.
durableWriteAheadManifestWireFormatVersion :: Int
durableWriteAheadManifestWireFormatVersion = 2

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
    (durableWriteAheadWireVersion wire == durableWriteAheadManifestWireFormatVersion)
    ( Left
        ( DurableWriteAheadOwnershipManifestVersionUnsupported
            (durableWriteAheadWireVersion wire)
        )
    )
  key <-
    decodeWriteAheadBoundedEnum
      "stack key"
      (durableWriteAheadWireStackKey wire)
  scope <- decodeWriteAheadScopeWire (durableWriteAheadWireScope wire)
  digest <-
    OwnershipManifestDigest
      <$> checkedWriteAheadDigest
        "manifest digest"
        (durableWriteAheadWireDigest wire)
  entries <- mapM writeAheadEntryFromWire (durableWriteAheadWireEntries wire)
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
    { durableManifestWireVersion = durableCompleteManifestWireFormatVersion
    , durableManifestWireStackKey = fromEnum (completeOwnershipManifestStackKey complete)
    , durableManifestWireScope = scopeToWire scope
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
    (durableManifestWireVersion wire == durableCompleteManifestWireFormatVersion)
    ( Left
        ( DurableCompleteOwnershipManifestVersionUnsupported
            (durableManifestWireVersion wire)
        )
    )
  key <- decodeBoundedEnum "stack-key" (durableManifestWireStackKey wire)
  purpose <- decodePurpose wire
  scope <- decodeCompleteScopeWire (durableManifestWireScope wire)
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
  -- The surface that selects the witness is the scope's own. It was encoded
  -- once and used for both before, so 'validateStaticBinding' rechecking the two
  -- against each other was already a check that could not fire; the fields that
  -- genuinely needed guarding were the ones the envelope never encoded.
  let surface = evidenceCleanupSurface scope
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

-- | The canonical scope decoder, mapped into this envelope's error type.
--
-- The field rules live in "Prodbox.Lifecycle.Teardown.ScopeCodec" rather than
-- here. Restating them per envelope is what let this module validate an AWS
-- account as any bounded printable text while another module required twelve
-- digits, and what let the DNS hosted zone go unvalidated because it went
-- unencoded.
decodeCompleteScopeWire
  :: ScopeWire
  -> Either DurableCompleteOwnershipManifestError ObservationEvidenceScope
decodeCompleteScopeWire =
  first (DurableCompleteOwnershipManifestFieldInvalid . renderScopeWireError)
    . scopeFromWire

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
    { durableWriteAheadWireVersion = durableWriteAheadManifestWireFormatVersion
    , durableWriteAheadWireStackKey = fromEnum key
    , durableWriteAheadWireScope = scopeToWire scope
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

-- | The canonical scope decoder, mapped into the write-ahead error type.
decodeWriteAheadScopeWire
  :: ScopeWire
  -> Either DurableWriteAheadOwnershipManifestError ObservationEvidenceScope
decodeWriteAheadScopeWire =
  first (DurableWriteAheadOwnershipManifestFieldInvalid . renderScopeWireError)
    . scopeFromWire

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

provenanceText :: OwnershipManifestProvenance -> Text
provenanceText (OwnershipManifestProvenance value) = value

manifestVersionText :: OwnershipManifestVersion -> Text
manifestVersionText (OwnershipManifestVersion value) = value
