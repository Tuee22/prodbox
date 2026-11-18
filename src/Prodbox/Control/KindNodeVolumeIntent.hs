{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A durable proposal for the scoped node /var volume. A record alone does
-- not authorize an effect, prove ownership, or settle a worker.
module Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeIntent
  , mkKindNodeVolumeIntent
  , KindNodeVolumeIntentWrite (..)
  , KindNodeVolumeIntentObservation (..)
  , recordKindNodeVolumeIntent
  , observeKindNodeVolumeIntent
  , KindNodeVolumeAttemptWrite (..)
  , KindNodeVolumeAttemptObservation (..)
  , recordKindNodeVolumeAttempt
  , observeKindNodeVolumeAttempt
  , KindNodeVolumeReceiptWrite (..)
  , KindNodeVolumeReceiptObservation (..)
  , recordKindNodeVolumeReceipt
  , observeKindNodeVolumeReceipt
  , KindNodeVolumeRemovalWrite (..)
  , KindNodeVolumeRemovalObservation (..)
  , recordKindNodeVolumeRemoval
  , observeKindNodeVolumeRemoval
  , KindNodeVolumeRemovalReceiptWrite (..)
  , KindNodeVolumeRemovalReceiptObservation (..)
  , recordKindNodeVolumeRemovalReceipt
  , observeKindNodeVolumeRemovalReceipt
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
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Config.KindPlan (kindNodeVarVolumeNameForScope)
import Prodbox.Control.DockerConnectedInfo
  ( DockerNodeVarCreateResult (..)
  , DockerNodeVarRemoveResult (..)
  , DockerNodeVarVolumeObservation (..)
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , DockerSocketIdentity (..)
  , classifyDockerDaemon
  )
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

data KindNodeVolumeIntent = KindNodeVolumeIntent !String !String !DockerSocketIdentity
  deriving (Eq, Show)

mkKindNodeVolumeIntent :: String -> DockerDaemonObservation -> Maybe KindNodeVolumeIntent
mkKindNodeVolumeIntent operation observed = case observed of
  DockerDaemonObserved identifier socket@(DockerSocketIdentity device inode owner mode)
    | validRootGeneration operation
        && device >= 0
        && inode > 0
        && owner >= 0
        && mode >= 0
        && mode .&. 0o170000 == 0o140000
        && classifyDockerDaemon (Just socket) (Just identifier) (Just socket) (Just identifier) (Just socket)
          == observed ->
        Just (KindNodeVolumeIntent operation identifier socket)
  _ -> Nothing

data KindNodeVolumeIntentWrite
  = NodeVolumeIntentRecorded
  | NodeVolumeIntentAlreadyExists
  | NodeVolumeIntentRefused
  | NodeVolumeIntentIncomplete
  deriving (Eq, Show)

data KindNodeVolumeIntentObservation
  = NodeVolumeIntentMissing
  | NodeVolumeIntentMatches
  | NodeVolumeIntentConflict
  | NodeVolumeIntentInvalid
  | NodeVolumeIntentUnobservable
  deriving (Eq, Show)

-- The caller must hold the recovered operation lease and supply its recheck.
-- Existing or partially written records are retained, never replaced.
recordKindNodeVolumeIntent
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeIntentWrite
recordKindNodeVolumeIntent bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeIntentRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) recordName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeVolumeIntentAlreadyExists
            Left (_ :: IOException) -> pure NodeVolumeIntentRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                rootStatus <- Files.getFdStatus root
                writeAll held (recordBytes bootstrap intent rootStatus)
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeVolumeIntentIncomplete
                Right () -> do
                  observed <- observeKindNodeVolumeIntent bootstrap intent stable
                  pure
                    (if observed == NodeVolumeIntentMatches then NodeVolumeIntentRecorded else NodeVolumeIntentIncomplete)
    pure
      (either (const NodeVolumeIntentRefused) id (checked :: Either IOException KindNodeVolumeIntentWrite))
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeVolumeIntentRefused -> result
    _ | changed -> NodeVolumeIntentIncomplete
    _ -> NodeVolumeIntentRefused

