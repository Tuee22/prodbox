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
  , KindNodeRemoveControlWrite (..)
  , recordKindNodeRemoveControl
  , observeKindNodeRemoveControl
  , KindNodeRemovePass (..)
  , KindNodeRemoveAttemptWrite (..)
  , KindNodeRemoveAttemptObservation (..)
  , recordKindNodeRemoveAttempt
  , observeKindNodeRemoveAttempt
  , recordKindNodeRemoveRecoveryAttempt
  , observeKindNodeRemoveRecoveryPredecessor
  , observeKindNodeRemoveAttemptFor
  , KindNodeRemoveResultWrite (..)
  , KindNodeRemoveResultObservation (..)
  , recordKindNodeRemoveResult
  , observeKindNodeRemoveResult
  , recordKindNodeRemoveResultFor
  , observeKindNodeRemoveResultFor
  , KindAbsencePlan
  , KindAbsencePlanRecovery (..)
  , mkKindAbsencePlan
  , recoverKindAbsencePlan
  , kindAbsenceOperation
  , kindAbsenceDaemon
  , kindAbsenceTarget
  , kindAbsenceImage
  , kindAbsenceImageVolumes
  , KindAbsenceStage (..)
  , KindAbsenceWrite (..)
  , KindAbsenceObservation (..)
  , KindAbsenceIdObservation (..)
  , KindAbsenceFootprintObservation (..)
  , KindAbsenceVolumeResultObservation (..)
  , KindAbsenceControlResultObservation (..)
  , recordKindAbsenceStage
  , observeKindAbsenceStage
  , recoverKindAbsenceControlId
  , recoverKindAbsenceFootprint
  , recoverKindAbsenceVolumeResult
  , recoverKindAbsenceControlResult
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub, sort)
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
  ( DockerImageVolumes (..)
  , DockerNodeConfigWriteResult (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeContainerStartResult (..)
  , DockerNodeVarRemoveResult (..)
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
import System.FilePath.Posix (isAbsolute, normalise, splitDirectories)
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
  -- The writer includes a separately bounded closing read and repeated
  -- admission checks; allow both within this enclosing bounded window.
  outcome <- timeout 60000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
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
  outcome <- timeout 30000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
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
  | NodeRemoveAttemptPriorUnconfirmed !KindNodeRemoveAttemptObservation
  | NodeRemoveAttemptControlUnconfirmed !KindNodeRemoveControlWrite !KindNodeRemoveControlObservation
  | NodeRemoveAttemptWriteUnconfirmed
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

data KindNodeRemovePass = InitialNodeRemoval | RetryNodeRemoval
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
            _ -> pure (NodeRemoveAttemptControlUnconfirmed control observed)
     where
      recordAfterControl = do
        let controlStable = do
              before <- stable
              current <- observeKindNodeRemoveControl bootstrap intent identifier (pure True)
              after <- stable
              pure (before && current == NodeRemoveControlMatches && after)
        recordNodeRemoveAttemptAfterControl InitialNodeRemoval bootstrap intent identifier controlStable
    _ -> pure (NodeRemoveAttemptPriorUnconfirmed prior)

-- The retry has a distinct durable location and is admitted only for the
-- same still-present container after an independent positive inventory.
recordKindNodeRemoveRecoveryAttempt
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool -> IO KindNodeRemoveAttemptWrite
recordKindNodeRemoveRecoveryAttempt bootstrap intent identifier stable = do
  admitted <- eligible
  if not admitted
    then pure NodeRemoveAttemptRefused
    else do
      positive <-
        observeNodeRemovalPositiveControl bootstrap (kindNodeCreateDaemon intent) identifier eligible
      if nodeRemovalPositive identifier positive
        then recordNodeRemoveAttemptAfterControl RetryNodeRemoval bootstrap intent identifier eligible
        else pure (NodeRemoveAttemptPositiveControlRefused positive)
 where
  eligible = do
    before <- stable
    predecessor <-
      if before
        then observeKindNodeRemoveRecoveryPredecessor bootstrap intent identifier
        else pure False
    after <- stable
    pure (predecessor && after)

observeKindNodeRemoveRecoveryPredecessor
  :: BootstrapProjection -> KindNodeCreateIntent -> String -> IO Bool
observeKindNodeRemoveRecoveryPredecessor bootstrap intent identifier = do
  original <- observeKindNodeRemoveAttempt bootstrap intent identifier (pure True)
  control <- observeKindNodeRemoveControl bootstrap intent identifier (pure True)
  result <- observeKindNodeRemoveResult bootstrap intent identifier (pure True)
  pure
    ( original == NodeRemoveAttemptMatches
        && control == NodeRemoveControlMatches
        && result == NodeRemoveResultMissing
    )

recordNodeRemoveAttemptAfterControl
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveAttemptWrite
recordNodeRemoveAttemptAfterControl pass bootstrap intent identifier stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      admitted <- stable
      ready <-
        if admitted
          then removePreconditions bootstrap intent identifier (pure True) sameRoot
          else pure False
      rootStatus <- Files.getFdStatus root
      let bytes = removeAttemptBytesFor pass bootstrap intent identifier rootStatus
      beforeWrite <- if ready then stable else pure False
      if not beforeWrite || BS.length bytes > 8192
        then pure NodeRemoveAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) (removeAttemptNameFor pass) Posix.WriteOnly createFlags)
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
                  observed <- observeKindNodeRemoveAttemptFor pass bootstrap intent identifier (pure True)
                  after <- stable
                  pure
                    ( if after && observed == NodeRemoveAttemptMatches
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
    _ -> NodeRemoveAttemptWriteUnconfirmed

-- A missing record is not evidence of container absence or worker settlement.
observeKindNodeRemoveAttempt
  :: BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveAttemptObservation
observeKindNodeRemoveAttempt = observeKindNodeRemoveAttemptFor InitialNodeRemoval

observeKindNodeRemoveAttemptFor
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveAttemptObservation
observeKindNodeRemoveAttemptFor pass bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removePreconditions bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeRemoveAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) (removeAttemptNameFor pass) Posix.ReadOnly readFlags)
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
                      (Posix.openFdAt (Just root) (removeAttemptNameFor pass) Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removePreconditions bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeRemoveAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (removeAttemptBytesFor pass bootstrap intent identifier rootStatus)
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

-- A control plan binds every journal entry to the already recorded node
-- creation, exact target ID, deterministic control name and image volume
-- declarations. It does not itself authorize a Docker request.
data KindAbsencePlan = KindAbsencePlan !KindNodeCreateIntent !String ![FilePath]
  deriving (Eq, Show)

data KindAbsencePlanRecovery
  = AbsencePlanMissing
  | AbsencePlanObserved !KindAbsencePlan
  | AbsencePlanUnconfirmed
  deriving (Eq, Show)

kindAbsenceOperation :: KindAbsencePlan -> String
kindAbsenceOperation (KindAbsencePlan intent _ _) = nodeCreateOperation (kindNodeCreateInput intent)

kindAbsenceDaemon :: KindAbsencePlan -> DockerDaemonObservation
kindAbsenceDaemon (KindAbsencePlan intent _ _) = kindNodeCreateDaemon intent

kindAbsenceTarget :: KindAbsencePlan -> String
kindAbsenceTarget (KindAbsencePlan _ target _) = target

kindAbsenceImage :: KindAbsencePlan -> String
kindAbsenceImage (KindAbsencePlan intent _ _) = nodeCreateImageId (kindNodeCreateInput intent)

kindAbsenceImageVolumes :: KindAbsencePlan -> DockerImageVolumes
kindAbsenceImageVolumes (KindAbsencePlan _ _ volumes) = DockerImageVolumes volumes

mkKindAbsencePlan :: KindNodeCreateIntent -> String -> DockerImageVolumes -> Maybe KindAbsencePlan
mkKindAbsencePlan intent target (DockerImageVolumes volumes)
  | not (validImageId ("sha256:" ++ target)) = Nothing
  | length volumes > 64 || volumes /= sort volumes || length volumes /= length (nub volumes) = Nothing
  | not (all validVolume volumes) = Nothing
  | otherwise = Just (KindAbsencePlan intent target volumes)
 where
  validVolume path =
    isAbsolute path
      && normalise path == path
      && path /= "/"
      && last path /= '/'
      && length path <= 4096
      && all (`notElem` ['\0', '\n', '\r']) path
      && all (`notElem` [".", ".."]) (splitDirectories path)

-- Recover the image declaration from the original attempt record, never from
-- the current image or Docker inventory. A missing local record is not proof
-- that no control exists; every candidate is rechecked against the full
-- operation-, node-, daemon- and root-bound record.
recoverKindAbsencePlan :: BootstrapProjection -> String -> IO Bool -> IO KindAbsencePlanRecovery
recoverKindAbsencePlan bootstrap operation stable = do
  proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
  case proposal of
    NodeCreateRecoveryRecorded intent -> do
      created <- observeKindNodeCreateResult bootstrap intent stable
      case created of
        NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just target)) -> recover intent target
        _ -> pure AbsencePlanUnconfirmed
    _ -> pure AbsencePlanUnconfirmed
 where
  recover intent target = do
    outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      checked <- try $ do
        ready <- removePreconditions bootstrap intent target stable sameRoot
        if not ready
          then pure (Left False)
          else do
            owner <- getEffectiveUserID
            opened <-
              try (Posix.openFdAt (Just root) (absenceStageName AbsenceCreateAttempt) Posix.ReadOnly readFlags)
            case opened of
              Left failure | isDoesNotExistError failure -> do
                still <- removePreconditions bootstrap intent target stable sameRoot
                pure (Left still)
              Left (_ :: IOException) -> pure (Left False)
              Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                status <- Files.getFdStatus held
                if not (safeFile owner status)
                  then pure (Left False)
                  else do
                    bytes <- readBounded held
                    pure $ case Aeson.eitherDecodeStrict' bytes
                      >>= parseEither (Aeson.withObject "absence plan" (.: "image_volumes")) of
                      Right volumes -> maybe (Left False) Right (mkKindAbsencePlan intent target (DockerImageVolumes volumes))
                      Left _ -> Left False
      pure (either (const (Left False)) id (checked :: Either IOException (Either Bool KindAbsencePlan)))
    case outcome of
      Just (Right (Left True)) -> pure AbsencePlanMissing
      Just (Right (Right plan)) -> do
        exact <- observeKindAbsenceStage bootstrap plan AbsenceCreateAttempt stable
        pure (if exact == AbsenceMatches then AbsencePlanObserved plan else AbsencePlanUnconfirmed)
      _ -> pure AbsencePlanUnconfirmed

