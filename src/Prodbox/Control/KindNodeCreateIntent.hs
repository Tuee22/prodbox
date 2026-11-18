{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Durable node create proposal. It does not authenticate the daemon, prove
-- resource provenance, admit an effect or settle a worker.
module Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateIntent
  , mkKindNodeCreateIntent
  , kindNodeCreateDaemon
  , kindNodeCreateInput
  , KindNodeCreateIntentWrite (..)
  , KindNodeCreateIntentObservation (..)
  , KindNodeCreateRecoveryObservation (..)
  , recordKindNodeCreateIntent
  , observeKindNodeCreateIntent
  , observeRecordedKindNodeCreateIntent
  , KindNodeCreateAttemptWrite (..)
  , KindNodeCreateAttemptObservation (..)
  , recordKindNodeCreateAttempt
  , observeKindNodeCreateAttempt
  , KindNodeCreateResultWrite (..)
  , KindNodeCreateResultObservation (..)
  , recordKindNodeCreateResult
  , observeKindNodeCreateResult
  , KindNodeCandidateWrite (..)
  , KindNodeCandidateObservation (..)
  , recordKindNodeCandidate
  , observeRecordedKindNodeCandidate
  , KindNodeStartAttemptWrite (..)
  , KindNodeStartAttemptObservation (..)
  , recordKindNodeStartAttempt
  , observeKindNodeStartAttempt
  , KindNodeConfigAttemptWrite (..)
  , KindNodeConfigAttemptObservation (..)
  , KindNodeConfigResultWrite (..)
  , KindNodeConfigResultObservation (..)
  , recordKindNodeConfigResult
  , observeKindNodeConfigResult
  , recordKindNodeConfigAttempt
  , observeKindNodeConfigAttempt
  , KindNodeStartResultWrite (..)
  , KindNodeStartResultObservation (..)
  , recordKindNodeStartResult
  , observeKindNodeStartResult
  , KindNodeRemoveControlObservation (..)
  , observeKindNodeRemoveControl
  , KindNodeRemoveAttemptWrite (..)
  , KindNodeRemoveAttemptObservation (..)
  , recordKindNodeRemoveAttempt
  , observeKindNodeRemoveAttempt
  , KindNodeRemoveResultWrite (..)
  , KindNodeRemoveResultObservation (..)
  , recordKindNodeRemoveResult
  , observeKindNodeRemoveResult
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapKindPlan
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
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeCreateBody)
import Prodbox.Control.DockerConnectedInfo
  ( DockerNodeConfigWriteResult (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeContainerStartResult (..)
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , DockerSocketIdentity (..)
  , classifyDockerDaemon
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindIntent)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindNodeRemovalSampling
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , nodeRemovalPositive
  , observeNodeRemovalPositiveControl
  )
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data KindNodeCreateIntent = KindNodeCreateIntent !KindNodeCreateInput !String !DockerSocketIdentity
  deriving (Eq, Show)

kindNodeCreateInput :: KindNodeCreateIntent -> KindNodeCreateInput
kindNodeCreateInput (KindNodeCreateIntent input _ _) = input

kindNodeCreateDaemon :: KindNodeCreateIntent -> DockerDaemonObservation
kindNodeCreateDaemon (KindNodeCreateIntent _ identifier socket) = DockerDaemonObserved identifier socket

mkKindNodeCreateIntent
  :: BootstrapProjection -> KindNodeCreateInput -> DockerDaemonObservation -> Maybe KindNodeCreateIntent
mkKindNodeCreateIntent bootstrap input observed = case observed of
  DockerDaemonObserved identifier socket@(DockerSocketIdentity device inode owner mode)
    | nodeCreateGeneration input == Text.unpack (bootstrapRootGeneration bootstrap)
        && kindNodeCreateBody (bootstrapKindPlan bootstrap) input /= Nothing
        && device >= 0
        && inode > 0
        && owner >= 0
        && mode >= 0
        && mode .&. 0o170000 == 0o140000
        && classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just identifier) (Just socket)
          == observed ->
        Just (KindNodeCreateIntent input identifier socket)
  _ -> Nothing

data KindNodeCreateIntentWrite
  = NodeCreateIntentRecorded
  | NodeCreateIntentAlreadyExists
  | NodeCreateIntentRefused
  | NodeCreateIntentIncomplete
  deriving (Eq, Show)
data KindNodeCreateIntentObservation
  = NodeCreateIntentMissing
  | NodeCreateIntentMatches
  | NodeCreateIntentConflict
  | NodeCreateIntentInvalid
  | NodeCreateIntentUnobservable
  deriving (Eq, Show)
data KindNodeCreateRecoveryObservation
  = NodeCreateRecoveryMissing
  | NodeCreateRecoveryRecorded !KindNodeCreateIntent
  | NodeCreateRecoveryConflict
  | NodeCreateRecoveryInvalid
  | NodeCreateRecoveryUnobservable
  deriving (Eq, Show)

