-- | Non-authorizing diagnostics for the closed descriptor-bound lifecycle
-- dispatcher. The production constructor, descriptor handle, authenticated
-- transport, cloud runtime, and executable action remain package-private.
module Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime
  ( DescriptorBoundLifecycleRuntimeRegression
  , fixedDescriptorBoundLifecycleRuntimeRegression
  , descriptorBoundLifecycleRuntimeCloudOperationsExact
  , descriptorBoundLifecycleRuntimeRecoveryOperationsExact
  , descriptorBoundLifecycleRuntimeCascadeHostOperationsExact
  , descriptorBoundLifecycleRuntimeUnsupportedOperationsExact
  , descriptorBoundLifecycleRuntimeUnsupportedIsRefusal
  , descriptorBoundLifecycleRuntimeNoCallerContinuation
  , descriptorBoundLifecycleRuntimeDescriptorBoundOnly
  , descriptorBoundLifecycleRuntimeOpacityClosed
  )
where

import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
