{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained, CAS-fenced lifecycle for one exact Vault worker role.
--
-- The journal closes Kubernetes-login response loss without blind retry.  A
-- caller first owns a monotonically greater fence, proves the role's prior
-- service-token inventory stably empty, and commits the one login attempt
-- before dispatching it.  Recovery from that committed attempt always enters
-- cleanup; only a later, greater fence may issue a successor login.
module Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , mkServiceSessionBinding
  , serviceSessionBindingRole
  , serviceSessionBindingOperationId
  , serviceSessionBindingAttemptId
  , serviceSessionBindingFence
  , ServiceSessionPhase (..)
  , ServiceSessionJournal
  , mkInitialServiceSessionJournal
  , serviceSessionJournalRole
  , serviceSessionJournalPhase
  , ServiceSessionEvent (..)
  , ServiceSessionJournalError (..)
  , stepServiceSessionJournal
  , encodeServiceSessionJournal
  , decodeServiceSessionJournal
  , serviceSessionJournalCodec
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionJournalRepository (..)
  , modelBServiceSessionJournalRepository
  , ServiceSessionJournalStoreError (..)
  , applyServiceSessionJournalEvent
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
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

data ServiceSessionBinding = ServiceSessionBinding
  { internalServiceSessionBindingRole :: !Text
  , internalServiceSessionBindingOperationId :: !Text
  , internalServiceSessionBindingAttemptId :: !Text
  , internalServiceSessionBindingFence :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkServiceSessionBinding
  :: Text
  -> Text
  -> Text
  -> Natural
  -> Either ServiceSessionJournalError ServiceSessionBinding
mkServiceSessionBinding role operationId attemptId fence = do
  validRole <- validateIdentity "worker-role" 160 role
  validOperation <- validateIdentity "operation-id" 192 operationId
  validAttempt <- validateIdentity "attempt-id" 192 attemptId
  when (fence == 0) (Left ServiceSessionFenceInvalid)
  pure
    ServiceSessionBinding
      { internalServiceSessionBindingRole = validRole
      , internalServiceSessionBindingOperationId = validOperation
      , internalServiceSessionBindingAttemptId = validAttempt
      , internalServiceSessionBindingFence = fence
      }

serviceSessionBindingRole :: ServiceSessionBinding -> Text
serviceSessionBindingRole = internalServiceSessionBindingRole

serviceSessionBindingOperationId :: ServiceSessionBinding -> Text
serviceSessionBindingOperationId = internalServiceSessionBindingOperationId

serviceSessionBindingAttemptId :: ServiceSessionBinding -> Text
serviceSessionBindingAttemptId = internalServiceSessionBindingAttemptId

serviceSessionBindingFence :: ServiceSessionBinding -> Natural
serviceSessionBindingFence = internalServiceSessionBindingFence

data ServiceSessionPhase
  = ServiceSessionVacant !Natural
  | ServiceSessionAcquiring !ServiceSessionBinding
  | ServiceSessionPrecleaned !ServiceSessionBinding
  | ServiceSessionLoginAttemptCommitted !ServiceSessionBinding
  | ServiceSessionActive !ServiceSessionBinding !Text
  | ServiceSessionCleanupRequired !ServiceSessionBinding !(Maybe Text)
  | ServiceSessionCleanupProven !ServiceSessionBinding
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ServiceSessionJournal = ServiceSessionJournal
  { internalServiceSessionJournalVersion :: !Word16
  , internalServiceSessionJournalRole :: !Text
  , internalServiceSessionJournalPhase :: !ServiceSessionPhase
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

serviceSessionJournalVersion :: Word16
serviceSessionJournalVersion = 1

serviceSessionJournalMaximumBytes :: Int
serviceSessionJournalMaximumBytes = 64 * 1024

mkInitialServiceSessionJournal
  :: Text -> Either ServiceSessionJournalError ServiceSessionJournal
mkInitialServiceSessionJournal role = do
  validRole <- validateIdentity "worker-role" 160 role
  pure
    ServiceSessionJournal
      { internalServiceSessionJournalVersion = serviceSessionJournalVersion
      , internalServiceSessionJournalRole = validRole
      , internalServiceSessionJournalPhase = ServiceSessionVacant 0
      }

serviceSessionJournalRole :: ServiceSessionJournal -> Text
serviceSessionJournalRole = internalServiceSessionJournalRole

serviceSessionJournalPhase :: ServiceSessionJournal -> ServiceSessionPhase
serviceSessionJournalPhase = internalServiceSessionJournalPhase

data ServiceSessionEvent
  = BeginServiceSessionAcquisition !ServiceSessionBinding
  | CommitServiceSessionPrecleaned !ServiceSessionBinding
  | CommitServiceSessionLoginAttempt !ServiceSessionBinding
  | CommitServiceSessionActive !ServiceSessionBinding !Text
  | RequireServiceSessionCleanup !ServiceSessionBinding
  | CommitServiceSessionCleanupProven !ServiceSessionBinding
  | ReleaseServiceSession !ServiceSessionBinding
  deriving stock (Eq, Show)

data ServiceSessionJournalError
  = ServiceSessionIdentityInvalid !Text
  | ServiceSessionFenceInvalid
  | ServiceSessionRoleMismatch
  | ServiceSessionFenceStale !Natural !Natural
  | ServiceSessionTransitionConflict
  | ServiceSessionAccessorInvalid
  | ServiceSessionJournalTooLarge !Int !Int
  | ServiceSessionJournalDecodeFailed
  | ServiceSessionJournalUnsupportedVersion !Word16
  | ServiceSessionJournalNonCanonical
  | ServiceSessionJournalInvariantInvalid
  deriving stock (Eq, Show)

stepServiceSessionJournal
  :: ServiceSessionEvent
  -> ServiceSessionJournal
  -> Either ServiceSessionJournalError ServiceSessionJournal
stepServiceSessionJournal event journal = do
  validateJournal journal
  let role = serviceSessionJournalRole journal
      phase = serviceSessionJournalPhase journal
      setPhase next = journal {internalServiceSessionJournalPhase = next}
      validateBinding binding =
        unless
          (serviceSessionBindingRole binding == role)
          (Left ServiceSessionRoleMismatch)
  case event of
    BeginServiceSessionAcquisition binding -> do
      validateBinding binding
      case phase of
        ServiceSessionVacant previousFence
          | serviceSessionBindingFence binding > previousFence ->
              pure (setPhase (ServiceSessionAcquiring binding))
          | otherwise ->
              Left
                ( ServiceSessionFenceStale
                    previousFence
                    (serviceSessionBindingFence binding)
                )
        ServiceSessionAcquiring existing
          | existing == binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    CommitServiceSessionPrecleaned binding -> do
      validateBinding binding
      case phase of
        ServiceSessionAcquiring existing
          | existing == binding ->
              pure (setPhase (ServiceSessionPrecleaned binding))
        ServiceSessionPrecleaned existing
          | existing == binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    CommitServiceSessionLoginAttempt binding -> do
      validateBinding binding
      case phase of
        ServiceSessionPrecleaned existing
          | existing == binding ->
              pure (setPhase (ServiceSessionLoginAttemptCommitted binding))
        ServiceSessionLoginAttemptCommitted existing
          | existing == binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    CommitServiceSessionActive binding rawAccessor -> do
      validateBinding binding
      accessor <- validateAccessor rawAccessor
      case phase of
        ServiceSessionLoginAttemptCommitted existing
          | existing == binding ->
              pure (setPhase (ServiceSessionActive binding accessor))
        ServiceSessionActive existing existingAccessor
          | existing == binding && existingAccessor == accessor -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    RequireServiceSessionCleanup binding -> do
      validateBinding binding
      let required accessor =
            pure (setPhase (ServiceSessionCleanupRequired binding accessor))
      case phase of
        ServiceSessionAcquiring existing
          | existing == binding -> required Nothing
        ServiceSessionPrecleaned existing
          | existing == binding -> required Nothing
        ServiceSessionLoginAttemptCommitted existing
          | existing == binding -> required Nothing
        ServiceSessionActive existing accessor
          | existing == binding -> required (Just accessor)
        ServiceSessionCleanupRequired existing _
          | existing == binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    CommitServiceSessionCleanupProven binding -> do
      validateBinding binding
      case phase of
        ServiceSessionCleanupRequired existing _
          | existing == binding ->
              pure (setPhase (ServiceSessionCleanupProven binding))
        ServiceSessionCleanupProven existing
          | existing == binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict
    ReleaseServiceSession binding -> do
      validateBinding binding
      case phase of
        ServiceSessionCleanupProven existing
          | existing == binding ->
              pure
                ( setPhase
                    (ServiceSessionVacant (serviceSessionBindingFence binding))
                )
        ServiceSessionVacant fence
          | fence == serviceSessionBindingFence binding -> Right journal
        _ -> Left ServiceSessionTransitionConflict

encodeServiceSessionJournal :: ServiceSessionJournal -> ByteString
encodeServiceSessionJournal = LazyByteString.toStrict . serialise

decodeServiceSessionJournal
  :: ByteString -> Either ServiceSessionJournalError ServiceSessionJournal
decodeServiceSessionJournal bytes = do
  when
    (ByteString.length bytes > serviceSessionJournalMaximumBytes)
    ( Left
        ( ServiceSessionJournalTooLarge
            (ByteString.length bytes)
            serviceSessionJournalMaximumBytes
        )
    )
  journal <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left ServiceSessionJournalDecodeFailed
    Right value -> Right value
  when
    (internalServiceSessionJournalVersion journal /= serviceSessionJournalVersion)
    ( Left
        ( ServiceSessionJournalUnsupportedVersion
            (internalServiceSessionJournalVersion journal)
        )
    )
  validateJournal journal
  unless
    (encodeServiceSessionJournal journal == bytes)
    (Left ServiceSessionJournalNonCanonical)
  pure journal

serviceSessionJournalCodec :: ModelBCodec ServiceSessionJournal
serviceSessionJournalCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodeServiceSessionJournal
    , decodeModelBValue = either (Left . show) Right . decodeServiceSessionJournal
    }

data ServiceSessionJournalSnapshot revision = ServiceSessionJournalSnapshot
  { serviceSessionJournalRevision :: !revision
  , serviceSessionJournalObserved :: !ServiceSessionJournal
  }
  deriving stock (Eq, Show)

data ServiceSessionJournalRepository m revision = ServiceSessionJournalRepository
  { readServiceSessionJournal
      :: m (Either Text (ServiceSessionJournalSnapshot revision))
  , compareAndSwapServiceSessionJournal
      :: revision
      -> ServiceSessionJournal
      -> m (Either Text ())
  }

modelBServiceSessionJournalRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m ServiceSessionJournal
  -> ModelBObjectCoordinate 'ClusterRetained
  -> Text
  -> ServiceSessionJournalRepository m (Maybe ModelBObjectVersion)
modelBServiceSessionJournalRepository adapter coordinate role =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> do
            initial <- firstText (mkInitialServiceSessionJournal role)
            Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = Nothing
                , serviceSessionJournalObserved = initial
                }
          ModelBObserved revision journal ->
            Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = Just revision
                , serviceSessionJournalObserved = journal
                }
          ModelBCorrupt detail -> Left ("service-session journal is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("service-session journal endpoint is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("service-session journal is unobservable: " <> detail)
    , compareAndSwapServiceSessionJournal = \expected journal -> do
        result <- modelBCompareAndSwap adapter $ case expected of
          Nothing -> ModelBInitialize coordinate journal
          Just revision -> ModelBReplace coordinate revision journal
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "service-session journal CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("service-session journal CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("service-session journal CAS endpoint is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("service-session journal CAS is unobservable: " <> detail)
    }

data ServiceSessionJournalStoreError
  = ServiceSessionJournalStoreUnavailable !Text
  | ServiceSessionJournalStoreTransitionRejected !ServiceSessionJournalError
  | ServiceSessionJournalStoreCommitFailed !Text
  | ServiceSessionJournalStoreReadBackMismatch
  deriving stock (Eq, Show)

applyServiceSessionJournalEvent
  :: (Monad m)
  => ServiceSessionJournalRepository m revision
  -> ServiceSessionEvent
  -> m (Either ServiceSessionJournalStoreError ServiceSessionJournal)
applyServiceSessionJournalEvent repository event = do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionJournalStoreUnavailable detail))
    Right snapshot -> case stepServiceSessionJournal event (serviceSessionJournalObserved snapshot) of
      Left err -> pure (Left (ServiceSessionJournalStoreTransitionRejected err))
      Right expected -> do
        committed <-
          compareAndSwapServiceSessionJournal
            repository
            (serviceSessionJournalRevision snapshot)
            expected
        case committed of
          Left detail -> do
            -- The CAS response may be lost after application.  Re-read before
            -- classifying it as failure; an exact expected value is the
            -- authoritative idempotent result.
            readBack <- readServiceSessionJournal repository
            pure $ case readBack of
              Right confirmed
                | serviceSessionJournalObserved confirmed == expected -> Right expected
              _ -> Left (ServiceSessionJournalStoreCommitFailed detail)
          Right () -> do
            readBack <- readServiceSessionJournal repository
            pure $ case readBack of
              Left detail -> Left (ServiceSessionJournalStoreUnavailable detail)
              Right confirmed
                | serviceSessionJournalObserved confirmed == expected -> Right expected
                | otherwise -> Left ServiceSessionJournalStoreReadBackMismatch

