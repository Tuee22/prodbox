{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only composition of a retained network attempt and a connected
-- Docker observation. This does not authorize a retry or settle a worker.
module Prodbox.Control.KindNetworkRecovery
  ( KindNetworkRecoveryResult (..)
  , KindNetworkRecoverySample (..)
  , KindNetworkConfigurationObservation (..)
  , KindNetworkIndependentObservation (..)
  , KindNetworkIndependentIdObservation (..)
  , compareKindNetworkConfiguration
  , observeRecoveredKindNetwork
  , observeRecordedNetworkAbsent
  , observeUnattemptedNetworkAbsent
  , priorNetworkRemovalRecorded
  , KindNetworkAttemptAction (..)
  , withNewConnectedKindNetworkAttempt
  , KindNetworkRemovalAction (..)
  , withNewConnectedKindNetworkRemoval
  , KindNetworkRecordedTransport (..)
  , withNewConnectedKindNetworkRecordedAttempt
  , withNewConnectedKindNetworkRecordedAttemptGuarded
  , runKindNetworkRecordedAttemptOnSession
  , withNewConnectedKindNetworkRecordedRemoval
  , withNewConnectedKindNetworkRecordedRemovalGuarded
  ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure (..)
  , DockerConnectedInfoResult (..)
  , DockerKindInfo
  , DockerNetworkCreateResult (..)
  , DockerNetworkDetails (..)
  , DockerNetworkRemoveResult (DockerNetworkRemoveReply)
  , DockerSession
  , inspectDockerSessionKindNetwork
  , parseDockerBridgeId
  , parseDockerNetworkDetails
  , readDockerSessionKindInfo
  , readDockerSessionKindNetworkIdControlled
  , readDockerSessionKindNetworks
  , readDockerSessionKindNetworksControlled
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (DockerDaemonObserved)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindLease (KindOperationOutcome, withRecoveredKindOperation)
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkAttemptObservation (..)
  , KindNetworkAttemptWrite (..)
  , KindNetworkIntent
  , KindNetworkIntentObservation (NetworkIntentMatches)
  , KindNetworkRecoveryObservation (..)
  , KindNetworkRemovalObservation (..)
  , KindNetworkRemovalRecovery (..)
  , KindNetworkRemovalWrite (..)
  , kindNetworkDaemon
  , kindNetworkMtu
  , kindNetworkOperation
  , kindNetworkSubnet
  , observeKindNetworkAttempt
  , observeKindNetworkIntent
  , observeKindNetworkRemoval
  , observeRecordedKindNetworkAttempt
  , observeRecordedKindNetworkIntent
  , observeRecordedKindNetworkRemoval
  , recordKindNetworkAttempt
  , recordKindNetworkRemoval
  , sameKindNetworkSubnet
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (..)
  , NetworkReceiptWrite (..)
  , NetworkTransport (..)
  , observeNetworkReceipt
  , recordNetworkReceipt
  )

priorNetworkRemovalRecorded :: NetworkReceiptObservation -> Bool
priorNetworkRemovalRecorded observed = case observed of
  NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)) -> True
  _ -> False

-- | The caller holds the operation and excludes create and removal results.
-- The proposal binds the daemon, whose bridge brackets the scoped name read.
observeUnattemptedNetworkAbsent :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO Bool
observeUnattemptedNetworkAbsent bootstrap intent held = do
  attempt <- observeKindNetworkAttempt bootstrap intent held
  if attempt /= NetworkAttemptMissing
    then pure False
    else do
      checked <- withConnectedDockerInfo 15000000 (bootstrapRuntimeSocket bootstrap) inspect
      pure (checked == DockerPeerCompleted (DockerConnectedInfoCompleted True))
 where
  inspect session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable = do
    before <- held
    if before && DockerDaemonObserved daemon identity == kindNetworkDaemon intent
      then do
        inventory <- readDockerSessionKindNetworksControlled session (bootstrapScope bootstrap)
        peer <- peerStable
        closing <- held
        pure (inventory == Right (Just []) && peer && closing)
      else pure False

-- | Confirm the bound receipt and require separate exact-ID and name reads.
-- The caller supplies the held operation and retirement admission check.
observeRecordedNetworkAbsent :: BootstrapProjection -> String -> IO Bool -> IO Bool
observeRecordedNetworkAbsent bootstrap operation held = do
  proposal <- observeRecordedKindNetworkIntent bootstrap operation held
  case proposal of
    NetworkRecoveryRecorded intent -> do
      created <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt held
      case created of
        NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId))) -> do
          receipt <- observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId) held
          if priorNetworkRemovalRecorded receipt
            then do
              absent <-
                withConnectedDockerInfo
                  30000000
                  (bootstrapRuntimeSocket bootstrap)
                  (inspectNetwork intent networkId)
              pure (absent == DockerPeerCompleted (DockerConnectedInfoCompleted True))
            else pure False
        _ -> pure False
    _ -> pure False
 where
  inspectNetwork intent networkId session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable = do
    before <- held
    if before && DockerDaemonObserved daemon identity == kindNetworkDaemon intent
      then do
        let scope = bootstrapScope bootstrap
        exact <- readDockerSessionKindNetworkIdControlled session scope networkId
        named <- readDockerSessionKindNetworks session scope
        peer <- peerStable
        closing <- held
        pure (exact == Right (Just False) && named == Right [] && peer && closing)
      else pure False

data KindNetworkRecoverySample = KindNetworkRecoverySample
  { networkAttemptBefore :: !KindNetworkAttemptObservation
  , networkCreateReceipt :: !NetworkReceiptObservation
  , networkRemovalBefore :: !KindNetworkRemovalRecovery
  , networkInventory :: !(Either DockerConnectedInfoFailure [String])
  , networkDetails :: !(Maybe (Either DockerConnectedInfoFailure DockerNetworkDetails))
  , networkConfiguration :: !KindNetworkConfigurationObservation
  , networkIndependent :: !KindNetworkIndependentObservation
  , networkDaemonAfter :: !(Either DockerConnectedInfoFailure DockerKindInfo)
  , networkAttemptAfter :: !KindNetworkAttemptObservation
  , networkRemovalAfter :: !KindNetworkRemovalRecovery
  , networkRemovalIdObservation :: !(Maybe (Either DockerConnectedInfoFailure (Maybe Bool)))
  , networkRemovalIndependentId :: !KindNetworkIndependentIdObservation
  , networkRemovalReceipt :: !NetworkReceiptObservation
  }
  deriving (Eq, Show)

data KindNetworkConfigurationObservation
  = NetworkConfigurationUnobserved
  | NetworkConfigurationMatches
  | NetworkConfigurationDiffers
  deriving (Eq, Show)

data KindNetworkIndependentObservation
  = NetworkIndependentUnobservable
  | NetworkIndependentObserved !DockerNetworkDetails
  | NetworkIndependentChanged !(Maybe DockerNetworkDetails)
  deriving (Eq, Show)

data KindNetworkIndependentIdObservation
  = NetworkIndependentIdUnobservable
  | NetworkIndependentIdBlind
  | NetworkIndependentIdObserved !Bool
  | NetworkIndependentIdChanged !(Maybe Bool)
  deriving (Eq, Show)

-- | Compare selected settings and labels only. A match is not provenance,
-- daemon authentication, settlement, or authorization to remove a resource.
compareKindNetworkConfiguration
  :: BootstrapProjection
  -> KindNetworkIntent
  -> DockerNetworkDetails
  -> KindNetworkConfigurationObservation
