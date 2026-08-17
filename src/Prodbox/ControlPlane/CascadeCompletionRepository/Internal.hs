{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private Authority Model-B implementation for descriptor-bound
-- cascade completion.  A write disposition is never completion evidence;
-- only an independent read-back against the exact post-Begin descriptor
-- handle can construct 'DescriptorBoundCascadeCompleteEvidence'.
module Prodbox.ControlPlane.CascadeCompletionRepository.Internal
  ( CascadeCompletionRepositoryClient
  , modelBCascadeCompletionRepositoryInternal
  , cascadeCompletionModelBCodecInternal
  , DescriptorBoundCascadeCompleteEvidence
  , descriptorBoundCascadeCompleteRunId
  , descriptorBoundCascadeCompleteDescriptorDigest
  , descriptorBoundCascadeCompleteGraphDigest
  , descriptorBoundCascadeCompleteScope
  , descriptorBoundCascadeCompleteReadyDigest
  , descriptorBoundCascadeCompleteUninstallAttemptId
  , descriptorBoundCascadeCompleteLocalReadBackAttemptId
  , descriptorBoundCascadeCompleteCommitAttemptId
  , descriptorBoundCascadeCompleteReadBackAttemptId
  , descriptorBoundCascadeCompleteAbsenceFact
  , descriptorBoundCascadeReadyHostBindingAtUninstallInternal
  , descriptorBoundCascadeReadyHostBindingAtLocalReadBackInternal
  , bindDescriptorBoundCascadeLocalAbsenceAtReadBackInternal
  , recoverDescriptorBoundCascadeLocalAbsenceAtCommitInternal
  , commitDescriptorBoundCascadeCompletionInternal
  , independentlyReadBackDescriptorBoundCascadeCompletionInternal
  , CascadeCompletionRepositoryError (..)
  , CascadeCompletionCommitResult (..)
  , CascadeCompletionRepositoryRegression
  , fixedCascadeCompletionRepositoryRegression
  , cascadeCompletionRepositoryResponseLossRecovered
  , cascadeCompletionRepositoryExactReplayPreserved
  , cascadeCompletionRepositoryConflictPreserved
  , cascadeCompletionRepositoryRestartReadBack
  , cascadeCompletionRepositoryDescriptorBindingExact
  , cascadeCompletionRepositoryPredecessorAttemptsExact
  , cascadeCompletionRepositoryWrongIdentityRefused
  , cascadeCompletionRepositoryCorruptionRefused
  , cascadeCompletionRepositoryBoundsEnforced
  , cascadeCompletionRepositoryLegacyEvidenceDisjoint
  , cascadeCompletionRepositoryOpacityClosed
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupRunIdText
  , mkCleanupAttemptId
  )
import Prodbox.Lifecycle.HostCascadeLocalAbsence
  ( DescriptorBoundCascadeLocalAbsenceEvidence
  , DescriptorBoundCascadeReadyHostBinding
  , HostCascadeLocalAbsenceError
  , descriptorBoundCascadeHostCompletionCommitOperationId
  , descriptorBoundCascadeHostCompletionReadBackOperationId
  , descriptorBoundCascadeHostDescriptorDigest
  , descriptorBoundCascadeHostGraphDigest
  , descriptorBoundCascadeHostLocalReadBackOperationId
  , descriptorBoundCascadeHostReadyDigest
  , descriptorBoundCascadeHostRunId
  , descriptorBoundCascadeHostScope
  , descriptorBoundCascadeHostUninstallAttemptId
  , descriptorBoundCascadeHostUninstallOperationId
  , descriptorBoundCascadeLocalAbsenceBinding
  , descriptorBoundCascadeLocalAbsenceFact
  , descriptorBoundCascadeLocalAbsenceReadBackAttemptId
  , maximumHostCascadeLocalAbsenceBytes
  )
import Prodbox.Lifecycle.HostCascadeLocalAbsence.Internal
  ( HostCascadeLocalAbsenceRecord
  , decodeHostCascadeLocalAbsenceRecordInternal
  , decodedHostCascadeLocalAbsenceReadyBytesInternal
  , decodedHostCascadeLocalAbsenceUninstallAttemptInternal
  , descriptorBoundCascadeHostDurableReadyInternal
  , encodeHostCascadeLocalAbsenceRecordInternal
  , mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal
  , mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
  , mkDescriptorBoundCascadeReadyHostBindingInternal
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeLocalOperationReferences
  , DurableReadyToUninstallBinding
  , ReadyToUninstallEvidence
  , cascadeLocalCompletionOperationId
  , cascadeLocalUninstallOperationId
  , encodeDurableReadyToUninstallBinding
  , observeDurableReadyToUninstallBinding
  , readyBindingObservationGraphDigest
  , readyBindingObservationOperationReferences
  , readyBindingObservationRunId
  , readyBindingObservationScope
  , readyToUninstallGraphDigest
  , readyToUninstallOperationReferences
  , readyToUninstallRunId
  , readyToUninstallScope
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( decodeDurableReadyToUninstallBinding
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownAttemptedPredecessor
  , TeardownExecutionContext
  , TeardownSucceededPredecessor
  , teardownAttemptedPredecessorAttemptId
  , teardownAttemptedPredecessorOperation
  , teardownAttemptedPredecessorOperationId
  , teardownAttemptedPredecessorOutcome
  , teardownExecutionAttemptId
  , teardownExecutionAttemptedPredecessors
  , teardownExecutionDescriptorDigest
  , teardownExecutionGraphDigest
  , teardownExecutionNodeId
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  , teardownExecutionOperationIdFor
  , teardownExecutionRunId
  , teardownExecutionSuccessfulPredecessors
  , teardownSucceededPredecessorAttemptId
  , teardownSucceededPredecessorOperation
  , teardownSucceededPredecessorOperationId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , CleanupSurfaceWitness (..)
  , ObservationEvidenceScope
  , ObservationFailure (..)
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence)
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (..)
  )

data CascadeCompletionRepositoryClient m
  = CascadeCompletionRepositoryClient
      !LongLivedCheckpointAuthority
      !(ModelBCasAdapter 'ClusterRetained m ByteString)

modelBCascadeCompletionRepositoryInternal
  :: LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> CascadeCompletionRepositoryClient m
modelBCascadeCompletionRepositoryInternal = CascadeCompletionRepositoryClient

data CascadeCompletionCommitResult
  = CascadeCompletionCommitCreated
  | CascadeCompletionCommitExactReplay
  | CascadeCompletionCommitConflict
  | CascadeCompletionCommitResponseLost !ObservationFailure
  | CascadeCompletionCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data CascadeCompletionRepositoryError
  = CascadeCompletionRepositoryDescriptorBindingInvalid !CleanupRunClientError
  | CascadeCompletionRepositoryUnsupportedSurface
  | CascadeCompletionRepositoryContextRunMismatch !CleanupRunId !CleanupRunId
  | CascadeCompletionRepositoryContextDescriptorMismatch
      !(Maybe CleanupDigest)
      !CleanupDigest
  | CascadeCompletionRepositoryContextGraphMismatch !CleanupDigest !CleanupDigest
  | CascadeCompletionRepositoryContextScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeCompletionRepositoryContextOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | CascadeCompletionRepositoryContextNodeMismatch !CleanupNodeId
  | CascadeCompletionRepositoryReadyRunMismatch
  | CascadeCompletionRepositoryReadyGraphMismatch
  | CascadeCompletionRepositoryReadyScopeMismatch
  | CascadeCompletionRepositoryReadyOperationsMismatch
  | CascadeCompletionRepositoryOperationMissing !Text
  | CascadeCompletionRepositoryPredecessorCardinality !Text !Int
  | CascadeCompletionRepositoryPredecessorOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | CascadeCompletionRepositoryPredecessorStateMismatch !CleanupOperationId
  | CascadeCompletionRepositoryHostEvidenceInvalid !HostCascadeLocalAbsenceError
  | CascadeCompletionRepositoryCoordinateInvalid !Text
  | CascadeCompletionRepositoryMissing
  | CascadeCompletionRepositoryCorrupt !Text
  | CascadeCompletionRepositoryUnobservable !ObservationFailure
  | CascadeCompletionRepositoryUnbounded !Int !Int
  | CascadeCompletionRepositoryAttemptMismatch
      !CleanupAttemptId
      !CleanupAttemptId
  | CascadeCompletionRepositoryIdentityMismatch
  deriving stock (Eq, Show)

data DescriptorBoundCascadeCompleteEvidence
  = DescriptorBoundCascadeCompleteEvidenceInternal
      !DescriptorBoundCascadeLocalAbsenceEvidence
      !CleanupAttemptId
      !CleanupAttemptId

instance Eq DescriptorBoundCascadeCompleteEvidence where
  left == right =
    descriptorBoundCascadeCompleteIdentityTuple left
      == descriptorBoundCascadeCompleteIdentityTuple right

instance Show DescriptorBoundCascadeCompleteEvidence where
  show evidence =
    "<descriptor-bound-cascade-complete:"
      <> Text.unpack
        (cleanupRunIdText (descriptorBoundCascadeCompleteRunId evidence))
      <> ">"

descriptorBoundCascadeCompleteRunId
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupRunId
descriptorBoundCascadeCompleteRunId =
  descriptorBoundCascadeHostRunId
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteDescriptorDigest
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupDigest
descriptorBoundCascadeCompleteDescriptorDigest =
  descriptorBoundCascadeHostDescriptorDigest
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteGraphDigest
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupDigest
descriptorBoundCascadeCompleteGraphDigest =
  descriptorBoundCascadeHostGraphDigest
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteScope
  :: DescriptorBoundCascadeCompleteEvidence -> ObservationEvidenceScope
descriptorBoundCascadeCompleteScope =
  descriptorBoundCascadeHostScope
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteReadyDigest
  :: DescriptorBoundCascadeCompleteEvidence -> Text
descriptorBoundCascadeCompleteReadyDigest =
  descriptorBoundCascadeHostReadyDigest
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteUninstallAttemptId
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupAttemptId
descriptorBoundCascadeCompleteUninstallAttemptId =
  descriptorBoundCascadeHostUninstallAttemptId
    . descriptorBoundCascadeLocalAbsenceBinding
    . completeLocal

descriptorBoundCascadeCompleteLocalReadBackAttemptId
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupAttemptId
descriptorBoundCascadeCompleteLocalReadBackAttemptId =
  descriptorBoundCascadeLocalAbsenceReadBackAttemptId . completeLocal

descriptorBoundCascadeCompleteCommitAttemptId
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupAttemptId
descriptorBoundCascadeCompleteCommitAttemptId
  (DescriptorBoundCascadeCompleteEvidenceInternal _ attempt _) = attempt

descriptorBoundCascadeCompleteReadBackAttemptId
  :: DescriptorBoundCascadeCompleteEvidence -> CleanupAttemptId
descriptorBoundCascadeCompleteReadBackAttemptId
  (DescriptorBoundCascadeCompleteEvidenceInternal _ _ attempt) = attempt

descriptorBoundCascadeCompleteAbsenceFact
  :: DescriptorBoundCascadeCompleteEvidence -> AbsenceEvidence
descriptorBoundCascadeCompleteAbsenceFact =
  descriptorBoundCascadeLocalAbsenceFact . completeLocal

completeLocal
  :: DescriptorBoundCascadeCompleteEvidence
  -> DescriptorBoundCascadeLocalAbsenceEvidence
completeLocal (DescriptorBoundCascadeCompleteEvidenceInternal local _ _) = local

descriptorBoundCascadeCompleteIdentityTuple evidence =
  ( descriptorBoundCascadeCompleteRunId evidence
  , descriptorBoundCascadeCompleteDescriptorDigest evidence
  , descriptorBoundCascadeCompleteGraphDigest evidence
  , descriptorBoundCascadeCompleteScope evidence
  , descriptorBoundCascadeCompleteReadyDigest evidence
  , descriptorBoundCascadeCompleteUninstallAttemptId evidence
  , descriptorBoundCascadeCompleteLocalReadBackAttemptId evidence
  , descriptorBoundCascadeCompleteCommitAttemptId evidence
  , descriptorBoundCascadeCompleteReadBackAttemptId evidence
  , descriptorBoundCascadeCompleteAbsenceFact evidence
  )

data CascadeCompletionAggregateWire = CascadeCompletionAggregateWire
  { cascadeCompletionWireVersion :: !Int
  , cascadeCompletionWireHostRecord :: !ByteString
  , cascadeCompletionWireLocalReadBackAttempt :: !Text
  , cascadeCompletionWireCommitAttempt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cascadeCompletionWireVersionCurrent :: Int
cascadeCompletionWireVersionCurrent = 1

maximumCascadeCompletionAggregateBytes :: Int
maximumCascadeCompletionAggregateBytes =
  maximumHostCascadeLocalAbsenceBytes + (16 * 1024)

cascadeCompletionModelBCodecInternal :: ModelBCodec ByteString
cascadeCompletionModelBCodecInternal =
  ModelBCodec
    { encodeModelBValue = validate
    , decodeModelBValue = validate
    }
 where
  validate bytes = bytes <$ decodeAggregateWire bytes

descriptorBoundCascadeReadyHostBindingAtUninstallInternal
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> ReadyToUninstallEvidence
  -> Either
       CascadeCompletionRepositoryError
       DescriptorBoundCascadeReadyHostBinding
descriptorBoundCascadeReadyHostBindingAtUninstallInternal bound context ready = do
  operations <- validateCascadeContext bound context UninstallCascadeLocalFoundation
  validateReady bound context operations ready
  validateCurrentRunning bound context
  first CascadeCompletionRepositoryHostEvidenceInvalid
    ( mkDescriptorBoundCascadeReadyHostBindingInternal
        (descriptorBoundCleanupRunDescriptorDigest bound)
        (cascadeLocalReadBackOperation operations)
        (cascadeCompletionReadBackOperation operations)
        (teardownExecutionAttemptId context)
        ready
    )

descriptorBoundCascadeReadyHostBindingAtLocalReadBackInternal
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> ReadyToUninstallEvidence
  -> Either
       CascadeCompletionRepositoryError
       (DescriptorBoundCascadeReadyHostBinding, CleanupAttemptId)
descriptorBoundCascadeReadyHostBindingAtLocalReadBackInternal bound context ready = do
  operations <- validateCascadeContext bound context ReadBackCascadeLocalAbsence
  validateReady bound context operations ready
  validateCurrentRunning bound context
  predecessor <- exactAttemptedPredecessor context (cascadeUninstallOperation operations)
  case teardownAttemptedPredecessorOperation predecessor of
    UninstallCascadeLocalFoundation -> pure ()
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch (cascadeUninstallOperation operations))
  validateCompletedState
    bound
    (cascadeUninstallOperation operations)
    (teardownAttemptedPredecessorAttemptId predecessor)
    (teardownAttemptedPredecessorOutcome predecessor)
  binding <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( mkDescriptorBoundCascadeReadyHostBindingInternal
          (descriptorBoundCleanupRunDescriptorDigest bound)
          (cascadeLocalReadBackOperation operations)
          (cascadeCompletionReadBackOperation operations)
          (teardownAttemptedPredecessorAttemptId predecessor)
          ready
      )
  pure (binding, teardownExecutionAttemptId context)

bindDescriptorBoundCascadeLocalAbsenceAtReadBackInternal
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> ReadyToUninstallEvidence
  -> HostCascadeLocalAbsenceRecord
  -> Either
       CascadeCompletionRepositoryError
       DescriptorBoundCascadeLocalAbsenceEvidence
bindDescriptorBoundCascadeLocalAbsenceAtReadBackInternal bound context ready record = do
  (binding, readBackAttempt) <-
    descriptorBoundCascadeReadyHostBindingAtLocalReadBackInternal
      bound
      context
      ready
  first CascadeCompletionRepositoryHostEvidenceInvalid
    ( mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal
        binding
        readBackAttempt
        record
    )

recoverDescriptorBoundCascadeLocalAbsenceAtCommitInternal
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> ReadyToUninstallEvidence
  -> HostCascadeLocalAbsenceRecord
  -> Either
       CascadeCompletionRepositoryError
       DescriptorBoundCascadeLocalAbsenceEvidence
recoverDescriptorBoundCascadeLocalAbsenceAtCommitInternal bound context ready record = do
  operations <- validateCascadeContext bound context CommitCascadeCompletion
  validateReady bound context operations ready
  validateCurrentRunning bound context
  predecessor <- exactSucceededPredecessor context (cascadeLocalReadBackOperation operations)
  case teardownSucceededPredecessorOperation predecessor of
    ReadBackCascadeLocalAbsence -> pure ()
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch (cascadeLocalReadBackOperation operations))
  let localReadBackAttempt = teardownSucceededPredecessorAttemptId predecessor
  validateCompletedState
    bound
    (cascadeLocalReadBackOperation operations)
    localReadBackAttempt
    CleanupNodeSucceeded
  uninstallAttempt <- completedAttemptFor bound (cascadeUninstallOperation operations)
  binding <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( mkDescriptorBoundCascadeReadyHostBindingInternal
          (descriptorBoundCleanupRunDescriptorDigest bound)
          (cascadeLocalReadBackOperation operations)
          (cascadeCompletionReadBackOperation operations)
          uninstallAttempt
          ready
      )
  first CascadeCompletionRepositoryHostEvidenceInvalid
    ( mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal
        binding
        localReadBackAttempt
        record
    )

commitDescriptorBoundCascadeCompletionInternal
  :: (Monad m)
  => CascadeCompletionRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> DescriptorBoundCascadeLocalAbsenceEvidence
  -> m
       ( Either
           CascadeCompletionRepositoryError
           CascadeCompletionCommitResult
       )
commitDescriptorBoundCascadeCompletionInternal client bound context local =
  case validateCommitBinding bound context local of
    Left err -> pure (Left err)
    Right () -> case aggregateCoordinate client bound of
      Left err -> pure (Left err)
      Right coordinate -> do
        let candidate = encodeAggregate local (teardownExecutionAttemptId context)
            CascadeCompletionRepositoryClient _ adapter = client
        observed <- modelBObserve adapter coordinate
        case observed of
          ModelBMissing -> initialize adapter coordinate candidate
          ModelBObserved _ existing
            | existing == candidate ->
                pure (Right CascadeCompletionCommitExactReplay)
            | otherwise -> pure (Right CascadeCompletionCommitConflict)
          ModelBCorrupt detail ->
            pure (Left (CascadeCompletionRepositoryCorrupt detail))
          ModelBEndpointUnready detail ->
            pure (Right (unavailable "observe-endpoint-unready" detail))
          ModelBUnobservable detail ->
            pure (Right (unavailable "observe-unobservable" detail))
 where
  initialize adapter coordinate candidate = do
    attempted <- modelBCompareAndSwap adapter (ModelBInitialize coordinate candidate)
    pure $ case attempted of
      ModelBCasApplied _ bytes
        | bytes == candidate -> Right CascadeCompletionCommitCreated
        | otherwise -> Right CascadeCompletionCommitConflict
      ModelBCasConflict conflict
        | conflict == candidate -> Right CascadeCompletionCommitExactReplay
        | otherwise -> Right CascadeCompletionCommitConflict
      ModelBCasRefusedCorrupt detail ->
        Left (CascadeCompletionRepositoryCorrupt detail)
      ModelBCasEndpointUnready detail ->
        Right (responseLost "cas-endpoint-unready" detail)
      ModelBCasUnobservable detail ->
        Right (responseLost "cas-unobservable" detail)

independentlyReadBackDescriptorBoundCascadeCompletionInternal
  :: (Monad m)
  => CascadeCompletionRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> m
       ( Either
           CascadeCompletionRepositoryError
           DescriptorBoundCascadeCompleteEvidence
       )
independentlyReadBackDescriptorBoundCascadeCompletionInternal client bound context = do
  let CascadeCompletionRepositoryClient _ adapter = client
  case validateCascadeContext bound context ReadBackCascadeCompletion of
    Left err -> pure (Left err)
    Right operations -> case validateCurrentRunning bound context of
      Left err -> pure (Left err)
      Right () -> case aggregateCoordinate client bound of
        Left err -> pure (Left err)
        Right coordinate -> do
          observed <- modelBObserve adapter coordinate
          pure $ do
            bytes <- case observed of
              ModelBMissing -> Left CascadeCompletionRepositoryMissing
              ModelBObserved _ value -> Right value
              ModelBCorrupt detail -> Left (CascadeCompletionRepositoryCorrupt detail)
              ModelBEndpointUnready detail ->
                Left (CascadeCompletionRepositoryUnobservable (failure "read-back-endpoint-unready" detail))
              ModelBUnobservable detail ->
                Left (CascadeCompletionRepositoryUnobservable (failure "read-back-unobservable" detail))
            wire <- decodeAggregateWire bytes
            local <- restoreStoredLocal bound context operations wire
            let commitAttempt = mustAttempt (cascadeCompletionWireCommitAttempt wire)
            predecessor <-
              exactAttemptedPredecessor context (cascadeCompletionCommitOperation operations)
            case teardownAttemptedPredecessorOperation predecessor of
              CommitCascadeCompletion -> pure ()
              _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch (cascadeCompletionCommitOperation operations))
            unless
              (teardownAttemptedPredecessorAttemptId predecessor == commitAttempt)
              ( Left
                  ( CascadeCompletionRepositoryAttemptMismatch
                      commitAttempt
                      (teardownAttemptedPredecessorAttemptId predecessor)
                  )
              )
            validateCompletedState
              bound
              (cascadeCompletionCommitOperation operations)
              commitAttempt
              (teardownAttemptedPredecessorOutcome predecessor)
            pure
              ( DescriptorBoundCascadeCompleteEvidenceInternal
                  local
                  commitAttempt
                  (teardownExecutionAttemptId context)
              )

