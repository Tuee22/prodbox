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
  , authorityControlPayloadRoute
  , authorityControlPayloadCommand
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
import Data.Map.Strict (Map)
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
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityAdmissionDecision (..)
  , AuthorityAdmissionInvariantError
  , AuthorityControlRoute (..)
  , AuthorityDecommissionState
  , AuthorityMigrationMode (..)
  , AuthorityProviderOperation
  , AuthorityRegisteredSubmissionDecision (..)
  , AuthoritySubmissionGateRefusal (..)
  , authorityAggregateAdmission
  , authorityAggregateConfig
  , authorityAggregateDecommission
  , authorityAggregateMigration
  , authorityAggregateProviderOperations
  , authorityAggregatePulumiCheckpoints
  , authorityAggregateRegisteredClients
  , authorityAggregateRetainedCapacity
  , authorityAggregateSubmissionEpochBindings
  , authorityAggregateSubmissionLedger
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
import Prodbox.Lifecycle.Authority.Config (ConfigState)
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState
  , AuthorityEpoch
  , AuthorityGenesisCommand
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
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , CascadeTerminalAuditReceipt
  , ProviderCredentialRevocationReceipt
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( AuthorityPulumiCheckpoints
  )
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId
  , ClientSequence
  , OperationId
  , RequestDigest (RequestDigest)
  , SubmissionLedger
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
  | -- | Sprint 4.85: bind the serving Lifecycle-provider generation. Appended
    -- so every earlier constructor keeps its @Serialise@ index and no
    -- historical request re-decodes as a different payload.
    AuthorityControlBindProviderGeneration !Natural
  | -- | Sprint 4.85: fence fresh Provider submissions and reserve the terminal
    -- audit's own submission. This is the route whose absence
    -- @GlobalProviderAdmissionFreezeUnavailable@ named: the transition and the
    -- reservation-honouring gate landed first, and until this constructor
    -- existed no authenticated caller could reach either.
    AuthorityControlFreezeProviderAdmissionForCascadeAudit
      !CascadeAuditFreezeBinding
  | -- | Sprint 7.36: make the terminal audit's verdict durable against the
    -- reservation that admitted it. Appended for the same reason as the two
    -- constructors above: every earlier one keeps its @Serialise@ index.
    AuthorityControlRecordCascadeTerminalAuditReceipt
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
  | -- | Sprint 7.36: end the cascade's Provider credential. Appended for the
    -- same reason as every constructor above it.
    AuthorityControlRevokeCascadeProviderCredential
      !CascadeAuditFreezeBinding
      !ProviderCredentialRevocationReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Total projection onto the closed route vocabulary the Authority owns.
--
-- Sprint 4.85: the wire payload and the command it issues used to be related
-- only inside 'serveAuthorityControlRequest', where nothing could read the
-- relation. Both projections below are total over the payload, so a route that
-- stops existing is an exhaustiveness failure here and a measurement change in
-- the operational-credential disposition join.
authorityControlPayloadRoute :: AuthorityControlPayload -> AuthorityControlRoute
authorityControlPayloadRoute payload = case payload of
  AuthorityControlGenesis _ -> AuthorityControlGenesisRoute
  AuthorityControlBackupRepair _ -> AuthorityControlBackupRepairRoute
  AuthorityControlBeginMigration -> AuthorityControlBeginMigrationRoute
  AuthorityControlForwardMigration _ -> AuthorityControlForwardMigrationRoute
  AuthorityControlBindProviderGeneration _ ->
    AuthorityControlProviderGenerationBindingRoute
  AuthorityControlFreezeProviderAdmissionForCascadeAudit _ ->
    AuthorityControlCascadeAuditFreezeRoute
  AuthorityControlRecordCascadeTerminalAuditReceipt _ _ ->
    AuthorityControlCascadeAuditReceiptRoute
  AuthorityControlRevokeCascadeProviderCredential _ _ ->
    AuthorityControlCascadeCredentialRevokeRoute

-- | The aggregate command one externally admissible payload issues.
authorityControlPayloadCommand
  :: AuthorityControlPayload -> AuthorityAdmissionCommand
authorityControlPayloadCommand payload = case payload of
  AuthorityControlGenesis command -> ApplyAuthorityGenesis command
  AuthorityControlBackupRepair command -> ApplyAuthorityBackupRepair command
  AuthorityControlBeginMigration -> BeginAuthorityMigration
  AuthorityControlForwardMigration command ->
    ApplyAuthorityForwardMigration command
  AuthorityControlBindProviderGeneration generation ->
    BindProviderAdmissionGeneration generation
  AuthorityControlFreezeProviderAdmissionForCascadeAudit binding ->
    FreezeProviderAdmissionForCascadeAudit binding
  AuthorityControlRecordCascadeTerminalAuditReceipt binding receipt ->
    RecordCascadeTerminalAuditReceipt binding receipt
  AuthorityControlRevokeCascadeProviderCredential binding revocation ->
    RevokeCascadeProviderCredential binding revocation

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

