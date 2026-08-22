{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private retained state for the Lifecycle Provider admission
-- epoch. The public facade exposes only read-only views and fixed diagnostics.
--
-- Sprint 4.85 added the two transitions this module previously described as
-- absent: binding a serving credential generation, and the atomic Cascade-audit
-- freeze that reserves exactly one terminal-audit submission while fencing
-- every other fresh one. Both are pure and package-private, and both are
-- consumed by @Prodbox.Lifecycle.Authority.Admission@ as commands over the same
-- retained aggregate the submission path reads — which is what makes the freeze
-- atomic with the pending-work proof rather than a second object that could
-- disagree.
--
-- What is still absent is an authenticated route that issues either command, so
-- no production caller can reach the frozen state yet. Revocation likewise has
-- no transition: 'ProviderCredentialRevocationReceipt' remains a retained shape
-- with no constructor.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
  ( ProviderAdmissionEpoch
  , ProviderAdmissionEpochView (..)
  , ProviderAdmissionEpochError (..)
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , providerAdmissionEpochView
  , initialLegacyProviderAdmissionEpochInternal
  , validateProviderAdmissionEpochInternal
  , providerAdmissionFreshSubmissionRefusalInternal
  , CascadeAuditFreezeBinding
  , mkCascadeAuditFreezeBinding
  , cascadeAuditFreezeBindingExpectedSubmissions
  , ProviderPendingWork (..)
  , ProviderAdmissionFreezeRefusal (..)
  , bindProviderAdmissionServingGenerationInternal
  , freezeProviderAdmissionForCascadeAuditInternal
  , ProviderAdmissionEpochRegression
  , fixedProviderAdmissionEpochRegression
  , providerAdmissionEpochRegressionLegacyPreserved
  , providerAdmissionEpochRegressionServingPermitsFresh
  , providerAdmissionEpochRegressionFrozenRefusesFresh
  , providerAdmissionEpochRegressionRevokedRefusesFresh
  , providerAdmissionEpochRegressionNoPendingClassified
  , providerAdmissionEpochRegressionOwnedPendingClassified
  , providerAdmissionEpochRegressionUnownedPendingClassified
  , providerAdmissionEpochRegressionFrozenShapeValidated
  , providerAdmissionEpochRegressionRevokedShapeValidated
  , providerAdmissionEpochRegressionInvalidGenerationRefused
  , providerAdmissionEpochRegressionNonCanonicalBindingRefused
  , ProviderAdmissionFreezeRegression
  , fixedProviderAdmissionFreezeRegression
  , freezeRegressionUnboundGenerationRefused
  , freezeRegressionPendingWorkRefused
  , freezeRegressionServingFreezes
  , freezeRegressionIdenticalFreezeIdempotent
  , freezeRegressionDifferentBindingRefused
  , freezeRegressionRevokedRefused
  , freezeRegressionGenerationBindIdempotent
  , freezeRegressionRebindDifferentGenerationRefused
  , freezeRegressionFrozenAdmitsOnlyReservation
  , CascadeTerminalAuditReceipt
  , CascadeTerminalAuditVerdict (..)
  , mkCascadeTerminalAuditReceipt
  , cascadeTerminalAuditReceiptScopeDigest
  , cascadeTerminalAuditReceiptQueryDigest
  , cascadeTerminalAuditReceiptRetainedSetDigest
  , cascadeTerminalAuditReceiptVerdict
  , cascadeAuditFreezeBindingScopeDigest
  , ProviderAdmissionAuditRecordRefusal (..)
  , ProviderAdmissionAuditReadBackRefusal (..)
  , recordCascadeTerminalAuditReceiptInternal
  , observedCascadeTerminalAuditReceiptInternal
  , confirmCascadeTerminalAuditReceipt
  , CascadeTerminalAuditReceiptRegression (..)
  , fixedCascadeTerminalAuditReceiptRegression
  , ProviderCredentialRevocationReceipt
  , mkProviderCredentialRevocationReceipt
  , ProviderAdmissionRevokeRefusal (..)
  , revokeCascadeProviderCredentialInternal
  , revokedCascadeTerminalAuditReceiptInternal
  , CascadeCredentialRevocationRegression (..)
  , fixedCascadeCredentialRevocationRegression
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (void)
import Data.Bifunctor (first)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRunId
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOperationId
  , mkCleanupRunId
  )

newtype ProviderCredentialGeneration = ProviderCredentialGeneration Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | An abstract retained shape for the future atomic freeze-and-reserve
-- transition. The current slice can validate and render this shape after
-- durable decode, but cannot construct or transition to it. The eventual
-- transition must additionally prove and retain the exact terminal-audit
-- submission key, digest, and intent in the same aggregate CAS.
data CascadeAuditFreezeBinding
  = CascadeAuditFreezeBinding
      !CleanupRunId
      !CleanupDigest
      !CleanupDigest
      !Text
      !CleanupNodeId
      !CleanupOperationId
      !CleanupAttemptId
      ![ClientSubmissionKey]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The future revoke protocol must bind independently read-back IAM and
-- retained Target generations. No constructor or transition is exported.
data ProviderCredentialRevocationReceipt
  = ProviderCredentialRevocationReceipt !CleanupDigest !CleanupDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Sprint 7.36: the durable record of one taken terminal escape audit.
--
-- It lives in the retained admission epoch rather than in the provider
-- operation record the audit's own submissions produce, and that placement is
-- the whole point.  Compaction deletes a settled submission's ledger entry, its
-- epoch binding, and its provider operation together, so a proof kept there is
-- a proof the Authority may discard under capacity pressure.  The audit's
-- verdict is what a later credential revocation is entitled to rely on, so it
-- has to outlive the record of the request that produced it.
--
-- The three digests are the audit's own identity: the scope it was taken in,
-- which must equal the reservation's; the query catalog it asked, so a clean
-- verdict claims nothing about what it did not ask; and the retained set it
-- classified against.
data CascadeTerminalAuditReceipt
  = CascadeTerminalAuditReceipt
      !Text
      !Text
      !Text
      !CascadeTerminalAuditVerdict
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | What the audit found.  All three are recordable: a receipt says what
-- happened, and refusing to record an escape or a blind spot would leave the
-- run with no durable statement of the very outcomes that must block what
-- follows.
data CascadeTerminalAuditVerdict
  = CascadeTerminalAuditReceiptClean
  | CascadeTerminalAuditReceiptEscaped !Natural
  | CascadeTerminalAuditReceiptUnobservable !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkCascadeTerminalAuditReceipt
  :: Text
  -> Text
  -> Text
  -> CascadeTerminalAuditVerdict
  -> Either ProviderAdmissionEpochError CascadeTerminalAuditReceipt
mkCascadeTerminalAuditReceipt scopeDigest queryDigest retainedDigest verdict = do
  requireDigest scopeDigest
  requireDigest queryDigest
  requireDigest retainedDigest
  case verdict of
    CascadeTerminalAuditReceiptClean -> Right ()
    CascadeTerminalAuditReceiptEscaped count
      | count == 0 -> Left (ProviderAdmissionAuditReceiptCountInvalid count)
      | otherwise -> Right ()
    CascadeTerminalAuditReceiptUnobservable count
      | count == 0 -> Left (ProviderAdmissionAuditReceiptCountInvalid count)
      | otherwise -> Right ()
  Right
    ( CascadeTerminalAuditReceipt
        scopeDigest
        queryDigest
        retainedDigest
        verdict
    )
 where
  requireDigest digest
    | isLowerHexSha256 digest = Right ()
    | otherwise = Left (ProviderAdmissionAuditReceiptDigestInvalid digest)

cascadeTerminalAuditReceiptScopeDigest :: CascadeTerminalAuditReceipt -> Text
cascadeTerminalAuditReceiptScopeDigest
  (CascadeTerminalAuditReceipt scopeDigest _ _ _) = scopeDigest

cascadeTerminalAuditReceiptQueryDigest :: CascadeTerminalAuditReceipt -> Text
cascadeTerminalAuditReceiptQueryDigest
  (CascadeTerminalAuditReceipt _ queryDigest _ _) = queryDigest

cascadeTerminalAuditReceiptRetainedSetDigest
  :: CascadeTerminalAuditReceipt -> Text
cascadeTerminalAuditReceiptRetainedSetDigest
  (CascadeTerminalAuditReceipt _ _ retainedDigest _) = retainedDigest

cascadeTerminalAuditReceiptVerdict
  :: CascadeTerminalAuditReceipt -> CascadeTerminalAuditVerdict
cascadeTerminalAuditReceiptVerdict
  (CascadeTerminalAuditReceipt _ _ _ verdict) = verdict

cascadeAuditFreezeBindingScopeDigest :: CascadeAuditFreezeBinding -> Text
cascadeAuditFreezeBindingScopeDigest
  (CascadeAuditFreezeBinding _ _ _ scopeDigest _ _ _ _) = scopeDigest

data ProviderAdmissionEpoch
  = ProviderAdmissionLegacyServingUnboundInternal
  | ProviderAdmissionServingInternal !ProviderCredentialGeneration
  | ProviderAdmissionCascadeAuditFrozenInternal
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
  | -- | Sprint 7.36: the revoked state carries the audit receipt that licensed
    -- it as well as the revocation's own. Dropping the audit's verdict at the
    -- moment the credential goes away would discard the durable statement that
    -- the surface was clean, which is the one thing nothing after this point
    -- can re-establish.
    ProviderAdmissionCascadeCredentialRevokedInternal
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
      !ProviderCredentialRevocationReceipt
  | -- | Sprint 7.36: the audit named by the reservation has been taken and its
    -- receipt is durable.  Appended, so every earlier constructor keeps its
    -- @Serialise@ index and no retained aggregate re-decodes as a different
    -- state.
    ProviderAdmissionCascadeAuditRecordedInternal
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Non-authorizing retained-state view. It intentionally omits the hidden
-- freeze binding and revocation receipt.
data ProviderAdmissionEpochView
  = ProviderAdmissionLegacyServingUnbound
  | ProviderAdmissionServing !Natural
  | ProviderAdmissionCascadeAuditFrozen !Natural
  | ProviderAdmissionCascadeCredentialRevoked !Natural
  | ProviderAdmissionCascadeAuditRecorded !Natural
  deriving stock (Eq, Show)

data ProviderAdmissionEpochError
  = ProviderAdmissionCredentialGenerationInvalid !Natural
  | ProviderAdmissionFreezeScopeDigestInvalid !Text
  | ProviderAdmissionFreezeExpectedSubmissionsEmpty
  | ProviderAdmissionFreezeExpectedSubmissionsExceedMaximum !Int !Int
  | ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
  | ProviderAdmissionAuditReceiptDigestInvalid !Text
  | -- | A verdict counting zero escapes or zero blind spots is the clean
    -- verdict wearing another constructor.
    ProviderAdmissionAuditReceiptCountInvalid !Natural
  | -- | One read-back digest standing for both proofs a revocation must bind.
    ProviderAdmissionRevocationProofsNotIndependent
  deriving stock (Eq, Show)

data ProviderAdmissionFreshSubmissionRefusal
  = ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  | ProviderAdmissionFreshSubmissionCredentialRevoked
  deriving stock (Eq, Show)

maximumExpectedProviderSubmissions :: Int
maximumExpectedProviderSubmissions = 4096

initialLegacyProviderAdmissionEpochInternal :: ProviderAdmissionEpoch
initialLegacyProviderAdmissionEpochInternal =
  ProviderAdmissionLegacyServingUnboundInternal

providerAdmissionEpochView
  :: ProviderAdmissionEpoch -> ProviderAdmissionEpochView
providerAdmissionEpochView epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal ->
    ProviderAdmissionLegacyServingUnbound
  ProviderAdmissionServingInternal generation ->
    ProviderAdmissionServing (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeAuditFrozenInternal generation _ ->
    ProviderAdmissionCascadeAuditFrozen
      (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeCredentialRevokedInternal generation _ _ _ ->
    ProviderAdmissionCascadeCredentialRevoked
      (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeAuditRecordedInternal generation _ _ ->
    ProviderAdmissionCascadeAuditRecorded
      (providerCredentialGenerationValue generation)

validateProviderAdmissionEpochInternal
  :: ProviderAdmissionEpoch -> Either ProviderAdmissionEpochError ()
validateProviderAdmissionEpochInternal epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> Right ()
  ProviderAdmissionServingInternal generation -> validateGeneration generation
  ProviderAdmissionCascadeAuditFrozenInternal generation binding -> do
    validateGeneration generation
    validateCascadeAuditFreezeBinding binding
  ProviderAdmissionCascadeCredentialRevokedInternal generation binding receipt _ -> do
    validateGeneration generation
    validateCascadeAuditFreezeBinding binding
    validateCascadeTerminalAuditReceipt receipt
  ProviderAdmissionCascadeAuditRecordedInternal generation binding receipt -> do
    validateGeneration generation
    validateCascadeAuditFreezeBinding binding
    validateCascadeTerminalAuditReceipt receipt

-- | Whether a fresh Provider submission is fenced by the current epoch.
--
-- Sprint 4.85: the frozen arm now consults the freeze binding\'s reservation.
-- A freeze that fenced /every/ fresh submission would fence the terminal audit
-- it exists to run, so the audit could never be submitted and the frozen state
-- would be a dead end. The binding names the exact submission keys the freeze
-- reserved, and only those are admitted; every other fresh submission is
-- refused exactly as before.
--
-- Revocation admits nothing: after revocation there is no credential to
-- execute a reserved submission with.
providerAdmissionFreshSubmissionRefusalInternal
  :: ProviderAdmissionEpoch
  -> ClientSubmissionKey
  -> Maybe ProviderAdmissionFreshSubmissionRefusal
providerAdmissionFreshSubmissionRefusalInternal epoch submissionKey = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionCascadeAuditFrozenInternal _ binding
    | submissionKey `elem` cascadeAuditFreezeBindingExpectedSubmissions binding ->
        Nothing
    | otherwise -> Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  -- Sprint 7.36: recording the receipt does not lift the fence. The reservation
  -- keeps admitting exactly its own submissions, because the audit's read-back
  -- and any response-loss retry are still that same reserved work; what lifts
  -- the fence is the revocation, which ends the credential outright.
  ProviderAdmissionCascadeAuditRecordedInternal _ binding _
    | submissionKey `elem` cascadeAuditFreezeBindingExpectedSubmissions binding ->
        Nothing
    | otherwise -> Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  ProviderAdmissionCascadeCredentialRevokedInternal {} ->
    Just ProviderAdmissionFreshSubmissionCredentialRevoked

cascadeAuditFreezeBindingExpectedSubmissions
  :: CascadeAuditFreezeBinding -> [ClientSubmissionKey]
cascadeAuditFreezeBindingExpectedSubmissions
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ keys) = keys

-- | Pending Provider work observed in the same aggregate read as the freeze.
--
-- It is a value the caller projects from the retained aggregate rather than a
-- list the caller composes: a freeze whose pending-work proof came from a
-- separate read could be issued against an aggregate that had since accepted a
-- submission, which is the race the atomicity requirement exists to remove.
data ProviderPendingWork
  = NoPendingProviderWork
  | PendingProviderWork !Int
  deriving stock (Eq, Show)

data ProviderAdmissionFreezeRefusal
  = -- | The epoch has no bound credential generation, so a freeze could not
    -- name which generation it fenced and a later revoke could not prove which
    -- one it revoked.
    ProviderAdmissionFreezeGenerationUnbound
  | -- | Pending Provider work exists. Freezing over it would fence the retries
    -- that could settle it, stranding admitted operations.
    ProviderAdmissionFreezePendingWorkPresent !Int
  | -- | Already frozen under a different reservation. A second freeze would
    -- silently replace the reservation the first one committed.
    ProviderAdmissionFreezeAlreadyFrozenDifferently
  | -- | The credential is revoked; there is nothing left to fence.
    ProviderAdmissionFreezeCredentialRevoked
  | ProviderAdmissionFreezeBindingInvalid !ProviderAdmissionEpochError
  deriving stock (Eq, Show)

-- | Bind the serving credential generation.
--
-- Idempotent on the same generation, because a lost response must not be
-- distinguishable from a repeat. A different generation is refused rather than
-- replacing the bound one, and neither a frozen nor a revoked epoch may be
-- rebound.
bindProviderAdmissionServingGenerationInternal
  :: ProviderAdmissionEpoch
  -> Natural
  -> Either ProviderAdmissionEpochError ProviderAdmissionEpoch
bindProviderAdmissionServingGenerationInternal epoch generation = do
  bound <- providerCredentialGeneration generation
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal ->
      Right (ProviderAdmissionServingInternal bound)
    ProviderAdmissionServingInternal existing
      | existing == bound -> Right epoch
      | otherwise ->
          Left
            ( ProviderAdmissionCredentialGenerationInvalid
                (providerCredentialGenerationValue existing)
            )
    ProviderAdmissionCascadeAuditFrozenInternal existing _ ->
      Left
        ( ProviderAdmissionCredentialGenerationInvalid
            (providerCredentialGenerationValue existing)
        )
    ProviderAdmissionCascadeCredentialRevokedInternal existing _ _ _ ->
      Left
        ( ProviderAdmissionCredentialGenerationInvalid
            (providerCredentialGenerationValue existing)
        )
    ProviderAdmissionCascadeAuditRecordedInternal existing _ _ ->
      Left
        ( ProviderAdmissionCredentialGenerationInvalid
            (providerCredentialGenerationValue existing)
        )

-- | Atomically freeze admission and reserve the terminal-audit submission.
--
-- The pending-work proof and the transition are one step over one aggregate, so
-- there is no window in which a submission is accepted between the proof and
-- the fence. Re-issuing the identical freeze is accepted unchanged: a lost
-- response must not burn a second reservation, and a second freeze under a
-- different binding is refused rather than replacing the first.
freezeProviderAdmissionForCascadeAuditInternal
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> ProviderPendingWork
  -> Either ProviderAdmissionFreezeRefusal ProviderAdmissionEpoch
freezeProviderAdmissionForCascadeAuditInternal epoch binding pending = do
  case validateCascadeAuditFreezeBinding binding of
    Left err -> Left (ProviderAdmissionFreezeBindingInvalid err)
    Right () -> Right ()
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal ->
      Left ProviderAdmissionFreezeGenerationUnbound
    ProviderAdmissionCascadeCredentialRevokedInternal {} ->
      Left ProviderAdmissionFreezeCredentialRevoked
    ProviderAdmissionCascadeAuditFrozenInternal _ existing
      | existing == binding -> Right epoch
      | otherwise -> Left ProviderAdmissionFreezeAlreadyFrozenDifferently
    -- Sprint 7.36: a lost freeze response retried after the receipt was
    -- recorded returns the recorded epoch unchanged. Re-entering the frozen
    -- state would discard a durable audit result, which is exactly the thing
    -- this record exists so nothing can do.
    ProviderAdmissionCascadeAuditRecordedInternal _ existing _
      | existing == binding -> Right epoch
      | otherwise -> Left ProviderAdmissionFreezeAlreadyFrozenDifferently
    ProviderAdmissionServingInternal generation -> case pending of
      PendingProviderWork count ->
        Left (ProviderAdmissionFreezePendingWorkPresent count)
      NoPendingProviderWork ->
        Right (ProviderAdmissionCascadeAuditFrozenInternal generation binding)

-- | Mint the revocation's two-sided proof.
--
-- The two digests are independent read-backs — the joint IAM family disposition
-- and the retained Target generation's revocation — and they may not be the
-- same value: one proof standing for both is precisely the substitution this
-- receipt exists to prevent.
mkProviderCredentialRevocationReceipt
  :: CleanupDigest
  -> CleanupDigest
  -> Either ProviderAdmissionEpochError ProviderCredentialRevocationReceipt
mkProviderCredentialRevocationReceipt iamDigest targetDigest
  | iamDigest == targetDigest =
      Left ProviderAdmissionRevocationProofsNotIndependent
  | otherwise =
      Right (ProviderCredentialRevocationReceipt iamDigest targetDigest)

-- | Why the cascade credential could not be revoked.
data ProviderAdmissionRevokeRefusal
  = -- | Nothing fenced this credential, so there is no cascade whose audit
    -- could have licensed the revocation.
    ProviderAdmissionRevokeNotFrozen
  | -- | The fence is in place but the audit's verdict is not durable. Revoking
    -- here would destroy the only credential that could re-run the audit, with
    -- no record of what it found.
    ProviderAdmissionRevokeAuditNotRecorded
  | ProviderAdmissionRevokeBindingMismatch
  | -- | The audit ran and did not come back clean. The credential is what a
    -- retry or an operator investigation needs, so an escape or a blind spot
    -- withholds the revocation rather than being overridden by it.
    ProviderAdmissionRevokeAuditNotClean !CascadeTerminalAuditVerdict
  | ProviderAdmissionRevokeAlreadyRevokedDifferently
  deriving stock (Eq, Show)

-- | Revoke the cascade's Provider credential.
--
-- It is reachable only from the recorded state, and only over a clean verdict,
-- so the ordering \"fence, audit, record, revoke\" is a property of the type
-- rather than of the caller. Idempotent on the identical receipt.
revokeCascadeProviderCredentialInternal
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> ProviderCredentialRevocationReceipt
  -> Either ProviderAdmissionRevokeRefusal ProviderAdmissionEpoch
revokeCascadeProviderCredentialInternal epoch binding revocation = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal ->
    Left ProviderAdmissionRevokeNotFrozen
  ProviderAdmissionServingInternal _ -> Left ProviderAdmissionRevokeNotFrozen
  ProviderAdmissionCascadeAuditFrozenInternal _ existing
    | existing /= binding -> Left ProviderAdmissionRevokeBindingMismatch
    | otherwise -> Left ProviderAdmissionRevokeAuditNotRecorded
  ProviderAdmissionCascadeAuditRecordedInternal generation existing recorded
    | existing /= binding -> Left ProviderAdmissionRevokeBindingMismatch
    | otherwise -> case cascadeTerminalAuditReceiptVerdict recorded of
        CascadeTerminalAuditReceiptClean ->
          Right
            ( ProviderAdmissionCascadeCredentialRevokedInternal
                generation
                existing
                recorded
                revocation
            )
        verdict -> Left (ProviderAdmissionRevokeAuditNotClean verdict)
  ProviderAdmissionCascadeCredentialRevokedInternal _ existing _ recordedRevocation
    | existing /= binding -> Left ProviderAdmissionRevokeBindingMismatch
    | recordedRevocation == revocation -> Right epoch
    | otherwise -> Left ProviderAdmissionRevokeAlreadyRevokedDifferently

-- | The audit receipt a revoked epoch still carries.
--
-- Revocation ends the credential, not the record of why it was allowed to.
revokedCascadeTerminalAuditReceiptInternal
  :: ProviderAdmissionEpoch -> Maybe CascadeTerminalAuditReceipt
revokedCascadeTerminalAuditReceiptInternal epoch = case epoch of
  ProviderAdmissionCascadeCredentialRevokedInternal _ _ receipt _ -> Just receipt
  _ -> Nothing

-- | Why a terminal-audit receipt could not be recorded.
data ProviderAdmissionAuditRecordRefusal
  = -- | Nothing reserved this audit, so there is no reservation the receipt
    -- could be the result of.
    ProviderAdmissionAuditRecordNotFrozen
  | -- | A receipt for a reservation this epoch does not hold. Recording it
    -- would attribute one run's audit to another's fence.
    ProviderAdmissionAuditRecordBindingMismatch
  | -- | The audit was taken in a different scope than the one reserved, so it
    -- does not answer the question the fence was raised for.
    ProviderAdmissionAuditRecordScopeDigestMismatch !Text !Text
  | -- | A different receipt is already durable for this reservation. The first
    -- one stands: overwriting it would let a second, differently scoped or
    -- differently answered audit replace a result the run may already have
    -- acted on.
    ProviderAdmissionAuditRecordAlreadyRecordedDifferently
  | ProviderAdmissionAuditRecordCredentialRevoked
  | ProviderAdmissionAuditRecordReceiptInvalid !ProviderAdmissionEpochError
  deriving stock (Eq, Show)

-- | Record the audit's verdict against the reservation that admitted it.
--
-- Idempotent on the identical receipt, because a lost response must not be
-- distinguishable from a repeat; a /different/ receipt for the same reservation
-- is refused rather than replacing the durable one.
recordCascadeTerminalAuditReceiptInternal
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> CascadeTerminalAuditReceipt
  -> Either ProviderAdmissionAuditRecordRefusal ProviderAdmissionEpoch
recordCascadeTerminalAuditReceiptInternal epoch binding receipt = do
  case validateCascadeTerminalAuditReceipt receipt of
    Left err -> Left (ProviderAdmissionAuditRecordReceiptInvalid err)
    Right () -> Right ()
  let reservedScope = cascadeAuditFreezeBindingScopeDigest binding
      auditedScope = cascadeTerminalAuditReceiptScopeDigest receipt
  if reservedScope == auditedScope
    then Right ()
    else
      Left
        ( ProviderAdmissionAuditRecordScopeDigestMismatch
            reservedScope
            auditedScope
        )
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal ->
      Left ProviderAdmissionAuditRecordNotFrozen
    ProviderAdmissionServingInternal _ ->
      Left ProviderAdmissionAuditRecordNotFrozen
    ProviderAdmissionCascadeCredentialRevokedInternal {} ->
      Left ProviderAdmissionAuditRecordCredentialRevoked
    ProviderAdmissionCascadeAuditFrozenInternal generation existing
      | existing /= binding -> Left ProviderAdmissionAuditRecordBindingMismatch
      | otherwise ->
          Right
            ( ProviderAdmissionCascadeAuditRecordedInternal
                generation
                existing
                receipt
            )
    ProviderAdmissionCascadeAuditRecordedInternal _ existing recorded
      | existing /= binding -> Left ProviderAdmissionAuditRecordBindingMismatch
      | recorded == receipt -> Right epoch
      | otherwise -> Left ProviderAdmissionAuditRecordAlreadyRecordedDifferently

-- | Why an independently re-read epoch does not confirm a committed receipt.
data ProviderAdmissionAuditReadBackRefusal
  = ProviderAdmissionAuditReadBackAbsent
  | ProviderAdmissionAuditReadBackBindingMismatch
  | ProviderAdmissionAuditReadBackReceiptMismatch
  deriving stock (Eq, Show)

-- | The receipt this epoch carries, if it carries one.
observedCascadeTerminalAuditReceiptInternal
  :: ProviderAdmissionEpoch -> Maybe CascadeTerminalAuditReceipt
observedCascadeTerminalAuditReceiptInternal epoch = case epoch of
  ProviderAdmissionCascadeAuditRecordedInternal _ _ receipt -> Just receipt
  _ -> Nothing

-- | Confirm a committed receipt against an independently re-read epoch.
--
-- The write returns its own decision; this reads the durable object again and
-- checks that what is there is the receipt that was committed, under the
-- reservation it was committed against. A commit whose response was lost is
-- confirmed here rather than re-committed, and a commit that silently landed
-- somewhere else is not confirmed at all.
confirmCascadeTerminalAuditReceipt
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> CascadeTerminalAuditReceipt
  -> Either ProviderAdmissionAuditReadBackRefusal ()
confirmCascadeTerminalAuditReceipt epoch binding committed =
  case epoch of
    ProviderAdmissionCascadeAuditRecordedInternal _ existing recorded
      | existing /= binding ->
          Left ProviderAdmissionAuditReadBackBindingMismatch
      | recorded /= committed ->
          Left ProviderAdmissionAuditReadBackReceiptMismatch
      | otherwise -> Right ()
    _ -> Left ProviderAdmissionAuditReadBackAbsent

validateCascadeTerminalAuditReceipt
  :: CascadeTerminalAuditReceipt -> Either ProviderAdmissionEpochError ()
validateCascadeTerminalAuditReceipt receipt =
  void
    ( mkCascadeTerminalAuditReceipt
        (cascadeTerminalAuditReceiptScopeDigest receipt)
        (cascadeTerminalAuditReceiptQueryDigest receipt)
        (cascadeTerminalAuditReceiptRetainedSetDigest receipt)
        (cascadeTerminalAuditReceiptVerdict receipt)
    )

providerCredentialGeneration
  :: Natural
  -> Either ProviderAdmissionEpochError ProviderCredentialGeneration
providerCredentialGeneration generation
  | generation == 0 =
      Left (ProviderAdmissionCredentialGenerationInvalid generation)
  | otherwise = Right (ProviderCredentialGeneration generation)

validateGeneration
  :: ProviderCredentialGeneration -> Either ProviderAdmissionEpochError ()
validateGeneration (ProviderCredentialGeneration generation)
  | generation == 0 =
      Left (ProviderAdmissionCredentialGenerationInvalid generation)
  | otherwise = Right ()

providerCredentialGenerationValue :: ProviderCredentialGeneration -> Natural
providerCredentialGenerationValue (ProviderCredentialGeneration generation) =
  generation

mkCascadeAuditFreezeBinding
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupDigest
  -> Text
  -> CleanupNodeId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> [ClientSubmissionKey]
  -> Either ProviderAdmissionEpochError CascadeAuditFreezeBinding
mkCascadeAuditFreezeBinding
  runId
  descriptorDigest
  graphDigest
  scopeDigest
  nodeId
  operationId
  attemptId
  expectedSubmissionKeys = do
    let binding =
          CascadeAuditFreezeBinding
            runId
            descriptorDigest
            graphDigest
            scopeDigest
            nodeId
            operationId
            attemptId
            expectedSubmissionKeys
    validateCascadeAuditFreezeBinding binding
    Right binding

validateCascadeAuditFreezeBinding
  :: CascadeAuditFreezeBinding -> Either ProviderAdmissionEpochError ()
validateCascadeAuditFreezeBinding
  (CascadeAuditFreezeBinding _ _ _ scopeDigest _ _ _ keys)
    | not (isLowerHexSha256 scopeDigest) =
        Left (ProviderAdmissionFreezeScopeDigestInvalid scopeDigest)
    | null keys = Left ProviderAdmissionFreezeExpectedSubmissionsEmpty
    | length keys > maximumExpectedProviderSubmissions =
        Left
          ( ProviderAdmissionFreezeExpectedSubmissionsExceedMaximum
              (length keys)
              maximumExpectedProviderSubmissions
          )
    | keys /= sort (nub keys) =
        Left ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
    | otherwise = Right ()

data ProviderPendingClassification
  = ProviderNoPendingSubmissions
  | ProviderOwnedPendingSubmissions ![Text]
  | ProviderUnownedPendingSubmissions ![Text]
  deriving stock (Eq, Show)

-- | Pure inventory classification only. It cannot freeze admission. In the
-- eventual protocol, even @ProviderNoPendingSubmissions@ is insufficient:
-- the same CAS must reserve the exact terminal-audit submission before it
-- blocks every other fresh submission.
classifyPending
  :: CascadeAuditFreezeBinding
  -> [ClientSubmissionKey]
  -> ProviderPendingClassification
classifyPending
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ expected)
  pending
    | not (null unowned) =
        ProviderUnownedPendingSubmissions
          (fmap clientSubmissionKeyText unowned)
    | not (null canonicalPending) =
        ProviderOwnedPendingSubmissions
          (fmap clientSubmissionKeyText canonicalPending)
    | otherwise = ProviderNoPendingSubmissions
   where
    canonicalPending = sort (nub pending)
    unowned = filter (`notElem` expected) canonicalPending

isLowerHexSha256 :: Text -> Bool
isLowerHexSha256 value =
  Text.length value == 64
    && Text.all (\character -> character `elem` ("0123456789abcdef" :: String)) value

data ProviderAdmissionEpochRegression = ProviderAdmissionEpochRegression
  { providerAdmissionEpochRegressionLegacyPreserved :: !Bool
  , providerAdmissionEpochRegressionServingPermitsFresh :: !Bool
  , providerAdmissionEpochRegressionFrozenRefusesFresh :: !Bool
  , providerAdmissionEpochRegressionRevokedRefusesFresh :: !Bool
  , providerAdmissionEpochRegressionNoPendingClassified :: !Bool
  , providerAdmissionEpochRegressionOwnedPendingClassified :: !Bool
  , providerAdmissionEpochRegressionUnownedPendingClassified :: !Bool
  , providerAdmissionEpochRegressionFrozenShapeValidated :: !Bool
  , providerAdmissionEpochRegressionRevokedShapeValidated :: !Bool
  , providerAdmissionEpochRegressionInvalidGenerationRefused :: !Bool
  , providerAdmissionEpochRegressionNonCanonicalBindingRefused :: !Bool
  }
  deriving stock (Eq, Show)

-- | Closed, non-authorizing coverage for otherwise hidden retained shapes.
-- It returns booleans only and cannot yield an epoch, binding, reservation,
-- or revocation receipt.
fixedProviderAdmissionEpochRegression
  :: Either Text ProviderAdmissionEpochRegression
fixedProviderAdmissionEpochRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  (keyA, keyB) <- case freezeBindingSubmissionKeys binding of
    [firstKey, secondKey] -> Right (firstKey, secondKey)
    _ -> Left "fixed Provider admission binding has unexpected key count"
  keyC <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/c")
  generation <- firstShow (providerCredentialGeneration 1)
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  let serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          fixedCleanAuditReceipt
          (ProviderCredentialRevocationReceipt iamDigest targetDigest)
      nonCanonicalBinding = replaceFreezeBindingKeys [keyB, keyA] binding
  pure
    ProviderAdmissionEpochRegression
      { providerAdmissionEpochRegressionLegacyPreserved =
          providerAdmissionEpochView initialLegacyProviderAdmissionEpochInternal
            == ProviderAdmissionLegacyServingUnbound
            && providerAdmissionFreshSubmissionRefusalInternal
              initialLegacyProviderAdmissionEpochInternal
              keyC
              == Nothing
      , providerAdmissionEpochRegressionServingPermitsFresh =
          providerAdmissionFreshSubmissionRefusalInternal serving keyC == Nothing
      , providerAdmissionEpochRegressionFrozenRefusesFresh =
          -- An unreserved key is fenced; the reserved one is admitted, or the
          -- freeze would fence the audit it exists to run.
          providerAdmissionFreshSubmissionRefusalInternal frozen keyC
            == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
            && providerAdmissionFreshSubmissionRefusalInternal frozen keyA == Nothing
      , providerAdmissionEpochRegressionRevokedRefusesFresh =
          -- Revocation admits nothing, including the reserved key: there is no
          -- credential left to execute it with.
          providerAdmissionFreshSubmissionRefusalInternal revoked keyC
            == Just ProviderAdmissionFreshSubmissionCredentialRevoked
            && providerAdmissionFreshSubmissionRefusalInternal revoked keyA
              == Just ProviderAdmissionFreshSubmissionCredentialRevoked
      , providerAdmissionEpochRegressionNoPendingClassified =
          classifyPending binding [] == ProviderNoPendingSubmissions
      , providerAdmissionEpochRegressionOwnedPendingClassified =
          classifyPending binding [keyA]
            == ProviderOwnedPendingSubmissions [clientSubmissionKeyText keyA]
      , providerAdmissionEpochRegressionUnownedPendingClassified =
          classifyPending binding [keyC]
            == ProviderUnownedPendingSubmissions [clientSubmissionKeyText keyC]
      , providerAdmissionEpochRegressionFrozenShapeValidated =
          validateProviderAdmissionEpochInternal frozen == Right ()
      , providerAdmissionEpochRegressionRevokedShapeValidated =
          validateProviderAdmissionEpochInternal revoked == Right ()
      , providerAdmissionEpochRegressionInvalidGenerationRefused =
          providerCredentialGeneration 0
            == Left (ProviderAdmissionCredentialGenerationInvalid 0)
      , providerAdmissionEpochRegressionNonCanonicalBindingRefused =
          validateCascadeAuditFreezeBinding nonCanonicalBinding
            == Left ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
      }

fixedCascadeAuditFreezeBinding
  :: Either Text CascadeAuditFreezeBinding
fixedCascadeAuditFreezeBinding = do
  runId <- mkCleanupRunId "provider-epoch-regression"
  nodeId <- mkCleanupNodeId "provider-epoch-audit"
  operationId <- mkCleanupOperationId "provider-epoch-audit-operation"
  attemptId <- mkCleanupAttemptId "provider-epoch-audit-attempt"
  descriptorDigest <- mkCleanupDigest (Text.replicate 64 "a")
  graphDigest <- mkCleanupDigest (Text.replicate 64 "b")
  keyA <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/a")
  keyB <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/b")
  firstShow
    ( mkCascadeAuditFreezeBinding
        runId
        descriptorDigest
        graphDigest
        (Text.replicate 64 "e")
        nodeId
        operationId
        attemptId
        [keyA, keyB]
    )

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

freezeBindingSubmissionKeys
  :: CascadeAuditFreezeBinding -> [ClientSubmissionKey]
freezeBindingSubmissionKeys
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ submissionKeys) = submissionKeys

replaceFreezeBindingKeys
  :: [ClientSubmissionKey]
  -> CascadeAuditFreezeBinding
  -> CascadeAuditFreezeBinding
replaceFreezeBindingKeys
  submissionKeys
  (CascadeAuditFreezeBinding runId descriptor graph scope node operation attempt _) =
    CascadeAuditFreezeBinding
      runId
      descriptor
      graph
      scope
      node
      operation
      attempt
      submissionKeys

-- | Fixed transition matrix for the Sprint-4.85 freeze and generation binding.
--
-- The private constructors stay private, so the matrix is computed here and
-- exposed as decided facts. Every arm is a decision a caller could otherwise
-- get wrong in a way no type would catch: freezing without a bound generation,
-- freezing over pending work, re-freezing under a different reservation, and
-- fencing the reserved submission the freeze exists to admit.
data ProviderAdmissionFreezeRegression = ProviderAdmissionFreezeRegression
  { freezeRegressionUnboundGenerationRefused :: !Bool
  , freezeRegressionPendingWorkRefused :: !Bool
  , freezeRegressionServingFreezes :: !Bool
  , freezeRegressionIdenticalFreezeIdempotent :: !Bool
  , freezeRegressionDifferentBindingRefused :: !Bool
  , freezeRegressionRevokedRefused :: !Bool
  , freezeRegressionGenerationBindIdempotent :: !Bool
  , freezeRegressionRebindDifferentGenerationRefused :: !Bool
  , freezeRegressionFrozenAdmitsOnlyReservation :: !Bool
  }
  deriving stock (Eq, Show)

fixedProviderAdmissionFreezeRegression
  :: Either Text ProviderAdmissionFreezeRegression
fixedProviderAdmissionFreezeRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  reserved <- case cascadeAuditFreezeBindingExpectedSubmissions binding of
    firstKey : _ -> Right firstKey
    [] -> Left "the fixed freeze binding reserves no submission"
  unrelated <-
    first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/unrelated")
  otherBinding <- fixedAlternateCascadeAuditFreezeBinding
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  generation <- first (Text.pack . show) (providerCredentialGeneration 7)
  let legacy = ProviderAdmissionLegacyServingUnboundInternal
      serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          fixedCleanAuditReceipt
          (ProviderCredentialRevocationReceipt iamDigest targetDigest)
      freeze epoch pending =
        freezeProviderAdmissionForCascadeAuditInternal epoch binding pending
  pure
    ProviderAdmissionFreezeRegression
      { freezeRegressionUnboundGenerationRefused =
          freeze legacy NoPendingProviderWork
            == Left ProviderAdmissionFreezeGenerationUnbound
      , freezeRegressionPendingWorkRefused =
          freeze serving (PendingProviderWork 2)
            == Left (ProviderAdmissionFreezePendingWorkPresent 2)
      , freezeRegressionServingFreezes =
          freeze serving NoPendingProviderWork == Right frozen
      , freezeRegressionIdenticalFreezeIdempotent =
          freeze frozen NoPendingProviderWork == Right frozen
      , freezeRegressionDifferentBindingRefused =
          freezeProviderAdmissionForCascadeAuditInternal
            frozen
            otherBinding
            NoPendingProviderWork
            == Left ProviderAdmissionFreezeAlreadyFrozenDifferently
      , freezeRegressionRevokedRefused =
          freeze revoked NoPendingProviderWork
            == Left ProviderAdmissionFreezeCredentialRevoked
      , freezeRegressionGenerationBindIdempotent =
          bindProviderAdmissionServingGenerationInternal legacy 7 == Right serving
            && bindProviderAdmissionServingGenerationInternal serving 7 == Right serving
      , freezeRegressionRebindDifferentGenerationRefused =
          isLeftBind (bindProviderAdmissionServingGenerationInternal serving 8)
            && isLeftBind (bindProviderAdmissionServingGenerationInternal frozen 7)
      , freezeRegressionFrozenAdmitsOnlyReservation =
          providerAdmissionFreshSubmissionRefusalInternal frozen reserved == Nothing
            && providerAdmissionFreshSubmissionRefusalInternal frozen unrelated
              == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
      }
 where
  isLeftBind result = case result of
    Left _ -> True
    Right _ -> False

-- | A second freeze binding that differs only in its scope digest and reserved
-- submission, so "a different binding is refused" is a real comparison rather
-- than a comparison against a value that differs in every field.
-- | Decided facts about recording and reading back a terminal-audit receipt,
-- exposed without exporting a way to perform either transition.
data CascadeTerminalAuditReceiptRegression = CascadeTerminalAuditReceiptRegression
  { auditReceiptRegressionRecordedFromFrozen :: !Bool
  , auditReceiptRegressionServingRefused :: !Bool
  , auditReceiptRegressionOtherBindingRefused :: !Bool
  , auditReceiptRegressionScopeMismatchRefused :: !Bool
  , auditReceiptRegressionIdenticalRecordIdempotent :: !Bool
  , auditReceiptRegressionDifferentReceiptRefused :: !Bool
  , auditReceiptRegressionRevokedRefused :: !Bool
  , auditReceiptRegressionFreezeAfterRecordPreservesIt :: !Bool
  , auditReceiptRegressionReadBackConfirms :: !Bool
  , auditReceiptRegressionReadBackRefusesOther :: !Bool
  , auditReceiptRegressionReadBackRefusesUnrecorded :: !Bool
  , auditReceiptRegressionRecordedAdmitsOnlyReservation :: !Bool
  , auditReceiptRegressionEmptyCountRefused :: !Bool
  , auditReceiptRegressionNonDigestRefused :: !Bool
  }
  deriving stock (Eq, Show)

fixedCascadeTerminalAuditReceiptRegression
  :: Either Text CascadeTerminalAuditReceiptRegression
fixedCascadeTerminalAuditReceiptRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  otherBinding <- fixedAlternateCascadeAuditFreezeBinding
  reserved <- case cascadeAuditFreezeBindingExpectedSubmissions binding of
    firstKey : _ -> Right firstKey
    [] -> Left "the fixed freeze binding reserves no submission"
  unrelated <-
    first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/unrelated")
  generation <- first (Text.pack . show) (providerCredentialGeneration 7)
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  clean <- firstShow (receiptFor CascadeTerminalAuditReceiptClean)
  escaped <- firstShow (receiptFor (CascadeTerminalAuditReceiptEscaped 2))
  foreignScope <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (Text.replicate 64 "f")
          queryDigest
          retainedDigest
          CascadeTerminalAuditReceiptClean
      )
  let serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      recorded =
        ProviderAdmissionCascadeAuditRecordedInternal generation binding clean
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          clean
          (ProviderCredentialRevocationReceipt iamDigest targetDigest)
      record epoch bound value =
        recordCascadeTerminalAuditReceiptInternal epoch bound value
  pure
    CascadeTerminalAuditReceiptRegression
      { auditReceiptRegressionRecordedFromFrozen =
          record frozen binding clean == Right recorded
      , auditReceiptRegressionServingRefused =
          record serving binding clean
            == Left ProviderAdmissionAuditRecordNotFrozen
      , auditReceiptRegressionOtherBindingRefused =
          record frozen otherBinding clean
            == Left
              ( ProviderAdmissionAuditRecordScopeDigestMismatch
                  (cascadeAuditFreezeBindingScopeDigest otherBinding)
                  (cascadeTerminalAuditReceiptScopeDigest clean)
              )
      , auditReceiptRegressionScopeMismatchRefused =
          record frozen binding foreignScope
            == Left
              ( ProviderAdmissionAuditRecordScopeDigestMismatch
                  (cascadeAuditFreezeBindingScopeDigest binding)
                  (Text.replicate 64 "f")
              )
      , auditReceiptRegressionIdenticalRecordIdempotent =
          record recorded binding clean == Right recorded
      , auditReceiptRegressionDifferentReceiptRefused =
          record recorded binding escaped
            == Left ProviderAdmissionAuditRecordAlreadyRecordedDifferently
      , auditReceiptRegressionRevokedRefused =
          record revoked binding clean
            == Left ProviderAdmissionAuditRecordCredentialRevoked
      , auditReceiptRegressionFreezeAfterRecordPreservesIt =
          freezeProviderAdmissionForCascadeAuditInternal
            recorded
            binding
            NoPendingProviderWork
            == Right recorded
      , auditReceiptRegressionReadBackConfirms =
          confirmCascadeTerminalAuditReceipt recorded binding clean
            == Right ()
            && observedCascadeTerminalAuditReceiptInternal recorded == Just clean
      , auditReceiptRegressionReadBackRefusesOther =
          confirmCascadeTerminalAuditReceipt recorded binding escaped
            == Left ProviderAdmissionAuditReadBackReceiptMismatch
            && confirmCascadeTerminalAuditReceipt
              recorded
              otherBinding
              clean
              == Left ProviderAdmissionAuditReadBackBindingMismatch
      , auditReceiptRegressionReadBackRefusesUnrecorded =
          confirmCascadeTerminalAuditReceipt frozen binding clean
            == Left ProviderAdmissionAuditReadBackAbsent
            && observedCascadeTerminalAuditReceiptInternal frozen == Nothing
      , auditReceiptRegressionRecordedAdmitsOnlyReservation =
          providerAdmissionFreshSubmissionRefusalInternal recorded reserved
            == Nothing
            && providerAdmissionFreshSubmissionRefusalInternal recorded unrelated
              == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
      , auditReceiptRegressionEmptyCountRefused =
          receiptFor (CascadeTerminalAuditReceiptEscaped 0)
            == Left (ProviderAdmissionAuditReceiptCountInvalid 0)
            && receiptFor (CascadeTerminalAuditReceiptUnobservable 0)
              == Left (ProviderAdmissionAuditReceiptCountInvalid 0)
      , auditReceiptRegressionNonDigestRefused =
          mkCascadeTerminalAuditReceipt
            "not-a-digest"
            queryDigest
            retainedDigest
            CascadeTerminalAuditReceiptClean
            == Left (ProviderAdmissionAuditReceiptDigestInvalid "not-a-digest")
      }
 where
  queryDigest = Text.replicate 64 "1"
  retainedDigest = Text.replicate 64 "2"
  receiptFor =
    mkCascadeTerminalAuditReceipt
      (Text.replicate 64 "e")
      queryDigest
      retainedDigest

