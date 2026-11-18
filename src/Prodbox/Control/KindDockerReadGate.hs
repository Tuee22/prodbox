{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A fail-closed, serialized classifier for the read-only Docker requests
-- currently understood by the kind adapter. This is not a sandbox, lifecycle
-- admission, daemon authentication, or an implementation of cluster creation.
module Prodbox.Control.KindDockerReadGate
  ( KindDockerReadGate
  , KindDockerReadRequest (..)
  , KindDockerReadResult (..)
  , newKindDockerReadGate
  , newKindInventoryReadGate
  , closeKindDockerReadGate
  , kindDockerInventoryObserved
  , runKindDockerRead
  , runConnectedKindDockerImageRead
  , KindDockerConnectedObservation (..)
  , runConnectedKindDockerRead
  , KindDockerReply (..)
  , runConnectedKindDockerReply
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (SomeException, evaluate, mask, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as LazyByteString
import Prodbox.Config.DeploymentScope (DeploymentScope, scopeKindName)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoFailure (DockerConnectedInfoInvalid)
  , DockerKindInfo (..)
  , DockerKindStorage (..)
  , DockerSession
  , inspectDockerSessionImage
  , readDockerSessionBridgeMtu
  , readDockerSessionKindContainers
  , readDockerSessionKindInfo
  , readDockerSessionKindNetworks
  , readDockerSessionKindStorage
  )
import Prodbox.Control.ImageIdObservation (ImageIdObservation, validImageId)

data KindDockerReadRequest
  = KindDockerInfo
  | KindDockerClusterInventory
  | KindDockerClusterContainers !String
  | KindDockerImage !String
  | KindDockerNetworks !String
  | KindDockerBridgeMtu
  | KindDockerSecurityOptions
  | KindDockerStorageDriver
  | KindDockerStorageStatus
  deriving (Eq, Show)

data KindDockerReadResult failure value
  = KindDockerReadRefused
  | KindDockerReadFailed !failure
  | KindDockerReadCompleted !value
  deriving (Eq, Show)

data KindDockerConnectedObservation
  = KindDockerProviderInfo !DockerKindInfo
  | KindDockerClusterLabels ![String]
  | KindDockerImageInfo !ImageIdObservation
  | KindDockerContainerNames ![String]
  | KindDockerNetworkIds ![String]
  | KindDockerBridgeMtuInfo !(Maybe Int)
  | KindDockerSecurityInfo ![String]
  | KindDockerStorageDriverInfo !String
  | KindDockerStorageStatusInfo !(Maybe [[String]])
  deriving (Eq, Show)

data KindDockerReply = KindDockerReply
  { kindDockerReplyExit :: !Int
  , kindDockerReplyStdout :: !ByteString.ByteString
  , kindDockerReplyStderr :: !ByteString.ByteString
  }
  deriving (Eq, Show)

data GateState = GateOpen !Bool | GateClosed !Bool

-- The state lock must cover both classification and the callback. In
-- particular, a later request cannot overtake an earlier refusal or failure.
data GatePolicy = AllKnownReads !String | InventoryOnly

data KindDockerReadGate = KindDockerReadGate !(MVar GateState) !DeploymentScope !GatePolicy

-- | The supplied image ID must already be bound to the inspected archive by
-- the caller. This constructor checks syntax and binds the deployment name.
newKindDockerReadGate :: DeploymentScope -> String -> IO (Maybe KindDockerReadGate)
newKindDockerReadGate scope imageId
  | validImageId imageId =
      Just . (\state -> KindDockerReadGate state scope (AllKnownReads imageId))
        <$> newMVar (GateOpen False)
  | otherwise = pure Nothing

-- | A selected-cluster inventory worker has no access to the other read
-- requests accepted by the general gate. The image syntax check is retained
-- until this internal worker no longer requires an image binding.
newKindInventoryReadGate :: DeploymentScope -> String -> IO (Maybe KindDockerReadGate)
newKindInventoryReadGate scope imageId
  | validImageId imageId =
      Just . (\state -> KindDockerReadGate state scope InventoryOnly) <$> newMVar (GateOpen False)
  | otherwise = pure Nothing

-- | Close before releasing a transport or after an interrupted exchange.
closeKindDockerReadGate :: KindDockerReadGate -> IO ()
closeKindDockerReadGate (KindDockerReadGate lock _ _) = modifyMVar_ lock close
 where
  close (GateOpen observed) = pure (GateClosed observed)
  close (GateClosed observed) = pure (GateClosed observed)

-- | Reports a successfully interpreted selected-cluster inventory request.
-- It does not prove that a reply was delivered or that the worker settled.
kindDockerInventoryObserved :: KindDockerReadGate -> IO Bool
kindDockerInventoryObserved (KindDockerReadGate lock _ _) = do
  state <- readMVar lock
  pure $ case state of
    GateOpen observed -> observed
    GateClosed observed -> observed

-- | Run only a recognized read request. Unknown or out-of-scope argv closes
-- the gate before returning refusal. A reported failure or callback exception
-- also closes it; exceptions are rethrown, including cancellation. The callback is trusted to
-- implement the typed request as a read, and must not retain the capability.
runKindDockerRead
  :: KindDockerReadGate
  -> [String]
  -> (KindDockerReadRequest -> IO (Either failure value))
  -> IO (KindDockerReadResult failure value)
runKindDockerRead (KindDockerReadGate lock scope policy) argv action = mask $ \restore -> do
  let handleState state = case state of
        GateClosed observed -> pure (GateClosed observed, Right KindDockerReadRefused)
        GateOpen observed -> case classifyPolicy policy (scopeKindName scope) argv of
          Nothing -> pure (GateClosed observed, Right KindDockerReadRefused)
          Just request -> do
            attempted <- try $ do
              result <- restore (action request)
              case result of
                Left failure -> evaluate failure >> pure (Left failure)
                Right value -> evaluate value >> pure (Right value)
            case attempted of
              Left failure -> pure (GateClosed observed, Left (failure :: SomeException))
              Right (Left failure) -> pure (GateClosed observed, Right (KindDockerReadFailed failure))
              Right (Right value) ->
                pure
                  ( GateOpen (observed || request == KindDockerClusterInventory)
                  , Right (KindDockerReadCompleted value)
                  )
  outcome <- modifyMVar lock handleState
  either throwIO pure outcome

classifyPolicy :: GatePolicy -> String -> [String] -> Maybe KindDockerReadRequest
classifyPolicy policy cluster argv = case policy of
  AllKnownReads imageId -> classify cluster imageId argv
  InventoryOnly -> case classify cluster "" argv of
    Just KindDockerClusterInventory -> Just KindDockerClusterInventory
    _ -> Nothing

-- | Interpret only exact image inspections on an already held Docker session.
-- Other otherwise recognized reads fail and close the gate until they have
-- an explicitly implemented interpreter. The caller still owns session
-- stability, daemon authentication, admission and worker settlement.
runConnectedKindDockerImageRead
  :: KindDockerReadGate
  -> DockerSession
  -> [String]
  -> IO (KindDockerReadResult DockerConnectedInfoFailure ImageIdObservation)
runConnectedKindDockerImageRead gate session argv =
  runKindDockerRead gate argv interpret
 where
  interpret request = case request of
    KindDockerImage imageId -> inspectDockerSessionImage session imageId
    KindDockerInfo -> pure (Left DockerConnectedInfoInvalid)
    KindDockerClusterInventory -> pure (Left DockerConnectedInfoInvalid)
    KindDockerClusterContainers _ -> pure (Left DockerConnectedInfoInvalid)
    KindDockerNetworks _ -> pure (Left DockerConnectedInfoInvalid)
    KindDockerBridgeMtu -> pure (Left DockerConnectedInfoInvalid)
    KindDockerSecurityOptions -> pure (Left DockerConnectedInfoInvalid)
    KindDockerStorageDriver -> pure (Left DockerConnectedInfoInvalid)
    KindDockerStorageStatus -> pure (Left DockerConnectedInfoInvalid)

-- | Interpret the supported reads on the held connection. A container list
-- is not proof of ownership or permission to mutate any returned resource.
runConnectedKindDockerRead
  :: KindDockerReadGate
  -> DockerSession
  -> String
  -> [String]
  -> IO (KindDockerReadResult DockerConnectedInfoFailure KindDockerConnectedObservation)
runConnectedKindDockerRead gate@(KindDockerReadGate _ scope _) session expectedDaemon argv =
  runKindDockerRead gate argv interpret
 where
  interpret request = case request of
    KindDockerInfo -> fmap KindDockerProviderInfo <$> readDockerSessionKindInfo session expectedDaemon
    KindDockerClusterInventory ->
      fmap (KindDockerClusterLabels . map (const (scopeKindName scope)))
        <$> readDockerSessionKindContainers session scope
    KindDockerImage imageId -> fmap KindDockerImageInfo <$> inspectDockerSessionImage session imageId
    KindDockerClusterContainers _ -> fmap KindDockerContainerNames <$> readDockerSessionKindContainers session scope
    KindDockerNetworks _ -> fmap KindDockerNetworkIds <$> readDockerSessionKindNetworks session scope
    KindDockerBridgeMtu -> fmap KindDockerBridgeMtuInfo <$> readDockerSessionBridgeMtu session
    KindDockerSecurityOptions ->
      fmap (KindDockerSecurityInfo . dockerKindSecurityOptions)
        <$> readDockerSessionKindInfo session expectedDaemon
    KindDockerStorageDriver ->
      fmap (KindDockerStorageDriverInfo . dockerKindStorageDriver)
        <$> readDockerSessionKindStorage session expectedDaemon
    KindDockerStorageStatus ->
      fmap (KindDockerStorageStatusInfo . dockerKindStorageStatus)
        <$> readDockerSessionKindStorage session expectedDaemon

-- | Project the already validated reads into the outputs consumed by the
-- pinned kind provider. This is not a broker or a mutation permit.
runConnectedKindDockerReply
  :: KindDockerReadGate -> DockerSession -> String -> [String] -> IO KindDockerReply
runConnectedKindDockerReply gate session expectedDaemon argv = do
  result <- runConnectedKindDockerRead gate session expectedDaemon argv
  pure $ case result of
    KindDockerReadRefused -> refused
    KindDockerReadFailed _ -> refused
    KindDockerReadCompleted observation -> KindDockerReply 0 (render observation) ByteString.empty
 where
  refused = KindDockerReply 1 ByteString.empty (Bytes.pack "Error: kind Docker request unavailable\n")
  render (KindDockerImageInfo _) = ByteString.empty
  render (KindDockerClusterLabels labels) = Bytes.pack (unlines labels)
  render (KindDockerContainerNames names) = Bytes.pack (unlines names)
  render (KindDockerNetworkIds identifiers) = Bytes.pack (unlines identifiers)
  render (KindDockerBridgeMtuInfo mtu) = Bytes.pack (maybe "<no value>\n" ((++ "\n") . show) mtu)
  render (KindDockerSecurityInfo options) = "'" <> LazyByteString.toStrict (Aeson.encode options) <> "'\n"
  render (KindDockerStorageDriverInfo driver) = Bytes.pack (driver ++ "\n")
  render (KindDockerStorageStatusInfo rows) = LazyByteString.toStrict (Aeson.encode rows) <> "\n"
  render (KindDockerProviderInfo info) =
    LazyByteString.toStrict $
      Aeson.encode $
        Aeson.object
          [ "CgroupDriver" Aeson..= dockerKindCgroupDriver info
          , "CgroupVersion" Aeson..= dockerKindCgroupVersion info
          , "MemoryLimit" Aeson..= dockerKindMemoryLimit info
          , "PidsLimit" Aeson..= dockerKindPidsLimit info
          , "CPUShares" Aeson..= dockerKindCpuShares info
          , "SecurityOptions" Aeson..= dockerKindSecurityOptions info
          ]

classify :: String -> String -> [String] -> Maybe KindDockerReadRequest
classify cluster imageId argv = case argv of
  ["info", "--format", "{{json .}}"] -> Just KindDockerInfo
  [ "ps"
    , "-a"
    , "--filter"
    , "label=io.x-k8s.kind.cluster"
    , "--format"
    , "{{.Label \"io.x-k8s.kind.cluster\"}}"
    ] -> Just KindDockerClusterInventory
  ["info", "--format", "'{{json .SecurityOptions}}'"] -> Just KindDockerSecurityOptions
  ["info", "-f", "{{.Driver}}"] -> Just KindDockerStorageDriver
  ["info", "-f", "{{json .DriverStatus }}"] -> Just KindDockerStorageStatus
  ["ps", "-a", "--filter", label, "--format", "{{.Names}}"]
    | label == "label=io.x-k8s.kind.cluster=" ++ cluster -> Just (KindDockerClusterContainers cluster)
  ["inspect", "--type=image", requested]
    | requested == imageId -> Just (KindDockerImage imageId)
  ["network", "ls", filterName, "--format={{.ID}}"]
    | filterName == "--filter=name=^" ++ cluster ++ "$" -> Just (KindDockerNetworks cluster)
  ["network", "inspect", "bridge", "-f", "{{ index .Options \"com.docker.network.driver.mtu\" }}"] -> Just KindDockerBridgeMtu
  _ -> Nothing