-- Exact pre-epoch wire shape.  Field order is the old aggregate order; the
-- constructor tag emitted by generic 'Serialise' is therefore byte-identical
-- to retained v6 objects.  It is decode-migration scaffolding only and never
-- becomes a second mutable domain type.
data AuthorityAdmissionAggregateV6Wire = AuthorityAdmissionAggregateV6Wire
  { authorityAdmissionV6Admission :: !AuthorityAdmissionState
  , authorityAdmissionV6Migration :: !AuthorityMigrationMode
  , authorityAdmissionV6SubmissionLedger :: !SubmissionLedger
  , authorityAdmissionV6RetainedCapacity :: !Natural
  , authorityAdmissionV6SubmissionEpochs
      :: !(Map (ClientId, ClientSequence) AuthorityEpoch)
  , authorityAdmissionV6ProviderOperations
      :: !(Map (ClientId, ClientSequence) AuthorityProviderOperation)
  , authorityAdmissionV6RegisteredClients :: !RegisteredClientTable
  , -- Sprint 4.89: the checkpoint aggregate gained a disposition map, encoded
    -- only when non-empty.  A v6 object predates dispositions and decodes with
    -- none, so it re-encodes byte-identically here; a v6 object that somehow
    -- carried one would re-encode wider and be refused as non-canonical, which
    -- is the right answer rather than silently dropping it.
    authorityAdmissionV6PulumiCheckpoints :: !AuthorityPulumiCheckpoints
  , authorityAdmissionV6Config :: !ConfigState
  , authorityAdmissionV6Decommission :: !AuthorityDecommissionState
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityAdmissionEnvelopeV6 = AuthorityAdmissionEnvelopeV6
  { authorityAdmissionEnvelopeV6Version :: !Word16
  , authorityAdmissionEnvelopeV6State :: !AuthorityAdmissionAggregateV6Wire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityAdmissionMaximumEncodedBytes :: Int
authorityAdmissionMaximumEncodedBytes = 512 * 1024

authorityAdmissionCodecVersion :: Word16
authorityAdmissionCodecVersion = 7

authorityAdmissionLegacyCodecVersion :: Word16
authorityAdmissionLegacyCodecVersion = 6

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
        case authorityAdmissionEnvelopeVersion envelope of
          version
            | version == authorityAdmissionCodecVersion -> Right ()
            | version == authorityAdmissionLegacyCodecVersion -> Right ()
            | otherwise ->
                Left (AuthorityAdmissionUnsupportedVersion version)
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
        if canonicalAuthorityAdmissionEnvelope envelope /= bytes
          then Left AuthorityAdmissionNonCanonical
          else Right aggregate

canonicalAuthorityAdmissionEnvelope
  :: AuthorityAdmissionEnvelope -> StrictByteString.ByteString
canonicalAuthorityAdmissionEnvelope envelope
  | authorityAdmissionEnvelopeVersion envelope
      == authorityAdmissionLegacyCodecVersion =
      LazyByteString.toStrict
        ( serialise
            AuthorityAdmissionEnvelopeV6
              { authorityAdmissionEnvelopeV6Version =
                  authorityAdmissionLegacyCodecVersion
              , authorityAdmissionEnvelopeV6State =
                  authorityAdmissionAggregateV6Wire
                    (authorityAdmissionEnvelopeState envelope)
              }
        )
  | otherwise = LazyByteString.toStrict (serialise envelope)

authorityAdmissionAggregateV6Wire
  :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregateV6Wire
authorityAdmissionAggregateV6Wire aggregate =
  AuthorityAdmissionAggregateV6Wire
    { authorityAdmissionV6Admission = authorityAggregateAdmission aggregate
    , authorityAdmissionV6Migration = authorityAggregateMigration aggregate
    , authorityAdmissionV6SubmissionLedger =
        authorityAggregateSubmissionLedger aggregate
    , authorityAdmissionV6RetainedCapacity =
        authorityAggregateRetainedCapacity aggregate
    , authorityAdmissionV6SubmissionEpochs =
        authorityAggregateSubmissionEpochBindings aggregate
    , authorityAdmissionV6ProviderOperations =
        authorityAggregateProviderOperations aggregate
    , authorityAdmissionV6RegisteredClients =
        authorityAggregateRegisteredClients aggregate
    , authorityAdmissionV6PulumiCheckpoints =
        authorityAggregatePulumiCheckpoints aggregate
    , authorityAdmissionV6Config = authorityAggregateConfig aggregate
    , authorityAdmissionV6Decommission =
        authorityAggregateDecommission aggregate
    }

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
      serveAuthorityTransition repository (authorityControlPayloadCommand payload)

authorityTransitionHttpStatus :: AuthorityTransitionResult -> ReplyStatus
authorityTransitionHttpStatus result = case result of
  AuthorityTransitionBadRequest _ -> ReplyBadRequest
  AuthorityTransitionReadFailed _ -> ReplyServiceUnavailable
  AuthorityTransitionWriteFailed _ -> ReplyServiceUnavailable
  AuthorityTransitionDecided decision -> case decision of
    AuthorityGenesisDecided (GenesisRefused _) -> ReplyConflict
    AuthorityGenesisDecided _ -> ReplyOk
    AuthorityBackupRepairDecided (BackupRepairRefused _) -> ReplyConflict
    AuthorityBackupRepairDecided _ -> ReplyOk
    AuthorityMigrationStarted -> ReplyOk
    AuthorityMigrationDecided (MigrationRefused _) -> ReplyConflict
    AuthorityMigrationDecided _ -> ReplyOk
    AuthorityMigrationImportDecided (MigrationImportRefused _) -> ReplyConflict
    AuthorityMigrationImportDecided _ -> ReplyOk
    AuthorityForwardMigrationDecided (ForwardMigrationRefused _) -> ReplyConflict
    AuthorityForwardMigrationDecided _ -> ReplyOk
    AuthorityProviderGenerationBound _ -> ReplyOk
    AuthorityProviderAdmissionFrozenForCascadeAudit -> ReplyOk
    AuthorityCascadeTerminalAuditReceiptRecorded -> ReplyOk
    AuthorityCascadeProviderCredentialRevoked -> ReplyOk
    AuthorityAdmissionCommandRefused _ -> ReplyConflict

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
    AuthorityProviderGenerationBound _ -> "authority-provider-generation-bound"
    AuthorityProviderAdmissionFrozenForCascadeAudit ->
      "authority-provider-admission-frozen-for-cascade-audit"
    AuthorityCascadeTerminalAuditReceiptRecorded ->
      "authority-cascade-terminal-audit-receipt-recorded"
    AuthorityCascadeProviderCredentialRevoked ->
      "authority-cascade-provider-credential-revoked"
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
  = AuthorityOperationObserved !OperationId !SubmissionStatus
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

authorityOperationSubmitHttpStatus :: AuthorityOperationSubmitResult -> ReplyStatus
authorityOperationSubmitHttpStatus result = case result of
  AuthorityOperationSubmitBadRequest _ -> ReplyBadRequest
  AuthorityOperationSubmitInvalidField _ -> ReplyBadRequest
  AuthorityOperationSubmitReadFailed _ -> ReplyServiceUnavailable
  AuthorityOperationSubmitWriteFailed _ -> ReplyServiceUnavailable
  AuthorityOperationSubmitDecided decision -> case decision of
    AuthorityRegisteredSubmissionRefusedByGate _ -> ReplyServiceUnavailable
    AuthorityRegisteredSubmissionRefusedRetainedCapacity -> ReplyServiceUnavailable
    AuthorityRegisteredSubmissionDecided submitted -> case submitted of
      RegisteredSubmissionAccepted _ -> ReplyOk
      RegisteredSubmissionDuplicate _ -> ReplyOk
      RegisteredSubmissionRefusedUnregistered -> ReplyForbidden
      RegisteredSubmissionRefusedGenerationMismatch {} -> ReplyForbidden
      RegisteredSubmissionRefusedReservationCapacity -> ReplyServiceUnavailable
      RegisteredSubmissionRefusedDigestConflict -> ReplyConflict
      RegisteredSubmissionRefusedGlobalCapacity -> ReplyServiceUnavailable
      RegisteredSubmissionRefusedExpired -> ReplyConflict
      RegisteredSubmissionRefusedLedgerDiverged -> ReplyServiceUnavailable

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
    AuthorityProviderAdmissionCascadeFrozen ->
      "authority-operation-refused-provider-cascade-audit-frozen"
    AuthorityProviderAdmissionCredentialRevoked ->
      "authority-operation-refused-provider-credential-revoked"

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

authorityOperationObserveHttpStatus :: AuthorityOperationObserveResult -> ReplyStatus
authorityOperationObserveHttpStatus result = case result of
  AuthorityOperationObserveBadRequest _ -> ReplyBadRequest
  AuthorityOperationObserveInvalidField _ -> ReplyBadRequest
  AuthorityOperationObserveReadFailed _ -> ReplyServiceUnavailable
  AuthorityOperationObserveDecided decision -> case decision of
    RegisteredSubmissionObserved _ _ -> ReplyOk
    RegisteredSubmissionUnknown -> ReplyNotFound
    RegisteredSubmissionObserveRefusedUnregistered -> ReplyForbidden
    RegisteredSubmissionObserveRefusedGenerationMismatch {} -> ReplyForbidden
    RegisteredSubmissionObserveDiverged -> ReplyServiceUnavailable

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
    RegisteredSubmissionObserved _ status -> case status of
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
    AuthorityOperationObserveDecided (RegisteredSubmissionObserved operation status) ->
      AuthorityOperationObserved operation status
    AuthorityOperationObserveDecided RegisteredSubmissionUnknown ->
      AuthorityOperationUnknown
    _ -> AuthorityOperationObserveRefused (authorityOperationObserveSummary result)
