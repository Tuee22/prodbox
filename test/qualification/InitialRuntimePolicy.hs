{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- Native controls for the package-private policy observer. Each invocation
-- supplies its actual RTS policy; no process-parent or Authority is admitted.
module Main (main) where

import Control.Monad (unless)
import Foreign.C.Types (CSize (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.RTS.Flags qualified as Rts
import Numeric.Natural (Natural)
import Prodbox.Subprocess.InitialRuntimePolicy qualified as Policy
import System.Environment (getArgs)

foreign import capi "Rts.h value BLOCK_SIZE" runtimeBlockBytes :: CSize

expect
  :: Either Policy.InitialRuntimePolicyError ()
  -> Either Policy.InitialRuntimePolicyError ()
  -> IO ()
expect expected observed = unless (observed == expected) (fail ("unexpected runtime policy: " <> show observed))

main :: IO ()
main = do
  [mode] <- getArgs
  ending <- (+ 10000000000) <$> getMonotonicTimeNSec
  flags <- Rts.getRTSFlags
  let gc = Rts.gcFlags flags
      cap = fromIntegral (Rts.maxHeapSize gc) * fromIntegral runtimeBlockBytes :: Natural
      nursery = fromIntegral (Rts.minAllocAreaSize gc) * fromIntegral runtimeBlockBytes :: Natural
      knownData = 1048576
      refused = Left Policy.InitialRuntimePolicyRefused
      expired = Left Policy.InitialRuntimePolicyExpired
      accepted = Right ()
      both expected required = do
        expect expected =<< Policy.verifyInitialRuntimePolicyBefore ending required
        expect expected =<< Policy.verifyInitialTraversalRuntimePolicyBefore ending required
      boundary = do
        unless
          (cap > nursery && nursery > 0)
          (fail "boundary needs a positive observed nursery below the cap")
        expect accepted =<< Policy.verifyInitialTraversalRuntimePolicyBefore ending (cap - nursery)
        expect refused =<< Policy.verifyInitialTraversalRuntimePolicyBefore ending (cap - nursery + 1)
  case mode of
    "refuse" -> do
      expect accepted =<< Policy.verifyInitialRuntimePolicyBefore ending knownData
      expect refused =<< Policy.verifyInitialTraversalRuntimePolicyBefore ending knownData
      unless (cap < knownData + nursery) (fail "fixture did not observe its incompatible policy")
    "finite" -> both accepted knownData >> boundary
    "small-nursery" -> do
      unless (nursery == 262144) (fail "fixture did not observe its explicitly selected nursery")
      both accepted knownData
      boundary
    "unlimited" -> do
      unless (cap == 0) (fail "fixture did not observe unlimited heap")
      both refused knownData
    "two-capabilities" -> both refused knownData
    "huge" -> both refused (2 ^ (500000 :: Int))
    "expired" -> do
      expect expired =<< Policy.verifyInitialRuntimePolicyBefore 0 0
      expect expired =<< Policy.verifyInitialTraversalRuntimePolicyBefore 0 0
    _ -> fail "unknown native runtime-policy mode"
  expect expired =<< Policy.verifyInitialTraversalRuntimePolicyBefore 0 knownData
  putStrLn
    ( "actual_heap_bytes="
        <> show cap
        <> "; nursery_bytes="
        <> show nursery
        <> "; policy_mode="
        <> mode
        <> "; passed"
    )