-- A missing record is not evidence of volume absence or worker settlement.
observeKindNodeVolumeIntent
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeIntentObservation
observeKindNodeVolumeIntent bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- preconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeIntentUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) recordName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- preconditions bootstrap intent stable sameRoot
              pure (if still then NodeVolumeIntentMissing else NodeVolumeIntentUnobservable)
            Left (_ :: IOException) -> pure NodeVolumeIntentUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeVolumeIntentUnobservable
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
                      then NodeVolumeIntentUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (recordBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeVolumeIntentMatches else NodeVolumeIntentConflict
                        _ -> NodeVolumeIntentInvalid
    pure
      ( either
          (const NodeVolumeIntentUnobservable)
          id
          (checked :: Either IOException KindNodeVolumeIntentObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeVolumeIntentUnobservable

-- A durable attempt is distinct from the proposal and must precede any effect.
-- It is retained after interruption and never authorizes a retry by itself.
data KindNodeVolumeAttemptWrite
  = NodeVolumeAttemptRecorded
  | NodeVolumeAttemptAlreadyExists
  | NodeVolumeAttemptRefused
  | NodeVolumeAttemptIncomplete
  deriving (Eq, Show)

data KindNodeVolumeAttemptObservation
  = NodeVolumeAttemptMissing
  | NodeVolumeAttemptMatches
  | NodeVolumeAttemptConflict
  | NodeVolumeAttemptInvalid
  | NodeVolumeAttemptUnobservable
  deriving (Eq, Show)

recordKindNodeVolumeAttempt
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeAttemptWrite
recordKindNodeVolumeAttempt bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeAttemptRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) attemptName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeVolumeAttemptAlreadyExists
            Left (_ :: IOException) -> pure NodeVolumeAttemptRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                rootStatus <- Files.getFdStatus root
                writeAll held (attemptBytes bootstrap intent rootStatus)
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeVolumeAttemptIncomplete
                Right () -> do
                  observed <- observeKindNodeVolumeAttempt bootstrap intent stable
                  pure
                    ( if observed == NodeVolumeAttemptMatches
                        then NodeVolumeAttemptRecorded
                        else NodeVolumeAttemptIncomplete
                    )
    pure
      ( either
          (const NodeVolumeAttemptRefused)
          id
          (checked :: Either IOException KindNodeVolumeAttemptWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeVolumeAttemptRefused -> result
    _ | changed -> NodeVolumeAttemptIncomplete
    _ -> NodeVolumeAttemptRefused

-- A missing record is not evidence of volume absence or worker settlement.
observeKindNodeVolumeAttempt
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeAttemptObservation
observeKindNodeVolumeAttempt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- attemptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeAttemptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) attemptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- attemptPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeVolumeAttemptMissing else NodeVolumeAttemptUnobservable)
            Left (_ :: IOException) -> pure NodeVolumeAttemptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeVolumeAttemptUnobservable
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
                      then NodeVolumeAttemptUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (attemptBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeVolumeAttemptMatches else NodeVolumeAttemptConflict
                        _ -> NodeVolumeAttemptInvalid
    pure
      ( either
          (const NodeVolumeAttemptUnobservable)
          id
          (checked :: Either IOException KindNodeVolumeAttemptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeVolumeAttemptUnobservable

-- A removal marker is not proof of ownership or authorization to delete.
data KindNodeVolumeRemovalWrite
  = NodeVolumeRemovalRecorded
  | NodeVolumeRemovalAlreadyExists
  | NodeVolumeRemovalRefused
  | NodeVolumeRemovalIncomplete
  deriving (Eq, Show)

data KindNodeVolumeRemovalObservation
  = NodeVolumeRemovalMissing
  | NodeVolumeRemovalMatches
  | NodeVolumeRemovalConflict
  | NodeVolumeRemovalInvalid
  | NodeVolumeRemovalUnobservable
  deriving (Eq, Show)

recordKindNodeVolumeRemoval
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeRemovalWrite
recordKindNodeVolumeRemoval bootstrap intent stable = do
  touched <- newIORef False
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- receiptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeRemovalRefused
        else mask $ \restore -> do
          created <- try (Posix.openFdAt (Just root) removalName Posix.WriteOnly createFlags)
          case created of
            Left failure | isAlreadyExistsError failure -> pure NodeVolumeRemovalAlreadyExists
            Left (_ :: IOException) -> pure NodeVolumeRemovalRefused
            Right file -> do
              writeIORef touched True
              written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                rootStatus <- Files.getFdStatus root
                writeAll held (removalBytes bootstrap intent rootStatus)
                fileSynchronise held
                fileSynchronise root
              case written of
                Left (_ :: IOException) -> pure NodeVolumeRemovalIncomplete
                Right () -> do
                  observed <- observeKindNodeVolumeRemoval bootstrap intent stable
                  pure
                    ( if observed == NodeVolumeRemovalMatches
                        then NodeVolumeRemovalRecorded
                        else NodeVolumeRemovalIncomplete
                    )
    pure
      ( either
          (const NodeVolumeRemovalRefused)
          id
          (checked :: Either IOException KindNodeVolumeRemovalWrite)
      )
  changed <- readIORef touched
  pure $ case outcome of
    Just (Right result) | result /= NodeVolumeRemovalRefused -> result
    _ | changed -> NodeVolumeRemovalIncomplete
    _ -> NodeVolumeRemovalRefused

-- A missing record is not evidence of volume absence or worker settlement.
observeKindNodeVolumeRemoval
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeRemovalObservation
observeKindNodeVolumeRemoval bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- receiptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeRemovalUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- receiptPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeVolumeRemovalMissing else NodeVolumeRemovalUnobservable)
            Left (_ :: IOException) -> pure NodeVolumeRemovalUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeVolumeRemovalUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) removalName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- receiptPreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeVolumeRemovalUnobservable
                      else case ( Aeson.eitherDecodeStrict' bytes
                                , decoded
                                , Aeson.eitherDecodeStrict' (removalBytes bootstrap intent rootStatus)
                                ) of
                        (Right value, Right checkedValue, Right wanted)
                          | value == checkedValue ->
                              if value == wanted then NodeVolumeRemovalMatches else NodeVolumeRemovalConflict
                        _ -> NodeVolumeRemovalInvalid
    pure
      ( either
          (const NodeVolumeRemovalUnobservable)
          id
          (checked :: Either IOException KindNodeVolumeRemovalObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeVolumeRemovalUnobservable

removalBytes :: BootstrapProjection -> KindNodeVolumeIntent -> Files.FileStatus -> BS.ByteString
removalBytes bootstrap intent root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-var-volume-removal" :: String)
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        ]

-- The receipt records a transport result, not a resource postcondition.
data KindNodeVolumeReceiptWrite
  = NodeVolumeReceiptRecorded
  | NodeVolumeReceiptAlreadyExists
  | NodeVolumeReceiptRefused
  | NodeVolumeReceiptIncomplete
  deriving (Eq, Show)

data KindNodeVolumeReceiptObservation
  = NodeVolumeReceiptMissing
  | NodeVolumeReceiptObserved !DockerNodeVarCreateResult
  | NodeVolumeReceiptConflict
  | NodeVolumeReceiptInvalid
  | NodeVolumeReceiptUnobservable
  deriving (Eq, Show)

recordKindNodeVolumeReceipt
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> DockerNodeVarCreateResult
  -> IO Bool
  -> IO KindNodeVolumeReceiptWrite
recordKindNodeVolumeReceipt bootstrap intent result stable
  | not (validResult result) = pure NodeVolumeReceiptRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- receiptPreconditions bootstrap intent stable sameRoot
          if not ready
            then pure NodeVolumeReceiptRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) receiptName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeVolumeReceiptAlreadyExists
                Left (_ :: IOException) -> pure NodeVolumeReceiptRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    rootStatus <- Files.getFdStatus root
                    writeAll held (receiptBytes bootstrap intent result rootStatus)
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeVolumeReceiptIncomplete
                    Right () -> do
                      observed <- observeKindNodeVolumeReceipt bootstrap intent stable
                      pure
                        ( if observed == NodeVolumeReceiptObserved result
                            then NodeVolumeReceiptRecorded
                            else NodeVolumeReceiptIncomplete
                        )
        pure
          ( either
              (const NodeVolumeReceiptRefused)
              id
              (checked :: Either IOException KindNodeVolumeReceiptWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeVolumeReceiptRefused -> outcomeValue
        _ | changed -> NodeVolumeReceiptIncomplete
        _ -> NodeVolumeReceiptRefused

observeKindNodeVolumeReceipt
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeReceiptObservation
observeKindNodeVolumeReceipt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- receiptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeReceiptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) receiptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- receiptPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeVolumeReceiptMissing else NodeVolumeReceiptUnobservable)
            Left (_ :: IOException) -> pure NodeVolumeReceiptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeVolumeReceiptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) receiptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- receiptPreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeVolumeReceiptUnobservable
                      else decodeReceipt bootstrap intent rootStatus bytes decoded
    pure
      ( either
          (const NodeVolumeReceiptUnobservable)
          id
          (checked :: Either IOException KindNodeVolumeReceiptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeVolumeReceiptUnobservable

-- A removal reply is not evidence of absence or settlement.
data KindNodeVolumeRemovalReceiptWrite
  = NodeVolumeRemovalReceiptRecorded
  | NodeVolumeRemovalReceiptAlreadyExists
  | NodeVolumeRemovalReceiptRefused
  | NodeVolumeRemovalReceiptIncomplete
  deriving (Eq, Show)

data KindNodeVolumeRemovalReceiptObservation
  = NodeVolumeRemovalReceiptMissing
  | NodeVolumeRemovalReceiptObserved !DockerNodeVarRemoveResult
  | NodeVolumeRemovalReceiptConflict
  | NodeVolumeRemovalReceiptInvalid
  | NodeVolumeRemovalReceiptUnobservable
  deriving (Eq, Show)

recordKindNodeVolumeRemovalReceipt
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> DockerNodeVarRemoveResult
  -> IO Bool
  -> IO KindNodeVolumeRemovalReceiptWrite
recordKindNodeVolumeRemovalReceipt bootstrap intent result stable
  | not (validRemovalResult result) = pure NodeVolumeRemovalReceiptRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        checked <- try $ do
          ready <- removalReceiptPreconditions bootstrap intent stable sameRoot
          if not ready
            then pure NodeVolumeRemovalReceiptRefused
            else mask $ \restore -> do
              created <- try (Posix.openFdAt (Just root) removalReceiptName Posix.WriteOnly createFlags)
              case created of
                Left failure | isAlreadyExistsError failure -> pure NodeVolumeRemovalReceiptAlreadyExists
                Left (_ :: IOException) -> pure NodeVolumeRemovalReceiptRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    rootStatus <- Files.getFdStatus root
                    writeAll held (removalReceiptBytes bootstrap intent result rootStatus)
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure NodeVolumeRemovalReceiptIncomplete
                    Right () -> do
                      observed <- observeKindNodeVolumeRemovalReceipt bootstrap intent stable
                      pure
                        ( if observed == NodeVolumeRemovalReceiptObserved result
                            then NodeVolumeRemovalReceiptRecorded
                            else NodeVolumeRemovalReceiptIncomplete
                        )
        pure
          ( either
              (const NodeVolumeRemovalReceiptRefused)
              id
              (checked :: Either IOException KindNodeVolumeRemovalReceiptWrite)
          )
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right outcomeValue) | outcomeValue /= NodeVolumeRemovalReceiptRefused -> outcomeValue
        _ | changed -> NodeVolumeRemovalReceiptIncomplete
        _ -> NodeVolumeRemovalReceiptRefused

observeKindNodeVolumeRemovalReceipt
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO KindNodeVolumeRemovalReceiptObservation
observeKindNodeVolumeRemovalReceipt bootstrap intent stable = do
  outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    checked <- try $ do
      ready <- removalReceiptPreconditions bootstrap intent stable sameRoot
      if not ready
        then pure NodeVolumeRemovalReceiptUnobservable
        else do
          owner <- getEffectiveUserID
          rootStatus <- Files.getFdStatus root
          opened <- try (Posix.openFdAt (Just root) removalReceiptName Posix.ReadOnly readFlags)
          case opened of
            Left failure | isDoesNotExistError failure -> do
              still <- removalReceiptPreconditions bootstrap intent stable sameRoot
              pure (if still then NodeVolumeRemovalReceiptMissing else NodeVolumeRemovalReceiptUnobservable)
            Left (_ :: IOException) -> pure NodeVolumeRemovalReceiptUnobservable
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              initial <- Files.getFdStatus held
              if not (safeFile owner initial)
                then pure NodeVolumeRemovalReceiptUnobservable
                else do
                  bytes <- readBounded held
                  decoded <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <-
                    bracket
                      (Posix.openFdAt (Just root) removalReceiptName Posix.ReadOnly readFlags)
                      Posix.closeFd
                      Files.getFdStatus
                  still <- removalReceiptPreconditions bootstrap intent stable sameRoot
                  pure $
                    if not (still && sameVersion initial after && sameVersion after named)
                      then NodeVolumeRemovalReceiptUnobservable
                      else decodeRemovalReceipt bootstrap intent rootStatus bytes decoded
    pure
      ( either
          (const NodeVolumeRemovalReceiptUnobservable)
          id
          (checked :: Either IOException KindNodeVolumeRemovalReceiptObservation)
      )
  pure $ case outcome of
    Just (Right observed) -> observed
    _ -> NodeVolumeRemovalReceiptUnobservable

removalReceiptPreconditions
  :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO Bool -> IO Bool
removalReceiptPreconditions bootstrap intent stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeVolumeRemoval bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeVolumeRemovalMatches && afterRoot && after)

validRemovalResult :: DockerNodeVarRemoveResult -> Bool
validRemovalResult DockerNodeVarRemoveNotStarted = True
validRemovalResult DockerNodeVarRemoveUnconfirmed = True
validRemovalResult (DockerNodeVarRemoveReply status) = status >= 100 && status <= 599

removalReceiptBytes
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> DockerNodeVarRemoveResult
  -> Files.FileStatus
  -> BS.ByteString
removalReceiptBytes bootstrap intent result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-var-volume-removal-result" :: String)
        , "removal" Aeson..= TextEncoding.decodeUtf8 (removalBytes bootstrap intent root)
        , "transport" Aeson..= removalResultValue result
        ]

removalResultValue :: DockerNodeVarRemoveResult -> Aeson.Value
removalResultValue result = case result of
  DockerNodeVarRemoveNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeVarRemoveUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeVarRemoveReply status -> Aeson.object ["state" Aeson..= ("reply" :: String), "status" Aeson..= status]

decodeRemovalReceipt
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeVolumeRemovalReceiptObservation
decodeRemovalReceipt bootstrap intent root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validRemovalResult result -> case Aeson.eitherDecodeStrict' (removalReceiptBytes bootstrap intent result root) of
      Right wanted | value == wanted -> NodeVolumeRemovalReceiptObserved result
      _ -> NodeVolumeRemovalReceiptConflict
    _ -> NodeVolumeRemovalReceiptInvalid
  _ -> NodeVolumeRemovalReceiptInvalid
 where
  parser = Aeson.withObject "volume removal result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeVarRemoveNotStarted
              "unconfirmed" -> pure DockerNodeVarRemoveUnconfirmed
              "reply" -> DockerNodeVarRemoveReply <$> transport .: "status"
              _ -> fail "invalid volume removal result"
        )

receiptPreconditions :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO Bool -> IO Bool
receiptPreconditions bootstrap intent stable sameRoot = do
  before <- stable
  root <- sameRoot
  if not (before && root)
    then pure False
    else do
      parent <- observeKindNodeVolumeAttempt bootstrap intent (pure True)
      afterRoot <- sameRoot
      after <- stable
      pure (parent == NodeVolumeAttemptMatches && afterRoot && after)

validResult :: DockerNodeVarCreateResult -> Bool
validResult result = case result of
  DockerNodeVarCreateNotStarted -> True
  DockerNodeVarCreateUnconfirmed -> True
  DockerNodeVarCreateReply status observation ->
    status >= 100 && status <= 599 && case (status, observation) of
      (201, Just DockerNodeVarVolumeMatching) -> True
      (201, Just DockerNodeVarVolumeConflict) -> True
      (201, _) -> False
      (_, Nothing) -> True
      _ -> False

receiptBytes
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> DockerNodeVarCreateResult
  -> Files.FileStatus
  -> BS.ByteString
receiptBytes bootstrap intent result root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-var-volume-create-result" :: String)
        , "attempt" Aeson..= TextEncoding.decodeUtf8 (attemptBytes bootstrap intent root)
        , "transport" Aeson..= resultValue result
        ]

