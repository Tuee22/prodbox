{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Read Docker system information over an already-held Unix connection.
-- The observation neither authenticates the peer nor authorizes effects.
module Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerSession
  , DockerConnectedInfoFailure (..)
  , DockerConnectedInfoResult (..)
  , withConnectedDockerInfo
  , observeConnectedDockerInfo
  , pingDockerSession
  , DockerKindInfo (..)
  , readDockerSessionKindInfo
  , dockerKindNodeRuntime
  , observeDockerKindNodeRuntime
  , DockerKindStorage (..)
  , readDockerSessionKindStorage
  , parseDockerKindStorage
  , DockerNodeContainerCreateResult (..)
  , createDockerSessionKindNode
  , DockerAbsenceControlCreate (..)
  , absenceControlCreateBody
  , createDockerSessionAbsenceControl
  , DockerNodeContainerObservation (..)
  , inspectDockerSessionKindNode
  , readDockerSessionContainerNotFound
  , readDockerSessionKindNodeNameNotFound
  , readDockerSessionKindNodeAddresses
  , parseDockerKindNodeAddresses
  , readDockerSessionKindNodeBootLine
  , readDockerSessionKindNodeVersion
  , parseDockerKindNodeVersionArchive
  , DockerNodeConfigWriteResult (..)
  , writeDockerSessionKindNodeConfig
  , DockerNodeConfigReadback (..)
  , readDockerSessionKindNodeConfig
  , parseDockerKindNodeConfigArchive
  , readDockerSessionKindNodeCa
  , parseDockerKindNodeCaArchive
  , DockerNodeConfigPath (..)
  , DockerNodeConfigPathObservation (..)
  , observeDockerSessionKindNodeConfigPath
  , parseDockerNodeContainer
  , DockerNodeContainerStartResult (..)
  , DockerNodeContainerRemoveResult (..)
  , removeDockerSessionKindNode
  , startDockerSessionKindNode
  , DockerNodeVarVolumeObservation (..)
  , DockerNodeVarCreateResult (..)
  , createDockerSessionNodeVarVolume
  , DockerNodeVarRemoveResult (..)
  , removeDockerSessionNodeVarVolume
  , removeDockerSessionAbsenceVolume
  , inspectDockerSessionNodeVarVolume
  , parseDockerNodeVarVolume
  , DockerMutationVolume (..)
  , DockerMutationVolumeObservation (..)
  , inspectDockerSessionMutationVolume
  , createDockerSessionMutationVolume
  , removeDockerSessionMutationVolume
  , readDockerSessionMutationHolder
  , readDockerSessionKindContainers
  , readDockerSessionKindNetworks
  , readDockerSessionKindNetworksControlled
  , readDockerSessionKindNetworkId
  , readDockerSessionKindNetworkIdControlled
  , parseDockerBridgeId
  , parseDockerKindNetworks
  , DockerNetworkDetails (..)
  , inspectDockerSessionKindNetwork
  , parseDockerNetworkDetails
  , DockerNetworkCreateResult (..)
  , createDockerSessionKindNetwork
  , DockerNetworkRemoveResult (..)
  , removeDockerSessionKindNetwork
  , readDockerSessionBridgeMtu
  , parseDockerBridgeMtu
  , parseDockerKindContainers
  , inspectDockerSessionImage
  , DockerImageVolumes (..)
  , inspectDockerSessionImageVolumes
  , parseDockerImageVolumes
  , DockerAbsenceControlObservation (..)
  , inspectDockerSessionAbsenceControl
  , parseDockerAbsenceControl
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  , classifyDockerImageLoadStream
  , loadDockerSessionImage
  , DockerImageSubmissionObservation (..)
  , DockerImageReadback (..)
  , loadAndObserveDockerSessionImage
  ) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as TarEntry
import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, (.:), (.:?))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAscii, isPrint, isSpace, toLower)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (hConnection, hContentLength, hTransferEncoding)
import Network.HTTP.Types.Status (statusCode)
import Network.HTTP.Types.URI (renderQuery)
import Network.HTTP.Types.Version (http11)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , DeploymentScope
  , scopeEnvironment
  , scopeKindName
  , scopeRoot
  , validRootGeneration
  )
import Prodbox.Config.KindPlan
  ( KindNodeCreateInput (..)
  , KindNodeRuntimeMode (..)
  , kindNodeCreateBody
  , kindNodeVarVolumeCreateBody
  , kindNodeVarVolumeLabels
  , kindNodeVarVolumeName
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (DockerDaemonObserved)
  , parseDockerDaemonId
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..), withConnectedDockerPeer)
import Prodbox.Control.ImageIdObservation
  ( ImageIdObservation
  , parseImageIdObservation
  , validImageId
  )
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkIntent
  , kindNetworkMtu
  , kindNetworkOperation
  , kindNetworkSubnet
  )
import Prodbox.Control.NodeArchiveExport (maximumDockerArchiveBytes)
import Prodbox.Settings.Coordinate (ipLiteralText, mkIpLiteral)
import System.FilePath.Posix (isAbsolute, normalise, splitDirectories)
import System.IO (SeekMode (AbsoluteSeek))
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd)
import Text.Read (readMaybe)

data DockerConnectedInfo = DockerConnectedInfo !String !DockerPeer
  deriving (Eq, Show)

-- The manager and socket are borrowed only within the callback. The manager
-- never opens a second connection, and callers cannot issue arbitrary requests.
newtype DockerSession = DockerSession HTTP.Manager

-- Only the fields consumed by kind's Docker provider are retained. This is a
-- bounded daemon observation, not an admission or authentication decision.
data DockerKindInfo = DockerKindInfo
  { dockerKindCgroupDriver :: !String
  , dockerKindCgroupVersion :: !String
  , dockerKindMemoryLimit :: !Bool
  , dockerKindPidsLimit :: !Bool
  , dockerKindCpuShares :: !Bool
  , dockerKindSecurityOptions :: ![String]
  }
  deriving (Eq, Show)

-- Kind requires cgroup v2 and all three delegated controllers with rootless
-- Docker. The retained request records the corresponding provider argv.
dockerKindNodeRuntime :: DockerKindInfo -> Maybe KindNodeRuntimeMode
dockerKindNodeRuntime info
  | not (any rootless (dockerKindSecurityOptions info)) = Just KindNodeRootful
  | dockerKindCgroupVersion info == "2"
      && dockerKindMemoryLimit info
      && dockerKindPidsLimit info
      && dockerKindCpuShares info
      && dockerKindCgroupDriver info /= "none" =
      Just KindNodeRootless
  | otherwise = Nothing
 where
  rootless = elem "name=rootless" . Text.splitOn "," . Text.pack

observeDockerKindNodeRuntime
  :: FilePath -> IO (Maybe (DockerDaemonObservation, KindNodeRuntimeMode))
observeDockerKindNodeRuntime socket = do
  observed <- withConnectedDockerInfo 15000000 socket $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) stable -> do
    info <- readDockerSessionKindInfo session identifier
    held <- stable
    pure $ case info of
      Right fields | held -> (DockerDaemonObserved identifier identity,) <$> dockerKindNodeRuntime fields
      _ -> Nothing
  pure $ case observed of
    DockerPeerCompleted (DockerConnectedInfoCompleted result) -> result
    _ -> Nothing

data DockerKindStorage = DockerKindStorage
  { dockerKindStorageDriver :: !String
  , dockerKindStorageStatus :: !(Maybe [[String]])
  }
  deriving (Eq, Show)

-- A matching response is configuration evidence only, not provenance or
-- permission to mutate. A 404 is one response, not proof of resource absence.
data DockerNodeVarVolumeObservation
  = DockerNodeVarVolumeNotFound
  | DockerNodeVarVolumeMatching
  | DockerNodeVarVolumeConflict
  deriving (Eq, Show)

data DockerConnectedInfoFailure
  = DockerConnectedInfoTransport
  | DockerConnectedInfoStatus
  | DockerConnectedInfoTooLarge
  | DockerConnectedInfoInvalid
  | DockerConnectedInfoChanged
  | DockerConnectedInfoConnectionClosing
  | DockerConnectedInfoFramingInvalid
  deriving (Eq, Show)

data DockerConnectedInfoResult value
  = DockerConnectedInfoRefused !DockerConnectedInfoFailure
  | DockerConnectedInfoCompleted !value
  deriving (Eq, Show)

-- | The callback borrows a session on the same socket used for this read.
-- It must not retain the session. This read does not authenticate the daemon,
-- admit effects or prove which process serves a socket-activated listener.
withConnectedDockerInfo
  :: Int
  -> FilePath
  -> (DockerSession -> DockerConnectedInfo -> IO Bool -> IO value)
  -> IO (DockerPeerResult (DockerConnectedInfoResult value))
withConnectedDockerInfo = withDockerInfo True

withDockerInfo
  :: Bool
  -> Int
  -> FilePath
  -> (DockerSession -> DockerConnectedInfo -> IO Bool -> IO value)
  -> IO (DockerPeerResult (DockerConnectedInfoResult value))
withDockerInfo requirePersistent limit path action = withConnectedDockerPeer limit path observe
 where
  observe socket peer stable = do
    manager <- connectedManager socket
    result <- readInfo requirePersistent manager
    case result of
      Left failure -> pure (DockerConnectedInfoRefused failure)
      Right identifier -> do
        ready <- stable
        if not ready
          then pure (DockerConnectedInfoRefused DockerConnectedInfoChanged)
          else
            DockerConnectedInfoCompleted
              <$> action (DockerSession manager) (DockerConnectedInfo identifier peer) stable

observeConnectedDockerInfo
  :: FilePath -> IO (DockerPeerResult (DockerConnectedInfoResult DockerConnectedInfo))
observeConnectedDockerInfo path = withDockerInfo False 5000000 path (\_ info _ -> pure info)

connectedManager :: Socket.Socket -> IO HTTP.Manager
connectedManager socket = do
  used <- newIORef False
  let connection _ _ _ = do
        prior <- atomicModifyIORef' used (True,)
        if prior
          then ioError (userError "connected Docker socket cannot be reused by the manager")
          else HTTP.makeConnection (SocketBytes.recv socket 8192) (SocketBytes.sendAll socket) (pure ())
      settings =
        HTTP.managerSetMaxHeaderLength 16384
          . HTTP.managerSetMaxNumberHeaders 128
          . HTTP.managerSetProxy HTTP.noProxy
          $ HTTP.defaultManagerSettings
            { HTTP.managerRawConnection = pure connection
            , HTTP.managerConnCount = 1
            , HTTP.managerIdleConnectionCount = 1
            , HTTP.managerRetryableException = const False
            }
  HTTP.newManager settings

dockerGet :: BS.ByteString -> HTTP.Request
dockerGet path =
  HTTP.defaultRequest
    { HTTP.method = "GET"
    , HTTP.host = "localhost"
    , HTTP.port = 80
    , HTTP.path = path
    , HTTP.proxy = Nothing
    , HTTP.redirectCount = 0
    , HTTP.responseTimeout = HTTP.responseTimeoutMicro 5000000
    , -- Docker compresses archive bodies when gzip is advertised, which
      -- http-client does by default; every parser here needs identity.
      HTTP.requestHeaders = [("Accept-Encoding", "identity")]
    }

readInfo :: Bool -> HTTP.Manager -> IO (Either DockerConnectedInfoFailure String)
readInfo requirePersistent manager = do
  result <- try $ do
    HTTP.withResponse (dockerGet "/info") manager (readResponse requirePersistent)
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure String))

-- | One bounded read-only request on the borrowed manager. This does not
-- authenticate the peer or grant admission for future daemon mutations.
pingDockerSession :: DockerSession -> IO (Either DockerConnectedInfoFailure ())
pingDockerSession (DockerSession manager) = do
  result <- try (HTTP.withResponse (dockerGet "/_ping") manager readPing)
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure ()))

-- | Observe only one exact image ID on the held connection. A failed query,
-- including a 404, is not proof of image absence or prior worker settlement.
inspectDockerSessionImage
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure ImageIdObservation)
inspectDockerSessionImage (DockerSession manager) identifier
  | not (validImageId identifier) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <-
        try
          ( HTTP.withResponse
              (dockerGet (BS8.pack ("/images/" ++ identifier ++ "/json")))
              manager
              (readImage identifier)
          )
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure ImageIdObservation))

-- Image declarations are needed before creating a never-started control:
-- Docker may allocate anonymous volumes even without starting the container.
-- This is a read-only point observation, not storage ownership or admission.
newtype DockerImageVolumes = DockerImageVolumes [FilePath]
  deriving (Eq, Show)

