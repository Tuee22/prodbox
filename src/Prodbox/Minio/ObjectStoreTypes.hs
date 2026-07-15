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
  , defaultObjectStoreBucket
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)

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

data ConditionalPutResult
  = ConditionalPutApplied
  | ConditionalPutConflict
  deriving (Eq, Show)

defaultObjectStoreBucket :: String
defaultObjectStoreBucket = "prodbox-state"
