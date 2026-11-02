{-# LANGUAGE OverloadedStrings #-}

module RegisteredCallerNativeTraffic (registeredCallerNativeTrafficSuite) where

import Control.Monad (forM_, replicateM_, void)
import ControlPlaneRpcAdmissionBirth
  ( RpcBirthCallerVaultFault (CallerVaultHealthy)
  , withRpcBirthCallerVaultFixture
  , withRpcBirthPreparedCoordinatorRegistryWireFixture
  )
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Text qualified as Text
import Prodbox.Capacity.RegisteredCallerTraffic
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyRefFor)
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (..)
  , externalCallerLoginWithToken
  , externalCallerPrincipal
  )
import Prodbox.ControlPlane.RegisteredRpcSigning
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RpcAdmissionBirthBootstrap
import Prodbox.ControlPlane.RpcAdmissionBirthConfig (validateRpcBirthConfig)
import Prodbox.ControlPlane.RpcAdmissionBirthExecution (rpcBirthObservedRegistry)
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcAdmissionBirthWire (rpcBirthRegistryResponseMaximumBytes)
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Session (SessionClock (..), newVaultSession)
import TestSupport

registeredCallerNativeTrafficSuite :: SuiteBuilder ()
registeredCallerNativeTrafficSuite = describe "registered caller native Vault traffic" $
  forM_ [LifecycleAuthorityOperator, LifecycleAuthorityTestHarness] $ \caller ->
    forM_ [0, 1, 2] $ \frames ->
      it (show caller <> " origin/public/signing prefix for " <> show frames <> " frames") $
        nativeTrafficCase caller frames

-- This exercises the real cached session, native Vault SDK and bootstrap/
-- registered signer. Only the HTTP service and authenticated Authority wire
-- are fixtures. Epoch and lazy-manifest costs remain separate upper terms.
nativeTrafficCase :: ExternalLifecycleAuthorityCaller -> Int -> IO ()
nativeTrafficCase caller frames = do
  now <- rpcBirthSystemTime
  let deadline = authorityTimeFromMicros (authorityTimeMicros now + 20000000)
      scope = must (mkAuthorityScope "home")
      principal = externalCallerPrincipal caller
      ref = controlPlaneSigningKeyRefFor principal
      extraScope = must (mkAuthorityScope "traffic-extra")
      extraVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
      extraSigner = must (mkRequestSigner CallerTestHarness (must (mkSigningKeyGeneration 1)) (BS.replicate 32 211))
      extra =
        must
          ( mkRpcObservedKey
              (mkRpcKeyOrigin extraScope extraVault (controlPlaneSigningKeyRefFor CallerTestHarness))
              1
              (requestSignerPublicKeyBytes extraSigner)
          )
  withRpcBirthCallerVaultFixture caller CallerVaultHealthy $ \address paths ->
    withRpcBirthPreparedCoordinatorRegistryWireFixture [extra] deadline (pure Nothing) $ \registration observer bounds providers inner _ -> do
      registry <- must <$> observeRpcKeyRegistry observer
      session <-
        newVaultSession
          address
          (SessionClock (pure 0))
          (externalCallerLoginWithToken address caller "synthetic-token")
      let mode = must (validateRpcBirthConfig LifecycleAuthorityRuntime scope registration)
          native = vaultNativeRpcSigningInterpreter scope ref session
          wire method headers url body
            | isRpcOwnBindingQuery body = do
                let query = must (decodeRpcOwnBindingQuery scope body)
                pure (Right (200, encodeRpcOwnBindingHint (must (selectRpcOwnBindingHint query registry))))
            | otherwise = inner method headers url body
          client =
            must
              ( Client.controlPlaneClientWithTransport
                  rpcBirthRegistryResponseMaximumBytes
                  (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                  wire
              )
          readRegistry = do
            observed <-
              observeRpcBirthBootstrapRegistry
                native
                (Right <$> rpcBirthSystemTime)
                (Transport.provideAuthenticatedClientNonce providers)
                scope
                mode
                deadline
                bounds
                client
            pure (first (const RpcKeyRegistryObservationUnavailable) (rpcBirthObservedRegistry <$> observed))
          registered =
            vaultRegisteredRpcSigningInterpreter scope scope ref session (RpcKeyRegistryObserver readRegistry)
      discovered <- must <$> readRegistry
      checked <- must <$> resolveActiveRegisteredRpcSigningCapability registered discovered
      replicateM_
        frames
        (void (must <$> signCanonicalBytesWithRequestCapability checked "native-caller-count"))
      actual <- readIORef paths
      let expected = registeredCallerNativeTraffic (fromIntegral frames)
          countPrefix prefix = fromIntegral (length (filter (Text.isPrefixOf prefix . Text.pack) actual))
      countPrefix "/v1/sys/health" `shouldBe` nativeOriginReads expected
      countPrefix "/v1/transit/keys/" `shouldBe` nativePublicKeyReads expected
      countPrefix "/v1/transit/sign/" `shouldBe` nativeSignatures expected
      length (filter (== "/v1/auth/kubernetes/login") actual) `shouldBe` 1
      fromIntegral (length actual)
        `shouldBe` (1 + nativeOriginReads expected + nativePublicKeyReads expected + nativeSignatures expected)

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