inspectDockerSessionImageVolumes
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure DockerImageVolumes)
inspectDockerSessionImageVolumes (DockerSession manager) identifier
  | not (validImageId identifier) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <-
        try
          (HTTP.withResponse (dockerGet (BS8.pack ("/images/" ++ identifier ++ "/json"))) manager readVolumes)
      pure
        ( either
            (const (Left DockerConnectedInfoTransport))
            id
            (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerImageVolumes))
        )
 where
  readVolumes response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated)
                | value == validated ->
                    either (const (Left DockerConnectedInfoInvalid)) Right (parseDockerImageVolumes identifier value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerImageVolumes :: String -> Aeson.Value -> Either String DockerImageVolumes
parseDockerImageVolumes identifier = parseEither $ Aeson.withObject "Docker image volume declarations" $ \image -> do
  actual <- image .: "Id"
  config <- image .: "Config"
  volumes <- Aeson.withObject "Docker image configuration" (.: "Volumes") config
  paths <- case volumes of
    Aeson.Null -> pure []
    Aeson.Object entries -> do
      let pairs = KeyMap.toList entries
          validValue Aeson.Null = True
          validValue (Aeson.Object fields) = KeyMap.null fields
          validValue _ = False
      if length pairs <= 64 && all (validValue . snd) pairs
        then pure (map (Text.unpack . Key.toText . fst) pairs)
        else fail "invalid image volume declarations"
    _ -> fail "invalid image volume declarations"
  if not (validImageId identifier) || actual /= identifier || not (validImageVolumePaths (sort paths))
    then fail "image identity or volume path mismatch"
    else pure (DockerImageVolumes (sort paths))

validImageVolumePaths :: [FilePath] -> Bool
validImageVolumePaths paths =
  length paths <= 64
    && paths == sort paths
    && length paths == length (nub paths)
    && all validPath paths
 where
  validPath path =
    isAbsolute path
      && normalise path == path
      && path /= "/"
      && last path /= '/'
      && length path <= 4096
      && all (`notElem` ['\0', '\n', '\r']) path
      && all (`notElem` [".", ".."]) (splitDirectories path)

-- Configuration and mount observation only. Neither matching labels nor a
-- deterministic name establish ownership of a container or its volumes.
data DockerAbsenceControlObservation
  = DockerAbsenceControlMatching !String ![(FilePath, String)]
  | DockerAbsenceControlConflict
  deriving (Eq, Show)

inspectDockerSessionAbsenceControl
  :: DockerSession
  -> BootstrapProjection
  -> String
  -> String
  -> String
  -> DockerImageVolumes
  -> Maybe String
  -> IO (Either DockerConnectedInfoFailure DockerAbsenceControlObservation)
inspectDockerSessionAbsenceControl (DockerSession manager) bootstrap operation target image volumes expected
  | not (validAbsenceControlExpected bootstrap operation target image volumes expected) =
      pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let name = scopeKindName (bootstrapScope bootstrap) ++ "-absence-control"
      result <-
        try
          (HTTP.withResponse (dockerGet (BS8.pack ("/containers/" ++ name ++ "/json"))) manager readControl)
      pure
        ( either
            (const (Left DockerConnectedInfoTransport))
            id
            ( result
                :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerAbsenceControlObservation)
            )
        )
 where
  readControl response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated)
                | value == validated ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerAbsenceControl bootstrap operation target image volumes expected value)
              _ -> Left DockerConnectedInfoInvalid

validAbsenceControlExpected
  :: BootstrapProjection -> String -> String -> String -> DockerImageVolumes -> Maybe String -> Bool
validAbsenceControlExpected bootstrap operation target image (DockerImageVolumes volumes) expected =
  scopeEnvironment (bootstrapScope bootstrap) == Test
    && validRootGeneration operation
    && validImageId ("sha256:" ++ target)
    && validImageId image
    && validImageVolumePaths volumes
    && maybe True (\identifier -> identifier /= target && validImageId ("sha256:" ++ identifier)) expected

-- A 404 or failed query is deliberately not represented as absence. A
-- matching result supplies candidate IDs for later journaled ownership and
-- independent cleanup, not permission to remove them.
parseDockerAbsenceControl
  :: BootstrapProjection
  -> String
  -> String
  -> String
  -> DockerImageVolumes
  -> Maybe String
  -> Aeson.Value
  -> Either String DockerAbsenceControlObservation
parseDockerAbsenceControl bootstrap operation target image volumes@(DockerImageVolumes declared) expected =
  parseEither $ Aeson.withObject "Docker absence control" $ \container -> do
    identifier <- container .: "Id"
    name <- container .: "Name"
    imageId <- container .: "Image"
    config <- container .: "Config"
    configuredImage <- config .: "Image"
    entrypoint <- config .: "Entrypoint" :: Parser [String]
    command <- config .: "Cmd" :: Parser [String]
    networkDisabled <- config .: "NetworkDisabled"
    labels <- config .: "Labels" :: Parser (Map.Map String String)
    state <- container .: "State"
    running <- state .: "Running"
    paused <- state .: "Paused"
    restarting <- state .: "Restarting"
    dead <- state .: "Dead"
    status <- state .: "Status"
    host <- container .: "HostConfig"
    networkMode <- host .: "NetworkMode"
    privileged <- host .: "Privileged"
    readOnlyRoot <- host .: "ReadonlyRootfs"
    autoRemove <- host .: "AutoRemove"
    droppedCaps <- host .: "CapDrop" :: Parser [String]
    restart <- host .: "RestartPolicy" :: Parser Aeson.Value
    binds <- host .: "Binds"
    mounts <- container .: "Mounts" >>= traverse parseControlMount
    network <- container .: "NetworkSettings"
    networks <- network .: "Networks" :: Parser (Map.Map String Aeson.Value)
    networkEndpoints <- traverse parseControlNetwork networks
    let noBinds = case binds of Aeson.Null -> True; Aeson.Array items -> null items; _ -> False
        footprint = sort [(destination, volume) | (destination, volume, _) <- mounts]
        matching =
          validAbsenceControlExpected bootstrap operation target image volumes expected
            && validImageId ("sha256:" ++ identifier)
            && identifier /= target
            && maybe True (== identifier) expected
            && name == '/' : scopeKindName (bootstrapScope bootstrap) ++ "-absence-control"
            && imageId == image
            && configuredImage == image
            && entrypoint == ["/nonexistent"]
            && command == ["/nonexistent"]
            && networkDisabled
            && Map.lookup "io.prodbox.absence-control" labels == Just operation
            && Map.lookup "io.prodbox.generation" labels == Just (Text.unpack (bootstrapRootGeneration bootstrap))
            && Map.size labels <= 64
            && Map.notMember "io.x-k8s.kind.cluster" labels
            && Map.notMember "io.x-k8s.kind.role" labels
            && not running
            && not paused
            && not restarting
            && not dead
            && status == ("created" :: String)
            && networkMode == ("none" :: String)
            && not privileged
            && readOnlyRoot
            && not autoRemove
            && noBinds
            && droppedCaps == ["ALL"]
            && restart == Aeson.object ["Name" Aeson..= ("no" :: String), "MaximumRetryCount" Aeson..= (0 :: Int)]
            && all (`elem` ["none"]) (Map.keys networks)
            && and (Map.elems networkEndpoints)
            && length mounts <= 64
            && all (\(_, _, writable) -> writable) mounts
            && map fst footprint == declared
            && length (map snd footprint) == length (nub (map snd footprint))
    pure
      (if matching then DockerAbsenceControlMatching identifier footprint else DockerAbsenceControlConflict)
 where
  parseControlNetwork = Aeson.withObject "absence control network" $ \network -> do
    endpoint <- network .: "EndpointID"
    ipv4 <- network .: "IPAddress"
    ipv6 <- network .: "GlobalIPv6Address"
    pure (endpoint == ("" :: String) && ipv4 == ("" :: String) && ipv6 == ("" :: String))
  parseControlMount = Aeson.withObject "absence control mount" $ \mount -> do
    kind <- mount .: "Type"
    volume <- mount .: "Name"
    destination <- mount .: "Destination"
    driver <- mount .: "Driver"
    writable <- mount .: "RW"
    if kind /= ("volume" :: String)
      || driver /= ("local" :: String)
      || not (validImageId ("sha256:" ++ volume))
      then fail "invalid anonymous volume mount"
      else pure (destination, volume, writable)

-- | Read kind's provider information over the existing connection and match
-- its daemon ID against the earlier observation on that same session.
readDockerSessionKindInfo
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure DockerKindInfo)
readDockerSessionKindInfo (DockerSession manager) expected = do
  result <- try (HTTP.withResponse (dockerGet "/info") manager (readKindInfo expected))
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerKindInfo))

-- | Read the storage driver fields from the same selected daemon connection.
-- This observation does not authenticate the daemon or authorize an effect.
readDockerSessionKindStorage
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure DockerKindStorage)
readDockerSessionKindStorage (DockerSession manager) expected = do
  result <- try (HTTP.withResponse (dockerGet "/info") manager readStorage)
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerKindStorage))
 where
  readStorage response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either (const (Left DockerConnectedInfoInvalid)) Right (parseDockerKindStorage expected value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerKindStorage :: String -> Aeson.Value -> Either String DockerKindStorage
parseDockerKindStorage expected = parseEither $ Aeson.withObject "Docker storage info" $ \object -> do
  identifier <- object .: "ID"
  driver <- object .: "Driver"
  rows <-
    if KeyMap.member "DriverStatus" object
      then object .: "DriverStatus"
      else fail "missing Docker driver status"
  let safe limit value = length value <= limit && all (\character -> isAscii character && isPrint character) value
      validRow row = length row == 2 && all (safe 512) row
  if identifier /= expected
    || parseDockerDaemonId (BS8.unpack (BL.toStrict (Aeson.encode (identifier :: String))))
      /= Just expected
    || null driver
    || not (safe 128 driver)
    || maybe False (\values -> length values > 128 || any (not . validRow) values) rows
    then fail "invalid or changed Docker storage info"
    else pure (DockerKindStorage driver rows)

data DockerNodeContainerCreateResult
  = DockerNodeContainerCreateNotStarted
  | DockerNodeContainerCreateUnconfirmed
  | DockerNodeContainerCreateReply !Int !(Maybe String)
  deriving (Eq, Show)

-- | Submit one plan-derived node create request on the held connection. Docker
-- can implicitly create a named volume during container creation. The caller
-- must separately establish admission, exact network, image and volume
-- provenance, a durable attempt, daemon authentication, worker settlement and
-- cleanup before any effect. A response is not proof of ownership or readiness.
createDockerSessionKindNode
  :: DockerSession
  -> BootstrapProjection
  -> KindNodeCreateInput
  -> IO Bool
  -> IO DockerNodeContainerCreateResult
createDockerSessionKindNode (DockerSession manager) bootstrap input stable
  | nodeCreateGeneration input /= Text.unpack (bootstrapRootGeneration bootstrap) =
      pure DockerNodeContainerCreateNotStarted
  | otherwise = case kindNodeCreateBody (bootstrapKindPlan bootstrap) input of
      Nothing -> pure DockerNodeContainerCreateNotStarted
      Just payload -> do
        ready <- try stable
        case ready of
          Left (_ :: IOException) -> pure DockerNodeContainerCreateNotStarted
          Right False -> pure DockerNodeContainerCreateNotStarted
          Right True -> do
            let name = scopeKindName (bootstrapScope bootstrap) ++ "-control-plane"
                request =
                  (dockerGet "/containers/create")
                    { HTTP.method = "POST"
                    , HTTP.queryString = renderQuery True [("name", Just (BS8.pack name))]
                    , HTTP.requestHeaders = [("Content-Type", "application/json")]
                    , HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode payload)
                    , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                    }
            received <- try (try (HTTP.withResponse request manager readContainerCreate))
            case received of
              Left (_ :: IOException) -> pure DockerNodeContainerCreateUnconfirmed
              Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeContainerCreateUnconfirmed
              Right (Right reply) -> do
                after <- try stable
                pure $ case (reply, after :: Either IOException Bool) of
                  (Just result, Right True) -> result
                  _ -> DockerNodeContainerCreateUnconfirmed

readContainerCreate :: HTTP.Response HTTP.BodyReader -> IO (Maybe DockerNodeContainerCreateResult)
readContainerCreate response
  | not (framed response) = pure Nothing
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      case body of
        Nothing -> pure Nothing
        Just bytes
          | statusCode (HTTP.responseStatus response) /= 201 ->
              pure (Just (DockerNodeContainerCreateReply (statusCode (HTTP.responseStatus response)) Nothing))
          | otherwise -> do
              checked <- decodeBoundedYamlValue bytes
              pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
                (Right value, Right validated) | value == validated ->
                  case parseEither (Aeson.withObject "node create" (.: "Id")) value of
                    Right identifier
                      | validImageId ("sha256:" ++ identifier) ->
                          Just (DockerNodeContainerCreateReply 201 (Just identifier))
                    _ -> Nothing
                _ -> Nothing

data DockerAbsenceControlCreate
  = DockerAbsenceCreateInvalid
  | DockerAbsenceCreateAdmissionRefused
  | DockerAbsenceCreateImageUnobservable !DockerConnectedInfoFailure
  | DockerAbsenceCreateImageChanged !DockerImageVolumes
  | DockerAbsenceCreateAttempted !DockerNodeContainerCreateResult
  deriving (Eq, Show)

