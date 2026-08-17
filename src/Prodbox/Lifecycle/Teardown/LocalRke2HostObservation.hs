-- | Read-only host-observation facade.  Candidate construction, the opaque
-- local RKE2 state eliminator, canonical bytes, and proof restoration remain
-- package-private.
module Prodbox.Lifecycle.Teardown.LocalRke2HostObservation
  ( LocalRke2HostObservationIdentity
  , localRke2HostObservationRunId
  , localRke2HostObservationDescriptorDigest
  , localRke2HostObservationGraphDigest
  , localRke2HostObservationScope
  , localRke2HostObservationFoundation
  , localRke2HostObservationEstablishOperationId
  , localRke2HostObservationEstablishAttemptId
  , localRke2HostObservationIdentityDigest
  , LocalRke2HostObservationError (..)
  , maximumLocalRke2HostObservationBytes
  )
where

import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal
