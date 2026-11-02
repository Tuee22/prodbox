{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRpcBirthWire (controlPlaneRpcBirthWireSuite) where

import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RequestReplay
import Prodbox.ControlPlane.RoleReadiness
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint (isRpcBirthObservationForRole)
import Prodbox.ControlPlane.RpcAdmissionBirthExecution qualified as Birth
import Prodbox.ControlPlane.RpcAdmissionBirthWire
import Prodbox.ControlPlane.RpcAdmissionBirthWire qualified as Wire
import Prodbox.ControlPlane.Server (RoleInterpreter (..))
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk))
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

controlPlaneRpcBirthWireSuite :: SuiteBuilder ()
controlPlaneRpcBirthWireSuite = describe "shared RPC birth response classes" $ do
  it "preserves the ordinary and distinct registry ceilings" $ do
    rpcBirthResponseMaximumForBody rpcBirthRequestPrefix `shouldBe` Just 65536
    rpcBirthResponseMaximumForBody rpcBirthDescriptorRequest `shouldBe` Just 65536
    rpcBirthResponseMaximumForBody rpcBirthRegistryRequest `shouldBe` Just 139520
    rpcBirthRegistryObservationMaximumBytes `shouldBe` 139392

  it "leaves unrelated request families unclassified" $ do
    rpcBirthResponseMaximumForBody BS.empty `shouldBe` Nothing
    rpcBirthResponseMaximumForBody "an unrelated migration request" `shouldBe` Nothing
    rpcBirthResponseMaximumForBody "prodbox-rpc-birth-request/v2\NUL" `shouldBe` Nothing

  it "keeps malformed family tails inside their producer bound" $ do
    classifyRpcBirthWireFamily (rpcBirthRequestPrefix <> "invalid")
      `shouldBe` Just RpcBirthCommandFamily
    rpcBirthResponseMaximumForBody (rpcBirthRegistryRequest <> "invalid") `shouldBe` Just 139520

  describe "authenticated producer and replay completion" $ do
    let key = Text.replicate 32 "a"
        cases =
          [ ("prepare", Birth.encodeRpcBirthCommand (Birth.PrepareRpcBirth 1 key), 65536)
          , ("complete", Birth.encodeRpcBirthCommand (Birth.CompleteRpcBirth 1 key), 65536)
          , ("abort", Birth.encodeRpcBirthCommand (Birth.AbortRpcBirth 1 key), 65536)
          , ("observe", Birth.encodeRpcBirthCommand Birth.ObserveRpcBirth, 65536)
          , ("descriptor", Wire.rpcBirthDescriptorRequest, 65536)
          , ("registry", Wire.rpcBirthRegistryRequest, 139520)
          , ("malformed registry", Wire.rpcBirthRegistryRequest <> "invalid", 139520)
          , ("unrelated migration", "unrelated migration body", 2097152)
          ]
    forM_ cases $ \(label, body, maximumBytes) -> describe label $
      forM_ [False, True] $ \oversized ->
        it
          ( if oversized
              then "refuses overflow without inventing replay completion"
              else "delivers its ceiling and preserves exact or fresh replay"
          )
          (one body maximumBytes oversized)

