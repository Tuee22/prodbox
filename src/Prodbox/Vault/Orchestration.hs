{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.36: pure orchestration helpers for the @prodbox vault@ lifecycle
-- (init / unseal / seal). The effectful HTTP + file IO lives in
-- "Prodbox.CLI.Vault"; this module holds the total, unit-testable decision
-- logic — the unseal plan over a 'SealStatus' plus key shares, the
-- per-submission progress classification, and the canonical on-disk
-- unlock-bundle path.
module Prodbox.Vault.Orchestration
  ( UnsealStep (..)
  , UnsealOutcome (..)
  , planUnseal
  , interpretUnsealProgress
  , vaultUnlockBundleRelPath
  , vaultUnlockBundlePath
  )
where

import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.Vault.Client (SealStatus (..))
import System.FilePath ((</>))

-- | One unseal key share to submit, 1-indexed by submission order.
data UnsealStep = UnsealStep
  { unsealStepIndex :: Int
  , unsealStepKey :: Text
  }
  deriving (Eq, Show)

-- | The classification of a post-submission 'SealStatus' relative to the step
-- just submitted. 'UnsealStalled' (progress did not advance) aborts the loop so
-- a bundle that does not match this Vault fails loud instead of looping.
data UnsealOutcome
  = UnsealAdvanced Natural
  | UnsealCompleted
  | UnsealStalled
  deriving (Eq, Show)

-- | The repo-relative path of the encrypted host-side unlock bundle. The
-- on-disk artifact is always the ciphertext envelope; the plaintext bundle
-- lives only in memory after a successful decrypt.
vaultUnlockBundleRelPath :: FilePath
vaultUnlockBundleRelPath = ".data/prodbox/vault-unlock-bundle.age"

-- | The unlock bundle path under a repository root.
vaultUnlockBundlePath :: FilePath -> FilePath
vaultUnlockBundlePath repoRoot = repoRoot </> vaultUnlockBundleRelPath

-- | Plan the unseal key submissions needed to bring a sealed Vault to
-- unsealed. An already-unsealed Vault needs no submissions ('Right' @[]@); a
-- bundle with too few keys for the remaining threshold fails loud.
planUnseal :: SealStatus -> [Text] -> Either String [UnsealStep]
planUnseal status keys
  | not (sealStatusSealed status) = Right []
  | null keys = Left "unlock bundle has no unseal keys"
  | needed > length keys =
      Left
        ( "insufficient unseal keys: need "
            ++ show needed
            ++ " have "
            ++ show (length keys)
        )
  | otherwise =
      Right [UnsealStep index key | (index, key) <- zip [1 ..] (take needed keys)]
 where
  threshold = fromIntegral (sealStatusThreshold status) :: Int
  progress = fromIntegral (sealStatusProgress status) :: Int
  needed = max 0 (threshold - progress)

-- | Classify the seal status observed after submitting an unseal step: an
-- unsealed Vault is 'UnsealCompleted'; a progress count that reached the step's
-- 1-based index advanced; an unchanged progress count stalled (a bad share).
interpretUnsealProgress :: SealStatus -> UnsealStep -> UnsealOutcome
interpretUnsealProgress status step
  | not (sealStatusSealed status) = UnsealCompleted
  | (fromIntegral (sealStatusProgress status) :: Int) >= unsealStepIndex step =
      UnsealAdvanced (sealStatusProgress status)
  | otherwise = UnsealStalled
