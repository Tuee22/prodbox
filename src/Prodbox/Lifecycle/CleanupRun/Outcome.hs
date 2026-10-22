{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Pure, non-authorizing cleanup outcomes shared by wire and retained state.
-- Constructor order is the existing cleanup journal encoding.
module Prodbox.Lifecycle.CleanupRun.Outcome
  ( CleanupPrimaryOutcome (..)
  , CleanupNodeOutcome (..)
  ) where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)

data CleanupPrimaryOutcome
  = CleanupPrimarySucceeded
  | CleanupPrimaryFailed !Text
  | CleanupPrimaryCancelled
  | CleanupPrimaryRunnerLost
  | CleanupPrimaryExitFailure !Int
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupNodeOutcome
  = CleanupNodeSucceeded
  | CleanupNodeFailed !Text
  | CleanupNodeEffectUnconfirmed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)
