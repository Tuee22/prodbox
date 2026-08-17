-- | Bounded recovery-plane Authority protocol.  The request carries only the
-- durable run/current-operation/current-attempt identity; it cannot carry or
-- mint component observations.  Handler construction and descriptor reload
-- remain package-private.
module Prodbox.ControlPlane.RecoveryPlaneEndpoint
  ( RecoveryPlaneWirePhase (..)
  , RecoveryPlaneWireRequest (..)
  , recoveryPlaneInitialReadBackWireRequest
  , recoveryPlaneFinalDispositionWireRequest
  , RecoveryPlaneWireOutcome (..)
  , RecoveryPlaneWireRefusal (..)
  , RecoveryPlaneWireUnavailable (..)
  , RecoveryPlaneWireResponse (..)
  , RecoveryPlaneEndpointHandler
  , RecoveryPlaneEndpointResult
  , recoveryPlaneEndpointFormatVersion
  , recoveryPlaneEndpointMaximumBytes
  , recoveryPlaneEndpointResponseMaximumBytes
  , serveRecoveryPlaneEndpointRequest
  , recoveryPlaneEndpointStatus
  , recoveryPlaneWireResponseStatus
  , recoveryPlaneEndpointBody
  , decodeRecoveryPlaneEndpointResponse
  , RecoveryPlaneEndpointResponseError (..)
  , confirmRecoveryPlaneResponse
  , RecoveryPlaneEndpointRegression
  , fixedRecoveryPlaneEndpointRegression
  , recoveryPlaneEndpointValidExact
  , recoveryPlaneEndpointMalformedNoExecution
  , recoveryPlaneEndpointOversizeNoExecution
  , recoveryPlaneEndpointInvalidIdentityNoExecution
  , recoveryPlaneEndpointUnsupportedVersionNoExecution
  , recoveryPlaneEndpointAllArmsValidateVersion
  , recoveryPlaneEndpointAllArmsValidateRequestDigest
  )
where

import Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal
