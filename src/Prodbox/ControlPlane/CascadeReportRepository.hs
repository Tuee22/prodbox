{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the Authority's retained namespace for one cascade run's
-- pre-uninstall report identity and its one-shot local-completion permit.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- puts two authority-bearing actions on the writing side of Stage C: the
-- Authority commits the complete pre-uninstall cleanup report, and it signs the
-- one-shot local-completion permit.  Neither existed as a durable surface, so
-- the commit boundary "Prodbox.Lifecycle.Teardown.PreUninstallReadiness"
-- declares had nothing to be wired to.
--
-- Four properties carry the design.
--
--   * __One run, one slot, and no replace arm.__  Both slots are keyed by the
--     'CleanupRunId' alone and the only write this repository can issue is into
--     an empty slot.  That is what makes the permit one-shot: a second and
--     different permit under one run is a conflict rather than a second key,
--     because two permits would be two licences to destroy the same host.  It
--     is the same shape "Prodbox.ControlPlane.HostCleanupReadinessRepository"
--     applies to the accepted readiness, for the same reason.
--
--   * __An exact replay is a success.__  A rerun that commits the report it
--     already committed, or asks for the permit it was already granted, is what
--     a resumable cascade does after a lost response.  Only a /different/ value
--     under the same run is refused.
--
--   * __The durable record states only what the compiled run cannot.__  The
--     report commitment holds the run and the report digest; the permit holds
--     the grant's own fields.  Scope and graph digest are re-derived from the
--     compiled program by the caller rather than stored here, so the durable
--     bytes and the running cascade have nothing to disagree about — unlike the
--     durable readiness binding, which must restore a proof from bytes alone
--     while the Authority is absent and therefore has to carry them.
--
--   * __A lost response is not a refusal.__  A compare-and-swap whose result
--     could not be observed leaves a write that may have landed, and reporting
--     it as a refusal would let the run conclude the opposite of what may be
--     durable.  It is reported as its own disposition and resolved by the next
--     observation.
--
-- What this module does not own: replicating the report bytes into the
-- independent Backup Adapter, which is
-- "Prodbox.ControlPlane.CleanupReportBackupClient"; reading them back, which is
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportBackup"; and the composition of
-- the two into the Stage-C boundaries, which is
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportCommit".
module Prodbox.ControlPlane.CascadeReportRepository
  ( -- * The Authority client
    CascadeReportAuthorityClient
  , modelBCascadeReportRepository
  , cascadeReportAuthorityLogicalName
  , cascadeCompletionPermitAuthorityLogicalName

    -- * Committing the report identity
  , CascadeReportSlotResult (..)
  , renderCascadeReportSlotResult
  , commitCascadeReportAttempt

    -- * Granting the one-shot permit
  , grantLocalCompletionPermitAttempt

    -- * Reading either slot back
  , CascadeReportRepositoryError (..)
  , renderCascadeReportRepositoryError
  , observeCommittedCascadeReport
  , observeGrantedLocalCompletionPermit
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , CleanupRunId
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeLocalOperationReferences (..)
  , CascadeReportDigest
  , cascadeReportDigestText
  , mkCascadeReportDigest
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (ObservationFailure))

-- ---------------------------------------------------------------------------
-- The Authority client
-- ---------------------------------------------------------------------------

-- | The Authority's retained cascade-report namespace.
--
-- The adapter is indexed @'ClusterRetained'@, so a composition that tried to
-- carry a report identity or a destroy permit over a chart-scoped transport is
-- a type error rather than a run that loses its permit with the cluster.
data CascadeReportAuthorityClient m
  = CascadeReportAuthorityClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString)

modelBCascadeReportRepository
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> CascadeReportAuthorityClient m
modelBCascadeReportRepository = CascadeReportAuthorityClient

-- | One run, one report slot.
--
-- The run id is framed by its own length before hashing, so no two distinct
-- run ids can produce the same name by concatenation.
cascadeReportAuthorityLogicalName :: CleanupRunId -> Text
cascadeReportAuthorityLogicalName =
  slotName "authority/cascade-pre-uninstall-report/" "cascade-pre-uninstall-report-identity/v1"

-- | One run, one permit slot, and it is a different slot from the report.
--
-- Committing a report identity and licensing a destructive local uninstall are
-- separate acts, and folding them into one slot would make the second
-- unconditional on the first having been observed.
cascadeCompletionPermitAuthorityLogicalName :: CleanupRunId -> Text
cascadeCompletionPermitAuthorityLogicalName =
  slotName "authority/cascade-local-completion-permit/" "cascade-local-completion-permit-identity/v1"

slotName :: Text -> Text -> CleanupRunId -> Text
slotName prefix domain runId =
  prefix
    <> TextEncoding.decodeUtf8
      ( hexSha256
          (TextEncoding.encodeUtf8 (Text.concat (map frame [domain, cleanupRunIdText runId])))
      )
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

