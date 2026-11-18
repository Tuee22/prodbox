{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Durable transport observations for network effects. A receipt is not a
-- resource postcondition, admission, daemon authentication, or settlement.
module Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkTransport (..)
  , NetworkReceiptWrite (..)
  , NetworkReceiptObservation (..)
  , recordNetworkReceipt
  , observeNetworkReceipt
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, withScopeRootDescriptor)
import Prodbox.Control.DockerConnectedInfo
  ( DockerNetworkCreateResult (..)
  , DockerNetworkRemoveResult (..)
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), DockerSocketIdentity (..))
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkAttemptObservation (NetworkAttemptMatches)
  , KindNetworkIntent
  , KindNetworkRemovalObservation (NetworkRemovalMatches)
  , kindNetworkDaemon
  , kindNetworkMtu
  , kindNetworkOperation
  , kindNetworkSubnet
  , observeKindNetworkAttempt
  , observeKindNetworkRemoval
  )
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data NetworkReceiptKind = NetworkCreateReceipt | NetworkRemovalReceipt !String deriving (Eq, Show)
data NetworkTransport
  = NetworkCreateTransport !DockerNetworkCreateResult
  | NetworkRemovalTransport !DockerNetworkRemoveResult
  deriving (Eq, Show)
data NetworkReceiptWrite
  = NetworkReceiptRecorded
  | NetworkReceiptAlreadyExists
  | NetworkReceiptRefused
  | NetworkReceiptIncomplete
  deriving (Eq, Show)
data NetworkReceiptObservation
  = NetworkReceiptMissing
  | NetworkReceiptObserved !NetworkTransport
  | NetworkReceiptConflict
  | NetworkReceiptInvalid
  | NetworkReceiptUnobservable
  deriving (Eq, Show)

-- Caller holds the operation lease and rechecks the selected connection and
-- exact marker. Existing/incomplete records remain untouched for recovery.
recordNetworkReceipt
  :: BootstrapProjection
  -> KindNetworkIntent
  -> NetworkReceiptKind
  -> NetworkTransport
  -> IO Bool
  -> IO NetworkReceiptWrite
