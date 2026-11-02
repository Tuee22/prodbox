{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownCapturedCreationBinding
  ( lifecycleTeardownCapturedCreationBindingSuite
  , withHealthyCapturedCreationTransport
  , cleanupScope
  , scopeOperation
  ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef
import Data.Text (Text)
import LifecycleTeardownStackGeneration qualified as Fixture
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate (mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId, mkCleanupOperationId)
import Prodbox.Lifecycle.Lease (authorityDurationFromMicros, authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( ProviderCreationBindingReadError (..)
  , readProviderCreationBindingWithTransport
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.StackGeneration
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

data Scenario = Healthy | SelectMissing | CreationMissing | ForeignOperation | ForeignRevision
  deriving (Eq, Show)

lifecycleTeardownCapturedCreationBindingSuite :: SuiteBuilder ()
lifecycleTeardownCapturedCreationBindingSuite = describe "captured creation binding" $ do
  it "uses exactly selection and independent creation read-back with the original scope operation" $ do
    (result, frames) <- runFixture Healthy AwsTestKey cleanupScope
    let expected =
          must
            ( mkAwsStackProviderBinding
                cleanupOperation
                AwsTestKey
                cleanupScope
                Fixture.providerScopeRevision
                Fixture.fixtureProviderConfig
            )
    result `shouldBe` Right expected
    length frames `shouldBe` 2
    take 1 frames `shouldBe` [awsStackCreationSelectWireRequest AwsTestKey scopeOperation cleanupScope]
    map awsStackCreationWireRequestAction frames
      `shouldBe` [AwsStackCreationWireSelectForCleanup, AwsStackCreationWireIndependentReadBack]
  it "refuses a missing AWS scope before any network request" $ do
    (result, frames) <-
      runFixture
        Healthy
        AwsTestKey
        (scopeWith Cascade lifecycleRegistryRevision Fixture.fixtureFoundation Nothing)
    result `shouldBe` Left ProviderCreationAwsScopeMissing
    frames `shouldBe` []
  forM_ foreignScopes $ \(name, key, scope, expected) ->
    it name $ do
      (result, frames) <- runFixture Healthy key scope
      result `shouldBe` Left (ProviderCreationSelectedIdentityRefused expected)
      frames `shouldBe` [awsStackCreationSelectWireRequest key scopeOperation scope]
  it "leaves an unavailable selection unresolved without another scope or read-back" $ do
    (result, frames) <- runFixture SelectMissing AwsTestKey cleanupScope
    result `shouldSatisfy` isSelectionRefused
    frames `shouldBe` [awsStackCreationSelectWireRequest AwsTestKey scopeOperation cleanupScope]
  it "requires the independent creation object after selection" $ do
    (result, frames) <- runFixture CreationMissing AwsTestKey cleanupScope
    result `shouldSatisfy` isReadBackRefused
    length frames `shouldBe` 2
  it "refuses a different creating operation after exact read-back" $ do
    (result, frames) <- runFixture ForeignOperation AwsTestKey cleanupScope
    result `shouldBe` Left ProviderCreationOperationMismatch
    length frames `shouldBe` 2
  it "refuses a committed revision different from the selected generation" $ do
    (result, frames) <- runFixture ForeignRevision AwsTestKey cleanupScope
    result `shouldBe` Left ProviderCreationRevisionMismatch
    length frames `shouldBe` 2

foreignScopes :: [(String, RegisteredResourceKey, ObservationEvidenceScope, StackGenerationError)]
foreignScopes =
  [
    ( "refuses a foreign registered key before creation read-back"
    , AwsEksKey
    , cleanupScope
    , StackGenerationResourceKeyMismatch AwsTestKey AwsEksKey
    )
  ,
    ( "refuses a foreign foundation before creation read-back"
    , AwsTestKey
    , scopeWith Cascade lifecycleRegistryRevision foreignFoundation (Just Fixture.fixtureAwsScope)
    , StackGenerationFoundationMismatch Fixture.fixtureFoundation foreignFoundation
    )
  ,
    ( "refuses a foreign registry revision before creation read-back"
    , AwsTestKey
    , scopeWith Cascade foreignRevision Fixture.fixtureFoundation (Just Fixture.fixtureAwsScope)
    , StackGenerationRegistryRevisionMismatch lifecycleRegistryRevision foreignRevision
    )
  ,
    ( "refuses a foreign AWS account before creation read-back"
    , AwsTestKey
    , scopeWith Cascade lifecycleRegistryRevision Fixture.fixtureFoundation (Just foreignAccount)
    , StackGenerationAwsAccountMismatch
        (awsScopeAccountId Fixture.fixtureAwsScope)
        (awsScopeAccountId foreignAccount)
    )
  ,
    ( "refuses a foreign AWS region before creation read-back"
    , AwsTestKey
    , scopeWith Cascade lifecycleRegistryRevision Fixture.fixtureFoundation (Just foreignRegion)
    , StackGenerationAwsRegionMismatch
        (awsScopeRegion Fixture.fixtureAwsScope)
        (awsScopeRegion foreignRegion)
    )
  ,
    ( "refuses a surface that cannot select this stack"
    , AwsTestKey
    , scopeWith
        LocalOnly
        lifecycleRegistryRevision
        Fixture.fixtureFoundation
        (Just Fixture.fixtureAwsScope)
    , StackGenerationSurfaceRefused LocalOnly AwsTestKey
    )
  ]
 where
  foreignFoundation = LinuxRke2FoundationId "foundation/foreign"
  foreignRevision = RegistryRevision "foreign-registry"
  foreignAccount = Fixture.fixtureAwsScope {awsScopeAccountId = AwsAccountId "210987654321"}
  foreignRegion = Fixture.fixtureAwsScope {awsScopeRegion = AwsRegion (fixtureAwsRegion FixtureEuWest1)}

runFixture
  :: Scenario
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> IO (Either ProviderCreationBindingReadError AwsStackProviderBinding, [AwsStackCreationWireRequest])
runFixture scenario key scope =
  withCapturedCreationTransport scenario unexpectedRoute $ \transport ->
    readProviderCreationBindingWithTransport transport scopeOperation cleanupOperation key scope
 where
  unexpectedRoute _ _ url _ = fail ("unexpected creation-fixture route: " <> url)

-- Shared actual-wire fixture for the managed cloud-composition probe. The
-- fallback is the HTTP boundary for its other registered Authority routes.
withHealthyCapturedCreationTransport
  :: ControlPlaneTransport
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (value, [AwsStackCreationWireRequest])
withHealthyCapturedCreationTransport = withCapturedCreationTransport Healthy

withCapturedCreationTransport
  :: Scenario
  -> ControlPlaneTransport
  -> (AuthenticatedClientTransport 'LifecycleAuthorityRuntime -> IO value)
  -> IO (value, [AwsStackCreationWireRequest])
withCapturedCreationTransport scenario otherRoute consume = do
  original <- observedCreationAt "captured-original" "a" Fixture.providerScopeRevision
  (generation, committed) <- case scenario of
    ForeignRevision -> do
      let revision = must (mkProviderRevision 2)
          intent =
            ReconcileRegisteredStack
              (must (mkProviderStackRef "aws-test"))
              revision
              Fixture.fixtureProviderConfig
              Fixture.fixtureProviderRunMarker
      (operation, admitted) <- Fixture.admitFixtureIntent "other-revision" "c" intent
      observed <-
        must
          <$> observeAuthorityAwsStackCreationOperation
            (Fixture.readOnlyAuthorityRepository admitted)
            revision
            operation
      providerScope <- Fixture.fixtureVerifiedProviderScope
      gen <-
        pure
          ( must
              ( establishRegisteredStackGeneration
                  observed
                  providerScope
                  Fixture.fixtureFoundation
                  Fixture.creatingRunScope
                  ExplicitPerRun
                  initialStackGenerationOrdinal
              )
          )
      pure (gen, must (prepareAwsStackCreationBinding observed creationScope))
    ForeignOperation -> do
      observed <- observedCreationAt "different-operation" "b" Fixture.providerScopeRevision
      gen <- generationFrom original
      pure (gen, must (prepareAwsStackCreationBinding observed creationScope))
    _ -> do
      gen <- generationFrom original
      pure (gen, must (prepareAwsStackCreationBinding original creationScope))
  requests <- newIORef []
  nonces <- newIORef (0 :: Int)
  let authScope = must (mkAuthorityScope "home")
      bounds = must (mkAuthenticatedTransportBounds 65536 1024 65000)
      signer = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.replicate 32 192))
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
          (pure (Right authScope))
          (pure (Right authorityEpochGenesis))
          (pure (Right (authorityTimeFromMicros 1000000)))
          (pure (Right trust))
      lifetime = must (authorityDurationFromMicros 10000000)
      transport method headers url frame
        | url /= "http://home.test" <> controlPlaneRoutePath LifecycleAwsStackCreationBinding =
            otherRoute method headers url frame
        | otherwise = do
            verified <-
              authenticateControlPlaneFrame
                bounds
                lifetime
                server
                LifecycleAuthorityRuntime
                LifecycleAwsStackCreationBinding
                (Lazy.fromStrict frame)
            let authenticated = authenticatedServerVerifiedRequest (must verified)
                request = must (decodeControlPlaneRequest 65536 (Lazy.fromStrict (verifiedRequestBody authenticated)))
            verifiedRequestDeadline authenticated `shouldBe` authorityTimeFromMicros 6000000
            modifyIORef' requests (<> [request])
            let answer = replyFor scenario generation committed request
            pure
              ( Right
                  ( replyStatusCode (awsStackCreationWireResponseStatus answer)
                  , Lazy.toStrict (encodeControlPlaneResponse answer)
                  )
              )
      nextNonce = do
        value <- atomicModifyIORef' nonces advance
        pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral value)))))
      providers =
        AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability signer)))
          (pure (Right authScope))
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
  result <- consume (mkAuthenticatedClientTransport bounds providers client)
  frames <- readIORef requests
  pure (result, frames)
 where
  advance value = (value + 1, value + 1)