resultValue :: DockerNodeVarCreateResult -> Aeson.Value
resultValue result = case result of
  DockerNodeVarCreateNotStarted -> Aeson.object ["state" Aeson..= ("not-started" :: String)]
  DockerNodeVarCreateUnconfirmed -> Aeson.object ["state" Aeson..= ("unconfirmed" :: String)]
  DockerNodeVarCreateReply status observed ->
    Aeson.object
      [ "state" Aeson..= ("reply" :: String)
      , "status" Aeson..= status
      , "observation" Aeson..= fmap observationText observed
      ]
 where
  observationText DockerNodeVarVolumeMatching = "matching" :: String
  observationText DockerNodeVarVolumeConflict = "conflict"
  observationText DockerNodeVarVolumeNotFound = "not-found"

decodeReceipt
  :: BootstrapProjection
  -> KindNodeVolumeIntent
  -> Files.FileStatus
  -> BS.ByteString
  -> Either failure Aeson.Value
  -> KindNodeVolumeReceiptObservation
decodeReceipt bootstrap intent root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right validated) | value == validated -> case parseEither parser value of
    Right result | validResult result -> case Aeson.eitherDecodeStrict' (receiptBytes bootstrap intent result root) of
      Right wanted | value == wanted -> NodeVolumeReceiptObserved result
      _ -> NodeVolumeReceiptConflict
    _ -> NodeVolumeReceiptInvalid
  _ -> NodeVolumeReceiptInvalid
 where
  parser = Aeson.withObject "volume result" $ \object ->
    object .: "transport"
      >>= Aeson.withObject
        "transport"
        ( \transport -> do
            state <- transport .: "state" :: Parser String
            case state of
              "not-started" -> pure DockerNodeVarCreateNotStarted
              "unconfirmed" -> pure DockerNodeVarCreateUnconfirmed
              "reply" -> do
                status <- transport .: "status"
                observation <- transport .: "observation" :: Parser (Maybe String)
                parsed <- case observation of
                  Nothing -> pure Nothing
                  Just "matching" -> pure (Just DockerNodeVarVolumeMatching)
                  Just "conflict" -> pure (Just DockerNodeVarVolumeConflict)
                  _ -> fail "invalid volume observation"
                pure (DockerNodeVarCreateReply status parsed)
              _ -> fail "invalid volume result"
        )

