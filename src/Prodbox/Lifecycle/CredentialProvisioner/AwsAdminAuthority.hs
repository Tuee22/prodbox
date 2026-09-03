{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Durable Lifecycle-Authority outbox for one AWS-admin Credential
-- Provisioner operation.  Every retained value is secret-free.  In
-- particular, administrator credentials and generated access-key material are
-- never representable in this state machine.
--
-- The ordering is load-bearing: the exact prepared Target outbox commits
-- before Kubernetes attestation, attestation commits before Transit signs the
-- permit, and the exact signed permit commits before a worker receipt can
-- settle the operation.  Exact replay is idempotent and every divergent replay
-- is refused.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorityState (..)
  , initialAwsAdminAuthorityState
  , awsAdminAuthorityCurrentIntent
  , awsAdminAuthorityCurrentPermit
  , commitAwsAdminPrepared
  , commitAwsAdminPreparedRenewal
  , awsAdminPreparedRenewalBindingsMatch
  , AwsAdminAttemptResourceObservation (..)
  , AwsAdminRecoveryCleanupPhase (..)
  , AwsAdminAttemptJournalObservation (..)
  , AwsAdminAuthorizedRecoveryError (..)
  , AwsAdminAuthorizedRecoveryProof
  , proveAwsAdminAuthorizedRecovery
  , bindAwsAdminPreparedRenewalIntent
  , bindAwsAdminAuthorizedRecoveryIntent
  , commitAwsAdminPreparedAuthorizedRecovery
  , commitAwsAdminAttested
  , commitAwsAdminAuthorized
  , commitAwsAdminCompleted
  , AwsAdminAuthorityStateError (..)
  , encodeAwsAdminAuthorityState
  , decodeAwsAdminAuthorityState
  , awsAdminAuthorityStateCodec
  , AwsAdminAuthoritySnapshot (..)
  , AwsAdminAuthorityRepository (..)
  , modelBAwsAdminAuthorityRepository
  , AwsAdminPreparedTargetBoundary (..)
  , AwsAdminAuthorityRepositoryError (..)
  , prepareAwsAdminAuthority
  , prepareAwsAdminAuthorityRenewal
  , prepareAwsAdminAuthorityAuthorizedRecovery
  , attestAwsAdminAuthority
  , authorizeAwsAdminAuthority
  , completeAwsAdminAuthority
  , observeAwsAdminAuthority
  , AwsAdminAuthorityAuthorizationError (..)
  , authorizeAwsAdminAttestation
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (fromLeft)
import Data.Text (Text)
import Data.Word (Word16, Word8)
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
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminExecutionError
  , AwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceipt
  , validateAwsAdminWorkerReceiptForPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminCleanupRecoveryProgram (..)
  , AwsAdminJobBinding
  , AwsAdminPermitError
  , AwsAdminPermitIntent
  , AwsAdminPermitKind (..)
  , SignedAwsAdminPermit
  , awsAdminJobHeartbeat
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentCleanupPredecessor
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentKind
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPlanBinding
  , awsAdminPermitIntentPreparedTarget
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitSigningPayload
  , bindAwsAdminPermitIntentCleanupRecovery
  , decodeAwsAdminJobBinding
  , decodeAwsAdminPermitIntent
  , decodeSignedAwsAdminPermit
  , encodeAwsAdminJobBinding
  , encodeAwsAdminPermitIntent
  , encodeSignedAwsAdminPermit
  , mkSomeSignedAwsAdminPermit
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitIntent
  , verifySignedAwsAdminPermit
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , preparedCredentialTargetDeadline
  , preparedCredentialTargetFence
  , preparedCredentialTargetGeneration
  , preparedCredentialTargetId
  , preparedCredentialTargetOwnerNonce
  , preparedCredentialTargetPlanBinding
  , preparedCredentialTargetRequestDigest
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest)

data AwsAdminAuthorityState
  = AwsAdminAuthorityVacant
  | AwsAdminAuthorityPrepared !AwsAdminPermitIntent
  | AwsAdminAuthorityAttested !AwsAdminPermitIntent !AwsAdminJobBinding
  | AwsAdminAuthorityAuthorized !SignedAwsAdminPermit
  | AwsAdminAuthorityCompleted !SignedAwsAdminPermit !AwsAdminWorkerReceipt
  deriving stock (Eq, Show)

initialAwsAdminAuthorityState :: AwsAdminAuthorityState
initialAwsAdminAuthorityState = AwsAdminAuthorityVacant

awsAdminAuthorityCurrentIntent
  :: AwsAdminAuthorityState -> Maybe AwsAdminPermitIntent
awsAdminAuthorityCurrentIntent state = case state of
  AwsAdminAuthorityVacant -> Nothing
  AwsAdminAuthorityPrepared intent -> Just intent
  AwsAdminAuthorityAttested intent _ -> Just intent
  AwsAdminAuthorityAuthorized permit -> Just (signedAwsAdminPermitIntent permit)
  AwsAdminAuthorityCompleted permit _ -> Just (signedAwsAdminPermitIntent permit)

awsAdminAuthorityCurrentPermit
  :: AwsAdminAuthorityState -> Maybe SignedAwsAdminPermit
awsAdminAuthorityCurrentPermit state = case state of
  AwsAdminAuthorityAuthorized permit -> Just permit
  AwsAdminAuthorityCompleted permit _ -> Just permit
  _ -> Nothing

data AwsAdminAuthorityStateError
  = AwsAdminAuthorityTransitionRefused
  | AwsAdminAuthorityTransitionConflict
  | AwsAdminAuthorityIntentInvalid !AwsAdminPermitError
  | AwsAdminAuthorityBindingInvalid !AwsAdminPermitError
  | AwsAdminAuthorityPermitInvalid !AwsAdminPermitError
  | AwsAdminAuthorityReceiptInvalid !AwsAdminExecutionError
  | AwsAdminAuthorityRenewalNotPrepared
  | AwsAdminAuthorityRenewalDeadlineInvalid
  | AwsAdminAuthorityRenewalBindingMismatch
  | AwsAdminAuthorityRecoveryNotAuthorized
  | AwsAdminAuthorityRecoveryProofMismatch
  | AwsAdminAuthorityStateTooLarge !Int !Int
  | AwsAdminAuthorityStateDecodeFailed
  | AwsAdminAuthorityStateUnsupportedVersion !Word16
  | AwsAdminAuthorityStateInvalid
  | AwsAdminAuthorityStateNonCanonical
  deriving stock (Eq, Show)

