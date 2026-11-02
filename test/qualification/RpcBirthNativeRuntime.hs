{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Run the installed Authority against synthetic native Vault and S3 services.
-- The driver owns private mount/network namespaces, a synthetic CA, all listeners
-- and each operator child. Linux namespace tools, OpenSSL and noninteractive sudo
-- are explicit fixture prerequisites; no live cluster or AWS credential is used.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, link, poll, wait, withAsync)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, forever, unless)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair)
import Data.Bifunctor (second)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (isAsciiUpper)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Dhall qualified
import Dhall.Core qualified as Core
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport qualified as T
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.Runtime (registeredClientTableFromTrustRegistry)
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.Crypto.Envelope (DekCipher (..), sealEnvelope)
import Prodbox.Http.Client (defaultHttpConfig, httpRequestRawBounded)
import Prodbox.Lib.ChartPlatform (ResolvedCustomImage (..), valuesForLifecycleAuthorityWithRpcBirth)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.CheckpointAuthority
import Prodbox.Lifecycle.Lease
import Prodbox.Minio.EncryptedObject
import Prodbox.Runtime.Role (RuntimeRole (..))
import System.Directory (canonicalizePath)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (readSymbolicLink, setFileMode)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import System.Process.Typed qualified as Process
import System.Timeout (timeout)

data Fault
  = Healthy
  | MissingPrimary
  | MissingBoth
  | MissingMarker
  | CorruptPrimary
  | CorruptMarker
  | ForeignPin
  | OriginalKeyMissing
  | UnobservablePrimary
  deriving (Eq, Show)

data Environment = Environment
  { fixtureFault :: Fault
  , wrappedKeys :: IORef (Map.Map Text BS.ByteString)
  , objects :: IORef (Map.Map BS.ByteString (Natural, BS.ByteString))
  , requests :: IORef [(BS.ByteString, BS.ByteString)]
  }

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--operator", path] -> isolateProbe path
    ["--isolated", parentMount, parentNetwork, "--operator", path] -> do
      currentMount <- readSymbolicLink "/proc/self/ns/mnt"
      currentNetwork <- readSymbolicLink "/proc/self/ns/net"
      unless
        (currentMount /= parentMount && currentNetwork /= parentNetwork)
        (fail "native fixture refuses to bind outside private mount and network namespaces")
      runSuite path
    _ -> fail "usage: native-runtime-probe --operator /absolute/path/to/prodbox"

-- Privilege is used only for private namespaces and a synthetic CA projection.
-- The fixture and operator run with the invoking user's identity.
isolateProbe :: FilePath -> IO ()
isolateProbe requestedOperator = withSystemTempDirectory "prodbox-native-namespace" $ \directory -> do
  operator <- canonicalizePath requestedOperator
  executable <- getExecutablePath
  parentMount <- readSymbolicLink "/proc/self/ns/mnt"
  parentNetwork <- readSymbolicLink "/proc/self/ns/net"
  uid <- getEffectiveUserID
  gid <- getEffectiveGroupID
  let certificate = directory </> "synthetic-ca.crt"
      privateKey = directory </> "synthetic-ca.key"
  Process.runProcess_ $
    Process.setStdout Process.nullStream $
      Process.setStderr Process.nullStream $
        Process.proc
          "openssl"
          [ "req"
          , "-x509"
          , "-newkey"
          , "rsa:2048"
          , "-nodes"
          , "-days"
          , "1"
          , "-subj"
          , "/CN=prodbox-synthetic-runtime-fixture"
          , "-keyout"
          , privateKey
          , "-out"
          , certificate
          ]
  setFileMode privateKey 0o600
  let command =
        Process.setStdin Process.nullStream $
          Process.proc
            "sudo"
            [ "-n"
            , "unshare"
            , "--mount"
            , "--net"
            , "--propagation"
            , "private"
            , "--"
            , "bash"
            , "-c"
            , namespaceScript
            , "prodbox-native-runtime-fixture"
            , certificate
            , show uid
            , show gid
            , executable
            , parentMount
            , parentNetwork
            , operator
            ]
  completed <- timeout 100000000 (Process.runProcess command)
  case completed of
    Just result -> exitWith result
    Nothing -> fail "private native fixture exceeded its 100-second outer bound"

