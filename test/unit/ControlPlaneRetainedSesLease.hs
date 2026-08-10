{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRetainedSesLease (controlPlaneRetainedSesLeaseSuite) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  , trustedRequestKeyFromSigner
  )
import Prodbox.ControlPlane.RetainedSesLeaseClient
import Prodbox.ControlPlane.RetainedSesLeaseEndpoint
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlanePost)
  , ControlPlaneRoute (LifecycleRetainedSesLease)
  , decodeRoleRoute
  , routesForRole
  )
import Prodbox.Http.Client
  ( HttpBoundedError (HttpBoundedTransport)
  , HttpError (HttpConnectionFailure)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , LeaseAcquireDecision (LeaseAcquireCompareAndSwap)
  , LeaseKey
  , LeaseProjection
  , StableQuiescenceWitness
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , beginLeaseAcquire
  , decideLeaseAcquire
  , defaultSesLeasePolicy
  , encodeLeaseProjection
  , mkLeaseKey
  , mkOwnerNonce
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

controlPlaneRetainedSesLeaseSuite :: SuiteBuilder ()
controlPlaneRetainedSesLeaseSuite =
  describe "Sprint 4.50 closed retained SES lease authority transport" $ do
    it "round-trips observe/initialize/replace through the role-indexed route" $ do
      authority <- sampleAuthority
      key <- sampleKey
      projection <- sampleProjection authority key
      (serverAdapter, state, writes) <- memoryAdapter
      handler <-
        accepted
          ( mkRetainedSesLeaseHandler
              (32 * 1024)
              defaultSesLeasePolicy
              authority
              key
              serverAdapter
          )
      client <- clientFor handler
      let capability = lifecycleAuthorityRetainedSesLease defaultSesLeasePolicy key client

      observeRetainedSesLease capability `shouldReturn` ModelBMissing
      initialized <- initializeRetainedSesLease capability projection
      version1 <- appliedVersion initialized
      observeRetainedSesLease capability
        `shouldReturn` ModelBObserved version1 projection
      replaced <- replaceRetainedSesLease capability version1 projection
      version2 <- appliedVersion replaced
      version2 `shouldNotBe` version1
      readIORef state `shouldReturn` Just (version2, projection)
      readIORef writes `shouldReturn` 2

    it "refuses a valid projection for another lease key before retained CAS" $ do
      authority <- sampleAuthority
      expectedKey <- sampleKey
      otherKey <- accepted (mkLeaseKey "999999999999" "ca-central-1" "aws-ses")
      otherProjection <- sampleProjection authority otherKey
      (serverAdapter, _, writes) <- memoryAdapter
      handler <-
        accepted
          ( mkRetainedSesLeaseHandler
              (32 * 1024)
              defaultSesLeasePolicy
              authority
              expectedKey
              serverAdapter
          )
      response <-
        runRetainedSesLeaseHandler
          handler
          ( encodeControlPlaneRequest
              (InitializeRetainedSesLease (encodeLeaseProjection otherProjection))
          )
      case response of
        RetainedSesLeaseProjectionRefused _ -> pure ()
        other -> expectationFailure ("expected projection refusal, got " ++ show other)
      retainedSesLeaseResponseHttpStatus response `shouldBe` ReplyBadRequest
      readIORef writes `shouldReturn` 0

    it "never sends a caller-selected coordinate through the closed client" $ do
      authority <- sampleAuthority
      key <- sampleKey
      projection <- sampleProjection authority key
      calls <- newIORef (0 :: Int)
      endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
      rawClient <-
        accepted
          ( controlPlaneClientWithTransport
              retainedSesLeaseMaximumResponseBytes
              endpoint
              (\_ _ _ _ -> modifyIORef' calls (+ 1) >> pure (Left impossibleTransport))
          )
      let client = authenticatedClientTransport rawClient
      adapter <-
        accepted
          ( retainedSesLeaseModelBCasAdapter
              authority
              key
              (lifecycleAuthorityRetainedSesLease defaultSesLeasePolicy key client)
          )
      otherCoordinate <-
        accepted (mkClusterRetainedCoordinate authority "leases/not-the-registered-object")
      modelBObserve adapter otherCoordinate
        `shouldReturn` ModelBCorrupt coordinateRefusal
      modelBCompareAndSwap adapter (ModelBInitialize otherCoordinate projection)
        `shouldReturn` ModelBCasRefusedCorrupt coordinateRefusal
      readIORef calls `shouldReturn` 0

    it "fails closed before raw transport when authenticated signer provisioning is absent" $ do
      key <- sampleKey
      calls <- newIORef (0 :: Int)
      nonceCalls <- newIORef (0 :: Int)
      endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
      rawClient <-
        accepted
          ( controlPlaneClientWithTransport
              retainedSesLeaseMaximumResponseBytes
              endpoint
              (\_ _ _ _ -> modifyIORef' calls (+ 1) >> pure (Left impossibleTransport))
          )
      let unavailableProviders =
            clientProviders
              { provideAuthenticatedClientSigner =
                  pure (Left "host signer provisioning contract is absent")
              , provideAuthenticatedClientNonce =
                  modifyIORef' nonceCalls (+ 1) >> pure (Right requestNonce)
              }
          transport =
            mkAuthenticatedClientTransport
              transportBounds
              unavailableProviders
              rawClient
          capability =
            lifecycleAuthorityRetainedSesLease defaultSesLeasePolicy key transport
      observation <- observeRetainedSesLease capability
      observation
        `shouldBe` ModelBEndpointUnready
          "AuthenticatedClientSignerUnavailable \"host signer provisioning contract is absent\""
      readIORef calls `shouldReturn` 0
      readIORef nonceCalls `shouldReturn` 0

    it "owns one closed route and does not revive gateway object-store paths" $ do
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/authority/retained-ses-lease"
        `shouldBe` Just LifecycleRetainedSesLease
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/object-store/authority/cas"
        `shouldBe` Nothing
      decodeRoleRoute
        LifecycleAuthorityRuntime
        ControlPlanePost
        "/v1/object-store/pulumi/put"
        `shouldBe` Nothing

    it "keeps the production lease and authority-clock path free of legacy transports" $ do
      runtimeSource <- readFile "src/Prodbox/Lifecycle/LeaseRuntime.hs"
      sesSource <- readFile "src/Prodbox/Infra/AwsSesStack.hs"
      leaseClientSource <- readFile "src/Prodbox/ControlPlane/RetainedSesLeaseClient.hs"
      runtimeSource `shouldNotContain` "Prodbox.Gateway"
      runtimeSource `shouldNotContain` "checkpointAuthorityGatewayEndpoint"
      sesSource `shouldNotContain` "observeGatewayAuthorityTime"
      sesSource `shouldNotContain` "waitForGatewayAuthorityTime"
      sesSource `shouldNotContain` "leaseProjectionModelBCodec"
      sesSource `shouldContain` "withHostLifecycleAuthorityAuthentication"
      sesSource `shouldContain` "dispatchAuthenticatedProviderIntentFresh"
      leaseClientSource `shouldContain` "callAuthenticatedClientTransport"
      leaseClientSource `shouldNotContain` "callControlPlane"

sampleAuthority :: IO LongLivedCheckpointAuthority
sampleAuthority =
  accepted
    ( mkLongLivedCheckpointAuthority
        "cluster-a"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

sampleKey :: IO LeaseKey
sampleKey = accepted (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

sampleProjection
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> IO LeaseProjection
sampleProjection authority key = do
  owner <- accepted (mkOwnerNonce "owner-nonce-0123456789")
  request <-
    accepted
      ( beginLeaseAcquire
          defaultSesLeasePolicy
          authority
          key
          owner
          (authorityTimeFromMicros 1000000)
      )
  case decideLeaseAcquire
    defaultSesLeasePolicy
    (authorityTimeFromMicros 1000000)
    request
    (Nothing :: Maybe (StableQuiescenceWitness ()))
    ModelBMissing of
    LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) -> pure projection
    decision -> fail ("expected initial lease projection, got " ++ show decision)

memoryAdapter
  :: IO
       ( ModelBCasAdapter 'ClusterRetained IO LeaseProjection
       , IORef (Maybe (ModelBObjectVersion, LeaseProjection))
       , IORef Int
       )
memoryAdapter = do
  state <- newIORef Nothing
  writes <- newIORef 0
  counter <- newIORef (0 :: Int)
  let nextVersion = do
        modifyIORef' counter (+ 1)
        value <- readIORef counter
        accepted (mkModelBObjectVersion ("version-" <> Text.pack (show value)))
      observe = do
        current <- readIORef state
        pure $ case current of
          Nothing -> ModelBMissing
          Just (version, projection) -> ModelBObserved version projection
      cas request = case request of
        ModelBInitialize _ projection -> do
          current <- readIORef state
          case current of
            Just (version, oldProjection) ->
              pure (ModelBCasConflict (ModelBObserved version oldProjection))
            Nothing -> apply projection
        ModelBReplace _ expected projection -> do
          current <- readIORef state
          case current of
            Just (actual, _)
              | actual == expected -> apply projection
            Nothing -> pure (ModelBCasConflict ModelBMissing)
            Just (actual, oldProjection) ->
              pure (ModelBCasConflict (ModelBObserved actual oldProjection))
        ModelBInitializeGuarded {} -> pure (ModelBCasRefusedCorrupt "unexpected guarded CAS")
        ModelBReplaceGuarded {} -> pure (ModelBCasRefusedCorrupt "unexpected guarded CAS")
      apply projection = do
        version <- nextVersion
        writeIORef state (Just (version, projection))
        modifyIORef' writes (+ 1)
        pure (ModelBCasApplied version projection)
  pure
    ( ModelBCasAdapter
        { modelBObserve = const observe
        , modelBCompareAndSwap = cas
        }
    , state
    , writes
    )

clientFor
  :: RetainedSesLeaseHandler IO
  -> IO (AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
clientFor handler = do
  endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    accepted
      ( controlPlaneClientWithTransport
          retainedSesLeaseMaximumResponseBytes
          endpoint
          ( \method _ url body -> do
              method `shouldBe` "POST"
              url `shouldBe` "http://lifecycle-authority:8600/v1/authority/retained-ses-lease"
              authenticated <-
                authenticateControlPlaneFrame
                  transportBounds
                  maximumLifetime
                  serverProviders
                  LifecycleAuthorityRuntime
                  LifecycleRetainedSesLease
                  (LazyByteString.fromStrict body)
              case authenticated of
                Left err -> pure (Right (401, TextEncoding.encodeUtf8 (Text.pack (show err))))
                Right request -> do
                  response <-
                    runRetainedSesLeaseHandler
                      handler
                      (LazyByteString.fromStrict (authenticatedServerInnerBody request))
                  pure
                    ( Right
                        ( replyStatusCode (retainedSesLeaseResponseHttpStatus response)
                        , retainedSesLeaseResponseBody response
                        )
                    )
          )
      )
  pure (authenticatedClientTransport rawClient)

authenticatedClientTransport
  :: ControlPlaneClient 'LifecycleAuthorityRuntime
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
authenticatedClientTransport =
  mkAuthenticatedClientTransport transportBounds clientProviders

clientProviders :: AuthenticatedClientProviders IO
clientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability requestSigner))
    , provideAuthenticatedClientScope = pure (Right authorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right deadline)
    , provideAuthenticatedClientNonce = pure (Right requestNonce)
    }

serverProviders :: AuthenticatedServerProviders IO
serverProviders =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right authorityScope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right now)
    , provideAuthenticatedServerTrustRegistry = pure (Right trustRegistry)
    }

