{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneRpcBirthBootstrap (rpcBirthBootstrapSuite) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), finally, throwIO, try)
import Control.Monad (forM_, when)
import ControlPlaneRpcAdmissionBirth
  ( RpcBirthCallerVaultFault (CallerVaultHealthy)
  , rpcBirthHomeRegistryFixture
  , withRpcBirthCallerVaultFixture
  , withRpcBirthPreparedCoordinatorRegistryWireFixture
  )
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Codec (decodeControlPlaneResponse, encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication (ExternalLifecycleAuthorityCaller (..))
import Prodbox.ControlPlane.RegisteredRpcSigning
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthBootstrap
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Client (VaultToken (..))
import Prodbox.Vault.Session
import TestSupport

rpcBirthBootstrapSuite :: SuiteBuilder ()
rpcBirthBootstrapSuite = describe "Sprint 6.5 private registered RPC bootstrap" $ do
  forM_ [LifecycleAuthorityOperator, LifecycleAuthorityTestHarness] $ \caller ->
    it ("uses the cached native Vault adapter and fixed authenticated reads for " <> show caller) $
      withBootstrapFixture $ \fixture ->
        withRpcBirthCallerVaultFixture caller CallerVaultHealthy $ \address paths -> do
          session <-
            newVaultSession
              address
              (SessionClock (pure 0))
              (pure (Right (LoginLease (VaultToken "fixture-role-token") 60 False)))
          let principal = case caller of
                LifecycleAuthorityOperator -> CallerOperatorCli
                LifecycleAuthorityTestHarness -> CallerTestHarness
              native = vaultNativeRpcSigningInterpreter scope (controlPlaneSigningKeyRefFor principal) session
          result <-
            runBootstrap
              fixture
              native
              (bootstrapMode fixture)
              (bootstrapDeadline fixture)
              (bootstrapWire fixture)
          fmap rpcBirthObservedRegistry result `shouldBe` Right (bootstrapRegistry fixture)
          readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint", "peer", "registry"]
          observed <- readIORef paths
          length (filter (Text.isPrefixOf "/v1/transit/sign/" . Text.pack) observed) `shouldBe` 2
          length (filter (== "/v1/auth/kubernetes/login") observed) `shouldBe` 0

  it "authenticates native version one under the remote origin's logical generation two" $
    withBootstrapFixtureFor [remoteKey] $ \fixture -> do
      native <- fixtureNativeFor fixture remoteOrigin remoteSigner NativeHealthy
      versions <- newIORef []
      let record :: NativeRpcSigningProgram value -> IO (Either RegisteredRpcSigningError value)
          record program = do
            case program of
              SignRpcNative version _ -> modifyIORef' versions (<> [version])
              _ -> pure ()
            runNativeRpcSigningProgram native program
          recorded = NativeRpcSigningInterpreter record
          binding = must (selectActiveRpcKeyForOrigin remoteOrigin (bootstrapRegistry fixture))
      signingKeyGenerationValue (rpcKeyBindingGeneration binding) `shouldBe` 2
      result <-
        runBootstrap
          fixture
          recorded
          (bootstrapMode fixture)
          (bootstrapDeadline fixture)
          (bootstrapWire fixture)
      fmap rpcBirthObservedRegistry result `shouldBe` Right (bootstrapRegistry fixture)
      readIORef versions `shouldReturn` [1, 1]
      readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint", "peer", "registry"]

  it "cannot use a native-matching forged logical generation to pass peer authentication" $
    withBootstrapFixtureFor [remoteKey] $ \fixture -> do
      native <- fixtureNativeFor fixture remoteOrigin remoteSigner NativeHealthy
      let extra = must (mkRpcObservedKey fixtureOrigin 2 (requestSignerPublicKeyBytes extraSigner))
          extraSigner = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.replicate 32 203))
          withExtra = snd (must (registerRpcKey extra rpcBirthHomeRegistryFixture))
          forged = snd (must (registerRpcKey remoteKey withExtra))
          wire config method url bytes = do
            response <- bootstrapWire fixture config method url bytes
            if isRpcOwnBindingQuery bytes
              then do
                let query = must (decodeRpcOwnBindingQuery scope bytes)
                    hint = must (selectRpcOwnBindingHint query forged)
                signingKeyGenerationValue (rpcOwnBindingHintGeneration hint) `shouldBe` 3
                pure (Right (200, encodeRpcOwnBindingHint hint))
              else pure response
      result <- runBootstrap fixture native (bootstrapMode fixture) (bootstrapDeadline fixture) wire
      result `shouldSatisfy` isLeft
      readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint", "peer"]

  it "refuses legacy mode before any native or transport effects" $
    withBootstrapFixture $ \fixture -> do
      touched <- newIORef False
      let native = NativeRpcSigningInterpreter $ \_ -> writeIORef touched True >> pure (Left RpcSigningOriginUnavailable)
      runBootstrap
        fixture
        native
        legacyRpcBirthServingMode
        (bootstrapDeadline fixture)
        (bootstrapWire fixture)
        `shouldReturn` Left RpcBirthBootstrapRegisteredModeRequired
      readIORef touched `shouldReturn` False
      readIORef (bootstrapRoutes fixture) `shouldReturn` []

  it "refuses an expired original deadline before any native or transport effects" $
    withBootstrapFixture $ \fixture -> do
      touched <- newIORef False
      let native = NativeRpcSigningInterpreter $ \_ -> writeIORef touched True >> pure (Left RpcSigningOriginUnavailable)
      runBootstrap
        fixture
        native
        (bootstrapMode fixture)
        (authorityTimeFromMicros 1)
        (bootstrapWire fixture)
        `shouldReturn` Left RpcBirthBootstrapDeadlineReached
      readIORef touched `shouldReturn` False
      readIORef (bootstrapRoutes fixture) `shouldReturn` []

  forM_ [WrongPublic, WrongPublicVersion, WrongSignVersion, OriginChangesAfterSign] $ \fault ->
    it ("refuses native mismatch before sending a signed request: " <> show fault) $
      withBootstrapFixture $ \fixture -> do
        native <- fixtureNative fixture fault
        result <-
          runBootstrap
            fixture
            native
            (bootstrapMode fixture)
            (bootstrapDeadline fixture)
            (bootstrapWire fixture)
        result `shouldSatisfy` isLeft
        readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint"]

  it "refuses an independently captured pin that disagrees with the authenticated observation" $
    withBootstrapFixture $ \fixture -> do
      native <- fixtureNative fixture NativeHealthy
      let wrong = must (registeredRpcBirthServingMode scope 2 (Text.replicate 64 "b"))
      runBootstrap fixture native wrong (bootstrapDeadline fixture) (bootstrapWire fixture)
        `shouldReturn` Left RpcBirthBootstrapPinMismatch
      readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint", "peer", "registry"]

  forM_ [400, 503] $ \status ->
    it ("does not sign after refused discovery HTTP " <> show status) $
      withBootstrapFixture $ \fixture -> do
        native <- fixtureNative fixture NativeHealthy
        let wire config method url bytes
              | isRpcOwnBindingQuery bytes = pure (Right (status, "unavailable"))
              | otherwise = bootstrapWire fixture config method url bytes
        runBootstrap fixture native (bootstrapMode fixture) (bootstrapDeadline fixture) wire
          `shouldReturn` Left (RpcBirthBootstrapHintHttpStatus status)
        readIORef (bootstrapRoutes fixture) `shouldReturn` []

  it "does not sign after a noncanonical hint" $
    withBootstrapFixture $ \fixture -> do
      native <- fixtureNative fixture NativeHealthy
      let wire config method url bytes = do
            result <- bootstrapWire fixture config method url bytes
            pure $
              if isRpcOwnBindingQuery bytes
                then fmap (\(status, body) -> (status, body <> "trailing")) result
                else result
      runBootstrap fixture native (bootstrapMode fixture) (bootstrapDeadline fixture) wire
        `shouldReturn` Left (RpcBirthBootstrapHint RpcOwnBindingWireInvalid)
      readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint"]

  forM_ [RetiredDuringRead, RotatedDuringRead] $ \change ->
    it ("checks the hint against the complete current registry: " <> show change) $
      withBootstrapFixture $ \fixture -> do
        native <- fixtureNative fixture NativeHealthy
        let wire config method url bytes = do
              response <- bootstrapWire fixture config method url bytes
              if "/migration/apply" `Text.isSuffixOf` Text.pack url && not (isRpcOwnBindingQuery bytes)
                then pure (fmap (rewriteRegistry fixture change) response)
                else pure response
        result <- runBootstrap fixture native (bootstrapMode fixture) (bootstrapDeadline fixture) wire
        let cause = case change of
              RetiredDuringRead -> RpcOwnBindingRegistryRefused RpcKeyBindingMissing
              RotatedDuringRead -> RpcOwnBindingChanged
        result `shouldBe` Left (RpcBirthBootstrapHint cause)
        readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint", "peer", "registry"]

  forM_ [CutOrigin, CutPublic, CutSign, CutHint, CutPeer, CutRegistry] $ \cut ->
    it ("preserves asynchronous cancellation at " <> show cut) $
      withBootstrapFixture $ \fixture -> do
        native <- fixtureNative fixture NativeHealthy
        let interrupted = NativeRpcSigningInterpreter $ \program -> do
              when (matchesNative cut program) (throwIO ThreadKilled)
              runNativeRpcSigningProgram native program
            wire config method url bytes = do
              when (matchesWire cut url bytes) (throwIO ThreadKilled)
              bootstrapWire fixture config method url bytes
        result <-
          try (runBootstrap fixture interrupted (bootstrapMode fixture) (bootstrapDeadline fixture) wire)
        (result :: Either AsyncException (Either RpcBirthBootstrapError RpcBirthRegistryObservation))
          `shouldBe` Left ThreadKilled

  it "bounds and joins a blocked native signature with the original deadline" $
    withBootstrapFixture $ \fixture -> do
      native <- fixtureNative fixture NativeHealthy
      finished <- newIORef False
      now <- rpcBirthSystemTime
      let deadline = authorityTimeFromMicros (authorityTimeMicros now + 100000)
          block :: NativeRpcSigningProgram value -> IO (Either RegisteredRpcSigningError value)
          block program = case program of
            SignRpcNative _ _ ->
              (threadDelay 1000000 >> runNativeRpcSigningProgram native program)
                `finally` writeIORef finished True
            _ -> runNativeRpcSigningProgram native program
          blocked = NativeRpcSigningInterpreter block
      result <- runBootstrap fixture blocked (bootstrapMode fixture) deadline (bootstrapWire fixture)
      result `shouldSatisfy` isLeft
      readIORef finished `shouldReturn` True
      readIORef (bootstrapRoutes fixture) `shouldReturn` ["hint"]