-- A closed, never-started control specification. It deliberately leaves image
-- volume declarations intact: their exact anonymous IDs must be recorded and
-- independently retired. This body grants no ownership or effect admission.
absenceControlCreateBody
  :: BootstrapProjection -> String -> String -> String -> DockerImageVolumes -> Maybe Aeson.Value
absenceControlCreateBody bootstrap operation target image volumes
  | not (validAbsenceControlExpected bootstrap operation target image volumes Nothing) = Nothing
  | otherwise =
      Just $
        Aeson.object
          [ "Image" Aeson..= image
          , "Entrypoint" Aeson..= (["/nonexistent"] :: [String])
          , "Cmd" Aeson..= (["/nonexistent"] :: [String])
          , "NetworkDisabled" Aeson..= True
          , "Labels"
              Aeson..= Aeson.object
                [ "io.prodbox.absence-control" Aeson..= operation
                , "io.prodbox.generation" Aeson..= bootstrapRootGeneration bootstrap
                ]
          , "HostConfig"
              Aeson..= Aeson.object
                [ "NetworkMode" Aeson..= ("none" :: String)
                , "Privileged" Aeson..= False
                , "ReadonlyRootfs" Aeson..= True
                , "AutoRemove" Aeson..= False
                , "Binds" Aeson..= ([] :: [String])
                , "CapDrop" Aeson..= (["ALL"] :: [String])
                , "RestartPolicy"
                    Aeson..= Aeson.object ["Name" Aeson..= ("no" :: String), "MaximumRetryCount" Aeson..= (0 :: Int)]
                ]
          ]

-- The caller must hold the operation and settled-worker owners, establish an
-- exact fresh-control precondition and durable create attempt, fund image
-- volume creation, and own recovery and cleanup before using this transport.
-- A lost reply remains unconfirmed; the name/labels do not prove ownership.
createDockerSessionAbsenceControl
  :: DockerSession
  -> BootstrapProjection
  -> String
  -> String
  -> String
  -> DockerImageVolumes
  -> IO Bool
  -> IO DockerAbsenceControlCreate
createDockerSessionAbsenceControl session@(DockerSession manager) bootstrap operation target image volumes stable =
  case absenceControlCreateBody bootstrap operation target image volumes of
    Nothing -> pure DockerAbsenceCreateInvalid
    Just payload -> do
      admitted <- try stable
      case admitted of
        Left (_ :: IOException) -> pure DockerAbsenceCreateAdmissionRefused
        Right False -> pure DockerAbsenceCreateAdmissionRefused
        Right True -> do
          observed <- inspectDockerSessionImageVolumes session image
          afterImage <- try stable
          case (observed, afterImage :: Either IOException Bool) of
            (Left failure, _) -> pure (DockerAbsenceCreateImageUnobservable failure)
            (Right _, Left _) -> pure DockerAbsenceCreateAdmissionRefused
            (Right _, Right False) -> pure DockerAbsenceCreateAdmissionRefused
            (Right actual, Right True) | actual /= volumes -> pure (DockerAbsenceCreateImageChanged actual)
            (Right _, Right True) -> do
              let name = scopeKindName (bootstrapScope bootstrap) ++ "-absence-control"
                  request =
                    (dockerGet "/containers/create")
                      { HTTP.method = "POST"
                      , HTTP.queryString = renderQuery True [("name", Just (BS8.pack name))]
                      , HTTP.requestHeaders = [("Content-Type", "application/json")]
                      , HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode payload)
                      , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                      }
              received <- try (try (HTTP.withResponse request manager readContainerCreate))
              case received of
                Left (_ :: IOException) -> pure (DockerAbsenceCreateAttempted DockerNodeContainerCreateUnconfirmed)
                Right (Left (_ :: HTTP.HttpException)) -> pure (DockerAbsenceCreateAttempted DockerNodeContainerCreateUnconfirmed)
                Right (Right reply) -> do
                  after <- try stable
                  pure $ DockerAbsenceCreateAttempted $ case (reply, after :: Either IOException Bool) of
                    (Just result@(DockerNodeContainerCreateReply 201 (Just identifier)), Right True)
                      | identifier /= target -> result
                    (Just result@(DockerNodeContainerCreateReply status Nothing), Right True)
                      | status /= 201 -> result
                    _ -> DockerNodeContainerCreateUnconfirmed

-- Configuration comparison only; labels, mounts and a running state do not
-- establish resource provenance, admission, Kubernetes readiness or settlement.
data DockerNodeContainerObservation
  = DockerNodeContainerMatching !Bool
  | DockerNodeContainerConflict
  deriving (Eq, Show)

-- A bounded exact-ID read. The caller must authenticate the held daemon and
-- independently verify the inventory and removal history before using it.
readDockerSessionContainerNotFound :: DockerSession -> String -> IO Bool
readDockerSessionContainerNotFound session identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure False
  | otherwise = readDockerSessionContainerMissing session identifier

-- The deterministic name supplies a point observation for a proposal that
-- has never acquired an exact container ID.
readDockerSessionKindNodeNameNotFound :: DockerSession -> DeploymentScope -> IO Bool
readDockerSessionKindNodeNameNotFound session scope =
  readDockerSessionContainerMissing session (scopeKindName scope ++ "-control-plane")

readDockerSessionContainerMissing :: DockerSession -> String -> IO Bool
readDockerSessionContainerMissing (DockerSession manager) identifier = do
  let request = dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/json"))
  result <- try (HTTP.withResponse request manager observe)
  pure (either (const False) id (result :: Either HTTP.HttpException Bool))
 where
  observe response
    | statusCode (HTTP.responseStatus response) /= 404 = pure False
    | not (persistent response && framed response) = pure False
    | otherwise = do
        body <- collectBody 4096 (HTTP.responseBody response)
        case body of
          Nothing -> pure False
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated)
                | value == validated ->
                    parseEither (Aeson.withObject "Docker container not found" (.: "message")) value
                      == Right ("No such container: " ++ identifier)
              _ -> False

inspectDockerSessionKindNode
  :: DockerSession
  -> BootstrapProjection
  -> KindNodeCreateInput
  -> String
  -> IO (Either DockerConnectedInfoFailure DockerNodeContainerObservation)
inspectDockerSessionKindNode (DockerSession manager) bootstrap input identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | nodeCreateGeneration input /= Text.unpack (bootstrapRootGeneration bootstrap) =
      pure (Left DockerConnectedInfoInvalid)
  | kindNodeCreateBody (bootstrapKindPlan bootstrap) input == Nothing =
      pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <-
        try
          (HTTP.withResponse (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/json"))) manager readNode)
      pure
        ( either
            (const (Left DockerConnectedInfoTransport))
            id
            ( result
                :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNodeContainerObservation)
            )
        )
 where
  readNode response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated)
                | value == validated ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerNodeContainer bootstrap input identifier value)
              _ -> Left DockerConnectedInfoInvalid

-- The selected node must match in the same Docker inspection that supplies
-- its addresses. This is a point observation, not network ownership proof.
readDockerSessionKindNodeAddresses
  :: DockerSession
  -> BootstrapProjection
  -> KindNodeCreateInput
  -> String
  -> IO (Either DockerConnectedInfoFailure BS.ByteString)
readDockerSessionKindNodeAddresses (DockerSession manager) bootstrap input identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <-
        try
          (HTTP.withResponse (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/json"))) manager readNode)
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure BS.ByteString))
 where
  readNode response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated)
                | value == validated ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerKindNodeAddresses bootstrap input identifier value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerKindNodeAddresses
  :: BootstrapProjection -> KindNodeCreateInput -> String -> Aeson.Value -> Either String BS.ByteString
parseDockerKindNodeAddresses bootstrap input identifier value = do
  observed <- parseDockerNodeContainer bootstrap input identifier value
  if observed /= DockerNodeContainerMatching True
    then Left "node is not the selected running node"
    else pure ()
  (ipv4, ipv6) <-
    parseEither
      ( Aeson.withObject "node" $ \node -> do
          settings <- node .: "NetworkSettings"
          networks <- settings .: "Networks" :: Parser (Map.Map String Aeson.Value)
          network <-
            maybe
              (fail "missing selected network")
              pure
              (Map.lookup (scopeKindName (bootstrapScope bootstrap)) networks)
          Aeson.withObject
            "network"
            (\selected -> (,) <$> selected .: "IPAddress" <*> selected .: "GlobalIPv6Address")
            network
      )
      value
  let valid family address =
        Text.null address
          || ( Text.any (== ':') address == family && case mkIpLiteral address of
                 Right parsed -> ipLiteralText parsed == address
                 Left _ -> False
             )
  if (Text.null ipv4 && Text.null ipv6) || not (valid False ipv4 && valid True ipv6)
    then Left "invalid node addresses"
    else Right (BS8.pack (Text.unpack ipv4 ++ "," ++ Text.unpack ipv6 ++ "\n"))

-- | Read a bounded non-following log snapshot for one exact node ID and
-- return only an observed kind boot marker. The caller must first and afterward
-- inspect the matching running node and bind the operation and daemon. This
-- does not establish Kubernetes readiness or permit an effect.
readDockerSessionKindNodeBootLine
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure (Maybe BS.ByteString))
readDockerSessionKindNodeBootLine (DockerSession manager) identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let request =
            (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/logs")))
              { HTTP.queryString =
                  renderQuery True [("stdout", Just "1"), ("stderr", Just "1"), ("tail", Just "256")]
              }
      result <- try (HTTP.withResponse request manager readLogs)
      pure
        ( either
            (const (Left DockerConnectedInfoTransport))
            id
            (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure (Maybe BS.ByteString)))
        )
 where
  readLogs response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure $ case body of
          Nothing -> Left DockerConnectedInfoTooLarge
          Just bytes -> Right (firstBootMarker (BS8.lines bytes))
  firstBootMarker [] = Nothing
  firstBootMarker (line : remaining) = case marker line of
    Nothing -> firstBootMarker remaining
    found -> found
  marker rawLine =
    let line = stripColourSequences rawLine
        (_, start) = BS8.breakSubstring "Reached target " line
        (middle, target) = BS8.breakSubstring "Multi-User System" start
        (_, cgroup) = BS8.breakSubstring "detected cgroup v1" line
        candidate
          | not (BS8.null start) && not (BS8.null target) = middle <> "Multi-User System"
          | not (BS8.null cgroup) = "detected cgroup v1"
          | otherwise = BS8.empty
        printable byte = byte >= 32 && byte <= 126
     in if BS8.null candidate || BS8.length candidate > 4096 || not (BS.all printable candidate)
          then Nothing
          else Just (candidate <> "\n")

-- Remove only CSI colour sequences (ESC '[' digits and semicolons, then 'm').
-- A TTY container's init writes them around unit names; any other control byte
-- is left in place and still fails the printable check.
stripColourSequences :: BS.ByteString -> BS.ByteString
stripColourSequences input = case BS.uncons input of
  Nothing -> BS.empty
  Just (27, rest)
    | Just ('[', afterBracket) <- BS8.uncons rest
    , (parameters, afterParameters) <-
        BS8.span (\character -> character == ';' || (character >= '0' && character <= '9')) afterBracket
    , Just ('m', remaining) <- BS8.uncons afterParameters
    , BS.length parameters <= 16 ->
        stripColourSequences remaining
  Just (byte, rest) -> BS.cons byte (stripColourSequences rest)

-- Read only the file that kind's version probe would display. An archive with a
-- link, multiple entries, an unexpected name or an oversized body is refused.
readDockerSessionKindNodeVersion
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure BS.ByteString)
readDockerSessionKindNodeVersion (DockerSession manager) identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let request =
            (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/archive")))
              { HTTP.queryString = renderQuery True [("path", Just "/kind/version")]
              , -- The client advertises gzip by default and Docker then
                -- compresses the archive; the strict tar parser needs identity.
                HTTP.requestHeaders = [("Accept-Encoding", "identity")]
              }
      result <- try (HTTP.withResponse request manager readArchive)
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure BS.ByteString))
 where
  readArchive response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 32768 (HTTP.responseBody response)
        pure $ case body of
          Nothing -> Left DockerConnectedInfoTooLarge
          Just bytes -> maybe (Left DockerConnectedInfoInvalid) Right (parseDockerKindNodeVersionArchive bytes)

parseDockerKindNodeVersionArchive :: BS.ByteString -> Maybe BS.ByteString
parseDockerKindNodeVersionArchive bytes = case Tar.read (BL.fromStrict bytes) of
  Tar.Next entry Tar.Done
    | TarEntry.entryPath entry == "version"
    , TarEntry.NormalFile contents size <- TarEntry.entryContent entry
    , size >= 0 && size <= 4096
    , BL.length contents == size ->
        Just (BL.toStrict contents)
  _ -> Nothing

data DockerNodeConfigWriteResult
  = DockerNodeConfigWriteNotStarted
  | DockerNodeConfigWriteUnconfirmed
  | DockerNodeConfigWriteReply !Int
  deriving (Eq, Show)

-- The caller must validate the secret-bearing input, establish exact container
-- and path ownership, authenticate the daemon, record and admit the attempt,
-- settle workers and independently reconcile any unconfirmed submission.
-- This operation does not make any of those decisions.
writeDockerSessionKindNodeConfig
  :: DockerSession -> String -> BS.ByteString -> IO Bool -> IO DockerNodeConfigWriteResult
writeDockerSessionKindNodeConfig (DockerSession manager) identifier contents stable
  | not (validImageId ("sha256:" ++ identifier)) || BS.null contents || BS.length contents > 65536 =
      pure DockerNodeConfigWriteNotStarted
  | otherwise = case TarEntry.toTarPath False "kubeadm.conf" of
      Left _ -> pure DockerNodeConfigWriteNotStarted
      Right path -> do
        ready <- try stable
        case ready of
          Left (_ :: IOException) -> pure DockerNodeConfigWriteNotStarted
          Right False -> pure DockerNodeConfigWriteNotStarted
          Right True -> do
            let archive = Tar.write [TarEntry.fileEntry path (BL.fromStrict contents)]
                request =
                  (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/archive")))
                    { HTTP.method = "PUT"
                    , HTTP.queryString = renderQuery True [("path", Just "/kind"), ("noOverwriteDirNonDir", Just "true")]
                    , HTTP.requestHeaders = [("Content-Type", "application/x-tar")]
                    , HTTP.requestBody = HTTP.RequestBodyLBS archive
                    , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                    }
            result <- try (try (HTTP.withResponse request manager readReply))
            case result of
              Left (_ :: IOException) -> pure DockerNodeConfigWriteUnconfirmed
              Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeConfigWriteUnconfirmed
              Right (Right status) -> do
                after <- try stable
                pure $ case (status, after :: Either IOException Bool) of
                  (Just code, Right True) -> DockerNodeConfigWriteReply code
                  _ -> DockerNodeConfigWriteUnconfirmed
 where
  readReply response
    | not (persistent response && framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure (statusCode (HTTP.responseStatus response) <$ body)

data DockerNodeConfigReadback = DockerNodeConfigMatches | DockerNodeConfigDiffers
  deriving (Eq, Show)

-- Compare in memory only: neither result contains the potentially secret file.
-- A 404 or transport error is not evidence of file absence or settlement.
readDockerSessionKindNodeConfig
  :: DockerSession
  -> String
  -> BS.ByteString
  -> IO (Either DockerConnectedInfoFailure DockerNodeConfigReadback)
readDockerSessionKindNodeConfig (DockerSession manager) identifier expected
  | not (validImageId ("sha256:" ++ identifier)) || BS.null expected || BS.length expected > 65536 =
      pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let request =
            (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/archive")))
              { HTTP.queryString = renderQuery True [("path", Just "/kind/kubeadm.conf")]
              }
      result <- try (HTTP.withResponse request manager readArchive)
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNodeConfigReadback))
 where
  readArchive response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 73728 (HTTP.responseBody response)
        pure $ case body of
          Nothing -> Left DockerConnectedInfoTooLarge
          Just bytes -> maybe (Left DockerConnectedInfoInvalid) Right (parseDockerKindNodeConfigArchive expected bytes)

parseDockerKindNodeConfigArchive :: BS.ByteString -> BS.ByteString -> Maybe DockerNodeConfigReadback
parseDockerKindNodeConfigArchive = parseDockerNodeFileArchive "kubeadm.conf"

-- The caller must bracket this read with the exact running-node and daemon
-- observations, and separately verify the selected kubeconfig and TLS peer.
-- A matching archive alone does not authenticate an API server or permit an
-- effect. Certificate bytes stay in memory and never appear in the result.
readDockerSessionKindNodeCa
  :: DockerSession
  -> String
  -> BS.ByteString
  -> IO (Either DockerConnectedInfoFailure DockerNodeConfigReadback)
readDockerSessionKindNodeCa (DockerSession manager) identifier expected
  | not (validImageId ("sha256:" ++ identifier)) || BS.null expected || BS.length expected > 65536 =
      pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let request =
            (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/archive")))
              { HTTP.queryString = renderQuery True [("path", Just "/etc/kubernetes/pki/ca.crt")]
              }
      result <- try (HTTP.withResponse request manager readArchive)
      pure
        ( either
            (const (Left DockerConnectedInfoTransport))
            id
            (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNodeConfigReadback))
        )
 where
  readArchive response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 73728 (HTTP.responseBody response)
        pure $ case body of
          Nothing -> Left DockerConnectedInfoTooLarge
          Just bytes -> maybe (Left DockerConnectedInfoInvalid) Right (parseDockerKindNodeCaArchive expected bytes)

parseDockerKindNodeCaArchive :: BS.ByteString -> BS.ByteString -> Maybe DockerNodeConfigReadback
parseDockerKindNodeCaArchive = parseDockerNodeFileArchive "ca.crt"

parseDockerNodeFileArchive
  :: FilePath -> BS.ByteString -> BS.ByteString -> Maybe DockerNodeConfigReadback
parseDockerNodeFileArchive name expected bytes = case Tar.read (BL.fromStrict bytes) of
  Tar.Next entry Tar.Done
    | TarEntry.entryPath entry == name
    , TarEntry.NormalFile contents size <- TarEntry.entryContent entry
    , size >= 0 && size <= 65536
    , BL.length contents == size ->
        Just (if BL.toStrict contents == expected then DockerNodeConfigMatches else DockerNodeConfigDiffers)
  _ -> Nothing

data DockerNodeConfigPath = DockerNodeConfigDirectory | DockerNodeConfigFile
  deriving (Eq, Show)

-- The timestamp, mode and size allow repeated point observations to be
-- compared; they do not identify an inode or exclude a concurrent path swap.
data DockerNodeConfigPathObservation
  = DockerNodeConfigDirectoryObserved !Integer !Integer !Text.Text
  | DockerNodeConfigRegularObserved !Integer !Integer !Text.Text
  | DockerNodeConfigOtherObserved
  | DockerNodeConfigNotFoundResponse
  deriving (Eq, Show)

-- Docker's 404 can mean either container or path is missing. It is retained as
-- a response, not inferred absence. The caller must bind the node and daemon,
-- settle workers and independently establish ownership and effect admission.
observeDockerSessionKindNodeConfigPath
  :: DockerSession
  -> String
  -> DockerNodeConfigPath
  -> IO (Either DockerConnectedInfoFailure DockerNodeConfigPathObservation)
observeDockerSessionKindNodeConfigPath (DockerSession manager) identifier selected
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let (path, name) = case selected of
            DockerNodeConfigDirectory -> ("/kind", "kind")
            DockerNodeConfigFile -> ("/kind/kubeadm.conf", "kubeadm.conf")
          request =
            (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/archive")))
              { HTTP.method = "HEAD"
              , HTTP.queryString = renderQuery True [("path", Just path)]
              }
      result <- try (HTTP.withResponse request manager (readPath name))
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          ( result
              :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNodeConfigPathObservation)
          )
 where
  readPath name response
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | statusCode (HTTP.responseStatus response) == 404 = pure (Right DockerNodeConfigNotFoundResponse)
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | otherwise = case [value | (header, value) <- HTTP.responseHeaders response, header == "X-Docker-Container-Path-Stat"] of
        [encoded] | BS.length encoded <= 8192 -> case Base64.decode encoded of
          Right bytes | BS.length bytes <= 4096 && Base64.encode bytes == encoded -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either (const (Left DockerConnectedInfoInvalid)) Right (parseEither (parseStat name) value)
              _ -> Left DockerConnectedInfoInvalid
          _ -> pure (Left DockerConnectedInfoInvalid)
        _ -> pure (Left DockerConnectedInfoInvalid)
  parseStat expected = Aeson.withObject "container path stat" $ \object -> do
    name <- object .: "name"
    size <- object .: "size" :: Parser Integer
    mode <- object .: "mode" :: Parser Integer
    modified <- object .: "mtime" :: Parser Text.Text
    target <- object .: "linkTarget" :: Parser Text.Text
    if KeyMap.size object /= 5
      || name /= (expected :: String)
      || size < 0
      || size > 9223372036854775807
      || mode < 0
      || mode > 4294967295
      || Text.null modified
      || Text.length modified > 64
      || Text.length target > 4096
      || not (Text.all (\c -> isAscii c && isPrint c) modified)
      || not (Text.all (\c -> isAscii c && isPrint c) target)
      then fail "invalid container path stat"
      else
        pure $
          if Text.null target && mode >= 2147483648 && mode <= 2147487743
            then DockerNodeConfigDirectoryObserved mode size modified
            else
              if Text.null target && mode <= 4095
                then DockerNodeConfigRegularObserved mode size modified
                else DockerNodeConfigOtherObserved

parseDockerNodeContainer
  :: BootstrapProjection
  -> KindNodeCreateInput
  -> String
  -> Aeson.Value
  -> Either String DockerNodeContainerObservation
parseDockerNodeContainer bootstrap input identifier = parseEither $ Aeson.withObject "kind node" $ \node -> do
  actualId <- node .: "Id"
  actualName <- node .: "Name"
  actualImage <- node .: "Image"
  config <- node .: "Config"
  labels <- config .: "Labels" :: Parser (Map.Map String String)
  hostname <- config .: "Hostname"
  tty <- config .: "Tty"
  exposed <- config .: "ExposedPorts" :: Parser (Map.Map String Aeson.Value)
  state <- node .: "State"
  running <- state .: "Running"
  paused <- state .: "Paused"
  restarting <- state .: "Restarting"
  dead <- state .: "Dead"
  status <- state .: "Status" :: Parser String
  mounts <- node .: "Mounts" >>= traverse parseMount
  hostConfig <- node .: "HostConfig"
  publishAll <- hostConfig .: "PublishAllPorts"
  privileged <- hostConfig .: "Privileged"
  cgroupMode <- hostConfig .: "CgroupnsMode"
  restart <- hostConfig .: "RestartPolicy"
  security <- hostConfig .: "SecurityOpt" :: Parser [String]
  networkMode <- hostConfig .: "NetworkMode" :: Parser String
  tmpfs <- hostConfig .: "Tmpfs"
  devices <- (maybe [] id <$> hostConfig .:? "Devices") :: Parser [Aeson.Value]
  initProcess <- hostConfig .: "Init"
  ports <- hostConfig .: "PortBindings" >>= parsePorts
  expectedBody <-
    maybe
      (fail "invalid node create input")
      pure
      (kindNodeCreateBody (bootstrapKindPlan bootstrap) input)
  expectedPorts <-
    Aeson.withObject
      "expected node"
      (\body -> body .: "HostConfig" >>= (.: "PortBindings") >>= parsePorts)
      expectedBody
  expectedExposed <- Aeson.withObject "expected node" (.: "ExposedPorts") expectedBody
  expectedHost <- Aeson.withObject "expected node" (.: "HostConfig") expectedBody
  expectedRestart <- expectedHost .: "RestartPolicy"
  expectedSecurity <- expectedHost .: "SecurityOpt" :: Parser [String]
  expectedTmpfs <- expectedHost .: "Tmpfs"
  expectedDevices <- maybe [] id <$> expectedHost .:? "Devices"
  networkSettings <- node .: "NetworkSettings"
  networks <- networkSettings .: "Networks" :: Parser (Map.Map String Aeson.Value)
  networkIds <- traverse (Aeson.withObject "network" (.: "NetworkID")) networks
  let scope = bootstrapScope bootstrap
      cluster = scopeKindName scope
      expectedName = '/' : cluster ++ "-control-plane"
      expectedVolume =
        kindNodeVarVolumeName
          (bootstrapKindPlan bootstrap)
          (nodeCreateGeneration input)
          (nodeCreateOperation input)
      selected destination =
        [ (kind, name, source, writable)
        | (kind, name, source, target, writable) <- mounts
        , target == destination
        ]
      matches =
        not paused
          && not restarting
          && not dead
          && (if running then status == "running" else status `elem` ["created", "exited"])
          && length mounts == 3
          && ports == expectedPorts
          && not publishAll
          && hostname == cluster ++ "-control-plane"
          && tty
          && privileged
          && cgroupMode == ("private" :: String)
          && restart == (expectedRestart :: Aeson.Value)
          -- Docker appends label=disable to a privileged container's options.
          && (security == expectedSecurity || security == expectedSecurity ++ ["label=disable"])
          && tmpfs == (expectedTmpfs :: Aeson.Value)
          && devices == expectedDevices
          && initProcess == (False :: Bool)
          && exposed == expectedExposed
          && actualId == identifier
          && actualName == expectedName
          && actualImage == nodeCreateImageId input
          && Map.lookup "io.x-k8s.kind.cluster" labels == Just cluster
          && Map.lookup "io.x-k8s.kind.role" labels == Just "control-plane"
          && Map.lookup "io.prodbox.generation" labels == Just (nodeCreateGeneration input)
          && Map.lookup "io.prodbox.operation" labels == Just (nodeCreateOperation input)
          && (networkMode == cluster || networkMode == nodeCreateNetworkId input)
          -- A created, never-started container reports an empty network ID;
          -- Docker fills it only when the container starts.
          && ( Map.toList networkIds == [(cluster, nodeCreateNetworkId input)]
                 || (not running && status == "created" && Map.toList networkIds == [(cluster, "")])
             )
          && case (expectedVolume, selected "/var") of
            (Just volume, [("volume", Just actual, source, True)]) -> actual == volume && not (null source)
            _ -> False
      bindMatches =
        selected "/var/lib/prodbox" == [("bind", Nothing, scopeRoot scope, True)]
          && selected "/lib/modules" == [("bind", Nothing, "/lib/modules", False)]
  if not (validImageId ("sha256:" ++ identifier))
    || nodeCreateGeneration input /= Text.unpack (bootstrapRootGeneration bootstrap)
    || length mounts > 128
    || Map.size labels > 128
    || Map.size exposed > 16
    || Map.size networks > 16
    then fail "invalid node inspection input or oversized response"
    else
      pure
        (if matches && bindMatches then DockerNodeContainerMatching running else DockerNodeContainerConflict)
 where
  parsePorts :: Aeson.Value -> Parser (Map.Map String [(String, String)])
  parsePorts value = do
    bindings <- Aeson.parseJSON value :: Parser (Map.Map String [Aeson.Value])
    if Map.size bindings > 16 || any ((> 8) . length) bindings
      then fail "oversized port bindings"
      else
        traverse
          ( traverse
              (Aeson.withObject "port binding" (\binding -> (,) <$> binding .: "HostIp" <*> binding .: "HostPort"))
          )
          bindings

  parseMount :: Aeson.Value -> Parser (String, Maybe String, FilePath, FilePath, Bool)
  parseMount = Aeson.withObject "mount" $ \mount ->
    (,,,,)
      <$> mount .: "Type"
      <*> mount .:? "Name"
      <*> mount .: "Source"
      <*> mount .: "Destination"
      <*> mount .: "RW"

data DockerNodeContainerStartResult
  = DockerNodeContainerStartNotStarted
  | DockerNodeContainerStartUnconfirmed
  | DockerNodeContainerStartReply !Int
  deriving (Eq, Show)

-- | Send one start request for a full container ID. The caller must separately
-- prove ownership, authenticate the daemon, establish admission, persist the
-- start attempt, settle any worker and independently inspect readiness. A 204
-- or 304 response is transport evidence only.
startDockerSessionKindNode
  :: DockerSession -> String -> IO Bool -> IO DockerNodeContainerStartResult
startDockerSessionKindNode (DockerSession manager) identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure DockerNodeContainerStartNotStarted
  | otherwise = do
      ready <- try stable
      case ready of
        Left (_ :: IOException) -> pure DockerNodeContainerStartNotStarted
        Right False -> pure DockerNodeContainerStartNotStarted
        Right True -> do
          let request =
                (dockerGet (BS8.pack ("/containers/" ++ identifier ++ "/start")))
                  { HTTP.method = "POST"
                  , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                  }
          received <- try (try (HTTP.withResponse request manager readStart))
          case received of
            Left (_ :: IOException) -> pure DockerNodeContainerStartUnconfirmed
            Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeContainerStartUnconfirmed
            Right (Right reply) -> do
              after <- try stable
              pure $ case (reply, after :: Either IOException Bool) of
                (Just status, Right True) -> DockerNodeContainerStartReply status
                _ -> DockerNodeContainerStartUnconfirmed
 where
  readStart response
    | statusCode (HTTP.responseStatus response) == 204 || statusCode (HTTP.responseStatus response) == 304 =
        let lengths = [value | (name, value) <- HTTP.responseHeaders response, name == hContentLength]
            encodings = [value | (name, value) <- HTTP.responseHeaders response, name == hTransferEncoding]
         in pure $
              if null encodings && (null lengths || lengths == ["0"])
                then Just (statusCode (HTTP.responseStatus response))
                else Nothing
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure (statusCode (HTTP.responseStatus response) <$ body)

data DockerNodeContainerRemoveResult
  = DockerNodeContainerRemoveNotStarted
  | DockerNodeContainerRemoveUnconfirmed
  | DockerNodeContainerRemoveReply !Int
  deriving (Eq, Show)

-- | Send one deletion request for a full ID on the held session. The caller
-- must separately prove exact ownership, admission, daemon and worker
-- settlement, persist the cleanup attempt first, and independently read back
-- absence. Even a 204 or 404 is a transport response, not absence evidence.
removeDockerSessionKindNode
  :: DockerSession -> String -> IO Bool -> IO Bool -> IO DockerNodeContainerRemoveResult
removeDockerSessionKindNode (DockerSession manager) identifier beforeEffect afterEffect
  | not (validImageId ("sha256:" ++ identifier)) = pure DockerNodeContainerRemoveNotStarted
  | otherwise = do
      ready <- try beforeEffect
      case ready of
        Left (_ :: IOException) -> pure DockerNodeContainerRemoveNotStarted
        Right False -> pure DockerNodeContainerRemoveNotStarted
        Right True -> do
          let request =
                (dockerGet (BS8.pack ("/containers/" ++ identifier)))
                  { HTTP.method = "DELETE"
                  , -- v=1 removes only anonymous volumes attached to this container
                    -- (the node image declares one). Named volumes, including the
                    -- node's recorded /var volume, are never touched by it.
                    HTTP.queryString = "?force=1&v=1"
                  , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                  }
          received <- try (try (HTTP.withResponse request manager readRemoval))
          case received of
            Left (_ :: IOException) -> pure DockerNodeContainerRemoveUnconfirmed
            Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeContainerRemoveUnconfirmed
            Right (Right reply) -> do
              after <- try afterEffect
              pure $ case (reply, after :: Either IOException Bool) of
                (Just result, Right True) -> DockerNodeContainerRemoveReply result
                _ -> DockerNodeContainerRemoveUnconfirmed
 where
  readRemoval response
    | statusCode (HTTP.responseStatus response) == 204 =
        let lengths = [value | (name, value) <- HTTP.responseHeaders response, name == hContentLength]
            encodings = [value | (name, value) <- HTTP.responseHeaders response, name == hTransferEncoding]
         in pure $ if null encodings && (null lengths || lengths == ["0"]) then Just 204 else Nothing
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure (statusCode (HTTP.responseStatus response) <$ body)

-- A response is transport evidence only: Docker can return an existing volume
-- for create. Neither the status nor matching configuration proves provenance.
data DockerNodeVarCreateResult
  = DockerNodeVarCreateNotStarted
  | DockerNodeVarCreateUnconfirmed
  | DockerNodeVarCreateReply !Int !(Maybe DockerNodeVarVolumeObservation)
  deriving (Eq, Show)

-- | Send one derived create request on the held session. The caller must
-- independently establish admission, authenticate the daemon, persist and
-- recheck the exact attempt, exclude competing writers, and settle/recover the
-- effect. This function is not an admission or proof of ownership.
createDockerSessionNodeVarVolume
  :: DockerSession -> BootstrapProjection -> String -> IO Bool -> IO DockerNodeVarCreateResult
createDockerSessionNodeVarVolume (DockerSession manager) bootstrap operation stable =
  case ( kindNodeVarVolumeCreateBody plan generation operation
       , kindNodeVarVolumeName plan generation operation
       ) of
    (Just payload, Just name) -> do
      ready <- try stable
      case ready of
        Left (_ :: IOException) -> pure DockerNodeVarCreateNotStarted
        Right False -> pure DockerNodeVarCreateNotStarted
        Right True -> do
          let request =
                (dockerGet "/volumes/create")
                  { HTTP.method = "POST"
                  , HTTP.requestHeaders = [("Content-Type", "application/json")]
                  , HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode payload)
                  , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                  }
          received <- try (try (HTTP.withResponse request manager (readCreate name)))
          case received of
            Left (_ :: IOException) -> pure DockerNodeVarCreateUnconfirmed
            Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeVarCreateUnconfirmed
            Right (Right reply) -> do
              after <- try stable
              pure $ case (reply, after :: Either IOException Bool) of
                (Just result, Right True) -> result
                _ -> DockerNodeVarCreateUnconfirmed
    _ -> pure DockerNodeVarCreateNotStarted
 where
  plan = bootstrapKindPlan bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  readCreate name response
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure Nothing
          Just bytes
            | statusCode (HTTP.responseStatus response) /= 201 ->
                pure (Just (DockerNodeVarCreateReply (statusCode (HTTP.responseStatus response)) Nothing))
            | otherwise -> do
                checked <- decodeBoundedYamlValue bytes
                pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
                  (Right value, Right validated) | value == validated ->
                    case parseDockerNodeVarVolume bootstrap operation name value of
                      Right observation -> Just (DockerNodeVarCreateReply 201 (Just observation))
                      Left _ -> Nothing
                  _ -> Nothing