namespaceScript :: String
namespaceScript =
  unlines
    [ "set -euo pipefail"
    , "ip link set lo up"
    , "mount -t tmpfs -o mode=755,nosuid,nodev tmpfs /run"
    , "mkdir -p /run/secrets/kubernetes.io/serviceaccount"
    , "cat \"$1\" > /run/secrets/kubernetes.io/serviceaccount/ca.crt"
    , "exec setpriv --reuid=\"$2\" --regid=\"$3\" --init-groups --no-new-privs \"$4\" --isolated \"$5\" \"$6\" --operator \"$7\""
    ]

runSuite :: FilePath -> IO ()
runSuite operator = do
  outcome <- timeout 90000000 $ do
    forM_
      [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired]
      (\phase -> probe operator phase Healthy)
    forM_
      [ MissingPrimary
      , MissingBoth
      , MissingMarker
      , CorruptPrimary
      , CorruptMarker
      , ForeignPin
      , OriginalKeyMissing
      , UnobservablePrimary
      ]
      (probe operator BirthCommitted)
  unless (outcome == Just ()) (fail "native role fixture exceeded its owned 90-second deadline")
  putStrLn "All five real role cold starts and eight refusal cases passed."

must :: (Show error) => Either error value -> value
must = either (error . show) id

probe :: FilePath -> RpcBirthPhase -> Fault -> IO ()
probe operator phase fault = withSystemTempDirectory "prodbox-native-birth" $ \directory -> do
  env <- Environment fault <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef []
  now <- rpcBirthSystemTime
  let clients = must (registeredClientTableFromTrustRegistry legacyTrust)
      legacy = productionLegacy clients
      deadline = authorityTimeFromMicros (authorityTimeMicros now + 60000000)
      descriptor =
        must
          ( mkRpcBirthDescriptor
              scope
              1
              keyA
              (authorityAggregateAuthenticationEpoch legacy)
              deadline
              (objectVersion 1)
              seeded
              clients
          )
      prepared = must (prepareRpcBirth descriptor seeded (must (rpcBirthLegacy legacy)))
      preparedMarker = rpcBirthMarkerFor BirthMarkerPrepared descriptor
      armed = must (advanceRpcBirth ArmRpcBirth prepared (Just preparedMarker))
      committed = must (advanceRpcBirth CommitRpcBirth armed (Just preparedMarker))
      retiring = must (advanceRpcBirth RetirePreparedRpcBirth prepared Nothing)
      retiredMarker = rpcBirthMarkerFor BirthMarkerRetired descriptor
      retired = must (advanceRpcBirth FinishRpcBirthRetirement retiring (Just retiredMarker))
      (record, marker) = case phase of
        BirthPrepared -> (rpcBirthStageRecord prepared, Nothing)
        BirthArmed -> (rpcBirthStageRecord armed, Just preparedMarker)
        BirthCommitted -> (rpcBirthStageRecord committed, Just (rpcBirthMarkerFor BirthMarkerCommitted descriptor))
        BirthRetiring -> (rpcBirthStageRecord retiring, Nothing)
        BirthRetired -> (rpcBirthStageRecord retired, Just retiredMarker)
        BirthLegacy -> error "native probe requires a pinned phase"
      codec = rpcBirthRecordCodec 524288 256 1024 scope clients
      pin =
        RpcBirthConfigRegistered
          ( RpcBirthConfigPin
              "home"
              1
              (if fault == ForeignPin then Text.replicate 64 "c" else rpcBirthDescriptorDigest descriptor)
          )
      epoch = authorityAggregateAuthenticationEpoch (rpcBirthAdmission record)
  putObject env "authority/admission" (must (encodeModelBValue codec record))
  forM_ marker $ \value ->
    putObject
      env
      "authority/rpc-registration-birth"
      (must (encodeModelBValue (rpcBirthMarkerCodec scope) value))
  applyFault env
  unchanged <- readIORef (objects env)
  withListener $ \vault port -> withListener $ \store storePort ->
    withAsync (forever (serveVault env epoch vault)) $ \vaultWorker ->
      withAsync (forever (serveStore env store)) $ \storeWorker -> do
        link vaultWorker
        link storeWorker
        let jwtPath = directory </> "synthetic-jwt"
            configPath = directory </> "role.dhall"
        TextIO.writeFile jwtPath "synthetic-native-fixture-jwt"
        setFileMode jwtPath 0o600
        config <- roleConfig (endpoint port) (endpoint storePort) jwtPath pin
        TextIO.writeFile configPath config
        assertPortAvailable
        bracket
          ( Process.startProcess
              ( Process.setStdin
                  Process.nullStream
                  (Process.proc operator ["lifecycle-authority", "start", "--config", configPath])
              )
          )
          Process.stopProcess
          $ \child -> withAsync (Process.waitExitCode child) $ \role ->
            if fault == Healthy
              then observeRunningRole env phase descriptor epoch role
              else do
                outcome <- wait role
                unless
                  (outcome == ExitFailure 1)
                  (fail ("invalid state did not refuse startup: " <> show (fault, outcome)))
                putStrLn (show fault <> ": real production startup refused invalid retained/native state")
        assertPortAvailable
        after <- readIORef (objects env)
        unless
          ( (if fault == Healthy then Map.delete (objectPath "authority/request-replay") after else after)
              == unchanged
          )
          (fail ("startup/observation mutated retained state: " <> show (phase, fault)))
        paths <- readIORef (requests env)
        unless
          ( null
              [ path
              | (method, path) <- paths
              , method == "PUT"
              , fault /= Healthy || path /= objectPath "authority/request-replay"
              ]
          )
          (fail "startup/observation wrote outside the registered replay object")
 where
  endpoint port = "http://127.0.0.1:" <> Text.pack (show port)