recordNetworkReceipt bootstrap intent kind result stable
  | not (validTransport kind result) = pure NetworkReceiptRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- receiptReady bootstrap intent kind stable sameRoot
          status <- Files.getFdStatus root
          let bytes = receiptBytes bootstrap intent kind result status
          if not ready || BS.length bytes > 8192
            then pure NetworkReceiptRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) (receiptName kind) Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NetworkReceiptAlreadyExists
                Left (_ :: IOException) -> pure NetworkReceiptRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NetworkReceiptIncomplete
                    Right () -> do
                      observed <- observeNetworkReceipt bootstrap intent kind stable
                      pure
                        ( if observed == NetworkReceiptObserved result
                            then NetworkReceiptRecorded
                            else NetworkReceiptIncomplete
                        )
        pure (either (const NetworkReceiptRefused) id (checked :: Either IOException NetworkReceiptWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right value) | value /= NetworkReceiptRefused -> value
        _ | changed -> NetworkReceiptIncomplete
        _ -> NetworkReceiptRefused

-- Missing local receipt is not evidence about a Docker-side effect.
observeNetworkReceipt
  :: BootstrapProjection
  -> KindNetworkIntent
  -> NetworkReceiptKind
  -> IO Bool
  -> IO NetworkReceiptObservation
observeNetworkReceipt bootstrap intent kind stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- receiptReady bootstrap intent kind stable sameRoot
      if not ready
        then pure NetworkReceiptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) (receiptName kind) Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- receiptReady bootstrap intent kind stable sameRoot
              pure (if still then NetworkReceiptMissing else NetworkReceiptUnobservable)
            Left (_ :: IOException) -> pure NetworkReceiptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NetworkReceiptUnobservable
                else do
                  bytes <- readBounded held
                  checkedValue <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) (receiptName kind) Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- receiptReady bootstrap intent kind stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NetworkReceiptUnobservable
                      else decodeReceipt bootstrap intent kind rootStatus bytes checkedValue
    pure
      ( either
          (const NetworkReceiptUnobservable)
          id
          (checked :: Either IOException NetworkReceiptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NetworkReceiptUnobservable

receiptReady
  :: BootstrapProjection -> KindNetworkIntent -> NetworkReceiptKind -> IO Bool -> IO Bool -> IO Bool
receiptReady bootstrap intent kind stable sameRoot = do
  first <- stable
  rootBefore <- sameRoot
  if not (first && rootBefore)
    then pure False
    else do
      parent <- case kind of
        NetworkCreateReceipt -> (== NetworkAttemptMatches) <$> observeKindNetworkAttempt bootstrap intent (pure True)
        NetworkRemovalReceipt identifier -> (== NetworkRemovalMatches) <$> observeKindNetworkRemoval bootstrap intent identifier (pure True)
      rootAfter <- sameRoot
      lastCheck <- stable
      pure (parent && rootAfter && lastCheck)

validTransport :: NetworkReceiptKind -> NetworkTransport -> Bool
validTransport NetworkCreateReceipt (NetworkCreateTransport result) = case result of
  DockerNetworkCreateNotStarted -> True
  DockerNetworkCreateUnconfirmed -> True
  DockerNetworkCreateReply status identifier ->
    validStatus status && case (status, identifier) of
      (201, Just value) -> validId value
      (201, Nothing) -> False
      (_, Nothing) -> True
      _ -> False
validTransport (NetworkRemovalReceipt identifier) (NetworkRemovalTransport result) =
  validId identifier && case result of
    DockerNetworkRemoveNotStarted -> True
    DockerNetworkRemoveUnconfirmed -> True
    DockerNetworkRemoveReply status -> validStatus status
validTransport _ _ = False

validId :: String -> Bool
validId identifier = validImageId ("sha256:" ++ identifier)
validStatus :: Int -> Bool
validStatus status = status >= 100 && status <= 599

transportValue :: NetworkTransport -> Aeson.Value
transportValue transport = case transport of
  NetworkCreateTransport result -> case result of
    DockerNetworkCreateNotStarted -> state "not-started"
    DockerNetworkCreateUnconfirmed -> state "unconfirmed"
    DockerNetworkCreateReply status identifier ->
      Aeson.object
        ["state" Aeson..= ("reply" :: String), "status" Aeson..= status, "network_id" Aeson..= identifier]
  NetworkRemovalTransport result -> case result of
    DockerNetworkRemoveNotStarted -> state "not-started"
    DockerNetworkRemoveUnconfirmed -> state "unconfirmed"
    DockerNetworkRemoveReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]
 where
  state value = Aeson.object ["state" Aeson..= (value :: String)]

receiptBytes
  :: BootstrapProjection
  -> KindNetworkIntent
  -> NetworkReceiptKind
  -> NetworkTransport
  -> Files.FileStatus
  -> BS.ByteString
receiptBytes bootstrap intent kind result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= receiptTag kind
        , "operation_id" Aeson..= kindNetworkOperation intent
        , "network" Aeson..= scopeKindName (bootstrapScope bootstrap)
        , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
        , "root_device" Aeson..= toInteger (Files.deviceID root)
        , "root_inode" Aeson..= toInteger (Files.fileID root)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "subnet" Aeson..= kindNetworkSubnet intent
        , "mtu" Aeson..= kindNetworkMtu intent
        , "daemon" Aeson..= daemonValue (kindNetworkDaemon intent)
        , "target" Aeson..= removalTarget kind
        , "transport" Aeson..= transportValue result
        ]
 where
  daemonValue (DockerDaemonObserved identifier (DockerSocketIdentity device inode owner mode)) =
    Aeson.object
      [ "id" Aeson..= identifier
      , "device" Aeson..= device
      , "inode" Aeson..= inode
      , "owner" Aeson..= owner
      , "mode" Aeson..= mode
      ]
  daemonValue _ = Aeson.Null
  removalTarget NetworkCreateReceipt = Nothing
  removalTarget (NetworkRemovalReceipt identifier) = Just identifier

