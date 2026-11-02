{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRegisteredRpcSigning (registeredRpcSigningSuite) where

import Control.Concurrent.Async (link, withAsync)
import Control.Exception (AsyncException (ThreadKilled), bracket, throwIO, try)
import Control.Monad (forever, void)
import Data.Aeson (Value (Number, Object, String), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (toLower)
import Data.IORef
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.AuthorityPeerContext
import Prodbox.ControlPlane.AuthorityPeerContextClient
import Prodbox.ControlPlane.AuthorityPeerContextEndpoint
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RegisteredRpcSigning
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
  ( ControlPlaneMethod (ControlPlaneGet, ControlPlanePost)
  , ControlPlaneRoute (LifecycleAuthorityPeerObserve)
  )
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( mkTargetIntentPublicKey
  , mkTargetIssuerKeyGeneration
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyOk), replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime))
import Prodbox.Vault.Client
import Prodbox.Vault.Session
import TestSupport

registeredRpcSigningSuite :: SuiteBuilder ()
registeredRpcSigningSuite = describe "Sprint 6.5 registered native RPC signing" $ do
  it "signs native version one under logical generation two through the actual Vault HTTP adapter" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      signingKeyGenerationValue (requestSigningCapabilityGeneration signer) `shouldBe` 2
      signature <- signCanonicalBytesWithRequestCapability signer "canonical-claims"
      expected <- pureNativeSignature "canonical-claims"
      signature `shouldBe` expected
      readIORef (signatureVersions fixture) `shouldReturn` [1]
      readIORef (nativeRequests fixture) >>= (`shouldSatisfy` any (BS.isInfixOf "GET /v1/sys/health"))

  it "reads the registered old native public key even when the latest native version is two" $
    withFixture $ \fixture -> do
      info <-
        vaultReadTransitSigningKeyVersion
          (nativeAddress fixture)
          (VaultToken "fixture-role-token")
          keyName
          1
      transitSigningKeyVersion (must info) `shouldBe` 1
      transitSigningPublicKey (must info) `shouldBe` nativePublic 18
      latest <-
        vaultReadTransitSigningKey (nativeAddress fixture) (VaultToken "fixture-role-token") keyName
      transitSigningKeyVersion (must latest) `shouldBe` 2
      transitSigningPublicKey (must latest) `shouldBe` nativePublic 19

  it "carries native one/logical two through signed client, server verifier and peer metadata handler" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      let bounds = must (Transport.mkAuthenticatedTransportBounds 65536 256 65000)
          now = authorityTimeFromMicros 1000
          deadline = authorityTimeFromMicros 2000000
          epoch = maybe (error "fixture epoch") id (Genesis.authorityEpochFromValue 2)
          registry = must (registeredRpcRouteTrust LifecycleAuthorityRuntime 16 registered)
          server =
            Transport.AuthenticatedServerProviders
              (pure (Right rootScope))
              (pure (Right epoch))
              (pure (Right now))
              (pure (Right registry))
          lifetime = must (authorityDurationFromMicros 3000000)
          readPeer :: AuthorityPeerContextProgram result -> IO (Either AuthorityPeerContextError result)
          readPeer program = pure $ case program of
            ReadPeerContextTime -> Right now
            ReadPeerContextEpoch _ -> Right epoch
            ReadPeerContextIssuer _ -> Right (must (mkTargetIssuerKeyGeneration 1), must (mkTargetIntentPublicKey (nativePublic 17)))
          transport _ _ url frame = do
            url `shouldBe` "http://home.test/v1/authority/peer/observe"
            verified <-
              Transport.authenticateControlPlaneFrame
                bounds
                lifetime
                server
                LifecycleAuthorityRuntime
                LifecycleAuthorityPeerObserve
                (Lazy.fromStrict frame)
            let request = Transport.authenticatedServerVerifiedRequest (must verified)
            signingKeyGenerationValue (verifiedRequestSigningKeyGeneration request) `shouldBe` 2
            verifiedRequestAuthorityEpoch request `shouldBe` Genesis.authorityEpochGenesis
            verifiedRequestAuthorityScope request `shouldBe` rootScope
            result <-
              authorityPeerContextVerifiedHandler rootScope (AuthorityPeerContextInterpreter readPeer) request
            pure $ case result of
              Just (status, body) -> Right (replyStatusCode status, body)
              Nothing -> error "fixture peer handler did not match"
          providers =
            Transport.AuthenticatedClientProviders
              (pure (Right signer))
              (pure (Right rootScope))
              (pure (Left "peer refresh must not call ordinary epoch provider"))
              (pure (Right deadline))
              (pure (Right (must (mkRequestNonce (BS.replicate 16 1)))))
          client =
            must
              ( Client.controlPlaneClientWithTransport
                  1024
                  (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                  transport
              )
      response <-
        requestAuthorityPeerContextWithin
          (pure (Right now))
          deadline
          rootScope
          (Transport.mkAuthenticatedClientTransport bounds providers client)
      peerContextEpoch (must response) `shouldBe` epoch
      readIORef (signatureVersions fixture) `shouldReturn` [1]

  it "does not send a zero native version to either Vault operation" $
    withFixture $ \fixture -> do
      public <-
        vaultReadTransitSigningKeyVersion
          (nativeAddress fixture)
          (VaultToken "fixture-role-token")
          keyName
          0
      public `shouldSatisfy` either (const True) (const False)
      signature <-
        vaultTransitSignEd25519AtVersion
          (nativeAddress fixture)
          (VaultToken "fixture-role-token")
          keyName
          0
          "payload"
      signature `shouldSatisfy` either (const True) (const False)
      readIORef (nativeRequests fixture) `shouldReturn` []

  it "refuses a forged caller/key reference before any native HTTP request" $
    withFixture $ \fixture -> do
      let forged = ref {controlPlaneSigningKeyPrincipal = CallerOperatorCli}
          interpreter =
            vaultRegisteredRpcSigningInterpreter
              rootScope
              localScope
              forged
              (nativeSession fixture)
              (RpcKeyRegistryObserver (pure (Right registered)))
      result <- resolveRegisteredRpcSigningCapability interpreter remoteBinding
      void result `shouldBe` Left RpcSigningOriginMismatch
      readIORef (nativeRequests fixture) `shouldReturn` []

  forMNativeFault
    [ (WrongIncarnation, RpcSigningOriginMismatch)
    , (UninitializedVault, RpcSigningOriginUnavailable)
    , (SealedVault, RpcSigningOriginUnavailable)
    , (WrongPublicKey, RpcSigningPublicMismatch)
    , (MissingNativeVersion, RpcSigningPublicUnavailable)
    , (WrongKeyType, RpcSigningPublicUnavailable)
    , (OversizedPublicResponse, RpcSigningPublicUnavailable)
    ]
    $ \fault expected -> it ("refuses native metadata fault " ++ show fault ++ " before signing") $
      withFixture $ \fixture -> do
        writeIORef (nativeFault fixture) fault
        result <- resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
        void result `shouldBe` Left expected
        readIORef (signatureVersions fixture) `shouldReturn` []

  it "refuses a retained registry observation failure before signing" $
    withFixture $ \fixture -> do
      writeIORef (registryState fixture) (Left RpcKeyRegistryWireInvalid)
      result <- resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      void result `shouldBe` Left (RpcSigningRegistryUnavailable RpcKeyRegistryWireInvalid)

  it "checks registry authority scope independently of local Vault scope" $
    withFixture $ \fixture -> do
      let other = must (Coordinate.mkAuthorityScope "other-root")
      writeIORef (registryState fixture) (Right (seedAt other))
      result <- resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      void result `shouldBe` Left RpcSigningRegistryScopeMismatch

  it "rechecks retirement before every signature" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      retireFixture fixture
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/binding-refused")
      readIORef (signatureVersions fixture) `shouldReturn` []

  it "does not emit a signature after retirement during the native sign call" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      writeIORef (signHook fixture) (retireFixture fixture)
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/binding-refused")
      readIORef (signatureVersions fixture) `shouldReturn` [1]

  it "does not emit a signature after its Vault incarnation changes" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      writeIORef (signHook fixture) (writeIORef (nativeFault fixture) WrongIncarnation)
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/origin-mismatch")

  it "checks the returned native version against one rather than logical generation two" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      writeIORef (nativeFault fixture) WrongSignatureVersion
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/native-version-mismatch")

  it "lets the common capability verifier reject an invalid native signature" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      writeIORef (nativeFault fixture) InvalidSignature
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left RequestSigningCapabilityAuthenticationFailed

  it "refuses an oversized valid signature response before emitting its bytes" $
    withFixture $ \fixture -> do
      signer <- must <$> resolveRegisteredRpcSigningCapability (nativeInterpreter fixture) remoteBinding
      writeIORef (nativeFault fixture) OversizedSignatureResponse
      signCanonicalBytesWithRequestCapability signer "claims"
        `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/signature-unavailable")

  it "preserves cancellation from the retained registration observer" $
    withFixture $ \fixture -> do
      let cancelled =
            vaultRegisteredRpcSigningInterpreter
              rootScope
              localScope
              ref
              (nativeSession fixture)
              (RpcKeyRegistryObserver (throwIO ThreadKilled))
      result <- try (void (resolveRegisteredRpcSigningCapability cancelled remoteBinding))
      (result :: Either AsyncException ()) `shouldBe` Left ThreadKilled

  mapM_
    ( \selected -> do
        it ("selects exact registered origin for explicit caller " ++ show selected) $
          withFixtureFor selected $ \fixture -> do
            signer <-
              must
                <$> resolveActiveRegisteredRpcSigningCapability (nativeInterpreter fixture) (registeredFor selected)
            requestSigningCapabilityPrincipal signer `shouldBe` selected
            signingKeyGenerationValue (requestSigningCapabilityGeneration signer) `shouldBe` 2
            expected <- pureNativeSignature "caller-claims"
            signCanonicalBytesWithRequestCapability signer "caller-claims" `shouldReturn` expected
            readIORef (signatureVersions fixture) `shouldReturn` [1]
        it ("does not default to another caller/origin for " ++ show selected) $
          withFixtureFor selected $ \fixture -> do
            result <- resolveActiveRegisteredRpcSigningCapability (nativeInterpreter fixture) registered
            void result `shouldBe` Left (RpcSigningBindingRefused RpcKeyBindingMissing)
            readIORef (signatureVersions fixture) `shouldReturn` []
        it ("refuses stale selection metadata after retirement for " ++ show selected) $
          withFixtureFor selected $ \fixture -> do
            let retired =
                  must
                    ( retireRpcKey
                        selected
                        (rpcKeyBindingGeneration (fst (registrationFor selected)))
                        (registeredFor selected)
                    )
            writeIORef (registryState fixture) (Right retired)
            result <-
              resolveActiveRegisteredRpcSigningCapability (nativeInterpreter fixture) (registeredFor selected)
            void result `shouldBe` Left (RpcSigningBindingRefused RpcKeyAlreadyRetired)
            readIORef (signatureVersions fixture) `shouldReturn` []
        it ("rechecks live registration at signing for " ++ show selected) $
          withFixtureFor selected $ \fixture -> do
            signer <-
              must
                <$> resolveActiveRegisteredRpcSigningCapability (nativeInterpreter fixture) (registeredFor selected)
            let retired =
                  must
                    ( retireRpcKey
                        selected
                        (rpcKeyBindingGeneration (fst (registrationFor selected)))
                        (registeredFor selected)
                    )
            writeIORef (signHook fixture) (writeIORef (registryState fixture) (Right retired))
            signCanonicalBytesWithRequestCapability signer "caller-claims"
              `shouldReturn` Left (RequestSigningCapabilityUnavailable "registered-rpc-signing/binding-refused")
            readIORef (signatureVersions fixture) `shouldReturn` [1]
    )
    [CallerOperatorCli, CallerTestHarness]

data NativeFault
  = NativeHealthy
  | WrongIncarnation
  | UninitializedVault
  | SealedVault
  | WrongPublicKey
  | MissingNativeVersion
  | WrongKeyType
  | WrongSignatureVersion
  | InvalidSignature
  | OversizedPublicResponse
  | OversizedSignatureResponse
  deriving (Eq, Show)

forMNativeFault
  :: [(NativeFault, RegisteredRpcSigningError)]
  -> (NativeFault -> RegisteredRpcSigningError -> SuiteBuilder ())
  -> SuiteBuilder ()
forMNativeFault values action = mapM_ (uncurry action) values

data Fixture = Fixture
  { nativeFault :: IORef NativeFault
  , registryState :: IORef (Either RpcKeyRegistryError RpcKeyRegistry)
  , signHook :: IORef (IO ())
  , nativeRequests :: IORef [BS.ByteString]
  , signatureVersions :: IORef [Integer]
  , nativeAddress :: VaultAddress
  , nativeSession :: VaultSession
  , nativeInterpreter :: RegisteredRpcSigningInterpreter IO
  }

withFixture :: (Fixture -> IO value) -> IO value
withFixture = withFixtureFor principal

withFixtureFor :: CallerPrincipal -> (Fixture -> IO value) -> IO value
withFixtureFor selected action = do
  fault <- newIORef NativeHealthy
  registry <- newIORef (Right (registeredFor selected))
  hook <- newIORef (pure ())
  requests <- newIORef []
  versions <- newIORef []
  withHttpFixture (reply (controlPlaneSigningKeyRefFor selected) fault hook requests versions) $ \address -> do
    session <-
      newVaultSession
        address
        (SessionClock (pure 0))
        (pure (Right (LoginLease (VaultToken "fixture-role-token") 60 False)))
    let interpreter =
          vaultRegisteredRpcSigningInterpreter
            rootScope
            localScope
            (controlPlaneSigningKeyRefFor selected)
            session
            (RpcKeyRegistryObserver (readIORef registry))
    action (Fixture fault registry hook requests versions address session interpreter)

retireFixture :: Fixture -> IO ()
retireFixture fixture =
  writeIORef
    (registryState fixture)
    (Right (must (retireRpcKey principal (rpcKeyBindingGeneration remoteBinding) registered)))

reply
  :: ControlPlaneSigningKeyRef
  -> IORef NativeFault
  -> IORef (IO ())
  -> IORef [BS.ByteString]
  -> IORef [Integer]
  -> BS.ByteString
  -> Server.ParsedControlPlaneRequest
  -> IO BS.ByteString
reply selectedRef faultRef hook requests versions raw request = do
  modifyIORef' requests (<> [raw])
  BS8.map toLower raw `shouldSatisfy` BS.isInfixOf "x-vault-token: fixture-role-token"
  fault <- readIORef faultRef
  case Server.parsedRequestPath request of
    "/v1/sys/health" -> do
      Server.parsedRequestMethod request `shouldBe` Just ControlPlaneGet
      pure $
        json
          [ "initialized" .= (fault /= UninitializedVault)
          , "sealed" .= (fault == SealedVault)
          , "cluster_id"
              .= if fault == WrongIncarnation
                then "33333333-3333-3333-3333-333333333333"
                else rpcVaultIncarnationText localVault
          ]
    path | path == "/v1/transit/keys/" ++ Text.unpack (controlPlaneSigningKeyName selectedRef) -> do
      Server.parsedRequestMethod request `shouldBe` Just ControlPlaneGet
      let firstPublic = nativePublic (if fault == WrongPublicKey then 20 else 18)
          keys =
            if fault == MissingNativeVersion
              then object ["2" .= keyVersion (nativePublic 19)]
              else object ["1" .= keyVersion firstPublic, "2" .= keyVersion (nativePublic 19)]
      pure
        ( json $
            [ "data"
                .= object
                  [ "type" .= (if fault == WrongKeyType then ("rsa-2048" :: Text.Text) else "ed25519")
                  , "latest_version" .= (2 :: Int)
                  , "keys" .= keys
                  ]
            ]
              <> padding (fault == OversizedPublicResponse)
        )
    path | path == "/v1/transit/sign/" ++ Text.unpack (controlPlaneSigningKeyName selectedRef) -> do
      Server.parsedRequestMethod request `shouldBe` Just ControlPlanePost
      value <- either (fail . show) pure (eitherDecodeStrict' (Server.parsedRequestBody request))
      case value of
        Object fields -> do
          KeyMap.lookup "key_version" fields `shouldBe` Just (Number 1)
          input <- case KeyMap.lookup "input" fields of
            Just (String encoded) -> either fail pure (B64.decode (TextEncoding.encodeUtf8 encoded))
            _ -> fail "missing sign input"
          modifyIORef' versions (<> [1])
          signature <-
            if fault == InvalidSignature then pure (BS.replicate 64 0) else must <$> pureNativeSignature input
          action <- readIORef hook
          action
          let version = if fault == WrongSignatureVersion then "2" else "1"
          pure
            ( json $
                [ "data"
                    .= object
                      ["signature" .= ("vault:v" <> version <> ":" <> TextEncoding.decodeUtf8 (B64.encode signature))]
                ]
                  <> padding (fault == OversizedSignatureResponse)
            )
        _ -> fail "invalid sign request"
    _ -> fail "unexpected native Vault path"
 where
  json = Lazy.toStrict . encode . object
  keyVersion public = object ["public_key" .= TextEncoding.decodeUtf8 (B64.encode public)]
  padding enabled = ["padding" .= Text.replicate 131072 "x" | enabled]

withHttpFixture
  :: (BS.ByteString -> Server.ParsedControlPlaneRequest -> IO BS.ByteString)
  -> (VaultAddress -> IO value)
  -> IO value
withHttpFixture handler action = withSocketsDo $ bracket open close $ \listener -> do
  address <- getSocketName listener
  case address of
    SockAddrInet port _ -> withAsync (forever (serve listener)) $ \worker -> do
      link worker
      action (VaultAddress ("http://127.0.0.1:" <> Text.pack (show port)))
    _ -> fail "fixture listener is not IPv4"
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 8
    pure listener
  serve listener = bracket (accept listener) (close . fst) $ \(connection, _) -> do
    raw <- receive connection BS.empty
    request <- maybe (fail "invalid HTTP fixture framing") pure (Server.parseControlPlaneRequest raw)
    body <- handler raw request
    sendAll connection (Server.renderHttpResponse ReplyOk body)
  receive connection accumulated = case Server.inspectControlPlaneRequestFraming accumulated of
    Left err -> fail (show err)
    Right (Server.ControlPlaneFramingComplete raw) -> pure raw
    Right Server.ControlPlaneFramingIncomplete -> do
      chunk <- recv connection 4096
      if BS.null chunk then fail "fixture HTTP EOF" else receive connection (accumulated <> chunk)

must :: (Show error) => Either error value -> value
must = either (error . show) id
rootScope, localScope :: Coordinate.AuthorityScope
rootScope = must (Coordinate.mkAuthorityScope "home")
localScope = must (Coordinate.mkAuthorityScope "aws")
homeVault, localVault :: RpcVaultIncarnation
homeVault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
localVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
principal :: CallerPrincipal
principal = CallerService TargetSecretAgentRuntime
ref :: ControlPlaneSigningKeyRef
ref = controlPlaneSigningKeyRefFor principal
keyName :: Text.Text
keyName = controlPlaneSigningKeyName ref
nativePublic :: Int -> BS.ByteString
nativePublic seed = requestSignerPublicKeyBytes (nativeSigner seed)
nativeSigner :: Int -> RequestSigner
nativeSigner seed =
  must
    (mkRequestSigner principal (must (mkSigningKeyGeneration 1)) (BS.replicate 32 (fromIntegral seed)))
pureNativeSignature :: BS.ByteString -> IO (Either RequestSigningCapabilityError BS.ByteString)
pureNativeSignature = signCanonicalBytesWithRequestCapability (localRequestSigningCapability (nativeSigner 18))
seedAt :: Coordinate.AuthorityScope -> RpcKeyRegistry
seedAt scope =
  must
    ( seedLegacyRpcKeyRegistry
        scope
        [ must
            ( mkRpcObservedKey
                (mkRpcKeyOrigin scope homeVault (controlPlaneSigningKeyRefFor caller))
                1
                (nativePublic (if caller == principal then 17 else fromIntegral (callerPrincipalCode caller) + 31))
            )
        | caller <- allCallerPrincipals
        ]
    )
registered :: RpcKeyRegistry
registered = snd registration
remoteBinding :: RpcKeyBinding
remoteBinding = fst registration
registration :: (RpcKeyBinding, RpcKeyRegistry)
registration =
  must
    ( registerRpcKey
        (must (mkRpcObservedKey (mkRpcKeyOrigin localScope localVault ref) 1 (nativePublic 18)))
        (seedAt rootScope)
    )

registeredFor :: CallerPrincipal -> RpcKeyRegistry
registeredFor = snd . registrationFor

registrationFor :: CallerPrincipal -> (RpcKeyBinding, RpcKeyRegistry)
registrationFor selected =
  must
    ( registerRpcKey
        ( must
            ( mkRpcObservedKey
                (mkRpcKeyOrigin localScope localVault (controlPlaneSigningKeyRefFor selected))
                1
                (nativePublic 18)
            )
        )
        (seedAt rootScope)
    )