compareKindNetworkConfiguration bootstrap intent details =
  if dockerNetworkDriver details == "bridge"
    && dockerNetworkIpv6 details
    && ipv6SubnetsMatch
    && Map.lookup "com.docker.network.bridge.enable_ip_masquerade" options == Just "true"
    && Map.lookup "com.docker.network.driver.mtu" options == fmap show (kindNetworkMtu intent)
    && Map.lookup "io.prodbox.deployment" labels == Just (scopeKindName (bootstrapScope bootstrap))
    && Map.lookup "io.prodbox.generation" labels == Just (Text.unpack (bootstrapRootGeneration bootstrap))
    && Map.lookup "io.prodbox.operation" labels == Just (kindNetworkOperation intent)
    then NetworkConfigurationMatches
    else NetworkConfigurationDiffers
 where
  options = dockerNetworkOptions details
  labels = dockerNetworkLabels details
  ipv6SubnetsMatch = case filter (elem ':') (dockerNetworkSubnets details) of
    [subnet] -> sameKindNetworkSubnet (kindNetworkSubnet intent) subnet
    _ -> False

data KindNetworkRecoveryResult
  = KindNetworkRecoveryRecordRefused !KindNetworkRecoveryObservation
  | KindNetworkRecoveryDaemonMismatch
  | KindNetworkRecoverySampled !KindNetworkRecoverySample
  | KindNetworkRecoveryChangedAfter !KindNetworkRecoverySample
  deriving (Eq, Show)

data KindNetworkAttemptAction value
  = KindNetworkAttemptRecordRefused !KindNetworkRecoveryObservation
  | KindNetworkAttemptDaemonMismatch
  | KindNetworkAttemptMarkerRefused !KindNetworkAttemptWrite
  | KindNetworkAttemptReceiptRefused !NetworkReceiptObservation
  | KindNetworkAttemptChanged
  | KindNetworkAttemptReturned !value
  | KindNetworkAttemptChangedAfter !value
  deriving (Eq, Show)

data KindNetworkRemovalAction value
  = KindNetworkRemovalRecordRefused !KindNetworkRecoveryObservation
  | KindNetworkRemovalDaemonMismatch
  | KindNetworkRemovalCreateReceiptRefused !NetworkReceiptObservation
  | KindNetworkRemovalReadRefused !DockerConnectedInfoFailure
  | KindNetworkRemovalConfigurationDiffers
  | KindNetworkRemovalPrior !KindNetworkRemovalObservation
  | KindNetworkRemovalMarkerRefused !KindNetworkRemovalWrite
  | KindNetworkRemovalReceiptRefused !NetworkReceiptObservation
  | KindNetworkRemovalChanged
  | KindNetworkRemovalReturned !value
  | KindNetworkRemovalChangedAfter !value
  deriving (Eq, Show)

data KindNetworkRecordedTransport = KindNetworkRecordedTransport
  { networkTransport :: !NetworkTransport
  , networkReceiptWrite :: !NetworkReceiptWrite
  }
  deriving (Eq, Show)

-- | Preserve the actual transport observation and receipt-write outcome
-- independently. A missing receipt after interruption remains uncertain.
withNewConnectedKindNetworkRecordedAttempt
  :: BootstrapProjection
  -> String
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO DockerNetworkCreateResult)
  -> IO
       ( KindOperationOutcome
           (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction KindNetworkRecordedTransport)))
       )
withNewConnectedKindNetworkRecordedAttempt bootstrap operation =
  withNewConnectedKindNetworkRecordedAttemptGuarded bootstrap operation id

withNewConnectedKindNetworkRecordedAttemptGuarded
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO Bool)
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO DockerNetworkCreateResult)
  -> IO
       ( KindOperationOutcome
           (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction KindNetworkRecordedTransport)))
       )
withNewConnectedKindNetworkRecordedAttemptGuarded bootstrap operation admission action =
  withNewConnectedKindNetworkAttemptGuarded bootstrap operation admission $ \intent session stable -> do
    result <- action intent session stable
    let transport = NetworkCreateTransport result
    written <- recordNetworkReceipt bootstrap intent NetworkCreateReceipt transport stable
    pure (KindNetworkRecordedTransport transport written)

-- | Use an already held session and operation lease for a recorded network
-- attempt. The caller must authenticate the daemon, admit the effect, settle
-- prior work, and recover or clean up its exact resources.
runKindNetworkRecordedAttemptOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO DockerNetworkCreateResult)
  -> IO (KindNetworkAttemptAction KindNetworkRecordedTransport)
runKindNetworkRecordedAttemptOnSession bootstrap operation session info stable action =
  runKindNetworkAttemptOnSession bootstrap operation session info stable $ \intent held markerStable -> do
    result <- action intent held markerStable
    let transport = NetworkCreateTransport result
    written <- recordNetworkReceipt bootstrap intent NetworkCreateReceipt transport markerStable
    pure (KindNetworkRecordedTransport transport written)

-- | Preserve the removal response separately from a receipt failure; the
-- callback still requires admission, ownership and worker settlement.
withNewConnectedKindNetworkRecordedRemoval
  :: BootstrapProjection
  -> String
  -> String
  -> (DockerSession -> IO Bool -> IO DockerNetworkRemoveResult)
  -> IO
       ( KindOperationOutcome
           (DockerPeerResult (DockerConnectedInfoResult (KindNetworkRemovalAction KindNetworkRecordedTransport)))
       )
withNewConnectedKindNetworkRecordedRemoval bootstrap operation networkId =
  withNewConnectedKindNetworkRecordedRemovalGuarded bootstrap operation networkId id

withNewConnectedKindNetworkRecordedRemovalGuarded
  :: BootstrapProjection
  -> String
  -> String
  -> (IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO DockerNetworkRemoveResult)
  -> IO
       ( KindOperationOutcome
           (DockerPeerResult (DockerConnectedInfoResult (KindNetworkRemovalAction KindNetworkRecordedTransport)))
       )
withNewConnectedKindNetworkRecordedRemovalGuarded bootstrap operation networkId settlementStable action =
  withNewConnectedKindNetworkRemovalGuarded bootstrap operation networkId settlementStable $ \session stable -> do
    result <- action session stable
    parent <- observeRecordedKindNetworkIntent bootstrap operation stable
    let transport = NetworkRemovalTransport result
    written <- case parent of
      NetworkRecoveryRecorded intent -> recordNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId) transport stable
      _ -> pure NetworkReceiptRefused
    pure (KindNetworkRecordedTransport transport written)

-- | Bind one new removal attempt to the observed daemon, exact ID and matching
-- configuration. Matching labels are not provenance: the caller must also
-- establish independent ownership, admission, prior worker settlement and
-- cleanup postconditions. Existing removal markers never enter the callback.
withNewConnectedKindNetworkRemoval
  :: BootstrapProjection
  -> String
  -> String
  -> (DockerSession -> IO Bool -> IO value)
  -> IO
       (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult (KindNetworkRemovalAction value))))
withNewConnectedKindNetworkRemoval bootstrap operation networkId =
  withNewConnectedKindNetworkRemovalGuarded bootstrap operation networkId id

withNewConnectedKindNetworkRemovalGuarded
  :: BootstrapProjection
  -> String
  -> String
  -> (IO Bool -> IO Bool)
  -> (DockerSession -> IO Bool -> IO value)
  -> IO
       (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult (KindNetworkRemovalAction value))))