-- | Independent observations admitted by the expired-attempt recovery proof.
-- Only an exact named-object 404 is absence; presence and every failed or
-- unauthorized observation remain distinct closed refusals.
data AwsAdminAttemptResourceObservation
  = AwsAdminAttemptResourceAbsent
  | AwsAdminAttemptResourcePresent
  | AwsAdminAttemptResourceUnobservable
  deriving stock (Bounded, Enum, Eq, Show)

-- | Exact pre-target phases that require a cleanup-only continuation.  None
-- carries a target receipt, so a fresh permit may first delete the bounded IAM
-- key family, prove stable absence, and only then consume its one remint.
data AwsAdminRecoveryCleanupPhase
  = AwsAdminRecoveryIntentCommittedRemintUsed
  | AwsAdminRecoveryCreateAttemptPreparedInitial
  | AwsAdminRecoveryCreateAttemptPreparedRemintUsed
  | AwsAdminRecoveryKeyCreatedInitial
  | AwsAdminRecoveryKeyCreatedRemintUsed
  | AwsAdminRecoveryCleanupRequiredInitial
  | AwsAdminRecoveryCleanupRequiredRemintUsed
  | AwsAdminRecoveryCleanupProvenInitial
  | AwsAdminRecoveryCleanupProvenRemintUsed
  deriving stock (Bounded, Enum, Eq, Show)

data AwsAdminAttemptJournalObservation
  = AwsAdminAttemptJournalAbsent
  | AwsAdminAttemptJournalInitialIntentCommitted
  | AwsAdminAttemptJournalCleanupContinuation !AwsAdminRecoveryCleanupPhase
  | AwsAdminAttemptJournalPresent
  | AwsAdminAttemptJournalUnobservable
  deriving stock (Eq, Show)

data AwsAdminAuthorizedRecoveryError
  = AwsAdminAuthorizedRecoveryNotAuthorized
  | AwsAdminAuthorizedRecoveryDeadlineActive
  | AwsAdminAuthorizedRecoveryJobPresent
  | AwsAdminAuthorizedRecoveryJobUnobservable
  | AwsAdminAuthorizedRecoveryPodPresent
  | AwsAdminAuthorizedRecoveryPodUnobservable
  | AwsAdminAuthorizedRecoveryJournalPresent
  | AwsAdminAuthorizedRecoveryJournalUnobservable
  deriving stock (Bounded, Enum, Eq, Show)

-- The constructor is deliberately private. The endpoint can receive this
-- capability only from 'proveAwsAdminAuthorizedRecovery', after exact Job and
-- Pod absence plus either no-effect journal evidence or an explicitly closed
-- pre-target cleanup phase has been supplied.
data AwsAdminAuthorizedRecoveryProof = AwsAdminAuthorizedRecoveryProof
  { recoveryProofNow :: !AuthorityTime
  , recoveryProofPermit :: !SignedAwsAdminPermit
  , recoveryProofRequiresCleanup :: !Bool
  }
  deriving stock (Eq, Show)

proveAwsAdminAuthorizedRecovery
  :: AuthorityTime
  -> AwsAdminAuthorityState
  -> AwsAdminAttemptResourceObservation
  -> AwsAdminAttemptResourceObservation
  -> AwsAdminAttemptJournalObservation
  -> Either AwsAdminAuthorizedRecoveryError AwsAdminAuthorizedRecoveryProof
proveAwsAdminAuthorizedRecovery now state jobObservation podObservation journalObservation = do
  permit <- case state of
    AwsAdminAuthorityAuthorized retained -> Right retained
    _ -> Left AwsAdminAuthorizedRecoveryNotAuthorized
  when
    ( authorityTimeMicros now
        < authorityTimeMicros
          (awsAdminPermitIntentDeadline (signedAwsAdminPermitIntent permit))
    )
    (Left AwsAdminAuthorizedRecoveryDeadlineActive)
  requireResourceAbsence
    AwsAdminAuthorizedRecoveryJobPresent
    AwsAdminAuthorizedRecoveryJobUnobservable
    jobObservation
  requireResourceAbsence
    AwsAdminAuthorizedRecoveryPodPresent
    AwsAdminAuthorizedRecoveryPodUnobservable
    podObservation
  requiresCleanup <- case journalObservation of
    AwsAdminAttemptJournalAbsent -> Right False
    AwsAdminAttemptJournalInitialIntentCommitted -> Right False
    AwsAdminAttemptJournalCleanupContinuation _ -> Right True
    AwsAdminAttemptJournalPresent -> Left AwsAdminAuthorizedRecoveryJournalPresent
    AwsAdminAttemptJournalUnobservable -> Left AwsAdminAuthorizedRecoveryJournalUnobservable
  pure
    AwsAdminAuthorizedRecoveryProof
      { recoveryProofNow = now
      , recoveryProofPermit = permit
      , recoveryProofRequiresCleanup = requiresCleanup
      }

bindAwsAdminPreparedRenewalIntent
  :: AwsAdminPermitIntent
  -> AwsAdminPermitIntent
  -> Either AwsAdminAuthorityStateError AwsAdminPermitIntent
bindAwsAdminPreparedRenewalIntent retained replacement =
  case awsAdminPermitIntentCleanupPredecessor retained of
    Just predecessor ->
      first
        AwsAdminAuthorityIntentInvalid
        ( bindAwsAdminPermitIntentCleanupRecovery
            (awsAdminPermitIntentKind retained)
            predecessor
            replacement
        )
    Nothing -> Right replacement