transportBounds :: AuthenticatedTransportBounds
transportBounds = mustRight (mkAuthenticatedTransportBounds 65536 256 65000)

maximumLifetime :: AuthorityDuration
maximumLifetime = mustRight (authorityDurationFromMicros 5000)

now :: AuthorityTime
now = authorityTimeFromMicros 1000

deadline :: AuthorityTime
deadline = authorityTimeFromMicros 2000

requestSigner :: RequestSigner
requestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

requestNonce :: RequestNonce
requestNonce = mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

authorityScope :: AuthorityScope
authorityScope = mustRight (mkAuthorityScope "cluster-a")

trustRegistry :: RouteTrustRegistry
trustRegistry =
  mustRight
    ( mkRouteTrustRegistry
        LifecycleAuthorityRuntime
        1
        [ (route, trustedRequestKeyFromSigner requestSigner)
        | route <- routesForRole LifecycleAuthorityRuntime
        ]
    )

appliedVersion :: ModelBCasResult value -> IO ModelBObjectVersion
appliedVersion result = case result of
  ModelBCasApplied version _ -> pure version
  _ -> fail "expected applied CAS"

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

impossibleTransport :: HttpBoundedError
impossibleTransport =
  HttpBoundedTransport
    (HttpConnectionFailure "must not be called")

coordinateRefusal :: Text.Text
coordinateRefusal =
  "closed retained SES lease capability refused a non-registered coordinate"
