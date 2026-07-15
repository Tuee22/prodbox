-- | Sprint 1.64: a cached, renewable Vault Kubernetes-auth session.
--
-- Counterexample @LCPC-2026-07-11@ traced a gateway hot-path CPU driver to a
-- fresh Vault Kubernetes login on every request (see the
-- @per-request-vault-login@ entry in "Prodbox.Legacy.EscapeRegistry"). This
-- module holds the token with a monotonic-clock expiry, renews it at two-thirds
-- of the lease, coalesces concurrent refreshes into a single flight, classifies
-- sealed/revoked/unavailable outcomes as structured errors, and — through
-- 'withSessionToken' — reacts to a downstream @403@ with exactly one
-- invalidate-and-relogin.
--
-- The refresh decision ('cachedTokenFresh') and error classification
-- ('httpErrorToSessionError', 'isForbiddenHttpError') are pure and unit-tested
-- against a fake clock and a fake login boundary; the effectful wrapper owns
-- only the 'IORef' cache and the single-flight 'MVar'. The one process-global
-- 'resolveSharedSession' registry keeps a persistent session per Vault
-- role/address so callers get the cache without threading a handle through every
-- request. Neither this module nor the token it holds is ever 'Show'n, so a
-- token cannot leak through a derived instance.
module Prodbox.Vault.Session
  ( VaultSession
  , VaultSessionError (..)
  , renderVaultSessionError
  , CachedToken (..)
  , LoginLease (..)
  , SessionClock (..)
  , SessionLogin
  , realSessionClock
  , newVaultSession
  , sessionAddress
  , sessionToken
  , sessionForceRelogin
  , withSessionToken
  , cachedTokenFresh
  , renewalDueSeconds
  , isForbiddenHttpError
  , httpErrorToSessionError
  , sessionErrorToHttp
  , GatewaySessionKey (..)
  , resolveSharedSession
  )
where

import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , newMVar
  , withMVar
  )
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import GHC.Clock (getMonotonicTime)
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Vault.Client (VaultAddress, VaultToken)
import System.IO.Unsafe (unsafePerformIO)

-- | A structured session-acquisition failure. @Sealed@ maps to a @503@-class
-- Vault outcome, @Forbidden@ to a @403@ (denied/revoked), and @Unavailable@ to
-- every transport/timeout/decode failure. The message never contains the token.
data VaultSessionError
  = VaultSessionSealed String
  | VaultSessionForbidden String
  | VaultSessionUnavailable String
  deriving (Eq, Show)

renderVaultSessionError :: VaultSessionError -> String
renderVaultSessionError err = case err of
  VaultSessionSealed detail -> detail
  VaultSessionForbidden detail -> detail
  VaultSessionUnavailable detail -> detail

-- | The lease evidence a successful login yields.
data LoginLease = LoginLease
  { loginLeaseToken :: VaultToken
  , loginLeaseSeconds :: Int
  , loginLeaseRenewable :: Bool
  }

-- | A cached token together with the monotonic instant it was obtained and its
-- lease. Deliberately has no 'Show' instance — it carries a secret.
data CachedToken = CachedToken
  { cachedToken :: VaultToken
  , cachedObtainedAt :: Double
  , cachedLeaseSeconds :: Int
  , cachedRenewable :: Bool
  }

-- | Injected monotonic clock (seconds). Real production clock is
-- 'realSessionClock'; tests inject a deterministic one.
newtype SessionClock = SessionClock {runSessionClock :: IO Double}

realSessionClock :: SessionClock
realSessionClock = SessionClock getMonotonicTime

-- | The login effect the session invokes to (re)authenticate. In production it
-- reads the current service-account JWT and calls
-- 'Prodbox.Vault.Client.vaultKubernetesLoginWithLease'; tests inject a fake.
type SessionLogin = IO (Either VaultSessionError LoginLease)

data VaultSession = VaultSession
  { vsCache :: IORef (Maybe CachedToken)
  , vsRefreshLock :: MVar ()
  , vsClock :: SessionClock
  , vsLogin :: SessionLogin
  , vsAddress :: VaultAddress
  }