attemptPreconditions :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO Bool -> IO Bool
attemptPreconditions bootstrap intent stable sameRoot = do
  before <- preconditions bootstrap intent stable sameRoot
  if not before
    then pure False
    else do
      parent <- observeKindNodeVolumeIntent bootstrap intent stable
      after <- preconditions bootstrap intent stable sameRoot
      pure (parent == NodeVolumeIntentMatches && after)

attemptBytes :: BootstrapProjection -> KindNodeVolumeIntent -> Files.FileStatus -> BS.ByteString
attemptBytes bootstrap intent root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("kind-node-var-volume-attempt" :: String)
        , "intent" Aeson..= TextEncoding.decodeUtf8 (recordBytes bootstrap intent root)
        ]

preconditions :: BootstrapProjection -> KindNodeVolumeIntent -> IO Bool -> IO Bool -> IO Bool
preconditions bootstrap (KindNodeVolumeIntent operation _ _) stable sameRoot = do
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

recordBytes :: BootstrapProjection -> KindNodeVolumeIntent -> Files.FileStatus -> BS.ByteString
recordBytes bootstrap (KindNodeVolumeIntent operation daemon (DockerSocketIdentity device inode owner mode)) root =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "operation_id" Aeson..= operation
        , "operation" Aeson..= ("kind-node-var-volume-create" :: String)
        , "volume"
            Aeson..= ( kindNodeVarVolumeNameForScope
                         (bootstrapScope bootstrap)
                         (Text.unpack (bootstrapRootGeneration bootstrap))
                         operation
                     )
        , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
        , "root_device" Aeson..= toInteger (Files.deviceID root)
        , "root_inode" Aeson..= toInteger (Files.fileID root)
        , "runtime_socket" Aeson..= bootstrapRuntimeSocket bootstrap
        , "daemon_id" Aeson..= daemon
        , "socket_device" Aeson..= device
        , "socket_inode" Aeson..= inode
        , "socket_owner" Aeson..= owner
        , "socket_mode" Aeson..= mode
        ]

recordName :: FilePath
recordName = "kind-node-var-volume-intent.json"

attemptName :: FilePath
attemptName = "kind-node-var-volume-attempt.json"

receiptName :: FilePath
receiptName = "kind-node-var-volume-create-result.json"

removalName :: FilePath
removalName = "kind-node-var-volume-removal.json"

removalReceiptName :: FilePath
removalReceiptName = "kind-node-var-volume-removal-result.json"

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
