{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authority-retained record of one established registered-stack generation,
-- addressed by the run-invariant slot the generation key hashes to.
--
-- The measured defect this repository closes: the existing
-- @authority/aws-stack-creations/@ slot is keyed by the cleanup surface and
-- durable run scope of the run that created the stack, so a /later/ cleanup run
-- cannot address it.  A generation record is addressed by
-- 'stackGenerationSlotLogicalName' instead, which contains no fact about who was
-- running, so the creating run and the cleaning run compute the same slot
-- without either knowing the other's scope.
--
-- Selection is bound to the read-back: a cleanup run derives its addressing key
-- from the compiled registry and its own exact Provider credential session,
-- reads the record that key addresses, requires the stored key to equal the
-- addressing key, and only then applies the surface eligibility check.  There is
-- no path by which a residue observation, a surface-keyed slot, or a caller
-- assertion supplies the selected generation.
module Prodbox.ControlPlane.RegisteredStackGenerationRepository
  ( -- * The durable record
    RegisteredStackGenerationRecord
  , prepareRegisteredStackGenerationRecord
  , registeredStackGenerationRecordGeneration
  , registeredStackGenerationRecordKey
  , registeredStackGenerationRecordBytes
  , registeredStackGenerationRecordLogicalName

    -- * Repository boundary
  , RegisteredStackGenerationCommitResult (..)
  , RegisteredStackGenerationReadBack (..)
  , RegisteredStackGenerationRepository (..)
  , registeredStackGenerationModelBCodec
  , modelBRegisteredStackGenerationRepository

    -- * Committed generations
  , CommittedRegisteredStackGeneration
  , committedRegisteredStackGeneration
  , committedRegisteredStackGenerationKey
  , confirmCommittedRegisteredStackGenerationReadBack
  , commitRegisteredStackGenerationWithRepair
  , independentlyReadBackRegisteredStackGeneration

    -- * Ordinal succession
  , StackGenerationCursorObservation (..)
  , ObservedStackGenerationCursor (..)
  , StackGenerationCursorCommitResult (..)
  , StackGenerationCursorRepository (..)
  , stackGenerationCursorModelBCodec
  , modelBStackGenerationCursorRepository
  , ReservedStackGeneration (..)
  , reserveNextStackGeneration

    -- * Cleanup selection bound to the read-back
  , selectRegisteredStackGenerationFromRepository
  , selectCurrentRegisteredStackGeneration

    -- * Refusals
  , RegisteredStackGenerationError (..)
  , renderRegisteredStackGenerationError
  )
where

import Control.Monad (when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( ObservedAwsStackCreationOperation
  , observedAwsStackCreationKey
  , observedAwsStackCreationOperationId
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize, ModelBReplace)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface
  , DurableObservationRunScope
  , LinuxRke2FoundationId
  , ObservationFailure (..)
  , RegisteredResourceKey
  )
import Prodbox.Lifecycle.Teardown.StackGeneration
  ( ProvenProviderAwsSession
  , RegisteredStackGeneration
  , SelectedStackGeneration
  , StackGenerationCursor
  , StackGenerationError (StackGenerationRecordFieldInvalid)
  , StackGenerationKey
  , StackGenerationOrdinal
  , StackGenerationSeriesKey
  , advanceStackGenerationCursor
  , decodeRegisteredStackGeneration
  , decodeStackGenerationCursor
  , encodeRegisteredStackGeneration
  , encodeStackGenerationCursor
  , maximumRegisteredStackGenerationRecordBytes
  , maximumStackGenerationCursorRecordBytes
  , openStackGenerationCursor
  , registeredStackGenerationKey
  , renderStackGenerationError
  , selectRegisteredStackGeneration
  , stackGenerationCursorAdmittedOperationId
  , stackGenerationCursorOrdinal
  , stackGenerationCursorSeries
  , stackGenerationKeyForOrdinal
  , stackGenerationKeyText
  , stackGenerationSelectorForKey
  , stackGenerationSeriesKeyFromProviderScope
  , stackGenerationSeriesKeyText
  , stackGenerationSeriesSlotLogicalName
  , stackGenerationSlotLogicalName
  )

-- ---------------------------------------------------------------------------
-- The durable record
-- ---------------------------------------------------------------------------

-- | A generation together with the exact canonical bytes that represent it.
-- Opaque so the bytes a commit writes and the bytes a read-back confirms are
-- always the same function of the same generation.
data RegisteredStackGenerationRecord = RegisteredStackGenerationRecord
  { internalRecordGeneration :: !RegisteredStackGeneration
  , internalRecordBytes :: !ByteString
  }

instance Eq RegisteredStackGenerationRecord where
  left == right = internalRecordBytes left == internalRecordBytes right

instance Show RegisteredStackGenerationRecord where
  show record =
    "<registered-stack-generation-record:"
      <> Text.unpack
        ( stackGenerationSlotLogicalName
            (registeredStackGenerationRecordKey record)
        )
      <> ">"

registeredStackGenerationRecordGeneration
  :: RegisteredStackGenerationRecord -> RegisteredStackGeneration
registeredStackGenerationRecordGeneration = internalRecordGeneration

registeredStackGenerationRecordKey
  :: RegisteredStackGenerationRecord -> StackGenerationKey
registeredStackGenerationRecordKey =
  registeredStackGenerationKey . internalRecordGeneration

registeredStackGenerationRecordBytes
  :: RegisteredStackGenerationRecord -> ByteString
registeredStackGenerationRecordBytes = internalRecordBytes

-- | The run-invariant Authority object name this record occupies.
registeredStackGenerationRecordLogicalName
  :: RegisteredStackGenerationRecord -> Text
registeredStackGenerationRecordLogicalName =
  stackGenerationSlotLogicalName . registeredStackGenerationRecordKey

-- | Encode a generation and prove the bytes round-trip to the same generation
-- before anything is written.  A record that cannot be read back as itself is
-- refused at preparation, not discovered at recovery.
prepareRegisteredStackGenerationRecord
  :: RegisteredStackGeneration
  -> Either RegisteredStackGenerationError RegisteredStackGenerationRecord
prepareRegisteredStackGenerationRecord generation = do
  let bytes = encodeRegisteredStackGeneration generation
  when
    (ByteString.length bytes > maximumRegisteredStackGenerationRecordBytes)
    ( Left
        ( RegisteredStackGenerationRecordTooLarge
            maximumRegisteredStackGenerationRecordBytes
            (ByteString.length bytes)
        )
    )
  decoded <-
    first RegisteredStackGenerationRecordInvalid (decodeRegisteredStackGeneration bytes)
  if decoded == generation
    then
      Right
        RegisteredStackGenerationRecord
          { internalRecordGeneration = decoded
          , internalRecordBytes = bytes
          }
    else
      Left
        ( RegisteredStackGenerationRecordInvalid
            ( StackGenerationRecordFieldInvalid
                "the encoded generation did not round-trip"
            )
        )

-- ---------------------------------------------------------------------------
-- Repository boundary
-- ---------------------------------------------------------------------------

data RegisteredStackGenerationCommitResult
  = RegisteredStackGenerationCommitCreated
  | RegisteredStackGenerationCommitExactReplay
  | RegisteredStackGenerationCommitConflict
  | RegisteredStackGenerationCommitResponseLost !ObservationFailure
  | RegisteredStackGenerationCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data RegisteredStackGenerationReadBack
  = RegisteredStackGenerationReadBackPresent !ByteString
  | RegisteredStackGenerationReadBackMissing
  | RegisteredStackGenerationReadBackCorrupt !Text
  | RegisteredStackGenerationReadBackUnobservable !ObservationFailure
  | RegisteredStackGenerationReadBackUnbounded !Int !Int
  deriving stock (Eq, Show)

-- | The read-back is keyed by the run-invariant 'StackGenerationKey' alone.
-- There is deliberately no accessor taking a run scope or a cleanup surface:
-- addressing a generation must not require knowing who created it.
data RegisteredStackGenerationRepository m = RegisteredStackGenerationRepository
  { createOrReplayRegisteredStackGeneration
      :: RegisteredStackGenerationRecord
      -> m RegisteredStackGenerationCommitResult
  , independentlyReadBackRegisteredStackGenerationBytes
      :: StackGenerationKey -> m RegisteredStackGenerationReadBack
  }

registeredStackGenerationModelBCodec :: ModelBCodec ByteString
registeredStackGenerationModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalBytes
    , decodeModelBValue = first show . validateCanonicalBytes
    }
 where
  validateCanonicalBytes bytes = do
    _ <- decodeRegisteredStackGeneration bytes
    Right bytes

modelBRegisteredStackGenerationRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> RegisteredStackGenerationRepository m
modelBRegisteredStackGenerationRepository authority adapter =
  RegisteredStackGenerationRepository
    { createOrReplayRegisteredStackGeneration = createOrReplay
    , independentlyReadBackRegisteredStackGenerationBytes = readBack
    }
 where
  createOrReplay record =
    case coordinateFor (registeredStackGenerationRecordKey record) of
      Left failure ->
        pure (RegisteredStackGenerationCommitUnavailable failure)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate record
          ModelBObserved _ existing ->
            pure (existingDisposition record existing)
          ModelBCorrupt detail -> pure (unavailable "corrupt" detail)
          ModelBEndpointUnready detail ->
            pure (unavailable "endpoint-unready" detail)
          ModelBUnobservable detail ->
            pure (unavailable "unobservable" detail)

  initialize coordinate record = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (registeredStackGenerationRecordBytes record))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == registeredStackGenerationRecordBytes record ->
            RegisteredStackGenerationCommitCreated
        | otherwise -> RegisteredStackGenerationCommitConflict
      ModelBCasConflict observation -> conflictDisposition record observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail ->
        unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        RegisteredStackGenerationCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack key = case coordinateFor key of
    Left failure ->
      pure (RegisteredStackGenerationReadBackUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> RegisteredStackGenerationReadBackMissing
        ModelBObserved _ bytes
          | ByteString.length bytes > maximumRegisteredStackGenerationRecordBytes ->
              RegisteredStackGenerationReadBackUnbounded
                (ByteString.length bytes)
                maximumRegisteredStackGenerationRecordBytes
          | otherwise -> RegisteredStackGenerationReadBackPresent bytes
        ModelBCorrupt detail -> RegisteredStackGenerationReadBackCorrupt detail
        ModelBEndpointUnready detail ->
          unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor key =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      (mkClusterRetainedCoordinate authority (stackGenerationSlotLogicalName key))

  unavailable category detail =
    RegisteredStackGenerationCommitUnavailable (repositoryFailure category detail)
  unobservable category detail =
    RegisteredStackGenerationReadBackUnobservable
      (repositoryFailure category detail)

existingDisposition
  :: RegisteredStackGenerationRecord
  -> ByteString
  -> RegisteredStackGenerationCommitResult
existingDisposition candidate existing
  | existing == registeredStackGenerationRecordBytes candidate =
      RegisteredStackGenerationCommitExactReplay
  | otherwise = RegisteredStackGenerationCommitConflict

conflictDisposition
  :: RegisteredStackGenerationRecord
  -> ModelBObservation ByteString
  -> RegisteredStackGenerationCommitResult
conflictDisposition candidate observation = case observation of
  ModelBObserved _ existing -> existingDisposition candidate existing
  ModelBMissing -> RegisteredStackGenerationCommitConflict
  ModelBCorrupt detail ->
    RegisteredStackGenerationCommitUnavailable
      (repositoryFailure "cas-conflict-corrupt" detail)
  ModelBEndpointUnready detail ->
    RegisteredStackGenerationCommitUnavailable
      (repositoryFailure "cas-conflict-endpoint-unready" detail)
  ModelBUnobservable detail ->
    RegisteredStackGenerationCommitResponseLost
      (repositoryFailure "cas-conflict-unobservable" detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ( Text.take
        1024
        ("registered stack generation repository " <> category <> ": " <> detail)
    )

-- ---------------------------------------------------------------------------
-- Committed generations
-- ---------------------------------------------------------------------------

-- | A generation observed in its own durable slot by a read-back independent of
-- the write that produced it.
newtype CommittedRegisteredStackGeneration = CommittedRegisteredStackGeneration
  { committedRegisteredStackGeneration :: RegisteredStackGeneration
  }
  deriving stock (Eq, Show)

committedRegisteredStackGenerationKey
  :: CommittedRegisteredStackGeneration -> StackGenerationKey
committedRegisteredStackGenerationKey =
  registeredStackGenerationKey . committedRegisteredStackGeneration

-- | Confirm one read-back against the key that addressed it.  A record whose
-- stored key differs from the addressing key is a slot-collision refusal, never
-- a successful selection of \"whatever was there\".
confirmCommittedRegisteredStackGenerationReadBack
  :: StackGenerationKey
  -> RegisteredStackGenerationReadBack
  -> Either RegisteredStackGenerationError CommittedRegisteredStackGeneration
confirmCommittedRegisteredStackGenerationReadBack expected observed =
  case observed of
    RegisteredStackGenerationReadBackMissing ->
      Left (RegisteredStackGenerationAbsent expected)
    RegisteredStackGenerationReadBackCorrupt detail ->
      Left (RegisteredStackGenerationCorrupt detail)
    RegisteredStackGenerationReadBackUnobservable failure ->
      Left (RegisteredStackGenerationUnobservable failure)
    RegisteredStackGenerationReadBackUnbounded actual limit ->
      Left (RegisteredStackGenerationRecordTooLarge limit actual)
    RegisteredStackGenerationReadBackPresent bytes -> do
      generation <-
        first
          RegisteredStackGenerationRecordInvalid
          (decodeRegisteredStackGeneration bytes)
      let actual = registeredStackGenerationKey generation
      if actual == expected
        then Right (CommittedRegisteredStackGeneration generation)
        else Left (RegisteredStackGenerationSlotKeyMismatch expected actual)

-- | Read one generation back at the slot its own key addresses.
independentlyReadBackRegisteredStackGeneration
  :: (Monad m)
  => RegisteredStackGenerationRepository m
  -> StackGenerationKey
  -> m (Either RegisteredStackGenerationError CommittedRegisteredStackGeneration)
independentlyReadBackRegisteredStackGeneration repository key = do
  observed <- independentlyReadBackRegisteredStackGenerationBytes repository key
  pure (confirmCommittedRegisteredStackGenerationReadBack key observed)

-- | Commit a generation and settle the outcome by independent read-back.
--
-- This is the same response-loss repair the AWS stack-creation binding already
-- performs: a lost CAS response is not a failure and not a success, so the only
-- honest resolution is to observe the slot again.  A read-back showing the exact
-- record repairs the lost response to a commit; a read-back showing absence
-- reports that nothing was committed and names the lost response; a read-back
-- showing a different record is a conflict.  Every terminal answer is therefore
-- carried by an observation rather than by the ambiguous write response.
commitRegisteredStackGenerationWithRepair
  :: (Monad m)
  => RegisteredStackGenerationRepository m
  -> RegisteredStackGeneration
  -> m (Either RegisteredStackGenerationError CommittedRegisteredStackGeneration)
commitRegisteredStackGenerationWithRepair repository generation =
  case prepareRegisteredStackGenerationRecord generation of
    Left err -> pure (Left err)
    Right record -> do
      committed <- createOrReplayRegisteredStackGeneration repository record
      case committed of
        RegisteredStackGenerationCommitCreated -> confirm record
        RegisteredStackGenerationCommitExactReplay -> confirm record
        RegisteredStackGenerationCommitConflict ->
          pure
            ( Left
                ( RegisteredStackGenerationConflict
                    (registeredStackGenerationRecordKey record)
                )
            )
        RegisteredStackGenerationCommitUnavailable failure ->
          pure (Left (RegisteredStackGenerationUnavailable failure))
        RegisteredStackGenerationCommitResponseLost failure -> do
          repaired <- confirm record
          pure $ case repaired of
            Right value -> Right value
            Left (RegisteredStackGenerationAbsent _) ->
              Left (RegisteredStackGenerationCommitNotApplied failure)
            Left other -> Left other
 where
  confirm record =
    independentlyReadBackRegisteredStackGeneration
      repository
      (registeredStackGenerationRecordKey record)

-- ---------------------------------------------------------------------------
-- Ordinal succession
-- ---------------------------------------------------------------------------

-- | A cursor observed together with the store version that produced it, so a
-- succession can be written conditionally on exactly what it read.
data ObservedStackGenerationCursor = ObservedStackGenerationCursor
  { observedStackGenerationCursor :: !StackGenerationCursor
  , observedStackGenerationCursorVersion :: !ModelBObjectVersion
  }
  deriving stock (Eq, Show)

data StackGenerationCursorObservation
  = StackGenerationCursorAbsent
  | StackGenerationCursorPresent !ObservedStackGenerationCursor
  | StackGenerationCursorCorrupt !Text
  | StackGenerationCursorUnobservable !ObservationFailure
  deriving stock (Eq, Show)

data StackGenerationCursorCommitResult
  = StackGenerationCursorCommitApplied
  | StackGenerationCursorCommitConflict
  | StackGenerationCursorCommitResponseLost !ObservationFailure
  | StackGenerationCursorCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

-- | Opening a series and advancing it are distinct writes: the first must find
-- no cursor, the second must find exactly the version it read.  Neither
-- accepts an unconditional overwrite.
data StackGenerationCursorRepository m = StackGenerationCursorRepository
  { observeStackGenerationCursor
      :: StackGenerationSeriesKey -> m StackGenerationCursorObservation
  , openStackGenerationCursorSlot
      :: StackGenerationCursor -> m StackGenerationCursorCommitResult
  , advanceStackGenerationCursorSlot
      :: ModelBObjectVersion
      -> StackGenerationCursor
      -> m StackGenerationCursorCommitResult
  }

stackGenerationCursorModelBCodec :: ModelBCodec ByteString
stackGenerationCursorModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalCursorBytes
    , decodeModelBValue = first show . validateCanonicalCursorBytes
    }
 where
  validateCanonicalCursorBytes bytes = do
    _ <- decodeStackGenerationCursor bytes
    Right bytes

modelBStackGenerationCursorRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> StackGenerationCursorRepository m
modelBStackGenerationCursorRepository authority adapter =
  StackGenerationCursorRepository
    { observeStackGenerationCursor = observe
    , openStackGenerationCursorSlot = \cursor ->
        write cursor (\coordinate bytes -> ModelBInitialize coordinate bytes)
    , advanceStackGenerationCursorSlot = \version cursor ->
        write cursor (\coordinate bytes -> ModelBReplace coordinate version bytes)
    }
 where
  observe series = case coordinateFor series of
    Left failure -> pure (StackGenerationCursorUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> StackGenerationCursorAbsent
        ModelBObserved version bytes
          | ByteString.length bytes > maximumStackGenerationCursorRecordBytes ->
              StackGenerationCursorCorrupt
                "the retained generation cursor exceeded its bound"
          | otherwise -> case decodeStackGenerationCursor bytes of
              Left err ->
                StackGenerationCursorCorrupt (renderStackGenerationError err)
              Right cursor ->
                StackGenerationCursorPresent
                  (ObservedStackGenerationCursor cursor version)
        ModelBCorrupt detail -> StackGenerationCursorCorrupt detail
        ModelBEndpointUnready detail ->
          StackGenerationCursorUnobservable
            (repositoryFailure "cursor-endpoint-unready" detail)
        ModelBUnobservable detail ->
          StackGenerationCursorUnobservable
            (repositoryFailure "cursor-unobservable" detail)

  write cursor request =
    case coordinateFor (stackGenerationCursorSeries cursor) of
      Left failure -> pure (StackGenerationCursorCommitUnavailable failure)
      Right coordinate -> do
        let bytes = encodeStackGenerationCursor cursor
        result <- modelBCompareAndSwap adapter (request coordinate bytes)
        pure $ case result of
          ModelBCasApplied _ applied
            | applied == bytes -> StackGenerationCursorCommitApplied
            | otherwise -> StackGenerationCursorCommitConflict
          ModelBCasConflict _ -> StackGenerationCursorCommitConflict
          ModelBCasRefusedCorrupt detail ->
            StackGenerationCursorCommitUnavailable
              (repositoryFailure "cursor-cas-corrupt" detail)
          ModelBCasEndpointUnready detail ->
            StackGenerationCursorCommitUnavailable
              (repositoryFailure "cursor-cas-endpoint-unready" detail)
          ModelBCasUnobservable detail ->
            StackGenerationCursorCommitResponseLost
              (repositoryFailure "cursor-cas-response-unobservable" detail)

  coordinateFor series =
    first
      (repositoryFailure "cursor-coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (stackGenerationSeriesSlotLogicalName series)
      )

-- | What one admitted create was given: the cycle it owns, and whether that
-- cycle was opened now, advanced now, or already reserved by this same admitted
-- operation on an earlier attempt.
data ReservedStackGeneration = ReservedStackGeneration
  { reservedStackGenerationOrdinal :: !StackGenerationOrdinal
  , reservedStackGenerationOperationId :: !OperationId
  , reservedStackGenerationWasReplay :: !Bool
  }
  deriving stock (Eq, Show)

-- | Reserve the cycle one admitted create owns.
--
-- Reservation is idempotent in the admitted operation: a retried create whose
-- operation already advanced the cursor is recognized as a replay and is given
-- back the same cycle, so a lost response cannot burn a second ordinal and
-- strand the record the first attempt may already have written.  Every other
-- outcome is settled by re-observing the cursor rather than by trusting the
-- write response.
reserveNextStackGeneration
  :: (Monad m)
  => StackGenerationCursorRepository m
  -> ObservedAwsStackCreationOperation
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> m (Either RegisteredStackGenerationError ReservedStackGeneration)
reserveNextStackGeneration repository observed providerScope foundation =
  case stackGenerationSeriesKeyFromProviderScope
    (observedAwsStackCreationKey observed)
    providerScope
    foundation of
    Left err -> pure (Left (RegisteredStackGenerationRecordInvalid err))
    Right series -> do
      current <- observeStackGenerationCursor repository series
      case current of
        StackGenerationCursorCorrupt detail ->
          pure (Left (RegisteredStackGenerationCorrupt detail))
        StackGenerationCursorUnobservable failure ->
          pure (Left (RegisteredStackGenerationUnobservable failure))
        StackGenerationCursorAbsent ->
          case openStackGenerationCursor observed providerScope foundation of
            Left err -> pure (Left (RegisteredStackGenerationRecordInvalid err))
            Right opened -> do
              committed <- openStackGenerationCursorSlot repository opened
              settle series committed (reservationFor opened False)
        StackGenerationCursorPresent existing
          | stackGenerationCursorAdmittedOperationId (observedStackGenerationCursor existing)
              == observedAwsStackCreationOperationId observed ->
              pure
                ( Right
                    ( reservationFor
                        (observedStackGenerationCursor existing)
                        True
                    )
                )
          | otherwise ->
              case advanceStackGenerationCursor
                (observedStackGenerationCursor existing)
                observed of
                Left err -> pure (Left (RegisteredStackGenerationRecordInvalid err))
                Right advanced -> do
                  committed <-
                    advanceStackGenerationCursorSlot
                      repository
                      (observedStackGenerationCursorVersion existing)
                      advanced
                  settle series committed (reservationFor advanced False)
 where
  reservationFor cursor wasReplay =
    ReservedStackGeneration
      { reservedStackGenerationOrdinal = stackGenerationCursorOrdinal cursor
      , reservedStackGenerationOperationId =
          stackGenerationCursorAdmittedOperationId cursor
      , reservedStackGenerationWasReplay = wasReplay
      }

  -- Whatever the write response said, the reservation is only what the cursor
  -- can be observed to hold afterwards.
  settle series committed intended = case committed of
    StackGenerationCursorCommitUnavailable failure ->
      pure (Left (RegisteredStackGenerationUnavailable failure))
    StackGenerationCursorCommitApplied -> confirm series intended Nothing
    StackGenerationCursorCommitConflict -> confirm series intended Nothing
    StackGenerationCursorCommitResponseLost failure ->
      confirm series intended (Just failure)

  confirm series intended lostResponse = do
    observedAgain <- observeStackGenerationCursor repository series
    pure $ case observedAgain of
      StackGenerationCursorCorrupt detail ->
        Left (RegisteredStackGenerationCorrupt detail)
      StackGenerationCursorUnobservable failure ->
        Left (RegisteredStackGenerationUnobservable failure)
      StackGenerationCursorAbsent ->
        Left
          ( maybe
              ( RegisteredStackGenerationCursorContended
                  (stackGenerationSeriesKeyText series)
              )
              RegisteredStackGenerationCommitNotApplied
              lostResponse
          )
      StackGenerationCursorPresent settled
        | stackGenerationCursorAdmittedOperationId
            (observedStackGenerationCursor settled)
            == reservedStackGenerationOperationId intended
            && stackGenerationCursorOrdinal (observedStackGenerationCursor settled)
              == reservedStackGenerationOrdinal intended ->
            Right intended
        | otherwise ->
            Left
              ( RegisteredStackGenerationCursorContended
                  (stackGenerationSeriesKeyText series)
              )

-- ---------------------------------------------------------------------------
-- Cleanup selection bound to the read-back
-- ---------------------------------------------------------------------------

-- | Select the generation a cleanup run must act on.
--
-- The addressing key is the run-invariant key the cleanup run derived from the
-- compiled registry and its own exact Provider credential session
-- (@stackGenerationKeyFromProviderScope@).  The selecting run scope and cleanup
-- surface are that run's own facts: they are recorded on the selection and
-- checked for surface eligibility, and they take no part in addressing the
-- record.  A cleanup run therefore never needs — and never consults — the run
-- scope or surface of the run that created the stack.
selectRegisteredStackGenerationFromRepository
  :: (Monad m)
  => RegisteredStackGenerationRepository m
  -> StackGenerationKey
  -> DurableObservationRunScope
  -> CleanupSurface
  -> m (Either RegisteredStackGenerationError SelectedStackGeneration)
selectRegisteredStackGenerationFromRepository
  repository
  addressingKey
  selectingRunScope
  selectingSurface = do
    committed <-
      independentlyReadBackRegisteredStackGeneration repository addressingKey
    pure $ do
      observed <- committed
      first
        RegisteredStackGenerationNotSelectable
        ( selectRegisteredStackGeneration
            ( stackGenerationSelectorForKey
                addressingKey
                selectingRunScope
                selectingSurface
            )
            (committedRegisteredStackGeneration observed)
        )

-- | The cleanup-run entry point: select the /current/ cycle of one registered
-- stack without being told which cycle that is.
--
-- A generation slot is addressed by its ordinal, so a cleanup run that knows
-- only the registered key cannot address a record directly.  The series cursor
-- is the one read that answers which cycle is current, and it is addressed by
-- the same registry-and-Provider-proof derivation the creating run used.  The
-- run therefore reaches the exact record through two authoritative reads and
-- never through visible residue: an unopened series refuses, an unobservable
-- store stays distinct from an absent one, and the record the ordinal addresses
-- must still carry exactly the key that addressed it.
selectCurrentRegisteredStackGeneration
  :: (Monad m)
  => StackGenerationCursorRepository m
  -> RegisteredStackGenerationRepository m
  -> RegisteredResourceKey
  -> ProvenProviderAwsSession
  -> LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> CleanupSurface
  -> m (Either RegisteredStackGenerationError SelectedStackGeneration)
selectCurrentRegisteredStackGeneration
  cursors
  generations
  resourceKey
  session
  foundation
  selectingRunScope
  selectingSurface =
    case stackGenerationSeriesKeyFromProviderScope resourceKey session foundation of
      Left err -> pure (Left (RegisteredStackGenerationRecordInvalid err))
      Right series -> do
        observed <- observeStackGenerationCursor cursors series
        case observed of
          StackGenerationCursorAbsent ->
            pure
              ( Left
                  ( RegisteredStackGenerationSeriesUnopened
                      (stackGenerationSeriesKeyText series)
                  )
              )
          StackGenerationCursorCorrupt detail ->
            pure (Left (RegisteredStackGenerationCorrupt detail))
          StackGenerationCursorUnobservable failure ->
            pure (Left (RegisteredStackGenerationUnobservable failure))
          StackGenerationCursorPresent present ->
            selectAt
              ( stackGenerationKeyForOrdinal
                  series
                  ( stackGenerationCursorOrdinal
                      (observedStackGenerationCursor present)
                  )
              )
   where
    selectAt addressingKey =
      selectRegisteredStackGenerationFromRepository
        generations
        addressingKey
        selectingRunScope
        selectingSurface

-- ---------------------------------------------------------------------------
-- Refusals
-- ---------------------------------------------------------------------------

data RegisteredStackGenerationError
  = RegisteredStackGenerationRecordInvalid !StackGenerationError
  | RegisteredStackGenerationRecordTooLarge !Int !Int
  | RegisteredStackGenerationConflict !StackGenerationKey
  | RegisteredStackGenerationUnavailable !ObservationFailure
  | RegisteredStackGenerationCommitNotApplied !ObservationFailure
  | RegisteredStackGenerationAbsent !StackGenerationKey
  | RegisteredStackGenerationCorrupt !Text
  | RegisteredStackGenerationUnobservable !ObservationFailure
  | RegisteredStackGenerationSlotKeyMismatch
      !StackGenerationKey
      !StackGenerationKey
  | RegisteredStackGenerationNotSelectable !StackGenerationError
  | RegisteredStackGenerationCursorContended !Text
  | -- | The series has no cursor, so no cycle of this registered stack has ever
    -- been reserved.  A cleanup run refuses here rather than inferring a cycle
    -- from whatever residue happens to be visible.
    RegisteredStackGenerationSeriesUnopened !Text
  deriving stock (Eq, Show)

renderRegisteredStackGenerationError
  :: RegisteredStackGenerationError -> Text
renderRegisteredStackGenerationError err = case err of
  RegisteredStackGenerationRecordInvalid detail ->
    renderStackGenerationError detail
  RegisteredStackGenerationRecordTooLarge limit actual ->
    "A registered stack generation record of "
      <> Text.pack (show actual)
      <> " bytes exceeds the bound of "
      <> Text.pack (show limit)
      <> " bytes."
  RegisteredStackGenerationConflict key ->
    "The durable slot for generation `"
      <> stackGenerationKeyText key
      <> "` already holds a different record; a generation is written once."
  RegisteredStackGenerationUnavailable (ObservationFailure detail) ->
    "The registered stack generation store was unavailable: " <> detail <> "."
  RegisteredStackGenerationCommitNotApplied (ObservationFailure detail) ->
    "The registered stack generation commit lost its response ("
      <> detail
      <> ") and an independent read-back observed the slot absent, so nothing \
         \was committed."
  RegisteredStackGenerationAbsent key ->
    "No registered stack generation is retained for `"
      <> stackGenerationKeyText key
      <> "`; cleanup will not infer one from residue."
  RegisteredStackGenerationCorrupt detail ->
    "The retained registered stack generation was corrupt: " <> detail <> "."
  RegisteredStackGenerationUnobservable (ObservationFailure detail) ->
    "The retained registered stack generation was unobservable: "
      <> detail
      <> ". Unobservable is not absence."
  RegisteredStackGenerationSlotKeyMismatch expected actual ->
    "The generation slot addressed by `"
      <> stackGenerationKeyText expected
      <> "` holds a record keyed `"
      <> stackGenerationKeyText actual
      <> "`."
  RegisteredStackGenerationNotSelectable detail ->
    renderStackGenerationError detail
  RegisteredStackGenerationCursorContended series ->
    "The generation cursor for series `"
      <> series
      <> "` did not settle on this run's reservation; another admitted create \
         \holds the current cycle. Re-observe before reserving again."
  RegisteredStackGenerationSeriesUnopened series ->
    "No cycle has ever been reserved for series `"
      <> series
      <> "`, so there is no generation to select. Cleanup refuses rather than \
         \inferring a cycle from visible residue."
