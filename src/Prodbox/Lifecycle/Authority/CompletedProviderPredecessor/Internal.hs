-- | Transient server evidence. Neither wire decoding nor record updates can
-- construct a successful predecessor observation.
module Prodbox.Lifecycle.Authority.CompletedProviderPredecessor.Internal
  ( ProviderPredecessorCoordinates (..)
  , ObservedCompletedProviderPredecessor (..)
  , completedProviderPredecessorCoordinates
  , completedProviderPredecessorReportDigest
  ) where

import Prodbox.Lifecycle.CleanupRun (CleanupDigest, CleanupRunId)

data ProviderPredecessorCoordinates = ProviderPredecessorCoordinates
  { providerPredecessorRunId :: !CleanupRunId
  , providerPredecessorDescriptorDigest :: !CleanupDigest
  , providerPredecessorGraphDigest :: !CleanupDigest
  , providerPredecessorScopeDigest :: !CleanupDigest
  }
  deriving (Eq, Show)

data ObservedCompletedProviderPredecessor
  = ObservedCompletedProviderPredecessor !ProviderPredecessorCoordinates !CleanupDigest

completedProviderPredecessorCoordinates
  :: ObservedCompletedProviderPredecessor -> ProviderPredecessorCoordinates
completedProviderPredecessorCoordinates (ObservedCompletedProviderPredecessor coordinates _) = coordinates

completedProviderPredecessorReportDigest
  :: ObservedCompletedProviderPredecessor -> CleanupDigest
completedProviderPredecessorReportDigest (ObservedCompletedProviderPredecessor _ digest) = digest