-- The records distinguish a possible create, recovered exact ID, storage
-- footprint, sampled control, possible remove and its transport result.
-- Removal requires the footprint, not a successful sample. Records are local
-- evidence only; the driver must independently observe each effect.
data KindAbsenceStage
  = AbsenceCreateAttempt
  | AbsenceCreateResult !DockerNodeContainerCreateResult
  | AbsenceControlIdentified !String
  | AbsenceFootprintRecorded !String ![(FilePath, String)]
  | AbsenceControlSampled !String ![(FilePath, String)]
  | AbsenceRemoveAttempt !String ![(FilePath, String)]
  | AbsenceRemoveResult !String ![(FilePath, String)] !DockerNodeContainerRemoveResult
  | AbsenceVolumeRemoveAttempt !String ![(FilePath, String)] !String
  | AbsenceVolumeRemoveResult !String ![(FilePath, String)] !String !DockerNodeVarRemoveResult
  deriving (Eq, Show)

data KindAbsenceWrite = AbsenceRecorded | AbsenceAlreadyExists | AbsenceRefused | AbsenceIncomplete
  deriving (Eq, Show)

data KindAbsenceObservation
  = AbsenceMissing
  | AbsenceMatches
  | AbsenceConflict
  | AbsenceInvalid
  | AbsenceUnobservable
  deriving (Eq, Show)