withNewConnectedKindNetworkRemovalGuarded bootstrap operation networkId settlementStable action =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = settlementStable ((&&) <$> operationStable <*> peerStable)
      recorded <- observeRecordedKindNetworkIntent bootstrap operation stable
      case recorded of
        NetworkRecoveryRecorded intent
          | kindNetworkDaemon intent == DockerDaemonObserved identifier identity -> do
              creation <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
              if not (createReceiptAllowsTarget networkId creation)
                then pure (KindNetworkRemovalCreateReceiptRefused creation)
                else do
                  prior <- observeKindNetworkRemoval bootstrap intent networkId stable
                  case prior of
                    NetworkRemovalMissing -> do
                      let creationStable = (== creation) <$> observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
                      ready <- creationStable
                      if ready then removeIfMatching intent session creationStable else pure KindNetworkRemovalChanged
                    other -> pure (KindNetworkRemovalPrior other)
          | otherwise -> pure KindNetworkRemovalDaemonMismatch
        _ -> pure (KindNetworkRemovalRecordRefused recorded)
 where
  removeIfMatching intent session stable = do
    details <- inspectDockerSessionKindNetwork session (bootstrapScope bootstrap) networkId
    case details of
      Left failure -> pure (KindNetworkRemovalReadRefused failure)
      Right observed
        | compareKindNetworkConfiguration bootstrap intent observed /= NetworkConfigurationMatches ->
            pure KindNetworkRemovalConfigurationDiffers
        | otherwise -> do
            written <- recordKindNetworkRemoval bootstrap intent networkId stable
            case written of
              NetworkRemovalRecorded -> do
                let markerStable = (== NetworkRemovalMatches) <$> observeKindNetworkRemoval bootstrap intent networkId stable
                priorReceipt <-
                  observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId) markerStable
                case priorReceipt of
                  NetworkReceiptMissing -> do
                    ready <- markerStable
                    if not ready
                      then pure KindNetworkRemovalChanged
                      else do
                        value <- action session markerStable
                        after <- try markerStable
                        pure $ case after of
                          Right True -> KindNetworkRemovalReturned value
                          (_ :: Either IOException Bool) -> KindNetworkRemovalChangedAfter value
                  other -> pure (KindNetworkRemovalReceiptRefused other)
              other -> pure (KindNetworkRemovalMarkerRefused other)

-- Unknown transport outcomes still require independent ownership proof from
-- the caller. A definite different ID or a damaged record cannot be ignored.
createReceiptAllowsTarget :: String -> NetworkReceiptObservation -> Bool
createReceiptAllowsTarget target receipt = case receipt of
  NetworkReceiptMissing -> True
  NetworkReceiptObserved (NetworkCreateTransport DockerNetworkCreateUnconfirmed) -> True
  NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just actual))) -> actual == target
  NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply status Nothing)) -> status /= 201
  _ -> False

-- | Bind a newly written attempt marker to the recorded proposal and held
-- daemon connection before entering the callback. The caller must separately
-- establish admission, daemon authentication, subnet allocation, bounded
-- worker settlement and cleanup. An existing marker never enters the callback.
withNewConnectedKindNetworkAttempt
  :: BootstrapProjection
  -> String
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO value)
  -> IO
       (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction value))))
withNewConnectedKindNetworkAttempt bootstrap operation =
  withNewConnectedKindNetworkAttemptGuarded bootstrap operation id

withNewConnectedKindNetworkAttemptGuarded
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO Bool)
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO value)
  -> IO
       (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult (KindNetworkAttemptAction value))))
withNewConnectedKindNetworkAttemptGuarded bootstrap operation admission action =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session info peerStable ->
      runKindNetworkAttemptOnSession
        bootstrap
        operation
        session
        info
        ((&&) <$> admission operationStable <*> peerStable)
        action

runKindNetworkAttemptOnSession
  :: BootstrapProjection
  -> String
  -> DockerSession
  -> DockerConnectedInfo
  -> IO Bool
  -> (KindNetworkIntent -> DockerSession -> IO Bool -> IO value)
  -> IO (KindNetworkAttemptAction value)