validateJournal
  :: ServiceSessionJournal -> Either ServiceSessionJournalError ()
validateJournal journal = do
  unless
    (internalServiceSessionJournalVersion journal == serviceSessionJournalVersion)
    (Left ServiceSessionJournalInvariantInvalid)
  validRole <-
    validateIdentity "worker-role" 160 (serviceSessionJournalRole journal)
  case serviceSessionJournalPhase journal of
    ServiceSessionVacant _ -> pure ()
    ServiceSessionAcquiring binding -> validateBound validRole binding
    ServiceSessionPrecleaned binding -> validateBound validRole binding
    ServiceSessionLoginAttemptCommitted binding -> validateBound validRole binding
    ServiceSessionActive binding accessor -> do
      validateBound validRole binding
      _ <- validateAccessor accessor
      pure ()
    ServiceSessionCleanupRequired binding maybeAccessor -> do
      validateBound validRole binding
      case maybeAccessor of
        Nothing -> pure ()
        Just accessor -> do
          _ <- validateAccessor accessor
          pure ()
    ServiceSessionCleanupProven binding -> validateBound validRole binding
 where
  validateBound role binding = do
    rebuilt <-
      mkServiceSessionBinding
        (serviceSessionBindingRole binding)
        (serviceSessionBindingOperationId binding)
        (serviceSessionBindingAttemptId binding)
        (serviceSessionBindingFence binding)
    unless
      (rebuilt == binding && serviceSessionBindingRole binding == role)
      (Left ServiceSessionJournalInvariantInvalid)

validateIdentity
  :: Text -> Int -> Text -> Either ServiceSessionJournalError Text
validateIdentity label maximumLength raw
  | Text.null value = Left (ServiceSessionIdentityInvalid label)
  | value /= raw = Left (ServiceSessionIdentityInvalid label)
  | Text.length value > maximumLength = Left (ServiceSessionIdentityInvalid label)
  | Text.any (\character -> isControl character || isSpace character) value =
      Left (ServiceSessionIdentityInvalid label)
  | otherwise = Right value
 where
  value = Text.strip raw

validateAccessor :: Text -> Either ServiceSessionJournalError Text
validateAccessor raw =
  case validateIdentity "accessor" 256 raw of
    Left _ -> Left ServiceSessionAccessorInvalid
    Right value -> Right value

firstText :: (Show errorValue) => Either errorValue value -> Either Text value
firstText = either (Left . Text.pack . show) Right
