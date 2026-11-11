{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Native environment data for an explicitly owned subprocess. Capturing or
-- editing this value grants no process slot, deadline or authority capability.
module Prodbox.Subprocess.ProcessEnvironment
  ( ProcessEnvironment
  , ProcessEnvironmentUsage (..)
  , ProcessEnvironmentError (..)
  , emptyProcessEnvironment
  , captureProcessEnvironmentBefore
  , overlayProcessEnvironment
  , filterProcessEnvironment
  , processEnvironmentUsage
  , processEnvironmentNativeEntries
  , processEnvironmentNormalFormBytes
  ) where

import Control.Exception (IOException, evaluate, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.Set qualified as Set
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Foreign qualified as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm
import System.Posix.Env.ByteString qualified as Native

-- Values deliberately have no Show or serialized representation.
data ProcessEnvironment
  = ProcessEnvironment ![(ByteString, ByteString)] !ProcessEnvironmentUsage

data ProcessEnvironmentUsage = ProcessEnvironmentUsage
  { processEnvironmentEntryCount :: !Natural
  , processEnvironmentEncodedBytes :: !Natural
  }
  deriving (Eq, Show)

data ProcessEnvironmentError
  = ProcessEnvironmentDeadlineReached
  | ProcessEnvironmentOverlayInvalid
  | ProcessEnvironmentIoRefused !IOErrorType !(Maybe Int)
  deriving (Eq, Show)

emptyProcessEnvironment :: ProcessEnvironment
emptyProcessEnvironment = fromEntries []

captureProcessEnvironmentBefore :: Word64 -> IO (Either ProcessEnvironmentError ProcessEnvironment)
captureProcessEnvironmentBefore ending = ioResult $ do
  before <- getMonotonicTimeNSec
  if before >= ending
    then pure (Left ProcessEnvironmentDeadlineReached)
    else do
      -- The convenience POSIX pair API assumes every entry contains '='.
      -- The raw API lets us retain GHC's accepted no-separator/empty-key
      -- behavior without decoding values into linked lists of characters.
      raw <- Native.getEnvironmentPrim
      captured <- evaluate (fromEntries (map splitEntry raw))
      after <- getMonotonicTimeNSec
      pure $
        if after >= ending
          then Left ProcessEnvironmentDeadlineReached
          else Right captured

overlayProcessEnvironment
  :: [(String, String)]
  -> ProcessEnvironment
  -> IO (Either ProcessEnvironmentError ProcessEnvironment)
overlayProcessEnvironment overrides (ProcessEnvironment inherited _)
  | any invalid overrides = pure (Left ProcessEnvironmentOverlayInvalid)
  | otherwise = ioResult $ do
      encoding <- getFileSystemEncoding
      let encode value = GHC.withCStringLen encoding value Bytes.packCStringLen
          encodePair (key, value) = (,) <$> encode key <*> encode value
      encoded <- traverse encodePair overrides
      let replaced = Set.fromList (map fst encoded)
      result <- evaluate (fromEntries (encoded <> filter (not . (`Set.member` replaced) . fst) inherited))
      pure (Right result)
 where
  invalid (key, value) = null key || '=' `elem` key || '\0' `elem` key || '\0' `elem` value

filterProcessEnvironment :: (ByteString -> Bool) -> ProcessEnvironment -> ProcessEnvironment
filterProcessEnvironment keep (ProcessEnvironment entries _) = fromEntries (filter (keep . fst) entries)

processEnvironmentUsage :: ProcessEnvironment -> ProcessEnvironmentUsage
processEnvironmentUsage (ProcessEnvironment _ usage) = usage

processEnvironmentNativeEntries :: ProcessEnvironment -> [(ByteString, ByteString)]
processEnvironmentNativeEntries (ProcessEnvironment entries _) = entries

splitEntry :: ByteString -> (ByteString, ByteString)
splitEntry raw =
  let (key, suffix) = Bytes.break (== 61) raw
   in (key, Bytes.drop 1 suffix)

-- Force the pair/byte metadata while computing exact encoded input usage.
-- This is not a decoded-heap or native-allocation bound.
fromEntries :: [(ByteString, ByteString)] -> ProcessEnvironment
fromEntries entries = ProcessEnvironment entries (foldl' add (ProcessEnvironmentUsage 0 0) entries)
 where
  add (ProcessEnvironmentUsage count size) (key, value) =
    ProcessEnvironmentUsage
      (count + 1)
      (size + fromIntegral (Bytes.length key) + fromIntegral (Bytes.length value) + 2)

ioResult
  :: IO (Either ProcessEnvironmentError value) -> IO (Either ProcessEnvironmentError value)
ioResult action = do
  result <- try action
  pure $ case result of
    Left (cause :: IOException) ->
      Left (ProcessEnvironmentIoRefused (ioe_type cause) (fromIntegral <$> ioe_errno cause))
    Right value -> value

-- | Quiescent data only; capture/encoding/exec and GC peaks remain separate.
-- Native.getEnvironmentPrim copies each complete raw entry into exact-length
-- PlainPtr storage. splitEntry yields two views of that one allocation;
-- overlays instead own two exact-length allocations. The joint pair term
-- charges two compact byte graphs. Its spare headers cover the raw entry's
-- one separator and alignment when the allocation is shared. This is a bound
-- for that closed pair-origin invariant, not for arbitrary ByteString views.
processEnvironmentNormalFormBytes :: ProcessEnvironment -> Natural
processEnvironmentNormalFormBytes (ProcessEnvironment entries (ProcessEnvironmentUsage count encoded)) =
  boxedRecordBytes
    [ boxedListBytes pairBytes entries
    , boxedRecordBytes [boxedNaturalBytes count, boxedNaturalBytes encoded]
    ]
 where
  pairBytes (key, value) = boxedRecordBytes [bytesTerm key, bytesTerm value]
  bytesTerm bytes = 64 + aligned (fromIntegral (Bytes.length bytes))
  aligned bytes = 8 * ((bytes + 7) `div` 8)