one :: ByteString -> Int -> Bool -> IO ()
one body maximumBytes oversized = do
  let limits = must (mkRequestReplayLimits 4 2097152 skew)
      payload = BS.replicate (maximumBytes + if oversized then 1 else 0) 97
  state <- newIORef (0 :: Int, initialRequestReplayProjection limits)
  effects <- newIORef (0 :: Int)
  frame <- capture body
  let repository =
        RequestReplayRepository
          { readRequestReplayProjection = do
              (revision, projection) <- readIORef state
              pure (Right (RequestReplaySnapshot revision projection))
          , compareAndSwapRequestReplayProjection = \expected projection -> atomicModifyIORef' state (swap expected projection)
          }
      inner =
        RoleInterpreter
          (constantRoleReadinessSource (readyRoleReadinessFacts "producer-fixture" 1000000000))
          (\_ _ -> modifyIORef' effects (+ 1) >> pure (Just (ReplyOk, payload)))
      wrapped attempt =
        authenticatedRoleInterpreterWithReadPolicy
          isRpcBirthObservationForRole
          bounds
          lifetime
          (AuthenticatedRoleProviders server (pure (Right attempt)))
          LifecycleAuthorityRuntime
          (must (mkReplayCasAttempts 4))
          limits
          repository
          (contextFreeAuthenticatedRoleHandler inner)
      attemptA = must (mkReplayAttemptId (BS.pack [32 .. 47]))
      attemptB = must (mkReplayAttemptId (BS.pack [48 .. 63]))
  first <- interpreterHandle (wrapped attemptA) LifecycleMigrationApply frame
  duplicate <- interpreterHandle (wrapped attemptB) LifecycleMigrationApply frame
  if oversized
    then do
      unless
        (first == Just (authenticatedRolePlainResponse AuthenticatedRoleHandlerInvalidResponse))
        (fail ("overflow accepted: " <> show (fmap (BS.length . snd) first)))
      unless
        (duplicate == Just (authenticatedRolePlainResponse AuthenticatedRoleReplayInFlight))
        (fail "overflow invented a completion")
    else do
      unless
        (first == Just (ReplyOk, payload))
        (fail ("bounded producer refused: " <> show (fmap (BS.length . snd) first)))
      let expected =
            if isRpcBirthObservationForRole LifecycleAuthorityRuntime LifecycleMigrationApply body
              then Just (authenticatedRolePlainResponse AuthenticatedRoleReadReplayRequiresFreshNonce)
              else first
      unless (duplicate == expected) (fail "producer changed exact/fresh replay policy")
      (_, projection) <- readIORef state
      if isRpcBirthObservationForRole LifecycleAuthorityRuntime LifecycleMigrationApply body
        then
          unless
            (BS.length (must (encodeRequestReplayProjection 1024 limits projection)) < 1024)
            (fail "fresh read retained its delivered payload")
        else pure ()
  readIORef effects >>= \n -> unless (n == 1) (fail "duplicate repeated the producer effect")
 where
  swap expected projection observed@(revision, _)
    | revision == expected = ((revision + 1, projection), RequestReplayCasApplied)
    | otherwise = (observed, RequestReplayCasConflict)

capture :: ByteString -> IO ByteString
capture body = do
  output <- newIORef Nothing
  let endpoint = must (mkLifecycleAuthorityEndpoint "http://authority.test:8600")
      providers =
        AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability signer)))
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (pure (Right deadline))
          (pure (Right nonce))
  client <-
    pure
      ( must
          ( controlPlaneClientWithTransport
              1024
              endpoint
              (\_ _ _ bytes -> writeIORef output (Just bytes) >> pure (Right (200, "ok")))
          )
      )
  result <- callAuthenticatedControlPlane bounds providers client LifecycleMigrationApplyRoute body
  unless (result == Right (ControlPlaneResponse 200 "ok")) (fail (show result))
  readIORef output >>= maybe (fail "client sent no frame") pure

signer :: RequestSigner
signer = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.pack [0 .. 31]))
scope :: AuthorityScope
scope = must (mkAuthorityScope "cluster-a")
nonce :: RequestNonce
nonce = must (mkRequestNonce (BS.pack [0 .. 15]))
bounds :: AuthenticatedTransportBounds
bounds = must (mkAuthenticatedTransportBounds 65536 256 65000)
now, deadline :: AuthorityTime
now = authorityTimeFromMicros 1000
deadline = authorityTimeFromMicros 2000
skew, lifetime :: AuthorityDuration
skew = must (authorityDurationFromMicros 100)
lifetime = must (authorityDurationFromMicros 5000)
server :: AuthenticatedServerProviders IO
server =
  AuthenticatedServerProviders
    (pure (Right scope))
    (pure (Right authorityEpochGenesis))
    (pure (Right now))
    ( pure
        ( Right
            ( must
                ( mkRouteTrustRegistry
                    LifecycleAuthorityRuntime
                    1
                    [(route, trustedRequestKeyFromSigner signer) | route <- routesForRole LifecycleAuthorityRuntime]
                )
            )
        )
    )
must :: (Show e) => Either e a -> a
must = either (error . show) id
