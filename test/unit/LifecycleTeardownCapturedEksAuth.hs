{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCapturedEksAuth (lifecycleTeardownCapturedEksAuthSuite) where

import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import EksClientAuthProjectionFixture
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthorityProviderEndpoint
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.EksClientAuthClient
import Prodbox.ControlPlane.EksClientAuthProjection
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Lifecycle.Authority.Admission
  ( ProviderOperationCleanupOwner (ProviderOperationOwnedByCleanupOperation)
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros, authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program (SomeTeardownOperation (..), teardownOperationTag)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

data Scenario
  = Healthy
  | MissingMarker
  | InvalidBase64
  | WrongDestination
  | WrongAccount
  | WrongRegion
  | WrongCluster
  | Expired
  | WireDenied
  | WireMalformed
  | SignerDenied
  | InvalidAccount
  | InvalidCluster
  deriving (Eq, Show)

lifecycleTeardownCapturedEksAuthSuite :: SuiteBuilder ()
lifecycleTeardownCapturedEksAuthSuite = describe "captured EKS issuance" $ do
  it "opens the real encrypted reply through one borrowed Authority request and exact cleanup owner" $ do
    context <- identityFor "commit-eks-drain-intent/aws-eks" "first" "attempt-a"
    (result, requests, consumed) <- runFixture Healthy context
    result `shouldBe` Right ()
    consumed `shouldBe` 1
    checkRequest context requests
  forM_ refusalCases $ \(scenario, expected) ->
    it (show scenario) $ do
      context <- identityFor "commit-eks-drain-intent/aws-eks" "refusal" "attempt-a"
      (result, requests, consumed) <- runFixture scenario context
      result `shouldBe` Left expected
      consumed `shouldBe` 0
      checkRequest context requests
  forM_ [WireDenied, WireMalformed] $ \scenario ->
    it (show scenario <> " has no projection callback or fallback") $ do
      context <- identityFor "commit-eks-drain-intent/aws-eks" "wire" "attempt-a"
      (result, requests, consumed) <- runFixture scenario context
      result `shouldSatisfy` dispatchRefused
      consumed `shouldBe` 0
      checkRequest context requests
  forM_ [InvalidAccount, InvalidCluster] $ \scenario ->
    it (show scenario <> " refuses before transport") $ do
      context <- identityFor "commit-eks-drain-intent/aws-eks" "invalid" "attempt-a"
      (result, requests, consumed) <- runFixture scenario context
      result `shouldBe` Left EksClientAuthRequestInvalid
      requests `shouldBe` []
      consumed `shouldBe` 0
  it "does not seek another credential source when the captured signer refuses" $ do
    context <- identityFor "commit-eks-drain-intent/aws-eks" "signer" "attempt-a"
    (result, requests, consumed) <- runFixture SignerDenied context
    result `shouldSatisfy` dispatchRefused
    requests `shouldBe` []
    consumed `shouldBe` 0
  it "keeps distinct run, node and admitted attempt identities in issuance keys" $ do
    first <- identityFor "commit-eks-drain-intent/aws-eks" "same" "attempt-a"
    otherRun <- identityFor "commit-eks-drain-intent/aws-eks" "other" "attempt-a"
    otherNode <- identityFor "drain-eks-kubernetes/aws-eks" "same" "attempt-a"
    otherAttempt <- identityFor "commit-eks-drain-intent/aws-eks" "same" "attempt-b"
    let keys = map eksClientAuthTeardownExecutionSubmissionKey [first, otherRun, otherNode, otherAttempt]
    length (unique keys) `shouldBe` 4
    forM_ [first, otherRun, otherNode, otherAttempt] $ \context -> do
      (result, requests, _) <- runFixture Healthy context
      result `shouldBe` Right ()
      checkRequest context requests

refusalCases :: [(Scenario, EksClientAuthClientError)]
refusalCases =
  [ (MissingMarker, EksClientAuthEvidenceInvalid)
  , (InvalidBase64, EksClientAuthEvidenceInvalid)
  , (WrongDestination, EksClientAuthEvidenceInvalid)
  , (WrongAccount, EksClientAuthProjectionBindingMismatch)
  , (WrongRegion, EksClientAuthProjectionBindingMismatch)
  , (WrongCluster, EksClientAuthProjectionBindingMismatch)
  , (Expired, EksClientAuthProjectionExpired)
  ]

checkRequest :: TeardownExecutionIdentity -> [ProviderDispatchPayload] -> IO ()
checkRequest context requests = case requests of
  [payload] -> do
    providerDispatchVersion payload `shouldBe` providerDispatchFormatVersion
    providerDispatchSubmissionKey payload `shouldBe` eksClientAuthTeardownExecutionSubmissionKey context
    providerDispatchCleanupOwner payload
      `shouldBe` ProviderOperationOwnedByCleanupOperation (teardownExecutionIdentityOperationId context)
    providerDispatchLane payload `shouldBe` ProviderAdmitAndExecute
    case providerDispatchIntent payload of
      IssueEksClientAuth request -> do
        eksClientAuthRequestAccountId request `shouldBe` account
        eksClientAuthRequestRegion request `shouldBe` region
        eksClientAuthRequestClusterName request `shouldBe` cluster
        BS.length (eksClientAuthRequestDestinationPublicKey request) `shouldBe` 32
      other -> expectationFailure ("unexpected intent: " <> show other)
  _ -> expectationFailure ("expected exactly one request, observed " <> show (length requests))

runFixture
  :: Scenario
  -> TeardownExecutionIdentity
  -> IO (Either EksClientAuthClientError (), [ProviderDispatchPayload], Int)
runFixture scenario context = do
  requests <- newIORef []
  consumed <- newIORef (0 :: Int)
  nonceCount <- newIORef (0 :: Int)
  now <- floor <$> getPOSIXTime
  let scope = must (mkAuthorityScope "home")
      bounds = must (mkAuthenticatedTransportBounds 65536 1024 65000)
      signer = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.replicate 32 193))
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
      wire _ _ _ frame = do
        authenticated <-
          authenticateControlPlaneFrame
            bounds
            lifetime
            server
            LifecycleAuthorityRuntime
            LifecycleProviderDispatch
            (Lazy.fromStrict frame)
        let request = authenticatedServerVerifiedRequest (must authenticated)
            payload = must (decodeControlPlaneRequest 65536 (Lazy.fromStrict (verifiedRequestBody request)))
        verifiedRequestDeadline request `shouldBe` authorityTimeFromMicros 6000000
        modifyIORef' requests (<> [payload])
        case scenario of
          WireDenied -> pure (Right (403, encoded (ProviderDispatchRefused "denied")))
          WireMalformed -> pure (Right (200, "invalid-cbor"))
          _ -> case providerDispatchIntent payload of
            IssueEksClientAuth requestBody -> do
              evidence <- evidenceFor scenario now requestBody
              let outcome =
                    providerExecutionOutcome
                      (ProviderIntentExecutionObserved (providerIntentCoordinate (providerDispatchIntent payload)) evidence)
              pure (Right (200, encoded (ProviderDispatchExecuted operation outcome)))
            other -> fail ("unexpected provider request: " <> show other)
      getSigner =
        pure
          ( if scenario == SignerDenied
              then Left "captured signer refused"
              else Right (localRequestSigningCapability signer)
          )
      nextNonce = do
        n <- atomicModifyIORef' nonceCount advance
        pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral n)))))
      providers =
        AuthenticatedClientProviders
          getSigner
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (pure (Right (authorityTimeFromMicros 6000000)))
          nextNonce
      client =
        must
          (controlPlaneClientWithTransport 65536 (must (mkLifecycleAuthorityEndpoint "http://home.test")) wire)
      transport = mkAuthenticatedClientTransport bounds providers client
      requestedAccount = if scenario == InvalidAccount then "invalid" else account
      requestedCluster = if scenario == InvalidCluster then "bad/cluster" else cluster
      consume projection = do
        modifyIORef' consumed (+ 1)
        eksClientAuthBearerToken projection `shouldBe` "synthetic-bearer"
        pure ()
  result <-
    withEksClientAuthProjectionForTeardownExecutionWithTransport
      transport
      context
      requestedAccount
      region
      requestedCluster
      consume
  trace <- readIORef requests
  count <- readIORef consumed
  pure (result, trace, count)
 where
  advance n = (n + 1, n + 1)
  encoded = Lazy.toStrict . encodeControlPlaneResponse