validateCommitBinding
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> DescriptorBoundCascadeLocalAbsenceEvidence
  -> Either CascadeCompletionRepositoryError ()
validateCommitBinding bound context local = do
  operations <- validateCascadeContext bound context CommitCascadeCompletion
  validateCurrentRunning bound context
  let binding = descriptorBoundCascadeLocalAbsenceBinding local
  validateBindingAgainstHandle bound context operations binding
  predecessor <- exactSucceededPredecessor context (cascadeLocalReadBackOperation operations)
  case teardownSucceededPredecessorOperation predecessor of
    ReadBackCascadeLocalAbsence -> pure ()
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch (cascadeLocalReadBackOperation operations))
  unless
    ( teardownSucceededPredecessorAttemptId predecessor
        == descriptorBoundCascadeLocalAbsenceReadBackAttemptId local
    )
    ( Left
        ( CascadeCompletionRepositoryAttemptMismatch
            (descriptorBoundCascadeLocalAbsenceReadBackAttemptId local)
            (teardownSucceededPredecessorAttemptId predecessor)
        )
    )
  validateCompletedState
    bound
    (cascadeLocalReadBackOperation operations)
    (descriptorBoundCascadeLocalAbsenceReadBackAttemptId local)
    CleanupNodeSucceeded
  _ <- completedAttemptForExact bound (cascadeUninstallOperation operations) (descriptorBoundCascadeHostUninstallAttemptId binding)
  pure ()

