{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneAuthorityPeerContext (authorityPeerContextSuite) where

import Codec.Serialise (Serialise, serialise)
import Control.Concurrent.MVar (newEmptyMVar, readMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import EpochPromotionFixture
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter qualified as Role
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
  ( controlPlaneSigningKeyRefFor
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.AuthorityAuthenticatedResponse qualified as SignedResponse
import Prodbox.ControlPlane.AuthorityControlClient qualified as AuthorityControl
import Prodbox.ControlPlane.AuthorityControlProtocol (isEpochPromotionObservationForRole)
import Prodbox.ControlPlane.AuthorityManifestResponse qualified as ManifestResponse
import Prodbox.ControlPlane.AuthorityPeerContext
import Prodbox.ControlPlane.AuthorityPeerContextClient
import Prodbox.ControlPlane.AuthorityPeerContextEndpoint
import Prodbox.ControlPlane.AuthorityResponseTrust
import Prodbox.ControlPlane.AuthoritySignedObservationEndpoint (authoritySignedObservationHandler)
import Prodbox.ControlPlane.AuthoritySnapshotObservation
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Codec
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication qualified as Authentication
import Prodbox.ControlPlane.RequestReplay qualified as Replay
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcAdmissionBirthWire (rpcBirthRegistryRequest)
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk, ReplyServiceUnavailable), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission qualified as Admission
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.EpochPromotion qualified as Promotion
import Prodbox.Lifecycle.Authority.EpochPromotionCoordinator qualified as Coordinator
import Prodbox.Lifecycle.Authority.EpochPromotionObservation qualified as PromotionObservation
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Authority.Migration qualified as Migration
import Prodbox.Lifecycle.Decommission.AuthorityExport (AuthorityManifestSigner (..))
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyDigest, mkManifestPublicKey)
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime, TargetSecretAgentRuntime)
  )
import Prodbox.Vault.Client (VaultAddress (VaultAddress))
import Prodbox.Vault.Session
  ( SessionClock (SessionClock)
  , VaultSessionError (VaultSessionUnavailable)
  , newVaultSession
  )
import System.Timeout (timeout)
import TestSupport