recordKindNodeCreateIntent
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCreateIntentWrite
recordKindNodeCreateIntent bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = recordBytes bootstrap intent rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeCreateIntentRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) recordName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeCreateIntentAlreadyExists
            Left (_ :: IOException) -> pure NodeCreateIntentRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeCreateIntentIncomplete
                Right () -> do
                  observed <- observeKindNodeCreateIntent bootstrap intent stable
                  pure
                    (if observed == NodeCreateIntentMatches then NodeCreateIntentRecorded else NodeCreateIntentIncomplete)
    pure
      (either (const NodeCreateIntentRefused) id (checked :: Either IOException KindNodeCreateIntentWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeCreateIntentRefused -> result
    _ | changed -> NodeCreateIntentIncomplete
    _ -> NodeCreateIntentRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeCreateIntent
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCreateIntentObservation
observeKindNodeCreateIntent bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeCreateIntentUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- preconditions bootstrap intent stable sameRoot
              pure (if still then NodeCreateIntentMissing else NodeCreateIntentUnobservable)
            Left (_ :: IOException) -> pure NodeCreateIntentUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeCreateIntentUnobservable
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
                      then NodeCreateIntentUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (recordBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeCreateIntentMatches else NodeCreateIntentConflict
                        _ -> NodeCreateIntentInvalid
    pure
      ( either
          (const NodeCreateIntentUnobservable)
          id
          (checked :: Either IOException KindNodeCreateIntentObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeCreateIntentUnobservable

observeRecordedKindNodeCreateIntent
  :: BootstrapProjection -> String -> IO Bool -> IO KindNodeCreateRecoveryObservation
observeRecordedKindNodeCreateIntent bootstrap operation stable
  | not (validRootGeneration operation) = pure NodeCreateRecoveryUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          let ready = operationReady bootstrap operation stable sameRoot
          initialReady <- ready
          if not initialReady
            then pure NodeCreateRecoveryUnobservable
            else do
              owner <- getEffectiveUserID
              rootStatus <- Files.getFdStatus root
              opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready
                  pure (if still then NodeCreateRecoveryMissing else NodeCreateRecoveryUnobservable)
                Left (_ :: IOException) -> pure NodeCreateRecoveryUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  initial <- Files.getFdStatus held
                  if not (safeFile owner initial)
                    then pure NodeCreateRecoveryUnobservable
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
                        then pure NodeCreateRecoveryUnobservable
                        else case decodeCandidate bytes checkedValue of
                          Nothing -> pure NodeCreateRecoveryInvalid
                          Just (value, candidate) -> case Aeson.eitherDecodeStrict' (recordBytes bootstrap candidate rootStatus) of
                            Right expected | value == expected -> pure (NodeCreateRecoveryRecorded candidate)
                            _ -> pure NodeCreateRecoveryConflict
        pure
          ( either
              (const NodeCreateRecoveryUnobservable)
              id
              (checked :: Either IOException KindNodeCreateRecoveryObservation)
          )
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> NodeCreateRecoveryUnobservable
 where
  decodeCandidate bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right validated) | value == validated ->
      case parseEither parseCandidate value of
        Right (Just candidate) -> Just (value, candidate)
        _ -> Nothing
    _ -> Nothing
  parseCandidate = Aeson.withObject "node create intent" $ \object -> do
    recordedOperation <- object .: "operation_id"
    generation <- object .: "root_generation"
    tool <- object .: "kind_digest"
    image <- object .: "image_id"
    network <- object .: "network_id"
    arguments <- object .: "arguments"
    identifier <- object .: "daemon_id"
    device <- object .: "socket_device"
    inode <- object .: "socket_inode"
    owner <- object .: "socket_owner"
    mode <- object .: "socket_mode"
    pure $
      if recordedOperation == operation
        then
          mkKindNodeCreateIntent
            bootstrap
            (KindNodeCreateInput tool image network generation operation arguments)
            (DockerDaemonObserved identifier (DockerSocketIdentity device inode owner mode))
        else Nothing

data KindNodeCreateAttemptWrite
  = NodeCreateAttemptRecorded
  | NodeCreateAttemptAlreadyExists
  | NodeCreateAttemptRefused
  | NodeCreateAttemptIncomplete
  deriving (Eq, Show)

data KindNodeCreateAttemptObservation
  = NodeCreateAttemptMissing
  | NodeCreateAttemptMatches
  | NodeCreateAttemptConflict
  | NodeCreateAttemptInvalid
  | NodeCreateAttemptUnobservable
  deriving (Eq, Show)

recordKindNodeCreateAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCreateAttemptWrite
recordKindNodeCreateAttempt bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptPreconditions bootstrap intent stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = attemptBytes bootstrap intent rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeCreateAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) attemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeCreateAttemptAlreadyExists
            Left (_ :: IOException) -> pure NodeCreateAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeCreateAttemptIncomplete
                Right () -> do
                  observed <- observeKindNodeCreateAttempt bootstrap intent stable
                  pure
                    ( if observed == NodeCreateAttemptMatches
                        then NodeCreateAttemptRecorded
                        else NodeCreateAttemptIncomplete
                    )
    pure
      ( either
          (const NodeCreateAttemptRefused)
          id
          (checked :: Either IOException KindNodeCreateAttemptWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeCreateAttemptRefused -> result
    _ | changed -> NodeCreateAttemptIncomplete
    _ -> NodeCreateAttemptRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeCreateAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCreateAttemptObservation
observeKindNodeCreateAttempt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeCreateAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- attemptPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeCreateAttemptMissing else NodeCreateAttemptUnobservable)
            Left (_ :: IOException) -> pure NodeCreateAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeCreateAttemptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- attemptPreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeCreateAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (attemptBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeCreateAttemptMatches else NodeCreateAttemptConflict
                        _ -> NodeCreateAttemptInvalid
    pure
      ( either
          (const NodeCreateAttemptUnobservable)
          id
          (checked :: Either IOException KindNodeCreateAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeCreateAttemptUnobservable

attemptPreconditions :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO Bool -> IO Bool
attemptPreconditions bootstrap intent stable sameRoot = do
  before <- preconditions bootstrap intent stable sameRoot
  if not before
    then pure False
    else do
      parent <- observeKindNodeCreateIntent bootstrap intent stable
      after <- preconditions bootstrap intent stable sameRoot
      pure (parent == NodeCreateIntentMatches && after)

attemptBytes :: BootstrapProjection -> KindNodeCreateIntent -> Files.FileStatus -> BS.ByteString
attemptBytes bootstrap intent root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-create-attempt" :: String)
        , "intent" Aeson..= TextEncoding.decodeUtf8 (recordBytes bootstrap intent root)
        ]

data KindNodeCreateResultWrite
  = NodeCreateResultRecorded
  | NodeCreateResultAlreadyExists
  | NodeCreateResultRefused
  | NodeCreateResultIncomplete
  deriving (Eq, Show)

data KindNodeCreateResultObservation
  = NodeCreateResultMissing
  | NodeCreateResultObserved !DockerNodeContainerCreateResult
  | NodeCreateResultConflict
  | NodeCreateResultInvalid
  | NodeCreateResultUnobservable
  deriving (Eq, Show)

recordKindNodeCreateResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> DockerNodeContainerCreateResult
  -> IO Bool
  -> IO KindNodeCreateResultWrite
recordKindNodeCreateResult bootstrap intent result stable
  | not (validCreateResult result) = pure NodeCreateResultRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- resultPreconditions bootstrap intent stable sameRoot
          rootStatus <- Files.getFdStatus root
          let bytes = resultBytes bootstrap intent result rootStatus
          if not ready || BS.length bytes > 8192
            then pure NodeCreateResultRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) resultName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeCreateResultAlreadyExists
                Left (_ :: IOException) -> pure NodeCreateResultRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeCreateResultIncomplete
                    Right () -> do
                      observed <- observeKindNodeCreateResult bootstrap intent stable
                      pure
                        ( if observed == NodeCreateResultObserved result
                            then NodeCreateResultRecorded
                            else NodeCreateResultIncomplete
                        )
        pure
          ( either
              (const NodeCreateResultRefused)
              id
              (checked :: Either IOException KindNodeCreateResultWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeCreateResultRefused -> outcomeValue
        _ | changed -> NodeCreateResultIncomplete
        _ -> NodeCreateResultRefused

observeKindNodeCreateResult
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCreateResultObservation
observeKindNodeCreateResult bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- resultPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeCreateResultUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) resultName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- resultPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeCreateResultMissing else NodeCreateResultUnobservable)
            Left (_ :: IOException) -> pure NodeCreateResultUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeCreateResultUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) resultName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- resultPreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeCreateResultUnobservable
                      else decodeCreateResult bootstrap intent rootStatus bytes decoded
    pure
      ( either
          (const NodeCreateResultUnobservable)
          id
          (checked :: Either IOException KindNodeCreateResultObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeCreateResultUnobservable

resultPreconditions :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO Bool -> IO Bool
resultPreconditions bootstrap intent stable sameRoot = do
  first <- stable
  root <- sameRoot
  if not (first && root)
    then pure False
    else do
      parent <- observeKindNodeCreateAttempt bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeCreateAttemptMatches && afterRoot && after)

validCreateResult :: DockerNodeContainerCreateResult -> Bool
validCreateResult DockerNodeContainerCreateNotStarted = True
validCreateResult DockerNodeContainerCreateUnconfirmed = True
validCreateResult (DockerNodeContainerCreateReply status identifier) =
  status >= 100 && status <= 599 && case (status, identifier) of
    (201, Just value) -> validImageId ("sha256:" ++ value)
    (201, Nothing) -> False
    (_, Nothing) -> True
    _ -> False

resultBytes
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> DockerNodeContainerCreateResult
  -> Files.FileStatus
  -> BS.ByteString
resultBytes bootstrap intent result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-create-result" :: String)
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        , "transport" Aeson..= createResultValue result
        ]

createResultValue :: DockerNodeContainerCreateResult -> Aeson.Value
createResultValue result = case result of
  DockerNodeContainerCreateNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeContainerCreateUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeContainerCreateReply status identifier ->
    Aeson.object
      ["state" Aeson..= ("reply" :: String), "status" Aeson..= status, "container_id" Aeson..= identifier]

decodeCreateResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeCreateResultObservation
decodeCreateResult bootstrap intent root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validCreateResult result -> case Aeson.eitherDecodeStrict' (resultBytes bootstrap intent result root) of
      Right wanted | value == wanted -> NodeCreateResultObserved result
      _ -> NodeCreateResultConflict
    _ -> NodeCreateResultInvalid
  _ -> NodeCreateResultInvalid
 where
  parser = Aeson.withObject "node create result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeContainerCreateNotStarted
              "unconfirmed" -> pure DockerNodeContainerCreateUnconfirmed
              "reply" -> DockerNodeContainerCreateReply <$> transport .: "status" <*> transport .: "container_id"
              _ -> fail "invalid node create result"
        )

-- A candidate record preserves only a repeated inventory observation. It is
-- not provenance, admission, a create reply or proof of worker settlement.
data KindNodeCandidateWrite
  = NodeCandidateRecorded
  | NodeCandidateAlreadyExists
  | NodeCandidateRefused
  | NodeCandidatePositiveControlRefused !NodeRemovalReadback
  | NodeCandidateIncomplete
  deriving (Eq, Show)

data KindNodeCandidateObservation
  = NodeCandidateRecordMissing
  | NodeCandidateRecordObserved !String
  | NodeCandidateRecordConflict
  | NodeCandidateRecordInvalid
  | NodeCandidateRecordUnobservable
  deriving (Eq, Show)

recordKindNodeCandidate
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeCandidateWrite
recordKindNodeCandidate bootstrap intent identifier stable
  | not (validImageId ("sha256:" ++ identifier)) = pure NodeCandidateRefused
  | otherwise = do
      prior <- observeRecordedKindNodeCandidate bootstrap intent stable
      case prior of
        NodeCandidateRecordMissing -> do
          positive <-
            observeNodeRemovalPositiveControl bootstrap (kindNodeCreateDaemon intent) identifier stable
          if not (candidatePositive identifier positive)
            then pure (NodeCandidatePositiveControlRefused positive)
            else publishCandidate bootstrap intent identifier stable
        NodeCandidateRecordObserved observed
          | observed == identifier -> pure NodeCandidateAlreadyExists
          | otherwise -> pure NodeCandidateRefused
        _ -> pure NodeCandidateRefused

candidatePositive :: String -> NodeRemovalReadback -> Bool
candidatePositive identifier observation =
  nodeRemovalPositive identifier observation && case observation of
    NodeRemovalReadbackSampled inventory -> nodeRemovalClusterIds inventory == [identifier]
    _ -> False

publishCandidate
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeCandidateWrite
publishCandidate bootstrap intent identifier stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- candidatePreconditions bootstrap intent stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = candidateBytes bootstrap intent identifier rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeCandidateRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) candidateName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeCandidateAlreadyExists
            Left (_ :: IOException) -> pure NodeCandidateRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeCandidateIncomplete
                Right () -> do
                  observed <- observeRecordedKindNodeCandidate bootstrap intent stable
                  pure
                    ( if observed == NodeCandidateRecordObserved identifier
                        then NodeCandidateRecorded
                        else NodeCandidateIncomplete
                    )
    pure (either (const NodeCandidateRefused) id (checked :: Either IOException KindNodeCandidateWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeCandidateRefused -> result
    _ | changed -> NodeCandidateIncomplete
    _ -> NodeCandidateRefused

observeRecordedKindNodeCandidate
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO KindNodeCandidateObservation
observeRecordedKindNodeCandidate bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- candidatePreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeCandidateRecordUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) candidateName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- candidatePreconditions bootstrap intent stable sameRoot
              pure (if still then NodeCandidateRecordMissing else NodeCandidateRecordUnobservable)
            Left (_ :: IOException) -> pure NodeCandidateRecordUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeCandidateRecordUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) candidateName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- candidatePreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeCandidateRecordUnobservable
                      else case (Aeson.eitherDecodeStrict' bytes, decoded) of
                        (Right value, Right checkedValue) | value == checkedValue ->
                          case parseEither (Aeson.withObject "node candidate" (.: "container_id")) value of
                            Right identifier | validImageId ("sha256:" ++ identifier) ->
                              case Aeson.eitherDecodeStrict' (candidateBytes bootstrap intent identifier rootStatus) of
                                Right expected | value == expected -> NodeCandidateRecordObserved identifier
                                _ -> NodeCandidateRecordConflict
                            _ -> NodeCandidateRecordInvalid
                        _ -> NodeCandidateRecordInvalid
    pure
      ( either
          (const NodeCandidateRecordUnobservable)
          id
          (checked :: Either IOException KindNodeCandidateObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeCandidateRecordUnobservable

candidatePreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO Bool -> IO Bool
candidatePreconditions bootstrap intent stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      result <- observeKindNodeCreateResult bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (candidateUncertain result && afterRoot && after)

candidateUncertain :: KindNodeCreateResultObservation -> Bool
candidateUncertain NodeCreateResultMissing = True
candidateUncertain (NodeCreateResultObserved DockerNodeContainerCreateUnconfirmed) = True
candidateUncertain _ = False

candidateBytes
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> Files.FileStatus -> BS.ByteString
candidateBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-unconfirmed-candidate" :: String)
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        , "container_id" Aeson..= identifier
        , "inventory" Aeson..= (["all", "name", "cluster-label"] :: [String])
        ]

data KindNodeStartAttemptWrite
  = NodeStartAttemptRecorded
  | NodeStartAttemptAlreadyExists
  | NodeStartAttemptRefused
  | NodeStartAttemptIncomplete
  deriving (Eq, Show)

data KindNodeStartAttemptObservation
  = NodeStartAttemptMissing
  | NodeStartAttemptMatches
  | NodeStartAttemptConflict
  | NodeStartAttemptInvalid
  | NodeStartAttemptUnobservable
  deriving (Eq, Show)

recordKindNodeStartAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeStartAttemptWrite
recordKindNodeStartAttempt bootstrap intent identifier stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- startPreconditions bootstrap intent identifier stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = startAttemptBytes bootstrap intent identifier rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeStartAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) startAttemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeStartAttemptAlreadyExists
            Left (_ :: IOException) -> pure NodeStartAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeStartAttemptIncomplete
                Right () -> do
                  observed <- observeKindNodeStartAttempt bootstrap intent identifier stable
                  pure
                    ( if observed == NodeStartAttemptMatches
                        then NodeStartAttemptRecorded
                        else NodeStartAttemptIncomplete
                    )
    pure
      ( either
          (const NodeStartAttemptRefused)
          id
          (checked :: Either IOException KindNodeStartAttemptWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeStartAttemptRefused -> result
    _ | changed -> NodeStartAttemptIncomplete
    _ -> NodeStartAttemptRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeStartAttempt
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeStartAttemptObservation
observeKindNodeStartAttempt bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- startPreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeStartAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) startAttemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- startPreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeStartAttemptMissing else NodeStartAttemptUnobservable)
            Left (_ :: IOException) -> pure NodeStartAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeStartAttemptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) startAttemptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- startPreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeStartAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (startAttemptBytes bootstrap intent identifier rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeStartAttemptMatches else NodeStartAttemptConflict
                        _ -> NodeStartAttemptInvalid
    pure
      ( either
          (const NodeStartAttemptUnobservable)
          id
          (checked :: Either IOException KindNodeStartAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeStartAttemptUnobservable

startPreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
startPreconditions bootstrap intent identifier stable sameRoot = do
  first <- stable
  root <- sameRoot
  if not (first && root && validImageId ("sha256:" ++ identifier))
    then pure False
    else do
      parent <- observeKindNodeCreateResult bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure
        ( parent == NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier))
            && afterRoot
            && after
        )

startAttemptBytes
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> Files.FileStatus -> BS.ByteString
startAttemptBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-start-attempt" :: String)
        , "create_result"
            Aeson..= TextEncoding.decodeUtf8
              (resultBytes bootstrap intent (DockerNodeContainerCreateReply 201 (Just identifier)) root)
        ]

data KindNodeConfigAttemptWrite
  = NodeConfigAttemptRecorded
  | NodeConfigAttemptAlreadyExists
  | NodeConfigAttemptRefused
  | NodeConfigAttemptIncomplete
  deriving (Eq, Show)

data KindNodeConfigAttemptObservation
  = NodeConfigAttemptMissing
  | NodeConfigAttemptMatches
  | NodeConfigAttemptConflict
  | NodeConfigAttemptInvalid
  | NodeConfigAttemptUnobservable
  deriving (Eq, Show)

recordKindNodeConfigAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeConfigAttemptWrite
recordKindNodeConfigAttempt bootstrap intent identifier stable = do
  touched <- newIORef False
  let admissionStable = do
        before <- stable
        removal <- observeKindNodeRemoveAttempt bootstrap intent identifier stable
        after <- stable
        pure (before && removal == NodeRemoveAttemptMissing && after)
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- configPreconditions bootstrap intent identifier admissionStable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = configAttemptBytes bootstrap intent identifier rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeConfigAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) configAttemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeConfigAttemptAlreadyExists
            Left (_ :: IOException) -> pure NodeConfigAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeConfigAttemptIncomplete
                Right () -> do
                  observed <- observeKindNodeConfigAttempt bootstrap intent identifier admissionStable
                  pure
                    ( if observed == NodeConfigAttemptMatches
                        then NodeConfigAttemptRecorded
                        else NodeConfigAttemptIncomplete
                    )
    pure
      ( either
          (const NodeConfigAttemptRefused)
          id
          (checked :: Either IOException KindNodeConfigAttemptWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeConfigAttemptRefused -> result
    _ | changed -> NodeConfigAttemptIncomplete
    _ -> NodeConfigAttemptRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeConfigAttempt
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeConfigAttemptObservation
observeKindNodeConfigAttempt bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- configPreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeConfigAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) configAttemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- configPreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeConfigAttemptMissing else NodeConfigAttemptUnobservable)
            Left (_ :: IOException) -> pure NodeConfigAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeConfigAttemptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) configAttemptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- configPreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeConfigAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (configAttemptBytes bootstrap intent identifier rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeConfigAttemptMatches else NodeConfigAttemptConflict
                        _ -> NodeConfigAttemptInvalid
    pure
      ( either
          (const NodeConfigAttemptUnobservable)
          id
          (checked :: Either IOException KindNodeConfigAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeConfigAttemptUnobservable

configPreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
configPreconditions bootstrap intent identifier stable sameRoot = do
  first <- stable
  root <- sameRoot
  if not (first && root && validImageId ("sha256:" ++ identifier))
    then pure False
    else do
      parent <- observeKindNodeStartResult bootstrap intent identifier (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure
        ( parent == NodeStartResultObserved (DockerNodeContainerStartReply 204)
            && afterRoot
            && after
        )

configAttemptBytes
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> Files.FileStatus -> BS.ByteString
configAttemptBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-config-attempt" :: String)
        , "path" Aeson..= ("/kind/kubeadm.conf" :: String)
        , "start_result"
            Aeson..= TextEncoding.decodeUtf8
              (startResultBytes bootstrap intent identifier (DockerNodeContainerStartReply 204) root)
        ]

data KindNodeStartResultWrite
  = NodeStartResultRecorded
  | NodeStartResultAlreadyExists
  | NodeStartResultRefused
  | NodeStartResultIncomplete
  deriving (Eq, Show)

data KindNodeStartResultObservation
  = NodeStartResultMissing
  | NodeStartResultObserved !DockerNodeContainerStartResult
  | NodeStartResultConflict
  | NodeStartResultInvalid
  | NodeStartResultUnobservable
  deriving (Eq, Show)

recordKindNodeStartResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerStartResult
  -> IO Bool
  -> IO KindNodeStartResultWrite
recordKindNodeStartResult bootstrap intent identifier result stable
  | not (validStartResult result) = pure NodeStartResultRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- startResultPreconditions bootstrap intent identifier stable sameRoot
          rootStatus <- Files.getFdStatus root
          let bytes = startResultBytes bootstrap intent identifier result rootStatus
          if not ready || BS.length bytes > 8192
            then pure NodeStartResultRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) startResultName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeStartResultAlreadyExists
                Left (_ :: IOException) -> pure NodeStartResultRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeStartResultIncomplete
                    Right () -> do
                      observed <- observeKindNodeStartResult bootstrap intent identifier stable
                      pure
                        ( if observed == NodeStartResultObserved result
                            then NodeStartResultRecorded
                            else NodeStartResultIncomplete
                        )
        pure
          ( either
              (const NodeStartResultRefused)
              id
              (checked :: Either IOException KindNodeStartResultWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeStartResultRefused -> outcomeValue
        _ | changed -> NodeStartResultIncomplete
        _ -> NodeStartResultRefused

observeKindNodeStartResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeStartResultObservation
observeKindNodeStartResult bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- startResultPreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeStartResultUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) startResultName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- startResultPreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeStartResultMissing else NodeStartResultUnobservable)
            Left (_ :: IOException) -> pure NodeStartResultUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeStartResultUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) startResultName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- startResultPreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeStartResultUnobservable
                      else decodeStartResult bootstrap intent identifier rootStatus bytes decoded
    pure
      ( either
          (const NodeStartResultUnobservable)
          id
          (checked :: Either IOException KindNodeStartResultObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeStartResultUnobservable

startResultPreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
startResultPreconditions bootstrap intent identifier stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeStartAttempt bootstrap intent identifier (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeStartAttemptMatches && afterRoot && after)

validStartResult :: DockerNodeContainerStartResult -> Bool
validStartResult DockerNodeContainerStartNotStarted = True
validStartResult DockerNodeContainerStartUnconfirmed = True
validStartResult (DockerNodeContainerStartReply status) = status >= 100 && status <= 599

startResultBytes
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerStartResult
  -> Files.FileStatus
  -> BS.ByteString
startResultBytes bootstrap intent identifier result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-start-result" :: String)
        , "attempt"
            Aeson..= (Aeson.decodeStrict' (startAttemptBytes bootstrap intent identifier root) :: Maybe Aeson.Value)
        , "transport" Aeson..= startResultValue result
        ]

startResultValue :: DockerNodeContainerStartResult -> Aeson.Value
startResultValue result = case result of
  DockerNodeContainerStartNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeContainerStartUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeContainerStartReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]

decodeStartResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeStartResultObservation
decodeStartResult bootstrap intent identifier root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validStartResult result -> case Aeson.eitherDecodeStrict' (startResultBytes bootstrap intent identifier result root) of
      Right wanted | value == wanted -> NodeStartResultObserved result
      _ -> NodeStartResultConflict
    _ -> NodeStartResultInvalid
  _ -> NodeStartResultInvalid
 where
  parser = Aeson.withObject "node start result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeContainerStartNotStarted
              "unconfirmed" -> pure DockerNodeContainerStartUnconfirmed
              "reply" -> DockerNodeContainerStartReply <$> transport .: "status"
              _ -> fail "invalid node start result"
        )

data KindNodeConfigResultWrite
  = NodeConfigResultRecorded
  | NodeConfigResultAlreadyExists
  | NodeConfigResultRefused
  | NodeConfigResultIncomplete
  deriving (Eq, Show)

data KindNodeConfigResultObservation
  = NodeConfigResultMissing
  | NodeConfigResultObserved !DockerNodeConfigWriteResult
  | NodeConfigResultConflict
  | NodeConfigResultInvalid
  | NodeConfigResultUnobservable
  deriving (Eq, Show)

recordKindNodeConfigResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeConfigWriteResult
  -> IO Bool
  -> IO KindNodeConfigResultWrite
recordKindNodeConfigResult bootstrap intent identifier result stable
  | not (validConfigResult result) = pure NodeConfigResultRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- configResultPreconditions bootstrap intent identifier stable sameRoot
          rootStatus <- Files.getFdStatus root
          let bytes = configResultBytes bootstrap intent identifier result rootStatus
          if not ready || BS.length bytes > 8192
            then pure NodeConfigResultRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) configResultName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeConfigResultAlreadyExists
                Left (_ :: IOException) -> pure NodeConfigResultRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeConfigResultIncomplete
                    Right () -> do
                      observed <- observeKindNodeConfigResult bootstrap intent identifier stable
                      pure
                        ( if observed == NodeConfigResultObserved result
                            then NodeConfigResultRecorded
                            else NodeConfigResultIncomplete
                        )
        pure
          ( either
              (const NodeConfigResultRefused)
              id
              (checked :: Either IOException KindNodeConfigResultWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeConfigResultRefused -> outcomeValue
        _ | changed -> NodeConfigResultIncomplete
        _ -> NodeConfigResultRefused

observeKindNodeConfigResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeConfigResultObservation
observeKindNodeConfigResult bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- configResultPreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeConfigResultUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) configResultName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- configResultPreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeConfigResultMissing else NodeConfigResultUnobservable)
            Left (_ :: IOException) -> pure NodeConfigResultUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeConfigResultUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) configResultName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- configResultPreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeConfigResultUnobservable
                      else decodeConfigResult bootstrap intent identifier rootStatus bytes decoded
    pure
      ( either
          (const NodeConfigResultUnobservable)
          id
          (checked :: Either IOException KindNodeConfigResultObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeConfigResultUnobservable

configResultPreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
configResultPreconditions bootstrap intent identifier stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeConfigAttempt bootstrap intent identifier (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeConfigAttemptMatches && afterRoot && after)

validConfigResult :: DockerNodeConfigWriteResult -> Bool
validConfigResult DockerNodeConfigWriteNotStarted = True
validConfigResult DockerNodeConfigWriteUnconfirmed = True
validConfigResult (DockerNodeConfigWriteReply status) = status >= 100 && status <= 599

configResultBytes
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeConfigWriteResult
  -> Files.FileStatus
  -> BS.ByteString
configResultBytes bootstrap intent identifier result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-config-result" :: String)
        , "attempt"
            Aeson..= (Aeson.decodeStrict' (configAttemptBytes bootstrap intent identifier root) :: Maybe Aeson.Value)
        , "transport" Aeson..= configResultValue result
        ]

configResultValue :: DockerNodeConfigWriteResult -> Aeson.Value
configResultValue result = case result of
  DockerNodeConfigWriteNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeConfigWriteUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeConfigWriteReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]

decodeConfigResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeConfigResultObservation
decodeConfigResult bootstrap intent identifier root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validConfigResult result -> case Aeson.eitherDecodeStrict' (configResultBytes bootstrap intent identifier result root) of
      Right wanted | value == wanted -> NodeConfigResultObserved result
      _ -> NodeConfigResultConflict
    _ -> NodeConfigResultInvalid
  _ -> NodeConfigResultInvalid
 where
  parser = Aeson.withObject "node config result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeConfigWriteNotStarted
              "unconfirmed" -> pure DockerNodeConfigWriteUnconfirmed
              "reply" -> DockerNodeConfigWriteReply <$> transport .: "status"
              _ -> fail "invalid node config result"
        )

