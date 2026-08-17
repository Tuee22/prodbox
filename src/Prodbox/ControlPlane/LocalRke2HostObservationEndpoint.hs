-- | Public read-only facade for the commit-only host-observation endpoint.
-- Handler construction, wire constructors, candidate bytes, repository
-- clients, and the host transport remain package-private.
module Prodbox.ControlPlane.LocalRke2HostObservationEndpoint
  ( LocalRke2HostObservationEndpointHandler
  , LocalRke2HostObservationEndpointResult
  , localRke2HostObservationEndpointMaximumBytes
  , localRke2HostObservationEndpointResponseMaximumBytes
  , serveLocalRke2HostObservationEndpointRequest
  , localRke2HostObservationEndpointStatus
  , localRke2HostObservationEndpointBody
  , LocalRke2HostObservationEndpointRegression
  , fixedLocalRke2HostObservationEndpointRegression
  , localRke2HostObservationEndpointValidExact
  , localRke2HostObservationEndpointMalformedNoExecution
  , localRke2HostObservationEndpointOversizeNoExecution
  , localRke2HostObservationEndpointInvalidIdentityNoExecution
  , localRke2HostObservationEndpointUnsupportedVersionNoExecution
  , localRke2HostObservationEndpointCandidateBoundNoExecution
  , localRke2HostObservationEndpointAllArmsValidateVersion
  , localRke2HostObservationEndpointAllArmsValidateRequestDigest
  )
where

import Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal
