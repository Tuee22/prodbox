{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded server boundary for the Lifecycle Authority's single retained
-- admission aggregate.
--
-- Control transitions and operation submissions use the same exact-revision
-- repository.  Every successful compare-and-swap is treated as provisional and
-- followed by authoritative read-back, so an applied write whose response is
-- lost converges without issuing a second operation.
module Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( -- * Wire payloads
    AuthorityControlPayload (..)
  , AuthorityOperationSubmitPayload (..)
  , AuthorityOperationObservePayload (..)
  , AuthorityOperationFieldError (..)

    -- * Physical state
  , AuthorityAdmissionSnapshot (..)
  , AuthorityAdmissionRepository (..)
  , AuthorityAdmissionCodecError (..)
  , authorityAdmissionMaximumEncodedBytes
  , authorityAdmissionStateCodec
  , authorityAdmissionStateCodecWithRegisteredClients
  , modelBAuthorityAdmissionRepository

    -- * Transition endpoint
  , AuthorityTransitionResult (..)
  , serveAuthorityTransition
  , serveAuthorityTransitionRequest
  , authorityAdmissionMigrationImportApplicator
  , serveAuthorityControlRequest
  , authorityTransitionHttpStatus
  , authorityTransitionSummary

    -- * Operation endpoints
  , AuthorityOperationSubmitResult (..)
  , AuthorityOperationObserveResult (..)
  , AuthorityOperationSubmitResponse (..)
  , AuthorityOperationObserveResponse (..)
  , authorityOperationResponseMaximumBytes
  , serveAuthorityOperationSubmit
  , serveAuthorityOperationSubmitRequest
  , serveAuthorityOperationObserve
  , serveAuthorityOperationObserveRequest
  , authorityOperationSubmitHttpStatus
  , authorityOperationSubmitSummary
  , authorityOperationSubmitResponseBody
  , authorityOperationObserveHttpStatus
  , authorityOperationObserveSummary
  , authorityOperationObserveResponseBody
  , registeredGenerationForSlot
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Either (fromLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , signingKeyGenerationValue
  , verifiedCallerSlotKeyGeneration
  , verifiedCallerSlotPrincipal
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionDecision (..)
  , AuthorityAdmissionInvariantError
  , AuthorityMigrationMode (..)
  , AuthorityRegisteredSubmissionDecision (..)
  , AuthoritySubmissionGateRefusal (..)
  , authorityAggregateMigration
  , decideRegisteredAuthoritySubmission
  , observeRegisteredAuthoritySubmission
  , stepAuthorityAdmission
  , stepRegisteredAuthoritySubmission
  , validateAuthorityAdmissionAggregate
  , validateAuthorityAdmissionAggregateWithRegisteredClients
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupRepairCommand
  , BackupRepairDecision (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , ClientSubmissionKeyError (..)
  , RegisteredClientGeneration
  , RegisteredClientTable
  , RegisteredSubmissionDecision (..)
  , RegisteredSubmissionObservation (..)
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand
  , GenesisDecision (..)
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationDecision (..)
  , MigrationForwardCommand
  , MigrationForwardDecision (..)
  , MigrationImportDecision (..)
  , decideMigrationImport
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationImportApplyResult (..)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( MigrationImportApplicationError (..)
  , MigrationImportCommandApplicator
  , mkMigrationImportCommandApplicator
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (RequestDigest)
  , SubmissionStatus (..)
  , TerminalOutcome (..)
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

-- | The externally admissible control transitions.  Projection-import
-- evidence is deliberately absent: only the Authority's importer may derive
-- and commit it after source and target read-back.  Ordinary migration commands
-- likewise retain their dedicated route and codec.
data AuthorityControlPayload
  = AuthorityControlGenesis !AuthorityGenesisCommand
  | AuthorityControlBackupRepair !BackupRepairCommand
  | AuthorityControlBeginMigration
  | AuthorityControlForwardMigration !MigrationForwardCommand
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityOperationSubmitPayload = AuthorityOperationSubmitPayload
  { authorityOperationSubmitKey :: !Text
  , authorityOperationSubmitDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityOperationObservePayload = AuthorityOperationObservePayload
  { authorityOperationObserveKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityOperationFieldError
  = AuthorityOperationSubmissionKeyEmpty
  | AuthorityOperationSubmissionKeyTooLong
  | AuthorityOperationSubmissionKeyInvalidCharacter
  | AuthorityOperationDigestEmpty
  | AuthorityOperationDigestTooLong
  | AuthorityOperationDigestInvalidCharacter
  deriving stock (Eq, Show)

data AuthorityAdmissionSnapshot revision = AuthorityAdmissionSnapshot
  { authorityAdmissionRevision :: !revision
  , authorityAdmissionSnapshotState :: !AuthorityAdmissionAggregate
  }
  deriving stock (Eq, Show)

data AuthorityAdmissionRepository m revision = AuthorityAdmissionRepository
  { readAuthorityAdmission
      :: m (Either Text (AuthorityAdmissionSnapshot revision))
  , compareAndSwapAuthorityAdmission
      :: revision
      -> AuthorityAdmissionAggregate
      -> m (Either Text ())
  }

data AuthorityAdmissionCodecError
  = AuthorityAdmissionTooLarge !Int !Int
  | AuthorityAdmissionInvalid
  | AuthorityAdmissionUnsupportedVersion !Word16
  | AuthorityAdmissionNonCanonical
  | AuthorityAdmissionInvariant !AuthorityAdmissionInvariantError
  deriving stock (Eq, Show)

data AuthorityAdmissionEnvelope = AuthorityAdmissionEnvelope
  { authorityAdmissionEnvelopeVersion :: !Word16
  , authorityAdmissionEnvelopeState :: !AuthorityAdmissionAggregate
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityAdmissionMaximumEncodedBytes :: Int
authorityAdmissionMaximumEncodedBytes = 512 * 1024

authorityAdmissionCodecVersion :: Word16
authorityAdmissionCodecVersion = 6

authorityAdmissionStateCodec
  :: Int
  -> Natural
  -> Natural
  -> ModelBCodec AuthorityAdmissionAggregate
authorityAdmissionStateCodec maximumBytes expectedLive expectedRetained =
  authorityAdmissionStateCodecFor
    maximumBytes
    expectedLive
    expectedRetained
    Nothing

-- | Production codec with the immutable registered-client definition pinned
-- by runtime configuration.  Reservation cursors evolve inside the retained
-- value, but principals, slots, key generations, and capacities cannot be
-- changed by decoding a different object.
authorityAdmissionStateCodecWithRegisteredClients
  :: Int
  -> Natural
  -> Natural
  -> RegisteredClientTable
  -> ModelBCodec AuthorityAdmissionAggregate
authorityAdmissionStateCodecWithRegisteredClients
  maximumBytes
  expectedLive
  expectedRetained
  expectedRegisteredClients =
    authorityAdmissionStateCodecFor
      maximumBytes
      expectedLive
      expectedRetained
      (Just expectedRegisteredClients)

authorityAdmissionStateCodecFor
  :: Int
  -> Natural
  -> Natural
  -> Maybe RegisteredClientTable
  -> ModelBCodec AuthorityAdmissionAggregate
authorityAdmissionStateCodecFor
  maximumBytes
  expectedLive
  expectedRetained
  expectedRegisteredClients =
    ModelBCodec
      { encodeModelBValue =
          either (Left . show) Right
            . encodeAuthorityAdmission
              maximumBytes
              expectedLive
              expectedRetained
              expectedRegisteredClients
      , decodeModelBValue =
          either (Left . show) Right
            . decodeAuthorityAdmission
              maximumBytes
              expectedLive
              expectedRetained
              expectedRegisteredClients
      }

encodeAuthorityAdmission
  :: Int
  -> Natural
  -> Natural
  -> Maybe RegisteredClientTable
  -> AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionCodecError StrictByteString.ByteString
encodeAuthorityAdmission
  maximumBytes
  expectedLive
  expectedRetained
  expectedRegisteredClients
  aggregate = do
    either
      (Left . AuthorityAdmissionInvariant)
      Right
      ( validateConfiguredAuthorityAdmission
          expectedLive
          expectedRetained
          expectedRegisteredClients
          aggregate
      )
    let bytes =
          LazyByteString.toStrict
            ( serialise
                AuthorityAdmissionEnvelope
                  { authorityAdmissionEnvelopeVersion = authorityAdmissionCodecVersion
                  , authorityAdmissionEnvelopeState = aggregate
                  }
            )
    if maximumBytes < 0 || StrictByteString.length bytes > maximumBytes
      then Left (AuthorityAdmissionTooLarge (StrictByteString.length bytes) maximumBytes)
      else Right bytes

decodeAuthorityAdmission
  :: Int
  -> Natural
  -> Natural
  -> Maybe RegisteredClientTable
  -> StrictByteString.ByteString
  -> Either AuthorityAdmissionCodecError AuthorityAdmissionAggregate
decodeAuthorityAdmission
  maximumBytes
  expectedLive
  expectedRetained
  expectedRegisteredClients
  bytes
    | maximumBytes < 0 || StrictByteString.length bytes > maximumBytes =
        Left (AuthorityAdmissionTooLarge (StrictByteString.length bytes) maximumBytes)
    | otherwise = do
        envelope <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
          Left _ -> Left AuthorityAdmissionInvalid
          Right decoded -> Right decoded
        if authorityAdmissionEnvelopeVersion envelope /= authorityAdmissionCodecVersion
          then
            Left
              ( AuthorityAdmissionUnsupportedVersion
                  (authorityAdmissionEnvelopeVersion envelope)
              )
          else Right ()
        let aggregate = authorityAdmissionEnvelopeState envelope
        either
          (Left . AuthorityAdmissionInvariant)
          Right
          ( validateConfiguredAuthorityAdmission
              expectedLive
              expectedRetained
              expectedRegisteredClients
              aggregate
          )
        if LazyByteString.toStrict (serialise envelope) /= bytes
          then Left AuthorityAdmissionNonCanonical
          else Right aggregate

validateConfiguredAuthorityAdmission
  :: Natural
  -> Natural
  -> Maybe RegisteredClientTable
  -> AuthorityAdmissionAggregate
  -> Either AuthorityAdmissionInvariantError ()
validateConfiguredAuthorityAdmission expectedLive expectedRetained expectedRegistry aggregate =
  case expectedRegistry of
    Nothing ->
      validateAuthorityAdmissionAggregate expectedLive expectedRetained aggregate
    Just registry ->
      validateAuthorityAdmissionAggregateWithRegisteredClients
        expectedLive
        expectedRetained
        registry
        aggregate

-- | Bind the aggregate to one retained Model-B coordinate.  Absence means the
-- explicitly supplied clean-install or migration initializer; corruption and
-- unobservability remain failures rather than being relabelled as absence.
modelBAuthorityAdmissionRepository
  :: (Monad m)
  => AuthorityAdmissionAggregate
  -> ModelBCasAdapter 'ClusterRetained m AuthorityAdmissionAggregate
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AuthorityAdmissionRepository m (Maybe ModelBObjectVersion)
modelBAuthorityAdmissionRepository initial adapter coordinate =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        observation <- modelBObserve adapter coordinate
        pure $ case observation of
          ModelBMissing ->
            Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = Nothing
                , authorityAdmissionSnapshotState = initial
                }
          ModelBObserved revision aggregate ->
            Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = Just revision
                , authorityAdmissionSnapshotState = aggregate
                }
          ModelBCorrupt detail -> Left ("authority admission is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("authority admission is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("authority admission is unobservable: " <> detail)
    , compareAndSwapAuthorityAdmission = \expected aggregate -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate aggregate
            Just revision -> ModelBReplace coordinate revision aggregate
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "authority admission CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("authority admission CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("authority admission CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("authority admission CAS is unobservable: " <> detail)
    }

data AuthorityTransitionResult
  = AuthorityTransitionDecided !AuthorityAdmissionDecision
  | AuthorityTransitionReadFailed !Text
  | AuthorityTransitionWriteFailed !Text
  | AuthorityTransitionBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

serveAuthorityTransition
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> AuthorityAdmissionCommand
  -> m AuthorityTransitionResult
serveAuthorityTransition repository command = do
  observed <- readAuthorityAdmission repository
  case observed of
    Left detail -> pure (AuthorityTransitionReadFailed detail)
    Right snapshot -> do
      let current = authorityAdmissionSnapshotState snapshot
          (decision, next) = stepAuthorityAdmission current command
      if next == current
        then pure (AuthorityTransitionDecided decision)
        else do
          attempted <-
            compareAndSwapAuthorityAdmission
              repository
              (authorityAdmissionRevision snapshot)
              next
          readback <- readAuthorityAdmission repository
          pure $ case readback of
            Left detail ->
              AuthorityTransitionWriteFailed
                ("authority transition readback failed: " <> detail)
            Right confirmed
              | authorityAdmissionSnapshotState confirmed == next ->
                  AuthorityTransitionDecided decision
              | otherwise ->
                  AuthorityTransitionWriteFailed
                    ( fromLeft
                        "authority transition CAS was not confirmed by readback"
                        attempted
                    )

serveAuthorityTransitionRequest
  :: (Monad m)
  => Int
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m AuthorityTransitionResult
serveAuthorityTransitionRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityTransitionBadRequest err)
    Right command -> serveAuthorityTransition repository command

-- | Bind verified projection evidence to the one retained Authority aggregate.
-- The applicator can express only 'ApplyAuthorityMigrationImport'; aggregate
-- admission refusal remains typed, and a successful transition is followed by
-- an authoritative aggregate read-back whose migration projection must replay
-- the exact command as already-applied (or preserve the exact refusal).
authorityAdmissionMigrationImportApplicator
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> MigrationImportCommandApplicator m
authorityAdmissionMigrationImportApplicator repository =
  mkMigrationImportCommandApplicator applyImport
 where
  applyImport command = do
    transitioned <-
      serveAuthorityTransition
        repository
        (ApplyAuthorityMigrationImport command)
    case transitioned of
      AuthorityTransitionReadFailed detail ->
        pure (Left (MigrationImportAuthorityReadFailed detail))
      AuthorityTransitionWriteFailed detail ->
        pure (Left (MigrationImportAuthorityWriteFailed detail))
      AuthorityTransitionBadRequest _ ->
        pure
          ( Left
              ( MigrationImportAuthorityProtocolViolation
                  "typed authority transition unexpectedly reported a request-codec failure"
              )
          )
      AuthorityTransitionDecided decision -> case decision of
        AuthorityMigrationImportDecided importDecision ->
          confirmImportReadback command importDecision
        AuthorityAdmissionCommandRefused refusal ->
          pure (Left (MigrationImportAuthorityRefused refusal))
        _ ->
          pure
            ( Left
                ( MigrationImportAuthorityProtocolViolation
                    "authority returned a non-import decision for an import command"
                )
            )

  confirmImportReadback command importDecision = do
    observed <- readAuthorityAdmission repository
    pure $ case observed of
      Left detail ->
        Left (MigrationImportAuthorityReadbackFailed detail)
      Right snapshot ->
        case authorityAggregateMigration
          (authorityAdmissionSnapshotState snapshot) of
          AuthorityCleanInstall ->
            Left
              ( MigrationImportAuthorityProtocolViolation
                  "authority import readback is not migration-controlled"
              )
          AuthorityMigrationControlled migration ->
            let replayDecision = decideMigrationImport migration command
             in if importReadbackConfirms importDecision replayDecision
                  then
                    Right
                      MigrationImportApplyResult
                        { appliedMigrationImportState = migration
                        , appliedMigrationImportDecision = importDecision
                        }
                  else
                    Left
                      ( MigrationImportAuthorityReadbackDiverged
                          importDecision
                          replayDecision
                      )

importReadbackConfirms
  :: MigrationImportDecision
  -> MigrationImportDecision
  -> Bool
importReadbackConfirms applied replay = case applied of
  MigrationImportAccepted -> replay == MigrationImportAlreadyApplied
  MigrationImportAlreadyApplied -> replay == MigrationImportAlreadyApplied
  MigrationImportRefused refusal ->
    replay == MigrationImportRefused refusal

-- | Decode only the closed externally admissible control vocabulary.  In
-- particular, a caller cannot smuggle a fabricated projection-import receipt
-- through the generic aggregate command codec.
serveAuthorityControlRequest
  :: (Monad m)
  => Int
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m AuthorityTransitionResult
serveAuthorityControlRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityTransitionBadRequest err)
    Right payload ->
      serveAuthorityTransition repository $ case payload of
        AuthorityControlGenesis command -> ApplyAuthorityGenesis command
        AuthorityControlBackupRepair command -> ApplyAuthorityBackupRepair command
        AuthorityControlBeginMigration -> BeginAuthorityMigration
        AuthorityControlForwardMigration command -> ApplyAuthorityForwardMigration command

authorityTransitionHttpStatus :: AuthorityTransitionResult -> Int
authorityTransitionHttpStatus result = case result of
  AuthorityTransitionBadRequest _ -> 400
  AuthorityTransitionReadFailed _ -> 503
  AuthorityTransitionWriteFailed _ -> 503
  AuthorityTransitionDecided decision -> case decision of
    AuthorityGenesisDecided (GenesisRefused _) -> 409
    AuthorityGenesisDecided _ -> 200
    AuthorityBackupRepairDecided (BackupRepairRefused _) -> 409
    AuthorityBackupRepairDecided _ -> 200
    AuthorityMigrationStarted -> 200
    AuthorityMigrationDecided (MigrationRefused _) -> 409
    AuthorityMigrationDecided _ -> 200
    AuthorityMigrationImportDecided (MigrationImportRefused _) -> 409
    AuthorityMigrationImportDecided _ -> 200
    AuthorityForwardMigrationDecided (ForwardMigrationRefused _) -> 409
    AuthorityForwardMigrationDecided _ -> 200
    AuthorityAdmissionCommandRefused _ -> 409

authorityTransitionSummary :: AuthorityTransitionResult -> Text
authorityTransitionSummary result = case result of
  AuthorityTransitionBadRequest err ->
    "authority-transition-bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityTransitionReadFailed _ -> "authority-transition-read-failed"
  AuthorityTransitionWriteFailed _ -> "authority-transition-write-failed"
  AuthorityTransitionDecided decision -> case decision of
    AuthorityGenesisDecided genesis -> case genesis of
      GenesisRefused _ -> "authority-genesis-refused"
      GenesisBeginEstablishment _ -> "authority-genesis-establishment-begun"
      GenesisRecordReceipt _ -> "authority-genesis-receipt-recorded"
      GenesisOpenAdmission _ _ -> "authority-genesis-admission-opened"
    AuthorityBackupRepairDecided repair -> case repair of
      BackupRepairRefused _ -> "authority-backup-repair-refused"
      BackupRepairNotNeeded -> "authority-backup-repair-not-needed"
      BackupRepairFroze _ -> "authority-backup-repair-frozen"
      BackupRepairWait -> "authority-backup-repair-wait"
      BackupRepairPermitMinted _ -> "authority-backup-repair-permit-recorded"
      BackupRepairPermitAlreadyMinted ->
        "authority-backup-repair-permit-already-recorded"
      BackupRepairRecordProgress _ -> "authority-backup-repair-progress-recorded"
      BackupRepairReopen _ _ -> "authority-backup-repair-admission-opened"
    AuthorityMigrationStarted -> "authority-migration-started"
    AuthorityMigrationDecided migration -> case migration of
      MigrationAccepted _ -> "authority-migration-accepted"
      MigrationAlreadyApplied -> "authority-migration-already-applied"
      MigrationRefused _ -> "authority-migration-refused"
    AuthorityMigrationImportDecided imported -> case imported of
      MigrationImportAccepted -> "authority-migration-import-accepted"
      MigrationImportAlreadyApplied -> "authority-migration-import-already-applied"
      MigrationImportRefused _ -> "authority-migration-import-refused"
    AuthorityForwardMigrationDecided forward -> case forward of
      ForwardMigrationAccepted -> "authority-forward-migration-accepted"
      ForwardMigrationAlreadyApplied -> "authority-forward-migration-already-applied"
      ForwardMigrationRefused _ -> "authority-forward-migration-refused"
    AuthorityAdmissionCommandRefused _ -> "authority-transition-refused"

data AuthorityOperationSubmitResult
  = AuthorityOperationSubmitDecided !AuthorityRegisteredSubmissionDecision
  | AuthorityOperationSubmitReadFailed !Text
  | AuthorityOperationSubmitWriteFailed !Text
  | AuthorityOperationSubmitBadRequest !ControlPlaneRequestCodecError
  | AuthorityOperationSubmitInvalidField !AuthorityOperationFieldError
  deriving stock (Eq, Show)

data AuthorityOperationObserveResult
  = AuthorityOperationObserveDecided !RegisteredSubmissionObservation
  | AuthorityOperationObserveReadFailed !Text
  | AuthorityOperationObserveBadRequest !ControlPlaneRequestCodecError
  | AuthorityOperationObserveInvalidField !AuthorityOperationFieldError
  deriving stock (Eq, Show)

-- | Canonical operation-submit response.  A successful response carries the
-- authority-allocated epoch/slot/generation sequence identity; callers never
-- infer or allocate that identity from an HTTP status or diagnostic string.
data AuthorityOperationSubmitResponse
  = AuthorityOperationAccepted !OperationId
  | AuthorityOperationDuplicate !OperationId
  | AuthorityOperationSubmitRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityOperationObserveResponse
  = AuthorityOperationObserved !SubmissionStatus
  | AuthorityOperationUnknown
  | AuthorityOperationObserveRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityOperationResponseMaximumBytes :: Int
authorityOperationResponseMaximumBytes = 64 * 1024

serveAuthorityOperationSubmit
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> VerifiedCallerSlot
  -> ClientSubmissionKey
  -> RequestDigest
  -> m AuthorityOperationSubmitResult
serveAuthorityOperationSubmit repository callerSlot submissionKey digest =
  case registeredGenerationForSlot callerSlot of
    Left detail -> pure (AuthorityOperationSubmitReadFailed detail)
    Right generation -> do
      observed <- readAuthorityAdmission repository
      case observed of
        Left detail -> pure (AuthorityOperationSubmitReadFailed detail)
        Right snapshot ->
          case stepRegisteredAuthoritySubmission
            (authorityAdmissionSnapshotState snapshot)
            (verifiedCallerSlotPrincipal callerSlot)
            generation
            submissionKey
            digest of
            Left invariant ->
              pure
                ( AuthorityOperationSubmitReadFailed
                    ("authority admission invariant failed: " <> Text.pack (show invariant))
                )
            Right (decision, next)
              | next == authorityAdmissionSnapshotState snapshot ->
                  pure (AuthorityOperationSubmitDecided decision)
              | otherwise -> do
                  attempted <-
                    compareAndSwapAuthorityAdmission
                      repository
                      (authorityAdmissionRevision snapshot)
                      next
                  confirmAuthoritySubmission
                    repository
                    attempted
                    decision
                    callerSlot
                    submissionKey
                    digest

confirmAuthoritySubmission
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> Either Text ()
  -> AuthorityRegisteredSubmissionDecision
  -> VerifiedCallerSlot
  -> ClientSubmissionKey
  -> RequestDigest
  -> m AuthorityOperationSubmitResult
confirmAuthoritySubmission
  repository
  attempted
  decision
  callerSlot
  submissionKey
  digest =
    case acceptedOperation decision of
      Nothing ->
        pure
          ( AuthorityOperationSubmitWriteFailed
              "authority submission state changed without an accepted operation"
          )
      Just accepted ->
        case registeredGenerationForSlot callerSlot of
          Left detail -> pure (AuthorityOperationSubmitWriteFailed detail)
          Right generation -> do
            readback <- readAuthorityAdmission repository
            pure $ case readback of
              Left detail ->
                AuthorityOperationSubmitWriteFailed
                  ("authority submission readback failed: " <> detail)
              Right snapshot ->
                case decideRegisteredAuthoritySubmission
                  (authorityAdmissionSnapshotState snapshot)
                  (verifiedCallerSlotPrincipal callerSlot)
                  generation
                  submissionKey
                  digest of
                  Right
                    ( AuthorityRegisteredSubmissionDecided
                        (RegisteredSubmissionDuplicate duplicate)
                      )
                      | duplicate == accepted -> AuthorityOperationSubmitDecided decision
                  _ ->
                    AuthorityOperationSubmitWriteFailed
                      ( fromLeft
                          "authority submission CAS was not confirmed by readback"
                          attempted
                      )

acceptedOperation :: AuthorityRegisteredSubmissionDecision -> Maybe OperationId
acceptedOperation decision = case decision of
  AuthorityRegisteredSubmissionDecided (RegisteredSubmissionAccepted operationId) ->
    Just operationId
  _ -> Nothing

serveAuthorityOperationSubmitRequest
  :: (Monad m)
  => Int
  -> AuthorityAdmissionRepository m revision
  -> VerifiedCallerSlot
  -> ByteString
  -> m AuthorityOperationSubmitResult
serveAuthorityOperationSubmitRequest maximumBytes repository callerSlot body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityOperationSubmitBadRequest err)
    Right payload -> case validateSubmitPayload payload of
      Left err -> pure (AuthorityOperationSubmitInvalidField err)
      Right (submissionKey, digest) ->
        serveAuthorityOperationSubmit repository callerSlot submissionKey digest

serveAuthorityOperationObserve
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> VerifiedCallerSlot
  -> ClientSubmissionKey
  -> m AuthorityOperationObserveResult
serveAuthorityOperationObserve repository callerSlot submissionKey =
  case registeredGenerationForSlot callerSlot of
    Left detail -> pure (AuthorityOperationObserveReadFailed detail)
    Right generation -> do
      observed <- readAuthorityAdmission repository
      pure $ case observed of
        Left detail -> AuthorityOperationObserveReadFailed detail
        Right snapshot ->
          case observeRegisteredAuthoritySubmission
            (authorityAdmissionSnapshotState snapshot)
            (verifiedCallerSlotPrincipal callerSlot)
            generation
            submissionKey of
            Left invariant ->
              AuthorityOperationObserveReadFailed
                ("authority admission invariant failed: " <> Text.pack (show invariant))
            Right decision -> AuthorityOperationObserveDecided decision

serveAuthorityOperationObserveRequest
  :: (Monad m)
  => Int
  -> AuthorityAdmissionRepository m revision
  -> VerifiedCallerSlot
  -> ByteString
  -> m AuthorityOperationObserveResult
serveAuthorityOperationObserveRequest maximumBytes repository callerSlot body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (AuthorityOperationObserveBadRequest err)
    Right payload -> case validateObservePayload payload of
      Left err -> pure (AuthorityOperationObserveInvalidField err)
      Right submissionKey ->
        serveAuthorityOperationObserve repository callerSlot submissionKey

validateSubmitPayload
  :: AuthorityOperationSubmitPayload
  -> Either
       AuthorityOperationFieldError
       (ClientSubmissionKey, RequestDigest)
validateSubmitPayload payload = do
  submissionKey <- validateSubmissionKey (authorityOperationSubmitKey payload)
  digest <- validateDigest (authorityOperationSubmitDigest payload)
  Right (submissionKey, digest)

validateObservePayload
  :: AuthorityOperationObservePayload
  -> Either AuthorityOperationFieldError ClientSubmissionKey
validateObservePayload = validateSubmissionKey . authorityOperationObserveKey

validateSubmissionKey
  :: Text -> Either AuthorityOperationFieldError ClientSubmissionKey
validateSubmissionKey value =
  case mkClientSubmissionKey value of
    Left ClientSubmissionKeyEmpty -> Left AuthorityOperationSubmissionKeyEmpty
    Left ClientSubmissionKeyTooLong {} -> Left AuthorityOperationSubmissionKeyTooLong
    Left ClientSubmissionKeyInvalidCharacter ->
      Left AuthorityOperationSubmissionKeyInvalidCharacter
    Right submissionKey -> Right submissionKey

validateDigest :: Text -> Either AuthorityOperationFieldError RequestDigest
validateDigest value
  | Text.null value = Left AuthorityOperationDigestEmpty
  | Text.length value > 128 = Left AuthorityOperationDigestTooLong
  | Text.any invalidCharacter value = Left AuthorityOperationDigestInvalidCharacter
  | otherwise = Right (RequestDigest value)

invalidCharacter :: Char -> Bool
invalidCharacter character = isControl character || isSpace character

registeredGenerationForSlot
  :: VerifiedCallerSlot -> Either Text RegisteredClientGeneration
registeredGenerationForSlot callerSlot =
  case mkRegisteredClientGeneration
    ( signingKeyGenerationValue
        (verifiedCallerSlotKeyGeneration callerSlot)
    ) of
    Left _ -> Left "verified caller slot contains an invalid signing-key generation"
    Right generation -> Right generation

authorityOperationSubmitHttpStatus :: AuthorityOperationSubmitResult -> Int
authorityOperationSubmitHttpStatus result = case result of
  AuthorityOperationSubmitBadRequest _ -> 400
  AuthorityOperationSubmitInvalidField _ -> 400
  AuthorityOperationSubmitReadFailed _ -> 503
  AuthorityOperationSubmitWriteFailed _ -> 503
  AuthorityOperationSubmitDecided decision -> case decision of
    AuthorityRegisteredSubmissionRefusedByGate _ -> 503
    AuthorityRegisteredSubmissionRefusedRetainedCapacity -> 503
    AuthorityRegisteredSubmissionDecided submitted -> case submitted of
      RegisteredSubmissionAccepted _ -> 200
      RegisteredSubmissionDuplicate _ -> 200
      RegisteredSubmissionRefusedUnregistered -> 403
      RegisteredSubmissionRefusedGenerationMismatch {} -> 403
      RegisteredSubmissionRefusedReservationCapacity -> 503
      RegisteredSubmissionRefusedDigestConflict -> 409
      RegisteredSubmissionRefusedGlobalCapacity -> 503
      RegisteredSubmissionRefusedExpired -> 409
      RegisteredSubmissionRefusedLedgerDiverged -> 503

authorityOperationSubmitSummary :: AuthorityOperationSubmitResult -> Text
authorityOperationSubmitSummary result = case result of
  AuthorityOperationSubmitBadRequest err ->
    "authority-operation-submit-bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityOperationSubmitInvalidField _ -> "authority-operation-submit-invalid-field"
  AuthorityOperationSubmitReadFailed _ -> "authority-operation-submit-read-failed"
  AuthorityOperationSubmitWriteFailed _ -> "authority-operation-submit-write-failed"
  AuthorityOperationSubmitDecided decision -> case decision of
    AuthorityRegisteredSubmissionRefusedByGate refusal -> gateSummary refusal
    AuthorityRegisteredSubmissionRefusedRetainedCapacity ->
      "authority-operation-refused-retained-capacity"
    AuthorityRegisteredSubmissionDecided submitted -> case submitted of
      RegisteredSubmissionAccepted _ -> "authority-operation-accepted"
      RegisteredSubmissionDuplicate _ -> "authority-operation-duplicate"
      RegisteredSubmissionRefusedUnregistered ->
        "authority-operation-refused-unregistered"
      RegisteredSubmissionRefusedGenerationMismatch {} ->
        "authority-operation-refused-generation-mismatch"
      RegisteredSubmissionRefusedReservationCapacity ->
        "authority-operation-refused-client-capacity"
      RegisteredSubmissionRefusedDigestConflict ->
        "authority-operation-refused-digest-conflict"
      RegisteredSubmissionRefusedGlobalCapacity ->
        "authority-operation-refused-full"
      RegisteredSubmissionRefusedExpired ->
        "authority-operation-refused-expired"
      RegisteredSubmissionRefusedLedgerDiverged ->
        "authority-operation-refused-ledger-diverged"
 where
  gateSummary refusal = case refusal of
    AuthorityGenesisFrozen -> "authority-operation-refused-genesis-frozen"
    AuthorityGenesisEstablishing ->
      "authority-operation-refused-genesis-establishing"
    AuthorityBackupRepairFrozen ->
      "authority-operation-refused-backup-repair-frozen"
    AuthorityDecommissionAdmissionFrozen ->
      "authority-operation-refused-decommission-frozen"
    AuthorityDecommissionPermanentlyStopped ->
      "authority-operation-refused-decommission-stopped"
    AuthorityLegacyWriterActive ->
      "authority-operation-refused-legacy-writer-active"
    AuthorityMigrationWritersQuiesced ->
      "authority-operation-refused-migration-writers-quiesced"

authorityOperationSubmitResponseBody
  :: AuthorityOperationSubmitResult -> StrictByteString.ByteString
authorityOperationSubmitResponseBody =
  LazyByteString.toStrict
    . encodeControlPlaneResponse
    . submitResponse
 where
  submitResponse result = case result of
    AuthorityOperationSubmitDecided
      ( AuthorityRegisteredSubmissionDecided
          (RegisteredSubmissionAccepted operation)
        ) -> AuthorityOperationAccepted operation
    AuthorityOperationSubmitDecided
      ( AuthorityRegisteredSubmissionDecided
          (RegisteredSubmissionDuplicate operation)
        ) -> AuthorityOperationDuplicate operation
    _ -> AuthorityOperationSubmitRefused (authorityOperationSubmitSummary result)

authorityOperationObserveHttpStatus :: AuthorityOperationObserveResult -> Int
authorityOperationObserveHttpStatus result = case result of
  AuthorityOperationObserveBadRequest _ -> 400
  AuthorityOperationObserveInvalidField _ -> 400
  AuthorityOperationObserveReadFailed _ -> 503
  AuthorityOperationObserveDecided decision -> case decision of
    RegisteredSubmissionObserved _ -> 200
    RegisteredSubmissionUnknown -> 404
    RegisteredSubmissionObserveRefusedUnregistered -> 403
    RegisteredSubmissionObserveRefusedGenerationMismatch {} -> 403
    RegisteredSubmissionObserveDiverged -> 503

authorityOperationObserveSummary :: AuthorityOperationObserveResult -> Text
authorityOperationObserveSummary result = case result of
  AuthorityOperationObserveBadRequest err ->
    "authority-operation-observe-bad-request:" <> controlPlaneRequestCodecToken err
  AuthorityOperationObserveInvalidField _ -> "authority-operation-observe-invalid-field"
  AuthorityOperationObserveReadFailed _ -> "authority-operation-observe-read-failed"
  AuthorityOperationObserveDecided decision -> case decision of
    RegisteredSubmissionUnknown -> "authority-operation-unknown"
    RegisteredSubmissionObserveRefusedUnregistered ->
      "authority-operation-observe-refused-unregistered"
    RegisteredSubmissionObserveRefusedGenerationMismatch {} ->
      "authority-operation-observe-refused-generation-mismatch"
    RegisteredSubmissionObserveDiverged ->
      "authority-operation-observe-ledger-diverged"
    RegisteredSubmissionObserved status -> case status of
      StatusUnknown -> "authority-operation-observe-ledger-diverged"
      StatusInFlight -> "authority-operation-in-flight"
      StatusSettled OperationCompletedOutcome ->
        "authority-operation-settled-completed"
      StatusSettled OperationCancelledOutcome ->
        "authority-operation-settled-cancelled"
      StatusExpired -> "authority-operation-expired"

authorityOperationObserveResponseBody
  :: AuthorityOperationObserveResult -> StrictByteString.ByteString
authorityOperationObserveResponseBody =
  LazyByteString.toStrict
    . encodeControlPlaneResponse
    . observeResponse
 where
  observeResponse result = case result of
    AuthorityOperationObserveDecided (RegisteredSubmissionObserved status) ->
      AuthorityOperationObserved status
    AuthorityOperationObserveDecided RegisteredSubmissionUnknown ->
      AuthorityOperationUnknown
    _ -> AuthorityOperationObserveRefused (authorityOperationObserveSummary result)