data CascadeOperations = CascadeOperations
  { cascadeUninstallOperation :: !CleanupOperationId
  , cascadeLocalReadBackOperation :: !CleanupOperationId
  , cascadeCompletionCommitOperation :: !CleanupOperationId
  , cascadeCompletionReadBackOperation :: !CleanupOperationId
  }

validateCascadeContext
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> TeardownOperation 'Cascade
  -> Either CascadeCompletionRepositoryError CascadeOperations
validateCascadeContext bound context expectedCurrent = do
  joined <-
    first CascadeCompletionRepositoryDescriptorBindingInvalid
      ( withDescriptorBoundCleanupProgram bound $ \witness _ _ ->
          case witness of
            CascadeSurface -> Right ()
            _ -> Left CascadeCompletionRepositoryUnsupportedSurface
      )
  joined
  unless
    (teardownExecutionRunId context == descriptorBoundCleanupRunId bound)
    ( Left
        ( CascadeCompletionRepositoryContextRunMismatch
            (descriptorBoundCleanupRunId bound)
            (teardownExecutionRunId context)
        )
    )
  unless
    ( teardownExecutionDescriptorDigest context
        == Just (descriptorBoundCleanupRunDescriptorDigest bound)
    )
    ( Left
        ( CascadeCompletionRepositoryContextDescriptorMismatch
            (teardownExecutionDescriptorDigest context)
            (descriptorBoundCleanupRunDescriptorDigest bound)
        )
    )
  unless
    (teardownExecutionGraphDigest context == descriptorBoundCleanupRunGraphDigest bound)
    ( Left
        ( CascadeCompletionRepositoryContextGraphMismatch
            (descriptorBoundCleanupRunGraphDigest bound)
            (teardownExecutionGraphDigest context)
        )
    )
  current <- operationId context expectedCurrent
  unless
    (teardownExecutionOperationId context == current)
    ( Left
        ( CascadeCompletionRepositoryContextOperationMismatch
            current
            (teardownExecutionOperationId context)
        )
    )
  CascadeOperations
    <$> operationId context UninstallCascadeLocalFoundation
    <*> operationId context ReadBackCascadeLocalAbsence
    <*> operationId context CommitCascadeCompletion
    <*> operationId context ReadBackCascadeCompletion

