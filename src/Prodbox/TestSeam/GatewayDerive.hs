-- | Sprint 3.16: the integration-harness test seam at the gateway-client
-- boundary.
--
-- Sprint 3.13's host paths read the raw master seed from MinIO (or a
-- @PRODBOX_TEST_HOST_MASTER_SEED_HEX@ host-side override) and derived
-- chart-secret values themselves. Sprint 3.16 moved that derivation
-- behind the in-cluster gateway daemon's @/v1/secret/*@ RPC: the host now
-- requests *derived* values, never the raw seed
-- (@secret_derivation_doctrine.md §2/§5@).
--
-- The fake-environment integration suites have no running gateway daemon
-- to answer those RPCs, so this seam lets them stand in. When
-- @PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX@ is set to a 64-character hex
-- string, the host-side gateway-client callers
-- ('Prodbox.Secret.HostBootstrap.preApplyDerivedSecretsForRelease' and
-- 'Prodbox.CLI.Rke2.readKeycloakVscodeClientSecret') compute the
-- *derived* response the daemon would have returned from this test seed,
-- locally, instead of dialing the loopback NodePort. The seed is purely a
-- deterministic fixture for computing the gateway's response shape: it is
-- never a host read of the real MinIO master seed, never lands on a host
-- path, and is never re-exported as a Secret value the way the retired
-- @PRODBOX_TEST_HOST_MASTER_SEED_HEX@ seam was. Production never sets it.
--
-- Centralising the @lookupEnv@ here keeps the seam a single, named,
-- auditable surface — distinct from any supported configuration read.
module Prodbox.TestSeam.GatewayDerive
  ( gatewayDeriveTestSeedEnvVar
  , lookupGatewayDeriveTestSeed
  )
where

import System.Environment (lookupEnv)

-- | The single environment variable name the gateway-derive test seam
-- reads. Exposed so the integration harness and unit tests can reference
-- it without re-typing the literal.
gatewayDeriveTestSeedEnvVar :: String
gatewayDeriveTestSeedEnvVar = "PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX"

-- | Look up the gateway-derive test-seam seed (a 64-character hex string,
-- or absent). 'Nothing' is the production path: the caller dials the real
-- gateway. 'Just' is the integration-harness path: the caller derives the
-- gateway's deterministic response from this seed locally.
lookupGatewayDeriveTestSeed :: IO (Maybe String)
lookupGatewayDeriveTestSeed = lookupEnv gatewayDeriveTestSeedEnvVar