newVaultSession :: VaultAddress -> SessionClock -> SessionLogin -> IO VaultSession
newVaultSession address clock login = do
  cache <- newIORef Nothing
  lock <- newMVar ()
  pure
    VaultSession
      { vsCache = cache
      , vsRefreshLock = lock
      , vsClock = clock
      , vsLogin = login
      , vsAddress = address
      }

sessionAddress :: VaultSession -> VaultAddress
sessionAddress = vsAddress

-- | The monotonic instant at which a cached token becomes due for renewal:
-- two-thirds of the way through its lease.
renewalDueSeconds :: CachedToken -> Double
renewalDueSeconds ct =
  cachedObtainedAt ct + (fromIntegral (cachedLeaseSeconds ct) * 2 / 3)

-- | Whether a cached token is still fresh at @now@. A non-positive lease is
-- never fresh, so an unusable or expiry-less login is always re-fetched rather
-- than trusted forever.
cachedTokenFresh :: Double -> CachedToken -> Bool
cachedTokenFresh now ct =
  cachedLeaseSeconds ct > 0 && now < renewalDueSeconds ct

-- | Get a valid token: return the cached one while it is fresh, otherwise
-- refresh through a single flight (concurrent callers coalesce onto one login).
sessionToken :: VaultSession -> IO (Either VaultSessionError VaultToken)
sessionToken session = do
  cached <- readIORef (vsCache session)
  now <- runSessionClock (vsClock session)
  case cached of
    Just ct | cachedTokenFresh now ct -> pure (Right (cachedToken ct))
    _ -> refreshUnderLock session

-- | Single-flight refresh: hold the refresh lock, re-check freshness (another
-- caller may have refreshed while we waited), and log in only if still stale.
refreshUnderLock :: VaultSession -> IO (Either VaultSessionError VaultToken)
refreshUnderLock session =
  withMVar (vsRefreshLock session) $ \() -> do
    cached <- readIORef (vsCache session)
    now <- runSessionClock (vsClock session)
    case cached of
      Just ct | cachedTokenFresh now ct -> pure (Right (cachedToken ct))
      _ -> performLogin session

performLogin :: VaultSession -> IO (Either VaultSessionError VaultToken)
performLogin session = do
  outcome <- vsLogin session
  case outcome of
    Left err -> pure (Left err)
    Right lease -> do
      now <- runSessionClock (vsClock session)
      let ct =
            CachedToken
              { cachedToken = loginLeaseToken lease
              , cachedObtainedAt = now
              , cachedLeaseSeconds = loginLeaseSeconds lease
              , cachedRenewable = loginLeaseRenewable lease
              }
      writeIORef (vsCache session) (Just ct)
      pure (Right (loginLeaseToken lease))

-- | Force one invalidate-and-relogin, skipping it if the cache has already been
-- replaced with a different token since the caller observed @staleToken@ — so a
-- burst of concurrent @403@s on the same token produces exactly one relogin.
reloginAfterForbidden
  :: VaultSession -> VaultToken -> IO (Either VaultSessionError VaultToken)
reloginAfterForbidden session staleToken =
  withMVar (vsRefreshLock session) $ \() -> do
    cached <- readIORef (vsCache session)
    case cached of
      Just ct
        | cachedToken ct /= staleToken -> pure (Right (cachedToken ct))
      _ -> do
        writeIORef (vsCache session) Nothing
        performLogin session

-- | Unconditionally invalidate the cache and relogin (single-flight).
sessionForceRelogin :: VaultSession -> IO (Either VaultSessionError VaultToken)
sessionForceRelogin session =
  withMVar (vsRefreshLock session) $ \() -> do
    writeIORef (vsCache session) Nothing
    performLogin session

-- | Whether an 'HttpError' is a @403@ (the invalidate-and-relogin trigger).
isForbiddenHttpError :: HttpError -> Bool
isForbiddenHttpError err = case err of
  HttpStatus 403 _ -> True
  _ -> False