replyFor
  :: Scenario
  -> RegisteredStackGeneration
  -> AwsStackCreationBinding
  -> AwsStackCreationWireRequest
  -> AwsStackCreationWireResponse
replyFor scenario generation committed request = case awsStackCreationWireRequestAction request of
  AwsStackCreationWireSelectForCleanup
    | scenario == SelectMissing ->
        AwsStackCreationWireRefused version (AwsStackCreationWireScopeUnproven "scope not settled")
    | otherwise ->
        AwsStackCreationWireSelected
          version
          (awsStackCreationWireRequestPayload request)
          (encodeRegisteredStackGeneration generation)
  AwsStackCreationWireIndependentReadBack
    | scenario == CreationMissing ->
        AwsStackCreationWireRefused version AwsStackCreationWireReadBackMissing
    | otherwise ->
        AwsStackCreationWireReadBackPresent
          version
          (encodeAwsStackCreationAuthorityIdentity (awsStackCreationBindingIdentity committed))
          (awsStackCreationBindingBytes committed)
  AwsStackCreationWireCommitAttempt -> error "captured reader attempted a mutation"
 where
  version = awsStackCreationEndpointFormatVersion

scopeWith
  :: CleanupSurface
  -> RegistryRevision
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> ObservationEvidenceScope
scopeWith surface revision foundation aws =
  mkObservationEvidenceScope
    surface
    revision
    (DurableObservationRunScope "captured-cascade/original-run")
    foundation
    aws
    ReconcileDesiredAbsent