data BootstrapFixture = BootstrapFixture
  { bootstrapMode :: !RpcBirthServingMode
  , bootstrapDeadline :: !AuthorityTime
  , bootstrapRegistry :: !RpcKeyRegistry
  , bootstrapBounds :: !Transport.AuthenticatedTransportBounds
  , bootstrapProviders :: !(Transport.AuthenticatedClientProviders IO)
  , bootstrapWire :: !Client.ControlPlaneTransport
  , bootstrapRoutes :: !(IORef [Text])
  }

withBootstrapFixture :: (BootstrapFixture -> IO value) -> IO value
withBootstrapFixture = withBootstrapFixtureFor []

withBootstrapFixtureFor :: [RpcObservedKey] -> (BootstrapFixture -> IO value) -> IO value
withBootstrapFixtureFor keys action = do
  now <- rpcBirthSystemTime
  let deadline = authorityTimeFromMicros (authorityTimeMicros now + 5000000)
  withRpcBirthPreparedCoordinatorRegistryWireFixture keys deadline (pure Nothing) $ \config observer bounds providers inner _ -> do
    registry <- must <$> observeRpcKeyRegistry observer
    routes <- newIORef []
    let mode = must (validateRpcBirthConfig LifecycleAuthorityRuntime scope config)
        wire http method url bytes = do
          let route
                | isRpcOwnBindingQuery bytes = "hint"
                | "/peer/observe" `Text.isSuffixOf` Text.pack url = "peer"
                | otherwise = "registry"
          modifyIORef' routes (<> [route])
          case route of
            "hint" -> do
              url `shouldBe` "http://home.test/v1/migration/apply"
              let query = must (decodeRpcOwnBindingQuery scope bytes)
              pure (Right (200, encodeRpcOwnBindingHint (must (selectRpcOwnBindingHint query registry))))
            _ -> inner http method url bytes
    action (BootstrapFixture mode deadline registry bounds providers wire routes)