data KindAbsenceIdObservation = AbsenceIdObserved !String | AbsenceIdUnconfirmed
  deriving (Eq, Show)

data KindAbsenceFootprintObservation
  = AbsenceFootprintObserved ![(FilePath, String)]
  | AbsenceFootprintUnconfirmed
  deriving (Eq, Show)

data KindAbsenceVolumeResultObservation
  = AbsenceVolumeAttemptMissing
  | AbsenceVolumeResultMissing
  | AbsenceVolumeResultObserved !DockerNodeVarRemoveResult
  | AbsenceVolumeResultUnconfirmed
  deriving (Eq, Show)

data KindAbsenceControlResultObservation
  = AbsenceControlAttemptMissing
  | AbsenceControlResultMissing
  | AbsenceControlResultObserved !DockerNodeContainerRemoveResult
  | AbsenceControlResultUnconfirmed
  deriving (Eq, Show)

absenceStageName :: KindAbsenceStage -> FilePath
absenceStageName stage =
  "kind-node-absence-control-" ++ case stage of
    AbsenceCreateAttempt -> "create-attempt.json"
    AbsenceCreateResult _ -> "create-result.json"
    AbsenceControlIdentified _ -> "identified.json"
    AbsenceFootprintRecorded _ _ -> "footprint.json"
    AbsenceControlSampled _ _ -> "sampled.json"
    AbsenceRemoveAttempt _ _ -> "remove-attempt.json"
    AbsenceRemoveResult {} -> "remove-result.json"
    AbsenceVolumeRemoveAttempt _ _ volume -> "volume-" ++ volume ++ "-attempt.json"
    AbsenceVolumeRemoveResult _ _ volume _ -> "volume-" ++ volume ++ "-result.json"

absencePrevious :: KindAbsenceStage -> Maybe KindAbsenceStage
absencePrevious stage = case stage of
  AbsenceCreateAttempt -> Nothing
  AbsenceCreateResult _ -> Just AbsenceCreateAttempt
  AbsenceControlIdentified _ -> Just AbsenceCreateAttempt
  AbsenceFootprintRecorded identifier _ -> Just (AbsenceControlIdentified identifier)
  AbsenceControlSampled identifier volumes -> Just (AbsenceFootprintRecorded identifier volumes)
  AbsenceRemoveAttempt identifier volumes -> Just (AbsenceFootprintRecorded identifier volumes)
  AbsenceRemoveResult identifier volumes _ -> Just (AbsenceRemoveAttempt identifier volumes)
  AbsenceVolumeRemoveAttempt identifier volumes _ -> Just (AbsenceRemoveAttempt identifier volumes)
  AbsenceVolumeRemoveResult identifier volumes volume _ -> Just (AbsenceVolumeRemoveAttempt identifier volumes volume)

