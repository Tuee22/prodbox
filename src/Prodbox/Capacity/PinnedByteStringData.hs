{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | Constant-time backing-capacity observation on the pinned ByteString ABI.
-- Supported values come from owned immutable library producers. The snapshot
-- grants no lifetime, mutation permit or complete construction/GC/native bound.
module Prodbox.Capacity.PinnedByteStringData
  ( PinnedByteStringData
  , PinnedByteStringDataError (..)
  , observePinnedByteStringData
  , observeCompactPinnedByteStringData
  , pinnedByteStringDataBytes
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Internal qualified as Bytes
import GHC.Exts (Int (I#), getSizeofMutableByteArray#)
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.IO (IO (..))
import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm (boxedByteViewBytes, boxedCompactBytes)

newtype PinnedByteStringData = PinnedByteStringData Natural
  deriving (Eq, Show)

data PinnedByteStringDataError
  = PinnedByteStringBackingUnsupported
  | PinnedByteStringLengthInvalid
  | PinnedByteStringCompactBoundExceeded !Natural !Natural
  deriving (Eq, Show)

observePinnedByteStringData
  :: ByteString -> IO (Either PinnedByteStringDataError PinnedByteStringData)
observePinnedByteStringData bytes = case Bytes.toForeignPtr bytes of
  (ForeignPtr _ (PlainPtr array), _, lengthBytes) -> do
    let readCapacity state = case getSizeofMutableByteArray# array state of
          (# next, size #) -> (# next, I# size #)
    capacity <- IO readCapacity
    pure $
      if lengthBytes < 0 || lengthBytes > capacity
        then Left PinnedByteStringLengthInvalid
        else Right (PinnedByteStringData (boxedByteViewBytes (fromIntegral capacity) bytes))
  _ -> pure (Left PinnedByteStringBackingUnsupported)

pinnedByteStringDataBytes :: PinnedByteStringData -> Natural
pinnedByteStringDataBytes (PinnedByteStringData bytes) = bytes

-- Corroborate the compact data term on this same value. Word rounding can
-- conservatively cover padding; a larger retained backing refuses. This is
-- a postcondition, not funding for the allocation that created the value.
observeCompactPinnedByteStringData
  :: ByteString -> IO (Either PinnedByteStringDataError PinnedByteStringData)
observeCompactPinnedByteStringData bytes = do
  observed <- observePinnedByteStringData bytes
  pure $ case observed of
    Left cause -> Left cause
    Right backing ->
      let actual = pinnedByteStringDataBytes backing
          expected = boxedCompactBytes bytes
       in if actual <= expected
            then Right backing
            else Left (PinnedByteStringCompactBoundExceeded actual expected)
