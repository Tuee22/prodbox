-- | Public consumer facade for short-lived EKS client-auth projections.
--
-- A host caller may prepare an ephemeral destination, decode and open the
-- Provider-owned encrypted envelope, and inspect the resulting projection.
-- Raw bearer construction and envelope sealing are deliberately absent.
module Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthDestination
  , EksClientAuthPublicKey
  , EksClientAuthEnvelope
  , EksClientAuthProjection
  , EksClientAuthProjectionError (..)
  , prepareEksClientAuthDestination
  , eksClientAuthPublicKeyBytes
  , validateEksClusterArnBinding
  , eksClientAuthAccountId
  , eksClientAuthRegion
  , eksClientAuthClusterName
  , eksClientAuthClusterArn
  , eksClientAuthEndpoint
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthBearerToken
  , eksClientAuthExpiresAtEpochSeconds
  , openEksClientAuthProjection
  , encodeEksClientAuthEnvelope
  , decodeEksClientAuthEnvelope
  )
where

import Prodbox.ControlPlane.EksClientAuthProjection.Internal
  ( EksClientAuthDestination
  , EksClientAuthEnvelope
  , EksClientAuthProjection
  , EksClientAuthProjectionError (..)
  , EksClientAuthPublicKey
  , decodeEksClientAuthEnvelope
  , eksClientAuthAccountId
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterArn
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  , eksClientAuthExpiresAtEpochSeconds
  , eksClientAuthPublicKeyBytes
  , eksClientAuthRegion
  , encodeEksClientAuthEnvelope
  , openEksClientAuthProjection
  , prepareEksClientAuthDestination
  , validateEksClusterArnBinding
  )