absenceControlId :: KindAbsenceStage -> Maybe String
absenceControlId stage = case stage of
  AbsenceCreateAttempt -> Nothing
  AbsenceCreateResult _ -> Nothing
  AbsenceControlIdentified identifier -> Just identifier
  AbsenceFootprintRecorded identifier _ -> Just identifier
  AbsenceControlSampled identifier _ -> Just identifier
  AbsenceRemoveAttempt identifier _ -> Just identifier
  AbsenceRemoveResult identifier _ _ -> Just identifier
  AbsenceVolumeRemoveAttempt identifier _ _ -> Just identifier
  AbsenceVolumeRemoveResult identifier _ _ _ -> Just identifier

absenceFootprint :: KindAbsenceStage -> Maybe [(FilePath, String)]
absenceFootprint stage = case stage of
  AbsenceCreateAttempt -> Nothing
  AbsenceCreateResult _ -> Nothing
  AbsenceControlIdentified _ -> Nothing
  AbsenceFootprintRecorded _ volumes -> Just volumes
  AbsenceControlSampled _ volumes -> Just volumes
  AbsenceRemoveAttempt _ volumes -> Just volumes
  AbsenceRemoveResult _ volumes _ -> Just volumes
  AbsenceVolumeRemoveAttempt _ volumes _ -> Just volumes
  AbsenceVolumeRemoveResult _ volumes _ _ -> Just volumes

validAbsenceStage :: KindAbsencePlan -> KindAbsenceStage -> Bool
validAbsenceStage (KindAbsencePlan _ target declared) stage =
  validResult && validFootprint && validVolume && case absenceControlId stage of
    Nothing -> True
    Just identifier -> identifier /= target && validImageId ("sha256:" ++ identifier)
 where
  validResult = case stage of
    AbsenceCreateResult result ->
      validCreateResult result && case result of
        DockerNodeContainerCreateReply 201 (Just identifier) -> identifier /= target
        _ -> True
    AbsenceRemoveResult _ _ result -> validRemoveResult result
    AbsenceVolumeRemoveResult _ _ _ result -> case result of
      DockerNodeVarRemoveNotStarted -> True
      DockerNodeVarRemoveUnconfirmed -> True
      DockerNodeVarRemoveReply status -> status >= 100 && status <= 599
    _ -> True
  validVolume = case stage of
    AbsenceVolumeRemoveAttempt _ volumes volume -> volume `elem` map snd volumes
    AbsenceVolumeRemoveResult _ volumes volume _ -> volume `elem` map snd volumes
    _ -> True
  validFootprint = case absenceFootprint stage of
    Nothing -> True
    Just volumes ->
      map fst volumes == declared
        && length (map snd volumes) == length (nub (map snd volumes))
        && all (validImageId . ("sha256:" ++) . snd) volumes

absenceStageValue
  :: BootstrapProjection -> KindAbsencePlan -> KindAbsenceStage -> Files.FileStatus -> Aeson.Value
absenceStageValue bootstrap (KindAbsencePlan intent target volumes) stage root =
  Aeson.object $
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-node-absence-control" :: String)
    , "stage" Aeson..= absenceStageName stage
    , "node_create_result"
        Aeson..= TextEncoding.decodeUtf8
          (resultBytes bootstrap intent (DockerNodeContainerCreateReply 201 (Just target)) root)
    , "control_name" Aeson..= (scopeKindName (bootstrapScope bootstrap) ++ "-absence-control")
    , "control_label"
        Aeson..= ("io.prodbox.absence-control=" ++ nodeCreateOperation (kindNodeCreateInput intent))
    , "image_volumes" Aeson..= volumes
    , "control_id" Aeson..= absenceControlId stage
    , "anonymous_volumes" Aeson..= absenceFootprint stage
    , "create_transport" Aeson..= case stage of
        AbsenceCreateResult result -> Just (createResultValue result)
        _ -> Nothing
    , "remove_transport" Aeson..= case stage of
        AbsenceRemoveResult _ _ result -> Just (removeResultValue result)
        _ -> Nothing
    ]
      ++ case stage of
        AbsenceVolumeRemoveAttempt _ _ volume -> ["volume_id" Aeson..= volume]
        AbsenceVolumeRemoveResult _ _ volume result ->
          [ "volume_id" Aeson..= volume
          , "volume_transport" Aeson..= case result of
              DockerNodeVarRemoveNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
              DockerNodeVarRemoveUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
              DockerNodeVarRemoveReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]
          ]
        _ -> []

absencePreconditions :: BootstrapProjection -> KindAbsencePlan -> IO Bool -> IO Bool -> IO Bool
absencePreconditions bootstrap (KindAbsencePlan intent target _) = removePreconditions bootstrap intent target

