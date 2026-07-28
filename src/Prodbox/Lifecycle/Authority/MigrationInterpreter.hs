{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Durable compare-and-swap interpreter for the single-writer migration
-- kernel. The repository owns opaque revision tokens; a command can never
-- overwrite state read from a different revision.
module Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  , MigrationApplyError (..)
  , MigrationApplyResult (..)
  , migrationStateCodec
  , modelBMigrationRepository
  , applyMigrationCommand
  )
where

import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCodecError
  , MigrationCommand
  , MigrationDecision
  , MigrationState
  , decodeMigrationState
  , encodeMigrationState
  , initialMigrationState
  , stepMigration
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )

data StoredMigration revision = StoredMigration
  { storedMigrationRevision :: !revision
  , storedMigrationBytes :: !ByteString
  }
  deriving stock (Eq, Show)

data MigrationRepository m revision = MigrationRepository
  { readMigrationState :: m (Either Text (Maybe (StoredMigration revision)))
  , compareAndSwapMigrationState
      :: Maybe revision
      -> ByteString
      -> m (Either Text Bool)
  }

data MigrationApplyError
  = MigrationReadFailed !Text
  | MigrationDecodeFailed !MigrationCodecError
  | MigrationWriteFailed !Text
  | MigrationConcurrentWrite
  deriving stock (Eq, Show)

data MigrationApplyResult = MigrationApplyResult
  { appliedMigrationState :: !MigrationState
  , appliedMigrationDecision :: !MigrationDecision
  }
  deriving stock (Eq, Show)

migrationStateCodec :: Int -> ModelBCodec MigrationState
migrationStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = Right . LazyByteString.toStrict . encodeMigrationState
    , decodeModelBValue =
        either (Left . show) Right
          . decodeMigrationState maximumBytes
          . LazyByteString.fromStrict
    }

modelBMigrationRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m MigrationState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> MigrationRepository m ModelBObjectVersion
modelBMigrationRepository adapter coordinate =
  MigrationRepository
    { readMigrationState = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right Nothing
          ModelBObserved revision state ->
            Right
              ( Just
                  StoredMigration
                    { storedMigrationRevision = revision
                    , storedMigrationBytes = encodeMigrationState state
                    }
              )
          ModelBCorrupt detail -> Left ("migration state is corrupt: " <> detail)
          ModelBUnobservable detail -> Left ("migration state is unobservable: " <> detail)
    , compareAndSwapMigrationState =
        writeModelBMigrationState
          migrationMaximumBytes
          adapter
          coordinate
    }
 where
  migrationMaximumBytes = 64 * 1024

writeModelBMigrationState
  :: (Monad m)
  => Int
  -> ModelBCasAdapter 'ClusterRetained m MigrationState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Maybe ModelBObjectVersion
  -> ByteString
  -> m (Either Text Bool)
writeModelBMigrationState maximumBytes adapter coordinate expected bytes =
  case decodeMigrationState maximumBytes bytes of
    Left err -> pure (Left (Text.pack ("migration write refused: " ++ show err)))
    Right state -> do
      result <-
        modelBCompareAndSwap adapter $ case expected of
          Nothing -> ModelBInitialize coordinate state
          Just revision -> ModelBReplace coordinate revision state
      pure $ case result of
        ModelBCasApplied _ _ -> Right True
        ModelBCasConflict _ -> Right False
        ModelBCasRefusedCorrupt detail -> Left ("migration CAS refused corrupt: " <> detail)
        ModelBCasUnobservable detail -> Left ("migration CAS unobservable: " <> detail)

applyMigrationCommand
  :: (Monad m)
  => Int
  -> MigrationRepository m revision
  -> MigrationCommand
  -> m (Either MigrationApplyError MigrationApplyResult)
applyMigrationCommand maximumBytes repository command = do
  observed <- readMigrationState repository
  case observed of
    Left detail -> pure (Left (MigrationReadFailed detail))
    Right maybeStored ->
      case decodeObserved maybeStored of
        Left err -> pure (Left err)
        Right (expectedRevision, current) -> do
          let (next, decision) = stepMigration current command
              result =
                MigrationApplyResult
                  { appliedMigrationState = next
                  , appliedMigrationDecision = decision
                  }
          if next == current
            then pure (Right result)
            else do
              written <-
                compareAndSwapMigrationState
                  repository
                  expectedRevision
                  (encodeMigrationState next)
              pure $ case written of
                Left detail -> Left (MigrationWriteFailed detail)
                Right False -> Left MigrationConcurrentWrite
                Right True -> Right result
 where
  decodeObserved maybeStored = case maybeStored of
    Nothing -> Right (Nothing, initialMigrationState)
    Just stored ->
      case decodeMigrationState maximumBytes (storedMigrationBytes stored) of
        Left err -> Left (MigrationDecodeFailed err)
        Right state -> Right (Just (storedMigrationRevision stored), state)