-- | The clean receipt the freeze regression's revoked fixture carries.
fixedCleanAuditReceipt :: CascadeTerminalAuditReceipt
fixedCleanAuditReceipt =
  CascadeTerminalAuditReceipt
    (Text.replicate 64 "e")
    (Text.replicate 64 "1")
    (Text.replicate 64 "2")
    CascadeTerminalAuditReceiptClean

-- | Decided facts about the revocation transition, exposed without exporting a
-- way to perform one.
data CascadeCredentialRevocationRegression = CascadeCredentialRevocationRegression
  { revocationRegressionServingRefused :: !Bool
  , revocationRegressionFrozenRefusedUnrecorded :: !Bool
  , revocationRegressionOtherBindingRefused :: !Bool
  , revocationRegressionCleanRecordRevokes :: !Bool
  , revocationRegressionEscapeVerdictRefused :: !Bool
  , revocationRegressionUnobservableVerdictRefused :: !Bool
  , revocationRegressionIdenticalRevokeIdempotent :: !Bool
  , revocationRegressionDifferentReceiptRefused :: !Bool
  , revocationRegressionAuditReceiptSurvives :: !Bool
  , revocationRegressionRevokedRefusesFresh :: !Bool
  , revocationRegressionSharedProofRefused :: !Bool
  }
  deriving stock (Eq, Show)

