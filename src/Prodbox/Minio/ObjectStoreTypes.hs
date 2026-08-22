-- | Shared Model-B object-store value types. Extracted from
-- "Prodbox.Minio.ObjectStore" (Sprint 1.66) so both the subprocess client
-- ("Prodbox.Minio.ObjectStore") and the native SigV4 client
-- ("Prodbox.Minio.ObjectStoreNative") can share them without a circular import.
-- @Prodbox.Minio.ObjectStore@ re-exports every name here, so external importers
-- are unchanged.
module Prodbox.Minio.ObjectStoreTypes
  ( ObjectStoreConfig (..)
  , ObjectStoreBackend (..)
  , ObjectVersion (..)
  , VersionedObject (..)
  , ConditionalPutResult (..)
  , ConditionalDeleteResult (..)
  , defaultObjectStoreBucket
  , minioSigningRegion
  , minioSigningRegionBytes
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)

-- | Sprint 1.91: the one SigV4 signing scope the Model-B object store is
-- addressed under.
--
-- Three constants stated this same fact — the subprocess backend's, the native
-- client's, and the container registry's storage backend — and the subprocess
-- and native arms are deliberately substitutable. A signing-region divergence
-- between two substitutable arms presents as a signature mismatch that names
-- neither of them, so agreeing today is not the same as being one value.
--
-- __It is not an AWS coordinate.__ MinIO requires a region in the SigV4 scope
-- string and ignores which one; no AWS account is reached and no AWS namespace
-- is consulted. It is @config_doctrine.md@ § 0's second compiled class ("not
-- AWS"), not a deployment choice, and it does not move to Dhall.
minioSigningRegion :: String
minioSigningRegion = "us-east-1"

-- | 'minioSigningRegion' in the encoding the signing algebra consumes.
minioSigningRegionBytes :: ByteString
minioSigningRegionBytes = BS8.pack minioSigningRegion

data ObjectStoreConfig = ObjectStoreConfig
  { objectStoreEndpoint :: String
  , objectStoreBucket :: String
  , objectStoreAccessKey :: String
  , objectStoreSecretKey :: String
  }
  deriving (Eq, Show)

-- | Which client performs Model-B object-store operations. Sprint 1.66 adds the
-- native SigV4 client; the @aws@ CLI subprocess remains the default and the
-- config-selectable rollback until the native client's live-MinIO parity is
-- proven, after which the subprocess path is retired through the deletion
-- ledger.
data ObjectStoreBackend
  = ObjectStoreSubprocess
  | ObjectStoreNative
  deriving (Eq, Show)

-- | Opaque object generation returned by the S3-compatible store.  Callers
-- may compare or feed it back to a conditional put, but cannot manufacture a
-- generation from untrusted payload data.
newtype ObjectVersion = ObjectVersion {objectVersionEtag :: Text}
  deriving (Eq, Ord, Show)

data VersionedObject = VersionedObject
  { versionedObjectBytes :: ByteString
  , versionedObjectVersion :: ObjectVersion
  }
  deriving (Eq, Show)

-- | The outcome of a conditional put. Sprint 1.76: the applied arm carries the
-- version the store returned for the write it just accepted — the receipt of a
-- round trip that actually landed. Discarding it was what left every caller
-- unable to distinguish "a write reached the store" from "I decided one had",
-- so the receipt is threaded rather than dropped.
data ConditionalPutResult
  = ConditionalPutApplied !ObjectVersion
  | ConditionalPutConflict
  deriving (Eq, Show)

data ConditionalDeleteResult
  = ConditionalDeleteApplied
  | ConditionalDeleteConflict
  deriving (Eq, Show)

defaultObjectStoreBucket :: String
defaultObjectStoreBucket = "prodbox-state"