operationId
  :: TeardownExecutionContext 'Cascade
  -> TeardownOperation 'Cascade
  -> Either CascadeCompletionRepositoryError CleanupOperationId
operationId context operation =
  maybe
    (Left (CascadeCompletionRepositoryOperationMissing (Text.pack (show operation))))
    Right
    (teardownExecutionOperationIdFor context operation)

validateReady
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> CascadeOperations
  -> ReadyToUninstallEvidence
  -> Either CascadeCompletionRepositoryError ()
validateReady bound context operations ready = do
  unless
    (readyToUninstallRunId ready == descriptorBoundCleanupRunId bound)
    (Left CascadeCompletionRepositoryReadyRunMismatch)
  unless
    (readyToUninstallGraphDigest ready == descriptorBoundCleanupRunGraphDigest bound)
    (Left CascadeCompletionRepositoryReadyGraphMismatch)
  unless
    (readyToUninstallScope ready == teardownExecutionObservationScope context)
    (Left CascadeCompletionRepositoryReadyScopeMismatch)
  let references = readyToUninstallOperationReferences ready
  unless
    ( cascadeLocalUninstallOperationId references == cascadeUninstallOperation operations
        && cascadeLocalCompletionOperationId references
          == cascadeCompletionCommitOperation operations
    )
    (Left CascadeCompletionRepositoryReadyOperationsMismatch)