receiptTag :: NetworkReceiptKind -> String
receiptTag NetworkCreateReceipt = "network-create-receipt"
receiptTag (NetworkRemovalReceipt _) = "network-removal-receipt"
receiptName :: NetworkReceiptKind -> FilePath
receiptName NetworkCreateReceipt = "kind-network-create-result.json"
receiptName (NetworkRemovalReceipt _) = "kind-network-removal-result.json"

decodeReceipt
  :: BootstrapProjection
  -> KindNetworkIntent
  -> NetworkReceiptKind
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> NetworkReceiptObservation
decodeReceipt bootstrap intent kind root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right verified) | value == verified -> case parseEither parser value of
    Right transport | validTransport kind transport -> case Aeson.eitherDecodeStrict' (receiptBytes bootstrap intent kind transport root) of
      Right expected | value == expected -> NetworkReceiptObserved transport
      _ -> NetworkReceiptConflict
    _ -> NetworkReceiptInvalid
  _ -> NetworkReceiptInvalid
 where
  parser = Aeson.withObject "network receipt" $ \object -> object .: "transport" >>= parseTransport
  parseTransport = Aeson.withObject "network transport" $ \object -> do
    state <- object .: "state" :: Parser String
    case (kind, state) of
      (NetworkCreateReceipt, "not-started") -> pure (NetworkCreateTransport DockerNetworkCreateNotStarted)
      (NetworkCreateReceipt, "unconfirmed") -> pure (NetworkCreateTransport DockerNetworkCreateUnconfirmed)
      (NetworkCreateReceipt, "reply") ->
        NetworkCreateTransport
          <$> (DockerNetworkCreateReply <$> object .: "status" <*> object .: "network_id")
      (NetworkRemovalReceipt _, "not-started") -> pure (NetworkRemovalTransport DockerNetworkRemoveNotStarted)
      (NetworkRemovalReceipt _, "unconfirmed") -> pure (NetworkRemovalTransport DockerNetworkRemoveUnconfirmed)
      (NetworkRemovalReceipt _, "reply") -> NetworkRemovalTransport . DockerNetworkRemoveReply <$> object .: "status"
      _ -> fail "invalid network transport"

readFlags, createFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}
safeFile :: UserID -> Files.FileStatus -> Bool
safeFile owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.fileMode status .&. 0o077 == 0
    && Files.linkCount status == 1
    && Files.fileSize status >= 0
    && Files.fileSize status <= 8192
sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion a b =
  Files.deviceID a == Files.deviceID b
    && Files.fileID a == Files.fileID b
    && Files.fileSize a == Files.fileSize b
    && Files.fileMode a == Files.fileMode b
    && Files.fileOwner a == Files.fileOwner b
    && Files.linkCount a == Files.linkCount b
    && Files.modificationTimeHiRes a == Files.modificationTimeHiRes b
    && Files.statusChangeTimeHiRes a == Files.statusChangeTimeHiRes b
readBounded :: Fd -> IO BS.ByteString
readBounded fd = go [] 0
 where
  go chunks count = do
    result <- try (PosixBytes.fdRead fd (fromIntegral (8193 - count)))
    case result of
      Left failure | isEOFError failure -> pure (BS.concat (reverse chunks))
      Left failure -> throwIO failure
      Right bytes | BS.null bytes -> pure (BS.concat (reverse chunks))
      Right bytes | count + BS.length bytes > 8192 -> pure (BS.concat (reverse (bytes : chunks)))
      Right bytes -> go (bytes : chunks) (count + BS.length bytes)
writeAll :: Fd -> BS.ByteString -> IO ()
writeAll fd bytes = unless (BS.null bytes) $ do
  count <- PosixBytes.fdWrite fd bytes
  if count <= 0
    then ioError (userError "short network receipt write")
    else writeAll fd (BS.drop (fromIntegral count) bytes)