data KindNodeRemoveControlWrite
  = NodeRemoveControlRecorded
  | NodeRemoveControlAlreadyExists
  | NodeRemoveControlRefused
  | NodeRemoveControlIncomplete
  deriving (Eq, Show)

data KindNodeRemoveControlObservation
  = NodeRemoveControlMissing
  | NodeRemoveControlMatches
  | NodeRemoveControlConflict
  | NodeRemoveControlInvalid
  | NodeRemoveControlUnobservable
  deriving (Eq, Show)

recordKindNodeRemoveControl
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeRemoveControlWrite
recordKindNodeRemoveControl bootstrap intent identifier stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removePreconditions bootstrap intent identifier stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = removeControlBytes bootstrap intent identifier rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeRemoveControlRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) removeControlName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeRemoveControlAlreadyExists
            Left (_ :: IOException) -> pure NodeRemoveControlRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeRemoveControlIncomplete
                Right () -> do
                  observed <- observeKindNodeRemoveControl bootstrap intent identifier stable
                  pure
                    ( if observed == NodeRemoveControlMatches
                        then NodeRemoveControlRecorded
                        else NodeRemoveControlIncomplete
                    )
    pure
      ( either
          (const NodeRemoveControlRefused)
          id
          (checked :: Either IOException KindNodeRemoveControlWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeRemoveControlRefused -> result
    _ | changed -> NodeRemoveControlIncomplete
    _ -> NodeRemoveControlRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeRemoveControl
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveControlObservation
observeKindNodeRemoveControl bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removePreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeRemoveControlUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) removeControlName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- removePreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeRemoveControlMissing else NodeRemoveControlUnobservable)
            Left (_ :: IOException) -> pure NodeRemoveControlUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeRemoveControlUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) removeControlName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removePreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeRemoveControlUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (removeControlBytes bootstrap intent identifier rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeRemoveControlMatches else NodeRemoveControlConflict
                        _ -> NodeRemoveControlInvalid
    pure
      ( either
          (const NodeRemoveControlUnobservable)
          id
          (checked :: Either IOException KindNodeRemoveControlObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeRemoveControlUnobservable

data KindNodeRemoveAttemptWrite
  = NodeRemoveAttemptRecorded
  | NodeRemoveAttemptAlreadyExists
  | NodeRemoveAttemptRefused
  | NodeRemoveAttemptPositiveControlRefused !NodeRemovalReadback
  | NodeRemoveAttemptIncomplete
  deriving (Eq, Show)

data KindNodeRemoveAttemptObservation
  = NodeRemoveAttemptMissing
  | NodeRemoveAttemptMatches
  | NodeRemoveAttemptConflict
  | NodeRemoveAttemptInvalid
  | NodeRemoveAttemptUnobservable
  deriving (Eq, Show)

recordKindNodeRemoveAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeRemoveAttemptWrite
recordKindNodeRemoveAttempt bootstrap intent identifier stable = do
  prior <- observeKindNodeRemoveAttempt bootstrap intent identifier stable
  case prior of
    NodeRemoveAttemptMatches -> pure NodeRemoveAttemptAlreadyExists
    NodeRemoveAttemptMissing -> do
      positive <-
        observeNodeRemovalPositiveControl bootstrap (kindNodeCreateDaemon intent) identifier stable
      if not (nodeRemovalPositive identifier positive)
        then pure (NodeRemoveAttemptPositiveControlRefused positive)
        else do
          control <- recordKindNodeRemoveControl bootstrap intent identifier stable
          observed <- observeKindNodeRemoveControl bootstrap intent identifier stable
          case (control, observed) of
            (NodeRemoveControlRecorded, NodeRemoveControlMatches) -> recordAfterControl
            (NodeRemoveControlAlreadyExists, NodeRemoveControlMatches) -> recordAfterControl
            (NodeRemoveControlRecorded, _) -> pure NodeRemoveAttemptIncomplete
            (NodeRemoveControlIncomplete, _) -> pure NodeRemoveAttemptIncomplete
            _ -> pure NodeRemoveAttemptRefused
     where
      recordAfterControl = do
        let controlStable = do
              before <- stable
              current <- observeKindNodeRemoveControl bootstrap intent identifier stable
              after <- stable
              pure (before && current == NodeRemoveControlMatches && after)
        recordNodeRemoveAttemptAfterControl bootstrap intent identifier controlStable
    _ -> pure NodeRemoveAttemptRefused

recordNodeRemoveAttemptAfterControl
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeRemoveAttemptWrite
recordNodeRemoveAttemptAfterControl bootstrap intent identifier stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removePreconditions bootstrap intent identifier stable sameRoot
      rootStatus <- Files.getFdStatus root
      let bytes = removeAttemptBytes bootstrap intent identifier rootStatus
      if not ready || BS.length bytes > 8192
        then pure NodeRemoveAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) removeAttemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeRemoveAttemptAlreadyExists
            Left (_ :: IOException) -> pure NodeRemoveAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                writeAll held bytes
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeRemoveAttemptIncomplete
                Right () -> do
                  observed <- observeKindNodeRemoveAttempt bootstrap intent identifier stable
                  pure
                    ( if observed == NodeRemoveAttemptMatches
                        then NodeRemoveAttemptRecorded
                        else NodeRemoveAttemptIncomplete
                    )
    pure
      ( either
          (const NodeRemoveAttemptRefused)
          id
          (checked :: Either IOException KindNodeRemoveAttemptWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeRemoveAttemptRefused -> result
    _ | changed -> NodeRemoveAttemptIncomplete
    _ -> NodeRemoveAttemptRefused

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeRemoveAttempt
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveAttemptObservation
observeKindNodeRemoveAttempt bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removePreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeRemoveAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) removeAttemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- removePreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeRemoveAttemptMissing else NodeRemoveAttemptUnobservable)
            Left (_ :: IOException) -> pure NodeRemoveAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeRemoveAttemptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) removeAttemptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removePreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeRemoveAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (removeAttemptBytes bootstrap intent identifier rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeRemoveAttemptMatches else NodeRemoveAttemptConflict
                        _ -> NodeRemoveAttemptInvalid
    pure
      ( either
          (const NodeRemoveAttemptUnobservable)
          id
          (checked :: Either IOException KindNodeRemoveAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeRemoveAttemptUnobservable

removeControlBytes
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> Files.FileStatus -> BS.ByteString
removeControlBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-remove-positive-control" :: String)
        , "attempt_binding"
            Aeson..= TextEncoding.decodeUtf8 (removeAttemptBytes bootstrap intent identifier root)
        , "projections" Aeson..= (["all", "name", "cluster-label"] :: [String])
        ]

removePreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
removePreconditions bootstrap intent identifier stable sameRoot = do
  first <- stable
  root <- sameRoot
  if not (first && root && validImageId ("sha256:" ++ identifier))
    then pure False
    else do
      parent <- observeKindNodeCreateResult bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure
        ( parent == NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier))
            && afterRoot
            && after
        )

removeAttemptBytes
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> Files.FileStatus -> BS.ByteString
removeAttemptBytes bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-remove-attempt" :: String)
        , "create_result"
            Aeson..= TextEncoding.decodeUtf8
              (resultBytes bootstrap intent (DockerNodeContainerCreateReply 201 (Just identifier)) root)
        ]

