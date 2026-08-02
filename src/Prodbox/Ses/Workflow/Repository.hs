{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact-revision Model-B repository for the retained SES aggregate.
module Prodbox.Ses.Workflow.Repository
  ( SesWorkflowSnapshot (..)
  , SesWorkflowRepository (..)
  , sesWorkflowModelBCodec
  , modelBSesWorkflowRepository
  , applySesWorkflowEvent
  )
where

import Codec.Serialise (deserialiseOrFail, serialise)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  )
import Prodbox.Ses.Workflow.Model
  ( SesWorkflowEvent
  , SesWorkflowState
  , evolveSesWorkflow
  )

data SesWorkflowSnapshot revision = SesWorkflowSnapshot
  { sesWorkflowSnapshotRevision :: !revision
  , sesWorkflowSnapshotState :: !SesWorkflowState
  }
  deriving stock (Eq, Show)

data SesWorkflowRepository m revision = SesWorkflowRepository
  { readSesWorkflowSnapshot :: m (Either Text (SesWorkflowSnapshot revision))
  , compareAndSwapSesWorkflow
      :: revision
      -> SesWorkflowState
      -> m (Either Text ())
  }

sesWorkflowModelBCodec :: ModelBCodec SesWorkflowState
sesWorkflowModelBCodec =
  ModelBCodec
    { encodeModelBValue = Right . LazyByteString.toStrict . serialise
    , decodeModelBValue =
        either (Left . show) Right . deserialiseOrFail . LazyByteString.fromStrict
    }

-- | SES state has no implicit initial value at the storage boundary. Genesis
-- must be journaled with the selected contract and legacy epoch before this
-- repository is constructed.
modelBSesWorkflowRepository
  :: (Monad m)
  => ModelBCasAdapter lifetime m SesWorkflowState
  -> ModelBObjectCoordinate lifetime
  -> SesWorkflowRepository m ModelBObjectVersion
modelBSesWorkflowRepository adapter coordinate =
  SesWorkflowRepository
    { readSesWorkflowSnapshot = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBObserved revision state -> Right (SesWorkflowSnapshot revision state)
          ModelBMissing -> Left "SES workflow genesis is absent"
          ModelBCorrupt detail -> Left ("SES workflow is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("SES workflow store is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("SES workflow is unobservable: " <> detail)
    , compareAndSwapSesWorkflow = \revision state -> do
        result <- modelBCompareAndSwap adapter (ModelBReplace coordinate revision state)
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "SES workflow CAS conflict"
          ModelBCasRefusedCorrupt detail -> Left ("SES workflow CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("SES workflow CAS is not ready: " <> detail)
          ModelBCasUnobservable detail -> Left ("SES workflow CAS is unobservable: " <> detail)
    }

applySesWorkflowEvent
  :: (Monad m)
  => SesWorkflowRepository m revision
  -> SesWorkflowEvent
  -> m (Either Text SesWorkflowState)
applySesWorkflowEvent repository event = do
  observed <- readSesWorkflowSnapshot repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot -> do
      let next = evolveSesWorkflow (sesWorkflowSnapshotState snapshot) event
      if next == sesWorkflowSnapshotState snapshot
        then pure (Right next)
        else do
          written <-
            compareAndSwapSesWorkflow
              repository
              (sesWorkflowSnapshotRevision snapshot)
              next
          pure $ case written of
            Left detail -> Left (Text.take 256 detail)
            Right () -> Right next
