{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Sprint 4.50: the deterministic decommission inventory that the receipt is
-- bound to.
--
-- A 'DecommissionManifest' is the signed plan a total-teardown run commits to
-- before the point of no return: the ordered set of typed nodes it will destroy,
-- read back, and prove absent, tagged with the cluster identity it decommissions.
-- Its canonical digest ('decommissionManifestDigest') is the exact
-- 'Prodbox.Lifecycle.Decommission.Frame.FrameDigest' every receipt frame carries,
-- so a receipt can never be replayed against a different plan — reopening a
-- receipt under a manifest whose digest differs is a chain refusal, not a resume.
--
-- The manifest is opaque: it is only reachable through 'mkDecommissionManifest',
-- which rejects an empty or duplicated inventory, an invalid cluster identity, and
-- an invalid target reference, so a malformed plan cannot be digested or committed.
-- The typed-graph ordering over these nodes (TLS objects before the shared bucket,
-- SES IAM destroy/read-back before target/custody tombstones, backup and shared
-- bucket last) and the retained-Model-B receipt-commit are separate increments.
module Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , DecommissionManifest
  , ManifestError (..)
  , currentManifestVersion
  , mkDecommissionManifest
  , manifestVersion
  , manifestClusterId
  , manifestNodes
  , decommissionManifestDigest
  , ManifestCodecError (..)
  , encodeDecommissionManifest
  , decodeDecommissionManifest
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest, contentDigest)

-- | A typed unit of decommission work. Singleton nodes name a unique resource
-- class; 'TargetGeneration' is parameterised by the target reference because a
-- run may tombstone several Target Secret Agent generations.
data DecommissionNode
  = -- | Prove every SES consumer quiescent before destroying the provider.
    SesConsumerQuiescence
  | -- | Destroy and read back the SES provider stack.
    SesProviderStack
  | -- | Destroy and read back the external SMTP IAM family.
    SesSmtpIam
  | -- | Tombstone and read back one Target Secret Agent generation.
    TargetGeneration !Text
  | -- | Tombstone and read back retained-home custody.
    RetainedCustody
  | -- | Delete the retained TLS objects and versions (never the shared bucket).
    TlsRetainedObjects
  | -- | Delete the TLS retention identity.
    TlsRetentionIdentity
  | -- | Prove every registered backup prefix absent before deleting backup state.
    BackupPrefixAbsenceProof
  | -- | Delete the backup objects and identity.
    BackupObjects
  | -- | Delete the shared object bucket — always last.
    SharedObjectBucket
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | The deterministic signed inventory. Opaque: build it through
-- 'mkDecommissionManifest'.
data DecommissionManifest = DecommissionManifest
  { manifestVersion :: !Word
  , manifestClusterId :: !Text
  , manifestNodes :: ![DecommissionNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ManifestError
  = ManifestClusterIdInvalid
  | ManifestNodesEmpty
  | ManifestNodesDuplicated
  | ManifestTargetRefInvalid
  deriving stock (Eq, Show)

currentManifestVersion :: Word
currentManifestVersion = 1

-- | Build a validated manifest: a non-empty, duplicate-free node inventory under a
-- well-formed cluster identity, with every target reference well-formed.
mkDecommissionManifest
  :: Text
  -> [DecommissionNode]
  -> Either ManifestError DecommissionManifest
mkDecommissionManifest clusterId nodes
  | not (validIdentifier clusterId) = Left ManifestClusterIdInvalid
  | null nodes = Left ManifestNodesEmpty
  | any (not . validTargetNode) nodes = Left ManifestTargetRefInvalid
  | nub nodes /= nodes = Left ManifestNodesDuplicated
  | otherwise =
      Right
        DecommissionManifest
          { manifestVersion = currentManifestVersion
          , manifestClusterId = Text.strip clusterId
          , manifestNodes = nodes
          }
 where
  validTargetNode node = case node of
    TargetGeneration reference -> validIdentifier reference
    _ -> True

-- | The canonical digest that binds a receipt to this exact plan.
decommissionManifestDigest :: DecommissionManifest -> FrameDigest
decommissionManifestDigest =
  contentDigest . LazyByteString.toStrict . serialise

data ManifestCodecError
  = ManifestEnvelopeTooLarge
  | ManifestEnvelopeInvalid
  | ManifestEnvelopeUnsupportedVersion
  | ManifestEnvelopeNonCanonical
  deriving stock (Eq, Show)

-- | Canonical manifest bytes. The manifest is its own versioned envelope (it
-- carries 'manifestVersion'), so a separate wrapper is unnecessary.
encodeDecommissionManifest :: DecommissionManifest -> ByteString
encodeDecommissionManifest = serialise

-- | Decode a manifest from @maximumBytes@-bounded canonical bytes, refusing
-- oversize, non-canonical, and unsupported-version input before it can be
-- committed or resumed.
decodeDecommissionManifest
  :: Int -> ByteString -> Either ManifestCodecError DecommissionManifest
decodeDecommissionManifest maximumBytes bytes
  | maximumBytes < 0 = Left ManifestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left ManifestEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left ManifestEnvelopeInvalid
        Right manifest
          | manifestVersion manifest /= currentManifestVersion ->
              Left ManifestEnvelopeUnsupportedVersion
          | serialise manifest /= bytes -> Left ManifestEnvelopeNonCanonical
          | otherwise -> Right manifest

validIdentifier :: Text -> Bool
validIdentifier value =
  not (Text.null trimmed)
    && Text.length trimmed <= 128
    && not (Text.any isControl trimmed)
 where
  trimmed = Text.strip value
