{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

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
  , ServiceSessionWorkload
  , mkServiceSessionWorkload
  , serviceSessionWorkloadJobName
  , serviceSessionWorkloadJobUid
  , serviceSessionWorkloadPodName
  , serviceSessionWorkloadPodUid
  , serviceSessionWorkloadServiceAccountUid
  , WireTargetWorkerAttemptBinding (..)
  , ServiceSessionWorkloadEvidence
  , mkServiceSessionWorkloadEvidence
  , serviceSessionWorkloadEvidenceWorkload
  , serviceSessionWorkloadEvidenceAttempt
  , serviceSessionJournalWorkload
  , serviceSessionJournalWorkloadEvidence
  , ServiceSessionCreationReservation
  , mkServiceSessionCreationReservation
  , serviceSessionCreationOperationId
  , serviceSessionCreationJobName
  , serviceSessionCreationFence
  , ServiceSessionDispatchState (..)
  , serviceSessionJournalDispatchState
  , serviceSessionJournalRecoverableRetirement
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
import Data.Char (isAsciiLower, isControl, isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
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
import Prodbox.Lifecycle.Lease (OwnerNonce, mkOwnerNonce, ownerNonceText)
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest, targetValueDigestText)

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

-- | Non-secret exact Kubernetes identity retained with an external Target
-- worker session. It is not evidence that the workload has stopped.
data ServiceSessionWorkload = ServiceSessionWorkload
  { serviceSessionWorkloadJobName :: !Text
  , serviceSessionWorkloadJobUid :: !Text
  , serviceSessionWorkloadPodName :: !Text
  , serviceSessionWorkloadPodUid :: !Text
  , serviceSessionWorkloadServiceAccountUid :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- This is the exact version-1 preimage already used by the signed worker
-- permit. Moving its definition does not change its canonical encoding.
data WireTargetWorkerAttemptBinding = WireTargetWorkerAttemptBinding
  { wireAttemptVersion :: !Word16
  , wireAttemptAgentIdentity :: !Text
  , wireAttemptDeploymentUid :: !Text
  , wireAttemptDeploymentGeneration :: !Natural
  , wireAttemptObservedDeploymentGeneration :: !Natural
  , wireAttemptObservedRolloutDigest :: !Text
  , wireAttemptJobName :: !Text
  , wireAttemptJobUid :: !Text
  , wireAttemptPodName :: !Text
  , wireAttemptPodUid :: !Text
  , wireAttemptServiceAccount :: !Text
  , wireAttemptServiceAccountUid :: !Text
  , wireAttemptImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ServiceSessionWorkloadEvidence = ServiceSessionWorkloadEvidence
  { serviceSessionWorkloadEvidenceWorkload :: !ServiceSessionWorkload
  , serviceSessionWorkloadEvidenceAttempt :: !WireTargetWorkerAttemptBinding
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkServiceSessionWorkloadEvidence
  :: ServiceSessionWorkload
  -> WireTargetWorkerAttemptBinding
  -> Either ServiceSessionJournalError ServiceSessionWorkloadEvidence
mkServiceSessionWorkloadEvidence workload attempt = do
  validateWorkload workload
  unless
    ( wireAttemptVersion attempt == 1
        && wireAttemptJobName attempt == serviceSessionWorkloadJobName workload
        && wireAttemptJobUid attempt == serviceSessionWorkloadJobUid workload
        && wireAttemptPodName attempt == serviceSessionWorkloadPodName workload
        && wireAttemptPodUid attempt == serviceSessionWorkloadPodUid workload
        && wireAttemptServiceAccount attempt == targetSecretWorkerVaultRole
        && wireAttemptServiceAccountUid attempt == serviceSessionWorkloadServiceAccountUid workload
        && wireAttemptDeploymentGeneration attempt > 0
        && wireAttemptObservedDeploymentGeneration attempt == wireAttemptDeploymentGeneration attempt
    )
    (Left ServiceSessionJournalInvariantInvalid)
  _ <- validateIdentity "attempt-agent" 512 (wireAttemptAgentIdentity attempt)
  _ <- validateIdentity "attempt-deployment-uid" 128 (wireAttemptDeploymentUid attempt)
  _ <- validateIdentity "attempt-rollout-digest" 512 (wireAttemptObservedRolloutDigest attempt)
  _ <- validateIdentity "attempt-image-digest" 128 (wireAttemptImageDigest attempt)
  pure (ServiceSessionWorkloadEvidence workload attempt)

mkServiceSessionWorkload
  :: Text -> Text -> Text -> Text -> Text -> Either ServiceSessionJournalError ServiceSessionWorkload
mkServiceSessionWorkload jobName jobUid podName podUid serviceAccountUid = do
  validJob <- validateWorkloadName "job-name" jobName
  validJobUid <- validateIdentity "job-uid" 128 jobUid
  validPod <- validateWorkloadName "pod-name" podName
  validPodUid <- validateIdentity "pod-uid" 128 podUid
  validServiceAccountUid <- validateIdentity "service-account-uid" 128 serviceAccountUid
  pure (ServiceSessionWorkload validJob validJobUid validPod validPodUid validServiceAccountUid)

validateWorkloadName :: Text -> Text -> Either ServiceSessionJournalError Text
validateWorkloadName label raw = do
  value <- validateIdentity label 253 raw
  if Text.all
    (\character -> isAsciiLower character || isDigit character || character == '-' || character == '.')
    value
    then Right value
    else Left (ServiceSessionIdentityInvalid label)

data ServiceSessionCreationReservation = ServiceSessionCreationReservation
  { serviceSessionCreationOperationId :: !Text
  , serviceSessionCreationJobName :: !Text
  , serviceSessionCreationFence :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkServiceSessionCreationReservation
  :: Text -> Text -> Natural -> Either ServiceSessionJournalError ServiceSessionCreationReservation
mkServiceSessionCreationReservation operation job fence = do
  let lowerHex character = isDigit character || character `elem` ['a' .. 'f']
  unless
    ( Text.length operation == 64
        && Text.all lowerHex operation
        && job == "target-secret-" <> Text.take 40 operation
        && fence > 0
    )
    (Left ServiceSessionJournalInvariantInvalid)
  pure (ServiceSessionCreationReservation operation job fence)

data ServiceSessionDispatchState
  = ServiceSessionDispatchReady
  | ServiceSessionDispatchIssued
  | ServiceSessionDispatchSettled
  | ServiceSessionWorkloadRetired
  | ServiceSessionDispatchCleanupOwned !OwnerNonce
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ServiceSessionPhase
  = ServiceSessionVacant !Natural
  | ServiceSessionAcquiring !ServiceSessionBinding
  | ServiceSessionPrecleaned !ServiceSessionBinding
  | ServiceSessionLoginAttemptCommitted !ServiceSessionBinding
  | ServiceSessionActive !ServiceSessionBinding !Text
  | ServiceSessionCleanupRequired !ServiceSessionBinding !(Maybe Text)
  | ServiceSessionCleanupProven !ServiceSessionBinding
  | ServiceSessionWorkloadOwned !ServiceSessionPhase !ServiceSessionWorkload
  | ServiceSessionVerifiedWorkloadOwned !ServiceSessionPhase !ServiceSessionWorkloadEvidence
  | ServiceSessionCreationReserved !ServiceSessionCreationReservation
  | ServiceSessionDispatchOwned
      !ServiceSessionPhase
      !ServiceSessionWorkloadEvidence
      !ServiceSessionDispatchState
  | ServiceSessionCreationPrepared !ServiceSessionCreationReservation
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

serviceSessionWorkloadJournalVersion :: Word16
serviceSessionWorkloadJournalVersion = 2

serviceSessionVerifiedWorkloadJournalVersion :: Word16
serviceSessionVerifiedWorkloadJournalVersion = 3

serviceSessionCreationJournalVersion :: Word16
serviceSessionCreationJournalVersion = 4

serviceSessionDispatchJournalVersion :: Word16
serviceSessionDispatchJournalVersion = 5

serviceSessionRetirementJournalVersion :: Word16
serviceSessionRetirementJournalVersion = 6

serviceSessionCleanupOwnerJournalVersion :: Word16
serviceSessionCleanupOwnerJournalVersion = 7

serviceSessionCreationPreparedJournalVersion :: Word16
serviceSessionCreationPreparedJournalVersion = 8

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
serviceSessionJournalPhase journal = case internalServiceSessionJournalPhase journal of
  ServiceSessionWorkloadOwned phase _ -> phase
  ServiceSessionVerifiedWorkloadOwned phase _ -> phase
  ServiceSessionDispatchOwned phase _ _ -> phase
  phase -> phase

serviceSessionJournalWorkload :: ServiceSessionJournal -> Maybe ServiceSessionWorkload
serviceSessionJournalWorkload journal = case internalServiceSessionJournalPhase journal of
  ServiceSessionWorkloadOwned _ workload -> Just workload
  ServiceSessionVerifiedWorkloadOwned _ evidence -> Just (serviceSessionWorkloadEvidenceWorkload evidence)
  ServiceSessionDispatchOwned _ evidence _ -> Just (serviceSessionWorkloadEvidenceWorkload evidence)
  _ -> Nothing

serviceSessionJournalWorkloadEvidence
  :: ServiceSessionJournal -> Maybe ServiceSessionWorkloadEvidence
serviceSessionJournalWorkloadEvidence journal = case internalServiceSessionJournalPhase journal of
  ServiceSessionVerifiedWorkloadOwned _ evidence -> Just evidence
  ServiceSessionDispatchOwned _ evidence _ -> Just evidence
  _ -> Nothing

serviceSessionJournalDispatchState :: ServiceSessionJournal -> Maybe ServiceSessionDispatchState
serviceSessionJournalDispatchState journal = case internalServiceSessionJournalPhase journal of
  ServiceSessionDispatchOwned _ _ state -> Just state
  _ -> Nothing

-- | Only current-format unclaimed retirements can be considered for replay.
-- This is a candidate, not evidence that the workload is physically fenced.
serviceSessionJournalRecoverableRetirement
  :: ServiceSessionJournal -> Maybe (ServiceSessionBinding, ServiceSessionWorkload)
serviceSessionJournalRecoverableRetirement journal =
  case internalServiceSessionJournalPhase journal of
    ServiceSessionDispatchOwned phase evidence ServiceSessionWorkloadRetired
      | internalServiceSessionJournalVersion journal == serviceSessionCleanupOwnerJournalVersion ->
          fmap
            (,serviceSessionWorkloadEvidenceWorkload evidence)
            (phaseBindingForRecovery phase)
    _ -> Nothing
 where
  phaseBindingForRecovery phase = case phase of
    ServiceSessionAcquiring binding -> Just binding
    ServiceSessionPrecleaned binding -> Just binding
    ServiceSessionLoginAttemptCommitted binding -> Just binding
    ServiceSessionActive binding _ -> Just binding
    _ -> Nothing

data ServiceSessionEvent
  = BeginServiceSessionAcquisition !ServiceSessionBinding
  | BeginServiceSessionWorkload !ServiceSessionBinding !ServiceSessionWorkload
  | BeginServiceSessionVerifiedWorkload !ServiceSessionBinding !ServiceSessionWorkloadEvidence
  | ReserveServiceSessionCreation !ServiceSessionCreationReservation
  | IssueServiceSessionCreation !ServiceSessionCreationReservation
  | ReleasePreparedServiceSessionCreation !ServiceSessionCreationReservation
  | BindServiceSessionCreation
      !ServiceSessionCreationReservation
      !ServiceSessionBinding
      !ServiceSessionWorkloadEvidence
  | BeginServiceSessionDispatch !ServiceSessionBinding
  | SettleServiceSessionDispatch !ServiceSessionBinding
  | RetireServiceSessionWorkload !ServiceSessionBinding !ServiceSessionWorkload
  | ClaimServiceSessionCleanup !ServiceSessionBinding !OwnerNonce
  | RequireOwnedServiceSessionCleanup !ServiceSessionBinding !OwnerNonce
  | ProveOwnedServiceSessionCleanup !ServiceSessionBinding !OwnerNonce
  | ReleaseOwnedServiceSession !ServiceSessionBinding !OwnerNonce
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
  case internalServiceSessionJournalPhase journal of
    ServiceSessionWorkloadOwned phase workload -> do
      next <- stepUnwrapped event (journal {internalServiceSessionJournalPhase = phase})
      case internalServiceSessionJournalPhase next of
        ServiceSessionVacant _ -> pure next
        nextPhase -> pure next {internalServiceSessionJournalPhase = ServiceSessionWorkloadOwned nextPhase workload}
    ServiceSessionVerifiedWorkloadOwned phase evidence -> do
      next <- stepUnwrapped event (journal {internalServiceSessionJournalPhase = phase})
      case internalServiceSessionJournalPhase next of
        ServiceSessionVacant _ -> pure next
        nextPhase ->
          pure
            next {internalServiceSessionJournalPhase = ServiceSessionVerifiedWorkloadOwned nextPhase evidence}
    ServiceSessionDispatchOwned phase evidence state ->
      case event of
        ClaimServiceSessionCleanup binding owner -> do
          rebuiltOwner <-
            either
              (const (Left ServiceSessionJournalInvariantInvalid))
              Right
              (mkOwnerNonce (ownerNonceText owner))
          unless (rebuiltOwner == owner) (Left ServiceSessionJournalInvariantInvalid)
          case (state, phase) of
            (ServiceSessionWorkloadRetired, ServiceSessionAcquiring existing) | existing == binding -> claimed owner
            (ServiceSessionWorkloadRetired, ServiceSessionPrecleaned existing) | existing == binding -> claimed owner
            (ServiceSessionWorkloadRetired, ServiceSessionLoginAttemptCommitted existing) | existing == binding -> claimed owner
            (ServiceSessionWorkloadRetired, ServiceSessionActive existing _) | existing == binding -> claimed owner
            _ -> Left ServiceSessionTransitionConflict
         where
          claimed selectedOwner =
            pure
              journal
                { internalServiceSessionJournalVersion = serviceSessionCleanupOwnerJournalVersion
                , internalServiceSessionJournalPhase =
                    ServiceSessionDispatchOwned phase evidence (ServiceSessionDispatchCleanupOwned selectedOwner)
                }
        RequireOwnedServiceSessionCleanup binding owner -> stepOwnedCleanup journal phase evidence state owner (RequireServiceSessionCleanup binding)
        ProveOwnedServiceSessionCleanup binding owner -> stepOwnedCleanup journal phase evidence state owner (CommitServiceSessionCleanupProven binding)
        ReleaseOwnedServiceSession binding owner -> stepOwnedCleanup journal phase evidence state owner (ReleaseServiceSession binding)
        RetireServiceSessionWorkload binding workload
          | workload /= serviceSessionWorkloadEvidenceWorkload evidence ->
              Left ServiceSessionJournalInvariantInvalid
          | otherwise -> case (state, phase) of
              (ServiceSessionDispatchReady, ServiceSessionAcquiring existing) | existing == binding -> retired
              (ServiceSessionDispatchReady, ServiceSessionPrecleaned existing) | existing == binding -> retired
              (ServiceSessionDispatchReady, ServiceSessionLoginAttemptCommitted existing) | existing == binding -> retired
              (ServiceSessionDispatchSettled, ServiceSessionActive existing _) | existing == binding -> retired
              _ -> Left ServiceSessionTransitionConflict
         where
          retired
            | internalServiceSessionJournalVersion journal
                `elem` [serviceSessionRetirementJournalVersion, serviceSessionCleanupOwnerJournalVersion] =
                pure
                  journal
                    { internalServiceSessionJournalPhase =
                        ServiceSessionDispatchOwned phase evidence ServiceSessionWorkloadRetired
                    }
            | otherwise = Left ServiceSessionTransitionConflict
        BeginServiceSessionDispatch binding ->
          case (state, phase) of
            (ServiceSessionDispatchReady, ServiceSessionLoginAttemptCommitted existing)
              | existing == binding ->
                  pure
                    journal
                      { internalServiceSessionJournalPhase =
                          ServiceSessionDispatchOwned phase evidence ServiceSessionDispatchIssued
                      }
            _ -> Left ServiceSessionTransitionConflict
        SettleServiceSessionDispatch binding ->
          case (state, phase) of
            (ServiceSessionDispatchIssued, ServiceSessionActive existing _)
              | existing == binding ->
                  pure
                    journal
                      { internalServiceSessionJournalPhase =
                          ServiceSessionDispatchOwned phase evidence ServiceSessionDispatchSettled
                      }
            (ServiceSessionDispatchSettled, ServiceSessionActive existing _)
              | existing == binding -> Right journal
            _ -> Left ServiceSessionTransitionConflict
        _ -> do
          unless (allowedDispatchEvent state event) (Left ServiceSessionTransitionConflict)
          next <- stepUnwrapped event (journal {internalServiceSessionJournalPhase = phase})
          case internalServiceSessionJournalPhase next of
            ServiceSessionVacant _ -> pure next
            nextPhase ->
              pure
                next {internalServiceSessionJournalPhase = ServiceSessionDispatchOwned nextPhase evidence state}
    _ -> stepUnwrapped event journal

stepOwnedCleanup
  :: ServiceSessionJournal
  -> ServiceSessionPhase
  -> ServiceSessionWorkloadEvidence
  -> ServiceSessionDispatchState
  -> OwnerNonce
  -> ServiceSessionEvent
  -> Either ServiceSessionJournalError ServiceSessionJournal
stepOwnedCleanup journal phase evidence state owner event = do
  unless (state == ServiceSessionDispatchCleanupOwned owner) (Left ServiceSessionTransitionConflict)
  next <- stepUnwrapped event (journal {internalServiceSessionJournalPhase = phase})
  case internalServiceSessionJournalPhase next of
    ServiceSessionVacant _ -> pure next
    nextPhase ->
      pure
        next {internalServiceSessionJournalPhase = ServiceSessionDispatchOwned nextPhase evidence state}

allowedDispatchEvent :: ServiceSessionDispatchState -> ServiceSessionEvent -> Bool
allowedDispatchEvent state event = case event of
  CommitServiceSessionPrecleaned _ -> state == ServiceSessionDispatchReady
  CommitServiceSessionLoginAttempt _ -> state == ServiceSessionDispatchReady
  CommitServiceSessionActive _ _ -> state == ServiceSessionDispatchIssued
  RequireServiceSessionCleanup _ -> False
  CommitServiceSessionCleanupProven _ -> False
  ReleaseServiceSession _ -> False
  _ -> False

stepUnwrapped
  :: ServiceSessionEvent
  -> ServiceSessionJournal
  -> Either ServiceSessionJournalError ServiceSessionJournal
stepUnwrapped event journal = do
  let role = serviceSessionJournalRole journal
      phase = serviceSessionJournalPhase journal
      setPhase next = journal {internalServiceSessionJournalPhase = next}
      validateBinding binding =
        unless
          (serviceSessionBindingRole binding == role)
          (Left ServiceSessionRoleMismatch)
  case event of
    BeginServiceSessionDispatch _ -> Left ServiceSessionTransitionConflict
    SettleServiceSessionDispatch _ -> Left ServiceSessionTransitionConflict
    RetireServiceSessionWorkload _ _ -> Left ServiceSessionTransitionConflict
    ClaimServiceSessionCleanup _ _ -> Left ServiceSessionTransitionConflict
    RequireOwnedServiceSessionCleanup _ _ -> Left ServiceSessionTransitionConflict
    ProveOwnedServiceSessionCleanup _ _ -> Left ServiceSessionTransitionConflict
    ReleaseOwnedServiceSession _ _ -> Left ServiceSessionTransitionConflict
    -- Version 8 describes only the pre-issue state. Once it is consumed,
    -- retain the established version-7 issued or vacant wire shape.
    IssueServiceSessionCreation reservation -> case phase of
      ServiceSessionCreationPrepared existing
        | existing == reservation
            && internalServiceSessionJournalVersion journal == serviceSessionCreationPreparedJournalVersion ->
            Right
              journal
                { internalServiceSessionJournalVersion = serviceSessionCleanupOwnerJournalVersion
                , internalServiceSessionJournalPhase = ServiceSessionCreationReserved reservation
                }
      _ -> Left ServiceSessionTransitionConflict
    ReleasePreparedServiceSessionCreation reservation -> case phase of
      ServiceSessionCreationPrepared existing
        | existing == reservation
            && internalServiceSessionJournalVersion journal == serviceSessionCreationPreparedJournalVersion ->
            Right
              journal
                { internalServiceSessionJournalVersion = serviceSessionCleanupOwnerJournalVersion
                , internalServiceSessionJournalPhase = ServiceSessionVacant (serviceSessionCreationFence reservation)
                }
      _ -> Left ServiceSessionTransitionConflict
    ReserveServiceSessionCreation reservation -> do
      unless (role == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      rebuilt <-
        mkServiceSessionCreationReservation
          (serviceSessionCreationOperationId reservation)
          (serviceSessionCreationJobName reservation)
          (serviceSessionCreationFence reservation)
      unless (rebuilt == reservation) (Left ServiceSessionJournalInvariantInvalid)
      case phase of
        ServiceSessionVacant previousFence
          | serviceSessionCreationFence reservation > previousFence ->
              pure
                journal
                  { internalServiceSessionJournalVersion = serviceSessionCreationPreparedJournalVersion
                  , internalServiceSessionJournalPhase = ServiceSessionCreationPrepared reservation
                  }
          | otherwise ->
              Left (ServiceSessionFenceStale previousFence (serviceSessionCreationFence reservation))
        _ -> Left ServiceSessionTransitionConflict
    BindServiceSessionCreation reservation binding evidence -> do
      validateBinding binding
      unless (role == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      validateWorkloadEvidenceBinding binding evidence
      unless
        ( serviceSessionBindingOperationId binding == serviceSessionCreationOperationId reservation
            && serviceSessionBindingFence binding == serviceSessionCreationFence reservation
            && serviceSessionWorkloadJobName (serviceSessionWorkloadEvidenceWorkload evidence)
              == serviceSessionCreationJobName reservation
        )
        (Left ServiceSessionJournalInvariantInvalid)
      case phase of
        ServiceSessionCreationReserved existing
          | existing == reservation
              && internalServiceSessionJournalVersion journal == serviceSessionCleanupOwnerJournalVersion ->
              pure
                ( setPhase
                    (ServiceSessionDispatchOwned (ServiceSessionAcquiring binding) evidence ServiceSessionDispatchReady)
                )
        _ -> Left ServiceSessionTransitionConflict
    BeginServiceSessionVerifiedWorkload binding evidence -> do
      validateBinding binding
      unless (role == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      when
        (internalServiceSessionJournalVersion journal >= serviceSessionCreationJournalVersion)
        (Left ServiceSessionJournalInvariantInvalid)
      validateWorkloadEvidenceBinding binding evidence
      case phase of
        ServiceSessionVacant previousFence
          | serviceSessionBindingFence binding > previousFence ->
              pure
                ( journal
                    { internalServiceSessionJournalVersion = serviceSessionVerifiedWorkloadJournalVersion
                    , internalServiceSessionJournalPhase =
                        ServiceSessionVerifiedWorkloadOwned (ServiceSessionAcquiring binding) evidence
                    }
                )
          | otherwise -> Left (ServiceSessionFenceStale previousFence (serviceSessionBindingFence binding))
        _ -> Left ServiceSessionTransitionConflict
    BeginServiceSessionWorkload binding workload -> do
      validateBinding binding
      unless (role == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      when
        (internalServiceSessionJournalVersion journal >= serviceSessionVerifiedWorkloadJournalVersion)
        (Left ServiceSessionJournalInvariantInvalid)
      validateWorkload workload
      validateWorkloadBinding binding workload
      case phase of
        ServiceSessionVacant previousFence
          | serviceSessionBindingFence binding > previousFence ->
              pure
                ( journal
                    { internalServiceSessionJournalVersion = serviceSessionWorkloadJournalVersion
                    , internalServiceSessionJournalPhase =
                        ServiceSessionWorkloadOwned (ServiceSessionAcquiring binding) workload
                    }
                )
          | otherwise -> Left (ServiceSessionFenceStale previousFence (serviceSessionBindingFence binding))
        _ -> Left ServiceSessionTransitionConflict
    BeginServiceSessionAcquisition binding -> do
      validateBinding binding
      when
        ( role == targetSecretWorkerVaultRole
            && internalServiceSessionJournalVersion journal >= serviceSessionWorkloadJournalVersion
        )
        (Left ServiceSessionJournalInvariantInvalid)
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
  unless
    ( internalServiceSessionJournalVersion journal
        `elem` [ serviceSessionJournalVersion
               , serviceSessionWorkloadJournalVersion
               , serviceSessionVerifiedWorkloadJournalVersion
               , serviceSessionCreationJournalVersion
               , serviceSessionDispatchJournalVersion
               , serviceSessionRetirementJournalVersion
               , serviceSessionCleanupOwnerJournalVersion
               , serviceSessionCreationPreparedJournalVersion
               ]
    )
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
    ( internalServiceSessionJournalVersion journal
        `elem` [ serviceSessionJournalVersion
               , serviceSessionWorkloadJournalVersion
               , serviceSessionVerifiedWorkloadJournalVersion
               , serviceSessionCreationJournalVersion
               , serviceSessionDispatchJournalVersion
               , serviceSessionRetirementJournalVersion
               , serviceSessionCleanupOwnerJournalVersion
               , serviceSessionCreationPreparedJournalVersion
               ]
    )
    (Left ServiceSessionJournalInvariantInvalid)
  validRole <-
    validateIdentity "worker-role" 160 (serviceSessionJournalRole journal)
  when
    ( internalServiceSessionJournalVersion journal >= serviceSessionWorkloadJournalVersion
        && validRole /= targetSecretWorkerVaultRole
    )
    (Left ServiceSessionJournalInvariantInvalid)
  when (internalServiceSessionJournalVersion journal == serviceSessionCreationPreparedJournalVersion) $
    case internalServiceSessionJournalPhase journal of
      ServiceSessionCreationPrepared _ -> pure ()
      _ -> Left ServiceSessionJournalInvariantInvalid
  case internalServiceSessionJournalPhase journal of
    ServiceSessionWorkloadOwned inner workload -> do
      unless
        (internalServiceSessionJournalVersion journal == serviceSessionWorkloadJournalVersion)
        (Left ServiceSessionJournalInvariantInvalid)
      unless (validRole == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      case inner of
        ServiceSessionVacant _ -> Left ServiceSessionJournalInvariantInvalid
        ServiceSessionWorkloadOwned _ _ -> Left ServiceSessionJournalInvariantInvalid
        _ -> pure ()
      validateWorkload workload
      case inner of
        ServiceSessionAcquiring binding -> validateWorkloadBinding binding workload
        ServiceSessionPrecleaned binding -> validateWorkloadBinding binding workload
        ServiceSessionLoginAttemptCommitted binding -> validateWorkloadBinding binding workload
        ServiceSessionActive binding _ -> validateWorkloadBinding binding workload
        ServiceSessionCleanupRequired binding _ -> validateWorkloadBinding binding workload
        ServiceSessionCleanupProven binding -> validateWorkloadBinding binding workload
        _ -> Left ServiceSessionJournalInvariantInvalid
      validatePhase validRole inner
    ServiceSessionVerifiedWorkloadOwned inner evidence -> do
      unless
        ( internalServiceSessionJournalVersion journal
            `elem` [serviceSessionVerifiedWorkloadJournalVersion, serviceSessionCreationJournalVersion]
        )
        (Left ServiceSessionJournalInvariantInvalid)
      unless (validRole == targetSecretWorkerVaultRole) (Left ServiceSessionRoleMismatch)
      binding <- case inner of
        ServiceSessionAcquiring value -> Right value
        ServiceSessionPrecleaned value -> Right value
        ServiceSessionLoginAttemptCommitted value -> Right value
        ServiceSessionActive value _ -> Right value
        ServiceSessionCleanupRequired value _ -> Right value
        ServiceSessionCleanupProven value -> Right value
        _ -> Left ServiceSessionJournalInvariantInvalid
      validateWorkloadEvidenceBinding binding evidence
      validatePhase validRole inner
    ServiceSessionDispatchOwned inner evidence state -> do
      unless
        ( internalServiceSessionJournalVersion journal
            `elem` [ serviceSessionDispatchJournalVersion
                   , serviceSessionRetirementJournalVersion
                   , serviceSessionCleanupOwnerJournalVersion
                   ]
            && validRole == targetSecretWorkerVaultRole
        )
        (Left ServiceSessionJournalInvariantInvalid)
      binding <- case (state, inner) of
        (ServiceSessionDispatchReady, ServiceSessionAcquiring value) -> Right value
        (ServiceSessionDispatchReady, ServiceSessionPrecleaned value) -> Right value
        (ServiceSessionDispatchReady, ServiceSessionLoginAttemptCommitted value) -> Right value
        (ServiceSessionDispatchIssued, ServiceSessionLoginAttemptCommitted value) -> Right value
        (ServiceSessionDispatchIssued, ServiceSessionActive value _) -> Right value
        (ServiceSessionDispatchSettled, ServiceSessionActive value _) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionAcquiring value) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionPrecleaned value) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionLoginAttemptCommitted value) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionActive value _) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionCleanupRequired value _) -> Right value
        (ServiceSessionWorkloadRetired, ServiceSessionCleanupProven value) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionAcquiring value) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionPrecleaned value) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionLoginAttemptCommitted value) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionActive value _) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionCleanupRequired value _) -> Right value
        (ServiceSessionDispatchCleanupOwned _, ServiceSessionCleanupProven value) -> Right value
        (ServiceSessionDispatchReady, ServiceSessionCleanupRequired value _) -> Right value
        (ServiceSessionDispatchSettled, ServiceSessionCleanupRequired value _) -> Right value
        (ServiceSessionDispatchReady, ServiceSessionCleanupProven value) -> Right value
        (ServiceSessionDispatchSettled, ServiceSessionCleanupProven value) -> Right value
        _ -> Left ServiceSessionJournalInvariantInvalid
      when
        ( state == ServiceSessionWorkloadRetired
            && internalServiceSessionJournalVersion journal
              `notElem` [serviceSessionRetirementJournalVersion, serviceSessionCleanupOwnerJournalVersion]
        )
        (Left ServiceSessionJournalInvariantInvalid)
      case state of
        ServiceSessionDispatchCleanupOwned owner -> do
          unless
            (internalServiceSessionJournalVersion journal == serviceSessionCleanupOwnerJournalVersion)
            (Left ServiceSessionJournalInvariantInvalid)
          rebuiltOwner <-
            either
              (const (Left ServiceSessionJournalInvariantInvalid))
              Right
              (mkOwnerNonce (ownerNonceText owner))
          unless (rebuiltOwner == owner) (Left ServiceSessionJournalInvariantInvalid)
        _ -> pure ()
      validateWorkloadEvidenceBinding binding evidence
      validatePhase validRole inner
    ServiceSessionCreationPrepared reservation -> do
      unless
        ( internalServiceSessionJournalVersion journal == serviceSessionCreationPreparedJournalVersion
            && validRole == targetSecretWorkerVaultRole
        )
        (Left ServiceSessionJournalInvariantInvalid)
      rebuilt <-
        mkServiceSessionCreationReservation
          (serviceSessionCreationOperationId reservation)
          (serviceSessionCreationJobName reservation)
          (serviceSessionCreationFence reservation)
      unless (rebuilt == reservation) (Left ServiceSessionJournalInvariantInvalid)
    ServiceSessionCreationReserved reservation -> do
      unless
        ( internalServiceSessionJournalVersion journal
            `elem` [ serviceSessionCreationJournalVersion
                   , serviceSessionDispatchJournalVersion
                   , serviceSessionRetirementJournalVersion
                   , serviceSessionCleanupOwnerJournalVersion
                   ]
            && validRole == targetSecretWorkerVaultRole
        )
        (Left ServiceSessionJournalInvariantInvalid)
      rebuilt <-
        mkServiceSessionCreationReservation
          (serviceSessionCreationOperationId reservation)
          (serviceSessionCreationJobName reservation)
          (serviceSessionCreationFence reservation)
      unless (rebuilt == reservation) (Left ServiceSessionJournalInvariantInvalid)
    phase -> do
      case phase of
        ServiceSessionVacant _ -> pure ()
        _ ->
          when
            ( validRole == targetSecretWorkerVaultRole
                && internalServiceSessionJournalVersion journal >= serviceSessionWorkloadJournalVersion
            )
            (Left ServiceSessionJournalInvariantInvalid)
      validatePhase validRole phase
 where
  validatePhase role phase = case phase of
    ServiceSessionVacant _ -> pure ()
    ServiceSessionAcquiring binding -> validateBound role binding
    ServiceSessionPrecleaned binding -> validateBound role binding
    ServiceSessionLoginAttemptCommitted binding -> validateBound role binding
    ServiceSessionActive binding accessor -> do
      validateBound role binding
      _ <- validateAccessor accessor
      pure ()
    ServiceSessionCleanupRequired binding maybeAccessor -> do
      validateBound role binding
      case maybeAccessor of
        Nothing -> pure ()
        Just accessor -> do
          _ <- validateAccessor accessor
          pure ()
    ServiceSessionCleanupProven binding -> validateBound role binding
    ServiceSessionWorkloadOwned _ _ -> Left ServiceSessionJournalInvariantInvalid
    ServiceSessionVerifiedWorkloadOwned _ _ -> Left ServiceSessionJournalInvariantInvalid
    ServiceSessionCreationReserved _ -> Left ServiceSessionJournalInvariantInvalid
    ServiceSessionCreationPrepared _ -> Left ServiceSessionJournalInvariantInvalid
    ServiceSessionDispatchOwned {} -> Left ServiceSessionJournalInvariantInvalid
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

