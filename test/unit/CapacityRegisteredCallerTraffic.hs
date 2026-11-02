{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module CapacityRegisteredCallerTraffic (capacityRegisteredCallerTrafficSuite) where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM_, replicateM, replicateM_, (>=>))
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight, rights)
import Data.IORef
import Data.List (nub)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RegisteredCallerTraffic
import Prodbox.Capacity.RpcBirthTraffic qualified as Birth
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.Coordinate
import Prodbox.ControlPlane.RegisteredCallerBudget
import Prodbox.ControlPlane.RegisteredRpcSigning
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RpcKeyRegistry
import TestSupport

capacityRegisteredCallerTrafficSuite :: SuiteBuilder ()
capacityRegisteredCallerTrafficSuite = describe "registered caller traffic and debit accounting" $ do
  forM_ [CallerOperatorCli, CallerTestHarness] $ \principal ->
    forM_ [0, 1, 2, 8, 64, 2055] $ \frames ->
      it (show principal <> " actual resolver/signature observations for " <> show frames <> " frames") $ do
        observationsRef <- newIORef (0 :: Int)
        signatures <- newIORef (0 :: Int)
        let scope = must (mkAuthorityScope "home")
            oldVault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
            currentVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
            signer = must (mkRequestSigner principal (must (mkSigningKeyGeneration 1)) (BS.replicate 32 18))
            nativeCapability = localRequestSigningCapability signer
            public = requestSignerPublicKeyBytes signer
            origin = mkRpcKeyOrigin scope currentVault (controlPlaneSigningKeyRefFor principal)
            seedPublic selected =
              requestSignerPublicKeyBytes
                ( must
                    ( mkRequestSigner
                        selected
                        (must (mkSigningKeyGeneration 1))
                        ( BS.replicate
                            32
                            (if selected == principal then 17 else fromIntegral (callerPrincipalCode selected) + 31)
                        )
                    )
                )
            seed =
              must
                ( seedLegacyRpcKeyRegistry
                    scope
                    [ must
                        ( mkRpcObservedKey
                            (mkRpcKeyOrigin scope oldVault (controlPlaneSigningKeyRefFor selected))
                            1
                            (seedPublic selected)
                        )
                    | selected <- allCallerPrincipals
                    ]
                )
            (_, registry) = must (registerRpcKey (must (mkRpcObservedKey origin 1 public)) seed)
            interpret :: RegisteredRpcSigningProgram value -> IO (Either RegisteredRpcSigningError value)
            interpret program = case program of
              ReadRegisteredRpcNativeOrigin -> pure (Right origin)
              ReadRegisteredRpcNativePublic version -> pure (Right (version, public))
              ReadRegisteredRpcRegistry -> modifyIORef' observationsRef (+ 1) >> pure (Right registry)
              SignRegisteredRpcNative version bytes -> do
                modifyIORef' signatures (+ 1)
                signature <- signCanonicalBytesWithRequestCapability nativeCapability bytes
                pure (first (const RpcSigningSignatureUnavailable) ((version,) <$> signature))
            interpreter = RegisteredRpcSigningInterpreter interpret
        discovered <- must <$> runRegisteredRpcSigningProgram interpreter ReadRegisteredRpcRegistry
        checked <- must <$> resolveActiveRegisteredRpcSigningCapability interpreter discovered
        replicateM_
          frames
          ( signCanonicalBytesWithRequestCapability checked "bounded-caller-claims"
              >>= (\result -> must result `seq` pure ())
          )
        observed <- readIORef observationsRef
        actualSignatures <- readIORef signatures
        let traffic = registeredCallerTraffic (fromIntegral frames) 1
        fromIntegral observed `shouldBe` registryObservations traffic
        actualSignatures `shouldBe` frames
        totalSignedFrames traffic `shouldBe` (fromIntegral frames + 2 * fromIntegral observed)
        protocolHttpRequests traffic `shouldBe` (fromIntegral frames + 3 * fromIntegral observed)
  it "retains the closed birth controller's eight-frame/44-signature correspondence" $ do
    let traffic = registeredCallerTraffic 8 0
    registryObservations traffic
      `shouldBe` Birth.rpcBirthRegistryReadMaximum Birth.RpcBirthRegisteredTraffic
    totalSignedFrames traffic
      `shouldBe` Birth.rpcBirthSignedRequestMaximum Birth.RpcBirthRegisteredTraffic
  it "charges discovery and construction independently for every attempt" $ do
    let each = registeredCallerTraffic 8 3
        twice = repeatCallerAttempts 2 each
    registryObservations twice `shouldBe` 36
    totalSignedFrames twice `shouldBe` 88
    protocolHttpRequests twice `shouldBe` 124
    perExchangeForwards twice `shouldBe` 60
    totalSignedFrames twice `shouldSatisfy` (/= totalSignedFrames (registeredCallerTraffic 16 3))
  forM_
    [ (CallerOrdinaryFrame, 2)
    , (CallerRegistryObservation, 6)
    , (CallerSignedNonce, 14)
    , (CallerHomeScope, 2)
    , (CallerForward, 10)
    , (CallerProtocolHttp, 20)
    , (CallerStartupProbe, 14)
    , (CallerTokenLogin, 2)
    ]
    $ \(kind, maximumUses) ->
      it ("debits the exact finite independent allowance for " <> show kind) $ do
        budget <- must <$> newCallerBudget (registeredCallerTraffic 2 1) 2 1000000000
        successful <- replicateM maximumUses (consumeCallerBudget budget kind)
        successful `shouldSatisfy` all isRight
        consumeCallerBudget budget kind >>= (`shouldBe` Left (CallerBudgetExhausted kind))
        consumeCallerBudget budget kind >>= (`shouldBe` Left (CallerBudgetExhausted kind))
        forM_
          (filter (/= kind) [minBound .. maxBound])
          (consumeCallerBudget budget >=> (`shouldBe` Right ()))
  it "rejects forged, repeated, zero and out-of-width planning values before allocation" $ do
    let canonical = registeredCallerTraffic 2 1
        oversized = registeredCallerTraffic (fromIntegral (maxBound :: Word64) + 1) 1
    forM_
      [ (canonical {registryObservations = 7}, 1, 1000000000)
      , (repeatCallerAttempts 2 canonical, 1, 1000000000)
      , (canonical {homeScopeEntries = 0}, 1, 1000000000)
      , (canonical, 0, 1000000000)
      , (canonical, 1, 0)
      , (oversized, 1, 1000000000)
      ]
      $ \(traffic, logins, remaining) ->
        newCallerBudget traffic logins remaining >>= (`shouldSatisfy` isLeft)
  it "rounds serialized retry funding upward at the original-clock boundary" $ do
    let traffic = registeredCallerTraffic 0 0
    forM_ [(250000000, 4), (250000001, 5)] $ \(remaining, expected) -> do
      budget <- must <$> newCallerBudget traffic 1 remaining
      replicateM_ expected (consumeCallerBudget budget CallerStartupProbe >>= (`shouldBe` Right ()))
      consumeCallerBudget budget CallerStartupProbe
        >>= (`shouldBe` Left (CallerBudgetExhausted CallerStartupProbe))
  it "shares one nonce debit across concurrent copies before entering the source" $ do
    budget <- must <$> newCallerBudget (registeredCallerTraffic 2 1) 1 1000000000
    generated <- newIORef (0 :: Int)
    results <-
      Async.mapConcurrently
        (const (nextCallerBudgetedNonce budget (atomicModifyIORef' generated (\n -> (n + 1, n + 1)))))
        [1 .. 50 :: Int]
    length (filter isRight results) `shouldBe` 14
    length (filter isLeft results) `shouldBe` 36
    length (nub (rights results)) `shouldBe` 14
    readIORef generated >>= (`shouldBe` 14)
  it "does not refund a nonce after a source exception" $ do
    budget <- must <$> newCallerBudget (registeredCallerTraffic 0 0) 1 1000000000
    failed <-
      try (nextCallerBudgetedNonce budget (throwIO (userError "source failure")))
        :: IO (Either IOException (Either CallerBudgetError ()))
    failed `shouldSatisfy` isLeft
    replicateM_ 3 (nextCallerBudgetedNonce budget (pure ()) >>= (`shouldBe` Right ()))
    nextCallerBudgetedNonce budget (fail "exhausted source entered" :: IO ())
      >>= (`shouldBe` Left (CallerBudgetExhausted CallerSignedNonce))
  it "does not refund a nonce after cancellation inside its source" $ do
    budget <- must <$> newCallerBudget (registeredCallerTraffic 0 0) 1 1000000000
    entered <- newEmptyMVar
    blocked <- newEmptyMVar :: IO (MVar ())
    worker <- Async.async (nextCallerBudgetedNonce budget (putMVar entered () >> takeMVar blocked))
    takeMVar entered
    Async.cancel worker
    Async.waitCatch worker >>= (`shouldSatisfy` isLeft)
    replicateM_ 3 (nextCallerBudgetedNonce budget (pure ()) >>= (`shouldBe` Right ()))
    nextCallerBudgetedNonce budget (fail "cancelled debit was refunded" :: IO ())
      >>= (`shouldBe` Left (CallerBudgetExhausted CallerSignedNonce))

  it "includes bounded Vault retries, startup, capture and token commands" $ do
    let cost = must (registeredCallerCost 2 1 2 15000000000)
        native = callerCostNativeTraffic cost
    nativeOriginReads native `shouldBe` 48
    nativePublicKeyReads native `shouldBe` 41
    nativeSignatures native `shouldBe` 14
    nativeEpochReads native `shouldBe` 2
    nativeManifestReads native `shouldBe` 1
    nativePrimitiveCalls native `shouldBe` 106
    callerCostVaultHttp cost `shouldBe` 214
    callerCostStartupProbes cost `shouldBe` 70
    callerCostTokenLogins cost `shouldBe` 2
    callerCostTokenCommands cost `shouldBe` 6
    callerCostConfigCaptures cost `shouldBe` 1
    callerCostNativeHttp cost `shouldBe` 304
    callerCostTraffic cost `shouldBe` registeredCallerTraffic 2 1

  it "charges a complete zero-ordinary-frame prefix and one lazy manifest read" $ do
    let cost = must (registeredCallerCost 0 0 2 15000000000)
        native = callerCostNativeTraffic cost
    nativeOriginReads native `shouldBe` 16
    nativePublicKeyReads native `shouldBe` 13
    nativeSignatures native `shouldBe` 4
    nativeEpochReads native `shouldBe` 0
    nativeManifestReads native `shouldBe` 1
    nativePrimitiveCalls native `shouldBe` 34
    callerCostStartupProbes cost `shouldBe` 63
    callerCostNativeHttp cost `shouldBe` 139

  it "bounds native cost even when the protocol counters alone fit a machine word" $ do
    let wide = fromIntegral (maxBound :: Word64) :: Natural
        frames = wide `div` 10
    protocolHttpRequests (registeredCallerTraffic frames 0) `shouldSatisfy` (<= wide)
    registeredCallerCost frames 0 1 1 `shouldBe` Left CallerCostCountOverflow
    registeredCallerCost 0 0 (wide `div` 2 + 1) 1 `shouldBe` Left CallerCostCountOverflow
    registeredCallerCost 0 wide 1 1 `shouldBe` Left CallerCostCountOverflow

  it "refuses empty login/window inputs before allocating a debit owner" $ do
    registeredCallerCost 0 0 1 0 `shouldBe` Left CallerCostOriginalWindowEmpty
    registeredCallerCost 0 0 0 1 `shouldBe` Left CallerCostLoginAllowanceEmpty
    newCallerBudget (registeredCallerTraffic 0 0) 1 0 >>= (`shouldSatisfy` isLeft)
    newCallerBudget (registeredCallerTraffic 0 0) 0 1 >>= (`shouldSatisfy` isLeft)

  it "uses the same original-clock retry rounding in the checked cost and counters" $ do
    forM_ [(1, 4), (250000000, 4), (250000001, 5), (1000000000, 7)] $ \(remaining, expected) -> do
      let cost = must (registeredCallerCost 0 0 1 remaining)
      callerCostStartupProbes cost `shouldBe` expected
      budget <- must <$> newCallerBudget (callerCostTraffic cost) 1 remaining
      replicateM_
        (fromIntegral expected)
        (consumeCallerBudget budget CallerStartupProbe >>= (`shouldBe` Right ()))
      consumeCallerBudget budget CallerStartupProbe
        `shouldReturn` Left (CallerBudgetExhausted CallerStartupProbe)

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