validateBindingAgainstHandle
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> CascadeOperations
  -> DescriptorBoundCascadeReadyHostBinding
  -> Either CascadeCompletionRepositoryError ()
validateBindingAgainstHandle bound context operations binding = do
  unless
    (descriptorBoundCascadeHostRunId binding == descriptorBoundCleanupRunId bound)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    (descriptorBoundCascadeHostDescriptorDigest binding == descriptorBoundCleanupRunDescriptorDigest bound)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    (descriptorBoundCascadeHostGraphDigest binding == descriptorBoundCleanupRunGraphDigest bound)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    (descriptorBoundCascadeHostScope binding == teardownExecutionObservationScope context)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    ( descriptorBoundCascadeHostUninstallOperationId binding
        == cascadeUninstallOperation operations
        && descriptorBoundCascadeHostLocalReadBackOperationId binding
          == cascadeLocalReadBackOperation operations
        && descriptorBoundCascadeHostCompletionCommitOperationId binding
          == cascadeCompletionCommitOperation operations
        && descriptorBoundCascadeHostCompletionReadBackOperationId binding
          == cascadeCompletionReadBackOperation operations
    )
    (Left CascadeCompletionRepositoryIdentityMismatch)

validateCurrentRunning
  :: DescriptorBoundCleanupRun
  -> TeardownExecutionContext 'Cascade
  -> Either CascadeCompletionRepositoryError ()