authorityPeerContextSuite :: SuiteBuilder ()
authorityPeerContextSuite = describe "Sprint 6.5 authenticated peer epoch refresh" $ do
  it "retains the original peer request bytes and separates the signed form" $ do
    authorityPeerContextRequest `shouldBe` BS.pack [131, 0, 1, 129, 0]
    signedAuthorityPeerContextRequest `shouldSatisfy` (/= authorityPeerContextRequest)
  it
    "authenticates both Authority observations against their exact requests"
    signedAuthorityObservationControl
  it "signs the peer response under the independently pinned manifest key" manifestPeerControl
  forM_ [1, 2] $ \epoch ->
    it ("accepts peer observation signed at epoch " ++ show epoch ++ " against epoch 2") $ do
      fixture <- newFixture
      verified <- authenticate fixture LifecycleAuthorityPeerObserve epoch authorityPeerContextRequest
      Authentication.verifiedRequestAuthorityEpoch (must verified) `shouldBe` epochAt epoch
      result <- observeAuthorityPeerContext scope (fixtureInterpreter fixture) (must verified)
      peerContextEpoch (must result) `shouldBe` epochAt 2
      peerContextIssuer (must result) `shouldBe` fst issuer
      peerContextPublicKey (must result) `shouldBe` snd issuer

  it "refuses a future epoch before exposing the peer body" $ do
    fixture <- newFixture
    authenticate fixture LifecycleAuthorityPeerObserve 3 authorityPeerContextRequest
      >>= (`shouldSatisfy` isLeft)
    readIORef (effectDeadlines fixture) `shouldReturn` []

  forM_ (filter (/= LifecycleAuthorityPeerObserve) allControlPlaneRoutes) $ \route ->
    it ("keeps exact-epoch authentication for " ++ show route) $ do
      fixture <- newFixture
      authenticate fixture route 1 "ordinary-body" >>= (`shouldSatisfy` isLeft)

  it "keeps the peer verifier pinned to its route and callee" $ do
    let signed = signedFor LifecycleAuthorityControl 1 requestDeadline authorityPeerContextRequest
        context =
          Authentication.mkPeerObservationVerificationContext
            trusted
            scope
            (epochAt 2)
            requestDeadline
            nonce
            now
            lifetime
    Authentication.decodeAndVerifyControlPlaneRequest
      65000
      context
      (Authentication.encodeSignedControlPlaneRequest signed)
      `shouldBe` Left (Authentication.RequestRouteMismatch LifecycleAuthorityPeerObserve LifecycleAuthorityControl)

  it "grants the new route only to the Target Agent, operator and harness" $ do
    trustedCallersForRoute LifecycleAuthorityPeerObserve
      `shouldBe` [ Authentication.CallerOperatorCli
                 , Authentication.CallerTestHarness
                 , Authentication.CallerService TargetSecretAgentRuntime
                 ]
    trustedCallersForRoute LifecycleAuthorityPeerObserve
      `shouldSatisfy` notElem (Authentication.CallerService ProviderWorkerRuntime)

  it "does not change durable caller-slot identity across epoch refresh" $ do
    fixture <- newFixture
    peer <- must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
    ordinary <- must <$> authenticate fixture LifecycleAuthorityControl 2 "ordinary-body"
    Authentication.verifiedRequestCallerSlot peer
      `shouldBe` Authentication.verifiedRequestCallerSlot ordinary
    compare
      (Authentication.verifiedRequestCallerSlot peer)
      (Authentication.verifiedRequestCallerSlot ordinary)
      `shouldBe` EQ
    show (Authentication.verifiedRequestCallerSlot peer)
      `shouldBe` show (Authentication.verifiedRequestCallerSlot ordinary)

  it "rejects a foreign authenticated scope before the handler" $ do
    fixture <- newFixture
    let foreignScope = must (Coordinate.mkAuthorityScope "foreign-authority")
        providers =
          (serverProviders fixture LifecycleAuthorityRuntime)
            { Transport.provideAuthenticatedServerScope = pure (Right foreignScope)
            }
    result <-
      Transport.authenticateControlPlaneFrame
        bounds
        lifetime
        providers
        LifecycleAuthorityRuntime
        LifecycleAuthorityPeerObserve
        (frameFor LifecycleAuthorityPeerObserve 1 requestDeadline authorityPeerContextRequest)
    result `shouldSatisfy` isLeft

  forM_ [1, 2] $ \generation -> it ("rejects an untrusted signing key at generation " ++ show generation) $ do
    fixture <- newFixture
    let other =
          must
            ( Authentication.mkRequestSigner
                Authentication.CallerTestHarness
                (must (Authentication.mkSigningKeyGeneration generation))
                (BS.replicate 32 18)
            )
        registry = registryFor LifecycleAuthorityRuntime (Authentication.trustedRequestKeyFromSigner other)
        providers =
          (serverProviders fixture LifecycleAuthorityRuntime)
            { Transport.provideAuthenticatedServerTrustRegistry = pure (Right registry)
            }
    result <-
      Transport.authenticateControlPlaneFrame
        bounds
        lifetime
        providers
        LifecycleAuthorityRuntime
        LifecycleAuthorityPeerObserve
        (frameFor LifecycleAuthorityPeerObserve 1 requestDeadline authorityPeerContextRequest)
    result `shouldSatisfy` isLeft

  it "rejects corrupt authenticated bytes" $ do
    fixture <- newFixture
    let frame = frameFor LifecycleAuthorityPeerObserve 1 requestDeadline authorityPeerContextRequest
    result <-
      Transport.authenticateControlPlaneFrame
        bounds
        lifetime
        (serverProviders fixture LifecycleAuthorityRuntime)
        LifecycleAuthorityRuntime
        LifecycleAuthorityPeerObserve
        (frame <> "corruption")
    result `shouldSatisfy` isLeft

  it "keeps body-digest authentication on the historical-epoch route" $ do
    fixture <- newFixture
    let original = Lazy.toStrict (frameFor LifecycleAuthorityPeerObserve 1 requestDeadline "payload-a")
        (prefix, suffix) = BS.breakSubstring "payload-a" original
        changed = Lazy.fromStrict (prefix <> "payload-b" <> BS.drop 9 suffix)
    suffix `shouldSatisfy` (not . BS.null)
    result <-
      Transport.authenticateControlPlaneFrame
        bounds
        lifetime
        (serverProviders fixture LifecycleAuthorityRuntime)
        LifecycleAuthorityRuntime
        LifecycleAuthorityPeerObserve
        changed
    result
      `shouldBe` Left
        (Transport.AuthenticatedServerRequestAuthenticationFailed [Authentication.RequestBodyDigestMismatch])

  forM_ [False, True] $ \changeNonce ->
    it ("keeps signed metadata projection binding: nonce=" ++ show changeNonce) $ do
      fixture <- newFixture
      let outerDeadline = if changeNonce then requestDeadline else authorityTimeFromMicros 2500
          outerNonce = if changeNonce then must (Authentication.mkRequestNonce (BS.replicate 16 12)) else nonce
          signed = signedFor LifecycleAuthorityPeerObserve 1 requestDeadline authorityPeerContextRequest
          frame = frameWithMetadata outerDeadline outerNonce signed
      result <-
        Transport.authenticateControlPlaneFrame
          bounds
          lifetime
          (serverProviders fixture LifecycleAuthorityRuntime)
          LifecycleAuthorityRuntime
          LifecycleAuthorityPeerObserve
          frame
      result `shouldSatisfy` isLeft

  it "refuses an expired signed deadline before the handler" $ do
    fixture <- newFixture
    writeIORef (fixtureTime fixture) (Right requestDeadline)
    authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
      >>= (`shouldSatisfy` isLeft)

  it "refuses a wrong handler scope before any observation effect" $ do
    fixture <- newFixture
    verified <-
      must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
    observeAuthorityPeerContext
      (must (Coordinate.mkAuthorityScope "wrong-scope"))
      (fixtureInterpreter fixture)
      verified
      `shouldReturn` Left PeerContextBindingInvalid
    readIORef (effectDeadlines fixture) `shouldReturn` []

  it "refuses malformed peer commands before reading public facts" $ do
    fixture <- newFixture
    verified <- must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 "malformed"
    observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified
      `shouldReturn` Left PeerContextRequestInvalid
    readIORef (effectDeadlines fixture) `shouldReturn` []

  forM_
    [ ("public epoch", \fixture -> writeIORef (fixtureEpoch fixture) (Right (epochAt 3)))
    ,
      ( "issuer generation"
      , \fixture -> writeIORef (fixtureIssuer fixture) (Right (must (mkTargetIssuerKeyGeneration 2), snd issuer))
      )
    ,
      ( "issuer public key"
      , \fixture -> writeIORef (fixtureIssuer fixture) (Right (fst issuer, publicAt 19))
      )
    ]
    $ \(label, change) ->
      it ("refuses " ++ label ++ " drift between complete samples") $ do
        fixture <- newFixture
        verified <-
          must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
        writeIORef (effectHook fixture) (\count -> when (count == 3) (change fixture))
        observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified
          `shouldReturn` Left PeerContextFactsChanged

  it "refuses expiry after the closing fact read" $ do
    fixture <- newFixture
    verified <-
      must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
    writeIORef
      (effectHook fixture)
      (\count -> when (count == 4) (writeIORef (fixtureTime fixture) (Right requestDeadline)))
    observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified
      `shouldReturn` Left PeerContextDeadlineReached
    readIORef (effectDeadlines fixture) `shouldReturn` replicate 4 requestDeadline

  forM_
    [
      ( PeerContextClockUnavailable
      , \fixture -> writeIORef (fixtureTime fixture) (Left PeerContextClockUnavailable)
      )
    ,
      ( PeerContextEpochUnavailable
      , \fixture -> writeIORef (fixtureEpoch fixture) (Left PeerContextEpochUnavailable)
      )
    ,
      ( PeerContextIssuerUnavailable
      , \fixture -> writeIORef (fixtureIssuer fixture) (Left PeerContextIssuerUnavailable)
      )
    ]
    $ \(cause, change) ->
      it ("preserves unavailable observation " ++ show cause) $ do
        fixture <- newFixture
        verified <-
          must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
        change fixture
        observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified `shouldReturn` Left cause

  it "does not accept a request ahead of independently read public state" $ do
    fixture <- newFixture
    verified <-
      must <$> authenticate fixture LifecycleAuthorityPeerObserve 2 authorityPeerContextRequest
    writeIORef (fixtureEpoch fixture) (Right (epochAt 1))
    observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified
      `shouldReturn` Left PeerContextRequestEpochAhead

  it "round-trips bounded metadata and checks HTTP status and expected scope" $ do
    fixture <- newFixture
    context <- observedContext fixture
    let encoded = encodeAuthorityPeerContextResponse (Right context)
    Lazy.toStrict
      ( encodeControlPlaneResponse
          (ObservedWire "retained-home" 2 1 (targetIntentPublicKeyBytes (snd issuer)))
      )
      `shouldBe` encoded
    BS.length encoded `shouldSatisfy` (<= authorityPeerContextMaximumBytes)
    decodeAuthorityPeerContextResponse encoded `shouldBe` Right context
    decodeAuthorityPeerContextClientResponse scope (Client.ControlPlaneResponse 200 encoded)
      `shouldBe` Right context
    decodeAuthorityPeerContextClientResponse scope (Client.ControlPlaneResponse 503 encoded)
      `shouldBe` Left (PeerContextClientHttpStatus 503)
    decodeAuthorityPeerContextClientResponse
      (must (Coordinate.mkAuthorityScope "foreign-scope"))
      (Client.ControlPlaneResponse 200 encoded)
      `shouldBe` Left PeerContextClientScopeMismatch

  forM_ [PeerContextFactsChanged, PeerContextEpochUnavailable, PeerContextDeadlineReached] $ \cause ->
    it ("returns a structured remote refusal " ++ show cause) $
      decodeAuthorityPeerContextResponse (encodeAuthorityPeerContextResponse (Left cause))
        `shouldBe` Left cause

  forM_
    [ ("zero epoch", ObservedWire "retained-home" 0 1 (targetIntentPublicKeyBytes (snd issuer)))
    , ("zero issuer", ObservedWire "retained-home" 2 0 (targetIntentPublicKeyBytes (snd issuer)))
    , ("invalid scope", ObservedWire "bad scope" 2 1 (targetIntentPublicKeyBytes (snd issuer)))
    , ("invalid public key", ObservedWire "retained-home" 2 1 (BS.replicate 31 1))
    ]
    $ \(label, wire) ->
      it ("refuses canonical but invalid metadata: " ++ label) $
        decodeAuthorityPeerContextResponse (Lazy.toStrict (encodeControlPlaneResponse wire))
          `shouldBe` Left PeerContextResponseInvalid

  it "refuses oversized, corrupt and noncanonical response bytes" $ do
    fixture <- newFixture
    context <- observedContext fixture
    let encoded = encodeAuthorityPeerContextResponse (Right context)
    forM_ [BS.replicate 1025 0, "corrupt", encoded <> "trailing"] $ \bytes ->
      decodeAuthorityPeerContextResponse bytes `shouldBe` Left PeerContextResponseInvalid

  it "refuses an oversized producer before emitting a successful HTTP response" $ do
    fixture <- newFixture
    verified <-
      must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
    writeIORef
      (fixtureIssuer fixture)
      (Right (must (mkTargetIssuerKeyGeneration (2 ^ (9000 :: Natural))), snd issuer))
    authorityPeerContextVerifiedHandler scope (fixtureInterpreter fixture) verified
      `shouldReturn` Just (ReplyServiceUnavailable, encodeAuthorityPeerContextResponse (Left PeerContextResponseInvalid))

  it "uses the fixed client without invoking its ordinary epoch provider" $ do
    fixture <- newFixture
    boundary <- newBoundary fixture
    result <- requestAuthorityPeerContext scope (boundaryTransport boundary)
    peerContextEpoch (must result) `shouldBe` epochAt 2
    readIORef (ordinaryEpochCalls boundary) `shouldReturn` 0
    frames <- readIORef (boundaryFrames boundary)
    case frames of
      [frame] -> do
        authenticated <-
          Transport.authenticateControlPlaneFrame
            bounds
            lifetime
            (serverProviders fixture LifecycleAuthorityRuntime)
            LifecycleAuthorityRuntime
            LifecycleAuthorityPeerObserve
            (Lazy.fromStrict frame)
        Authentication.verifiedRequestAuthorityEpoch
          (Transport.authenticatedServerVerifiedRequest (must authenticated))
          `shouldBe` epochAt 1
      _ -> expectationFailure "expected exactly one authenticated frame"

  it "requires a fresh nonce and observes a subsequently committed epoch" $ do
    fixture <- newFixture
    boundary <- newBoundary fixture
    first <- requestAuthorityPeerContext scope (boundaryTransport boundary)
    peerContextEpoch (must first) `shouldBe` epochAt 2
    captured <- capturedFrame boundary
    writeIORef (fixtureEpoch fixture) (Right (epochAt 3))
    boundarySend boundary captured
      `shouldReturn` (409, "authenticated-read-replay-requires-fresh-nonce\n")
    second <- requestAuthorityPeerContext scope (boundaryTransport boundary)
    peerContextEpoch (must second) `shouldBe` epochAt 3

  it "caps nested signed requests and all four fact reads by the parent deadline" $ do
    fixture <- newFixture
    boundary <- newBoundary fixture
    let parent = authorityTimeFromMicros 1500
    result <-
      requestAuthorityPeerContext
        scope
        (Transport.authenticatedClientTransportWithin parent (boundaryTransport boundary))
    result `shouldSatisfy` either (const False) (const True)
    readIORef (effectDeadlines fixture) `shouldReturn` replicate 4 parent
    frame <- capturedFrame boundary
    authenticated <-
      Transport.authenticateControlPlaneFrame
        bounds
        lifetime
        (serverProviders fixture LifecycleAuthorityRuntime)
        LifecycleAuthorityRuntime
        LifecycleAuthorityPeerObserve
        (Lazy.fromStrict frame)
    Authentication.verifiedRequestDeadline
      (Transport.authenticatedServerVerifiedRequest (must authenticated))
      `shouldBe` parent

  it "does not give ordinary mutation calls the special client epoch" $ do
    fixture <- newFixture
    boundary <- newBoundary fixture
    result <-
      Transport.callAuthenticatedClientTransport
        (boundaryTransport boundary)
        Client.LifecycleAuthorityControlRoute
        "mutation"
    result `shouldBe` Left (Transport.AuthenticatedClientEpochUnavailable "ordinary epoch unavailable")
    readIORef (ordinaryEpochCalls boundary) `shouldReturn` 1
    readIORef (boundaryFrames boundary) `shouldReturn` []

  it "physically bounds refresh by the earlier sampled transport deadline" $ do
    fixture <- newFixture
    let providerDeadline = authorityTimeFromMicros 1500000
        parent = authorityTimeFromMicros 2000000
    boundary <- newBoundaryWithDeadline providerDeadline fixture
    result <-
      requestAuthorityPeerContextWithin (pure (Right now)) parent scope (boundaryTransport boundary)
    peerContextEpoch (must result) `shouldBe` epochAt 2
    readIORef (effectDeadlines fixture) `shouldReturn` replicate 4 providerDeadline
    readIORef (boundaryDeadlineCalls boundary) `shouldReturn` 1

  it "does not renew an earlier parent deadline while resolving the transport" $ do
    fixture <- newFixture
    let parent = authorityTimeFromMicros 1500000
    boundary <- newBoundaryWithDeadline (authorityTimeFromMicros 2000000) fixture
    result <-
      requestAuthorityPeerContextWithin (pure (Right now)) parent scope (boundaryTransport boundary)
    result `shouldSatisfy` either (const False) (const True)
    readIORef (effectDeadlines fixture) `shouldReturn` replicate 4 parent

  it "bounds blocked HTTP by an earlier provider deadline rather than the later parent" $ do
    blocked <- newEmptyMVar
    let transport = rawPeerTransport (pure (Right (authorityTimeFromMicros 2000))) (readMVar blocked)
    timeout
      500000
      ( requestAuthorityPeerContextWithin
          (pure (Right now))
          (authorityTimeFromMicros 2000000)
          scope
          transport
      )
      `shouldReturn` Just (Left PeerContextClientTimedOut)

  it "includes deadline-provider resolution in the parent's physical timeout" $ do
    blocked <- newEmptyMVar
    let transport = rawPeerTransport (readMVar blocked) (pure (200, "unreachable"))
    requestAuthorityPeerContextWithin (pure (Right now)) requestDeadline scope transport
      `shouldReturn` Left PeerContextClientTimedOut

  it "refuses an expired parent before resolving its provider" $ do
    calls <- newIORef (0 :: Int)
    let transport =
          rawPeerTransport
            (modifyIORef' calls (+ 1) >> pure (Right requestDeadline))
            (pure (200, "unreachable"))
    requestAuthorityPeerContextWithin (pure (Right now)) now scope transport
      `shouldReturn` Left PeerContextClientDeadlineReached
    readIORef calls `shouldReturn` 0

  it "refuses an unavailable client clock" $ do
    let transport = rawPeerTransport (pure (Right requestDeadline)) (pure (200, "unreachable"))
    requestAuthorityPeerContextWithin (pure (Left "unavailable")) requestDeadline scope transport
      `shouldReturn` Left PeerContextClientClockUnavailable

  it "does not accept a successful response after the effective deadline" $ do
    fixture <- newFixture
    context <- observedContext fixture
    clock <- newIORef now
    let deadline = authorityTimeFromMicros 2000000
        transport = rawPeerTransport (pure (Right deadline)) $ do
          writeIORef clock deadline
          pure (200, encodeAuthorityPeerContextResponse (Right context))
    requestAuthorityPeerContextWithin (Right <$> readIORef clock) deadline scope transport
      `shouldReturn` Left PeerContextClientDeadlineReached

  it "preserves cancellation during the physically bounded HTTP call" $ do
    let deadline = authorityTimeFromMicros 2000000
        transport = rawPeerTransport (pure (Right deadline)) (throwIO ThreadKilled)
    result <- try (void (requestAuthorityPeerContextWithin (pure (Right now)) deadline scope transport))
    (result :: Either AsyncException ()) `shouldBe` Left ThreadKilled

  it "refuses expired production effects before acquiring a Vault session" $ do
    logins <- newIORef (0 :: Int)
    session <- newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) $ do
      modifyIORef' logins (+ 1)
      pure (Left (VaultSessionUnavailable "unexpected login"))
    let interpreter = vaultAuthorityPeerContextInterpreter session (pure (Right now))
    runAuthorityPeerContextProgram interpreter (ReadPeerContextEpoch now)
      `shouldReturn` Left PeerContextDeadlineReached
    runAuthorityPeerContextProgram interpreter (ReadPeerContextIssuer now)
      `shouldReturn` Left PeerContextDeadlineReached
    readIORef logins `shouldReturn` 0

  it "bounds a blocked production issuer read by the original deadline" $ do
    blocked <- newEmptyMVar
    session <-
      newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) (readMVar blocked)
    let interpreter = vaultAuthorityPeerContextInterpreter session (pure (Right now))
    runAuthorityPeerContextProgram interpreter (ReadPeerContextIssuer (authorityTimeFromMicros 1100))
      `shouldReturn` Left PeerContextEffectTimedOut

  it "preserves asynchronous cancellation through the production projection" $ do
    session <-
      newVaultSession (VaultAddress "http://unused.test") (SessionClock (pure 0)) (throwIO ThreadKilled)
    let interpreter = vaultAuthorityPeerContextInterpreter session (pure (Right now))
    result <-
      try (void (runAuthorityPeerContextProgram interpreter (ReadPeerContextIssuer requestDeadline)))
    (result :: Either AsyncException ()) `shouldBe` Left ThreadKilled