observeRunningRole
  :: Environment -> RpcBirthPhase -> RpcBirthDescriptor -> AuthorityEpoch -> Async ExitCode -> IO ()
observeRunningRole env phase descriptor epoch role = do
  waitRole role 200
  nonces <- newIORef (0 :: Int)
  current <- rpcBirthSystemTime
  let bound = authorityTimeFromMicros (authorityTimeMicros current + 10000000)
      providers =
        T.AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability (signer CallerOperatorCli))))
          (pure (Right scope))
          (pure (Right epoch))
          (pure (Right bound))
          ( do
              count <- atomicModifyIORef' nonces (\count -> (count + 1, count + 1))
              pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral count)))))
          )
      transportBounds = must (T.mkAuthenticatedTransportBounds 1048576 4096 1040000)
      wire method headers url bytes = do
        result <-
          httpRequestRawBounded defaultHttpConfig 1048576 method headers url (Just (Lazy.fromStrict bytes))
        putStrLn
          ( "Native fixture HTTP response: "
              <> show (url, fmap (second BS.length) result)
          )
        pure result
      client =
        must
          ( Client.controlPlaneClientWithTransport
              1048576
              (must (Client.mkLifecycleAuthorityEndpoint "http://127.0.0.1:8600"))
              wire
          )
      transport = T.mkAuthenticatedClientTransport transportBounds providers client
  observed <- requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) bound scope transport
  observation <- either (fail . show) pure observed
  unless
    ( rpcBirthStatusPhase (rpcBirthObservationStatus observation) == phase
        && rpcBirthObservationDescriptor observation == Just descriptor
        && rpcBirthObservationRequiresRegistration observation
    )
    (fail "real runtime returned a different retained descriptor/phase/pin")
  paths <- readIORef (requests env)
  let rpcReads =
        [ path
        | (method, path) <- paths
        , method == "GET"
        , "/v1/transit/keys/prodbox-control-plane-" `BS.isPrefixOf` path
        ]
      unexpected = [path | path <- rpcReads, path /= ownKeyPath]
  unless (null unexpected) (fail ("unrelated RPC key read: " <> show unexpected))
  unless (not (null rpcReads)) (fail "production runtime did not resolve its exact native RPC key")
  putStrLn
    ( show phase
        <> ": real encrypted-store startup and signed descriptor dispatch passed; RPC key reads="
        <> show (length rpcReads)
    )

productionLegacy :: RegisteredClientTable -> AuthorityAdmissionAggregate
productionLegacy clients =
  foldl
    (\state command -> snd (stepAuthorityAdmission state command))
    (openAdmission (must (initialCleanInstallAuthorityWithRegisteredClients 256 1024 clients)))
    ( [BeginAuthorityMigration]
        <> [ ApplyAuthorityMigrationImport (RecordProjectionImport projection ProjectionMissing)
           | projection <- [minBound .. maxBound]
           ]
        <> [ ApplyAuthorityMigrationImport CompleteProjectionImports
           , ApplyAuthorityMigration (VerifyShadow stamp)
           , ApplyAuthorityMigration (FreezeLegacy stamp)
           ]
    )
 where
  stamp = maybe (error "native fixture migration stamp") id (mkMigrationDigest "native-runtime-birth")