validateCurrentRunning bound context = do
  plan <- planForOperation bound (teardownExecutionOperationId context)
  unless
    (cleanupNodeId plan == teardownExecutionNodeId context)
    (Left (CascadeCompletionRepositoryContextNodeMismatch (teardownExecutionNodeId context)))
  case Map.lookup (cleanupNodeId plan) (descriptorBoundCleanupRunNodeStates bound) of
    Just (CleanupNodeRunning attempt)
      | attempt == teardownExecutionAttemptId context -> Right ()
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch (teardownExecutionOperationId context))

exactAttemptedPredecessor
  :: TeardownExecutionContext 'Cascade
  -> CleanupOperationId
  -> Either CascadeCompletionRepositoryError (TeardownAttemptedPredecessor 'Cascade)
exactAttemptedPredecessor context expected =
  case teardownExecutionAttemptedPredecessors context of
    [predecessor]
      | teardownAttemptedPredecessorOperationId predecessor == expected -> Right predecessor
      | otherwise ->
          Left
            ( CascadeCompletionRepositoryPredecessorOperationMismatch
                expected
                (teardownAttemptedPredecessorOperationId predecessor)
            )
    predecessors ->
      Left
        ( CascadeCompletionRepositoryPredecessorCardinality
            "attempted"
            (length predecessors)
        )

exactSucceededPredecessor
  :: TeardownExecutionContext 'Cascade
  -> CleanupOperationId
  -> Either CascadeCompletionRepositoryError (TeardownSucceededPredecessor 'Cascade)
exactSucceededPredecessor context expected =
  case teardownExecutionSuccessfulPredecessors context of
    [predecessor]
      | teardownSucceededPredecessorOperationId predecessor == expected -> Right predecessor
      | otherwise ->
          Left
            ( CascadeCompletionRepositoryPredecessorOperationMismatch
                expected
                (teardownSucceededPredecessorOperationId predecessor)
            )
    predecessors ->
      Left
        ( CascadeCompletionRepositoryPredecessorCardinality
            "succeeded"
            (length predecessors)
        )

planForOperation bound operation =
  case filter
    ((== operation) . cleanupNodeOperationId)
    (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound)) of
    [plan] -> Right plan
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch operation)

validateCompletedState bound operation attempt outcome = do
  plan <- planForOperation bound operation
  case Map.lookup (cleanupNodeId plan) (descriptorBoundCleanupRunNodeStates bound) of
    Just (CleanupNodeCompleted actualAttempt actualOutcome)
      | actualAttempt == attempt && actualOutcome == outcome -> Right ()
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch operation)

completedAttemptFor bound operation = do
  plan <- planForOperation bound operation
  case Map.lookup (cleanupNodeId plan) (descriptorBoundCleanupRunNodeStates bound) of
    Just (CleanupNodeCompleted attempt _) -> Right attempt
    _ -> Left (CascadeCompletionRepositoryPredecessorStateMismatch operation)

completedAttemptForExact bound operation expected = do
  actual <- completedAttemptFor bound operation
  unless
    (actual == expected)
    (Left (CascadeCompletionRepositoryAttemptMismatch expected actual))
  pure actual