-- Mirror only the private wire shape to plant semantically invalid public metadata.
data ResponseWire = ObservedWire !Text !Natural !Natural !BS.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data MetadataWire = MetadataWire !Word16 !Natural !BS.ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)
data FrameWire = FrameWire !Word16 !BS.ByteString !BS.ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)

data Fixture = Fixture
  { fixtureTime :: IORef (Either AuthorityPeerContextError AuthorityTime)
  , fixtureEpoch :: IORef (Either AuthorityPeerContextError Genesis.AuthorityEpoch)
  , fixtureIssuer
      :: IORef (Either AuthorityPeerContextError (TargetIssuerKeyGeneration, TargetIntentPublicKey))
  , effectHook :: IORef (Int -> IO ())
  , effectDeadlines :: IORef [AuthorityTime]
  , fixtureInterpreter :: AuthorityPeerContextInterpreter IO
  }

newFixture :: IO Fixture
newFixture = do
  clock <- newIORef (Right now)
  epoch <- newIORef (Right (epochAt 2))
  key <- newIORef (Right issuer)
  hook <- newIORef (const (pure ()))
  deadlines <- newIORef []
  count <- newIORef (0 :: Int)
  let mark deadline = do
        modifyIORef' deadlines (<> [deadline])
        index <- atomicModifyIORef' count (\value -> (value + 1, value + 1))
        action <- readIORef hook
        action index
      interpret :: AuthorityPeerContextProgram result -> IO (Either AuthorityPeerContextError result)
      interpret program = case program of
        ReadPeerContextTime -> readIORef clock
        ReadPeerContextEpoch deadline -> mark deadline >> readIORef epoch
        ReadPeerContextIssuer deadline -> mark deadline >> readIORef key
  pure (Fixture clock epoch key hook deadlines (AuthorityPeerContextInterpreter interpret))