data KindNodeRemoveResultWrite
  = NodeRemoveResultRecorded
  | NodeRemoveResultAlreadyExists
  | NodeRemoveResultRefused
  | NodeRemoveResultIncomplete
  deriving (Eq, Show)

data KindNodeRemoveResultObservation
  = NodeRemoveResultMissing
  | NodeRemoveResultObserved !DockerNodeContainerRemoveResult
  | NodeRemoveResultConflict
  | NodeRemoveResultInvalid
  | NodeRemoveResultUnobservable
  deriving (Eq, Show)

recordKindNodeRemoveResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerRemoveResult
  -> IO Bool
  -> IO KindNodeRemoveResultWrite
recordKindNodeRemoveResult bootstrap intent identifier result stable
  | not (validRemoveResult result) = pure NodeRemoveResultRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- removeResultPreconditions bootstrap intent identifier stable sameRoot
          rootStatus <- Files.getFdStatus root
          let bytes = removeResultBytes bootstrap intent identifier result rootStatus
          if not ready || BS.length bytes > 8192
            then pure NodeRemoveResultRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) removeResultName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeRemoveResultAlreadyExists
                Left (_ :: IOException) -> pure NodeRemoveResultRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held bytes
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeRemoveResultIncomplete
                    Right () -> do
                      observed <- observeKindNodeRemoveResult bootstrap intent identifier stable
                      pure
                        ( if observed == NodeRemoveResultObserved result
                            then NodeRemoveResultRecorded
                            else NodeRemoveResultIncomplete
                        )
        pure
          ( either
              (const NodeRemoveResultRefused)
              id
              (checked :: Either IOException KindNodeRemoveResultWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeRemoveResultRefused -> outcomeValue
        _ | changed -> NodeRemoveResultIncomplete
        _ -> NodeRemoveResultRefused

observeKindNodeRemoveResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveResultObservation
observeKindNodeRemoveResult bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removeResultPreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeRemoveResultUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) removeResultName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- removeResultPreconditions bootstrap intent identifier stable sameRoot
              pure (if still then NodeRemoveResultMissing else NodeRemoveResultUnobservable)
            Left (_ :: IOException) -> pure NodeRemoveResultUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeRemoveResultUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) removeResultName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removeResultPreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeRemoveResultUnobservable
                      else decodeRemoveResult bootstrap intent identifier rootStatus bytes decoded
    pure
      ( either
          (const NodeRemoveResultUnobservable)
          id
          (checked :: Either IOException KindNodeRemoveResultObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeRemoveResultUnobservable

removeResultPreconditions
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO Bool -> IO Bool
removeResultPreconditions bootstrap intent identifier stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeRemoveAttempt bootstrap intent identifier (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeRemoveAttemptMatches && afterRoot && after)

validRemoveResult :: DockerNodeContainerRemoveResult -> Bool
validRemoveResult DockerNodeContainerRemoveNotStarted = True
validRemoveResult DockerNodeContainerRemoveUnconfirmed = True
validRemoveResult (DockerNodeContainerRemoveReply status) = status >= 100 && status <= 599

removeResultBytes
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerRemoveResult
  -> Files.FileStatus
  -> BS.ByteString
removeResultBytes bootstrap intent identifier result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-remove-result" :: String)
        , "attempt"
            Aeson..= (Aeson.decodeStrict' (removeAttemptBytes bootstrap intent identifier root) :: Maybe Aeson.Value)
        , "transport" Aeson..= removeResultValue result
        ]

removeResultValue :: DockerNodeContainerRemoveResult -> Aeson.Value
removeResultValue result = case result of
  DockerNodeContainerRemoveNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeContainerRemoveUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeContainerRemoveReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]

decodeRemoveResult
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeRemoveResultObservation
decodeRemoveResult bootstrap intent identifier root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validRemoveResult result -> case Aeson.eitherDecodeStrict' (removeResultBytes bootstrap intent identifier result root) of
      Right wanted | value == wanted -> NodeRemoveResultObserved result
      _ -> NodeRemoveResultConflict
    _ -> NodeRemoveResultInvalid
  _ -> NodeRemoveResultInvalid
 where
  parser = Aeson.withObject "node remove result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeContainerRemoveNotStarted
              "unconfirmed" -> pure DockerNodeContainerRemoveUnconfirmed
              "reply" -> DockerNodeContainerRemoveReply <$> transport .: "status"
              _ -> fail "invalid node remove result"
        )