bindAwsAdminAuthorizedRecoveryIntent
  :: AwsAdminAuthorizedRecoveryProof
  -> AwsAdminPermitIntent
  -> Either AwsAdminAuthorityStateError AwsAdminPermitIntent
bindAwsAdminAuthorizedRecoveryIntent proof replacement
  | recoveryProofRequiresCleanup proof =
      first
        AwsAdminAuthorityIntentInvalid
        ( bindAwsAdminPermitIntentCleanupRecovery
            retainedKind
            predecessorDigest
            replacement
        )
  | Just retainedPredecessor <- awsAdminPermitIntentCleanupPredecessor retainedIntent =
      first
        AwsAdminAuthorityIntentInvalid
        ( bindAwsAdminPermitIntentCleanupRecovery
            retainedKind
            retainedPredecessor
            replacement
        )
  | renewableKindMatches retainedKind (awsAdminPermitIntentKind replacement) = Right replacement
  | otherwise = Left AwsAdminAuthorityRenewalBindingMismatch
 where
  retainedIntent = signedAwsAdminPermitIntent (recoveryProofPermit proof)
  retainedKind = awsAdminPermitIntentKind retainedIntent
  predecessorDigest =
    sha256TargetValueDigest
      (encodeSignedAwsAdminPermit (recoveryProofPermit proof))

requireResourceAbsence
  :: AwsAdminAuthorizedRecoveryError
  -> AwsAdminAuthorizedRecoveryError
  -> AwsAdminAttemptResourceObservation
  -> Either AwsAdminAuthorizedRecoveryError ()
requireResourceAbsence presentError unobservableError observation = case observation of
  AwsAdminAttemptResourceAbsent -> Right ()
  AwsAdminAttemptResourcePresent -> Left presentError
  AwsAdminAttemptResourceUnobservable -> Left unobservableError

commitAwsAdminPrepared
  :: AwsAdminPermitIntent
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminPrepared intent state = do
  validatedIntent <- validateCanonicalIntent intent
  case awsAdminAuthorityCurrentIntent state of
    Just existing
      | existing == validatedIntent -> Right state
      | otherwise -> Left AwsAdminAuthorityTransitionConflict
    Nothing -> case state of
      AwsAdminAuthorityVacant -> Right (AwsAdminAuthorityPrepared validatedIntent)
      _ -> Left AwsAdminAuthorityTransitionRefused

-- | Replace only an expired, prepared-but-unattested attempt.  The expired
-- deadline prevents a concurrent attestation from being admitted; every
-- durable request and plan binding remains exact while the active deadline,
-- image, selected Agent, and derived prepared receipt may advance.
commitAwsAdminPreparedRenewal
  :: AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminPermitIntent
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminPreparedRenewal now retained replacement state = do
  validatedRetained <- validateCanonicalIntent retained
  validatedReplacement <- validateCanonicalIntent replacement
  case state of
    AwsAdminAuthorityPrepared current
      | current == validatedReplacement -> Right state
      | current /= validatedRetained -> Left AwsAdminAuthorityRenewalNotPrepared
      | not (renewalDeadlineValid now current validatedReplacement) ->
          Left AwsAdminAuthorityRenewalDeadlineInvalid
      | not (renewalBindingsMatch current validatedReplacement) ->
          Left AwsAdminAuthorityRenewalBindingMismatch
      | otherwise -> Right (AwsAdminAuthorityPrepared validatedReplacement)
    _ -> Left AwsAdminAuthorityRenewalNotPrepared

-- | Recover exactly the expired Authorized attempt captured by the opaque
-- proof. The fresh intent must retain every immutable renewal binding. Exact
-- replay of the replacement Prepared state closes the CAS-response-loss case.
commitAwsAdminPreparedAuthorizedRecovery
  :: AwsAdminAuthorizedRecoveryProof
  -> AwsAdminPermitIntent
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminPreparedAuthorizedRecovery proof replacement state = do
  validatedReplacement <- validateCanonicalIntent replacement
  let retainedPermit = recoveryProofPermit proof
      retained = signedAwsAdminPermitIntent retainedPermit
      now = recoveryProofNow proof
  case state of
    AwsAdminAuthorityPrepared current
      | current == validatedReplacement -> Right state
    AwsAdminAuthorityAuthorized currentPermit
      | currentPermit /= retainedPermit -> Left AwsAdminAuthorityRecoveryProofMismatch
      | not (renewalDeadlineValid now retained validatedReplacement) ->
          Left AwsAdminAuthorityRenewalDeadlineInvalid
      | not (authorizedRecoveryKindMatches proof validatedReplacement) ->
          Left AwsAdminAuthorityRenewalBindingMismatch
      | not (renewalCoreBindingsMatch retained validatedReplacement) ->
          Left AwsAdminAuthorityRenewalBindingMismatch
      | otherwise -> Right (AwsAdminAuthorityPrepared validatedReplacement)
    _ -> Left AwsAdminAuthorityRecoveryNotAuthorized

renewalDeadlineValid
  :: AuthorityTime -> AwsAdminPermitIntent -> AwsAdminPermitIntent -> Bool
renewalDeadlineValid now retained replacement =
  authorityTimeMicros (awsAdminPermitIntentDeadline retained)
    <= authorityTimeMicros now
    && authorityTimeMicros now
      < authorityTimeMicros (awsAdminPermitIntentDeadline replacement)
    && authorityTimeMicros (awsAdminPermitIntentDeadline retained)
      < authorityTimeMicros (awsAdminPermitIntentDeadline replacement)

renewalBindingsMatch :: AwsAdminPermitIntent -> AwsAdminPermitIntent -> Bool
renewalBindingsMatch retained replacement =
  renewableKindMatches
    (awsAdminPermitIntentKind retained)
    (awsAdminPermitIntentKind replacement)
    && renewalCoreBindingsMatch retained replacement