serverProviders :: Fixture -> RuntimeRole -> Transport.AuthenticatedServerProviders IO
serverProviders fixture role =
  Transport.AuthenticatedServerProviders
    (pure (Right scope))
    (either (const (Left "epoch unavailable")) Right <$> readIORef (fixtureEpoch fixture))
    (either (const (Left "clock unavailable")) Right <$> readIORef (fixtureTime fixture))
    (pure (Right (registryFor role trusted)))

registryFor :: RuntimeRole -> Authentication.TrustedRequestKey -> Transport.RouteTrustRegistry
registryFor role key = must (Transport.mkRouteTrustRegistry role 1 [(route, key) | route <- routesForRole role])

authenticate
  :: Fixture
  -> ControlPlaneRoute
  -> Natural
  -> BS.ByteString
  -> IO (Either Transport.AuthenticatedServerError Authentication.VerifiedControlPlaneRequest)
authenticate fixture route epoch body = do
  result <-
    Transport.authenticateControlPlaneFrame
      bounds
      lifetime
      (serverProviders fixture (controlPlaneRouteRole route))
      (controlPlaneRouteRole route)
      route
      (frameFor route epoch requestDeadline body)
  pure (Transport.authenticatedServerVerifiedRequest <$> result)

signedFor
  :: ControlPlaneRoute
  -> Natural
  -> AuthorityTime
  -> BS.ByteString
  -> Authentication.SignedControlPlaneRequest