data DockerNodeVarRemoveResult
  = DockerNodeVarRemoveNotStarted
  | DockerNodeVarRemoveUnconfirmed
  | DockerNodeVarRemoveReply !Int
  deriving (Eq, Show)

-- | Send one non-forced request for the derived volume on the held session.
-- The caller must independently establish exact ownership, no remaining users,
-- admission and worker settlement, persist the removal attempt before this
-- call, and independently verify cleanup. A 204 or 404 is not absence proof.
removeDockerSessionNodeVarVolume
  :: DockerSession -> BootstrapProjection -> String -> IO Bool -> IO DockerNodeVarRemoveResult
removeDockerSessionNodeVarVolume session bootstrap operation stable =
  case kindNodeVarVolumeName
    (bootstrapKindPlan bootstrap)
    (Text.unpack (bootstrapRootGeneration bootstrap))
    operation of
    Nothing -> pure DockerNodeVarRemoveNotStarted
    Just name -> removeDockerSessionVolume session name stable stable

-- | The caller must bind this full anonymous-volume ID to a durable control
-- footprint and settle all users before the non-forced removal attempt.
removeDockerSessionAbsenceVolume
  :: DockerSession -> String -> IO Bool -> IO Bool -> IO DockerNodeVarRemoveResult
removeDockerSessionAbsenceVolume session identifier beforeEffect afterEffect
  | not (validImageId ("sha256:" ++ identifier)) = pure DockerNodeVarRemoveNotStarted
  | otherwise = removeDockerSessionVolume session identifier beforeEffect afterEffect

removeDockerSessionVolume
  :: DockerSession -> String -> IO Bool -> IO Bool -> IO DockerNodeVarRemoveResult
removeDockerSessionVolume (DockerSession manager) volumeName beforeEffect afterEffect = do
  ready <- try beforeEffect
  case ready of
    Left (_ :: IOException) -> pure DockerNodeVarRemoveNotStarted
    Right False -> pure DockerNodeVarRemoveNotStarted
    Right True -> do
      let request =
            (dockerGet (BS8.pack ("/volumes/" ++ volumeName)))
              { HTTP.method = "DELETE"
              , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
              }
      received <- try (try (HTTP.withResponse request manager readRemoval))
      case received of
        Left (_ :: IOException) -> pure DockerNodeVarRemoveUnconfirmed
        Right (Left (_ :: HTTP.HttpException)) -> pure DockerNodeVarRemoveUnconfirmed
        Right (Right reply) -> do
          after <- try afterEffect
          pure $ case (reply, after :: Either IOException Bool) of
            (Just result, Right True) -> DockerNodeVarRemoveReply result
            _ -> DockerNodeVarRemoveUnconfirmed
 where
  readRemoval response
    | statusCode (HTTP.responseStatus response) == 204 =
        let lengths = [value | (name, value) <- HTTP.responseHeaders response, name == hContentLength]
            encodings = [value | (name, value) <- HTTP.responseHeaders response, name == hTransferEncoding]
         in pure $ if null encodings && (null lengths || lengths == ["0"]) then Just 204 else Nothing
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure (statusCode (HTTP.responseStatus response) <$ body)

-- The opaque input value binds a new disposable volume to its dominating
-- campaign. A Docker create response can also report a pre-existing object.
data DockerMutationVolume = DockerMutationVolume
  { dockerMutationVolumeName :: !String
  , dockerMutationVolumeOwner :: !String
  , dockerMutationVolumeOptions :: !(Map.Map String String)
  }
  deriving (Eq, Show)

data DockerMutationVolumeObservation
  = DockerMutationVolumeMissing
  | DockerMutationVolumeObserved !String
  deriving (Eq, Show)

