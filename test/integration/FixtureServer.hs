{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module FixtureServer
  ( runBrokerFixtureServer
  , runAuthorityFixtureServer
  , runVaultFixtureServer
  , withVaultFixtureServer
  )
where

import Codec.Serialise (DeserialiseFailure, Serialise, deserialiseOrFail, serialise)
import Control.Concurrent (forkIO)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Aeson (Value, decodeStrict', withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Network.Socket
  ( Family (AF_INET)
  , SockAddr (SockAddrInet)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , listen
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityAggregateEnvelope)
  , AuthorityBackupBlobObservation (AuthorityBackupBlobPresent)
  , AuthorityBackupCiphertext
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( LifecycleAuthorityObservation (..)
  , lifecycleAuthorityServiceIdentity
  )
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( ProviderDispatchResponse (ProviderDispatchCompleted, ProviderDispatchRefused)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerResponse (AwsAdminFirstReconcileObserved)
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (..)
  , CleanupRunDescriptorRefusal (CleanupRunDescriptorUnavailable)
  , CleanupRunDescriptorResponse (CleanupRunDescriptorRefused)
  , cleanupRunMaximumBytes
  , encodeCleanupRunDescriptorResponse
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigObservation (..)
  , ConfigProjection (..)
  , ConfigProjectionScope (ConfigProjectionOperator)
  , ConfigProposeCasResponse (ConfigProposalAlreadyCurrent)
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekTransitBoundary (..)
  , prepareTlsDekExchange
  )
import Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityResponse (TlsAuthorityObserved)
  )
import Prodbox.Http.ResponseObligation
  ( ResponseObligation
  , ResponseRefusal (ResponseCancelled, ResponseHandlerFailed)
  , mkResponseObligation
  , renderResponseRefusalReason
  , responseWriteBudgetMicrosDefault
  , withResponseObligation
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigDigest (..)
  , ConfigGeneration (..)
  , ConfigReference (..)
  , ConfigSchemaVersion (..)
  , InForceConfig (..)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (BackupEstablished)
  , BackupReceipt (BackupReceipt)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  , authorityEpochGenesis
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (MigrationReplacementWriterActive)
  , MigrationEpoch
  , mkMigrationEpoch
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (ClientId)
  , ClientSequence (ClientSequence)
  , OperationId (..)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.Authority.TlsRetention
  ( TlsRetentionState (TlsRetentionEmpty)
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupRun
  , beginCleanupNode
  , claimCleanupRun
  , completeCleanupNode
  , decodeCleanupRun
  , encodeCleanupRun
  , mkCleanupAttemptId
  , mkCleanupNodeId
  , mkCleanupOwnerId
  , recordPrimaryOutcome
  )
import Prodbox.Settings (loadConfigFileAtPath, renderConfigDhall)
import System.Environment (lookupEnv)
import System.IO qualified as IO

data FixtureAuthenticatedFrameWire = FixtureAuthenticatedFrameWire
  { fixtureFrameVersion :: !Word16
  , fixtureFrameMetadata :: !ByteString.ByteString
  , fixtureFrameSignedEnvelope :: !ByteString.ByteString
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureRequestClaimsWire = FixtureRequestClaimsWire
  { fixtureRequestProtocol :: !Text.Text
  , fixtureRequestSchema :: !Word
  , fixtureRequestRoute :: !Word
  , fixtureRequestCallerPrincipal :: !Word
  , fixtureRequestCalleeRole :: !Word
  , fixtureRequestAuthorityScope :: !Text.Text
  , fixtureRequestAuthorityEpoch :: !Natural
  , fixtureRequestDeadlineMicros :: !Natural
  , fixtureRequestNonce :: !ByteString.ByteString
  , fixtureRequestSigningKeyGeneration :: !Natural
  , fixtureRequestBodyDigest :: !ByteString.ByteString
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureSignedRequestWire = FixtureSignedRequestWire
  { fixtureSignedClaims :: !FixtureRequestClaimsWire
  , fixtureSignedBody :: !ByteString.ByteString
  , fixtureSignedSignature :: !ByteString.ByteString
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

runBrokerFixtureServer :: Int -> IO ()
runBrokerFixtureServer port =
  runFixtureServer port brokerBody

runAuthorityFixtureServer :: Int -> IO ()
runAuthorityFixtureServer port = do
  cleanupRunState <- newIORef Nothing
  runFixtureServer port (authorityBody cleanupRunState)

runVaultFixtureServer :: Int -> IO ()
runVaultFixtureServer port =
  runFixtureServer port (pureBody vaultBody)

withVaultFixtureServer :: (Int -> IO value) -> IO value
withVaultFixtureServer action =
  withSocketsDo $
    bracket (openFixtureListener 0) close $ \listener -> do
      address <- getSocketName listener
      port <- case address of
        SockAddrInet rawPort _ -> pure (fromIntegral rawPort)
        _ -> ioError (userError "Vault fixture listener was not IPv4")
      void (forkIO (acceptForever listener (pureBody vaultBody)))
      action port

runFixtureServer
  :: Int
  -> (ByteString8.ByteString -> String -> IO ByteString.ByteString)
  -> IO ()
runFixtureServer port responseBody =
  withSocketsDo $
    bracket (openFixtureListener port) close (`acceptForever` responseBody)

openFixtureListener :: Int -> IO Socket
openFixtureListener port = do
  listener <- socket AF_INET Stream defaultProtocol
  setSocketOption listener ReuseAddr 1
  bind listener (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 16
  pure listener

acceptForever
  :: Socket
  -> (ByteString8.ByteString -> String -> IO ByteString.ByteString)
  -> IO ()
acceptForever listener responseBody = go
 where
  go = do
    accepted <- try (accept listener) :: IO (Either IOException (Socket, SockAddr))
    case accepted of
      Left _ -> pure ()
      Right (connection, _) -> do
        bracket (pure connection) close (serve responseBody)
        go

-- | Sprint 4.60: the fixture answers or refuses; it never closes an accepted
-- connection silently.
--
-- Before this, an exception anywhere in @responseBody@ escaped before any byte
-- was written and was re-raised by the caller's @bracket@, so the client saw a
-- bare close (reported as @NoResponseDataReceived@) and the accept loop died,
-- taking every later request in the test with it. A schema drift in a Tier-0
-- fixture therefore presented as a network fault.
serve
  :: (ByteString8.ByteString -> String -> IO ByteString.ByteString)
  -> Socket
  -> IO ()
serve responseBody connection =
  withResponseObligation fixtureResponseObligation connection $ do
    request <- recvRequest connection ByteString8.empty
    let path = case words (ByteString8.unpack (ByteString8.takeWhile (/= '\r') request)) of
          _method : rawPath : _ -> rawPath
          _ -> ""
    body <- responseBody request path
    let status
          | path == "/v1/target-tls/retain" = "404 Not Found"
          | otherwise = "200 OK"
    pure (status, body)

-- | The fixture's obligation. Unlike the production control-plane server, the
-- refusal body carries the exception text: a fixture's job is to name the
-- failure, and `renderHttpError` truncates at 200 characters, so the summary
-- goes first.
fixtureResponseObligation :: ResponseObligation (String, ByteString.ByteString)
fixtureResponseObligation =
  mkResponseObligation
    renderFixtureResponse
    fixtureRefusalReply
    observeFixtureRefusal
    responseWriteBudgetMicrosDefault

-- | Sprint 4.65: the fixture observes its refusals too.
--
-- It already puts the reason in the reply body, so this is not where the
-- fixture's diagnosis comes from. It exists because a fixture that opted out
-- would be the counterexample to the required argument — the moment one server
-- passes a no-op is the moment the field stops meaning "every refusal is
-- observed". The destination differs from production's on purpose: a test's
-- stderr is read by whoever is running the test.
observeFixtureRefusal :: ResponseRefusal -> IO ()
observeFixtureRefusal refusal =
  IO.hPutStrLn IO.stderr ("fixture-server refusal: " ++ renderResponseRefusalReason refusal)

fixtureRefusalReply :: ResponseRefusal -> (String, ByteString.ByteString)
fixtureRefusalReply refusal = case refusal of
  ResponseHandlerFailed err ->
    ( "500 Internal Server Error"
    , ByteString8.pack ("fixture handler failed: " ++ show err)
    )
  ResponseCancelled _ ->
    ("503 Service Unavailable", "fixture shutting down")

renderFixtureResponse :: (String, ByteString.ByteString) -> ByteString.ByteString
renderFixtureResponse (status, body) =
  ByteString8.pack
    ( "HTTP/1.1 "
        ++ status
        ++ "\r\nContent-Type: application/json\r\nContent-Length: "
        ++ show (ByteString.length body)
        ++ "\r\nConnection: close\r\n\r\n"
    )
    <> body

pureBody
  :: (ByteString8.ByteString -> String -> String)
  -> ByteString8.ByteString
  -> String
  -> IO ByteString.ByteString
pureBody body request path = pure (ByteString8.pack (body request path))

authorityBody
  :: IORef (Maybe CleanupRun) -> ByteString8.ByteString -> String -> IO ByteString.ByteString
authorityBody cleanupRunState request path
  | path == "/readyz" = pure "{}"
  | path == "/v1/authority/observe" =
      pure
        ( LazyByteString.toStrict
            ( encodeControlPlaneResponse
                LifecycleAuthorityObservation
                  { observedAuthorityServiceIdentity = lifecycleAuthorityServiceIdentity
                  , observedAuthorityScope = "prodbox-home"
                  , observedAuthorityWriterStatus =
                      MigrationReplacementWriterActive fixtureMigrationEpoch
                  , observedAuthorityAdmission =
                      Just
                        ( BackupEstablished
                            authorityEpochGenesis
                            (TargetAgentGenerationReceipt "aws-admin-target-v1:1:1:fixture:fixture")
                            (BackupReceipt fixtureBackupDigestText)
                        )
                  , observedAuthorityTimeMicros = 1
                  }
            )
        )
  | path == "/v1/authority/config/observe" = do
      config <- fixtureConfigBytes
      pure
        ( LazyByteString.toStrict
            ( encodeControlPlaneResponse
                ( ConfigObservationObserved
                    ConfigProjection
                      { configProjectionIdentity = fixtureInForceConfig
                      , configProjectionScope = ConfigProjectionOperator
                      , configProjectionBytes = config
                      }
                )
            )
        )
  | path == "/v1/authority/config/propose-cas" =
      pure
        ( LazyByteString.toStrict
            (encodeControlPlaneResponse (ConfigProposalAlreadyCurrent fixtureInForceConfig))
        )
  | path == "/v1/authority/control" =
      pure
        ( LazyByteString.toStrict
            (encodeControlPlaneResponse ("fixture-authority-control-applied" :: Text.Text))
        )
  | path == "/v1/authority/aws-admin-provisioner" =
      pure
        ( LazyByteString.toStrict
            (encodeControlPlaneResponse (AwsAdminFirstReconcileObserved Nothing))
        )
  | path == "/v1/authority/provider-dispatch" =
      providerDispatchBody
  | path == "/v1/authority/tls-retention/observe" =
      pure
        ( LazyByteString.toStrict
            (encodeControlPlaneResponse (TlsAuthorityObserved TlsRetentionEmpty))
        )
  | path == "/v1/target-tls/exchange/prepare" = do
      prepared <-
        prepareTlsDekExchange
          TlsDekTransitBoundary
            { tlsDekTransitEncrypt = \_ -> pure (Right "vault:v1:fixture-private-key")
            , tlsDekTransitDecrypt = \_ -> pure (Left "fixture decrypt is unavailable")
            }
      case prepared of
        Left detail -> ioError (userError (show detail))
        Right value -> pure (LazyByteString.toStrict (encodeControlPlaneResponse value))
  | path == "/v1/target-tls/retain" = pure "fixture certificate is absent"
  | path == "/v1/authority/cleanup-run" = cleanupRunBody cleanupRunState request
  | path == "/v1/authority-backup/observe" =
      pure
        ( LazyByteString.toStrict
            ( encodeControlPlaneResponse
                ( AuthorityBackupBlobPresent
                    fixtureBackupCiphertext
                    fixtureBackupReceipt
                )
            )
        )
  | otherwise = pure "{}"

cleanupRunBody :: IORef (Maybe CleanupRun) -> ByteString.ByteString -> IO ByteString.ByteString
cleanupRunBody state request =
  case authenticatedInnerBody request of
    Left detail -> pure (ByteString8.pack detail)
    Right innerBody -> case decodeControlPlaneRequest cleanupRunMaximumBytes (LazyByteString.fromStrict innerBody) of
      Left detail -> pure (ByteString8.pack (show detail))
      Right command -> runCommand command
 where
  runCommand command = case command of
    CleanupRunScan -> pure (LazyByteString.toStrict (serialise ([] :: [Text.Text])))
    CleanupRunCreate _ encoded ->
      case decodeCleanupRun cleanupRunMaximumBytes encoded of
        Left detail -> pure (ByteString8.pack (show detail))
        Right run -> writeIORef state (Just run) >> encodeFixtureCleanupRun run
    CleanupRunObserve _ -> readFixtureCleanupRun state
    CleanupRunClaim _ rawOwner now expires ->
      transitionFixtureCleanupRun state $ \run -> do
        owner <- fixtureEither (mkCleanupOwnerId rawOwner)
        fixtureEither (claimCleanupRun owner now expires run)
    CleanupRunRecordPrimary _ rawOwner fence outcome ->
      transitionFixtureCleanupRun state $ \run -> do
        owner <- fixtureEither (mkCleanupOwnerId rawOwner)
        fixtureEither (recordPrimaryOutcome owner fence outcome run)
    CleanupRunBeginNode _ rawOwner fence rawNode rawAttempt ->
      transitionFixtureCleanupRun state $ \run -> do
        owner <- fixtureEither (mkCleanupOwnerId rawOwner)
        node <- fixtureEither (mkCleanupNodeId rawNode)
        attempt <- fixtureEither (mkCleanupAttemptId rawAttempt)
        fixtureEither (beginCleanupNode owner fence node attempt run)
    CleanupRunCompleteNode _ rawOwner fence rawNode rawAttempt outcome ->
      transitionFixtureCleanupRun state $ \run -> do
        owner <- fixtureEither (mkCleanupOwnerId rawOwner)
        node <- fixtureEither (mkCleanupNodeId rawNode)
        attempt <- fixtureEither (mkCleanupAttemptId rawAttempt)
        fixtureEither (completeCleanupNode owner fence node attempt outcome run)
    CleanupRunCompact {} -> readFixtureCleanupRun state
    CleanupRunDescriptorBound _ ->
      case encodeCleanupRunDescriptorResponse
        ( CleanupRunDescriptorRefused
            (CleanupRunDescriptorUnavailable "integration fixture does not implement descriptor-bound cleanup")
        ) of
        Left detail -> ioError (userError (Text.unpack detail))
        Right encoded -> pure encoded

transitionFixtureCleanupRun
  :: IORef (Maybe CleanupRun)
  -> (CleanupRun -> Either error CleanupRun)
  -> IO ByteString.ByteString
transitionFixtureCleanupRun state transition = do
  observed <- readIORef state
  case observed of
    Nothing -> pure ByteString.empty
    Just run -> case transition run of
      Left _ -> pure ByteString.empty
      Right next -> writeIORef state (Just next) >> encodeFixtureCleanupRun next

fixtureEither :: (Show error) => Either error value -> Either String value
fixtureEither = either (Left . show) Right

readFixtureCleanupRun :: IORef (Maybe CleanupRun) -> IO ByteString.ByteString
readFixtureCleanupRun state = do
  observed <- readIORef state
  maybe (pure ByteString.empty) encodeFixtureCleanupRun observed

encodeFixtureCleanupRun :: CleanupRun -> IO ByteString.ByteString
encodeFixtureCleanupRun run =
  case encodeCleanupRun cleanupRunMaximumBytes run of
    Left detail -> ioError (userError (show detail))
    Right encoded -> pure encoded

httpRequestBody :: ByteString.ByteString -> ByteString.ByteString
httpRequestBody request =
  let (_, suffix) = ByteString.breakSubstring "\r\n\r\n" request
   in ByteString.drop 4 suffix

authenticatedInnerBody :: ByteString.ByteString -> Either String ByteString.ByteString
authenticatedInnerBody request = do
  frame <-
    either
      (Left . show)
      Right
      ( deserialiseOrFail
          (LazyByteString.fromStrict (httpRequestBody request))
          :: Either DeserialiseFailure FixtureAuthenticatedFrameWire
      )
  signed <-
    either
      (Left . show)
      Right
      ( deserialiseOrFail
          (LazyByteString.fromStrict (fixtureFrameSignedEnvelope frame))
          :: Either DeserialiseFailure FixtureSignedRequestWire
      )
  pure (fixtureSignedBody signed)

fixtureBackupCiphertext :: AuthorityBackupCiphertext
fixtureBackupCiphertext =
  case mkAuthorityBackupCiphertext "fixture-authority-backup" of
    Left detail -> error (Text.unpack detail)
    Right ciphertext -> ciphertext

fixtureBackupDigestText :: Text.Text
fixtureBackupDigestText =
  case authorityBackupCiphertextDigest fixtureBackupCiphertext of
    digest -> authorityBackupDigestText digest

fixtureBackupReceipt :: AuthorityBackupReceipt
fixtureBackupReceipt =
  AuthorityBackupReceipt
    { authorityBackupReceiptClass = AuthorityAggregateEnvelope
    , authorityBackupReceiptDigest = authorityBackupCiphertextDigest fixtureBackupCiphertext
    , authorityBackupReceiptObjectVersion = "fixture-version-1"
    }

-- | The operation id the fixture Authority reports for a settled dispatch.
fixtureAdmittedOperation :: OperationId
fixtureAdmittedOperation =
  OperationId
    { operationIdEpoch = authorityEpochGenesis
    , operationIdClient = ClientId "fixture-client"
    , operationIdSequence = ClientSequence 1
    , operationIdDigest = RequestDigest "fixture-request-digest"
    }

fixtureMigrationEpoch :: MigrationEpoch
fixtureMigrationEpoch =
  case mkMigrationEpoch 1 of
    Nothing -> error "fixture migration epoch is invalid"
    Just epoch -> epoch

providerDispatchBody :: IO ByteString.ByteString
providerDispatchBody = do
  mode <- lookupEnv "PRODBOX_FAKE_SES_READINESS_MODE"
  let response = case mode of
        Just "identity-failed" ->
          ProviderDispatchRefused
            "ses_sending_identity_verified: VerifiedForSendingStatus=False"
        -- Sprint 4.84: a settled dispatch names the operation the Authority
        -- admitted, so the fixture must name one too. It is a fixed value: the
        -- fixture admits nothing, and a caller that decides from it would be
        -- deciding from a fixture rather than from an admission.
        _ -> ProviderDispatchCompleted fixtureAdmittedOperation "fixture-ready"
  pure (LazyByteString.toStrict (encodeControlPlaneResponse response))

fixtureConfigBytes :: IO ByteString.ByteString
fixtureConfigBytes = do
  maybePath <- lookupEnv "PRODBOX_TEST_AUTHORITY_CONFIG_PATH"
  case maybePath of
    Nothing -> ioError (userError "PRODBOX_TEST_AUTHORITY_CONFIG_PATH is missing")
    Just path -> do
      loaded <- loadConfigFileAtPath path
      case loaded of
        Left detail -> ioError (userError detail)
        Right config -> pure (TextEncoding.encodeUtf8 (Text.pack (renderConfigDhall config)))

fixtureInForceConfig :: InForceConfig
fixtureInForceConfig =
  InForceConfig
    { inForceGeneration = ConfigGeneration 1
    , inForceSchema = ConfigSchemaVersion 1
    , inForceDigest = ConfigDigest fixtureDigest
    , inForceReference = ConfigReference fixtureDigest
    }
 where
  fixtureDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

brokerBody :: ByteString8.ByteString -> String -> IO ByteString.ByteString
brokerBody _ path = do
  mode <- lookupEnv "PRODBOX_TEST_BROKER_STATUS_MODE"
  pure . ByteString8.pack $ case (path, mode) of
    ("/v1/bootstrap/vault/status", Just "malformed") -> "not-json"
    ("/v1/bootstrap/vault/status", _) ->
      "{\"storage_generation\":\"1\",\"initialized\":true,\"sealed\":false,\"initialization_ambiguous\":false}"
    _ -> "{}"

vaultBody :: ByteString8.ByteString -> String -> String
vaultBody request path
  | path == "/v1/auth/kubernetes/login" =
      "{\"auth\":{\"client_token\":\"fixture-vault-token\",\"accessor\":\"fixture-accessor\",\"lease_duration\":3600,\"renewable\":false,\"token_type\":\"service\"}}"
  | "/v1/transit/keys/" `prefixOf` path =
      "{\"data\":{\"type\":\"ed25519\",\"latest_version\":1,\"keys\":{\"1\":{\"public_key\":\""
        ++ ByteString8.unpack (Base64.encode fixturePublicKey)
        ++ "\"}}}}"
  | "/v1/transit/sign/" `prefixOf` path =
      "{\"data\":{\"signature\":\"vault:v1:"
        ++ ByteString8.unpack (Base64.encode (signInput request))
        ++ "\"}}"
  | path == "/v1/secret/data/control-plane/authority-epoch" =
      "{\"data\":{\"data\":{\"epoch\":\"1\"},\"metadata\":{\"version\":1}}}"
  | otherwise = "{}"

prefixOf :: String -> String -> Bool
prefixOf prefix value = take (length prefix) value == prefix

signInput :: ByteString8.ByteString -> ByteString8.ByteString
signInput request =
  let body = snd (ByteString8.breakSubstring "\r\n\r\n" request)
      jsonBytes = ByteString8.drop 4 body
      decodedInput = do
        value <- decodeStrict' jsonBytes :: Maybe Value
        encoded <- either (const Nothing) Just (parseEither (withObject "sign" (.: "input")) value)
        either (const Nothing) Just (Base64.decode (TextEncoding.encodeUtf8 encoded))
      signature = Ed25519.sign fixtureSecretKey fixturePublicKeyValue (maybe ByteString8.empty id decodedInput)
   in ByteArray.convert signature

fixtureSecretKey :: Ed25519.SecretKey
fixtureSecretKey = case Ed25519.secretKey (ByteString8.pack "0123456789abcdef0123456789abcdef") of
  CryptoPassed key -> key
  CryptoFailed detail -> error (show detail)

fixturePublicKeyValue :: Ed25519.PublicKey
fixturePublicKeyValue = Ed25519.toPublic fixtureSecretKey

fixturePublicKey :: ByteString8.ByteString
fixturePublicKey = ByteArray.convert fixturePublicKeyValue

recvRequest :: Socket -> ByteString8.ByteString -> IO ByteString8.ByteString
recvRequest connection accumulated
  | "\r\n\r\n" `ByteString8.isInfixOf` accumulated = pure accumulated
  | otherwise = do
      chunk <- recv connection 8192
      if ByteString8.null chunk
        then pure accumulated
        else recvRequest connection (accumulated <> chunk)