roleConfig :: Text -> Text -> FilePath -> RpcBirthConfig -> IO Text
roleConfig vault store jwtPath pin = do
  let image =
        ResolvedCustomImage
          "registry.test/prodbox/runtime"
          "fixture"
          (Just ("sha256:" <> replicate 64 'a'))
          (Just ("sha256:" <> replicate 64 'b'))
  values <-
    either
      fail
      pure
      ( valuesForLifecycleAuthorityWithRpcBirth
          pin
          "home"
          store
          "lifecycle-authority"
          "lifecycle-authority"
          (Just image)
      )
  body <- case values of
    Object fields -> case KeyMap.lookup "config" fields of
      Just (Object config) -> case KeyMap.lookup "roleDhall" config of
        Just (String text) -> pure text
        _ -> fail "roleDhall missing"
      _ -> fail "chart config missing"
    _ -> fail "chart values are not an object"
  pure
    ( Text.replace
        (literal "/var/run/secrets/kubernetes.io/serviceaccount/token")
        (literal (Text.pack jwtPath))
        (Text.replace (literal "http://vault.vault.svc.cluster.local:8200") (literal vault) body)
    )
 where
  literal :: Text -> Text
  literal = Core.pretty . Core.denote . Dhall.embed Dhall.inject

waitRole :: Async ExitCode -> Int -> IO ()
waitRole role attempts = do
  stopped <- poll role
  case stopped of
    Just result -> fail ("production role stopped during native startup: " <> show result)
    Nothing -> do
      connected <- try $ bracket (socket AF_INET Stream defaultProtocol) close $ \connection ->
        connect connection (SockAddrInet 8600 (tupleToHostAddress (127, 0, 0, 1)))
      case (connected :: Either IOException ()) of
        Right () -> pure ()
        Left _
          | attempts > (0 :: Int) -> threadDelay 25000 >> waitRole role (attempts - 1)
          | otherwise -> fail "production role did not bind within five seconds"

assertPortAvailable :: IO ()
assertPortAvailable = bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
  setSocketOption listener ReuseAddr 1
  bind listener (SockAddrInet 8600 (tupleToHostAddress (127, 0, 0, 1)))

withListener :: (Socket -> PortNumber -> IO value) -> IO value
withListener action = withSocketsDo $ bracket open close $ \listener -> do
  address <- getSocketName listener
  case address of SockAddrInet port _ -> action listener port; _ -> fail "fixture listener not IPv4"
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 16
    pure listener

putObject :: Environment -> Text -> BS.ByteString -> IO ()
putObject env name bytes = do
  let logical = authorityLogicalObject name
  encrypted <-
    sealEnvelope (fixtureCipher env) (logicalObjectAad "home" logical) bytes
      >>= either (fail . show) pure
  let path = objectPath name
  modifyIORef' (objects env) (Map.insert path (1, encrypted))

fixtureCipher :: Environment -> DekCipher
fixtureCipher env =
  DekCipher
    { dekWrap = \key -> atomicModifyIORef' (wrappedKeys env) $ \keys ->
        let token = "vault:v1:fixture-" <> Text.pack (show (Map.size keys + 1))
         in (Map.insert token key keys, Right token)
    , dekUnwrap = \token ->
        maybe (Left "unknown synthetic wrapped key") Right . Map.lookup token
          <$> readIORef (wrappedKeys env)
    }

ownKeyPath :: BS.ByteString
ownKeyPath =
  "/v1/transit/keys/"
    <> TE.encodeUtf8
      (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor (CallerService LifecycleAuthorityRuntime)))