validMutationVolume :: DockerMutationVolume -> Bool
validMutationVolume volume =
  let name = dockerMutationVolumeName volume
      owner = dockerMutationVolumeOwner volume
      safe value =
        not (null value)
          && length value <= 120
          && all (\c -> c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') value
   in safe name && safe owner && take 16 name == "prodbox-mutdisk-"

inspectDockerSessionMutationVolume
  :: DockerSession
  -> DockerMutationVolume
  -> IO (Either DockerConnectedInfoFailure DockerMutationVolumeObservation)
inspectDockerSessionMutationVolume session volume
  | not (validMutationVolume volume) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      inspected <-
        readMutationDockerJson
          session
          (dockerGet path)
          200
          ("get " ++ name ++ ": no such volume")
      pure $ case inspected of
        Left failure -> Left failure
        Right Nothing -> Right DockerMutationVolumeMissing
        Right (Just exists) ->
          maybe
            (Left DockerConnectedInfoInvalid)
            (Right . DockerMutationVolumeObserved)
            (matchMutationVolume volume exists)
 where
  name = dockerMutationVolumeName volume
  path = BS8.pack ("/volumes/" ++ name)

createDockerSessionMutationVolume
  :: DockerSession
  -> DockerMutationVolume
  -> IO Bool
  -> IO (Either DockerConnectedInfoFailure DockerMutationVolumeObservation)
createDockerSessionMutationVolume session volume stable = do
  before <- stable
  if before && validMutationVolume volume
    then do
      created <- readMutationDockerJson session request 201 ""
      after <- stable
      pure $ case (created, after) of
        (Right (Just value), True) ->
          maybe
            (Left DockerConnectedInfoInvalid)
            (Right . DockerMutationVolumeObserved)
            (matchMutationVolume volume value)
        (Left failure, True) -> Left failure
        _ -> Left DockerConnectedInfoInvalid
    else pure (Left DockerConnectedInfoInvalid)
 where
  request =
    (dockerGet "/volumes/create")
      { HTTP.method = "POST"
      , HTTP.requestHeaders = [("Content-Type", "application/json")]
      , HTTP.requestBody =
          HTTP.RequestBodyLBS $
            Aeson.encode $
              Aeson.object
                [ "Name" Aeson..= dockerMutationVolumeName volume
                , "Driver" Aeson..= ("local" :: String)
                , "DriverOpts" Aeson..= dockerMutationVolumeOptions volume
                , "Labels" Aeson..= mutationVolumeLabels volume
                ]
      }

removeDockerSessionMutationVolume
  :: DockerSession -> DockerMutationVolume -> IO Bool -> IO DockerNodeVarRemoveResult
removeDockerSessionMutationVolume session volume stable
  | validMutationVolume volume =
      removeDockerSessionVolume session (dockerMutationVolumeName volume) stable stable
  | otherwise = pure DockerNodeVarRemoveNotStarted

mutationVolumeLabels :: DockerMutationVolume -> Map.Map String String
mutationVolumeLabels volume = Map.singleton "io.prodbox.mutation-volume-owner" (dockerMutationVolumeOwner volume)

matchMutationVolume :: DockerMutationVolume -> Aeson.Value -> Maybe String
matchMutationVolume volume =
  either (const Nothing) Just
    . parseEither
      ( Aeson.withObject "bound mutation output volume" $ \object -> do
          name <- object .: "Name"
          driver <- object .: "Driver"
          scope <- object .: "Scope"
          options <- object .: "Options"
          labels <- object .: "Labels"
          created <- object .: "CreatedAt"
          if name == dockerMutationVolumeName volume
            && (driver :: String) == "local"
            && (scope :: String) == "local"
            && options == dockerMutationVolumeOptions volume
            && labels == mutationVolumeLabels volume
            && not (null created)
            && length created <= 64
            then pure created
            else fail "different mutation volume"
      )

-- | Bind a running keeper's host PID to one verified storage mount. The
-- caller still holds and verifies the corresponding process and filesystem descriptors.
readDockerSessionMutationHolder
  :: DockerSession
  -> String
  -> String
  -> String
  -> DockerMutationVolume
  -> IO (Either DockerConnectedInfoFailure Int)
readDockerSessionMutationHolder session identifier image user volume
  | not (validImageId ("sha256:" ++ identifier) && validImageId image && validMutationVolume volume) =
      pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      observed <- readMutationDockerJson session (dockerGet path) 200 ""
      pure $ case observed of
        Right (Just found) -> either (const (Left DockerConnectedInfoInvalid)) Right (parseEither parseHolder found)
        Right Nothing -> Left DockerConnectedInfoStatus
        Left failure -> Left failure
 where
  path = BS8.pack ("/containers/" ++ identifier ++ "/json")
  parseHolder = Aeson.withObject "mutation output holder" $ \container -> do
    actual <- container .: "Id"
    actualImage <- container .: "Image"
    config <- container .: "Config"
    actualUser <- config .: "User"
    host <- container .: "HostConfig"
    net <- host .: "NetworkMode"
    readOnly <- host .: "ReadonlyRootfs"
    state <- container .: "State"
    running <- state .: "Running"
    pid <- state .: "Pid"
    mounts <- container .: "Mounts"
    case mounts of
      [mounted] -> do
        kind <- mounted .: "Type"
        name <- mounted .: "Name"
        pathInside <- mounted .: "Destination"
        writable <- mounted .: "RW"
        if actual == identifier
          && actualImage == image
          && actualUser == user
          && (net :: String) == "none"
          && readOnly
          && running
          && pid > 0
          && (kind :: String) == "volume"
          && name == dockerMutationVolumeName volume
          && (pathInside :: String) == "/quota"
          && not writable
          then pure pid
          else fail "different mutation holder"
      _ -> fail "different mutation mounts"

readMutationDockerJson
  :: DockerSession
  -> HTTP.Request
  -> Int
  -> String
  -> IO (Either DockerConnectedInfoFailure (Maybe Aeson.Value))
readMutationDockerJson (DockerSession manager) request expected notFound = do
  result <- try (HTTP.withResponse request manager decode)
  pure (either (\(_ :: HTTP.HttpException) -> Left DockerConnectedInfoTransport) id result)
 where
  decode response
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        let status = statusCode (HTTP.responseStatus response)
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right validated) | value == validated && status == expected -> Right (Just value)
              (Right value, Right validated)
                | value == validated && status == 404 && not (null notFound) ->
                    if parseEither (Aeson.withObject "Docker volume not found" (\fields -> fields .: "message")) value
                      == Right notFound
                      then Right Nothing
                      else Left DockerConnectedInfoInvalid
              _ -> Left DockerConnectedInfoInvalid

-- | Read the deterministic candidate volume over an already held connection.
-- The operation owner must independently establish daemon and scope identity,
-- observe prior attempts and settle workers before relying on this read.
inspectDockerSessionNodeVarVolume
  :: DockerSession
  -> BootstrapProjection
  -> String
  -> IO (Either DockerConnectedInfoFailure DockerNodeVarVolumeObservation)
inspectDockerSessionNodeVarVolume (DockerSession manager) bootstrap operation =
  case kindNodeVarVolumeName
    (bootstrapKindPlan bootstrap)
    (Text.unpack (bootstrapRootGeneration bootstrap))
    operation of
    Nothing -> pure (Left DockerConnectedInfoInvalid)
    Just name -> do
      result <-
        try (HTTP.withResponse (dockerGet (BS8.pack ("/volumes/" ++ name))) manager (readVolume name))
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          ( result
              :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNodeVarVolumeObservation)
          )
 where
  readVolume name response
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case (statusCode (HTTP.responseStatus response), body) of
          (_, Nothing) -> pure (Left DockerConnectedInfoTooLarge)
          (404, Just _) -> pure (Right DockerNodeVarVolumeNotFound)
          (200, Just bytes) -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerNodeVarVolume bootstrap operation name value)
              _ -> Left DockerConnectedInfoInvalid
          _ -> pure (Left DockerConnectedInfoStatus)

-- | Compare only an exact expected name and closed local-driver configuration.
-- A label match does not prove which operation created the volume.
parseDockerNodeVarVolume
  :: BootstrapProjection
  -> String
  -> String
  -> Aeson.Value
  -> Either String DockerNodeVarVolumeObservation
parseDockerNodeVarVolume bootstrap operation expectedName = parseEither $ Aeson.withObject "Docker node volume" $ \volume -> do
  name <- volume .: "Name"
  driver <- volume .: "Driver"
  scope <- volume .: "Scope"
  labels <- (maybe Map.empty id <$> volume .:? "Labels") :: Parser (Map.Map String String)
  options <- volume .: "Options"
  let expected =
        kindNodeVarVolumeName
          (bootstrapKindPlan bootstrap)
          (Text.unpack (bootstrapRootGeneration bootstrap))
          operation
      safe value = length value <= 1024 && all (\character -> isAscii character && isPrint character) value
      labelsSafe =
        Map.size labels <= 64
          && all (\(key, value) -> not (null key) && safe key && safe value) (Map.toList labels)
      noOptions = case options of
        Aeson.Null -> True
        Aeson.Object entries -> KeyMap.null entries
        _ -> False
      expectedLabels =
        kindNodeVarVolumeLabels
          (bootstrapKindPlan bootstrap)
          (Text.unpack (bootstrapRootGeneration bootstrap))
          operation
      matches =
        driver == ("local" :: String)
          && scope == ("local" :: String)
          && noOptions
          && maybe False (all (\(key, value) -> Map.lookup key labels == Just value) . Map.toList) expectedLabels
  if expected /= Just expectedName || name /= expectedName || not labelsSafe
    then fail "invalid Docker node volume response"
    else pure (if matches then DockerNodeVarVolumeMatching else DockerNodeVarVolumeConflict)

readKindInfo
  :: String -> HTTP.Response HTTP.BodyReader -> IO (Either DockerConnectedInfoFailure DockerKindInfo)
readKindInfo expected response
  | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
  | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
  | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      case body of
        Nothing -> pure (Left DockerConnectedInfoTooLarge)
        Just bytes -> do
          checked <- decodeBoundedYamlValue bytes
          pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
            (Right value, Right valid)
              | value == valid ->
                  either (const (Left DockerConnectedInfoInvalid)) Right (parseEither parseKindInfo value)
            _ -> Left DockerConnectedInfoInvalid
 where
  parseKindInfo = Aeson.withObject "Docker kind info" $ \object -> do
    identifier <- object .: "ID"
    driver <- object .: "CgroupDriver"
    version <- object .: "CgroupVersion"
    memory <- object .: "MemoryLimit"
    pids <- object .: "PidsLimit"
    cpu <- object .: "CPUShares"
    options <- object .: "SecurityOptions"
    if identifier /= expected
      || parseDockerDaemonId (BS8.unpack (BL.toStrict (Aeson.encode (identifier :: String))))
        /= Just expected
      || not (validInfoWord 64 driver && validInfoWord 64 version)
      || length options > 64
      || any (not . validInfoWord 256) options
      then fail "invalid or changed Docker kind info"
      else pure (DockerKindInfo driver version memory pids cpu options)
  validInfoWord limit word =
    not (null word)
      && length word <= limit
      && all (\character -> isAscii character && isPrint character) word

-- | Read names selected by the exact cluster label over the held session.
-- An empty result is a point observation, not proof of absence or ownership.
readDockerSessionKindContainers
  :: DockerSession -> DeploymentScope -> IO (Either DockerConnectedInfoFailure [String])
readDockerSessionKindContainers (DockerSession manager) scope = do
  let cluster = scopeKindName scope
      filters =
        BL.toStrict (Aeson.encode (Aeson.object ["label" Aeson..= ["io.x-k8s.kind.cluster=" ++ cluster]]))
      request =
        (dockerGet "/containers/json")
          { HTTP.queryString = renderQuery True [("all", Just "1"), ("filters", Just filters)]
          }
  result <- try (HTTP.withResponse request manager (readKindContainers scope))
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure [String]))

-- | A bounded name-filtered observation, not proof of ownership or absence.
-- The full response is validated rather than silently filtering foreign rows.
readDockerSessionKindNetworks
  :: DockerSession -> DeploymentScope -> IO (Either DockerConnectedInfoFailure [String])
readDockerSessionKindNetworks session scope =
  readDockerSessionNetworkNamed session (scopeKindName scope)

-- Exercise the same name inventory against Docker's built-in bridge before
-- reading the selected scope. An invisible control leaves the read unknown.
readDockerSessionKindNetworksControlled
  :: DockerSession -> DeploymentScope -> IO (Either DockerConnectedInfoFailure (Maybe [String]))
readDockerSessionKindNetworksControlled session scope = do
  positive <- readDockerSessionNetworkNamed session "bridge"
  case positive of
    Right [_] -> fmap Just <$> readDockerSessionKindNetworks session scope
    Right [] -> pure (Right Nothing)
    Right _ -> pure (Left DockerConnectedInfoInvalid)
    Left failure -> pure (Left failure)

readDockerSessionNetworkNamed
  :: DockerSession -> String -> IO (Either DockerConnectedInfoFailure [String])
readDockerSessionNetworkNamed session name =
  let filters = BL.toStrict (Aeson.encode (Aeson.object ["name" Aeson..= ["^" ++ name ++ "$"]]))
   in readDockerSessionNetworkInventory session name filters

-- | Observe an exact full ID through a separate Docker inventory query.
-- Empty is a point observation only, not proof of absence or settlement.
readDockerSessionKindNetworkId
  :: DockerSession -> DeploymentScope -> String -> IO (Either DockerConnectedInfoFailure Bool)