-- | Classify a login 'HttpError' into a structured session error.
httpErrorToSessionError :: HttpError -> VaultSessionError
httpErrorToSessionError err = case err of
  HttpStatus 403 body ->
    VaultSessionForbidden ("Vault denied Kubernetes login (403): " ++ truncateDetail body)
  HttpStatus 503 body ->
    VaultSessionSealed ("Vault is sealed or unavailable (503): " ++ truncateDetail body)
  HttpStatus code body ->
    VaultSessionUnavailable ("Vault login failed (" ++ show code ++ "): " ++ truncateDetail body)
  HttpTimeout detail -> VaultSessionUnavailable ("Vault login timeout: " ++ detail)
  HttpConnectionFailure detail -> VaultSessionUnavailable ("Vault login connection failure: " ++ detail)
  HttpDecode detail -> VaultSessionUnavailable ("Vault login response decode error: " ++ detail)

-- | Project a session error back onto an 'HttpError' so callers that already
-- render 'HttpError' keep their error taxonomy unchanged.
sessionErrorToHttp :: VaultSessionError -> HttpError
sessionErrorToHttp err = case err of
  VaultSessionSealed detail -> HttpStatus 503 detail
  VaultSessionForbidden detail -> HttpStatus 403 detail
  VaultSessionUnavailable detail -> HttpConnectionFailure detail

truncateDetail :: String -> String
truncateDetail detail
  | length detail > 200 = take 200 detail ++ "…"
  | otherwise = detail

-- | Run a token-consuming Vault operation through the session. Acquire a token
-- (cached or single-flight refreshed), run @op@, and on a @403@ perform exactly
-- one invalidate-and-relogin and retry once. Session-acquisition failures are
-- projected back to 'HttpError' so the caller's existing error handling is
-- unchanged.
withSessionToken
  :: VaultSession
  -> (VaultToken -> IO (Either HttpError a))
  -> IO (Either HttpError a)
withSessionToken session op = do
  tokenResult <- sessionToken session
  case tokenResult of
    Left sessionErr -> pure (Left (sessionErrorToHttp sessionErr))
    Right token -> do
      firstResult <- op token
      case firstResult of
        Left err
          | isForbiddenHttpError err -> do
              reloginResult <- reloginAfterForbidden session token
              case reloginResult of
                Left sessionErr -> pure (Left (sessionErrorToHttp sessionErr))
                Right freshToken -> op freshToken
        _ -> pure firstResult

-- | The identity of a shared session: one persistent 'VaultSession' per
-- (address, auth path, role).
data GatewaySessionKey = GatewaySessionKey
  { gatewaySessionAddress :: String
  , gatewaySessionAuthPath :: String
  , gatewaySessionRole :: String
  }
  deriving (Eq, Ord, Show)

-- | The one process-global session registry. It lives here, outside every
-- daemon-runtime module, so no daemon path defines module-level mutable state;
-- the @unsafePerformIO@ + @NOINLINE@ idiom creates the map exactly once.
{-# NOINLINE sharedSessionRegistry #-}
sharedSessionRegistry :: MVar (Map GatewaySessionKey VaultSession)
sharedSessionRegistry = unsafePerformIO (newMVar Map.empty)

-- | Look up the persistent session for @key@, creating and caching it on first
-- use via @create@.
resolveSharedSession
  :: GatewaySessionKey -> (GatewaySessionKey -> IO VaultSession) -> IO VaultSession
resolveSharedSession key create =
  modifyMVar sharedSessionRegistry (lookupOrCreateSession key create)

lookupOrCreateSession
  :: GatewaySessionKey
  -> (GatewaySessionKey -> IO VaultSession)
  -> Map GatewaySessionKey VaultSession
  -> IO (Map GatewaySessionKey VaultSession, VaultSession)
lookupOrCreateSession key create registry =
  case Map.lookup key registry of
    Just session -> pure (registry, session)
    Nothing -> do
      session <- create key
      pure (Map.insert key session registry, session)
