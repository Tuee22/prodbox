-- | Public facade for the cascade's retained-slot endpoint.  The wire
-- constructors, the handler construction, the slot bytes, and the closed
-- namespace's admission function stay package-private, so holding anything
-- exported here authorizes nothing.
module Prodbox.ControlPlane.CascadeRetainedSlotEndpoint
  ( CascadeRetainedSlotEndpointHandler
  , CascadeRetainedSlotEndpointResult
  , cascadeRetainedSlotEndpointMaximumBytes
  , cascadeRetainedSlotEndpointResponseMaximumBytes
  , maximumCascadeRetainedSlotValueBytes
  , cascadeRetainedSlotModelBCodec
  , serveCascadeRetainedSlotEndpointRequest
  , cascadeRetainedSlotEndpointStatus
  , cascadeRetainedSlotEndpointBody
  , CascadeRetainedSlotEndpointRegression
  , fixedCascadeRetainedSlotEndpointRegression
  , cascadeRetainedSlotEndpointAdmitsExactlyTheCascadeNamespaces
  , cascadeRetainedSlotEndpointForeignNameNoExecution
  , cascadeRetainedSlotEndpointMalformedSuffixNoExecution
  , cascadeRetainedSlotEndpointMalformedNoExecution
  , cascadeRetainedSlotEndpointOversizeNoExecution
  , cascadeRetainedSlotEndpointUnsupportedVersionNoExecution
  , cascadeRetainedSlotEndpointOversizeValueNoExecution
  , cascadeRetainedSlotEndpointConflictCarriesObservedBytes
  , cascadeRetainedSlotEndpointAllArmsValidateRequestDigest
  )
where

import Prodbox.ControlPlane.CascadeRetainedSlotEndpoint.Internal
