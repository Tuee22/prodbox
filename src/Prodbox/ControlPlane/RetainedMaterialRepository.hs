{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact-revision retained-material aggregate storage.
module Prodbox.ControlPlane.RetainedMaterialRepository
  ( RetainedMaterialSnapshot (..)
  , RetainedMaterialRepository (..)
  , retainedMaterialModelBCodec
  , modelBRetainedMaterialRepository
  , applyRetainedMaterialCommand
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedMaterialAggregate
  , RetainedMaterialCommand
  , RetainedMaterialDecision
  , SRetainedMaterialSchema
  , applyRetainedMaterialDecision
  , decideRetainedMaterial
  , decodeRetainedMaterialAggregate
  , encodeRetainedMaterialAggregate
  , initialRetainedMaterialAggregate
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  )

data RetainedMaterialSnapshot schema revision = RetainedMaterialSnapshot
  { retainedMaterialSnapshotRevision :: !(Maybe revision)
  , retainedMaterialSnapshotAggregate :: !(RetainedMaterialAggregate schema)
  }
  deriving stock (Eq, Show)

data RetainedMaterialRepository schema m revision = RetainedMaterialRepository
  { readRetainedMaterialSnapshot
      :: m (Either Text (RetainedMaterialSnapshot schema revision))
  , compareAndSwapRetainedMaterial
      :: Maybe revision
      -> RetainedMaterialAggregate schema
      -> m (Either Text ())
  }

retainedMaterialModelBCodec
  :: SRetainedMaterialSchema schema
  -> ModelBCodec (RetainedMaterialAggregate schema)
retainedMaterialModelBCodec schema =
  ModelBCodec
    { encodeModelBValue =
        either (Left . show) Right . encodeRetainedMaterialAggregate schema
    , decodeModelBValue =
        either (Left . show) Right . decodeRetainedMaterialAggregate schema
    }

modelBRetainedMaterialRepository
  :: (Monad m)
  => ModelBCasAdapter lifetime m (RetainedMaterialAggregate schema)
  -> ModelBObjectCoordinate lifetime
  -> RetainedMaterialRepository schema m ModelBObjectVersion
modelBRetainedMaterialRepository adapter coordinate =
  RetainedMaterialRepository
    { readRetainedMaterialSnapshot = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right (RetainedMaterialSnapshot Nothing initialRetainedMaterialAggregate)
          ModelBObserved revision aggregate ->
            Right (RetainedMaterialSnapshot (Just revision) aggregate)
          ModelBCorrupt detail -> Left ("retained material is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("retained material is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("retained material is unobservable: " <> detail)
    , compareAndSwapRetainedMaterial = \expected aggregate -> do
        result <- modelBCompareAndSwap adapter $ case expected of
          Nothing -> ModelBInitialize coordinate aggregate
          Just revision -> ModelBReplace coordinate revision aggregate
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "retained material CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("retained material CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("retained material CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("retained material CAS is unobservable: " <> detail)
    }

applyRetainedMaterialCommand
  :: (Monad m)
  => RetainedMaterialRepository schema m revision
  -> RetainedMaterialCommand schema
  -> m (Either Text (RetainedMaterialDecision schema))
applyRetainedMaterialCommand repository command = do
  observed <- readRetainedMaterialSnapshot repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot -> do
      let aggregate = retainedMaterialSnapshotAggregate snapshot
          decision = decideRetainedMaterial aggregate command
          next = applyRetainedMaterialDecision decision aggregate
      if next == aggregate
        then pure (Right decision)
        else do
          written <-
            compareAndSwapRetainedMaterial
              repository
              (retainedMaterialSnapshotRevision snapshot)
              next
          pure $ case written of
            Left detail -> Left (Text.take 256 detail)
            Right () -> Right decision