preconditions :: BootstrapProjection -> KindNodeCreateIntent -> IO Bool -> IO Bool -> IO Bool
preconditions bootstrap intent@(KindNodeCreateIntent input identifier socket) stable sameRoot
  | mkKindNodeCreateIntent bootstrap input (DockerDaemonObserved identifier socket) /= Just intent =
      pure False
  | otherwise = operationReady bootstrap (nodeCreateOperation input) stable sameRoot

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

recordBytes :: BootstrapProjection -> KindNodeCreateIntent -> Files.FileStatus -> BS.ByteString
recordBytes bootstrap (KindNodeCreateIntent input daemon (DockerSocketIdentity device inode owner mode)) root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "operation_id" Aeson..= nodeCreateOperation input
        , "operation" Aeson..= ("kind-node-create" :: String)
        , "node" Aeson..= (scopeKindName (bootstrapScope bootstrap) ++ "-control-plane")
        , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
        , "root_device" Aeson..= toInteger (Files.deviceID root)
        , "root_inode" Aeson..= toInteger (Files.fileID root)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "kind_digest" Aeson..= nodeCreateToolDigest input
        , "image_id" Aeson..= nodeCreateImageId input
        , "network_id" Aeson..= nodeCreateNetworkId input
        , "arguments" Aeson..= nodeCreateArguments input
        , "body" Aeson..= kindNodeCreateBody (bootstrapKindPlan bootstrap) input
        , "daemon_id" Aeson..= daemon
        , "socket_device" Aeson..= device
        , "socket_inode" Aeson..= inode
        , "socket_owner" Aeson..= owner
        , "socket_mode" Aeson..= mode
        ]

recordName :: FilePath
recordName = "kind-node-create-intent.json"

attemptName :: FilePath
attemptName = "kind-node-create-attempt.json"

resultName :: FilePath
resultName = "kind-node-create-result.json"

candidateName :: FilePath
candidateName = "kind-node-create-candidate.json"

startAttemptName :: FilePath
startAttemptName = "kind-node-start-attempt.json"

configAttemptName :: FilePath
configAttemptName = "kind-node-config-attempt.json"

configResultName :: FilePath
configResultName = "kind-node-config-result.json"

startResultName :: FilePath
startResultName = "kind-node-start-result.json"

removeControlName :: FilePath
removeControlName = "kind-node-remove-positive-control.json"

removeAttemptName :: FilePath
removeAttemptName = "kind-node-remove-attempt.json"

removeResultName :: FilePath
removeResultName = "kind-node-remove-result.json"

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
    then ioError (userError "short node volume intent write")
    else writeAll fd (BS.drop (fromIntegral count) bytes)