renewalCoreBindingsMatch :: AwsAdminPermitIntent -> AwsAdminPermitIntent -> Bool
renewalCoreBindingsMatch retained replacement =
  awsAdminPermitIntentPermitId retained == awsAdminPermitIntentPermitId replacement
    && awsAdminPermitIntentCredentialClass retained == awsAdminPermitIntentCredentialClass replacement
    && awsAdminPermitIntentAction retained == awsAdminPermitIntentAction replacement
    && awsAdminPermitIntentOperationId retained == awsAdminPermitIntentOperationId replacement
    && awsAdminPermitIntentGeneration retained == awsAdminPermitIntentGeneration replacement
    && awsAdminPermitIntentRequestDigest retained == awsAdminPermitIntentRequestDigest replacement
    && planBindingIsExact
    && awsAdminPermitIntentIamParameters retained == awsAdminPermitIntentIamParameters replacement
    && awsAdminPermitIntentAuthorityScope retained == awsAdminPermitIntentAuthorityScope replacement
    && awsAdminPermitIntentAuthorityEndpoint retained == awsAdminPermitIntentAuthorityEndpoint replacement
    && preparedBindingsMatch
 where
  retainedPrepared = awsAdminPermitIntentPreparedTarget retained
  replacementPrepared = awsAdminPermitIntentPreparedTarget replacement
  planBindingIsExact =
    awsAdminPermitIntentPlanBinding retained
      == awsAdminPermitIntentPlanBinding replacement
      && awsAdminPermitIntentPlanBinding retained /= Nothing
  preparedBindingsMatch =
    preparedCredentialTargetOwnerNonce retainedPrepared
      == preparedCredentialTargetOwnerNonce replacementPrepared
      && preparedCredentialTargetFence retainedPrepared
        == preparedCredentialTargetFence replacementPrepared
      && preparedCredentialTargetId retainedPrepared
        == preparedCredentialTargetId replacementPrepared
      && preparedCredentialTargetGeneration retainedPrepared
        == preparedCredentialTargetGeneration replacementPrepared
      && preparedCredentialTargetRequestDigest retainedPrepared
        == preparedCredentialTargetRequestDigest replacementPrepared
      && preparedCredentialTargetPlanBinding retainedPrepared
        == preparedCredentialTargetPlanBinding replacementPrepared
      && preparedCredentialTargetDeadline retainedPrepared
        == awsAdminPermitIntentDeadline retained
      && preparedCredentialTargetDeadline replacementPrepared
        == awsAdminPermitIntentDeadline replacement

awsAdminPreparedRenewalBindingsMatch
  :: AwsAdminPermitIntent -> AwsAdminPermitIntent -> Bool
awsAdminPreparedRenewalBindingsMatch = renewalBindingsMatch

renewableKindMatches :: AwsAdminPermitKind -> AwsAdminPermitKind -> Bool
renewableKindMatches retained replacement = case (retained, replacement) of
  (GenesisBackupKind _, GenesisBackupKind _) -> True
  (NormalOperatorMaterialKind, NormalOperatorMaterialKind) -> True
  (BackupRepairFrozenKind left, BackupRepairFrozenKind right) -> left == right
  ( CleanupRecoveryKind retainedProgram retainedPredecessor
    , CleanupRecoveryKind replacementProgram replacementPredecessor
    ) ->
      retainedPredecessor == replacementPredecessor
        && cleanupProgramsRenewablyMatch retainedProgram replacementProgram
  _ -> False

cleanupProgramsRenewablyMatch
  :: AwsAdminCleanupRecoveryProgram
  -> AwsAdminCleanupRecoveryProgram
  -> Bool
cleanupProgramsRenewablyMatch retained replacement = case (retained, replacement) of
  (NormalOperatorMaterialCleanupProgram, NormalOperatorMaterialCleanupProgram) -> True
  (GenesisBackupCleanupProgram _, GenesisBackupCleanupProgram _) -> True
  _ -> False

authorizedRecoveryKindMatches
  :: AwsAdminAuthorizedRecoveryProof -> AwsAdminPermitIntent -> Bool
authorizedRecoveryKindMatches proof replacement
  | recoveryProofRequiresCleanup proof =
      exactCleanupBinding predecessorDigest
  | Just retainedPredecessor <- awsAdminPermitIntentCleanupPredecessor retained =
      exactCleanupBinding retainedPredecessor
  | otherwise = renewableKindMatches retainedKind (awsAdminPermitIntentKind replacement)
 where
  retained = signedAwsAdminPermitIntent (recoveryProofPermit proof)
  retainedKind = awsAdminPermitIntentKind retained
  predecessorDigest =
    sha256TargetValueDigest
      (encodeSignedAwsAdminPermit (recoveryProofPermit proof))
  exactCleanupBinding predecessor =
    bindAwsAdminPermitIntentCleanupRecovery retainedKind predecessor replacement
      == Right replacement

commitAwsAdminAttested
  :: AwsAdminJobBinding
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminAttested binding state = case state of
  AwsAdminAuthorityPrepared intent -> do
    validated <- validateCanonicalBinding intent binding
    Right (AwsAdminAuthorityAttested intent validated)
  AwsAdminAuthorityAttested intent existing -> do
    validated <- validateCanonicalBinding intent binding
    if existing == validated
      then Right state
      else Left AwsAdminAuthorityTransitionConflict
  AwsAdminAuthorityAuthorized permit ->
    replayForPermit permit
  AwsAdminAuthorityCompleted permit _ ->
    replayForPermit permit
  AwsAdminAuthorityVacant -> Left AwsAdminAuthorityTransitionRefused
 where
  replayForPermit permit = do
    validated <-
      validateCanonicalBinding (signedAwsAdminPermitIntent permit) binding
    if signedAwsAdminPermitBinding permit == validated
      then Right state
      else Left AwsAdminAuthorityTransitionConflict

commitAwsAdminAuthorized
  :: SignedAwsAdminPermit
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminAuthorized permit state = do
  validatedPermit <- validateCanonicalPermit permit
  case state of
    AwsAdminAuthorityAttested intent binding
      | intent == signedAwsAdminPermitIntent validatedPermit
          && binding == signedAwsAdminPermitBinding validatedPermit ->
          Right (AwsAdminAuthorityAuthorized validatedPermit)
      | otherwise -> Left AwsAdminAuthorityTransitionConflict
    AwsAdminAuthorityAuthorized existing
      | existing == validatedPermit -> Right state
      | otherwise -> Left AwsAdminAuthorityTransitionConflict
    AwsAdminAuthorityCompleted existing _
      | existing == validatedPermit -> Right state
      | otherwise -> Left AwsAdminAuthorityTransitionConflict
    _ -> Left AwsAdminAuthorityTransitionRefused

