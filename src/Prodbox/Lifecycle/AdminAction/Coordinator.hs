{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host coordinator for the attested one-shot Admin Action Job.
--
-- The durable, secret-free permit is prepared before Kubernetes creation. The
-- credential frame is constructed only after exact Pod attestation and
-- Authority authorization. Every post-intent path performs Job deletion and a
-- positive absence read-back; cleanup failure suppresses any action receipt.
module Prodbox.Lifecycle.AdminAction.Coordinator
  ( AdminActionKubernetesBoundary (..)
  , AdminActionCleanupBinding (..)
  , AdminActionCoordinatorError (..)
  , coordinateAdminAction
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
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AdminActionClient
  ( AdminActionClient
  , AdminActionClientError
  , authorizeAdminActionClient
  , completeAdminActionClient
  , observeAdminActionClient
  , prepareAdminActionClient
  )
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionPodObservation
  , AdminActionPrepareRequest (..)
  )
import Prodbox.Lifecycle.AdminAction.Kubernetes
  ( AdminActionAttestationError
  , AdminActionJobIntent
  , AdminActionJobIntentError
  , RawAdminActionPodObservation (..)
  , mkAdminActionJobIntent
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionBackupReceipt
  , AdminActionExecutionState (..)
  , AdminActionPermitCore
  , AdminActionProtocolError
  , AdminActionReceipt
  , SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , adminActionJobUid
  , decodeAdminActionReceipt
  , signedAdminActionPermitBackupReceipt
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  , verifyAdminActionReceiptForPermit
  )
import Prodbox.Lifecycle.AdminAction.WorkerProtocol
  ( AdminActionWorkerIngressError
  , encodeAdminActionWorkerIngress
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Settings (Credentials)

data AdminActionKubernetesBoundary m = AdminActionKubernetesBoundary
  { createAdminActionJob
      :: AdminActionJobIntent
      -> m (Either Text ())
  , observeAdminActionJob
      :: AdminActionJobIntent
      -> m (Either Text (Maybe RawAdminActionPodObservation))
  , attestAdminActionJob
      :: AuthorityTime
      -> AdminActionJobIntent
      -> RawAdminActionPodObservation
      -> m (Either AdminActionAttestationError AdminActionPodObservation)
  , attachAdminActionIngress
      :: SignedAdminActionPermit
      -> ByteString
      -> m (Either Text ByteString)
  , deleteAdminActionJob
      :: AdminActionJobIntent
      -> Maybe AdminActionCleanupBinding
      -> m (Either Text ())
  , observeAdminActionJobAbsent
      :: AdminActionJobIntent
      -> Maybe AdminActionCleanupBinding
      -> m (Either Text Bool)
  }

data AdminActionCleanupBinding = AdminActionCleanupBinding
  { adminActionCleanupJobUid :: !Text
  , adminActionCleanupPodName :: !Text
  , adminActionCleanupPodUid :: !Text
  }
  deriving stock (Eq, Show)

data AdminActionCoordinatorError
  = AdminActionCoordinatorPrepareFailed !AdminActionClientError
  | AdminActionCoordinatorIntentRejected !AdminActionJobIntentError
  | AdminActionCoordinatorCreateFailed !Text
  | AdminActionCoordinatorObservationFailed !Text
  | AdminActionCoordinatorWorkloadAbsent
  | AdminActionCoordinatorAttestationFailed !AdminActionAttestationError
  | AdminActionCoordinatorAuthorizeFailed !AdminActionClientError
  | AdminActionCoordinatorFrameRejected !AdminActionWorkerIngressError
  | AdminActionCoordinatorAttachFailed !Text
  | AdminActionCoordinatorReceiptRejected !AdminActionProtocolError
  | AdminActionCoordinatorCompleteFailed !AdminActionClientError
  | AdminActionCoordinatorObserveFailed !AdminActionClientError
  | AdminActionCoordinatorAuthorityStateConflict
  | AdminActionCoordinatorDeleteFailed !Text
  | AdminActionCoordinatorAbsenceUnobservable !Text
  | AdminActionCoordinatorStillPresent
  | AdminActionCoordinatorUnhandledException
  deriving stock (Eq, Show)

coordinateAdminAction
  :: AdminActionClient IO
  -> AdminActionKubernetesBoundary IO
  -> AuthorityTime
  -> Natural
  -> Text
  -> Credentials
  -> AdminActionPrepareRequest
  -> IO (Either AdminActionCoordinatorError AdminActionReceipt)
coordinateAdminAction client kubernetes now maximumLifetimeSeconds imageReference credentials request = do
  prepared <- prepareAdminActionClient client request
  case prepared of
    Left err -> pure (Left (AdminActionCoordinatorPrepareFailed err))
    Right (core, backup) -> case mkAdminActionJobIntent now maximumLifetimeSeconds core imageReference of
      Left err -> pure (Left (AdminActionCoordinatorIntentRejected err))
      Right intent -> do
        observed <- observeAdminActionClient client (adminActionPrepareOperationId request)
        case observed of
          Left err -> pure (Left (AdminActionCoordinatorObserveFailed err))
          Right state -> case authoritativeCompletion core backup state of
            Left err -> pure (Left err)
            Right (Just (completedPermit, completedReceipt)) ->
              finishRecovered intent completedPermit completedReceipt
            Right Nothing -> coordinateIntent core backup intent
 where
  finishRecovered intent completedPermit completedReceipt = do
    mask_ $ do
      cleanup <-
        cleanupAdminActionJob
          kubernetes
          intent
          (Just (permitCleanupBinding completedPermit))
      pure (completedReceipt <$ cleanup)

  coordinateIntent core backup intent = do
    -- The mask begins before Job creation.  Individual remote effects remain
    -- interruptible through @restore@, while the exact cleanup binding update
    -- and the hand-off into terminal cleanup cannot be interrupted.
    mask $ \restore -> do
      cleanupBindingRef <- newIORef Nothing
      attempted <- tryAny $ do
        created <- restore (createAdminActionJob kubernetes intent)
        observed <- restore (observeAdminActionJob kubernetes intent)
        case observed of
          Left detail ->
            pure
              ( Left
                  ( case created of
                      Left createDetail ->
                        AdminActionCoordinatorCreateFailed
                          (boundedDetail createDetail detail)
                      Right () -> AdminActionCoordinatorObservationFailed detail
                  )
              )
          Right Nothing ->
            pure
              ( Left
                  ( case created of
                      Left detail -> AdminActionCoordinatorCreateFailed detail
                      Right () -> AdminActionCoordinatorWorkloadAbsent
                  )
              )
          Right (Just raw) -> do
            -- Observation transfers cleanup ownership before any attestation
            -- field is forced.  A malformed/mismatched Pod is still the exact
            -- Job/Pod that this coordinator must UID-delete; it must never
            -- fall back to a name-only cleanup after an attestation refusal
            -- or cancellation while evaluating the observation.
            writeIORef cleanupBindingRef (rawCleanupBinding raw)
            attested <- restore (attestAdminActionJob kubernetes now intent raw)
            case attested of
              Left err ->
                pure (Left (AdminActionCoordinatorAttestationFailed err))
              Right attestation -> do
                authorized <-
                  restore
                    ( authorizeAdminActionClient
                        client
                        (adminActionPrepareOperationId request)
                        attestation
                    )
                case authorized of
                  Left err -> do
                    recovered <- restore (recoverCompleted core backup)
                    pure $ case recovered of
                      Right (Just (_, recoveredReceipt)) -> Right recoveredReceipt
                      _ -> Left (AdminActionCoordinatorAuthorizeFailed err)
                  Right permit -> case encodeAdminActionWorkerIngress permit credentials of
                    Left err ->
                      pure (Left (AdminActionCoordinatorFrameRejected err))
                    Right ingress -> do
                      attached <-
                        restore (attachAdminActionIngress kubernetes permit ingress)
                      case attached of
                        Left detail -> do
                          recovered <- restore (recoverCompleted core backup)
                          pure $ case recovered of
                            Right (Just (_, recoveredReceipt)) -> Right recoveredReceipt
                            _ -> Left (AdminActionCoordinatorAttachFailed detail)
                        Right receiptBytes -> case decodeAndVerifyReceipt permit receiptBytes of
                          Left err ->
                            pure (Left (AdminActionCoordinatorReceiptRejected err))
                          Right receipt -> do
                            completed <-
                              restore
                                ( completeAdminActionClient
                                    client
                                    (adminActionPrepareOperationId request)
                                    receipt
                                )
                            case completed of
                              Left err -> do
                                recovered <- restore (recoverCompleted core backup)
                                pure $ case recovered of
                                  Right (Just (_, recoveredReceipt)) -> Right recoveredReceipt
                                  _ -> Left (AdminActionCoordinatorCompleteFailed err)
                              Right confirmed -> pure (Right confirmed)
      cleanupBinding <- readIORef cleanupBindingRef
      cleanup <- cleanupAdminActionJob kubernetes intent cleanupBinding
      case attempted of
        Left exception
          | isAsyncException exception -> throwIO exception
        _ -> pure $ case cleanup of
          Left err -> Left err
          Right () -> case attempted of
            Left _ -> Left AdminActionCoordinatorUnhandledException
            Right outcome -> outcome

  recoverCompleted core backup = do
    observed <- observeAdminActionClient client (adminActionPrepareOperationId request)
    pure $ case observed of
      Left err -> Left (AdminActionCoordinatorObserveFailed err)
      Right state -> authoritativeCompletion core backup state

cleanupAdminActionJob
  :: AdminActionKubernetesBoundary IO
  -> AdminActionJobIntent
  -> Maybe AdminActionCleanupBinding
  -> IO (Either AdminActionCoordinatorError ())
cleanupAdminActionJob boundary intent binding = do
  deleted <- tryAny (deleteAdminActionJob boundary intent binding)
  absent <- tryAny (observeAdminActionJobAbsent boundary intent binding)
  pure $ case absent of
    -- Positive absence is authoritative even when the delete response was
    -- lost or its transport threw after Kubernetes applied it.
    Right (Right True) -> Right ()
    Left _ -> Left (AdminActionCoordinatorAbsenceUnobservable "cleanup observation threw")
    Right (Left detail) -> Left (AdminActionCoordinatorAbsenceUnobservable detail)
    Right (Right False) -> case deleted of
      Left _ -> Left (AdminActionCoordinatorDeleteFailed "cleanup deletion threw")
      Right (Left detail) -> Left (AdminActionCoordinatorDeleteFailed detail)
      Right (Right ()) -> Left AdminActionCoordinatorStillPresent

decodeAndVerifyReceipt
  :: SignedAdminActionPermit
  -> ByteString
  -> Either AdminActionProtocolError AdminActionReceipt
decodeAndVerifyReceipt permit bytes = do
  receipt <- decodeAdminActionReceipt bytes
  verifyAdminActionReceiptForPermit permit receipt
  pure receipt

rawCleanupBinding :: RawAdminActionPodObservation -> Maybe AdminActionCleanupBinding
rawCleanupBinding raw
  | observedAdminActionJobUid raw == "" = Nothing
  | observedAdminActionPodName raw == "" = Nothing
  | observedAdminActionPodUid raw == "" = Nothing
  | otherwise =
      Just
        AdminActionCleanupBinding
          { adminActionCleanupJobUid = observedAdminActionJobUid raw
          , adminActionCleanupPodName = observedAdminActionPodName raw
          , adminActionCleanupPodUid = observedAdminActionPodUid raw
          }

permitCleanupBinding :: SignedAdminActionPermit -> AdminActionCleanupBinding
permitCleanupBinding permit =
  AdminActionCleanupBinding
    { adminActionCleanupJobUid = adminActionJobUid binding
    , adminActionCleanupPodName = adminActionJobPodName binding
    , adminActionCleanupPodUid = adminActionJobPodUid binding
    }
 where
  binding = signedAdminActionPermitBinding permit

authoritativeCompletion
  :: AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> AdminActionExecutionState
  -> Either
       AdminActionCoordinatorError
       (Maybe (SignedAdminActionPermit, AdminActionReceipt))
authoritativeCompletion expectedCore expectedBackup state = case state of
  AdminActionExecutionPrepared core backup
    | core == expectedCore && backup == expectedBackup -> Right Nothing
    | otherwise -> Left AdminActionCoordinatorAuthorityStateConflict
  AdminActionExecutionAuthorized permit
    | permitMatches permit -> Right Nothing
    | otherwise -> Left AdminActionCoordinatorAuthorityStateConflict
  AdminActionExecutionCompleted permit receipt
    | not (permitMatches permit) -> Left AdminActionCoordinatorAuthorityStateConflict
    | otherwise -> case verifyAdminActionReceiptForPermit permit receipt of
        Left err -> Left (AdminActionCoordinatorReceiptRejected err)
        Right () -> Right (Just (permit, receipt))
  AdminActionExecutionIdle -> Left AdminActionCoordinatorAuthorityStateConflict
 where
  permitMatches permit =
    signedAdminActionPermitCore permit == expectedCore
      && signedAdminActionPermitBackupReceipt permit == expectedBackup

boundedDetail :: Text -> Text -> Text
boundedDetail left right = Text.take 256 left <> "; " <> Text.take 256 right

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)
