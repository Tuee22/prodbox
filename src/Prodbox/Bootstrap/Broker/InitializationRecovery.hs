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
  ( SecretFreeWorkerRequest
  , SecretWorkerDurableResult
  , SecretWorkerOperation (SecretWorkerInitialize)
  , secretWorkerCheckpointRequest
  , secretWorkerCheckpointResult
  , secretWorkerDurableResultOperation
  , secretWorkerRequestOperation
  , secretWorkerRequestStorageGeneration
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary
  , StoreBoundaryError (BootstrapStoreBindingMismatch)
  , StoreReadBack (..)
  , readEncryptedInitResponse
  , readSecretWorkerCheckpoint
  )
import Prodbox.Bootstrap.Broker.Types
  ( EncryptedInitResponseReceipt
  , RootInitBinding (rootInitStorageGeneration)
  )

data RootInitRecoveryObservation
  = RootInitRecoveredResponse !EncryptedInitResponseReceipt
  | RootInitRecoveredAmbiguity
  | RootInitRecoveredWorkerResult !SecretWorkerDurableResult
  deriving stock (Eq, Show)

-- | A missing result may be returned as 'Nothing' only after the caller proves
-- both exact absence and settlement of any publication already dispatched.
-- Pod absence alone is insufficient. An unobservable or potentially in-flight
-- result must be returned as an error.
observeRootInitRecoveryEvidence
  :: (Monad m)
  => BootstrapStoreBoundary m
  -> RootInitBinding
  -> (SecretFreeWorkerRequest -> m (Either StoreBoundaryError (Maybe SecretWorkerDurableResult)))
  -> m (Either StoreBoundaryError RootInitRecoveryObservation)
observeRootInitRecoveryEvidence store binding observePublished = do
  response <- readEncryptedInitResponse store binding
  case response of
    Left failure -> pure (Left failure)
    Right (StoreObjectPresent _ _ receipt) ->
      pure (Right (RootInitRecoveredResponse receipt))
    Right StoreObjectAbsent -> do
      worker <- readSecretWorkerCheckpoint store
      case worker of
        Left failure -> pure (Left failure)
        Right StoreObjectAbsent -> pure (Right RootInitRecoveredAmbiguity)
        Right (StoreObjectPresent _ _ checkpoint) ->
          case secretWorkerCheckpointResult checkpoint of
            Just result -> pure (Right (RootInitRecoveredWorkerResult result))
            Nothing -> case secretWorkerCheckpointRequest checkpoint of
              Left _ -> pure (Right RootInitRecoveredAmbiguity)
              Right request
                | secretWorkerRequestOperation request /= SecretWorkerInitialize ->
                    pure (Left BootstrapStoreBindingMismatch)
                | secretWorkerRequestStorageGeneration request /= rootInitStorageGeneration binding ->
                    pure (Left BootstrapStoreBindingMismatch)
                | otherwise -> do
                    observed <- observePublished request
                    pure $ case observed of
                      Left failure -> Left failure
                      Right Nothing -> Right RootInitRecoveredAmbiguity
                      Right (Just result)
                        | secretWorkerDurableResultOperation result == SecretWorkerInitialize ->
                            Right (RootInitRecoveredWorkerResult result)
                        | otherwise -> Left BootstrapStoreBindingMismatch
