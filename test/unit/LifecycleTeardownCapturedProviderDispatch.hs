{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCapturedProviderDispatch (lifecycleTeardownCapturedProviderDispatchSuite) where

import Control.Monad (forM_, replicateM)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthorityProviderEndpoint hiding (providerDispatchSubmissionKey)
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Http.Client (HttpBoundedError (..), HttpError (HttpConnectionFailure))
import Prodbox.Lifecycle.Authority.ClientRegistry (clientSubmissionKeyText)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun (mkCleanupOperationId)
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros, authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

lifecycleTeardownCapturedProviderDispatchSuite :: SuiteBuilder ()
lifecycleTeardownCapturedProviderDispatchSuite = describe "captured Provider dispatch" $ do
  forM_ cases $ \(name, response, expected) ->
    it name $ do
      (actual, payloads, signatures) <- runFixture response False 1
      expected actual `shouldBe` True
      signatures `shouldBe` 1
      payloads `shouldBe` [payload]
  it "uses the same supplied transport for repeated dispatch without replacing its key or owner" $ do
    (actual, payloads, signatures) <- runFixture executed False 2
    actual `shouldBe` TeardownProviderCompleted outcome
    signatures `shouldBe` 2
    payloads `shouldBe` [payload, payload]
  it "propagates an unavailable captured signer before any HTTP without trying another auth source" $ do
    (actual, payloads, signatures) <- runFixture executed True 1
    isUnavailable actual `shouldBe` True
    payloads `shouldBe` []
    signatures `shouldBe` 1

cases
  :: [(String, Either HttpBoundedError (Int, BS.ByteString), TeardownProviderBoundaryResult -> Bool)]
cases =
  [ ("preserves a freshly executed kind and evidence", executed, (== TeardownProviderCompleted outcome))
  ,
    ( "keeps an executed response with inconsistent status unresolved"
    , reply 503 (ProviderDispatchExecuted operation outcome)
    , isUnavailable
    )
  ,
    ( "keeps an old completion with no retained kind unresolved"
    , reply 200 (ProviderDispatchCompleted operation "old")
    , isUnavailable
    )
  ,
    ( "keeps an already completed response with no kind unresolved"
    , reply 200 (ProviderDispatchAlreadyCompleted operation "old")
    , isUnavailable
    )
  ,
    ( "refuses an admitted-only answer to an execute request"
    , reply 200 (ProviderDispatchAdmitted operation)
    , isRefused
    )
  ,
    ( "preserves a definite Authority refusal"
    , reply 403 (ProviderDispatchRefused "denied")
    , (== TeardownProviderRefused "denied")
    )
  ,
    ( "preserves Authority unavailability"
    , reply 503 (ProviderDispatchUnavailable "offline")
    , (== TeardownProviderUnavailable "offline")
    )
  , ("keeps malformed wire data unresolved", Right (200, "malformed"), isUnavailable)
  ,
    ( "keeps a lost reply unresolved without replaying transport"
    , Left (HttpBoundedTransport (HttpConnectionFailure "lost"))
    , isUnavailable
    )
  ,
    ( "keeps a response outside the captured client's byte ceiling unresolved"
    , Right (200, BS.replicate 65537 42)
    , isUnavailable
    )
  ]

runFixture
  :: Either HttpBoundedError (Int, BS.ByteString)
  -> Bool
  -> Int
  -> IO (TeardownProviderBoundaryResult, [ProviderDispatchPayload], Int)
runFixture response denySigner repeats = do
  requests <- newIORef []
  signerCalls <- newIORef (0 :: Int)
  nonces <- newIORef (0 :: Int)
  let scope = must (mkAuthorityScope "home")
      bounds = must (mkAuthenticatedTransportBounds 65536 1024 65000)
      signer = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.replicate 32 191))
      trusted = trustedRequestKeyFromSigner signer
      trust =
        must
          ( mkRouteTrustRegistry
              LifecycleAuthorityRuntime
              1
              [(route, trusted) | route <- routesForRole LifecycleAuthorityRuntime]
          )
      server =
        AuthenticatedServerProviders
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (pure (Right (authorityTimeFromMicros 1000000)))
          (pure (Right trust))
      lifetime = must (authorityDurationFromMicros 10000000)
      transport _ _ _ frame = do
        verified <-
          authenticateControlPlaneFrame
            bounds
            lifetime
            server
            LifecycleAuthorityRuntime
            LifecycleProviderDispatch
            (Lazy.fromStrict frame)
        let decoded =
              must
                (decodeControlPlaneRequest 65536 (Lazy.fromStrict (authenticatedServerInnerBody (must verified))))
        modifyIORef' requests (<> [decoded])
        pure response
      getSigner = do
        modifyIORef' signerCalls (+ 1)
        pure
          (if denySigner then Left "captured signer refused" else Right (localRequestSigningCapability signer))
      nextNonce = do
        value <- atomicModifyIORef' nonces advance
        pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral value)))))
      providers =
        AuthenticatedClientProviders
          getSigner
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (pure (Right (authorityTimeFromMicros 6000000)))
          nextNonce
      client =
        must
          ( controlPlaneClientWithTransport
              65536
              (must (mkLifecycleAuthorityEndpoint "http://home.test"))
              transport
          )
      boundary =
        productionTeardownProviderBoundaryWithTransport
          (mkAuthenticatedClientTransport bounds providers client)
  results <-
    replicateM repeats (runTeardownProviderBoundary boundary key ObserveProviderAwsScope)
  actualRequests <- readIORef requests
  calls <- readIORef signerCalls
  pure (last results, actualRequests, calls)
 where
  advance value = (value + 1, value + 1)

payload :: ProviderDispatchPayload
payload =
  ProviderDispatchPayload
    providerDispatchFormatVersion
    (clientSubmissionKeyText (providerDispatchSubmissionKey key))
    ObserveProviderAwsScope
    (providerDispatchKeyCleanupOwner key)
    ProviderAdmitAndExecute

key :: ProviderDispatchKey
key =
  must
    ( mkProviderDispatchKey
        (must (mkCleanupOperationId "captured-cascade-provider"))
        ProviderDecisionObservation
    )

operation :: OperationId
operation =
  OperationId
    authorityEpochGenesis
    (ClientId "captured-caller")
    (ClientSequence 1)
    (RequestDigest "captured-request")

outcome :: ProviderExecutionOutcome
outcome =
  providerExecutionOutcome
    (ProviderIntentExecutionObserved (providerIntentCoordinate ObserveProviderAwsScope) "observed")

executed :: Either HttpBoundedError (Int, BS.ByteString)
executed = reply 200 (ProviderDispatchExecuted operation outcome)

reply :: Int -> ProviderDispatchResponse -> Either HttpBoundedError (Int, BS.ByteString)
reply status value = Right (status, Lazy.toStrict (encodeControlPlaneResponse value))

isUnavailable, isRefused :: TeardownProviderBoundaryResult -> Bool
isUnavailable result = case result of
  TeardownProviderUnavailable _ -> True
  TeardownProviderCompleted _ -> False
  TeardownProviderRefused _ -> False
isRefused result = case result of
  TeardownProviderRefused _ -> True
  TeardownProviderCompleted _ -> False
  TeardownProviderUnavailable _ -> False

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