-- A sample recorded after a removal attempt cannot attest that the control
-- was visible before cleanup. Existing samples remain readable on recovery.
absenceStageFence
  :: BootstrapProjection -> KindAbsencePlan -> KindAbsenceStage -> IO Bool -> IO Bool
absenceStageFence bootstrap plan stage stable = case stage of
  AbsenceControlSampled identifier volumes ->
    (== AbsenceMissing)
      <$> observeKindAbsenceStage bootstrap plan (AbsenceRemoveAttempt identifier volumes) stable
  AbsenceVolumeRemoveAttempt identifier volumes _ -> do
    sampled <- observeKindAbsenceStage bootstrap plan (AbsenceControlSampled identifier volumes) stable
    created <-
      observeKindAbsenceStage
        bootstrap
        plan
        (AbsenceCreateResult (DockerNodeContainerCreateReply 201 (Just identifier)))
        stable
    pure (sampled == AbsenceMatches && created == AbsenceMatches)
  _ -> pure True

recordKindAbsenceStage
  :: BootstrapProjection -> KindAbsencePlan -> KindAbsenceStage -> IO Bool -> IO KindAbsenceWrite
recordKindAbsenceStage bootstrap plan stage stable
  | not (validAbsenceStage plan stage) = pure AbsenceRefused
  | otherwise = do
      prior <- case absencePrevious stage of
        Nothing -> pure True
        Just previous -> (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan previous stable
      permitted <- absenceStageFence bootstrap plan stage stable
      if not (prior && permitted)
        then pure AbsenceRefused
        else do
          touched <- newIORef False
          outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
            checked <- try $ do
              ready <- absencePreconditions bootstrap plan stable sameRoot
              rootStatus <- Files.getFdStatus root
              priorCurrent <- case absencePrevious stage of
                Nothing -> pure True
                Just previous -> (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan previous stable
              stillPermitted <- absenceStageFence bootstrap plan stage stable
              let bytes = BL.toStrict (Aeson.encode (absenceStageValue bootstrap plan stage rootStatus))
              if not ready || not priorCurrent || not stillPermitted || BS.length bytes > 8192
                then pure AbsenceRefused
                else mask $ \restore -> do
                  opened <- try (Posix.openFdAt (Just root) (absenceStageName stage) Posix.WriteOnly createFlags)
                  case opened of
                    Left failure | isAlreadyExistsError failure -> pure AbsenceAlreadyExists
                    Left (_ :: IOException) -> pure AbsenceRefused
                    Right file -> do
                      writeIORef touched True
                      written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                        writeAll held bytes
                        fileSynchronise held
                        fileSynchronise root
                      case written of
                        Left (_ :: IOException) -> pure AbsenceIncomplete
                        Right () -> do
                          observed <- restore (observeKindAbsenceStage bootstrap plan stage stable)
                          pure (if observed == AbsenceMatches then AbsenceRecorded else AbsenceIncomplete)
            pure (either (const AbsenceRefused) id (checked :: Either IOException KindAbsenceWrite))
          changed <- readIORef touched
          pure $ case outcome of
            Just (Right result) | result /= AbsenceRefused -> result
            _ | changed -> AbsenceIncomplete
            _ -> AbsenceRefused
observeKindAbsenceStage
  :: BootstrapProjection -> KindAbsencePlan -> KindAbsenceStage -> IO Bool -> IO KindAbsenceObservation
observeKindAbsenceStage bootstrap plan stage stable
  | not (validAbsenceStage plan stage) = pure AbsenceInvalid
  | otherwise = do
      previous <- case absencePrevious stage of
        Nothing -> pure True
        Just prior -> (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan prior stable
      if not previous
        then pure AbsenceUnobservable
        else do
          outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
            checked <- try $ do
              ready <- absencePreconditions bootstrap plan stable sameRoot
              rootStatus <- Files.getFdStatus root
              if not ready
                then pure AbsenceUnobservable
                else do
                  owner <- getEffectiveUserID
                  opened <- try (Posix.openFdAt (Just root) (absenceStageName stage) Posix.ReadOnly readFlags)
                  case opened of
                    Left failure | isDoesNotExistError failure -> do
                      still <- absencePreconditions bootstrap plan stable sameRoot
                      pure (if still then AbsenceMissing else AbsenceUnobservable)
                    Left (_ :: IOException) -> pure AbsenceUnobservable
                    Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                      before <- Files.getFdStatus held
                      if not (safeFile owner before)
                        then pure AbsenceUnobservable
                        else do
                          bytes <- readBounded held
                          decoded <- decodeBoundedYamlValue bytes
                          after <- Files.getFdStatus held
                          named <-
                            bracket
                              (Posix.openFdAt (Just root) (absenceStageName stage) Posix.ReadOnly readFlags)
                              Posix.closeFd
                              Files.getFdStatus
                          still <- absencePreconditions bootstrap plan stable sameRoot
                          pure $
                            if not (still && sameVersion before after && sameVersion after named)
                              then AbsenceUnobservable
                              else case (Aeson.eitherDecodeStrict' bytes, decoded) of
                                (Right value, Right validated)
                                  | value == validated ->
                                      if value == absenceStageValue bootstrap plan stage rootStatus
                                        then AbsenceMatches
                                        else AbsenceConflict
                                _ -> AbsenceInvalid
            pure (either (const AbsenceUnobservable) id (checked :: Either IOException KindAbsenceObservation))
          afterPrevious <- case absencePrevious stage of
            Nothing -> pure True
            Just prior -> (== AbsenceMatches) <$> observeKindAbsenceStage bootstrap plan prior stable
          pure $
            if not afterPrevious
              then AbsenceUnobservable
              else case outcome of
                Just (Right result) -> result
                _ -> AbsenceUnobservable

-- Extract a candidate ID only from a bounded file, then re-observe the exact
-- bound stage under the lease. Missing and invalid files never imply absence.
recoverKindAbsenceControlId
  :: BootstrapProjection -> KindAbsencePlan -> IO Bool -> IO KindAbsenceIdObservation
recoverKindAbsenceControlId bootstrap plan stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- absencePreconditions bootstrap plan stable sameRoot
      if not ready
        then pure Nothing
        else do
          owner <- getEffectiveUserID
          opened <-
            try
              (Posix.openFdAt (Just root) (absenceStageName (AbsenceControlIdentified "")) Posix.ReadOnly readFlags)
          case opened of
            Left (_ :: IOException) -> pure Nothing
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              status <- Files.getFdStatus held
              if not (safeFile owner status)
                then pure Nothing
                else do
                  bytes <- readBounded held
                  pure $ case Aeson.eitherDecodeStrict' bytes
                    >>= parseEither (Aeson.withObject "absence control" (.: "control_id")) of
                    Right identifier -> Just identifier
                    Left _ -> Nothing
    pure (either (const Nothing) id (checked :: Either IOException (Maybe String)))
  case outcome of
    Just (Right (Just identifier)) -> do
      observed <- observeKindAbsenceStage bootstrap plan (AbsenceControlIdentified identifier) stable
      pure (if observed == AbsenceMatches then AbsenceIdObserved identifier else AbsenceIdUnconfirmed)
    _ -> pure AbsenceIdUnconfirmed

-- Keep the exact anonymous volume IDs available after container removal;
-- declarations alone cannot identify storage to clean up after a crash.
recoverKindAbsenceFootprint
  :: BootstrapProjection -> KindAbsencePlan -> String -> IO Bool -> IO KindAbsenceFootprintObservation
recoverKindAbsenceFootprint bootstrap plan identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- absencePreconditions bootstrap plan stable sameRoot
      if not ready
        then pure Nothing
        else do
          owner <- getEffectiveUserID
          opened <-
            try
              ( Posix.openFdAt
                  (Just root)
                  (absenceStageName (AbsenceFootprintRecorded "" []))
                  Posix.ReadOnly
                  readFlags
              )
          case opened of
            Left (_ :: IOException) -> pure Nothing
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              status <- Files.getFdStatus held
              if not (safeFile owner status)
                then pure Nothing
                else do
                  bytes <- readBounded held
                  pure $ case Aeson.eitherDecodeStrict' bytes
                    >>= parseEither (Aeson.withObject "absence control" (.: "anonymous_volumes")) of
                    Right volumes -> Just volumes
                    Left _ -> Nothing
    pure (either (const Nothing) id (checked :: Either IOException (Maybe [(FilePath, String)])))
  case outcome of
    Just (Right (Just volumes)) -> do
      observed <-
        observeKindAbsenceStage bootstrap plan (AbsenceFootprintRecorded identifier volumes) stable
      pure
        (if observed == AbsenceMatches then AbsenceFootprintObserved volumes else AbsenceFootprintUnconfirmed)
    _ -> pure AbsenceFootprintUnconfirmed

recoverKindAbsenceControlResult
  :: BootstrapProjection
  -> KindAbsencePlan
  -> String
  -> [(FilePath, String)]
  -> IO Bool
  -> IO KindAbsenceControlResultObservation
recoverKindAbsenceControlResult bootstrap plan identifier volumes stable = do
  let stage result = AbsenceRemoveResult identifier volumes result
  attempt <- observeKindAbsenceStage bootstrap plan (AbsenceRemoveAttempt identifier volumes) stable
  case attempt of
    AbsenceMissing -> pure AbsenceControlAttemptMissing
    AbsenceMatches -> do
      probe <- observeKindAbsenceStage bootstrap plan (stage DockerNodeContainerRemoveUnconfirmed) stable
      case probe of
        AbsenceMissing -> pure AbsenceControlResultMissing
        AbsenceMatches -> pure (AbsenceControlResultObserved DockerNodeContainerRemoveUnconfirmed)
        AbsenceConflict -> do
          candidate <- readCandidate (stage DockerNodeContainerRemoveUnconfirmed)
          case candidate of
            Just value -> do
              exact <- observeKindAbsenceStage bootstrap plan (stage value) stable
              pure
                ( if exact == AbsenceMatches
                    then AbsenceControlResultObserved value
                    else AbsenceControlResultUnconfirmed
                )
            Nothing -> pure AbsenceControlResultUnconfirmed
        _ -> pure AbsenceControlResultUnconfirmed
    _ -> pure AbsenceControlResultUnconfirmed
 where
  readCandidate stage = do
    outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      checked <- try $ do
        ready <- absencePreconditions bootstrap plan stable sameRoot
        if not ready
          then pure Nothing
          else do
            owner <- getEffectiveUserID
            opened <- try (Posix.openFdAt (Just root) (absenceStageName stage) Posix.ReadOnly readFlags)
            case opened of
              Left (_ :: IOException) -> pure Nothing
              Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                status <- Files.getFdStatus held
                if not (safeFile owner status)
                  then pure Nothing
                  else do
                    bytes <- readBounded held
                    pure $ either (const Nothing) Just (Aeson.eitherDecodeStrict' bytes >>= parseEither parseTransport)
      pure
        (either (const Nothing) id (checked :: Either IOException (Maybe DockerNodeContainerRemoveResult)))
    pure $ case outcome of Just (Right candidate) -> candidate; _ -> Nothing
  parseTransport = Aeson.withObject "absence control result" $ \object -> do
    transport <- object .: "remove_transport"
    Aeson.withObject
      "control transport"
      ( \fields -> do
          state <- fields .: "state"
          case (state :: String) of
            "not-started" -> pure DockerNodeContainerRemoveNotStarted
            "unconfirmed" -> pure DockerNodeContainerRemoveUnconfirmed
            "reply" -> DockerNodeContainerRemoveReply <$> fields .: "status"
            _ -> fail "invalid control transport state"
      )
      transport

-- Decode a candidate result only to re-observe the exact bound record. A
-- missing attempt, a missing result and malformed/unreadable data remain
-- distinct; none of them establishes provider settlement or permits retry.
recoverKindAbsenceVolumeResult
  :: BootstrapProjection
  -> KindAbsencePlan
  -> String
  -> [(FilePath, String)]
  -> String
  -> IO Bool
  -> IO KindAbsenceVolumeResultObservation
recoverKindAbsenceVolumeResult bootstrap plan identifier volumes volume stable = do
  let attempt = AbsenceVolumeRemoveAttempt identifier volumes volume
      stage result = AbsenceVolumeRemoveResult identifier volumes volume result
  observed <- observeKindAbsenceStage bootstrap plan attempt stable
  case observed of
    AbsenceMissing -> pure AbsenceVolumeAttemptMissing
    AbsenceMatches -> do
      probe <- observeKindAbsenceStage bootstrap plan (stage DockerNodeVarRemoveUnconfirmed) stable
      case probe of
        AbsenceMissing -> pure AbsenceVolumeResultMissing
        AbsenceMatches -> pure (AbsenceVolumeResultObserved DockerNodeVarRemoveUnconfirmed)
        AbsenceConflict -> do
          candidate <- readCandidate (stage DockerNodeVarRemoveUnconfirmed)
          case candidate of
            Just value -> do
              exact <- observeKindAbsenceStage bootstrap plan (stage value) stable
              pure
                ( if exact == AbsenceMatches
                    then AbsenceVolumeResultObserved value
                    else AbsenceVolumeResultUnconfirmed
                )
            Nothing -> pure AbsenceVolumeResultUnconfirmed
        _ -> pure AbsenceVolumeResultUnconfirmed
    _ -> pure AbsenceVolumeResultUnconfirmed
 where
  readCandidate stage = do
    outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      checked <- try $ do
        ready <- absencePreconditions bootstrap plan stable sameRoot
        if not ready
          then pure Nothing
          else do
            owner <- getEffectiveUserID
            opened <- try (Posix.openFdAt (Just root) (absenceStageName stage) Posix.ReadOnly readFlags)
            case opened of
              Left (_ :: IOException) -> pure Nothing
              Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                status <- Files.getFdStatus held
                if not (safeFile owner status)
                  then pure Nothing
                  else do
                    bytes <- readBounded held
                    pure $ either (const Nothing) Just (Aeson.eitherDecodeStrict' bytes >>= parseEither parseTransport)
      pure (either (const Nothing) id (checked :: Either IOException (Maybe DockerNodeVarRemoveResult)))
    pure $ case outcome of Just (Right candidate) -> candidate; _ -> Nothing
  parseTransport = Aeson.withObject "absence volume result" $ \object -> do
    transport <- object .: "volume_transport"
    Aeson.withObject
      "volume transport"
      ( \fields -> do
          state <- fields .: "state"
          case (state :: String) of
            "not-started" -> pure DockerNodeVarRemoveNotStarted
            "unconfirmed" -> pure DockerNodeVarRemoveUnconfirmed
            "reply" -> DockerNodeVarRemoveReply <$> fields .: "status"
            _ -> fail "invalid volume transport state"
      )
      transport

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
removeAttemptBytes = removeAttemptBytesFor InitialNodeRemoval

removeAttemptBytesFor
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> Files.FileStatus
  -> BS.ByteString
removeAttemptBytesFor pass bootstrap intent identifier root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= removeAttemptKind pass
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
recordKindNodeRemoveResult = recordKindNodeRemoveResultFor InitialNodeRemoval

recordKindNodeRemoveResultFor
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerRemoveResult
  -> IO Bool
  -> IO KindNodeRemoveResultWrite
recordKindNodeRemoveResultFor pass bootstrap intent identifier result stable
  | not (validRemoveResult result) = pure NodeRemoveResultRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          admitted <- stable
          ready <-
            if admitted
              then removeResultPreconditions pass bootstrap intent identifier (pure True) sameRoot
              else pure False
          rootStatus <- Files.getFdStatus root
          let bytes = removeResultBytes pass bootstrap intent identifier result rootStatus
          beforeWrite <- if ready then stable else pure False
          if not beforeWrite || BS.length bytes > 8192
            then pure NodeRemoveResultRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) (removeResultNameFor pass) Posix.WriteOnly createFlags)
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
                      observed <- observeKindNodeRemoveResultFor pass bootstrap intent identifier (pure True)
                      after <- stable
                      pure
                        ( if after && observed == NodeRemoveResultObserved result
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
observeKindNodeRemoveResult = observeKindNodeRemoveResultFor InitialNodeRemoval

observeKindNodeRemoveResultFor
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO KindNodeRemoveResultObservation
observeKindNodeRemoveResultFor pass bootstrap intent identifier stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removeResultPreconditions pass bootstrap intent identifier stable sameRoot
      if not ready
        then pure NodeRemoveResultUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) (removeResultNameFor pass) Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- removeResultPreconditions pass bootstrap intent identifier stable sameRoot
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
                      (Posix.openFdAt (Just root) (removeResultNameFor pass) Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removeResultPreconditions pass bootstrap intent identifier stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeRemoveResultUnobservable
                      else decodeRemoveResult pass bootstrap intent identifier rootStatus bytes decoded
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
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> IO Bool
  -> IO Bool
  -> IO Bool
removeResultPreconditions pass bootstrap intent identifier stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeRemoveAttemptFor pass bootstrap intent identifier (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeRemoveAttemptMatches && afterRoot && after)

validRemoveResult :: DockerNodeContainerRemoveResult -> Bool
validRemoveResult DockerNodeContainerRemoveNotStarted = True
validRemoveResult DockerNodeContainerRemoveUnconfirmed = True
validRemoveResult (DockerNodeContainerRemoveReply status) = status >= 100 && status <= 599

removeResultBytes
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> DockerNodeContainerRemoveResult
  -> Files.FileStatus
  -> BS.ByteString
removeResultBytes pass bootstrap intent identifier result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= removeResultKind pass
        , "attempt"
            Aeson..= ( Aeson.decodeStrict' (removeAttemptBytesFor pass bootstrap intent identifier root)
                         :: Maybe Aeson.Value
                     )
        , "transport" Aeson..= removeResultValue result
        ]

removeResultValue :: DockerNodeContainerRemoveResult -> Aeson.Value
removeResultValue result = case result of
  DockerNodeContainerRemoveNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeContainerRemoveUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeContainerRemoveReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]

decodeRemoveResult
  :: KindNodeRemovePass
  -> BootstrapProjection
  -> KindNodeCreateIntent
  -> String
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeRemoveResultObservation
decodeRemoveResult pass bootstrap intent identifier root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validRemoveResult result -> case Aeson.eitherDecodeStrict' (removeResultBytes pass bootstrap intent identifier result root) of
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

removeAttemptKind :: KindNodeRemovePass -> String
removeAttemptKind InitialNodeRemoval = "kind-node-remove-attempt"
removeAttemptKind RetryNodeRemoval = "kind-node-remove-retry-attempt"

removeResultKind :: KindNodeRemovePass -> String
removeResultKind InitialNodeRemoval = "kind-node-remove-result"
removeResultKind RetryNodeRemoval = "kind-node-remove-retry-result"

removeAttemptNameFor :: KindNodeRemovePass -> FilePath
removeAttemptNameFor pass = removeAttemptKind pass ++ ".json"

removeResultNameFor :: KindNodeRemovePass -> FilePath
removeResultNameFor pass = removeResultKind pass ++ ".json"

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
