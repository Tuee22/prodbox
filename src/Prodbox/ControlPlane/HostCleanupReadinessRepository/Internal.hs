{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: Authority-owned storage for one run's accepted pre-uninstall
-- readiness.
--
-- [Lifecycle Reconciliation Doctrine § 5b nodes 7 and 9](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- put the Lifecycle Authority on both sides of the destructive host boundary:
-- it accepts the readiness before local RKE2 is uninstalled, and after the
-- cascade re-establishes it the same readiness must still be there to be read
-- back.  The host runner already asked both questions and neither had a durable
-- answer, because nothing in the repository stored a readiness at the Authority
-- at all.  This module is that store.
--
-- Four properties carry the design.
--
--   * __A run owns exactly one readiness slot.__  The logical name is derived
--     from the 'CleanupRunId' alone, so a second readiness for the same run is
--     a conflict rather than a second key.  Readiness that could be re-keyed
--     would let a rerun accept a different permit under the same run.
--
--   * __The write result never decides durability.__  Accepting observes
--     first, initializes only into a missing slot, and classifies an existing
--     slot by comparing its exact bytes.  A lost response is reported as a lost
--     response, and the caller's next step is the independent read-back rather
--     than a retry that would overwrite.
--
--   * __The read-back decodes; it does not trust.__  Bytes come back through
--     the same canonical decoder that produced them, and the decoded
--     observation's run id is compared with the run the caller asked for.  A
--     slot holding another run's readiness is a refusal, not a value.
--
--   * __Missing, corrupt, and unobservable stay three answers.__  A slot that
--     holds nothing says the readiness was never accepted; a slot that could
--     not be read says nothing at all.  The host runner turns the first into
--     "the Authority has not accepted this run" and the second into an
--     observation failure, and collapsing them would make an unreachable
--     object store read as a clean "not yet".
--
-- What this module does not own: the /content/ of readiness, which
-- "Prodbox.Lifecycle.Teardown.PreUninstallReadiness" composes; the restoration
-- of the opaque proof, which needs the exact 'CleanupRun' and observation scope
-- and therefore belongs to the caller that holds them; and the durability class
-- of the object namespace, which the @'ClusterRetained'@ index fixes at compile
-- time.
module Prodbox.ControlPlane.HostCleanupReadinessRepository.Internal
  ( -- * The Authority client
    HostCleanupReadinessAuthorityClient
  , modelBHostCleanupReadinessRepository
  , hostCleanupReadinessAuthorityLogicalName
  , hostCleanupReadinessModelBCodec

    -- * Accepting
  , HostCleanupReadinessAcceptResult (..)
  , acceptHostCleanupReadinessAttempt

    -- * Reading it back
  , HostCleanupReadinessRepositoryError (..)
  , renderHostCleanupReadinessRepositoryError
  , AcceptedHostCleanupReadiness
  , acceptedHostCleanupReadinessRunId
  , acceptedHostCleanupReadinessBinding
  , independentlyReadBackAcceptedHostCleanupReadiness
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.CleanupRun (CleanupRunId, cleanupRunIdText)
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeEvidenceError
  , DurableReadyToUninstallBinding
  , decodeDurableReadyToUninstallBinding
  , encodeDurableReadyToUninstallBinding
  , maximumDurableReadyToUninstallBindingBytes
  , observeDurableReadyToUninstallBinding
  , readyBindingObservationRunId
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (ObservationFailure))

-- ---------------------------------------------------------------------------
-- The Authority client
-- ---------------------------------------------------------------------------

-- | The Authority's retained readiness namespace.
--
-- The adapter is indexed @'ClusterRetained'@, so a composition that tried to
-- carry this state over a chart-scoped transport is a type error rather than a
-- run that loses its readiness with the cluster.
data HostCleanupReadinessAuthorityClient m
  = HostCleanupReadinessAuthorityClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString)

modelBHostCleanupReadinessRepository
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> HostCleanupReadinessAuthorityClient m
modelBHostCleanupReadinessRepository = HostCleanupReadinessAuthorityClient

-- | One run, one slot.
--
-- The run id is framed by its own length before hashing, so no two distinct
-- run ids can produce the same name by concatenation.
hostCleanupReadinessAuthorityLogicalName :: CleanupRunId -> Text
hostCleanupReadinessAuthorityLogicalName runId =
  "authority/host-cleanup-readiness/"
    <> TextEncoding.decodeUtf8
      ( hexSha256
          ( TextEncoding.encodeUtf8
              ( Text.concat
                  ( map
                      frame
                      [ "host-cleanup-readiness-identity/v1"
                      , cleanupRunIdText runId
                      ]
                  )
              )
          )
      )
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

-- | Bytes are admitted in both directions only if they decode canonically.
--
-- Encoding validates too, so a caller cannot write a payload that only the
-- reader would reject.
hostCleanupReadinessModelBCodec :: ModelBCodec ByteString
hostCleanupReadinessModelBCodec =
  ModelBCodec
    { encodeModelBValue = validateBytes
    , decodeModelBValue = validateBytes
    }
 where
  validateBytes bytes
    | ByteString.length bytes > maximumDurableReadyToUninstallBindingBytes =
        Left "host cleanup readiness exceeds its encoded bound"
    | otherwise =
        bytes <$ first show (decodeDurableReadyToUninstallBinding bytes)

-- ---------------------------------------------------------------------------
-- Accepting
-- ---------------------------------------------------------------------------

-- | What one acceptance attempt did.
--
-- @ExactReplay@ is a success: the same run accepting the same readiness twice
-- is the rerun this protocol is built for.  @Conflict@ is not, because two
-- different readiness proofs under one run id would mean two permits.
data HostCleanupReadinessAcceptResult
  = HostCleanupReadinessAccepted
  | HostCleanupReadinessExactReplay
  | HostCleanupReadinessConflict
  | HostCleanupReadinessAcceptResponseLost !ObservationFailure
  | HostCleanupReadinessAcceptUnavailable !ObservationFailure
  deriving (Eq, Show)

-- | Observe the slot, initialize it only when it holds nothing, and classify an
-- existing slot by its exact bytes.
--
-- There is deliberately no replace arm.  Readiness is immutable for a run, so
-- the only write this repository can issue is the one into an empty slot.
acceptHostCleanupReadinessAttempt
  :: (Monad m)
  => HostCleanupReadinessAuthorityClient m
  -> CleanupRunId
  -> DurableReadyToUninstallBinding
  -> m HostCleanupReadinessAcceptResult
acceptHostCleanupReadinessAttempt
  (HostCleanupReadinessAuthorityClient authority adapter)
  runId
  binding =
    case readinessCoordinate authority runId of
      Left detail -> pure (acceptUnavailable "coordinate" detail)
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize coordinate
          ModelBObserved _ bytes -> pure (existingDisposition bytes)
          ModelBCorrupt detail -> pure (acceptUnavailable "corrupt" detail)
          ModelBEndpointUnready detail ->
            pure (acceptUnavailable "endpoint-unready" detail)
          ModelBUnobservable detail ->
            pure (acceptUnavailable "unobservable" detail)
   where
    expectedBytes = encodeDurableReadyToUninstallBinding binding

    initialize coordinate = do
      attempted <-
        modelBCompareAndSwap adapter (ModelBInitialize coordinate expectedBytes)
      pure $ case attempted of
        ModelBCasApplied _ bytes
          | bytes == expectedBytes -> HostCleanupReadinessAccepted
          | otherwise -> HostCleanupReadinessConflict
        ModelBCasConflict observation -> conflictDisposition observation
        ModelBCasRefusedCorrupt detail -> acceptUnavailable "cas-corrupt" detail
        ModelBCasEndpointUnready detail ->
          acceptUnavailable "cas-endpoint-unready" detail
        ModelBCasUnobservable detail ->
          HostCleanupReadinessAcceptResponseLost
            (repositoryFailure "cas-response-unobservable" detail)

    existingDisposition bytes
      | bytes == expectedBytes = HostCleanupReadinessExactReplay
      | otherwise = HostCleanupReadinessConflict

    conflictDisposition = \case
      ModelBObserved _ bytes -> existingDisposition bytes
      ModelBMissing ->
        HostCleanupReadinessAcceptResponseLost
          (repositoryFailure "cas-conflict-missing" "conflict value is missing")
      ModelBCorrupt detail -> acceptUnavailable "cas-conflict-corrupt" detail
      ModelBEndpointUnready detail ->
        HostCleanupReadinessAcceptResponseLost
          (repositoryFailure "cas-conflict-endpoint-unready" detail)
      ModelBUnobservable detail ->
        HostCleanupReadinessAcceptResponseLost
          (repositoryFailure "cas-conflict-unobservable" detail)

-- ---------------------------------------------------------------------------
-- Reading it back
-- ---------------------------------------------------------------------------

data HostCleanupReadinessRepositoryError
  = HostCleanupReadinessCoordinateInvalid !Text
  | HostCleanupReadinessMissing
  | HostCleanupReadinessCorrupt !Text
  | HostCleanupReadinessUnobservable !ObservationFailure
  | HostCleanupReadinessUnbounded !Int !Int
  | HostCleanupReadinessBindingInvalid !CascadeEvidenceError
  | HostCleanupReadinessRunIdMismatch !CleanupRunId !CleanupRunId
  deriving (Eq, Show)

renderHostCleanupReadinessRepositoryError
  :: HostCleanupReadinessRepositoryError -> Text
renderHostCleanupReadinessRepositoryError = \case
  HostCleanupReadinessCoordinateInvalid detail ->
    "the retained readiness coordinate is invalid: " <> detail
  HostCleanupReadinessMissing ->
    "the Lifecycle Authority holds no accepted readiness for this run"
  HostCleanupReadinessCorrupt detail ->
    "the accepted readiness is corrupt: " <> detail
  HostCleanupReadinessUnobservable (ObservationFailure detail) ->
    "the accepted readiness is unobservable: " <> detail
  HostCleanupReadinessUnbounded observed maximum' ->
    "the accepted readiness is "
      <> Text.pack (show observed)
      <> " bytes, over its bound of "
      <> Text.pack (show maximum')
  HostCleanupReadinessBindingInvalid err ->
    "the accepted readiness did not decode: " <> Text.pack (show err)
  HostCleanupReadinessRunIdMismatch expected observed ->
    "the accepted readiness belongs to run `"
      <> cleanupRunIdText observed
      <> "`, not `"
      <> cleanupRunIdText expected
      <> "`"

-- | A positively read-back acceptance.
--
-- The constructor stays package-private: holding one is not readiness, and
-- turning it into readiness still requires the exact 'CleanupRun' and
-- observation scope that only the running cascade holds.
data AcceptedHostCleanupReadiness = AcceptedHostCleanupReadiness
  { internalAcceptedReadinessRunId :: !CleanupRunId
  , internalAcceptedReadinessBinding :: !DurableReadyToUninstallBinding
  }

acceptedHostCleanupReadinessRunId :: AcceptedHostCleanupReadiness -> CleanupRunId
acceptedHostCleanupReadinessRunId = internalAcceptedReadinessRunId

acceptedHostCleanupReadinessBinding
  :: AcceptedHostCleanupReadiness -> DurableReadyToUninstallBinding
acceptedHostCleanupReadinessBinding = internalAcceptedReadinessBinding

-- | Observe the run's slot and decode what is in it.
--
-- The expected run id is compared against the /decoded/ observation rather than
-- against the coordinate, so a slot whose bytes name another run is refused
-- even though its name was derived from the right one.
independentlyReadBackAcceptedHostCleanupReadiness
  :: (Monad m)
  => HostCleanupReadinessAuthorityClient m
  -> CleanupRunId
  -> m (Either HostCleanupReadinessRepositoryError AcceptedHostCleanupReadiness)
independentlyReadBackAcceptedHostCleanupReadiness
  (HostCleanupReadinessAuthorityClient authority adapter)
  expectedRunId =
    case readinessCoordinate authority expectedRunId of
      Left detail ->
        pure (Left (HostCleanupReadinessCoordinateInvalid detail))
      Right coordinate -> do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Left HostCleanupReadinessMissing
          ModelBObserved _ bytes ->
            confirmAcceptedHostCleanupReadinessBytes expectedRunId bytes
          ModelBCorrupt detail -> Left (HostCleanupReadinessCorrupt detail)
          ModelBEndpointUnready detail ->
            Left
              ( HostCleanupReadinessUnobservable
                  (repositoryFailure "endpoint-unready" detail)
              )
          ModelBUnobservable detail ->
            Left
              ( HostCleanupReadinessUnobservable
                  (repositoryFailure "unobservable" detail)
              )

confirmAcceptedHostCleanupReadinessBytes
  :: CleanupRunId
  -> ByteString
  -> Either HostCleanupReadinessRepositoryError AcceptedHostCleanupReadiness
confirmAcceptedHostCleanupReadinessBytes expectedRunId bytes
  | ByteString.length bytes > maximumDurableReadyToUninstallBindingBytes =
      Left
        ( HostCleanupReadinessUnbounded
            (ByteString.length bytes)
            maximumDurableReadyToUninstallBindingBytes
        )
  | otherwise = do
      binding <-
        first
          HostCleanupReadinessBindingInvalid
          (decodeDurableReadyToUninstallBinding bytes)
      let observedRunId =
            readyBindingObservationRunId
              (observeDurableReadyToUninstallBinding binding)
      if observedRunId == expectedRunId
        then
          Right
            AcceptedHostCleanupReadiness
              { internalAcceptedReadinessRunId = observedRunId
              , internalAcceptedReadinessBinding = binding
              }
        else
          Left (HostCleanupReadinessRunIdMismatch expectedRunId observedRunId)

readinessCoordinate
  :: LongLivedCheckpointAuthority
  -> CleanupRunId
  -> Either Text (ModelBObjectCoordinate 'ClusterRetained)
readinessCoordinate authority runId =
  first
    (Text.pack . show)
    ( mkClusterRetainedCoordinate
        authority
        (hostCleanupReadinessAuthorityLogicalName runId)
    )

acceptUnavailable :: Text -> Text -> HostCleanupReadinessAcceptResult
acceptUnavailable category detail =
  HostCleanupReadinessAcceptUnavailable (repositoryFailure category detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure ("host-cleanup-readiness/" <> category <> ":" <> detail)