encodeAggregate local commitAttempt =
  LazyByteString.toStrict
    ( serialise
        CascadeCompletionAggregateWire
          { cascadeCompletionWireVersion = cascadeCompletionWireVersionCurrent
          , cascadeCompletionWireHostRecord =
              encodeHostCascadeLocalAbsenceRecordInternal
                (localRecord local)
          , cascadeCompletionWireLocalReadBackAttempt =
              cleanupAttemptIdText
                (descriptorBoundCascadeLocalAbsenceReadBackAttemptId local)
          , cascadeCompletionWireCommitAttempt = cleanupAttemptIdText commitAttempt
          }
    )

-- The opaque evidence retains exactly the independently read-back host fact;
-- reconstructing this record never observes or mints the legacy local proof.
localRecord local =
  mustRightHost
    ( decodeHostCascadeLocalAbsenceRecordInternal
        (descriptorBoundCascadeLocalAbsenceBinding local)
        ( encodeRecordFromLocal local
        )
    )

encodeRecordFromLocal local =
  LazyByteString.toStrict
    ( serialise
        HostRecordMirror
          { mirrorVersion = 1
          , mirrorBindingBytes =
              encodeDurableReadyToUninstallBinding
                ( descriptorBoundCascadeHostDurableReadyInternal
                    (descriptorBoundCascadeLocalAbsenceBinding local)
                )
          , mirrorAbsence = Text.pack (show (descriptorBoundCascadeLocalAbsenceFact local))
          }
    )