cleanupScope, creationScope :: ObservationEvidenceScope
cleanupScope =
  scopeWith Cascade lifecycleRegistryRevision Fixture.fixtureFoundation (Just Fixture.fixtureAwsScope)
creationScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    Fixture.creatingRunScope
    Fixture.fixtureFoundation
    (Just Fixture.fixtureAwsScope)
    ReconcileDesiredPresent

scopeOperation :: OperationId
scopeOperation =
  OperationId
    authorityEpochGenesis
    (ClientId "captured-program")
    (ClientSequence 2)
    (RequestDigest "original-scope-observation")

cleanupOperation :: CleanupOperationId
cleanupOperation = must (mkCleanupOperationId "captured-cascade-node")

isSelectionRefused, isReadBackRefused :: Either ProviderCreationBindingReadError value -> Bool
isSelectionRefused result = case result of
  Left (ProviderCreationSelectRefused _) -> True
  _ -> False
isReadBackRefused result = case result of
  Left (ProviderCreationReadBackRefused _) -> True
  _ -> False

must :: (Show failure) => Either failure value -> value
must = either (error . show) id

observedCreationAt :: Text -> Text -> ProviderRevision -> IO ObservedAwsStackCreationOperation
observedCreationAt label digest revision = do
  let intent =
        ReconcileRegisteredStack
          (must (mkProviderStackRef "aws-test"))
          revision
          Fixture.fixtureProviderConfig
          Fixture.fixtureProviderRunMarker
  (operation, admitted) <- Fixture.admitFixtureIntent label digest intent
  must
    <$> observeAuthorityAwsStackCreationOperation
      (Fixture.readOnlyAuthorityRepository admitted)
      revision
      operation

generationFrom :: ObservedAwsStackCreationOperation -> IO RegisteredStackGeneration
generationFrom observed = do
  providerScope <- Fixture.fixtureVerifiedProviderScope
  pure
    ( must
        ( establishRegisteredStackGeneration
            observed
            providerScope
            Fixture.fixtureFoundation
            Fixture.creatingRunScope
            ExplicitPerRun
            initialStackGenerationOrdinal
        )
    )
