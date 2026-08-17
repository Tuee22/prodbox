-- | Package-private representation of an independently read-back cleanup run
-- joined to its committed program descriptor.  Construction is retained for
-- Authority endpoint implementations; the public client facade exports only
-- the abstract handle and read-only views.
module Prodbox.ControlPlane.CleanupRunClient.Internal
  ( DescriptorBoundCleanupRun (..)
  )
where

import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CommittedCleanupProgramDescriptor
  )
import Prodbox.Lifecycle.CleanupRun (CleanupRun)

data DescriptorBoundCleanupRun = DescriptorBoundCleanupRun
  { internalDescriptorBoundCleanupRunDescriptor
      :: !CommittedCleanupProgramDescriptor
  , internalDescriptorBoundCleanupRunValue :: !CleanupRun
  }