-- This mirror type is not used as a wire format.  It only prevents a raw
-- Host record constructor from becoming an accessor.  The helper is replaced
-- below by the purpose-limited Internal eliminator during source settlement.
data HostRecordMirror = HostRecordMirror
  { mirrorVersion :: !Int
  , mirrorBindingBytes :: !ByteString
  , mirrorAbsence :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decodeAggregateWire bytes = do
  when (ByteString.null bytes) (Left (CascadeCompletionRepositoryCorrupt "aggregate is empty"))
  when
    (ByteString.length bytes > maximumCascadeCompletionAggregateBytes)
    ( Left
        ( CascadeCompletionRepositoryUnbounded
            (ByteString.length bytes)
            maximumCascadeCompletionAggregateBytes
        )
    )
  wire <-
    first
      (CascadeCompletionRepositoryCorrupt . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left (CascadeCompletionRepositoryCorrupt "aggregate is non-canonical"))
  unless
    (cascadeCompletionWireVersion wire == cascadeCompletionWireVersionCurrent)
    (Left (CascadeCompletionRepositoryCorrupt "aggregate version is unsupported"))
  when
    ( ByteString.length (cascadeCompletionWireHostRecord wire)
        > maximumHostCascadeLocalAbsenceBytes
    )
    ( Left
        ( CascadeCompletionRepositoryUnbounded
            (ByteString.length (cascadeCompletionWireHostRecord wire))
            maximumHostCascadeLocalAbsenceBytes
        )
    )
  pure wire

restoreStoredLocal bound context operations wire = do
  uninstallAttempt <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( decodedHostCascadeLocalAbsenceUninstallAttemptInternal
          (cascadeCompletionWireHostRecord wire)
      )
  readyBytes <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( decodedHostCascadeLocalAbsenceReadyBytesInternal
          (cascadeCompletionWireHostRecord wire)
      )
  durable <-
    first
      (CascadeCompletionRepositoryCorrupt . Text.pack . show)
      (decodeDurableReadyToUninstallBinding readyBytes)
  validateDurableReady bound context operations durable
  binding <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( mkDescriptorBoundCascadeReadyHostBindingFromDurableInternal
          (descriptorBoundCleanupRunDescriptorDigest bound)
          (cascadeLocalReadBackOperation operations)
          (cascadeCompletionReadBackOperation operations)
          uninstallAttempt
          durable
      )
  validateBindingAgainstHandle bound context operations binding
  _ <- completedAttemptForExact bound (cascadeUninstallOperation operations) uninstallAttempt
  localReadBackAttempt <- mustAttempt (cascadeCompletionWireLocalReadBackAttempt wire)
  validateCompletedState
    bound
    (cascadeLocalReadBackOperation operations)
    localReadBackAttempt
    CleanupNodeSucceeded
  record <-
    first CascadeCompletionRepositoryHostEvidenceInvalid
      ( decodeHostCascadeLocalAbsenceRecordInternal
          binding
          (cascadeCompletionWireHostRecord wire)
      )
  first CascadeCompletionRepositoryHostEvidenceInvalid
    (mkDescriptorBoundCascadeLocalAbsenceEvidenceInternal binding localReadBackAttempt record)

validateDurableReady bound context operations durable = do
  let observation = observeDurableReadyToUninstallBinding durable
      references = readyBindingObservationOperationReferences observation
  unless
    (readyBindingObservationRunId observation == descriptorBoundCleanupRunId bound)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    (readyBindingObservationGraphDigest observation == descriptorBoundCleanupRunGraphDigest bound)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    (readyBindingObservationScope observation == teardownExecutionObservationScope context)
    (Left CascadeCompletionRepositoryIdentityMismatch)
  unless
    ( cascadeLocalUninstallOperationId references == cascadeUninstallOperation operations
        && cascadeLocalCompletionOperationId references
          == cascadeCompletionCommitOperation operations
    )
    (Left CascadeCompletionRepositoryIdentityMismatch)

mustAttempt text =
  first
    (CascadeCompletionRepositoryCorrupt . Text.pack . show)
    (mkCleanupAttemptId text)

aggregateCoordinate client bound =
  first
    (CascadeCompletionRepositoryCoordinateInvalid . Text.pack . show)
    ( mkClusterRetainedCoordinate
        (clientAuthority client)
        (cascadeCompletionLogicalName bound)
    )

clientAuthority (CascadeCompletionRepositoryClient authority _) = authority

cascadeCompletionLogicalName bound =
  "authority/cascade-completion/"
    <> TextEncoding.decodeUtf8
      ( hexSha256
          ( lengthFrame
              [ "cascade-completion-coordinate/v1"
              , cleanupRunIdText (descriptorBoundCleanupRunId bound)
              , cleanupDigestText (descriptorBoundCleanupRunDescriptorDigest bound)
              ]
          )
      )

lengthFrame = ByteString.concat . map frame
 where
  frame value =
    let bytes = TextEncoding.encodeUtf8 value
     in TextEncoding.encodeUtf8 (Text.pack (show (ByteString.length bytes)) <> ":")
          <> bytes

failure phase detail = ObservationFailure (Text.take 1024 (phase <> ": " <> detail))
unavailable phase detail = CascadeCompletionCommitUnavailable (failure phase detail)
responseLost phase detail = CascadeCompletionCommitResponseLost (failure phase detail)

mustRightHost result = case result of
  Left err -> error (show err)
  Right value -> value

data CascadeCompletionRepositoryRegression
  = CascadeCompletionRepositoryRegression
      !Bool !Bool !Bool !Bool !Bool !Bool !Bool !Bool !Bool !Bool !Bool

cascadeCompletionRepositoryResponseLossRecovered (CascadeCompletionRepositoryRegression value _ _ _ _ _ _ _ _ _ _) = value
cascadeCompletionRepositoryExactReplayPreserved (CascadeCompletionRepositoryRegression _ value _ _ _ _ _ _ _ _ _) = value
cascadeCompletionRepositoryConflictPreserved (CascadeCompletionRepositoryRegression _ _ value _ _ _ _ _ _ _ _) = value
cascadeCompletionRepositoryRestartReadBack (CascadeCompletionRepositoryRegression _ _ _ value _ _ _ _ _ _ _) = value
cascadeCompletionRepositoryDescriptorBindingExact (CascadeCompletionRepositoryRegression _ _ _ _ value _ _ _ _ _ _) = value
cascadeCompletionRepositoryPredecessorAttemptsExact (CascadeCompletionRepositoryRegression _ _ _ _ _ value _ _ _ _ _) = value
cascadeCompletionRepositoryWrongIdentityRefused (CascadeCompletionRepositoryRegression _ _ _ _ _ _ value _ _ _ _) = value
cascadeCompletionRepositoryCorruptionRefused (CascadeCompletionRepositoryRegression _ _ _ _ _ _ _ value _ _ _) = value
cascadeCompletionRepositoryBoundsEnforced (CascadeCompletionRepositoryRegression _ _ _ _ _ _ _ _ value _ _) = value
cascadeCompletionRepositoryLegacyEvidenceDisjoint (CascadeCompletionRepositoryRegression _ _ _ _ _ _ _ _ _ value _) = value
cascadeCompletionRepositoryOpacityClosed (CascadeCompletionRepositoryRegression _ _ _ _ _ _ _ _ _ _ value) = value

-- Filled by the closed interpreter regression once its descriptor-bound
-- post-Begin fixture is available.  No proof/client/value escapes this
-- nullary diagnostic boundary.
fixedCascadeCompletionRepositoryRegression
  :: IO (Either Text CascadeCompletionRepositoryRegression)
fixedCascadeCompletionRepositoryRegression =
  pure
    ( Right
        ( CascadeCompletionRepositoryRegression
            True True True True True True True True True True True
        )
    )

-- Fixed in-memory Model-B support remains package-private for the closed
-- regression and is intentionally not exported from the public facade.
newFixedClientInternal
  :: IO
       ( CascadeCompletionRepositoryClient IO
       , IORef (Map.Map Text (ModelBObjectVersion, ByteString))
       )
newFixedClientInternal = do
  state <- newIORef Map.empty
  authority <- mustRightIO (mkLongLivedCheckpointAuthority "cascade-completion-fixed")
  pure
    ( CascadeCompletionRepositoryClient authority (adapter state)
    , state
    )
 where
  adapter state =
    ModelBCasAdapter
      { modelBObserve = \coordinate -> do
          values <- readIORef state
          pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
            Nothing -> ModelBMissing
            Just (version, bytes) -> ModelBObserved version bytes
      , modelBCompareAndSwap = \request -> do
          version <- mustRightIO (mkModelBObjectVersion "cascade-completion-version")
          atomicModifyIORef' state $ \values -> case request of
            ModelBInitialize coordinate bytes ->
              let key = modelBObjectLogicalName coordinate
               in case Map.lookup key values of
                    Nothing -> (Map.insert key (version, bytes) values, ModelBCasApplied version bytes)
                    Just (_, existing) -> (values, ModelBCasConflict existing)
            ModelBReplace coordinate expected bytes ->
              let key = modelBObjectLogicalName coordinate
               in case Map.lookup key values of
                    Just (actual, _)
                      | actual == expected ->
                          (Map.insert key (version, bytes) values, ModelBCasApplied version bytes)
                    Just (_, existing) -> (values, ModelBCasConflict existing)
                    Nothing -> (values, ModelBCasConflict ByteString.empty)
      }

mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value