runBootstrap
  :: BootstrapFixture
  -> NativeRpcSigningInterpreter IO
  -> RpcBirthServingMode
  -> AuthorityTime
  -> Client.ControlPlaneTransport
  -> IO (Either RpcBirthBootstrapError RpcBirthRegistryObservation)
runBootstrap fixture native mode deadline wire =
  observeRpcBirthBootstrapRegistry
    native
    (Right <$> rpcBirthSystemTime)
    (Transport.provideAuthenticatedClientNonce (bootstrapProviders fixture))
    scope
    mode
    deadline
    (bootstrapBounds fixture)
    ( must
        ( Client.controlPlaneClientWithTransport
            rpcBirthRegistryResponseMaximumBytes
            (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
            wire
        )
    )

data NativeFault
  = NativeHealthy
  | WrongPublic
  | WrongPublicVersion
  | WrongSignVersion
  | OriginChangesAfterSign
  deriving (Eq, Show)

fixtureNative :: BootstrapFixture -> NativeFault -> IO (NativeRpcSigningInterpreter IO)
fixtureNative fixture = fixtureNativeFor fixture fixtureOrigin fixtureSigner

fixtureNativeFor
  :: BootstrapFixture
  -> RpcKeyOrigin
  -> RequestSigner
  -> NativeFault
  -> IO (NativeRpcSigningInterpreter IO)
fixtureNativeFor fixture origin signing fault = do
  signed <- newIORef False
  let binding = must (selectActiveRpcKeyForOrigin origin (bootstrapRegistry fixture))
      observed = rpcKeyBindingObserved binding
      interpreter :: NativeRpcSigningProgram value -> IO (Either RegisteredRpcSigningError value)
      interpreter program = case program of
        ReadRpcNativeOrigin -> do
          afterSign <- readIORef signed
          pure (Right (if fault == OriginChangesAfterSign && afterSign then changedOrigin else origin))
        ReadRpcNativePublic version ->
          pure
            ( Right
                ( if fault == WrongPublicVersion then version + 1 else version
                , if fault == WrongPublic then BS.replicate 32 200 else rpcObservedPublicKey observed
                )
            )
        SignRpcNative version bytes -> do
          writeIORef signed True
          signature <-
            signCanonicalBytesWithRequestCapability (localRequestSigningCapability signing) bytes
          pure
            ( fmap
                (if fault == WrongSignVersion then version + 1 else version,)
                (first (const RpcSigningSignatureUnavailable) signature)
            )
  pure (NativeRpcSigningInterpreter interpreter)
 where
  changedOrigin =
    mkRpcKeyOrigin
      scope
      (must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222"))
      (controlPlaneSigningKeyRefFor CallerOperatorCli)

data RegistryChange = RetiredDuringRead | RotatedDuringRead
  deriving (Eq, Show)

-- The response remains canonical and preserves the descriptor's original home
-- seed. Only the post-authentication registry observation changes, modelling
-- retirement or registration between discovery and the complete read.
data RegistryObservationWire = RegistryObservationWire !Word !BS.ByteString !BS.ByteString
  deriving (Generic, Serialise)

rewriteRegistry
  :: BootstrapFixture -> RegistryChange -> (Int, BS.ByteString) -> (Int, BS.ByteString)
rewriteRegistry fixture change (status, body) =
  let encoded =
        must (decodeControlPlaneResponse rpcBirthRegistryResponseMaximumBytes (Lazy.fromStrict body))
          :: Either RpcBirthError BS.ByteString
      prefix = "prodbox-rpc-birth-registry-response/v1\NUL"
      original = maybe (error "fixture registry prefix") id (BS.stripPrefix prefix (must encoded))
      RegistryObservationWire version descriptor _ = must (deserialiseOrFail (Lazy.fromStrict original))
      registry = bootstrapRegistry fixture
      changed = case change of
        RetiredDuringRead -> must (retireRpcKey CallerOperatorCli (must (mkSigningKeyGeneration 1)) registry)
        RotatedDuringRead ->
          snd
            ( must
                ( registerRpcKey
                    (must (mkRpcObservedKey fixtureOrigin 2 (requestSignerPublicKeyBytes nextSigner)))
                    registry
                )
            )
      nextSigner = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 2)) (BS.replicate 32 201))
      rewritten =
        prefix
          <> Lazy.toStrict
            (serialise (RegistryObservationWire version descriptor (must (encodeRpcKeyRegistry changed))))
      canonical = must (decodeRpcBirthRegistryObservation scope rewritten)
   in ( status
      , Lazy.toStrict
          ( encodeControlPlaneResponse
              (Right (must (encodeRpcBirthRegistryObservation canonical)) :: Either RpcBirthError BS.ByteString)
          )
      )