evidenceFor :: Scenario -> Integer -> EksClientAuthRequest -> IO Text
evidenceFor scenario now request = case scenario of
  MissingMarker -> pure "missing-marker"
  InvalidBase64 -> pure (eksClientAuthEvidenceMarker <> "!base64!")
  WrongDestination -> do
    (_, envelope, _) <-
      must
        <$> testEksClientAuthProjectionFixture
          account
          region
          cluster
          (clusterArn account region cluster)
          endpoint
          "Y2E="
          "synthetic-bearer"
          (now + 120)
    pure (evidence envelope)
  _ -> do
    let actualAccount = if scenario == WrongAccount then "210987654321" else account
        actualRegion = if scenario == WrongRegion then fixtureAwsRegion FixtureEuWest1 else region
        actualCluster = if scenario == WrongCluster then "other-cluster" else cluster
        expiry = if scenario == Expired then now - 1 else now + 120
    envelope <-
      must
        <$> testEksClientAuthEnvelopeForDestination
          (eksClientAuthRequestDestinationPublicKey request)
          actualAccount
          actualRegion
          actualCluster
          (clusterArn actualAccount actualRegion actualCluster)
          endpoint
          "Y2E="
          "synthetic-bearer"
          expiry
    pure (evidence envelope)
 where
  evidence =
    (eksClientAuthEvidenceMarker <>)
      . TextEncoding.decodeUtf8
      . Base64.encode
      . encodeEksClientAuthEnvelope