signedFor route epoch deadline body =
  must
    ( Authentication.signControlPlaneRequest
        signer
        route
        (controlPlaneRouteRole route)
        scope
        (epochAt epoch)
        deadline
        nonce
        body
    )

frameFor :: ControlPlaneRoute -> Natural -> AuthorityTime -> BS.ByteString -> Lazy.ByteString
frameFor route epoch deadline body =
  frameWithMetadata deadline nonce (signedFor route epoch deadline body)

frameWithMetadata
  :: AuthorityTime
  -> Authentication.RequestNonce
  -> Authentication.SignedControlPlaneRequest
  -> Lazy.ByteString
frameWithMetadata deadline requestNonce signed = serialise (FrameWire 1 metadata envelope)
 where
  metadata =
    Lazy.toStrict
      ( serialise
          (MetadataWire 1 (authorityTimeMicros deadline) (Authentication.requestNonceBytes requestNonce))
      )
  envelope =
    Lazy.toStrict (Authentication.encodeSignedControlPlaneRequest signed)

observedContext :: Fixture -> IO AuthorityPeerContext
observedContext fixture = do
  verified <-
    must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 authorityPeerContextRequest
  must <$> observeAuthorityPeerContext scope (fixtureInterpreter fixture) verified

data Boundary = Boundary
  { boundaryTransport :: Transport.AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  , boundaryFrames :: IORef [BS.ByteString]
  , boundarySend :: BS.ByteString -> IO (Int, BS.ByteString)
  , ordinaryEpochCalls :: IORef Int
  , boundaryDeadlineCalls :: IORef Int
  }

newBoundary :: Fixture -> IO Boundary
newBoundary = newBoundaryWithDeadline requestDeadline

