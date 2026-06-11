-- | Sprint 3.16 follow-up: the typed gateway-derive capability the host CLI
-- threads from its entrypoint, replacing the ambient
-- @PRODBOX_TEST_GATEWAY_DERIVE_SEED_HEX@ reads that previously branched
-- production code paths deep in the call graph.
--
-- 'resolveGatewayDeriveMode' performs the seam's single environment read
-- ('Prodbox.TestSeam.GatewayDerive.lookupGatewayDeriveTestSeed') once, at
-- 'Prodbox.App.main', and decodes the hex seed to a typed 'MasterSeed'. The
-- resolved value is carried explicitly to the host-side derived-secret
-- consumers — 'Prodbox.CLI.Rke2.ensureGatewayChartReady' /
-- @readKeycloakVscodeClientSecret@ and
-- 'Prodbox.Secret.HostBootstrap.preApplyDerivedSecretsForRelease' — so none of
-- them re-read the environment.
--
-- 'ProductionGateway' is the production path (env var unset): the host dials
-- the in-cluster gateway daemon. 'TestSeed' is the integration-harness path
-- (the harness sets the env var in the spawned @prodbox@ subprocess, so the
-- read necessarily happens at the subprocess's own startup): the host computes
-- the daemon's deterministic response from the seed locally. Production never
-- sets the env var.
module Prodbox.Secret.GatewayDeriveMode
  ( GatewayDeriveMode (..)
  , resolveGatewayDeriveMode
  )
where

import Data.ByteString qualified as BS
import Data.Char (isHexDigit)
import Prodbox.Secret.Derive (MasterSeed, masterSeed)
import Prodbox.TestSeam.GatewayDerive (lookupGatewayDeriveTestSeed)

-- | The host-side gateway-derive capability, resolved once at the entrypoint.
data GatewayDeriveMode
  = -- | Production: dial the in-cluster gateway daemon for derived values.
    ProductionGateway
  | -- | Integration harness: compute the daemon's response from this seed.
    TestSeed MasterSeed

-- | Read the gateway-derive test seam once and decode it to a typed
-- 'GatewayDeriveMode'. 'Right ProductionGateway' when the env var is unset
-- (production); 'Right (TestSeed seed)' when it holds a valid 32-byte hex
-- seed; 'Left' when it is set but malformed (so the entrypoint fails fast
-- rather than silently falling back to the production dial).
resolveGatewayDeriveMode :: IO (Either String GatewayDeriveMode)
resolveGatewayDeriveMode = do
  maybeHex <- lookupGatewayDeriveTestSeed
  pure $ case maybeHex of
    Nothing -> Right ProductionGateway
    Just hex ->
      case decodeHex hex of
        Left err -> Left ("gateway-derive test seam: " ++ err)
        Right bytes ->
          case masterSeed bytes of
            Left err -> Left ("gateway-derive test seam: " ++ err)
            Right seed -> Right (TestSeed seed)

decodeHex :: String -> Either String BS.ByteString
decodeHex input
  | odd (length input) = Left "odd-length hex string"
  | not (all isHexDigit input) = Left "non-hex characters in input"
  | otherwise = Right (BS.pack (parsePairs input))
 where
  parsePairs [] = []
  parsePairs (a : b : rest) = fromIntegral (hexValue a * 16 + hexValue b) : parsePairs rest
  parsePairs _ = []
  hexValue c
    | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
    | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
    | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
    | otherwise = 0