runKindNetworkAttemptOnSession bootstrap operation session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) stable action = do
  recorded <- observeRecordedKindNetworkIntent bootstrap operation stable
  case recorded of
    NetworkRecoveryRecorded intent
      | kindNetworkDaemon intent == DockerDaemonObserved identifier identity -> do
          written <- recordKindNetworkAttempt bootstrap intent stable
          case written of
            NetworkAttemptRecorded -> do
              let markerStable = (== NetworkAttemptMatches) <$> observeKindNetworkAttempt bootstrap intent stable
              priorReceipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt markerStable
              case priorReceipt of
                NetworkReceiptMissing -> do
                  ready <- markerStable
                  if not ready
                    then pure KindNetworkAttemptChanged
                    else do
                      value <- action intent session markerStable
                      after <- try markerStable
                      pure $ case after of
                        Right True -> KindNetworkAttemptReturned value
                        (_ :: Either IOException Bool) -> KindNetworkAttemptChangedAfter value
                other -> pure (KindNetworkAttemptReceiptRefused other)
            other -> pure (KindNetworkAttemptMarkerRefused other)
      | otherwise -> pure KindNetworkAttemptDaemonMismatch
    _ -> pure (KindNetworkAttemptRecordRefused recorded)

-- | Hold the recovered operation and one observed daemon connection while
-- sampling exact inventory, optional detail and the attempt on either side.
-- Neither matching identities nor empty inventory proves ownership, absence,
-- daemon authenticity, or settlement. The endpoint must be independently
-- authenticated before any future effect.
observeRecoveredKindNetwork
  :: BootstrapProjection
  -> String
  -> IO (KindOperationOutcome (DockerPeerResult (DockerConnectedInfoResult KindNetworkRecoveryResult)))
observeRecoveredKindNetwork bootstrap operation =
  withRecoveredKindOperation bootstrap operation $ \operationStable ->
    withConnectedDockerInfo 30000000 (bootstrapRuntimeSocket bootstrap) $ \session (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
      let stable = (&&) <$> operationStable <*> peerStable
      recorded <- observeRecordedKindNetworkIntent bootstrap operation stable
      case recorded of
        NetworkRecoveryRecorded intent
          | kindNetworkDaemon intent == DockerDaemonObserved identifier identity -> do
              let recordStable = (== NetworkIntentMatches) <$> observeKindNetworkIntent bootstrap intent stable
              before <- observeRecordedKindNetworkAttempt bootstrap operation recordStable
              createReceipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt recordStable
              removalBefore <- observeRecordedKindNetworkRemoval bootstrap operation recordStable
              removalId <- case removalBefore of
                NetworkRemovalRecoveryRecorded networkId -> Just <$> readDockerSessionKindNetworkIdControlled session (bootstrapScope bootstrap) networkId
                _ -> pure Nothing
              removalIndependent <- case removalBefore of
                NetworkRemovalRecoveryRecorded networkId -> observeIndependentNetworkId bootstrap intent networkId recordStable
                _ -> pure NetworkIndependentIdUnobservable
              inventory <- readDockerSessionKindNetworks session (bootstrapScope bootstrap)
              details <- case inventory of
                Right [networkId] -> Just <$> inspectDockerSessionKindNetwork session (bootstrapScope bootstrap) networkId
                _ -> pure Nothing
              independent <- case details of
                Just (Right observed) -> observeIndependentNetwork bootstrap intent (dockerNetworkId observed) recordStable
                _ -> pure NetworkIndependentUnobservable
              daemon <- readDockerSessionKindInfo session identifier
              after <- observeRecordedKindNetworkAttempt bootstrap operation recordStable
              removalAfter <- observeRecordedKindNetworkRemoval bootstrap operation recordStable
              removalReceipt <- case removalAfter of
                NetworkRemovalRecoveryRecorded networkId -> observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId) recordStable
                _ -> pure NetworkReceiptUnobservable
              let configuration = case details of
                    Just (Right observed) -> compareKindNetworkConfiguration bootstrap intent observed
                    _ -> NetworkConfigurationUnobserved
                  sample =
                    KindNetworkRecoverySample
                      before
                      createReceipt
                      removalBefore
                      inventory
                      details
                      configuration
                      independent
                      daemon
                      after
                      removalAfter
                      removalId
                      removalIndependent
                      removalReceipt
              final <- try recordStable
              pure $ case final of
                Right True -> KindNetworkRecoverySampled sample
                (_ :: Either IOException Bool) -> KindNetworkRecoveryChangedAfter sample
          | otherwise -> pure KindNetworkRecoveryDaemonMismatch
        _ -> pure (KindNetworkRecoveryRecordRefused recorded)