-- This fixture lowers an actual compiled node into its opaque metadata identity.
-- It is not a descriptor-bound Authority or physical admission proof.
newtype IdentityCapture value = IdentityCapture {runIdentityCapture :: IORef (Maybe TeardownExecutionIdentity) -> IO value}
instance Functor IdentityCapture where
  fmap f action = IdentityCapture (\sink -> f <$> runIdentityCapture action sink)
instance Applicative IdentityCapture where
  pure value = IdentityCapture (\_ -> pure value)
  function <*> value = IdentityCapture (\sink -> runIdentityCapture function sink <*> runIdentityCapture value sink)
instance Monad IdentityCapture where
  action >>= next =
    IdentityCapture
      (\sink -> runIdentityCapture action sink >>= \value -> runIdentityCapture (next value) sink)
instance LifecycleTeardownEffects IdentityCapture where
  executeLifecycleTeardownOperation context _ = IdentityCapture $ \sink -> do
    writeIORef sink (Just (teardownExecutionIdentity context))
    pure (TeardownNodeRefused "captured metadata only")

identityFor :: Text -> Text -> Text -> IO TeardownExecutionIdentity
identityFor tag runSuffix attemptText = do
  let run = must (mkCleanupRunId ("issuer-" <> runSuffix))
      scope = AwsScope (AwsAccountId account) (AwsRegion region)
      compiled =
        must
          ( compileDesiredAbsenceGraphForRegisteredKeys
              run
              (LinuxRke2FoundationId "issuer-home")
              (Just scope)
              Nothing
              ExplicitPerRunSurface
              [AwsEksKey]
          )
      plans =
        [ plan
        | plan <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
        , Just (SomeTeardownOperation operationBody) <-
            [compiledOperationForNode (cleanupNodeId plan) compiled]
        , teardownOperationTag operationBody == tag
        ]
  case plans of
    [plan] -> do
      sink <- newIORef Nothing
      void
        ( runIdentityCapture
            (runCompiledTeardownNodeWithAttempt compiled (must (mkCleanupAttemptId attemptText)) plan)
            sink
        )
      observed <- readIORef sink
      maybe (fail "compiled node did not expose metadata") pure observed
    _ -> fail "compiled fixture did not contain exactly one requested node"

account, region, cluster, endpoint :: Text
account = "123456789012"
region = fixtureAwsRegion FixtureCaCentral1
cluster = "aws-eks-test-cluster"
endpoint = "https://example.eks.amazonaws.com"

clusterArn :: Text -> Text -> Text -> Text
clusterArn a r c = "arn:aws:eks:" <> r <> ":" <> a <> ":cluster/" <> c

operation :: OperationId
operation =
  OperationId
    authorityEpochGenesis
    (ClientId "issuer")
    (ClientSequence 1)
    (RequestDigest "fixture-request")

dispatchRefused :: Either EksClientAuthClientError value -> Bool
dispatchRefused result = case result of
  Left (EksClientAuthDispatchFailed _) -> True
  _ -> False

unique :: (Eq value) => [value] -> [value]
unique = foldr add []
 where
  add value rest = if value `elem` rest then rest else value : rest

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
