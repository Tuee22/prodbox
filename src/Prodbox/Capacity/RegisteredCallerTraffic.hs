-- | Per-attempt arithmetic for one cached registered signer. Ordinary frames
-- already include any ordinary peer refresh. Each private registry observation
-- issues one public hint and the two fixed signed peer/registry reads.
-- Native Vault/session and serialized readiness costs are separate terms of
-- the checked caller cost. None of these values grants operation admission or
-- selects an installed production program/replay profile.
module Prodbox.Capacity.RegisteredCallerTraffic
  ( RegisteredCallerTraffic (..)
  , registeredCallerTraffic
  , repeatCallerAttempts
  , NativeVaultTraffic (..)
  , registeredCallerNativeTraffic
  , RegisteredCallerCost
  , RegisteredCallerCostError (..)
  , registeredCallerCost
  , callerCostTraffic
  , callerCostNativeTraffic
  , callerCostStartupProbes
  , callerCostTokenLogins
  , callerCostTokenCommands
  , callerCostConfigCaptures
  , callerCostVaultHttp
  , callerCostNativeHttp
  ) where

import Data.Word (Word64)
import Numeric.Natural (Natural)

data RegisteredCallerTraffic = RegisteredCallerTraffic
  { ordinaryFrames :: !Natural
  , registryObservations :: !Natural
  , publicHints :: !Natural
  , metadataSignedFrames :: !Natural
  , totalSignedFrames :: !Natural
  , protocolHttpRequests :: !Natural
  , homeScopeEntries :: !Natural
  , perExchangeForwards :: !Natural
  }
  deriving (Eq, Show)

registeredCallerTraffic :: Natural -> Natural -> RegisteredCallerTraffic
registeredCallerTraffic frames ordinaryRoleScopes =
  RegisteredCallerTraffic
    frames
    registryReadCount
    registryReadCount
    metadata
    (frames + metadata)
    raw
    scopes
    -- Each fixed private hint/peer/registry program shares one forward.
    (frames + registryReadCount + scopes)
 where
  -- Discovery plus checked-signer construction, then both sides of every
  -- signature. The private signer itself cannot recursively read a registry.
  registryReadCount = 2 + 2 * frames
  metadata = 2 * registryReadCount
  raw = frames + 3 * registryReadCount
  -- The private bootstrap channel is constructed once for the cached signer.
  scopes = 1 + ordinaryRoleScopes

-- Applying the per-attempt setup only once to an aggregate request count
-- would undercount every later attempt's discovery/construction prefix.
repeatCallerAttempts :: Natural -> RegisteredCallerTraffic -> RegisteredCallerTraffic
repeatCallerAttempts attempts traffic =
  RegisteredCallerTraffic
    (attempts * ordinaryFrames traffic)
    (attempts * registryObservations traffic)
    (attempts * publicHints traffic)
    (attempts * metadataSignedFrames traffic)
    (attempts * totalSignedFrames traffic)
    (attempts * protocolHttpRequests traffic)
    (attempts * homeScopeEntries traffic)
    (attempts * perExchangeForwards traffic)

-- | Calls to token-consuming Vault HTTP primitives before the session's one
-- explicit 403 retry. The private bootstrap signer does not recurse into the
-- registered registry reader. Ordinary peer refreshes are already in frames.
data NativeVaultTraffic = NativeVaultTraffic
  { nativeOriginReads :: !Natural
  , nativePublicKeyReads :: !Natural
  , nativeSignatures :: !Natural
  , nativeEpochReads :: !Natural
  , nativeManifestReads :: !Natural
  , nativePrimitiveCalls :: !Natural
  }
  deriving (Eq, Show)

registeredCallerNativeTraffic :: Natural -> NativeVaultTraffic
registeredCallerNativeTraffic frames =
  NativeVaultTraffic origins public signatures frames 1 (origins + public + signatures + frames + 1)
 where
  registryReads = 2 + 2 * frames
  origins = 7 * registryReads + 2 + 2 * frames
  public = 6 * registryReads + 1 + 2 * frames
  signatures = 2 * registryReads + frames

data RegisteredCallerCost = RegisteredCallerCost
  { storedCostTraffic :: !RegisteredCallerTraffic
  , storedCostNative :: !NativeVaultTraffic
  , storedCostProbes :: !Natural
  , storedCostLogins :: !Natural
  , storedCostTokenCommands :: !Natural
  , storedCostVaultHttp :: !Natural
  , storedCostNativeHttp :: !Natural
  }
  deriving (Eq, Show)

data RegisteredCallerCostError
  = CallerCostOriginalWindowEmpty
  | CallerCostLoginAllowanceEmpty
  | CallerCostCountOverflow
  deriving (Eq, Show)

-- | Bound one captured caller, not every actor in a qualification run. Roles
-- counts channel constructions, including repeated scopes. The one private
-- scope is added here. Login attempts each own three managed token stages and
-- one HTTP login. Every token-consuming primitive can retry once after 403;
-- the shared HTTP manager contributes no hidden replay or bounded redirects.
-- One lazy manifest observation must be claimed before I/O, including on
-- cancellation. Complete program/body/memory/replay funding remains separate.
-- Native HTTP totals exclude subprocess-internal Kubernetes/forward traffic,
-- which retains its independently bounded command/transport program.
registeredCallerCost
  :: Natural
  -> Natural
  -> Natural
  -> Word64
  -> Either RegisteredCallerCostError RegisteredCallerCost
registeredCallerCost frames roles logins originalRemainingNs
  | originalRemainingNs == 0 = Left CallerCostOriginalWindowEmpty
  | logins == 0 = Left CallerCostLoginAllowanceEmpty
  | any (> fromIntegral (maxBound :: Word64)) counts = Left CallerCostCountOverflow
  | otherwise =
      Right (RegisteredCallerCost traffic native probes logins tokenCommands vaultHttp totalHttp)
 where
  traffic = registeredCallerTraffic frames roles
  native = registeredCallerNativeTraffic frames
  -- Exchanges serialize unsuccessful readiness probes and their 250-ms
  -- delays. A clipped final delay cannot authorize a request after expiry.
  retries = (fromIntegral originalRemainingNs + 249999999) `div` 250000000
  probes = perExchangeForwards traffic + retries
  tokenCommands = 3 * logins
  vaultHttp = 2 * nativePrimitiveCalls native + logins
  totalHttp = protocolHttpRequests traffic + probes + vaultHttp
  counts = [totalHttp, tokenCommands]

callerCostTraffic :: RegisteredCallerCost -> RegisteredCallerTraffic
callerCostTraffic = storedCostTraffic

callerCostNativeTraffic :: RegisteredCallerCost -> NativeVaultTraffic
callerCostNativeTraffic = storedCostNative

callerCostStartupProbes :: RegisteredCallerCost -> Natural
callerCostStartupProbes = storedCostProbes

callerCostTokenLogins :: RegisteredCallerCost -> Natural
callerCostTokenLogins = storedCostLogins

callerCostTokenCommands :: RegisteredCallerCost -> Natural
callerCostTokenCommands = storedCostTokenCommands

callerCostConfigCaptures :: RegisteredCallerCost -> Natural
callerCostConfigCaptures _ = 1

callerCostVaultHttp :: RegisteredCallerCost -> Natural
callerCostVaultHttp = storedCostVaultHttp

callerCostNativeHttp :: RegisteredCallerCost -> Natural
callerCostNativeHttp = storedCostNativeHttp