-- | A second Docker client reads the same daemon; it is independent of the
-- held HTTP connection but does not authenticate the daemon, prove absence,
-- ownership or settlement. Preserve changed observations as such.
observeIndependentNetwork
  :: BootstrapProjection
  -> KindNetworkIntent
  -> String
  -> IO Bool
  -> IO KindNetworkIndependentObservation
observeIndependentNetwork bootstrap intent identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure NetworkIndependentUnobservable
  | otherwise = do
      before <- observeDockerDaemon socket
      ready <- stable
      if not ready || before /= kindNetworkDaemon intent
        then pure NetworkIndependentUnobservable
        else do
          output <- readDocker socket ["network", "inspect", "--format", "{{json .}}", identifier]
          details <- case output of
            Nothing -> pure Nothing
            Just content -> do
              let bytes = BS8.pack content
              checked <- decodeBoundedYamlValue bytes
              pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
                (Right value, Right valid)
                  | value == valid ->
                      either (const Nothing) Just (parseDockerNetworkDetails (bootstrapScope bootstrap) identifier value)
                _ -> Nothing
          after <- observeDockerDaemon socket
          final <- try stable
          pure $ case final of
            Right True | before == after -> maybe NetworkIndependentUnobservable NetworkIndependentObserved details
            (_ :: Either IOException Bool) -> NetworkIndependentChanged details
 where
  socket = bootstrapRuntimeSocket bootstrap

-- | A second client performs the exact-ID query. An empty list is a point
-- observation only; daemon authentication, exclusion and
-- worker settlement remain independent requirements.
observeIndependentNetworkId
  :: BootstrapProjection
  -> KindNetworkIntent
  -> String
  -> IO Bool
  -> IO KindNetworkIndependentIdObservation
observeIndependentNetworkId bootstrap intent identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure NetworkIndependentIdUnobservable
  | otherwise = do
      before <- observeDockerDaemon socket
      ready <- stable
      if not ready || before /= kindNetworkDaemon intent
        then pure NetworkIndependentIdUnobservable
        else do
          bridgeOutput <- readDocker socket ["network", "inspect", "--format", "{{json .}}", "bridge"]
          bridge <- case bridgeOutput of
            Nothing -> pure Nothing
            Just content -> do
              let bytes = BS8.pack content
              checked <- decodeBoundedYamlValue bytes
              pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
                (Right value, Right valid) | value == valid -> either (const Nothing) Just (parseDockerBridgeId value)
                _ -> Nothing
          control <- case bridge of
            Just bridgeId | bridgeId /= identifier -> queryId bridgeId
            _ -> pure Nothing
          observed <- case control of
            Just True -> queryId identifier
            _ -> pure Nothing
          after <- observeDockerDaemon socket
          final <- try stable
          pure $ case final of
            Right True | before == after -> case control of
              Just False -> NetworkIndependentIdBlind
              _ -> maybe NetworkIndependentIdUnobservable NetworkIndependentIdObserved observed
            (_ :: Either IOException Bool) -> NetworkIndependentIdChanged observed
 where
  socket = bootstrapRuntimeSocket bootstrap
  queryId target = do
    output <-
      readDocker
        socket
        ["network", "ls", "--no-trunc", "--filter", "id=" ++ target, "--format", "{{.ID}}"]
    pure $ case lines <$> output of
      Just [] -> Just False
      Just [actual] | actual == target -> Just True
      _ -> Nothing