readDockerSessionKindNetworkId session scope identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      let filters = BL.toStrict (Aeson.encode (Aeson.object ["id" Aeson..= [identifier]]))
      observed <- readDockerSessionNetworkInventory session (scopeKindName scope) filters
      pure $ case observed of
        Left failure -> Left failure
        Right [] -> Right False
        Right [actual] | actual == identifier -> Right True
        _ -> Left DockerConnectedInfoInvalid

-- | First verify that this same ID-filtered query can see Docker's built-in
-- bridge. Nothing means the control was blind; False remains a point read.
readDockerSessionKindNetworkIdControlled
  :: DockerSession -> DeploymentScope -> String -> IO (Either DockerConnectedInfoFailure (Maybe Bool))
readDockerSessionKindNetworkIdControlled session@(DockerSession manager) scope identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <- try (HTTP.withResponse (dockerGet "/networks/bridge") manager readBridge)
      case result of
        Left (_ :: HTTP.HttpException) -> pure (Left DockerConnectedInfoTransport)
        Right (Left failure) -> pure (Left failure)
        Right (Right bridgeId)
          | bridgeId == identifier -> pure (Left DockerConnectedInfoInvalid)
          | otherwise -> do
              let filters = BL.toStrict (Aeson.encode (Aeson.object ["id" Aeson..= [bridgeId]]))
              control <- readDockerSessionNetworkInventory session "bridge" filters
              case control of
                Left failure -> pure (Left failure)
                Right [actual] | actual == bridgeId -> fmap Just <$> readDockerSessionKindNetworkId session scope identifier
                Right [] -> pure (Right Nothing)
                _ -> pure (Left DockerConnectedInfoInvalid)
 where
  readBridge response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either (const (Left DockerConnectedInfoInvalid)) Right (parseDockerBridgeId value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerBridgeId :: Aeson.Value -> Either String String
parseDockerBridgeId = parseEither $ Aeson.withObject "Docker bridge" $ \network -> do
  name <- network .: "Name"
  driver <- network .: "Driver"
  identifier <- network .: "Id"
  if (name :: String) == "bridge"
    && (driver :: String) == "bridge"
    && validImageId ("sha256:" ++ identifier)
    then pure identifier
    else fail "invalid Docker bridge control"

readDockerSessionNetworkInventory
  :: DockerSession -> String -> BS.ByteString -> IO (Either DockerConnectedInfoFailure [String])
readDockerSessionNetworkInventory (DockerSession manager) expectedName filters = do
  let
    request = (dockerGet "/networks") {HTTP.queryString = renderQuery True [("filters", Just filters)]}
  result <- try (HTTP.withResponse request manager readNetworks)
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure [String]))
 where
  readNetworks response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerNetworksByName expectedName value)
              _ -> Left DockerConnectedInfoInvalid

-- | Reject duplicates and foreign names; an ID alone does not imply ownership.
parseDockerKindNetworks :: DeploymentScope -> Aeson.Value -> Either String [String]
parseDockerKindNetworks scope = parseDockerNetworksByName (scopeKindName scope)

parseDockerNetworksByName :: String -> Aeson.Value -> Either String [String]
parseDockerNetworksByName expectedName = parseEither $ Aeson.withArray "Docker kind networks" parseEntries
 where
  parseEntries entries = case foldr (:) [] entries of
    [] -> pure []
    [entry] -> (: []) <$> Aeson.withObject "Docker network" parseNetwork entry
    _ -> fail "multiple kind networks"
  parseNetwork network = do
    name <- network .: "Name"
    identifier <- network .: "Id"
    if name == expectedName && validImageId ("sha256:" ++ identifier)
      then pure identifier
      else fail "foreign or invalid kind network"

-- | A bounded configuration observation, not evidence of ownership or
-- settlement. Labels and subnet strings still require separate interpretation.
data DockerNetworkDetails = DockerNetworkDetails
  { dockerNetworkId :: !String
  , dockerNetworkDriver :: !String
  , dockerNetworkIpv6 :: !Bool
  , dockerNetworkSubnets :: ![String]
  , dockerNetworkOptions :: !(Map.Map String String)
  , dockerNetworkLabels :: !(Map.Map String String)
  }
  deriving (Eq, Show)

data DockerNetworkCreateResult
  = DockerNetworkCreateNotStarted
  | DockerNetworkCreateUnconfirmed
  | DockerNetworkCreateReply !Int !(Maybe String)
  deriving (Eq, Show)

data DockerNetworkRemoveResult
  = DockerNetworkRemoveNotStarted
  | DockerNetworkRemoveUnconfirmed
  | DockerNetworkRemoveReply !Int
  deriving (Eq, Show)

-- | Send one deletion request for a full ID on the held session. The caller
-- must separately prove exact ownership, admission, daemon and worker
-- settlement, persist the cleanup attempt first, and independently read back
-- absence. Even a 204 or 404 is a transport response, not absence evidence.
removeDockerSessionKindNetwork
  :: DockerSession -> String -> IO Bool -> IO DockerNetworkRemoveResult
removeDockerSessionKindNetwork (DockerSession manager) identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure DockerNetworkRemoveNotStarted
  | otherwise = do
      ready <- try stable
      case ready of
        Left (_ :: IOException) -> pure DockerNetworkRemoveNotStarted
        Right False -> pure DockerNetworkRemoveNotStarted
        Right True -> do
          let request =
                (dockerGet (BS8.pack ("/networks/" ++ identifier)))
                  { HTTP.method = "DELETE"
                  , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
                  }
          received <- try (try (HTTP.withResponse request manager readRemoval))
          case received of
            Left (_ :: IOException) -> pure DockerNetworkRemoveUnconfirmed
            Right (Left (_ :: HTTP.HttpException)) -> pure DockerNetworkRemoveUnconfirmed
            Right (Right reply) -> do
              after <- try stable
              pure $ case (reply, after :: Either IOException Bool) of
                (Just result, Right True) -> DockerNetworkRemoveReply result
                _ -> DockerNetworkRemoveUnconfirmed
 where
  readRemoval response
    | statusCode (HTTP.responseStatus response) == 204 =
        let lengths = [value | (name, value) <- HTTP.responseHeaders response, name == hContentLength]
            encodings = [value | (name, value) <- HTTP.responseHeaders response, name == hTransferEncoding]
         in pure $ if null encodings && (null lengths || lengths == ["0"]) then Just 204 else Nothing
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        pure (statusCode (HTTP.responseStatus response) <$ body)

-- | Send one scoped request on the held connection. The caller must first
-- establish admission, bind the daemon, persist and recheck the exact attempt,
-- exclude competing writers, and settle/recover daemon effects. A reply is
-- transport evidence only and never proves ownership or resource presence.
createDockerSessionKindNetwork
  :: DockerSession -> BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO DockerNetworkCreateResult
createDockerSessionKindNetwork (DockerSession manager) bootstrap intent stable = do
  ready <- try stable
  case ready of
    Left (_ :: IOException) -> pure DockerNetworkCreateNotStarted
    Right False -> pure DockerNetworkCreateNotStarted
    Right True -> do
      let options =
            Aeson.object $
              ("com.docker.network.bridge.enable_ip_masquerade" Aeson..= ("true" :: String))
                : maybe [] (\mtu -> ["com.docker.network.driver.mtu" Aeson..= show mtu]) (kindNetworkMtu intent)
          labels =
            Aeson.object
              [ "io.prodbox.deployment" Aeson..= scopeKindName (bootstrapScope bootstrap)
              , "io.prodbox.generation" Aeson..= bootstrapRootGeneration bootstrap
              , "io.prodbox.operation" Aeson..= kindNetworkOperation intent
              ]
          payload =
            Aeson.encode $
              Aeson.object
                [ "Name" Aeson..= scopeKindName (bootstrapScope bootstrap)
                , "CheckDuplicate" Aeson..= True
                , "Driver" Aeson..= ("bridge" :: String)
                , "EnableIPv6" Aeson..= True
                , "Options" Aeson..= options
                , "Labels" Aeson..= labels
                , "IPAM"
                    Aeson..= Aeson.object
                      ["Config" Aeson..= [Aeson.object ["Subnet" Aeson..= kindNetworkSubnet intent]]]
                ]
          request =
            (dockerGet "/networks/create")
              { HTTP.method = "POST"
              , HTTP.requestHeaders = [("Content-Type", "application/json")]
              , HTTP.requestBody = HTTP.RequestBodyLBS payload
              , HTTP.responseTimeout = HTTP.responseTimeoutMicro 30000000
              }
      received <- try (try (HTTP.withResponse request manager readCreate))
      case received of
        Left (_ :: IOException) -> pure DockerNetworkCreateUnconfirmed
        Right (Left (_ :: HTTP.HttpException)) -> pure DockerNetworkCreateUnconfirmed
        Right (Right reply) -> do
          after <- try stable
          pure $ case (reply, after :: Either IOException Bool) of
            (Just result, Right True) -> result
            _ -> DockerNetworkCreateUnconfirmed
 where
  readCreate response
    | not (framed response) = pure Nothing
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure Nothing
          Just bytes
            | statusCode (HTTP.responseStatus response) /= 201 ->
                pure (Just (DockerNetworkCreateReply (statusCode (HTTP.responseStatus response)) Nothing))
            | otherwise -> do
                checked <- decodeBoundedYamlValue bytes
                pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
                  (Right value, Right validated) | value == validated ->
                    case parseEither (Aeson.withObject "network create" (.: "Id")) value of
                      Right identifier | validImageId ("sha256:" ++ identifier) -> Just (DockerNetworkCreateReply 201 (Just identifier))
                      _ -> Nothing
                  _ -> Nothing

-- | Read one full network ID over the held session; errors and 404 do not
-- prove absence. The matching name and ID alone do not prove ownership.
inspectDockerSessionKindNetwork
  :: DockerSession
  -> DeploymentScope
  -> String
  -> IO (Either DockerConnectedInfoFailure DockerNetworkDetails)