fixedCascadeCredentialRevocationRegression
  :: Either Text CascadeCredentialRevocationRegression
fixedCascadeCredentialRevocationRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  otherBinding <- fixedAlternateCascadeAuditFreezeBinding
  reserved <- case cascadeAuditFreezeBindingExpectedSubmissions binding of
    firstKey : _ -> Right firstKey
    [] -> Left "the fixed freeze binding reserves no submission"
  generation <- first (Text.pack . show) (providerCredentialGeneration 7)
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  revocation <-
    firstShow (mkProviderCredentialRevocationReceipt iamDigest targetDigest)
  otherRevocation <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          targetDigest
          iamDigest
      )
  escapedReceipt <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (Text.replicate 64 "e")
          (Text.replicate 64 "1")
          (Text.replicate 64 "2")
          (CascadeTerminalAuditReceiptEscaped 2)
      )
  unobservableReceipt <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (Text.replicate 64 "e")
          (Text.replicate 64 "1")
          (Text.replicate 64 "2")
          (CascadeTerminalAuditReceiptUnobservable 1)
      )
  let serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      recordedWith receipt =
        ProviderAdmissionCascadeAuditRecordedInternal generation binding receipt
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          fixedCleanAuditReceipt
          revocation
      revoke epoch bound proof =
        revokeCascadeProviderCredentialInternal epoch bound proof
  pure
    CascadeCredentialRevocationRegression
      { revocationRegressionServingRefused =
          revoke serving binding revocation
            == Left ProviderAdmissionRevokeNotFrozen
      , revocationRegressionFrozenRefusedUnrecorded =
          revoke frozen binding revocation
            == Left ProviderAdmissionRevokeAuditNotRecorded
      , revocationRegressionOtherBindingRefused =
          revoke frozen otherBinding revocation
            == Left ProviderAdmissionRevokeBindingMismatch
      , revocationRegressionCleanRecordRevokes =
          revoke (recordedWith fixedCleanAuditReceipt) binding revocation
            == Right revoked
      , revocationRegressionEscapeVerdictRefused =
          revoke (recordedWith escapedReceipt) binding revocation
            == Left
              ( ProviderAdmissionRevokeAuditNotClean
                  (CascadeTerminalAuditReceiptEscaped 2)
              )
      , revocationRegressionUnobservableVerdictRefused =
          revoke (recordedWith unobservableReceipt) binding revocation
            == Left
              ( ProviderAdmissionRevokeAuditNotClean
                  (CascadeTerminalAuditReceiptUnobservable 1)
              )
      , revocationRegressionIdenticalRevokeIdempotent =
          revoke revoked binding revocation == Right revoked
      , revocationRegressionDifferentReceiptRefused =
          revoke revoked binding otherRevocation
            == Left ProviderAdmissionRevokeAlreadyRevokedDifferently
      , revocationRegressionAuditReceiptSurvives =
          revokedCascadeTerminalAuditReceiptInternal revoked
            == Just fixedCleanAuditReceipt
      , revocationRegressionRevokedRefusesFresh =
          providerAdmissionFreshSubmissionRefusalInternal revoked reserved
            == Just ProviderAdmissionFreshSubmissionCredentialRevoked
      , revocationRegressionSharedProofRefused =
          mkProviderCredentialRevocationReceipt iamDigest iamDigest
            == Left ProviderAdmissionRevocationProofsNotIndependent
      }

fixedAlternateCascadeAuditFreezeBinding
  :: Either Text CascadeAuditFreezeBinding
fixedAlternateCascadeAuditFreezeBinding = do
  runId <- mkCleanupRunId "provider-epoch-regression"
  nodeId <- mkCleanupNodeId "provider-epoch-audit"
  operationId <- mkCleanupOperationId "provider-epoch-audit-operation"
  attemptId <- mkCleanupAttemptId "provider-epoch-audit-attempt"
  descriptorDigest <- mkCleanupDigest (Text.replicate 64 "a")
  graphDigest <- mkCleanupDigest (Text.replicate 64 "b")
  otherKey <-
    first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/other")
  first
    (Text.pack . show)
    ( mkCascadeAuditFreezeBinding
        runId
        descriptorDigest
        graphDigest
        (Text.replicate 64 "f")
        nodeId
        operationId
        attemptId
        [otherKey]
    )
