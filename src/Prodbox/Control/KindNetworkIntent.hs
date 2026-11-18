{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Durable proposal for one scoped Docker network. The record is not an
-- admission, a resource ownership claim, or evidence that a worker settled.
module Prodbox.Control.KindNetworkIntent
  ( KindNetworkIntent
  , mkKindNetworkIntent
  , KindNetworkIntentWrite (..)
  , KindNetworkIntentObservation (..)
  , KindNetworkRecoveryObservation (..)
  , KindNetworkAttemptWrite (..)
  , KindNetworkAttemptObservation (..)
  , KindNetworkRemovalWrite (..)
  , KindNetworkRemovalObservation (..)
  , KindNetworkRemovalRecovery (..)
  , kindNetworkSubnet
  , kindNetworkOperation
  , kindNetworkMtu
  , kindNetworkDaemon
  , sameKindNetworkSubnet
  , recordKindNetworkIntent
  , observeKindNetworkIntent
  , observeRecordedKindNetworkIntent
  , recordKindNetworkAttempt
  , observeKindNetworkAttempt
  , observeRecordedKindNetworkAttempt
  , recordKindNetworkRemoval
  , observeKindNetworkRemoval
  , observeRecordedKindNetworkRemoval
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, stripPrefix)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (readHex)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeKindName
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , DockerSocketIdentity (..)
  , classifyDockerDaemon
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindIntent)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

-- A separate network adapter must establish its subnet allocation and admit
-- any effect. This record itself cannot reserve or create a network.
data KindNetworkIntent = KindNetworkIntent !String !String !(Maybe Int) !String !DockerSocketIdentity
  deriving (Eq, Show)

kindNetworkSubnet :: KindNetworkIntent -> String
kindNetworkSubnet (KindNetworkIntent _ subnet _ _ _) = subnet

kindNetworkOperation :: KindNetworkIntent -> String
kindNetworkOperation (KindNetworkIntent operation _ _ _ _) = operation

kindNetworkMtu :: KindNetworkIntent -> Maybe Int
kindNetworkMtu (KindNetworkIntent _ _ mtu _ _) = mtu

kindNetworkDaemon :: KindNetworkIntent -> DockerDaemonObservation
kindNetworkDaemon (KindNetworkIntent _ _ _ identifier socket) = DockerDaemonObserved identifier socket

mkKindNetworkIntent
  :: String -> String -> Maybe Int -> DockerDaemonObservation -> Maybe KindNetworkIntent
mkKindNetworkIntent operation subnet mtu observed = case observed of
  DockerDaemonObserved identifier socket@(DockerSocketIdentity device inode owner mode)
    | validRootGeneration operation
        && validSubnet subnet
        && maybe True (\value -> value >= 68 && value <= 65535) mtu
        && device >= 0
        && inode > 0
        && owner >= 0
        && mode >= 0
        && mode .&. 0o170000 == 0o140000
        && classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just identifier) (Just socket)
          == observed ->
        Just (KindNetworkIntent operation subnet mtu identifier socket)
  _ -> Nothing

-- kind proposes a ULA /64. Require a syntactically valid IPv6 network address,
-- not a host address or a globally routable range. Allocation and overlap
-- against existing networks are independent observations.
validSubnet :: String -> Bool
validSubnet = maybe False (const True) . parseSubnet

-- Compare network addresses rather than their compressed textual spelling.
-- Invalid, non-ULA, host-address and non-/64 inputs never compare equal.
sameKindNetworkSubnet :: String -> String -> Bool
sameKindNetworkSubnet first second = case (parseSubnet first, parseSubnet second) of
  (Just a, Just b) -> a == b
  _ -> False

