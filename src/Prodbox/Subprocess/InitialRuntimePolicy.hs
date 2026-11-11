{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | Deny-only observation of the actual RTS policy under an original work end.
-- A successful comparison reserves no free heap or physical/Authority capacity.
module Prodbox.Subprocess.InitialRuntimePolicy
  ( InitialRuntimePolicyError (..)
  , verifyInitialRuntimePolicyBefore
  , verifyInitialTraversalRuntimePolicyBefore
  ) where

import Data.Word (Word64)
import Foreign.C.Types (CSize (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import GHC.RTS.Flags qualified as Rts
import Numeric.Natural (Natural)

foreign import capi "Rts.h value BLOCK_SIZE" runtimeBlockBytes :: CSize

data InitialRuntimePolicyError
  = InitialRuntimePolicyExpired
  | InitialRuntimePolicyRefused
  deriving (Eq, Show)

verifyInitialRuntimePolicyBefore
  :: Word64 -> Natural -> IO (Either InitialRuntimePolicyError ())
verifyInitialRuntimePolicyBefore ending required = do
  now <- getMonotonicTimeNSec
  if now >= ending
    then pure (Left InitialRuntimePolicyExpired)
    else do
      capabilities <- getNumCapabilities
      flags <- Rts.getRTSFlags
      let actualHeap = toInteger (Rts.maxHeapSize (Rts.gcFlags flags)) * toInteger runtimeBlockBytes
      if capabilities /= 1 || actualHeap <= 0 || actualHeap < toInteger required
        then pure (Left InitialRuntimePolicyRefused)
        else do
          closing <- getMonotonicTimeNSec
          pure (if closing >= ending then Left InitialRuntimePolicyExpired else Right ())

-- The configured minimum allocation area is independent of the authored data
-- floor. Refuse when their sum exceeds the actual heap before an allocating
-- traversal. This conservative check reserves no free heap and establishes no
-- complete construction, collection, stack, native or admission bound.
verifyInitialTraversalRuntimePolicyBefore
  :: Word64 -> Natural -> IO (Either InitialRuntimePolicyError ())
verifyInitialTraversalRuntimePolicyBefore ending required = do
  now <- getMonotonicTimeNSec
  if now >= ending
    then pure (Left InitialRuntimePolicyExpired)
    else do
      flags <- Rts.getRTSFlags
      let nursery = fromIntegral (Rts.minAllocAreaSize (Rts.gcFlags flags)) * fromIntegral runtimeBlockBytes
      if nursery == 0
        then pure (Left InitialRuntimePolicyRefused)
        else do
          observed <- verifyInitialRuntimePolicyBefore ending (required + nursery)
          case observed of
            Left cause -> pure (Left cause)
            Right () -> do
              closing <- getMonotonicTimeNSec
              pure (if closing >= ending then Left InitialRuntimePolicyExpired else Right ())
