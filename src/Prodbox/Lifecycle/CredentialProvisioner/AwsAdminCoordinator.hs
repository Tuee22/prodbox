{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Crash-safe host coordinator for one attested AWS-admin Credential
-- Provisioner Job. Authority state is committed before Kubernetes creation;
-- every path after creation UID-cleans the observed Job/Pod and requires a
-- positive absence read-back before returning a receipt.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminKubernetesBoundary (..)
  , AwsAdminCleanupBinding (..)
  , AwsAdminCoordinatorError (..)
  , coordinateAwsAdminProvisioning
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , throwIO
  , try
  )
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminPreparedProvisioning (..)
  , AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError
  , attestAwsAdminProvisioning
  , authorizeAwsAdminProvisioning
  , completeAwsAdminProvisioning
  , observeAwsAdminProvisioning
  , prepareAwsAdminProvisioning
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminPodObservation
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminExecutionError
  , AwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceipt
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
  , SignedAwsAdminPermit
  , awsAdminJobHeartbeat
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , awsAdminJobUid
  , awsAdminPermitIntentOperationId
  , decodeSignedAwsAdminPermit
  , signedAwsAdminPermitBinding
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorkerProtocol
  ( AwsAdminWorkerIngressError
  , encodeAwsAdminWorkerIngress
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.Lease (authorityTimeMicros)
import Prodbox.Settings (Credentials)

data AwsAdminKubernetesBoundary m = AwsAdminKubernetesBoundary
  { acquireAwsAdminJobHeartbeat
      :: m (Either Text Natural)
  , createAwsAdminJob
      :: Natural
      -> AwsAdminPreparedProvisioning
      -> m (Either Text ())
  , observeAwsAdminJob
      :: Natural
      -> AwsAdminPreparedProvisioning
      -> m (Either Text (Maybe AwsAdminPodObservation))
  , attachAwsAdminWorker
      :: SignedAwsAdminPermit
      -> ByteString
      -> m (Either Text ByteString)
  , deleteAwsAdminJob
      :: Natural
      -> AwsAdminPreparedProvisioning
      -> Maybe AwsAdminCleanupBinding
      -> m (Either Text ())
  , observeAwsAdminJobAbsent
      :: AwsAdminPreparedProvisioning
      -> Maybe AwsAdminCleanupBinding
      -> m (Either Text Bool)
  }

data AwsAdminCleanupBinding = AwsAdminCleanupBinding
  { awsAdminCleanupJobUid :: !Text
  , awsAdminCleanupPodName :: !Text
  , awsAdminCleanupPodUid :: !Text
  }
  deriving stock (Eq, Show)

data AwsAdminCoordinatorError
  = AwsAdminCoordinatorPrepareFailed !AwsAdminProvisionerClientError
  | AwsAdminCoordinatorObserveFailed !AwsAdminProvisionerClientError
  | AwsAdminCoordinatorHeartbeatUnavailable !Text
  | AwsAdminCoordinatorCreateFailed !Text
  | AwsAdminCoordinatorObservationFailed !Text
  | AwsAdminCoordinatorWorkloadAbsent
  | AwsAdminCoordinatorAttestFailed !AwsAdminProvisionerClientError
  | AwsAdminCoordinatorAuthorizeFailed !AwsAdminProvisionerClientError
  | AwsAdminCoordinatorIngressRejected !AwsAdminWorkerIngressError
  | AwsAdminCoordinatorAttachFailed !Text
  | AwsAdminCoordinatorReceiptRejected !AwsAdminExecutionError
  | AwsAdminCoordinatorCompleteFailed !AwsAdminProvisionerClientError
  | AwsAdminCoordinatorAuthorityStateConflict
  | AwsAdminCoordinatorDeleteFailed !Text
  | AwsAdminCoordinatorAbsenceUnobservable !Text
  | AwsAdminCoordinatorStillPresent
  | AwsAdminCoordinatorUnhandledException
  deriving stock (Eq, Show)

coordinateAwsAdminProvisioning
  :: AwsAdminProvisionerClient IO
  -> AwsAdminKubernetesBoundary IO
  -> Credentials
  -> AwsAdminPermitIntent
  -> IO (Either AwsAdminCoordinatorError AwsAdminWorkerReceipt)
coordinateAwsAdminProvisioning client kubernetes credentials requestedIntent = do
  preparedResult <- prepareAwsAdminProvisioning client requestedIntent
  case preparedResult of
    Left err -> pure (Left (AwsAdminCoordinatorPrepareFailed err))
    Right prepared -> do
      recovered <- recoverCompleted client operationId
      case recovered of
        Left err -> pure (Left err)
        Right (Just (permit, receipt)) ->
          mask_ $ do
            let heartbeat =
                  authorityTimeMicros
                    (awsAdminJobHeartbeat (signedAwsAdminPermitBinding permit))
            cleanup <-
              cleanupAwsAdminJob
                kubernetes
                heartbeat
                prepared
                (Just (cleanupBinding permit))
            pure (receipt <$ cleanup)
        Right Nothing -> do
          heartbeatResult <- acquireAwsAdminJobHeartbeat kubernetes
          case heartbeatResult of
            Left detail -> pure (Left (AwsAdminCoordinatorHeartbeatUnavailable detail))
            Right heartbeat -> coordinatePrepared heartbeat prepared
 where
  operationId =
    operatorMaterialOperationIdText
      (awsAdminPermitIntentOperationId requestedIntent)

  coordinatePrepared heartbeat prepared = mask $ \restore -> do
    cleanupRef <- newIORef Nothing
    attempted <- tryAny $ do
      created <- restore (createAwsAdminJob kubernetes heartbeat prepared)
      observed <- restore (observeAwsAdminJob kubernetes heartbeat prepared)
      case observed of
        Left detail ->
          pure
            ( Left
                ( case created of
                    Left createDetail -> AwsAdminCoordinatorCreateFailed (createDetail <> "; " <> detail)
                    Right () -> AwsAdminCoordinatorObservationFailed detail
                )
            )
        Right Nothing ->
          pure
            ( Left
                ( case created of
                    Left detail -> AwsAdminCoordinatorCreateFailed detail
                    Right () -> AwsAdminCoordinatorWorkloadAbsent
                )
            )
        Right (Just pod) -> do
          attested <- restore (attestAwsAdminProvisioning client requestedIntent operationId pod)
          case attested of
            Left err -> pure (Left (AwsAdminCoordinatorAttestFailed err))
            Right binding -> do
              writeIORef cleanupRef (Just (bindingCleanup binding))
              authorized <- restore (authorizeAwsAdminProvisioning client operationId)
              case authorized of
                Left err -> recoverOr (AwsAdminCoordinatorAuthorizeFailed err)
                Right permit -> case encodeAwsAdminWorkerIngress permit credentials of
                  Left err -> pure (Left (AwsAdminCoordinatorIngressRejected err))
                  Right ingress -> do
                    attached <- restore (attachAwsAdminWorker kubernetes permit ingress)
                    case attached of
                      Left detail -> recoverOr (AwsAdminCoordinatorAttachFailed detail)
                      Right bytes -> case decodeAndValidate permit bytes of
                        Left err -> pure (Left (AwsAdminCoordinatorReceiptRejected err))
                        Right receipt -> do
                          completed <-
                            restore
                              (completeAwsAdminProvisioning client operationId permit receipt)
                          case completed of
                            Left err -> recoverOr (AwsAdminCoordinatorCompleteFailed err)
                            Right confirmed -> case validateAwsAdminWorkerReceiptForPermit permit confirmed of
                              Left err -> pure (Left (AwsAdminCoordinatorReceiptRejected err))
                              Right () -> pure (Right confirmed)
    binding <- readIORef cleanupRef
    cleanup <- cleanupAwsAdminJob kubernetes heartbeat prepared binding
    case attempted of
      Left exception | isAsyncException exception -> throwIO exception
      _ -> pure $ case cleanup of
        Left err -> Left err
        Right () -> case attempted of
          Left _ -> Left AwsAdminCoordinatorUnhandledException
          Right result -> result

  recoverOr original = do
    recovered <- recoverCompleted client operationId
    pure $ case recovered of
      Right (Just (_, receipt)) -> Right receipt
      _ -> Left original

decodeAndValidate
  :: SignedAwsAdminPermit
  -> ByteString
  -> Either AwsAdminExecutionError AwsAdminWorkerReceipt
decodeAndValidate permit bytes = do
  receipt <- decodeAwsAdminWorkerReceipt bytes
  validateAwsAdminWorkerReceiptForPermit permit receipt
  pure receipt

recoverCompleted
  :: AwsAdminProvisionerClient IO
  -> Text
  -> IO
       ( Either
           AwsAdminCoordinatorError
           (Maybe (SignedAwsAdminPermit, AwsAdminWorkerReceipt))
       )
recoverCompleted client operationId = do
  observed <- observeAwsAdminProvisioning client operationId
  pure $ case observed of
    Left err -> Left (AwsAdminCoordinatorObserveFailed err)
    Right observation -> completionFromObservation observation

completionFromObservation
  :: AwsAdminProvisionerObservation
  -> Either
       AwsAdminCoordinatorError
       (Maybe (SignedAwsAdminPermit, AwsAdminWorkerReceipt))
completionFromObservation observation = case awsAdminObservedPhase observation of
  AwsAdminProvisionerCompleted -> case (awsAdminObservedPermit observation, awsAdminObservedReceipt observation) of
    (Just permitBytes, Just receiptBytes) -> do
      somePermit <-
        either
          (const (Left AwsAdminCoordinatorAuthorityStateConflict))
          Right
          (decodeSignedAwsAdminPermit permitBytes)
      withSomeSignedAwsAdminPermit somePermit $ \permit -> do
        receipt <-
          either
            (Left . AwsAdminCoordinatorReceiptRejected)
            Right
            (decodeAndValidate permit receiptBytes)
        Right (Just (permit, receipt))
    _ -> Left AwsAdminCoordinatorAuthorityStateConflict
  _ -> Right Nothing

cleanupAwsAdminJob
  :: AwsAdminKubernetesBoundary IO
  -> Natural
  -> AwsAdminPreparedProvisioning
  -> Maybe AwsAdminCleanupBinding
  -> IO (Either AwsAdminCoordinatorError ())
cleanupAwsAdminJob kubernetes heartbeat prepared binding = do
  _ <- deleteAwsAdminJob kubernetes heartbeat prepared binding
  absent <- observeAwsAdminJobAbsent kubernetes prepared binding
  pure $ case absent of
    Left detail -> Left (AwsAdminCoordinatorAbsenceUnobservable detail)
    Right False -> Left AwsAdminCoordinatorStillPresent
    -- The delete response is provisional. Positive UID-bound absence is the
    -- authoritative terminal observation and closes response loss.
    Right True -> Right ()

bindingCleanup :: AwsAdminJobBinding -> AwsAdminCleanupBinding
bindingCleanup binding =
  AwsAdminCleanupBinding
    { awsAdminCleanupJobUid = awsAdminJobUid binding
    , awsAdminCleanupPodName = awsAdminJobPodName binding
    , awsAdminCleanupPodUid = awsAdminJobPodUid binding
    }

cleanupBinding :: SignedAwsAdminPermit -> AwsAdminCleanupBinding
cleanupBinding = bindingCleanup . signedAwsAdminPermitBinding

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception = case fromException exception :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False