serveVault :: Environment -> AuthorityEpoch -> Socket -> IO ()
serveVault env epoch listener = serve env listener respond
 where
  respond _ path _ body = case path of
    "/v1/auth/kubernetes/login" ->
      pure
        ( 200
        , []
        , json
            [ "auth"
                .= object
                  [ "client_token" .= ("synthetic-role-token" :: Text)
                  , "accessor" .= ("synthetic-accessor" :: Text)
                  , "lease_duration" .= (600 :: Int)
                  , "renewable" .= False
                  , "token_type" .= ("service" :: Text)
                  ]
            ]
        )
    "/v1/secret/data/minio/lifecycle-authority" ->
      pure
        ( 200
        , []
        , kv
            ["minio_access_key" .= ("fixture-access" :: Text), "minio_secret_key" .= ("fixture-secret" :: Text)]
        )
    "/v1/secret/data/object-store/hmac" -> pure (200, [], kv ["key" .= ("fixture-hmac" :: Text)])
    "/v1/secret/data/control-plane/authority-epoch" -> pure (200, [], kv ["epoch" .= Text.pack (show (authorityEpochValue epoch))])
    "/v1/sys/health" ->
      pure
        ( 200
        , []
        , json
            [ "initialized" .= True
            , "sealed" .= False
            , "cluster_id" .= ("11111111-1111-1111-1111-111111111111" :: Text)
            ]
        )
    "/v1/transit/decrypt/prodbox-pulumi-state" -> do
      token <- textField "ciphertext" body
      key <- dekUnwrap (fixtureCipher env) token >>= either fail pure
      pure (200, [], json ["data" .= object ["plaintext" .= TE.decodeUtf8 (B64.encode key)]])
    "/v1/transit/encrypt/prodbox-pulumi-state" -> do
      text <- textField "plaintext" body
      key <- either fail pure (B64.decode (TE.encodeUtf8 text))
      token <- dekWrap (fixtureCipher env) key >>= either fail pure
      pure (200, [], json ["data" .= object ["ciphertext" .= token]])
    "/v1/transit/keys/prodbox-authority-genesis-signing" -> pure (200, [], keyInfo False 1)
    _
      | path == ownKeyPath -> pure (200, [], keyInfo (fixtureFault env == OriginalKeyMissing) 2)
      | otherwise -> pure (404, [], json ["errors" .= ["unavailable unrelated fixture object" :: Text]])
  kv fields = json ["data" .= object ["data" .= object fields, "metadata" .= object ["version" .= (1 :: Int)]]]
  keyInfo omitOriginal latest =
    json
      [ "data"
          .= object
            [ "type" .= ("ed25519" :: Text)
            , "latest_version" .= (latest :: Int)
            , "keys"
                .= object
                  ( ["1" .= object ["public_key" .= public 1] | not omitOriginal]
                      <> ["2" .= object ["public_key" .= public 2] | latest == 2]
                  )
            ]
      ]
  public version =
    TE.decodeUtf8 . B64.encode . requestSignerPublicKeyBytes $
      if version == (1 :: Int)
        then signer (CallerService LifecycleAuthorityRuntime)
        else
          must
            ( mkRequestSigner
                (CallerService LifecycleAuthorityRuntime)
                (must (mkSigningKeyGeneration 2))
                (BS.replicate 32 250)
            )

serveStore :: Environment -> Socket -> IO ()
serveStore env listener = serve env listener $ \method path headers body -> do
  unless
    (any (BS.isPrefixOf "authorization: AWS4-HMAC-SHA256") headers)
    (fail "native object request lacks SigV4 authorization")
  existing <- readIORef (objects env)
  case method of
    "HEAD" | path == "/prodbox-state" -> pure (200, [], "")
    "GET"
      | "/prodbox-state?" `BS.isPrefixOf` path ->
          pure (200, [], "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>")
    "GET"
      | fixtureFault env == UnobservablePrimary && path == objectPath "authority/admission" ->
          pure (503, [], "fixture temporarily unobservable")
    "GET" -> case Map.lookup path existing of
      Just (revision, bytes) -> pure (200, etag revision, bytes)
      Nothing -> pure (404, [], "<Error><Code>NoSuchKey</Code></Error>")
    "PUT" -> do
      let current = Map.lookup path existing
          matches = case current of
            Nothing -> "if-none-match: *" `elem` headers
            Just (revision, _) -> ("if-match: \"" <> B8.pack (show revision) <> "\"") `elem` headers
      if matches
        then do
          let revision = maybe 1 ((+ 1) . fst) current
          modifyIORef' (objects env) (Map.insert path (revision, body))
          pure (200, etag revision, "")
        else pure (412, [], "<Error><Code>PreconditionFailed</Code></Error>")
    _ -> fail ("unexpected native store method: " <> show method)
 where
  etag revision = [("ETag", "\"" <> B8.pack (show revision) <> "\"")]

serve
  :: Environment
  -> Socket
  -> ( BS.ByteString
       -> BS.ByteString
       -> [BS.ByteString]
       -> BS.ByteString
       -> IO (Int, [(BS.ByteString, BS.ByteString)], BS.ByteString)
     )
  -> IO ()