-- ---------------------------------------------------------------------------
-- Durable payloads
-- ---------------------------------------------------------------------------

data DurableCascadeReportEnvelope = DurableCascadeReportEnvelope
  { durableCascadeReportVersion :: !Word16
  , durableCascadeReportRunId :: !Text
  , durableCascadeReportDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data DurableCompletionPermitEnvelope = DurableCompletionPermitEnvelope
  { durableCompletionPermitVersion :: !Word16
  , durableCompletionPermitId :: !Text
  , durableCompletionPermitRunId :: !Text
  , durableCompletionPermitReportDigest :: !Text
  , durableCompletionPermitUninstallOperation :: !Text
  , durableCompletionPermitCompletionOperation :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cascadeReportSlotVersion :: Word16
cascadeReportSlotVersion = 1

-- | Both slots are small records of identities.  The bound exists so a
-- corrupted or foreign object cannot be decoded at all rather than to leave
-- room for growth.
maximumCascadeReportSlotBytes :: Int
maximumCascadeReportSlotBytes = 4 * 1024

-- ---------------------------------------------------------------------------
-- Slot results
-- ---------------------------------------------------------------------------

-- | What one write attempt did.
--
-- @ExactReplay@ is a success: the same run committing the same identity twice
-- is the rerun this protocol is built for.  @Conflict@ is not, because a second
-- and different identity under one run would mean the Authority holds two
-- answers for one question.
data CascadeReportSlotResult
  = CascadeReportSlotWritten
  | CascadeReportSlotExactReplay
  | CascadeReportSlotConflict
  | CascadeReportSlotResponseLost !ObservationFailure
  | CascadeReportSlotUnavailable !ObservationFailure
  deriving stock (Eq, Show)

renderCascadeReportSlotResult :: CascadeReportSlotResult -> Text
renderCascadeReportSlotResult = \case
  CascadeReportSlotWritten -> "the Authority recorded it"
  CascadeReportSlotExactReplay -> "the Authority already held exactly it"
  CascadeReportSlotConflict ->
    "the Authority already holds a different value for this run"
  CascadeReportSlotResponseLost (ObservationFailure detail) ->
    "the write may have landed and its result was not observed: " <> detail
  CascadeReportSlotUnavailable (ObservationFailure detail) ->
    "the Authority slot was unavailable: " <> detail

data CascadeReportRepositoryError
  = CascadeReportCoordinateInvalid !Text
  | CascadeReportSlotMissing
  | CascadeReportSlotCorrupt !Text
  | CascadeReportSlotUnobservable !ObservationFailure
  | CascadeReportSlotUnbounded !Int !Int
  | CascadeReportSlotRunIdMismatch !CleanupRunId !CleanupRunId
  deriving stock (Eq, Show)

renderCascadeReportRepositoryError :: CascadeReportRepositoryError -> Text
renderCascadeReportRepositoryError = \case
  CascadeReportCoordinateInvalid detail ->
    "the retained cascade-report coordinate is invalid: " <> detail
  CascadeReportSlotMissing ->
    "the Lifecycle Authority holds nothing for this run"
  CascadeReportSlotCorrupt detail ->
    "the retained cascade-report slot is corrupt: " <> detail
  CascadeReportSlotUnobservable (ObservationFailure detail) ->
    "the retained cascade-report slot is unobservable: " <> detail
  CascadeReportSlotUnbounded observed limit ->
    "the retained cascade-report slot is "
      <> Text.pack (show observed)
      <> " bytes, over its bound of "
      <> Text.pack (show limit)
  CascadeReportSlotRunIdMismatch expected observed ->
    "the retained cascade-report slot belongs to run `"
      <> cleanupRunIdText observed
      <> "`, not `"
      <> cleanupRunIdText expected
      <> "`"

-- ---------------------------------------------------------------------------
-- Committing the report identity
-- ---------------------------------------------------------------------------

-- | Record that this run's pre-uninstall report has this identity.
commitCascadeReportAttempt
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> CleanupRunId
  -> CascadeReportDigest
  -> m CascadeReportSlotResult
commitCascadeReportAttempt client runId digest =
  writeSlot
    client
    "cascade-report"
    (cascadeReportAuthorityLogicalName runId)
    (encodeReportEnvelope runId digest)

-- | Grant the one-shot local-completion permit for this run.
--
-- The grant's fields are supplied by the caller from the compiled run, so this
-- repository decides durability and uniqueness and never invents an identity.
grantLocalCompletionPermitAttempt
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> CleanupRunId
  -> Text
  -- ^ The permit id, derived by the caller and bound to the report identity.
  -> CascadeReportDigest
  -> CascadeLocalOperationReferences
  -> m CascadeReportSlotResult
grantLocalCompletionPermitAttempt client runId permitId digest operations =
  writeSlot
    client
    "cascade-completion-permit"
    (cascadeCompletionPermitAuthorityLogicalName runId)
    (encodePermitEnvelope runId permitId digest operations)

-- ---------------------------------------------------------------------------
-- Reading either slot back
-- ---------------------------------------------------------------------------

-- | The report identity the Authority durably holds for this run.
observeCommittedCascadeReport
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> CleanupRunId
  -> m (Either CascadeReportRepositoryError CascadeReportDigest)
observeCommittedCascadeReport client expectedRunId =
  readSlot
    client
    "cascade-report"
    (cascadeReportAuthorityLogicalName expectedRunId)
    (decodeReportEnvelope expectedRunId)

-- | The permit the Authority durably holds for this run.
observeGrantedLocalCompletionPermit
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> CleanupRunId
  -> m
       ( Either
           CascadeReportRepositoryError
           (Text, CascadeReportDigest, CascadeLocalOperationReferences)
       )
observeGrantedLocalCompletionPermit client expectedRunId =
  readSlot
    client
    "cascade-completion-permit"
    (cascadeCompletionPermitAuthorityLogicalName expectedRunId)
    (decodePermitEnvelope expectedRunId)

-- ---------------------------------------------------------------------------
-- The one write and the one read
-- ---------------------------------------------------------------------------

writeSlot
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> Text
  -> Text
  -> ByteString
  -> m CascadeReportSlotResult
writeSlot (CascadeReportAuthorityClient authority adapter) category logicalName expectedBytes =
  case slotCoordinate authority logicalName of
    Left detail -> pure (unavailable category "coordinate" detail)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      case observed of
        ModelBMissing -> initialize coordinate
        ModelBObserved _ bytes -> pure (existingDisposition bytes)
        ModelBCorrupt detail -> pure (unavailable category "corrupt" detail)
        ModelBEndpointUnready detail ->
          pure (unavailable category "endpoint-unready" detail)
        ModelBUnobservable detail ->
          pure (unavailable category "unobservable" detail)
 where
  initialize coordinate = do
    attempted <- modelBCompareAndSwap adapter (ModelBInitialize coordinate expectedBytes)
    pure $ case attempted of
      ModelBCasApplied _ bytes
        | bytes == expectedBytes -> CascadeReportSlotWritten
        | otherwise -> CascadeReportSlotConflict
      ModelBCasConflict observation -> conflictDisposition observation
      ModelBCasRefusedCorrupt detail -> unavailable category "cas-corrupt" detail
      ModelBCasEndpointUnready detail ->
        unavailable category "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        CascadeReportSlotResponseLost
          (slotFailure category "cas-response-unobservable" detail)

  existingDisposition bytes
    | bytes == expectedBytes = CascadeReportSlotExactReplay
    | otherwise = CascadeReportSlotConflict

  conflictDisposition = \case
    ModelBObserved _ bytes -> existingDisposition bytes
    ModelBMissing ->
      CascadeReportSlotResponseLost
        (slotFailure category "cas-conflict-missing" "conflict value is missing")
    ModelBCorrupt detail -> unavailable category "cas-conflict-corrupt" detail
    ModelBEndpointUnready detail ->
      CascadeReportSlotResponseLost
        (slotFailure category "cas-conflict-endpoint-unready" detail)
    ModelBUnobservable detail ->
      CascadeReportSlotResponseLost
        (slotFailure category "cas-conflict-unobservable" detail)

readSlot
  :: (Monad m)
  => CascadeReportAuthorityClient m
  -> Text
  -> Text
  -> (ByteString -> Either CascadeReportRepositoryError value)
  -> m (Either CascadeReportRepositoryError value)
readSlot (CascadeReportAuthorityClient authority adapter) category logicalName decode =
  case slotCoordinate authority logicalName of
    Left detail -> pure (Left (CascadeReportCoordinateInvalid detail))
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> Left CascadeReportSlotMissing
        ModelBObserved _ bytes -> decode bytes
        ModelBCorrupt detail -> Left (CascadeReportSlotCorrupt detail)
        ModelBEndpointUnready detail ->
          Left
            ( CascadeReportSlotUnobservable
                (slotFailure category "endpoint-unready" detail)
            )
        ModelBUnobservable detail ->
          Left
            ( CascadeReportSlotUnobservable
                (slotFailure category "unobservable" detail)
            )

slotCoordinate
  :: LongLivedCheckpointAuthority
  -> Text
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
slotCoordinate authority logicalName =
  first (Text.pack . show) (mkClusterRetainedCoordinate authority logicalName)

unavailable :: Text -> Text -> Text -> CascadeReportSlotResult
unavailable category reason detail =
  CascadeReportSlotUnavailable (slotFailure category reason detail)

slotFailure :: Text -> Text -> Text -> ObservationFailure
slotFailure category reason detail =
  ObservationFailure (category <> "/" <> reason <> ":" <> detail)

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

encodeReportEnvelope :: CleanupRunId -> CascadeReportDigest -> ByteString
encodeReportEnvelope runId digest =
  LazyByteString.toStrict
    ( serialise
        DurableCascadeReportEnvelope
          { durableCascadeReportVersion = cascadeReportSlotVersion
          , durableCascadeReportRunId = cleanupRunIdText runId
          , durableCascadeReportDigest = cascadeReportDigestText digest
          }
    )

decodeReportEnvelope
  :: CleanupRunId
  -> ByteString
  -> Either CascadeReportRepositoryError CascadeReportDigest
decodeReportEnvelope expectedRunId bytes = do
  envelope <- decodeCanonical bytes
  requireVersion (durableCascadeReportVersion envelope)
  requireRunId expectedRunId (durableCascadeReportRunId envelope)
  first
    CascadeReportSlotCorrupt
    (mkCascadeReportDigest (durableCascadeReportDigest envelope))

encodePermitEnvelope
  :: CleanupRunId
  -> Text
  -> CascadeReportDigest
  -> CascadeLocalOperationReferences
  -> ByteString
encodePermitEnvelope runId permitId digest operations =
  LazyByteString.toStrict
    ( serialise
        DurableCompletionPermitEnvelope
          { durableCompletionPermitVersion = cascadeReportSlotVersion
          , durableCompletionPermitId = permitId
          , durableCompletionPermitRunId = cleanupRunIdText runId
          , durableCompletionPermitReportDigest = cascadeReportDigestText digest
          , durableCompletionPermitUninstallOperation =
              cleanupOperationIdText (cascadeLocalUninstallOperationId operations)
          , durableCompletionPermitCompletionOperation =
              cleanupOperationIdText (cascadeLocalCompletionOperationId operations)
          }
    )

decodePermitEnvelope
  :: CleanupRunId
  -> ByteString
  -> Either
       CascadeReportRepositoryError
       (Text, CascadeReportDigest, CascadeLocalOperationReferences)
decodePermitEnvelope expectedRunId bytes = do
  envelope <- decodeCanonical bytes
  requireVersion (durableCompletionPermitVersion envelope)
  requireRunId expectedRunId (durableCompletionPermitRunId envelope)
  digest <-
    first
      CascadeReportSlotCorrupt
      (mkCascadeReportDigest (durableCompletionPermitReportDigest envelope))
  uninstall <- operationId (durableCompletionPermitUninstallOperation envelope)
  completion <- operationId (durableCompletionPermitCompletionOperation envelope)
  Right
    ( durableCompletionPermitId envelope
    , digest
    , CascadeLocalOperationReferences
        { cascadeLocalUninstallOperationId = uninstall
        , cascadeLocalCompletionOperationId = completion
        }
    )
 where
  operationId :: Text -> Either CascadeReportRepositoryError CleanupOperationId
  operationId = first CascadeReportSlotCorrupt . mkCleanupOperationId

-- | Decode, and require that re-encoding the decoded value reproduces the exact
-- bytes.  A slot whose bytes are not what the encoder would write is corrupt
-- rather than accepted, so an exact-replay comparison cannot be satisfied by
-- two different encodings of the same value.
decodeCanonical
  :: (Eq envelope, Serialise envelope)
  => ByteString
  -> Either CascadeReportRepositoryError envelope
decodeCanonical bytes
  | ByteString.length bytes > maximumCascadeReportSlotBytes =
      Left
        ( CascadeReportSlotUnbounded
            (ByteString.length bytes)
            maximumCascadeReportSlotBytes
        )
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left (CascadeReportSlotCorrupt "the retained slot did not decode")
      Right envelope
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left (CascadeReportSlotCorrupt "the retained slot is not canonical")
        | otherwise -> Right envelope

requireVersion :: Word16 -> Either CascadeReportRepositoryError ()
requireVersion version
  | version == cascadeReportSlotVersion = Right ()
  | otherwise =
      Left
        ( CascadeReportSlotCorrupt
            ("the retained slot carries version " <> Text.pack (show version))
        )

-- | The run id is compared against the /decoded/ record rather than against the
-- coordinate, so a slot whose bytes name another run is refused even though its
-- name was derived from the right one.
requireRunId :: CleanupRunId -> Text -> Either CascadeReportRepositoryError ()
requireRunId expected observedText = do
  observed <- first CascadeReportSlotCorrupt (mkCleanupRunId observedText)
  if observed == expected
    then Right ()
    else Left (CascadeReportSlotRunIdMismatch expected observed)
