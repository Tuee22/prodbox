-- | The local readiness owed after credential preparation. The lifecycle
-- exercise needs its retained control plane; it does not need application or
-- public-edge reconciliation. Both profiles keep the ordinary bootstrap floor.
module Prodbox.Lifecycle.RuntimeProfile
  ( NativeRuntimeProfile (..)
  ) where

data NativeRuntimeProfile
  = FullRuntime
  | LifecycleWorkersRuntime
  deriving (Eq, Show, Enum, Bounded)