newBoundaryWithDeadline :: AuthorityTime -> Fixture -> IO Boundary
newBoundaryWithDeadline configuredDeadline fixture = do
  frames <- newIORef []
  epochCalls <- newIORef (0 :: Int)
  nonceCounter <- newIORef (0 :: Natural)
  deadlineCalls <- newIORef (0 :: Int)
  let boundaryLifetime = must (authorityDurationFromMicros (max 10000 (authorityTimeMicros configuredDeadline)))
  let limits = must (Replay.mkRequestReplayLimits 64 2048 lifetime)
  state <- newIORef (0 :: Int, Replay.initialRequestReplayProjection limits)
  let repository =
        Replay.RequestReplayRepository
          { Replay.readRequestReplayProjection = do
              (version, projection) <- readIORef state
              pure (Right (Replay.RequestReplaySnapshot version projection))
          , Replay.compareAndSwapRequestReplayProjection = \expected projection -> atomicModifyIORef' state $ \observed@(version, _) ->
              if version == expected
                then ((version + 1, projection), Replay.RequestReplayCasApplied)
                else (observed, Replay.RequestReplayCasConflict)
          }
      wrapped =
        Role.authenticatedRoleInterpreterWithVerifiedHandler
          isAuthorityPeerContextObservationForRole
          (authorityPeerContextVerifiedHandler scope (fixtureInterpreter fixture))
          bounds
          boundaryLifetime
          ( Role.AuthenticatedRoleProviders
              (serverProviders fixture LifecycleAuthorityRuntime)
              (pure (Right (must (Replay.mkReplayAttemptId (BS.replicate 16 7)))))
          )
          LifecycleAuthorityRuntime
          (must (Replay.mkReplayCasAttempts 4))
          limits
          repository
          (Role.contextFreeAuthenticatedRoleHandler Server.failClosedInterpreter)
      send frame = do
        modifyIORef' frames (<> [frame])
        result <- Server.interpreterHandle wrapped LifecycleAuthorityPeerObserve frame
        pure $ case result of
          Just (status, bytes) -> (replyStatusCode status, bytes)
          Nothing -> (500, "missing response")
      providers =
        Transport.AuthenticatedClientProviders
          (pure (Right (Authentication.localRequestSigningCapability signer)))
          (pure (Right scope))
          (modifyIORef' epochCalls (+ 1) >> pure (Left "ordinary epoch unavailable"))
          (modifyIORef' deadlineCalls (+ 1) >> pure (Right configuredDeadline))
          ( do
              counter <- atomicModifyIORef' nonceCounter (\value -> (value + 1, value + 1))
              pure
                ( Right
                    (must (Authentication.mkRequestNonce (BS.replicate 16 1 <> Lazy.toStrict (serialise counter))))
                )
          )
      raw =
        must
          ( Client.controlPlaneClientWithTransport
              2048
              (must (Client.mkLifecycleAuthorityEndpoint "http://retained-home:8600"))
              (\_ _ _ body -> Right <$> send body)
          )
  pure
    ( Boundary
        (Transport.mkAuthenticatedClientTransport bounds providers raw)
        frames
        send
        epochCalls
        deadlineCalls
    )

manifestPeerControl :: IO ()
manifestPeerControl = do
  fixture <- newFixture
  keyReads <- newIORef (0 :: Int)
  let authoritySigner =
        must
          ( Authentication.mkRequestSigner
              (Authentication.CallerService LifecycleAuthorityRuntime)
              (must (Authentication.mkSigningKeyGeneration 1))
              (BS.replicate 32 29)
          )
      capability = Authentication.localRequestSigningCapability authoritySigner
      public = must (mkManifestPublicKey (Authentication.requestSignerPublicKeyBytes authoritySigner))
      expected = manifestPublicKeyDigest public
      manifestSigner =
        AuthorityManifestSigner
          { readAuthorityManifestPublicKey = modifyIORef' keyReads (+ 1) >> pure (Right (1, public))
          , signAuthorityManifestPayload = \bytes -> do
              signature <- Authentication.signCanonicalBytesWithRequestCapability capability bytes
              pure (either (Left . Text.pack . show) (\value -> Right (1, value)) signature)
          }
      unusedRepository =
        AuthorityAdmissionRepository
          (fail "unexpected Authority read")
          (\_ _ -> fail "unexpected Authority write")
      frame = signedFor LifecycleAuthorityPeerObserve 1 requestDeadline signedAuthorityPeerContextRequest
  verified <-
    must <$> authenticate fixture LifecycleAuthorityPeerObserve 1 signedAuthorityPeerContextRequest
  result <-
    ManifestResponse.authorityManifestSignedObservationHandler
      65536
      1024
      scope
      (fixtureInterpreter fixture)
      unusedRepository
      expected
      manifestSigner
      verified
  envelope <- case result of
    Just (Right bytes) -> pure bytes
    _ -> expectationFailure "manifest-signed peer refused valid observation" >> pure BS.empty
  let (status, body) =
        must
          ( SignedResponse.verifyAuthorityAuthenticatedResponse
              1024
              (Authentication.trustedRequestKeyFromSigner authoritySigner)
              frame
              envelope
          )
  peerContextEpoch
    ( must
        ( decodeAuthorityPeerContextClientResponse
            scope
            (Client.ControlPlaneResponse (fromIntegral status) body)
        )
    )
    `shouldBe` epochAt 2
  let wrongPublic = must (mkManifestPublicKey (Authentication.requestSignerPublicKeyBytes signer))
  ManifestResponse.authorityManifestSignedObservationHandler
    65536
    1024
    scope
    (fixtureInterpreter fixture)
    unusedRepository
    (manifestPublicKeyDigest wrongPublic)
    manifestSigner
    verified
    `shouldReturn` Just (Left ManifestResponse.ManifestResponseKeyMismatch)
  wrongRoute <- must <$> authenticate fixture LifecycleMigrationApply 2 rpcBirthRegistryRequest
  before <- readIORef keyReads
  ManifestResponse.authorityManifestSignedObservationHandler
    65536
    1024
    scope
    (fixtureInterpreter fixture)
    unusedRepository
    expected
    manifestSigner
    wrongRoute
    `shouldReturn` Nothing
  readIORef keyReads `shouldReturn` before

signedAuthorityObservationControl :: IO ()
signedAuthorityObservationControl = do
  fixture <- newFixture
  substitutions <- newIORef (0 :: Int)
  saved <- newIORef Map.empty
  nonceCounter <- newIORef (0 :: Natural)
  writes <- newIORef (0 :: Int)
  let initial =
        applyEpochAggregateCommand
          importedFrozenEpochAggregate
          ( Admission.ApplyAuthorityMigration
              (Migration.PrepareReplacementEpoch (epochFixtureEpoch 1) (epochFixtureEpoch 2) epochTopologyFixture)
          )
      repository =
        AuthorityAdmissionRepository
          { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot (1 :: Int) initial))
          , compareAndSwapAuthorityAdmission = \_ _ -> modifyIORef' writes (+ 1) >> pure (Left "unexpected write")
          }
      authoritySigner =
        must
          ( Authentication.mkRequestSigner
              (Authentication.CallerService LifecycleAuthorityRuntime)
              (must (Authentication.mkSigningKeyGeneration 1))
              (BS.replicate 32 29)
          )
      authorityKey = Authentication.trustedRequestKeyFromSigner authoritySigner
      capability = Authentication.localRequestSigningCapability authoritySigner
      limits = must (Replay.mkRequestReplayLimits 64 (2 * 1024 * 1024) lifetime)
  replayState <- newIORef (0 :: Int, Replay.initialRequestReplayProjection limits)
  let replayRepository =
        Replay.RequestReplayRepository
          { Replay.readRequestReplayProjection = do
              (version, projection) <- readIORef replayState
              pure (Right (Replay.RequestReplaySnapshot version projection))
          , Replay.compareAndSwapRequestReplayProjection = \expected projection ->
              atomicModifyIORef' replayState $ \old@(version, _) ->
                if version == expected
                  then ((version + 1, projection), Replay.RequestReplayCasApplied)
                  else (old, Replay.RequestReplayCasConflict)
          }
      readPolicy role route body =
        isAuthorityPeerContextObservationForRole role route body
          || isEpochPromotionObservationForRole role route body
      domain verified = do
        mode <- readIORef substitutions
        result <-
          if mode == 5 && Authentication.verifiedRequestRoute verified == LifecycleAuthorityPeerObserve
            then
              Just
                <$> SignedResponse.signAuthorityAuthenticatedResponse
                  65536
                  capability
                  verified
                  200
                  (BS.replicate 1025 65)
            else
              authoritySignedObservationHandler
                65536
                65536
                scope
                (fixtureInterpreter fixture)
                repository
                capability
                verified
        case result of
          Nothing
            | Authentication.verifiedRequestRoute verified == LifecycleAuthorityPeerObserve ->
                authorityPeerContextVerifiedHandler scope (fixtureInterpreter fixture) verified
            | otherwise -> do
                response <-
                  serveAuthorityControlRequest
                    65536
                    repository
                    (Lazy.fromStrict (Authentication.verifiedRequestBody verified))
                pure
                  ( Just
                      (authorityTransitionHttpStatus response, Lazy.toStrict (authorityTransitionResponseBody response))
                  )
          Just (Left _) -> pure (Just (ReplyServiceUnavailable, "signed-observation-refused"))
          Just (Right response) -> pure (Just (ReplyOk, response))
      wrapped =
        Role.authenticatedRoleInterpreterWithVerifiedHandler
          readPolicy
          domain
          bounds
          lifetime
          ( Role.AuthenticatedRoleProviders
              (serverProviders fixture LifecycleAuthorityRuntime)
              (pure (Right (must (Replay.mkReplayAttemptId (BS.replicate 16 7)))))
          )
          LifecycleAuthorityRuntime
          (must (Replay.mkReplayCasAttempts 4))
          limits
          replayRepository
          (Role.contextFreeAuthenticatedRoleHandler Server.failClosedInterpreter)
      routeFor url =
        if "/v1/authority/control" `isSuffixOf` url
          then LifecycleAuthorityControl
          else LifecycleAuthorityPeerObserve
      forged =
        PromotionObservation.EpochPromotionObservation
          2
          (Just 2)
          ( Just
              ( PromotionObservation.PreparedEpochObservation
                  1
                  2
                  Promotion.EpochAdmissionOpen
                  epochTopologyFixtureDigest
                  epochTopologyFixture
              )
          )
      raw =
        must
          ( Client.controlPlaneClientWithTransport
              (65536 + 512)
              (must (Client.mkLifecycleAuthorityEndpoint "http://retained-home:8600"))
              ( \_ _ url bytes -> do
                  result <- Server.interpreterHandle wrapped (routeFor url) bytes
                  case result of
                    Nothing -> pure (Right (500, "missing response"))
                    Just (status, body) -> do
                      previous <- Map.lookup (routeFor url) <$> readIORef saved
                      modifyIORef' saved (Map.insertWith (\_ old -> old) (routeFor url) body)
                      mode <- readIORef substitutions
                      pure $
                        Right $
                          case mode of
                            1
                              | routeFor url == LifecycleAuthorityControl ->
                                  (200, Lazy.toStrict (encodeControlPlaneResponse forged))
                            1 -> (200, "unsigned-peer")
                            2 -> (200, maybe body id previous)
                            3 -> (200, BS.take (BS.length body - 1) body)
                            4
                              | routeFor url == LifecycleAuthorityControl ->
                                  (200, Lazy.toStrict (encodeControlPlaneResponse forged))
                            _ -> (replyStatusCode status, body)
              )
          )
      providers =
        Transport.AuthenticatedClientProviders
          (pure (Right (Authentication.localRequestSigningCapability signer)))
          (pure (Right scope))
          (pure (Right (epochAt 2)))
          (pure (Right requestDeadline))
          ( do
              count <- atomicModifyIORef' nonceCounter (\value -> (value + 1, value + 1))
              pure
                (Right (must (Authentication.mkRequestNonce (BS.replicate 16 1 <> Lazy.toStrict (serialise count)))))
          )
      transport = Transport.mkAuthenticatedClientTransport bounds providers raw
      peer = requestAuthorityPeerContextWithVerifiedResponse scope authorityKey transport
      promotion = AuthorityControl.observeEpochPromotionWithVerifiedResponse transport authorityKey
  unsignedPromotion <- AuthorityControl.observeEpochPromotionWithTransport transport
  PromotionObservation.observedRetainedEpoch (must unsignedPromotion) `shouldBe` 1
  actualPeer <- peer
  peerContextEpoch (must actualPeer) `shouldBe` epochAt 2
  actualPromotion <- promotion
  PromotionObservation.observedRetainedEpoch (must actualPromotion) `shouldBe` 1
  writeIORef substitutions 1
  peer >>= (`shouldSatisfy` isLeft)
  promotion >>= (`shouldSatisfy` isLeft)
  writeIORef substitutions 2
  peer >>= (`shouldSatisfy` isLeft)
  promotion >>= (`shouldSatisfy` isLeft)
  writeIORef substitutions 3
  peer >>= (`shouldSatisfy` isLeft)
  promotion >>= (`shouldSatisfy` isLeft)
  writeIORef substitutions 5
  peer
    `shouldReturn` Left (PeerContextClientResponseAuthenticationFailed SignedResponse.AuthorityResponseBodyTooLarge)
  physicalCalls <- newIORef (0 :: Int)
  submissions <- newIORef (0 :: Int)
  let coordinatorBoundary =
        Coordinator.PromotionBoundary
          { Coordinator.boundaryTime = pure (Right now)
          , Coordinator.boundaryObserve = do
              observedPeer <- peer
              observedPromotion <- promotion
              pure $ do
                currentPeer <- either (Left . show) Right observedPeer
                currentPromotion <- either (Left . show) Right observedPromotion
                if Genesis.authorityEpochValue (peerContextEpoch currentPeer)
                  == fromIntegral (PromotionObservation.observedRetainedEpoch currentPromotion)
                  then Right currentPromotion
                  else Left "peer and aggregate epoch disagree"
          , Coordinator.boundaryPhysical = \_ _ _ -> modifyIORef' physicalCalls (+ 1) >> pure (Right ())
          , Coordinator.boundarySubmit = \_ _ -> modifyIORef' submissions (+ 1) >> pure (Right ())
          }
      coordinatorContext = Coordinator.PromotionContext 1 2 epochTopologyFixture requestDeadline
  writeIORef substitutions 4
  composed <-
    Coordinator.runPromotion coordinatorBoundary coordinatorContext Coordinator.CompletePromotion
  composed `shouldSatisfy` isLeft
  readIORef physicalCalls `shouldReturn` 0
  readIORef submissions `shouldReturn` 0
  readIORef writes `shouldReturn` 0
  let wrongKey = Authentication.trustedRequestKeyFromSigner signer
  requestAuthorityPeerContextWithVerifiedResponse scope wrongKey transport
    >>= (`shouldSatisfy` isLeft)
  let otherAuthority =
        must
          ( Authentication.mkRequestSigner
              (Authentication.CallerService LifecycleAuthorityRuntime)
              (must (Authentication.mkSigningKeyGeneration 1))
              (BS.replicate 32 30)
          )
  writeIORef substitutions 0
  requestAuthorityPeerContextWithVerifiedResponse
    scope
    (Authentication.trustedRequestKeyFromSigner otherAuthority)
    transport
    >>= (`shouldSatisfy` isLeft)
  let vault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
      authorityPrincipal = Authentication.CallerService LifecycleAuthorityRuntime
      origin principal = mkRpcKeyOrigin scope vault (controlPlaneSigningKeyRefFor principal)
      seedKey principal =
        let source =
              must
                ( Authentication.mkRequestSigner
                    principal
                    (must (Authentication.mkSigningKeyGeneration 1))
                    (BS.replicate 32 (fromIntegral (Authentication.callerPrincipalCode principal) + 31))
                )
            public =
              if principal == authorityPrincipal
                then Authentication.requestSignerPublicKeyBytes authoritySigner
                else Authentication.requestSignerPublicKeyBytes source
         in must (mkRpcObservedKey (origin principal) 1 public)
      keys = must (seedLegacyRpcKeyRegistry scope (map seedKey Authentication.allCallerPrincipals))
      clientSpec principal =
        must
          ( mkRegisteredClientSpec
              (clientPrincipalForCaller principal)
              (must (mkRegisteredClientSlot (fromIntegral (Authentication.callerPrincipalCode principal))))
              (must (mkRegisteredClientGeneration 1))
              4
          )
      clients =
        must (mkRegisteredClientTable 16 (map clientSpec (trustedCallersForRoute LifecycleOperationSubmit)))
      base = must (Admission.initialCleanInstallAuthorityWithRegisteredClients 4 8 clients)
      seeded = must (Admission.seedAuthorityRpcKeyRegistry scope keys base)
      snapshot = AuthorityAdmissionSnapshot (11 :: Int) seeded
      sameSnapshot = pure (Right snapshot)
      selectedOrigin = origin authorityPrincipal
      trustedSnapshot = must (selectAuthorityResponseTrust scope selectedOrigin snapshot)
  authorityAdmissionRevision (authorityResponseTrustSnapshot trustedSnapshot) `shouldBe` 11
  checkAuthorityResponseTrust trustedSnapshot snapshot `shouldBe` Right ()
  let changed = AuthorityAdmissionSnapshot 12 seeded
  checkAuthorityResponseTrust trustedSnapshot changed `shouldBe` Left AuthorityResponseSnapshotChanged
  let retired =
        must
          ( Admission.retireAuthorityRpcKey
              authorityPrincipal
              (must (Authentication.mkSigningKeyGeneration 1))
              seeded
          )
      retiredSnapshot = AuthorityAdmissionSnapshot (12 :: Int) retired
  isLeft (selectAuthorityResponseTrust scope (origin Authentication.CallerTestHarness) snapshot)
    `shouldBe` True
  isLeft (selectAuthorityResponseTrust scope selectedOrigin retiredSnapshot) `shouldBe` True
  observedPeer <-
    observeAuthorityPeerFromSnapshot scope selectedOrigin snapshot sameSnapshot transport
  peerContextEpoch (authoritySnapshotObservationValue (must observedPeer)) `shouldBe` epochAt 2
  observedPromotion <-
    observeAuthorityPromotionFromSnapshot scope selectedOrigin snapshot sameSnapshot transport
  PromotionObservation.observedRetainedEpoch
    (authoritySnapshotObservationValue (must observedPromotion))
    `shouldBe` 1
  stale <-
    observeAuthorityPromotionFromSnapshot scope selectedOrigin snapshot (pure (Right changed)) transport
  either (== AuthoritySnapshotTrustRefused AuthorityResponseSnapshotChanged) (const False) stale
    `shouldBe` True
  let unavailable = pure (Left "repository unavailable")
  closingFailure <-
    observeAuthorityPeerFromSnapshot scope selectedOrigin snapshot unavailable transport
  either (== AuthoritySnapshotClosingUnavailable) (const False) closingFailure `shouldBe` True
  beforeRefusal <- readIORef nonceCounter
  invalidOrigin <-
    observeAuthorityPeerFromSnapshot
      scope
      (origin Authentication.CallerTestHarness)
      snapshot
      sameSnapshot
      transport
  isLeft invalidOrigin `shouldBe` True
  readIORef nonceCounter `shouldReturn` beforeRefusal
  let mutation = Lazy.toStrict (encodeControlPlaneRequest AuthorityControlBeginMigration)
  verifiedMutation <- must <$> authenticate fixture LifecycleAuthorityControl 2 mutation
  SignedResponse.signAuthorityAuthenticatedResponse 65536 capability verifiedMutation 200 "unexpected"
    `shouldReturn` Left SignedResponse.AuthorityResponseRequestRefused
  SignedResponse.verifyAuthorityAuthenticatedResponse
    0
    authorityKey
    ( must
        ( Authentication.signControlPlaneRequest
            signer
            LifecycleAuthorityControl
            LifecycleAuthorityRuntime
            scope
            (epochAt 2)
            requestDeadline
            nonce
            "x"
        )
    )
    "x"
    `shouldBe` Left SignedResponse.AuthorityResponseInvalidLimit