data BootstrapCut = CutOrigin | CutPublic | CutSign | CutHint | CutPeer | CutRegistry
  deriving (Eq, Show)

matchesNative :: BootstrapCut -> NativeRpcSigningProgram value -> Bool
matchesNative cut program = case program of
  ReadRpcNativeOrigin -> cut == CutOrigin
  ReadRpcNativePublic _ -> cut == CutPublic
  SignRpcNative _ _ -> cut == CutSign

matchesWire :: BootstrapCut -> String -> BS.ByteString -> Bool
matchesWire cut url bytes = case cut of
  CutHint -> isRpcOwnBindingQuery bytes
  CutPeer -> "/peer/observe" `Text.isSuffixOf` Text.pack url
  CutRegistry -> "/migration/apply" `Text.isSuffixOf` Text.pack url && not (isRpcOwnBindingQuery bytes)
  CutOrigin -> False
  CutPublic -> False
  CutSign -> False

scope :: Coordinate.AuthorityScope
scope = must (Coordinate.mkAuthorityScope "home")

fixtureOrigin :: RpcKeyOrigin
fixtureOrigin =
  mkRpcKeyOrigin
    scope
    (must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111"))
    (controlPlaneSigningKeyRefFor CallerOperatorCli)

fixtureSigner :: RequestSigner
fixtureSigner =
  must
    ( mkRequestSigner
        CallerOperatorCli
        (must (mkSigningKeyGeneration 1))
        (BS.replicate 32 (fromIntegral (callerPrincipalCode CallerOperatorCli + 31)))
    )

remoteOrigin :: RpcKeyOrigin
remoteOrigin =
  mkRpcKeyOrigin
    (must (Coordinate.mkAuthorityScope "remote"))
    (must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222"))
    (controlPlaneSigningKeyRefFor CallerOperatorCli)

remoteSigner :: RequestSigner
remoteSigner = must (mkRequestSigner CallerOperatorCli (must (mkSigningKeyGeneration 1)) (BS.replicate 32 202))

remoteKey :: RpcObservedKey
remoteKey = must (mkRpcObservedKey remoteOrigin 1 (requestSignerPublicKeyBytes remoteSigner))

must :: (Show errorValue) => Either errorValue value -> value
must = either (error . show) id