parseSubnet :: String -> Maybe [Int]
parseSubnet subnet | length subnet > 64 = Nothing
parseSubnet subnet = case stripPrefix "46/" (reverse subnet) >>= parseAddress . reverse of
  Just groups@[first, _, _, _, _, _, _, _]
    | first >= 0xfc00 && first <= 0xfdff && all (== 0) (drop 4 groups) -> Just groups
  _ -> Nothing
 where
  parseAddress address = case breakOnDouble address of
    Nothing -> traverse parseGroup (splitGroups address) >>= exactEight
    Just (left, right) -> do
      before <- traverse parseGroup (if null left then [] else splitGroups left)
      after <- traverse parseGroup (if null right then [] else splitGroups right)
      let missing = 8 - length before - length after
      if missing <= 0 then Nothing else exactEight (before ++ replicate missing 0 ++ after)
  exactEight values = if length values == 8 then Just values else Nothing
  parseGroup group
    | null group || length group > 4 || any (\c -> not (isDigit c || (isAsciiLower c && c <= 'f'))) group =
        Nothing
    | otherwise = case readHex group of
        [(value, "")] -> Just (value :: Int)
        _ -> Nothing
  splitGroups value = case break (== ':') value of
    (part, []) -> [part]
    (part, _ : rest) -> part : splitGroups rest
  breakOnDouble = search []
   where
    search _ [] = Nothing
    search prefix remaining@(character : rest)
      | "::" `isPrefixOf` remaining = (reverse prefix,) <$> stripPrefix "::" remaining
      | otherwise = search (character : prefix) rest

data KindNetworkIntentWrite
  = NetworkIntentRecorded
  | NetworkIntentAlreadyExists
  | NetworkIntentRefused
  | NetworkIntentIncomplete
  deriving (Eq, Show)
data KindNetworkIntentObservation
  = NetworkIntentMissing
  | NetworkIntentMatches
  | NetworkIntentConflict
  | NetworkIntentInvalid
  | NetworkIntentUnobservable
  deriving (Eq, Show)
data KindNetworkRecoveryObservation
  = NetworkRecoveryMissing
  | NetworkRecoveryRecorded !KindNetworkIntent
  | NetworkRecoveryConflict
  | NetworkRecoveryInvalid
  | NetworkRecoveryUnobservable
  deriving (Eq, Show)
data KindNetworkAttemptWrite
  = NetworkAttemptRecorded
  | NetworkAttemptAlreadyExists
  | NetworkAttemptRefused
  | NetworkAttemptIncomplete
  deriving (Eq, Show)
data KindNetworkAttemptObservation
  = NetworkAttemptMissing
  | NetworkAttemptMatches
  | NetworkAttemptConflict
  | NetworkAttemptInvalid
  | NetworkAttemptUnobservable
  deriving (Eq, Show)
data KindNetworkRemovalWrite
  = NetworkRemovalRecorded
  | NetworkRemovalAlreadyExists
  | NetworkRemovalRefused
  | NetworkRemovalIncomplete
  deriving (Eq, Show)
data KindNetworkRemovalObservation
  = NetworkRemovalMissing
  | NetworkRemovalMatches
  | NetworkRemovalConflict
  | NetworkRemovalInvalid
  | NetworkRemovalUnobservable
  deriving (Eq, Show)
data KindNetworkRemovalRecovery
  = NetworkRemovalRecoveryMissing
  | NetworkRemovalRecoveryRecorded !String
  | NetworkRemovalRecoveryConflict
  | NetworkRemovalRecoveryInvalid
  | NetworkRemovalRecoveryUnobservable
  deriving (Eq, Show)

-- The caller holds the operation lease and supplies its recheck. An existing
-- or partial record is retained for recovery and never replaced here.
recordKindNetworkIntent
  :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO KindNetworkIntentWrite