rawPeerTransport
  :: IO (Either Text AuthorityTime)
  -> IO (Int, BS.ByteString)
  -> Transport.AuthenticatedClientTransport 'LifecycleAuthorityRuntime
rawPeerTransport deadline reply = Transport.mkAuthenticatedClientTransport bounds providers client
 where
  providers =
    Transport.AuthenticatedClientProviders
      (pure (Right (Authentication.localRequestSigningCapability signer)))
      (pure (Right scope))
      (pure (Left "ordinary epoch must not be read"))
      deadline
      (pure (Right nonce))
  client =
    must
      ( Client.controlPlaneClientWithTransport
          2048
          (must (Client.mkLifecycleAuthorityEndpoint "http://retained-home:8600"))
          (\_ _ _ _ -> Right <$> reply)
      )

capturedFrame :: Boundary -> IO BS.ByteString
capturedFrame boundary = do
  frames <- readIORef (boundaryFrames boundary)
  case frames of
    frame : _ -> pure frame
    [] -> expectationFailure "no frame captured" >> pure BS.empty

must :: (Show err) => Either err value -> value
must = either (error . show) id
scope :: Coordinate.AuthorityScope
scope = must (Coordinate.mkAuthorityScope "retained-home")
issuer :: (TargetIssuerKeyGeneration, TargetIntentPublicKey)
issuer = (must (mkTargetIssuerKeyGeneration 1), publicAt 17)
publicAt :: Int -> TargetIntentPublicKey
publicAt seed =
  targetIntentSigningPublicKey (must (mkTargetIntentSigningKey (BS.replicate 32 (fromIntegral seed))))
signer :: Authentication.RequestSigner
signer =
  must
    ( Authentication.mkRequestSigner
        Authentication.CallerTestHarness
        (must (Authentication.mkSigningKeyGeneration 1))
        (BS.replicate 32 17)
    )
trusted :: Authentication.TrustedRequestKey
trusted = Authentication.trustedRequestKeyFromSigner signer
nonce :: Authentication.RequestNonce
nonce = must (Authentication.mkRequestNonce (BS.replicate 16 11))
epochAt :: Natural -> Genesis.AuthorityEpoch
epochAt = fromJust . Genesis.authorityEpochFromValue
now :: AuthorityTime
now = authorityTimeFromMicros 1000
requestDeadline :: AuthorityTime
requestDeadline = authorityTimeFromMicros 2000
lifetime :: AuthorityDuration
lifetime = must (authorityDurationFromMicros 10000)
bounds :: Transport.AuthenticatedTransportBounds
bounds = must (Transport.mkAuthenticatedTransportBounds 65536 256 65000)
