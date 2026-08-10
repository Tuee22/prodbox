{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Read-only Lifecycle Authority identity, active-writer epoch, and clock
-- projection.  The response is produced only after the retained migration
-- state is observably decoded; a missing state is the explicit legacy-writer
-- initial state, while corruption and unobservability fail closed.
module Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( LifecycleAuthorityObserveRequest
  , LifecycleAuthorityObservation (..)
  , AuthorityObservationResult (..)
  , lifecycleAuthorityServiceIdentity
  , mkLifecycleAuthorityObserveRequest
  , serveLifecycleAuthorityObserveRequest
  , serveLifecycleAuthorityAggregateObserveRequest
  , authorityObservationHttpStatus
  , authorityObservationResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityMigrationMode (..)
  , authorityAggregateAdmission
  , authorityAggregateMigration
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , authorityEpochValue
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , migrationAuthorityStatus
  , mkMigrationEpoch
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationApplyError (..)
  , MigrationRepository
  , observeMigrationState
  )

newtype LifecycleAuthorityObserveRequest = LifecycleAuthorityObserveRequest
  { requestedAuthorityScope :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LifecycleAuthorityObservation = LifecycleAuthorityObservation
  { observedAuthorityServiceIdentity :: !Text
  , observedAuthorityScope :: !Text
  , observedAuthorityWriterStatus :: !MigrationAuthorityStatus
  , observedAuthorityAdmission :: !(Maybe AuthorityAdmissionState)
  , observedAuthorityTimeMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityObservationResult
  = AuthorityObservationBadRequest !ControlPlaneRequestCodecError
  | AuthorityObservationScopeMismatch
  | AuthorityObservationReadFailed !Text
  | AuthorityObservationStateCorrupt
  | AuthorityObservationClockFailed !Text
  | AuthorityObservationSucceeded !LifecycleAuthorityObservation
  deriving stock (Eq, Show)

lifecycleAuthorityServiceIdentity :: Text
lifecycleAuthorityServiceIdentity = "prodbox-lifecycle-authority"

mkLifecycleAuthorityObserveRequest
  :: Text -> Either Text LifecycleAuthorityObserveRequest
mkLifecycleAuthorityObserveRequest raw
  | Text.null raw = Left "Lifecycle Authority scope must not be empty"
  | Text.length raw > 128 = Left "Lifecycle Authority scope exceeds 128 characters"
  | Text.any (\character -> isControl character || isSpace character) raw =
      Left "Lifecycle Authority scope must not contain whitespace or control characters"
  | otherwise = Right (LifecycleAuthorityObserveRequest raw)

serveLifecycleAuthorityObserveRequest
  :: (Monad m)
  => Int
  -> Text
  -> m (Either Text Natural)
  -> MigrationRepository m revision
  -> LazyByteString.ByteString
  -> m AuthorityObservationResult
serveLifecycleAuthorityObserveRequest maximumBytes authorityScope observeNow repository body =
  serveLifecycleAuthorityObserveWith
    maximumBytes
    authorityScope
    observeNow
    observeWriterStatus
    body
 where
  observeWriterStatus = do
    observedState <- observeMigrationState maximumBytes repository
    pure $ case observedState of
      Left (MigrationReadFailed detail) -> Left (AuthorityObservationReadFailed detail)
      Left (MigrationDecodeFailed _) -> Left AuthorityObservationStateCorrupt
      Left (MigrationWriteFailed detail) -> Left (AuthorityObservationReadFailed detail)
      Left MigrationConcurrentWrite ->
        Left (AuthorityObservationReadFailed "migration observation raced with a writer")
      Right state -> Right (migrationAuthorityStatus state, Nothing)

-- | Observe writer identity from the same retained aggregate that gates and
-- appends submissions.  A clean install has no legacy writer: it is quiesced
-- until genesis/repair admission is open, then reports the exact Authority
-- epoch as the replacement writer generation.  A migration-controlled install
-- projects its retained migration fold directly.
serveLifecycleAuthorityAggregateObserveRequest
  :: (Monad m)
  => Int
  -> Text
  -> m (Either Text Natural)
  -> AuthorityAdmissionRepository m revision
  -> LazyByteString.ByteString
  -> m AuthorityObservationResult
serveLifecycleAuthorityAggregateObserveRequest maximumBytes authorityScope observeNow repository =
  serveLifecycleAuthorityObserveWith
    maximumBytes
    authorityScope
    observeNow
    observeWriterStatus
 where
  observeWriterStatus = do
    observed <- readAuthorityAdmission repository
    pure $ case observed of
      Left detail -> Left (AuthorityObservationReadFailed detail)
      Right snapshot ->
        let aggregate = authorityAdmissionSnapshotState snapshot
         in case aggregateWriterStatus aggregate of
              Left detail -> Left (AuthorityObservationReadFailed detail)
              Right status ->
                Right
                  ( status
                  , Just (authorityAggregateAdmission aggregate)
                  )

serveLifecycleAuthorityObserveWith
  :: (Monad m)
  => Int
  -> Text
  -> m (Either Text Natural)
  -> m
       ( Either
           AuthorityObservationResult
           (MigrationAuthorityStatus, Maybe AuthorityAdmissionState)
       )
  -> LazyByteString.ByteString
  -> m AuthorityObservationResult
serveLifecycleAuthorityObserveWith maximumBytes authorityScope observeNow observeStatus body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityObservationBadRequest err)
    Right request
      | requestedAuthorityScope request /= authorityScope ->
          pure AuthorityObservationScopeMismatch
      | otherwise -> do
          observedStatus <- observeStatus
          case observedStatus of
            Left failure -> pure failure
            Right (writerStatus, admissionState) -> do
              observedNow <- observeNow
              pure $ case observedNow of
                Left detail -> AuthorityObservationClockFailed detail
                Right now ->
                  AuthorityObservationSucceeded
                    LifecycleAuthorityObservation
                      { observedAuthorityServiceIdentity = lifecycleAuthorityServiceIdentity
                      , observedAuthorityScope = authorityScope
                      , observedAuthorityWriterStatus = writerStatus
                      , observedAuthorityAdmission = admissionState
                      , observedAuthorityTimeMicros = now
                      }

aggregateWriterStatus
  :: AuthorityAdmissionAggregate
  -> Either Text MigrationAuthorityStatus
aggregateWriterStatus aggregate = case authorityAggregateMigration aggregate of
  AuthorityMigrationControlled migration -> Right (migrationAuthorityStatus migration)
  AuthorityCleanInstall -> case authorityAggregateAdmission aggregate of
    BackupEstablished epoch _ _
      | authorityEpochValue epoch > fromIntegral (maxBound :: Word) ->
          Left "Authority epoch exceeds the migration observation generation bound"
      | otherwise ->
          maybe
            (Left "Authority epoch is not a valid migration observation generation")
            (Right . MigrationReplacementWriterActive)
            (mkMigrationEpoch (fromIntegral (authorityEpochValue epoch)))
    GenesisFrozen -> Right MigrationWritersQuiesced
    EstablishingBackup _ -> Right MigrationWritersQuiesced
    BackupRepairFrozen _ _ -> Right MigrationWritersQuiesced

authorityObservationHttpStatus :: AuthorityObservationResult -> ReplyStatus
authorityObservationHttpStatus result = case result of
  AuthorityObservationBadRequest _ -> ReplyBadRequest
  AuthorityObservationScopeMismatch -> ReplyConflict
  AuthorityObservationReadFailed _ -> ReplyServiceUnavailable
  AuthorityObservationStateCorrupt -> ReplyInternalError
  AuthorityObservationClockFailed _ -> ReplyServiceUnavailable
  AuthorityObservationSucceeded _ -> ReplyOk

authorityObservationResponseBody :: AuthorityObservationResult -> ByteString
authorityObservationResponseBody result = case result of
  AuthorityObservationSucceeded observation ->
    LazyByteString.toStrict (encodeControlPlaneResponse observation)
  AuthorityObservationBadRequest _ -> "authority-observe-bad-request"
  AuthorityObservationScopeMismatch -> "authority-observe-scope-mismatch"
  AuthorityObservationReadFailed _ -> "authority-observe-read-failed"
  AuthorityObservationStateCorrupt -> "authority-observe-state-corrupt"
  AuthorityObservationClockFailed _ -> "authority-observe-clock-failed"