recordKindNetworkIntent bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      if not ready
        then pure NetworkIntentRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) recordName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NetworkIntentAlreadyExists
            Left (_ :: IOException) -> pure NetworkIntentRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                rootStatus <- Files.getFdStatus root
                writeAll held (recordBytes bootstrap intent rootStatus)
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NetworkIntentIncomplete
                Right () -> do
                  observed <- observeKindNetworkIntent bootstrap intent stable
                  pure (if observed == NetworkIntentMatches then NetworkIntentRecorded else NetworkIntentIncomplete)
    pure (either (const NetworkIntentRefused) id (checked :: Either IOException KindNetworkIntentWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NetworkIntentRefused -> result
    _ | changed -> NetworkIntentIncomplete
    _ -> NetworkIntentRefused

-- Missing local state is not evidence of network absence or worker settlement.
observeKindNetworkIntent
  :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO KindNetworkIntentObservation
observeKindNetworkIntent bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      if not ready
        then pure NetworkIntentUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- preconditions bootstrap intent stable sameRoot
              pure (if still then NetworkIntentMissing else NetworkIntentUnobservable)
            Left (_ :: IOException) -> pure NetworkIntentUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NetworkIntentUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- preconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NetworkIntentUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (recordBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue -> if value == wanted then NetworkIntentMatches else NetworkIntentConflict
                        _ -> NetworkIntentInvalid
    pure
      ( either
          (const NetworkIntentUnobservable)
          id
          (checked :: Either IOException KindNetworkIntentObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NetworkIntentUnobservable

-- | Reconstruct and independently compare the stored proposal while the
-- caller holds the recovered operation lease. This is a local record read,
-- not proof of daemon identity, resource state, admission, or settlement.
observeRecordedKindNetworkIntent
  :: BootstrapProjection -> String -> IO Bool -> IO KindNetworkRecoveryObservation
observeRecordedKindNetworkIntent bootstrap operation stable
  | not (validRootGeneration operation) = pure NetworkRecoveryUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          let ready = operationReady bootstrap operation stable sameRoot
          initialReady <- ready
          if not initialReady
            then pure NetworkRecoveryUnobservable
            else do
              owner <- getEffectiveUserID
              rootStatus <- Files.getFdStatus root
              opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready
                  pure (if still then NetworkRecoveryMissing else NetworkRecoveryUnobservable)
                Left (_ :: IOException) -> pure NetworkRecoveryUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  initial <- Files.getFdStatus held
                  if not (safeFile owner initial)
                    then pure NetworkRecoveryUnobservable
                    else do
                      bytes <- readBounded held
                      checkedValue <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready
                      if not (still && sameVersion initial after && sameVersion after named)
                        then pure NetworkRecoveryUnobservable
                        else case decodeCandidate bytes checkedValue of
                          Nothing -> pure NetworkRecoveryInvalid
                          Just (value, candidate) -> case Aeson.eitherDecodeStrict' (recordBytes bootstrap candidate rootStatus) of
                            Right expected | value == expected -> pure (NetworkRecoveryRecorded candidate)
                            _ -> pure NetworkRecoveryConflict
        pure
          ( either
              (const NetworkRecoveryUnobservable)
              id
              (checked :: Either IOException KindNetworkRecoveryObservation)
          )
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> NetworkRecoveryUnobservable
 where
  decodeCandidate bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right validated) | value == validated ->
      case parseEither parseCandidate value of
        Right (Just candidate) -> Just (value, candidate)
        _ -> Nothing
    _ -> Nothing
  parseCandidate = Aeson.withObject "kind network intent" $ \object -> do
    recordedOperation <- object .: "operation_id"
    subnet <- object .: "subnet"
    mtu <- object .: "mtu"
    identifier <- object .: "daemon_id"
    device <- object .: "socket_device"
    inode <- object .: "socket_inode"
    owner <- object .: "socket_owner"
    mode <- object .: "socket_mode"
    pure $
      if recordedOperation == operation
        then
          mkKindNetworkIntent
            operation
            subnet
            mtu
            (DockerDaemonObserved identifier (DockerSocketIdentity device inode owner mode))
        else Nothing

-- | Persist once before a possible create submission. The matching parent
-- proposal, operation lease, admission and prior worker settlement are
-- separate obligations; this marker itself permits no Docker effect.
recordKindNetworkAttempt
  :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO KindNetworkAttemptWrite
recordKindNetworkAttempt bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptReady bootstrap intent stable sameRoot
      status <- Files.getFdStatus root
      let bytes = attemptBytes bootstrap intent status
      if not ready || BS.length bytes > 8192
        then pure NetworkAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) attemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NetworkAttemptAlreadyExists
            Left (_ :: IOException) -> pure NetworkAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NetworkAttemptIncomplete
                Right () -> do
                  observed <- observeKindNetworkAttempt bootstrap intent stable
                  pure
                    (if observed == NetworkAttemptMatches then NetworkAttemptRecorded else NetworkAttemptIncomplete)
    pure
      (either (const NetworkAttemptRefused) id (checked :: Either IOException KindNetworkAttemptWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NetworkAttemptRefused -> result
    _ | changed -> NetworkAttemptIncomplete
    _ -> NetworkAttemptRefused

-- | A missing or matching marker does not establish whether a worker is
-- active or a network exists; independently observe and settle both.
observeKindNetworkAttempt
  :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO KindNetworkAttemptObservation
observeKindNetworkAttempt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptReady bootstrap intent stable sameRoot
      if not ready
        then pure NetworkAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- attemptReady bootstrap intent stable sameRoot
              pure (if still then NetworkAttemptMissing else NetworkAttemptUnobservable)
            Left (_ :: IOException) -> pure NetworkAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NetworkAttemptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- attemptReady bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NetworkAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (attemptBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue -> if value == wanted then NetworkAttemptMatches else NetworkAttemptConflict
                        _ -> NetworkAttemptInvalid
    pure
      ( either
          (const NetworkAttemptUnobservable)
          id
          (checked :: Either IOException KindNetworkAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NetworkAttemptUnobservable

-- | Recover the parent independently before observing its attempt marker.
-- The caller must hold the recovered operation lease throughout.
observeRecordedKindNetworkAttempt
  :: BootstrapProjection -> String -> IO Bool -> IO KindNetworkAttemptObservation
observeRecordedKindNetworkAttempt bootstrap operation stable = do
  parent <- observeRecordedKindNetworkIntent bootstrap operation stable
  case parent of
    NetworkRecoveryRecorded intent -> observeKindNetworkAttempt bootstrap intent stable
    _ -> pure NetworkAttemptUnobservable

-- | Record a full removal target once before an admitted delete. This does
-- not prove that the network belongs to the operation, or that any previous
-- Docker worker has stopped. The caller must establish those separately.
recordKindNetworkRemoval
  :: BootstrapProjection -> KindNetworkIntent -> String -> IO Bool -> IO KindNetworkRemovalWrite
recordKindNetworkRemoval bootstrap intent identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure NetworkRemovalRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- removalReady bootstrap intent stable sameRoot
          status <- Files.getFdStatus root
          let bytes = removalBytes bootstrap intent identifier status
          if not ready || BS.length bytes > 8192
            then pure NetworkRemovalRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) removalName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NetworkRemovalAlreadyExists
                Left (_ :: IOException) -> pure NetworkRemovalRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NetworkRemovalIncomplete
                    Right () -> do
                      observed <- observeKindNetworkRemoval bootstrap intent identifier stable
                      pure
                        (if observed == NetworkRemovalMatches then NetworkRemovalRecorded else NetworkRemovalIncomplete)
        pure
          (either (const NetworkRemovalRefused) id (checked :: Either IOException KindNetworkRemovalWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right result) | result /= NetworkRemovalRefused -> result
        _ | changed -> NetworkRemovalIncomplete
        _ -> NetworkRemovalRefused

-- | This observes the local removal record only. A match or a missing record
-- does not establish whether Docker removed the target or a worker settled.
observeKindNetworkRemoval
  :: BootstrapProjection -> KindNetworkIntent -> String -> IO Bool -> IO KindNetworkRemovalObservation
observeKindNetworkRemoval bootstrap intent identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure NetworkRemovalUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- removalReady bootstrap intent stable sameRoot
          if not ready
            then pure NetworkRemovalUnobservable
            else do
              owner <- getEffectiveUserID
              rootStatus <- Files.getFdStatus root
              opened <- try (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- removalReady bootstrap intent stable sameRoot
                  pure (if still then NetworkRemovalMissing else NetworkRemovalUnobservable)
                Left (_ :: IOException) -> pure NetworkRemovalUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  initial <- Files.getFdStatus held
                  if not (safeFile owner initial)
                    then pure NetworkRemovalUnobservable
                    else do
                      bytes <- readBounded held
                      decoded <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- removalReady bootstrap intent stable sameRoot
                      pure $
                        if not (still && sameVersion initial after && sameVersion after named)
                          then NetworkRemovalUnobservable
                          else case ( Aeson.eitherDecodeStrict' bytes
                                    , decoded
                                    , Aeson.eitherDecodeStrict' (removalBytes bootstrap intent identifier rootStatus)
                                    ) of
                            (Right value, Right checkedValue, Right wanted)
                              | value == checkedValue -> if value == wanted then NetworkRemovalMatches else NetworkRemovalConflict
                            _ -> NetworkRemovalInvalid
        pure
          ( either
              (const NetworkRemovalUnobservable)
              id
              (checked :: Either IOException KindNetworkRemovalObservation)
          )
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> NetworkRemovalUnobservable

-- | Recover the exact target from the record while the caller holds the
-- operation lease. This observes local bytes only; it does not establish
-- ownership, daemon state, worker settlement, or permission to retry.
observeRecordedKindNetworkRemoval
  :: BootstrapProjection -> String -> IO Bool -> IO KindNetworkRemovalRecovery
observeRecordedKindNetworkRemoval bootstrap operation stable = do
  parent <- observeRecordedKindNetworkIntent bootstrap operation stable
  case parent of
    NetworkRecoveryRecorded intent -> do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- removalReady bootstrap intent stable sameRoot
          if not ready
            then pure NetworkRemovalRecoveryUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- removalReady bootstrap intent stable sameRoot
                  pure (if still then NetworkRemovalRecoveryMissing else NetworkRemovalRecoveryUnobservable)
                Left (_ :: IOException) -> pure NetworkRemovalRecoveryUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  initial <- Files.getFdStatus held
                  if not (safeFile owner initial)
                    then pure NetworkRemovalRecoveryUnobservable
                    else do
                      bytes <- readBounded held
                      validated <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- removalReady bootstrap intent stable sameRoot
                      if not (still && sameVersion initial after && sameVersion after named)
                        then pure NetworkRemovalRecoveryUnobservable
                        else case (Aeson.eitherDecodeStrict' bytes, validated) of
                          (Right value, Right checkedValue) | value == checkedValue ->
                            case parseEither (Aeson.withObject "network removal" (.: "network_id")) value of
                              Right identifier | validImageId ("sha256:" ++ identifier) -> do
                                observed <- observeKindNetworkRemoval bootstrap intent identifier stable
                                lastStatus <- Files.getFdStatus held
                                lastNamed <-
                                  bracket
                                    (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
                                    Posix.closeFd
                                    Files.getFdStatus
                                final <- removalReady bootstrap intent stable sameRoot
                                pure $
                                  if not (final && sameVersion after lastStatus && sameVersion lastStatus lastNamed)
                                    then NetworkRemovalRecoveryUnobservable
                                    else case observed of
                                      NetworkRemovalMatches -> NetworkRemovalRecoveryRecorded identifier
                                      NetworkRemovalConflict -> NetworkRemovalRecoveryConflict
                                      NetworkRemovalInvalid -> NetworkRemovalRecoveryInvalid
                                      _ -> NetworkRemovalRecoveryUnobservable
                              _ -> pure NetworkRemovalRecoveryInvalid
                          _ -> pure NetworkRemovalRecoveryInvalid
        pure
          ( either
              (const NetworkRemovalRecoveryUnobservable)
              id
              (checked :: Either IOException KindNetworkRemovalRecovery)
          )
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> NetworkRemovalRecoveryUnobservable
    _ -> pure NetworkRemovalRecoveryUnobservable

removalReady :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO Bool -> IO Bool
removalReady bootstrap intent stable sameRoot = do
  first <- stable
  rootBefore <- sameRoot
  if not (first && rootBefore)
    then pure False
    else do
      parent <- observeKindNetworkAttempt bootstrap intent (pure True)
      rootAfter <- sameRoot
      lastCheck <- stable
      pure (parent == NetworkAttemptMatches && rootAfter && lastCheck)

removalBytes
  :: BootstrapProjection -> KindNetworkIntent -> String -> Files.FileStatus -> BS.ByteString
removalBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-network-removal" :: String)
        , "network_id" Aeson..= identifier
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        ]

attemptReady :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO Bool -> IO Bool
attemptReady bootstrap intent stable sameRoot = do
  first <- stable
  rootBefore <- sameRoot
  if not (first && rootBefore)
    then pure False
    else do
      parent <- observeKindNetworkIntent bootstrap intent (pure True)
      rootAfter <- sameRoot
      lastCheck <- stable
      pure (parent == NetworkIntentMatches && rootAfter && lastCheck)

attemptBytes :: BootstrapProjection -> KindNetworkIntent -> Files.FileStatus -> BS.ByteString
attemptBytes bootstrap intent root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-network-attempt" :: String)
        , "intent" Aeson..= TextEncoding.decodeUtf8 (recordBytes bootstrap intent root)
        ]

preconditions :: BootstrapProjection -> KindNetworkIntent -> IO Bool -> IO Bool -> IO Bool
preconditions bootstrap (KindNetworkIntent operation _ _ _ _) = operationReady bootstrap operation

operationReady :: BootstrapProjection -> String -> IO Bool -> IO Bool -> IO Bool
operationReady bootstrap operation stable sameRoot = do
  first <- stable
  root <- sameRoot
  generation <-
    observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
  observed <- observeKindIntent bootstrap
  lastCheck <- stable
  pure
    ( first
        && root
        && generation == Right ScopeGenerationMatches
        && observed == KindIntentMatches operation
        && lastCheck
    )

recordBytes :: BootstrapProjection -> KindNetworkIntent -> Files.FileStatus -> BS.ByteString
recordBytes bootstrap (KindNetworkIntent operation subnet mtu daemon (DockerSocketIdentity device inode owner mode)) root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "operation_id" Aeson..= operation
        , "operation" Aeson..= ("kind-network-create" :: String)
        , "network" Aeson..= scopeKindName (bootstrapScope bootstrap)
        , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
        , "root_device" Aeson..= toInteger (Files.deviceID root)
        , "root_inode" Aeson..= toInteger (Files.fileID root)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "subnet" Aeson..= subnet
        , "mtu" Aeson..= mtu
        , "daemon_id" Aeson..= daemon
        , "socket_device" Aeson..= device
        , "socket_inode" Aeson..= inode
        , "socket_owner" Aeson..= owner
        , "socket_mode" Aeson..= mode
        ]

recordName :: FilePath
recordName = "kind-network-intent.json"
attemptName :: FilePath
attemptName = "kind-network-attempt.json"
removalName :: FilePath
removalName = "kind-network-removal.json"
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
    then ioError (userError "short network intent write")
    else writeAll fd (BS.drop (fromIntegral count) bytes)