serve env listener response = bracket (accept listener) (close . fst) $ \(connection, _) -> do
  raw <- receive connection BS.empty
  let (header, ending) = BS.breakSubstring "\r\n\r\n" raw
      lines' = B8.split '\n' header
      body = BS.drop 4 ending
      headers =
        map
          ( \line ->
              let (name, value) = BS.break (== 58) (B8.dropWhileEnd (== '\r') line)
               in B8.map toLowerAscii name <> value
          )
          (drop 1 lines')
  (method, path) <- case lines' of
    line : _ -> case B8.words line of
      method : path : _ -> pure (method, path)
      _ -> fail "invalid synthetic request line"
    [] -> fail "empty synthetic request"
  modifyIORef' (requests env) (<> [(method, path)])
  (status, extra, bytes) <- response method path headers body
  let rendered =
        B8.concat
          ( [ "HTTP/1.1 "
            , B8.pack (show status)
            , " fixture\r\nContent-Length: "
            , B8.pack (show (BS.length bytes))
            , "\r\nConnection: close\r\n"
            ]
              <> concat [[name, ": ", value, "\r\n"] | (name, value) <- extra]
              <> ["\r\n", bytes]
          )
  sendAll connection rendered
 where
  toLowerAscii char
    | isAsciiUpper char = toEnum (fromEnum char + 32)
    | otherwise = char
  receive connection accumulated = case Server.inspectControlPlaneRequestFraming accumulated of
    Left cause -> fail (show cause)
    Right (Server.ControlPlaneFramingComplete raw) -> pure raw
    Right Server.ControlPlaneFramingIncomplete -> do
      chunk <- recv connection 4096
      if BS.null chunk then fail "synthetic fixture EOF" else receive connection (accumulated <> chunk)

json :: [Pair] -> BS.ByteString
json = Lazy.toStrict . encode . object

textField :: Key -> BS.ByteString -> IO Text
textField name bytes = case eitherDecodeStrict' bytes of
  Right (Object fields) -> case KeyMap.lookup name fields of
    Just (String value) -> pure value
    _ -> fail "missing synthetic JSON field"
  _ -> fail "invalid synthetic JSON request"

objectPath :: Text -> BS.ByteString
objectPath name =
  "/prodbox-state/"
    <> TE.encodeUtf8
      (objectKeyForOpaqueId (opaqueObjectId "fixture-hmac" (authorityLogicalObject name)))

applyFault :: Environment -> IO ()
applyFault env = modifyIORef' (objects env) updateEntries
 where
  updateEntries entries = case fixtureFault env of
    MissingPrimary -> Map.delete (objectPath "authority/admission") entries
    MissingBoth -> Map.empty
    MissingMarker -> Map.delete (objectPath "authority/rpc-registration-birth") entries
    CorruptPrimary -> Map.insert (objectPath "authority/admission") (1, "not an encrypted envelope") entries
    CorruptMarker ->
      Map.insert (objectPath "authority/rpc-registration-birth") (1, "not an encrypted envelope") entries
    Healthy -> entries
    ForeignPin -> entries
    OriginalKeyMissing -> entries
    UnobservablePrimary -> entries

scope :: Coordinate.AuthorityScope
scope = must (Coordinate.mkAuthorityScope "home")

keyA :: Text
keyA = Text.replicate 32 "a"

objectVersion :: Natural -> ModelBObjectVersion
objectVersion value = must (mkModelBObjectVersion ("opaque-v" <> Text.pack (show value)))

signer :: CallerPrincipal -> RequestSigner
signer caller =
  must
    ( mkRequestSigner
        caller
        (must (mkSigningKeyGeneration 1))
        (BS.replicate 32 (fromIntegral (callerPrincipalCode caller + 31)))
    )

seeded :: RpcKeyRegistry
seeded =
  must
    ( seedLegacyRpcKeyRegistry
        scope
        [ must
            ( mkRpcObservedKey
                (mkRpcKeyOrigin scope incarnation (controlPlaneSigningKeyRefFor caller))
                1
                (requestSignerPublicKeyBytes (signer caller))
            )
        | caller <- allCallerPrincipals
        ]
    )
 where
  incarnation = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")

legacyTrust :: T.RouteTrustRegistry
legacyTrust =
  must
    ( registeredRpcRouteTrust
        LifecycleAuthorityRuntime
        ( fromIntegral
            (maximum (1 : map (length . trustedCallersForRoute) (routesForRole LifecycleAuthorityRuntime)))
        )
        seeded
    )

openAdmission :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAdmission =
  flip
    (foldl (\state command -> snd (stepAuthorityAdmission state (ApplyAuthorityGenesis command))))
    [ BeginGenesisEstablishment (GenesisPlan "birth-genesis" "backup/birth")
    , ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "birth-target")
    , ObserveBackupReceipt (BackupReceipt "birth-backup")
    ]