commitAwsAdminCompleted
  :: AwsAdminWorkerReceipt
  -> AwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
commitAwsAdminCompleted receipt state = case state of
  AwsAdminAuthorityAuthorized permit -> do
    validated <- validateCanonicalReceipt permit receipt
    Right (AwsAdminAuthorityCompleted permit validated)
  AwsAdminAuthorityCompleted permit existing -> do
    validated <- validateCanonicalReceipt permit receipt
    if existing == validated
      then Right state
      else Left AwsAdminAuthorityTransitionConflict
  _ -> Left AwsAdminAuthorityTransitionRefused

validateCanonicalIntent
  :: AwsAdminPermitIntent
  -> Either AwsAdminAuthorityStateError AwsAdminPermitIntent
validateCanonicalIntent intent =
  first
    AwsAdminAuthorityIntentInvalid
    (decodeAwsAdminPermitIntent (encodeAwsAdminPermitIntent intent))

validateCanonicalBinding
  :: AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> Either AwsAdminAuthorityStateError AwsAdminJobBinding
validateCanonicalBinding intent binding =
  first
    AwsAdminAuthorityBindingInvalid
    (decodeAwsAdminJobBinding intent (encodeAwsAdminJobBinding binding))

validateCanonicalPermit
  :: SignedAwsAdminPermit
  -> Either AwsAdminAuthorityStateError SignedAwsAdminPermit
validateCanonicalPermit permit = do
  somePermit <-
    first
      AwsAdminAuthorityPermitInvalid
      (decodeSignedAwsAdminPermit (encodeSignedAwsAdminPermit permit))
  withSomeSignedAwsAdminPermit somePermit $ \decoded ->
    if decoded == permit
      then Right decoded
      else Left AwsAdminAuthorityStateNonCanonical

validateCanonicalReceipt
  :: SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> Either AwsAdminAuthorityStateError AwsAdminWorkerReceipt
validateCanonicalReceipt permit receipt = do
  decoded <-
    first
      AwsAdminAuthorityReceiptInvalid
      (decodeAwsAdminWorkerReceipt (encodeAwsAdminWorkerReceipt receipt))
  first
    AwsAdminAuthorityReceiptInvalid
    (validateAwsAdminWorkerReceiptForPermit permit decoded)
  pure decoded

