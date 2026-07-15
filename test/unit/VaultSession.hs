{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.64 conformance suite for the cached renewable Vault session
-- ("Prodbox.Vault.Session"). Every behavior is exercised against a fake
-- monotonic clock and a fake login boundary — no live Vault, no cluster.
module VaultSession
  ( vaultSessionSuite
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
  ( newEmptyMVar
  , putMVar
  , takeMVar
  )
import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import Data.Text qualified as Text
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Vault.Client (VaultAddress (..), VaultToken (..))
import Prodbox.Vault.Session
import TestSupport

-- | A controllable fake monotonic clock backed by an 'IORef'.
mkFakeClock :: Double -> IO (Double -> IO (), SessionClock)
mkFakeClock start = do
  ref <- newIORef start
  pure (writeIORef ref, SessionClock (readIORef ref))

-- | A fake login that hands out @token-0@, @token-1@, … with a fixed lease and
-- counts how many times it was invoked.
mkCountingLogin :: Int -> IO (IO Int, SessionLogin)
mkCountingLogin leaseSeconds = do
  counter <- newIORef (0 :: Int)
  let login = do
        n <- readIORef counter
        writeIORef counter (n + 1)
        pure
          ( Right
              LoginLease
                { loginLeaseToken = VaultToken (Text.pack ("token-" ++ show n))
                , loginLeaseSeconds = leaseSeconds
                , loginLeaseRenewable = True
                }
          )
  pure (readIORef counter, login)

tokenText :: Either VaultSessionError VaultToken -> Either VaultSessionError Text.Text
tokenText = fmap unVaultToken

vaultSessionSuite :: SuiteBuilder ()
vaultSessionSuite =
  describe "Sprint 1.64 cached renewable Vault session" $ do
    describe "pure freshness algebra" $ do
      it "renews at two-thirds of the lease" $ do
        renewalDueSeconds (sampleCached 90 0) `shouldBe` 60
      it "is fresh before the renewal point and stale at or after it" $ do
        cachedTokenFresh 59 (sampleCached 90 0) `shouldBe` True
        cachedTokenFresh 60 (sampleCached 90 0) `shouldBe` False
        cachedTokenFresh 61 (sampleCached 90 0) `shouldBe` False
      it "is never fresh for a non-positive lease" $ do
        cachedTokenFresh 0 (sampleCached 0 0) `shouldBe` False
        cachedTokenFresh 0 (sampleCached (-5) 0) `shouldBe` False

    describe "error classification" $ do
      it "maps login HttpErrors to the right session error" $ do
        classifyKind (httpErrorToSessionError (HttpStatus 403 "denied")) `shouldBe` "forbidden"
        classifyKind (httpErrorToSessionError (HttpStatus 503 "sealed")) `shouldBe` "sealed"
        classifyKind (httpErrorToSessionError (HttpStatus 500 "boom")) `shouldBe` "unavailable"
        classifyKind (httpErrorToSessionError (HttpTimeout "t")) `shouldBe` "unavailable"
        classifyKind (httpErrorToSessionError (HttpConnectionFailure "c")) `shouldBe` "unavailable"
      it "recognizes only a 403 as the relogin trigger" $ do
        isForbiddenHttpError (HttpStatus 403 "x") `shouldBe` True
        isForbiddenHttpError (HttpStatus 401 "x") `shouldBe` False
        isForbiddenHttpError (HttpTimeout "x") `shouldBe` False
      it "projects a session error back onto an HttpError" $ do
        sessionErrorToHttp (VaultSessionForbidden "m") `shouldBe` HttpStatus 403 "m"
        sessionErrorToHttp (VaultSessionSealed "m") `shouldBe` HttpStatus 503 "m"
        sessionErrorToHttp (VaultSessionUnavailable "m") `shouldBe` HttpConnectionFailure "m"

    describe "sessionToken caching and renewal" $ do
      it "serves the cached token while fresh and refreshes past the renewal point" $ do
        (setClock, clock) <- mkFakeClock 0
        (loginCount, login) <- mkCountingLogin 90
        session <- newVaultSession (VaultAddress "addr") clock login
        r1 <- sessionToken session
        tokenText r1 `shouldBe` Right "token-0"
        loginCount >>= (`shouldBe` 1)
        setClock 59
        r2 <- sessionToken session
        tokenText r2 `shouldBe` Right "token-0"
        loginCount >>= (`shouldBe` 1)
        setClock 61
        r3 <- sessionToken session
        tokenText r3 `shouldBe` Right "token-1"
        loginCount >>= (`shouldBe` 2)

      it "coalesces concurrent stale refreshes into a single login (single flight)" $ do
        (_setClock, clock) <- mkFakeClock 0
        loginStarted <- newEmptyMVar
        loginGate <- newEmptyMVar
        counter <- newIORef (0 :: Int)
        let login = do
              n <- readIORef counter
              writeIORef counter (n + 1)
              putMVar loginStarted ()
              takeMVar loginGate
              pure
                ( Right
                    LoginLease
                      { loginLeaseToken = VaultToken "shared-token"
                      , loginLeaseSeconds = 90
                      , loginLeaseRenewable = True
                      }
                )
        session <- newVaultSession (VaultAddress "addr") clock login
        resultA <- newEmptyMVar
        resultB <- newEmptyMVar
        _ <- forkIO (sessionToken session >>= putMVar resultA)
        _ <- forkIO (sessionToken session >>= putMVar resultB)
        takeMVar loginStarted
        putMVar loginGate ()
        a <- takeMVar resultA
        b <- takeMVar resultB
        tokenText a `shouldBe` Right "shared-token"
        tokenText b `shouldBe` Right "shared-token"
        readIORef counter >>= (`shouldBe` 1)

    describe "withSessionToken 403 handling" $ do
      it "returns the op result on success without a relogin" $ do
        (_setClock, clock) <- mkFakeClock 0
        (loginCount, login) <- mkCountingLogin 90
        session <- newVaultSession (VaultAddress "addr") clock login
        result <- withSessionToken session (\_ -> pure (Right ("ok" :: String)))
        result `shouldBe` Right "ok"
        loginCount >>= (`shouldBe` 1)

      it "reacts to a 403 with exactly one invalidate-and-relogin, then retries once" $ do
        (_setClock, clock) <- mkFakeClock 0
        (loginCount, login) <- mkCountingLogin 90
        session <- newVaultSession (VaultAddress "addr") clock login
        opCount <- newIORef (0 :: Int)
        let op token = do
              n <- readIORef opCount
              writeIORef opCount (n + 1)
              if unVaultToken token == "token-0"
                then pure (Left (HttpStatus 403 "denied"))
                else pure (Right ("recovered" :: String))
        result <- withSessionToken session op
        result `shouldBe` Right "recovered"
        loginCount >>= (`shouldBe` 2)
        readIORef opCount >>= (`shouldBe` 2)

      it "passes a non-403 op error through without a relogin" $ do
        (_setClock, clock) <- mkFakeClock 0
        (loginCount, login) <- mkCountingLogin 90
        session <- newVaultSession (VaultAddress "addr") clock login
        result <-
          withSessionToken
            session
            (\_ -> pure (Left (HttpStatus 500 "boom") :: Either HttpError String))
        result `shouldBe` Left (HttpStatus 500 "boom")
        loginCount >>= (`shouldBe` 1)

sampleCached :: Int -> Double -> CachedToken
sampleCached leaseSeconds obtainedAt =
  CachedToken
    { cachedToken = VaultToken "sample"
    , cachedObtainedAt = obtainedAt
    , cachedLeaseSeconds = leaseSeconds
    , cachedRenewable = True
    }

classifyKind :: VaultSessionError -> String
classifyKind err = case err of
  VaultSessionForbidden _ -> "forbidden"
  VaultSessionSealed _ -> "sealed"
  VaultSessionUnavailable _ -> "unavailable"