validateWorkload :: ServiceSessionWorkload -> Either ServiceSessionJournalError ()
validateWorkload workload = do
  rebuilt <-
    mkServiceSessionWorkload
      (serviceSessionWorkloadJobName workload)
      (serviceSessionWorkloadJobUid workload)
      (serviceSessionWorkloadPodName workload)
      (serviceSessionWorkloadPodUid workload)
      (serviceSessionWorkloadServiceAccountUid workload)
  unless (rebuilt == workload) (Left ServiceSessionJournalInvariantInvalid)

validateWorkloadBinding
  :: ServiceSessionBinding -> ServiceSessionWorkload -> Either ServiceSessionJournalError ()
validateWorkloadBinding binding workload = do
  let digest = serviceSessionBindingOperationId binding
      lowerHex character = isDigit character || character `elem` ['a' .. 'f']
  unless
    ( Text.length digest == 64
        && Text.all lowerHex digest
        && serviceSessionWorkloadJobName workload == "target-secret-" <> Text.take 40 digest
    )
    (Left ServiceSessionJournalInvariantInvalid)

validateWorkloadEvidenceBinding
  :: ServiceSessionBinding -> ServiceSessionWorkloadEvidence -> Either ServiceSessionJournalError ()
validateWorkloadEvidenceBinding binding evidence = do
  let workload = serviceSessionWorkloadEvidenceWorkload evidence
      attempt = serviceSessionWorkloadEvidenceAttempt evidence
      attemptDigest = targetValueDigestText (sha256TargetValueDigest (LazyByteString.toStrict (serialise attempt)))
  validateWorkloadBinding binding workload
  rebuilt <- mkServiceSessionWorkloadEvidence workload attempt
  unless
    (rebuilt == evidence && serviceSessionBindingAttemptId binding == attemptDigest)
    (Left ServiceSessionJournalInvariantInvalid)

validateAccessor :: Text -> Either ServiceSessionJournalError Text
validateAccessor raw =
  case validateIdentity "accessor" 256 raw of
    Left _ -> Left ServiceSessionAccessorInvalid
    Right value -> Right value

firstText :: (Show errorValue) => Either errorValue value -> Either Text value
firstText = either (Left . Text.pack . show) Right
