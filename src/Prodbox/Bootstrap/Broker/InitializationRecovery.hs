{-# LANGUAGE DerivingStrategies #-}

-- | Observe retained initialization evidence without replaying the Vault call.
-- A durable worker result survives the interval before its encrypted response
-- is published separately. The engine still validates its binding and settles
-- the exact worker checkpoint before advancing the root journal.
module Prodbox.Bootstrap.Broker.InitializationRecovery
  ( RootInitRecoveryObservation (..)
  , observeRootInitRecoveryEvidence
  )
where

import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretWorkerDurableResult
  , secretWorkerCheckpointResult
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary
  , StoreBoundaryError
  , StoreReadBack (..)
  , readEncryptedInitResponse
  , readSecretWorkerCheckpoint
  )
import Prodbox.Bootstrap.Broker.Types
  ( EncryptedInitResponseReceipt
  , RootInitBinding
  )

data RootInitRecoveryObservation
  = RootInitRecoveredResponse !EncryptedInitResponseReceipt
  | RootInitRecoveredAmbiguity
  | RootInitRecoveredWorkerResult !SecretWorkerDurableResult
  deriving stock (Eq, Show)

observeRootInitRecoveryEvidence
  :: (Monad m)
  => BootstrapStoreBoundary m
  -> RootInitBinding
  -> m (Either StoreBoundaryError RootInitRecoveryObservation)
observeRootInitRecoveryEvidence store binding = do
  response <- readEncryptedInitResponse store binding
  case response of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent _ _ receipt) ->
      pure (Right (RootInitRecoveredResponse receipt))
    Right StoreObjectAbsent -> do
      worker <- readSecretWorkerCheckpoint store
      pure $ case worker of
        Left failure -> Left failure
        Right StoreObjectAbsent -> Right RootInitRecoveredAmbiguity
        Right (StoreObjectPresent _ _ checkpoint) ->
          Right $ case secretWorkerCheckpointResult checkpoint of
            Nothing -> RootInitRecoveredAmbiguity
            Just result -> RootInitRecoveredWorkerResult result