data WireAwsAdminAuthorityState = WireAwsAdminAuthorityState
  { wireAuthorityVersion :: !Word16
  , wireAuthorityPhase :: !Word8
  , wireAuthorityIntent :: !(Maybe ByteString)
  , wireAuthorityBinding :: !(Maybe ByteString)
  , wireAuthorityPermit :: !(Maybe ByteString)
  , wireAuthorityReceipt :: !(Maybe ByteString)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

awsAdminAuthorityStateVersion :: Word16
awsAdminAuthorityStateVersion = 1

awsAdminAuthorityStateMaximumBytes :: Int
awsAdminAuthorityStateMaximumBytes = 160 * 1024

encodeAwsAdminAuthorityState :: AwsAdminAuthorityState -> ByteString
encodeAwsAdminAuthorityState =
  LazyByteString.toStrict . serialise . authorityStateToWire

decodeAwsAdminAuthorityState
  :: ByteString -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
decodeAwsAdminAuthorityState bytes = do
  when
    (ByteString.length bytes > awsAdminAuthorityStateMaximumBytes)
    ( Left
        ( AwsAdminAuthorityStateTooLarge
            (ByteString.length bytes)
            awsAdminAuthorityStateMaximumBytes
        )
    )
  wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
    Left _ -> Left AwsAdminAuthorityStateDecodeFailed
    Right value -> Right value
  unless
    (wireAuthorityVersion wire == awsAdminAuthorityStateVersion)
    ( Left
        ( AwsAdminAuthorityStateUnsupportedVersion
            (wireAuthorityVersion wire)
        )
    )
  state <- authorityStateFromWire wire
  unless
    (encodeAwsAdminAuthorityState state == bytes)
    (Left AwsAdminAuthorityStateNonCanonical)
  pure state

awsAdminAuthorityStateCodec :: ModelBCodec AwsAdminAuthorityState
awsAdminAuthorityStateCodec =
  ModelBCodec
    { encodeModelBValue = Right . encodeAwsAdminAuthorityState
    , decodeModelBValue =
        either (Left . show) Right . decodeAwsAdminAuthorityState
    }

data AwsAdminAuthoritySnapshot revision = AwsAdminAuthoritySnapshot
  { awsAdminAuthorityRevision :: !revision
  , awsAdminAuthoritySnapshotState :: !AwsAdminAuthorityState
  }
  deriving stock (Eq, Show)

data AwsAdminAuthorityRepository m revision = AwsAdminAuthorityRepository
  { readAwsAdminAuthority
      :: m (Either Text (AwsAdminAuthoritySnapshot revision))
  , compareAndSwapAwsAdminAuthority
      :: revision
      -> AwsAdminAuthorityState
      -> m (Either Text ())
  }

modelBAwsAdminAuthorityRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m AwsAdminAuthorityState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AwsAdminAuthorityRepository m (Maybe ModelBObjectVersion)
modelBAwsAdminAuthorityRepository adapter coordinate =
  AwsAdminAuthorityRepository
    { readAwsAdminAuthority = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right
              AwsAdminAuthoritySnapshot
                { awsAdminAuthorityRevision = Nothing
                , awsAdminAuthoritySnapshotState = initialAwsAdminAuthorityState
                }
          ModelBObserved revision state ->
            Right
              AwsAdminAuthoritySnapshot
                { awsAdminAuthorityRevision = Just revision
                , awsAdminAuthoritySnapshotState = state
                }
          ModelBCorrupt detail ->
            Left ("AWS-admin Authority state is corrupt: " <> detail)
          ModelBEndpointUnready detail ->
            Left ("AWS-admin Authority state is not ready: " <> detail)
          ModelBUnobservable detail ->
            Left ("AWS-admin Authority state is unobservable: " <> detail)
    , compareAndSwapAwsAdminAuthority = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "AWS-admin Authority CAS conflict"
          ModelBCasRefusedCorrupt detail ->
            Left ("AWS-admin Authority CAS refused corrupt state: " <> detail)
          ModelBCasEndpointUnready detail ->
            Left ("AWS-admin Authority CAS is not ready: " <> detail)
          ModelBCasUnobservable detail ->
            Left ("AWS-admin Authority CAS is unobservable: " <> detail)
    }

-- | Production preparation must re-observe the exact retained target outbox.
-- Although the closed request carries its expected observation for replay
-- binding, the caller cannot make that observation authoritative by supplying
-- it: a byte-for-byte typed match with this boundary is required before CAS.
newtype AwsAdminPreparedTargetBoundary m = AwsAdminPreparedTargetBoundary
  { reobserveAwsAdminPreparedTarget
      :: AwsAdminPermitIntent
      -> m (Either Text PreparedCredentialTargetObservation)
  }

data AwsAdminAuthorityRepositoryError
  = AwsAdminAuthorityRepositoryUnavailable !Text
  | AwsAdminAuthorityPreparedTargetUnavailable !Text
  | AwsAdminAuthorityPreparedTargetMismatch
  | AwsAdminAuthorityRepositoryStateRejected !AwsAdminAuthorityStateError
  | AwsAdminAuthorityRepositoryAuthorizationRejected
      !AwsAdminAuthorityAuthorizationError
  | AwsAdminAuthorityRepositoryCommitFailed !Text
  | AwsAdminAuthorityRepositoryPermitMismatch
  deriving stock (Eq, Show)

prepareAwsAdminAuthority
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> AwsAdminPreparedTargetBoundary m
  -> AwsAdminPermitIntent
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
prepareAwsAdminAuthority repository targetBoundary intent = do
  observed <- reobserveAwsAdminPreparedTarget targetBoundary intent
  case observed of
    Left detail ->
      pure (Left (AwsAdminAuthorityPreparedTargetUnavailable detail))
    Right prepared
      | prepared /= expectedPrepared ->
          pure (Left AwsAdminAuthorityPreparedTargetMismatch)
      | otherwise ->
          transitionAndCommit repository (commitAwsAdminPrepared intent)
 where
  expectedPrepared = awsAdminPermitIntentPreparedTarget intent

prepareAwsAdminAuthorityRenewal
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> AwsAdminPreparedTargetBoundary m
  -> AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminPermitIntent
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
prepareAwsAdminAuthorityRenewal repository targetBoundary now retained replacement = do
  observed <- reobserveAwsAdminPreparedTarget targetBoundary replacement
  case observed of
    Left detail ->
      pure (Left (AwsAdminAuthorityPreparedTargetUnavailable detail))
    Right prepared
      | prepared /= awsAdminPermitIntentPreparedTarget replacement ->
          pure (Left AwsAdminAuthorityPreparedTargetMismatch)
      | otherwise ->
          transitionAndCommit
            repository
            (commitAwsAdminPreparedRenewal now retained replacement)

prepareAwsAdminAuthorityAuthorizedRecovery
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> AwsAdminPreparedTargetBoundary m
  -> AwsAdminAuthorizedRecoveryProof
  -> AwsAdminPermitIntent
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
prepareAwsAdminAuthorityAuthorizedRecovery repository targetBoundary proof replacement = do
  observed <- reobserveAwsAdminPreparedTarget targetBoundary replacement
  case observed of
    Left detail ->
      pure (Left (AwsAdminAuthorityPreparedTargetUnavailable detail))
    Right prepared
      | prepared /= awsAdminPermitIntentPreparedTarget replacement ->
          pure (Left AwsAdminAuthorityPreparedTargetMismatch)
      | otherwise ->
          transitionAndCommit
            repository
            (commitAwsAdminPreparedAuthorizedRecovery proof replacement)

attestAwsAdminAuthority
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> AwsAdminJobBinding
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
attestAwsAdminAuthority repository binding =
  transitionAndCommit repository (commitAwsAdminAttested binding)

authorizeAwsAdminAuthority
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> AuthorityManifestSigner m
  -> AuthorityTime
  -> m
       ( Either
           AwsAdminAuthorityRepositoryError
           (AwsAdminAuthorityState, SignedAwsAdminPermit)
       )
authorizeAwsAdminAuthority repository signer now = do
  snapshotResult <- readAwsAdminAuthority repository
  case snapshotResult of
    Left detail ->
      pure (Left (AwsAdminAuthorityRepositoryUnavailable detail))
    Right snapshot
      | Just permit <-
          awsAdminAuthorityCurrentPermit
            (awsAdminAuthoritySnapshotState snapshot) ->
          pure (Right (awsAdminAuthoritySnapshotState snapshot, permit))
      | otherwise -> do
          authorized <-
            authorizeAwsAdminAttestation
              signer
              now
              (awsAdminAuthoritySnapshotState snapshot)
          case authorized of
            Left err ->
              pure (Left (AwsAdminAuthorityRepositoryAuthorizationRejected err))
            Right (next, permit) -> do
              confirmed <-
                commitAndConfirm
                  repository
                  (awsAdminAuthorityRevision snapshot)
                  next
                  (retainsPermit permit)
              pure (fmap (,permit) confirmed)

completeAwsAdminAuthority
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
completeAwsAdminAuthority repository suppliedPermit receipt = do
  snapshotResult <- readAwsAdminAuthority repository
  case snapshotResult of
    Left detail ->
      pure (Left (AwsAdminAuthorityRepositoryUnavailable detail))
    Right snapshot -> case awsAdminAuthoritySnapshotState snapshot of
      AwsAdminAuthorityAuthorized retainedPermit
        | retainedPermit == suppliedPermit ->
            complete snapshot
        | otherwise ->
            pure (Left AwsAdminAuthorityRepositoryPermitMismatch)
      AwsAdminAuthorityCompleted retainedPermit existing
        | retainedPermit /= suppliedPermit ->
            pure (Left AwsAdminAuthorityRepositoryPermitMismatch)
        | existing /= receipt ->
            pure
              ( Left
                  ( AwsAdminAuthorityRepositoryStateRejected
                      AwsAdminAuthorityTransitionConflict
                  )
              )
        | otherwise -> pure (Right (awsAdminAuthoritySnapshotState snapshot))
      _ ->
        pure
          ( Left
              ( AwsAdminAuthorityRepositoryStateRejected
                  AwsAdminAuthorityTransitionRefused
              )
          )
 where
  complete snapshot = case commitAwsAdminCompleted receipt (awsAdminAuthoritySnapshotState snapshot) of
    Left err -> pure (Left (AwsAdminAuthorityRepositoryStateRejected err))
    Right next ->
      commitAndConfirm
        repository
        (awsAdminAuthorityRevision snapshot)
        next
        (retainsCompletion suppliedPermit receipt)

observeAwsAdminAuthority
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
observeAwsAdminAuthority repository = do
  snapshotResult <- readAwsAdminAuthority repository
  pure $ case snapshotResult of
    Left detail -> Left (AwsAdminAuthorityRepositoryUnavailable detail)
    Right snapshot -> Right (awsAdminAuthoritySnapshotState snapshot)

transitionAndCommit
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> ( AwsAdminAuthorityState
       -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
     )
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
transitionAndCommit repository transition = do
  snapshotResult <- readAwsAdminAuthority repository
  case snapshotResult of
    Left detail ->
      pure (Left (AwsAdminAuthorityRepositoryUnavailable detail))
    Right snapshot -> case transition (awsAdminAuthoritySnapshotState snapshot) of
      Left err -> pure (Left (AwsAdminAuthorityRepositoryStateRejected err))
      Right next
        | next == awsAdminAuthoritySnapshotState snapshot -> pure (Right next)
        | otherwise ->
            commitAndConfirm
              repository
              (awsAdminAuthorityRevision snapshot)
              next
              (isIdempotentTransition transition)

retainsPermit :: SignedAwsAdminPermit -> AwsAdminAuthorityState -> Maybe AwsAdminAuthorityState
retainsPermit permit observed = case awsAdminAuthorityCurrentPermit observed of
  Just retained | retained == permit -> Just observed
  _ -> Nothing

retainsCompletion
  :: SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> AwsAdminAuthorityState
  -> Maybe AwsAdminAuthorityState
retainsCompletion suppliedPermit receipt observed = case observed of
  AwsAdminAuthorityCompleted retainedPermit retainedReceipt
    | retainedPermit == suppliedPermit
        && retainedReceipt == receipt ->
        Just observed
  _ -> Nothing

isIdempotentTransition
  :: ( AwsAdminAuthorityState
       -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
     )
  -> AwsAdminAuthorityState
  -> Maybe AwsAdminAuthorityState
isIdempotentTransition transition observed = case transition observed of
  Right replayed | replayed == observed -> Just observed
  _ -> Nothing

-- | A successful CAS response is not proof of durability. Re-observe the
-- retained object after every attempted write and accept only an exact
-- idempotent descendant of the requested transition. This also recovers the
-- safe "write committed, response lost" case without repeating a side effect.
commitAndConfirm
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> revision
  -> AwsAdminAuthorityState
  -> (AwsAdminAuthorityState -> Maybe AwsAdminAuthorityState)
  -> m (Either AwsAdminAuthorityRepositoryError AwsAdminAuthorityState)
commitAndConfirm repository expected next acceptObserved = do
  committed <- compareAndSwapAwsAdminAuthority repository expected next
  observedResult <- readAwsAdminAuthority repository
  pure $ case observedResult of
    Right snapshot
      | Just accepted <-
          acceptObserved (awsAdminAuthoritySnapshotState snapshot) ->
          Right accepted
    Right _ ->
      Left
        ( AwsAdminAuthorityRepositoryCommitFailed
            (fromLeft "AWS-admin Authority readback mismatch" committed)
        )
    Left detail ->
      Left
        ( AwsAdminAuthorityRepositoryCommitFailed
            (either (<> "; readback failed: " <> detail) (const detail) committed)
        )

authorityStateToWire
  :: AwsAdminAuthorityState -> WireAwsAdminAuthorityState
authorityStateToWire state = case state of
  AwsAdminAuthorityVacant -> emptyWire 0
  AwsAdminAuthorityPrepared intent ->
    (emptyWire 1) {wireAuthorityIntent = Just (encodeAwsAdminPermitIntent intent)}
  AwsAdminAuthorityAttested intent binding ->
    (emptyWire 2)
      { wireAuthorityIntent = Just (encodeAwsAdminPermitIntent intent)
      , wireAuthorityBinding = Just (encodeAwsAdminJobBinding binding)
      }
  AwsAdminAuthorityAuthorized permit ->
    (emptyWire 3)
      { wireAuthorityPermit = Just (encodeSignedAwsAdminPermit permit)
      }
  AwsAdminAuthorityCompleted permit receipt ->
    (emptyWire 4)
      { wireAuthorityPermit = Just (encodeSignedAwsAdminPermit permit)
      , wireAuthorityReceipt = Just (encodeAwsAdminWorkerReceipt receipt)
      }

emptyWire :: Word8 -> WireAwsAdminAuthorityState
emptyWire phase =
  WireAwsAdminAuthorityState
    { wireAuthorityVersion = awsAdminAuthorityStateVersion
    , wireAuthorityPhase = phase
    , wireAuthorityIntent = Nothing
    , wireAuthorityBinding = Nothing
    , wireAuthorityPermit = Nothing
    , wireAuthorityReceipt = Nothing
    }

authorityStateFromWire
  :: WireAwsAdminAuthorityState
  -> Either AwsAdminAuthorityStateError AwsAdminAuthorityState
authorityStateFromWire wire = case wireAuthorityPhase wire of
  0
    | emptyPayload -> Right AwsAdminAuthorityVacant
  1 -> case payloads of
    (Just intentBytes, Nothing, Nothing, Nothing) -> do
      intent <- first AwsAdminAuthorityIntentInvalid (decodeAwsAdminPermitIntent intentBytes)
      commitAwsAdminPrepared intent AwsAdminAuthorityVacant
    _ -> Left AwsAdminAuthorityStateInvalid
  2 -> case payloads of
    (Just intentBytes, Just bindingBytes, Nothing, Nothing) -> do
      intent <- first AwsAdminAuthorityIntentInvalid (decodeAwsAdminPermitIntent intentBytes)
      binding <-
        first
          AwsAdminAuthorityBindingInvalid
          (decodeAwsAdminJobBinding intent bindingBytes)
      prepared <- commitAwsAdminPrepared intent AwsAdminAuthorityVacant
      commitAwsAdminAttested binding prepared
    _ -> Left AwsAdminAuthorityStateInvalid
  3 -> case payloads of
    (Nothing, Nothing, Just permitBytes, Nothing) -> do
      permit <- permitFromBytes permitBytes
      prepared <- commitAwsAdminPrepared (signedAwsAdminPermitIntent permit) AwsAdminAuthorityVacant
      attested <- commitAwsAdminAttested (signedAwsAdminPermitBinding permit) prepared
      commitAwsAdminAuthorized permit attested
    _ -> Left AwsAdminAuthorityStateInvalid
  4 -> case payloads of
    (Nothing, Nothing, Just permitBytes, Just receiptBytes) -> do
      permit <- permitFromBytes permitBytes
      receipt <-
        first
          AwsAdminAuthorityReceiptInvalid
          (decodeAwsAdminWorkerReceipt receiptBytes)
      prepared <- commitAwsAdminPrepared (signedAwsAdminPermitIntent permit) AwsAdminAuthorityVacant
      attested <- commitAwsAdminAttested (signedAwsAdminPermitBinding permit) prepared
      authorized <- commitAwsAdminAuthorized permit attested
      commitAwsAdminCompleted receipt authorized
    _ -> Left AwsAdminAuthorityStateInvalid
  _ -> Left AwsAdminAuthorityStateInvalid
 where
  payloads =
    ( wireAuthorityIntent wire
    , wireAuthorityBinding wire
    , wireAuthorityPermit wire
    , wireAuthorityReceipt wire
    )
  emptyPayload = payloads == (Nothing, Nothing, Nothing, Nothing)
  permitFromBytes permitBytes = do
    somePermit <-
      first
        AwsAdminAuthorityPermitInvalid
        (decodeSignedAwsAdminPermit permitBytes)
    withSomeSignedAwsAdminPermit somePermit Right

data AwsAdminAuthorityAuthorizationError
  = AwsAdminAuthorityAuthorizationState !AwsAdminAuthorityStateError
  | AwsAdminAuthorityAuthorizationNotAttested
  | AwsAdminAuthorityAuthorizationSignerUnavailable !Text
  | AwsAdminAuthorityAuthorizationSignerGenerationChanged !Natural !Natural
  | AwsAdminAuthorityAuthorizationAttestationStale
  | AwsAdminAuthorityAuthorizationPermitInvalid !AwsAdminPermitError
  deriving stock (Eq, Show)

-- | Transit-sign exactly the already-durable attestation.  The signer key
-- generation is read before signing and must be unchanged in the signature
-- response.  The result is locally verified before it may enter retained
-- Authority state.
authorizeAwsAdminAttestation
  :: (Monad m)
  => AuthorityManifestSigner m
  -> AuthorityTime
  -> AwsAdminAuthorityState
  -> m
       ( Either
           AwsAdminAuthorityAuthorizationError
           (AwsAdminAuthorityState, SignedAwsAdminPermit)
       )
authorizeAwsAdminAttestation signer now state = case state of
  AwsAdminAuthorityAttested intent binding -> do
    let nowMicros = authorityTimeMicros now
        heartbeatMicros = authorityTimeMicros (awsAdminJobHeartbeat binding)
    if heartbeatMicros > nowMicros || nowMicros - heartbeatMicros > maximumHeartbeatAgeMicros
      then pure (Left AwsAdminAuthorityAuthorizationAttestationStale)
      else do
        publicResult <- readAuthorityManifestPublicKey signer
        case publicResult of
          Left detail -> pure (Left (AwsAdminAuthorityAuthorizationSignerUnavailable detail))
          Right (publicGeneration, publicKey) -> do
            signatureResult <-
              signAuthorityManifestPayload
                signer
                (awsAdminPermitSigningPayload publicGeneration intent binding)
            pure $ do
              (signatureGeneration, signature) <-
                first AwsAdminAuthorityAuthorizationSignerUnavailable signatureResult
              unless
                (signatureGeneration == publicGeneration)
                ( Left
                    ( AwsAdminAuthorityAuthorizationSignerGenerationChanged
                        publicGeneration
                        signatureGeneration
                    )
                )
              somePermit <-
                first
                  AwsAdminAuthorityAuthorizationPermitInvalid
                  ( mkSomeSignedAwsAdminPermit
                      publicGeneration
                      intent
                      binding
                      signature
                  )
              withSomeSignedAwsAdminPermit somePermit $ \permit -> do
                first
                  AwsAdminAuthorityAuthorizationPermitInvalid
                  ( verifySignedAwsAdminPermit
                      (manifestPublicKeyBytes publicKey)
                      publicGeneration
                      now
                      permit
                  )
                authorized <-
                  first
                    AwsAdminAuthorityAuthorizationState
                    (commitAwsAdminAuthorized permit state)
                Right (authorized, permit)
  _ -> pure (Left AwsAdminAuthorityAuthorizationNotAttested)

maximumHeartbeatAgeMicros :: Natural
maximumHeartbeatAgeMicros = 30 * 1000000