inspectDockerSessionKindNetwork (DockerSession manager) scope identifier
  | not (validImageId ("sha256:" ++ identifier)) = pure (Left DockerConnectedInfoInvalid)
  | otherwise = do
      result <-
        try (HTTP.withResponse (dockerGet (BS8.pack ("/networks/" ++ identifier))) manager readNetwork)
      pure $
        either
          (const (Left DockerConnectedInfoTransport))
          id
          (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure DockerNetworkDetails))
 where
  readNetwork response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either
                      (const (Left DockerConnectedInfoInvalid))
                      Right
                      (parseDockerNetworkDetails scope identifier value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerNetworkDetails
  :: DeploymentScope -> String -> Aeson.Value -> Either String DockerNetworkDetails
parseDockerNetworkDetails scope identifier = parseEither $ Aeson.withObject "Docker network" $ \network -> do
  name <- network .: "Name"
  actualId <- network .: "Id"
  driver <- network .: "Driver"
  ipv6 <- network .: "EnableIPv6"
  options <- maybe Map.empty id <$> network .:? "Options"
  labels <- maybe Map.empty id <$> network .:? "Labels"
  ipam <- network .: "IPAM"
  subnets <-
    Aeson.withObject
      "Docker network IPAM"
      ( \fields -> do
          entries <- maybe [] id <$> fields .:? "Config"
          traverse (Aeson.withObject "Docker network IPAM entry" (.:? "Subnet")) entries
      )
      ipam
  let present = [subnet | Just subnet <- subnets]
      safeText limit value = length value <= limit && all (\c -> isAscii c && isPrint c) value
      safeMap values =
        Map.size values <= 64
          && all (\(key, value) -> not (null key) && safeText 256 key && safeText 1024 value) (Map.toList values)
  if not (validImageId ("sha256:" ++ identifier))
    || name /= scopeKindName scope
    || actualId /= identifier
    || null driver
    || not (safeText 64 driver)
    || length subnets > 16
    || any (\subnet -> null subnet || not (safeText 128 subnet)) present
    || not (safeMap options && safeMap labels)
    then fail "invalid or foreign Docker network"
    else pure (DockerNetworkDetails identifier driver ipv6 present options labels)

-- | Read only the built-in bridge's MTU option. This observes configuration,
-- not ownership or permission to use or modify any network.
readDockerSessionBridgeMtu :: DockerSession -> IO (Either DockerConnectedInfoFailure (Maybe Int))
readDockerSessionBridgeMtu (DockerSession manager) = do
  result <- try (HTTP.withResponse (dockerGet "/networks/bridge") manager readBridge)
  pure $
    either
      (const (Left DockerConnectedInfoTransport))
      id
      (result :: Either HTTP.HttpException (Either DockerConnectedInfoFailure (Maybe Int)))
 where
  readBridge response
    | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
    | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
    | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
    | otherwise = do
        body <- collectBody 65536 (HTTP.responseBody response)
        case body of
          Nothing -> pure (Left DockerConnectedInfoTooLarge)
          Just bytes -> do
            checked <- decodeBoundedYamlValue bytes
            pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
              (Right value, Right valid)
                | value == valid ->
                    either (const (Left DockerConnectedInfoInvalid)) Right (parseDockerBridgeMtu value)
              _ -> Left DockerConnectedInfoInvalid

parseDockerBridgeMtu :: Aeson.Value -> Either String (Maybe Int)
parseDockerBridgeMtu = parseEither $ Aeson.withObject "Docker bridge" $ \network -> do
  name <- network .: "Name"
  driver <- network .: "Driver"
  options <- network .: "Options"
  if (name :: String) /= "bridge" || (driver :: String) /= "bridge"
    then fail "unexpected Docker bridge"
    else Aeson.withObject "Docker bridge options" parseOptions options
 where
  parseOptions options = case KeyMap.lookup "com.docker.network.driver.mtu" options of
    Nothing -> pure Nothing
    Just value ->
      Aeson.withText
        "Docker bridge MTU"
        ( \raw ->
            let text = Text.unpack raw
             in case readMaybe text of
                  Just number | show (number :: Int) == text && number >= 68 && number <= 65535 -> pure (Just number)
                  _ -> fail "invalid Docker bridge MTU"
        )
        value

readKindContainers
  :: DeploymentScope -> HTTP.Response HTTP.BodyReader -> IO (Either DockerConnectedInfoFailure [String])
readKindContainers scope response
  | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
  | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
  | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      case body of
        Nothing -> pure (Left DockerConnectedInfoTooLarge)
        Just bytes -> do
          checked <- decodeBoundedYamlValue bytes
          pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
            (Right value, Right valid)
              | value == valid ->
                  either (const (Left DockerConnectedInfoInvalid)) Right (parseDockerKindContainers scope value)
            _ -> Left DockerConnectedInfoInvalid

-- | Refuse foreign labels, unexpected names and extra containers instead of
-- filtering them out and accidentally turning ambiguity into absence.
parseDockerKindContainers :: DeploymentScope -> Aeson.Value -> Either String [String]
parseDockerKindContainers scope = parseEither $ Aeson.withArray "Docker kind containers" parseEntries
 where
  parseEntries entries = case foldr (:) [] entries of
    [] -> pure []
    [entry] -> (: []) <$> parseContainer entry
    _ -> fail "multiple kind containers"
  cluster = scopeKindName scope
  expectedName = cluster ++ "-control-plane"
  parseContainer = Aeson.withObject "Docker kind container" $ \container -> do
    identifier <- container .: "Id"
    names <- container .: "Names"
    labels <- container .: "Labels"
    label <- Aeson.withObject "Docker labels" (.: "io.x-k8s.kind.cluster") labels
    if not (validImageId ("sha256:" ++ identifier)) || label /= cluster || names /= ["/" ++ expectedName]
      then fail "foreign or ambiguous kind container"
      else pure expectedName

-- A reply is only transport evidence. Docker can return errors within a 200
-- response, and neither a reply nor a disconnect settles a previous worker.
data DockerImageLoadStream
  = DockerImageLoadMessages !Int
  | DockerImageLoadErrorMessage
  | DockerImageLoadInvalidStream
  deriving (Eq, Show)

data DockerImageLoadResult
  = DockerImageLoadNotStarted
  | DockerImageLoadUnconfirmed
  | DockerImageLoadReply !Int !DockerImageLoadStream
  deriving (Eq, Show)

-- | Send a held archive once, over the already selected connection. The caller
-- must independently establish admission, write the attempt marker first,
-- bind the descriptor and daemon, and settle/recover all daemon-side effects.
-- This primitive deliberately does not retry or interpret a response as a
-- successful image load. The callback and descriptor must not outlive the
-- enclosing operation and its lease.
loadDockerSessionImage :: DockerSession -> Fd -> Integer -> IO Bool -> IO DockerImageLoadResult
loadDockerSessionImage (DockerSession manager) descriptor size stable
  | size <= 0 || size > maximumDockerArchiveBytes = pure DockerImageLoadNotStarted
  | otherwise = do
      preflight <- try $ do
        status <- Files.getFdStatus descriptor
        ready <- stable
        if not (ready && Files.isRegularFile status && toInteger (Files.fileSize status) == size)
          then pure False
          else (== 0) <$> Posix.fdSeek descriptor AbsoluteSeek 0
      case preflight of
        Left (_ :: IOException) -> pure DockerImageLoadNotStarted
        Right False -> pure DockerImageLoadNotStarted
        Right True -> do
          remaining <- newIORef size
          let popper = do
                count <- readIORef remaining
                if count == 0
                  then pure BS.empty
                  else do
                    bytes <- PosixBytes.fdRead descriptor (fromInteger (min count 32768))
                    if BS.null bytes
                      then ioError (userError "short Docker image archive")
                      else do
                        writeIORef remaining (count - toInteger (BS.length bytes))
                        pure bytes
              request =
                (dockerGet "/images/load")
                  { HTTP.method = "POST"
                  , HTTP.queryString = "?quiet=1"
                  , HTTP.requestHeaders = [("Content-Type", "application/x-tar")]
                  , HTTP.requestBody = HTTP.RequestBodyStream (fromInteger size) (\consume -> consume popper)
                  , HTTP.responseTimeout = HTTP.responseTimeoutMicro 180000000
                  }
          received <- try (try (HTTP.withResponse request manager readLoadReply))
          case received of
            Left (_ :: IOException) -> pure DockerImageLoadUnconfirmed
            Right (Left (_ :: HTTP.HttpException)) -> pure DockerImageLoadUnconfirmed
            Right (Right reply) -> do
              unread <- readIORef remaining
              after <- try stable
              case (reply, unread, after :: Either IOException Bool) of
                (Just (status, body), 0, Right True) -> DockerImageLoadReply status <$> classifyDockerImageLoadStream body
                _ -> pure DockerImageLoadUnconfirmed

-- | Parse bounded line-delimited Docker progress messages without exposing
-- provider-supplied text. Even a clean stream is not independent image
-- read-back, daemon authentication, or a worker-settlement witness.
classifyDockerImageLoadStream :: BS.ByteString -> IO DockerImageLoadStream
classifyDockerImageLoadStream bytes
  | BS.length bytes > 65536 || null messages || length messages > 1024 =
      pure DockerImageLoadInvalidStream
  | otherwise = do
      decoded <- traverse decodeMessage messages
      pure $
        if Nothing `elem` decoded
          then DockerImageLoadInvalidStream
          else
            if Just True `elem` decoded
              then DockerImageLoadErrorMessage
              else DockerImageLoadMessages (length messages)
 where
  messages = filter (not . BS8.all isSpace) (BS8.lines bytes)
  decodeMessage message = do
    checked <- decodeBoundedYamlValue message
    pure $ case (Aeson.eitherDecodeStrict' message, checked) of
      (Right (Aeson.Object object), Right value)
        | Aeson.Object object == value ->
            if any (nonNull object) ["error", "errorDetail"]
              then Just True
              else if any (textField object) ["stream", "status"] then Just False else Nothing
      _ -> Nothing
  nonNull object key = case KeyMap.lookup key object of
    Nothing -> False
    Just Aeson.Null -> False
    Just _ -> True
  textField object key = case KeyMap.lookup key object of
    Just (Aeson.String _) -> True
    _ -> False

readLoadReply :: HTTP.Response HTTP.BodyReader -> IO (Maybe (Int, BS.ByteString))
readLoadReply response
  | not (framed response) = pure Nothing
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      pure ((statusCode (HTTP.responseStatus response),) <$> body)

-- | The lookup is a second request on the same borrowed session. It is not
-- an independent observer, proof of ownership, or settlement of a lost reply.
data DockerImageReadback
  = DockerImageReadbackSkipped
  | DockerImageReadbackStable !(Either DockerConnectedInfoFailure ImageIdObservation)
  | DockerImageReadbackChanged !(Either DockerConnectedInfoFailure ImageIdObservation)
  deriving (Eq, Show)

data DockerImageSubmissionObservation = DockerImageSubmissionObservation
  { submissionTransport :: !DockerImageLoadResult
  , submissionImage :: !DockerImageReadback
  }
  deriving (Eq, Show)

-- | A caller must establish admission and durable attempt recording first.
-- Preserve both the load result and the exact-ID observation independently;
-- a failed or uncertain load must never be relabeled by a later image read.
loadAndObserveDockerSessionImage
  :: DockerSession -> Fd -> Integer -> String -> IO Bool -> IO DockerImageSubmissionObservation
loadAndObserveDockerSessionImage session descriptor size identifier stable
  | not (validImageId identifier) =
      pure (DockerImageSubmissionObservation DockerImageLoadNotStarted DockerImageReadbackSkipped)
  | otherwise = do
      outcome <- loadDockerSessionImage session descriptor size stable
      image <- case outcome of
        DockerImageLoadNotStarted -> pure DockerImageReadbackSkipped
        _ -> do
          ready <- try stable
          case ready of
            Right True -> do
              observed <- inspectDockerSessionImage session identifier
              after <- try stable
              pure $ case after of
                Right True -> DockerImageReadbackStable observed
                (_ :: Either IOException Bool) -> DockerImageReadbackChanged observed
            (_ :: Either IOException Bool) -> pure DockerImageReadbackSkipped
      pure (DockerImageSubmissionObservation outcome image)

readImage
  :: String -> HTTP.Response HTTP.BodyReader -> IO (Either DockerConnectedInfoFailure ImageIdObservation)
readImage identifier response
  | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
  | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      case body of
        Nothing -> pure (Left DockerConnectedInfoTooLarge)
        Just _ | statusCode (HTTP.responseStatus response) /= 200 -> pure (Left DockerConnectedInfoStatus)
        Just bytes -> do
          checked <- decodeBoundedYamlValue bytes
          pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
            (Right value, Right valid)
              | value == valid ->
                  either (const (Left DockerConnectedInfoInvalid)) Right (parseImageIdObservation identifier value)
            _ -> Left DockerConnectedInfoInvalid

readPing :: HTTP.Response HTTP.BodyReader -> IO (Either DockerConnectedInfoFailure ())
readPing response
  | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
  | not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
  | not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
  | otherwise = do
      body <- collectBody 2 (HTTP.responseBody response)
      pure (if body == Just "OK" then Right () else Left DockerConnectedInfoInvalid)

readResponse
  :: Bool -> HTTP.Response HTTP.BodyReader -> IO (Either DockerConnectedInfoFailure String)
readResponse requirePersistent response
  | statusCode (HTTP.responseStatus response) /= 200 = pure (Left DockerConnectedInfoStatus)
  | requirePersistent && not (persistent response) = pure (Left DockerConnectedInfoConnectionClosing)
  | requirePersistent && not (framed response) = pure (Left DockerConnectedInfoFramingInvalid)
  | otherwise = do
      body <- collectBody 65536 (HTTP.responseBody response)
      case body of
        Nothing -> pure (Left DockerConnectedInfoTooLarge)
        Just bytes -> do
          checked <- decodeBoundedYamlValue bytes
          pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
            (Right value, Right valid) | value == valid -> parseIdentifier value
            _ -> Left DockerConnectedInfoInvalid
 where
  parseIdentifier value = case parseEither (Aeson.withObject "Docker info" (.: "ID")) value of
    Left _ -> Left DockerConnectedInfoInvalid
    Right identifier -> case parseDockerDaemonId (BS8.unpack (BL.toStrict (Aeson.encode (identifier :: String)))) of
      Nothing -> Left DockerConnectedInfoInvalid
      Just valid -> Right valid

collectBody :: Int -> HTTP.BodyReader -> IO (Maybe BS.ByteString)
collectBody limit reader = go [] 0
 where
  go chunks count = do
    bytes <- HTTP.brReadSome reader (limit + 1 - count)
    let strict = BL.toStrict bytes
        total = count + BS.length strict
    if total > limit
      then pure Nothing
      else
        if BS.null strict
          then pure (Just (BS.concat (reverse chunks)))
          else go (strict : chunks) total

-- A server may close a connection at any time; this only rejects responses
-- that explicitly preclude reuse. It does not establish future liveness or
-- certify buffered bytes for a later effect.
persistent :: HTTP.Response body -> Bool
persistent response =
  HTTP.responseVersion response == http11
    && "close" `notElem` connectionTokens
 where
  connectionTokens =
    [ BS8.map toLower (BS8.dropWhileEnd isSpace (BS8.dropWhile isSpace token))
    | (name, value) <- HTTP.responseHeaders response
    , name == hConnection
    , token <- BS8.split ',' value
    ]

-- EOF-delimited bodies consume the connection; ambiguous framing must not be
-- handed to a caller as a reusable stream. The HTTP decoder still validates
-- the actual length or chunk syntax while reading the bounded response.
framed :: HTTP.Response body -> Bool
framed response = case (values hContentLength, values hTransferEncoding) of
  ([lengthValue], []) ->
    not (BS8.null lengthValue)
      && BS8.length lengthValue <= 20
      && BS8.all (\character -> character >= '0' && character <= '9') lengthValue
  ([], [encoding]) -> BS8.map toLower (BS8.dropWhileEnd isSpace (BS8.dropWhile isSpace encoding)) == "chunked"
  _ -> False
 where
  values header = [value | (name, value) <- HTTP.responseHeaders response, name == header]
