{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private retained state for the Lifecycle Provider admission
-- epoch. The public facade exposes only read-only views and fixed diagnostics.
--
-- Mutation reservations fence fresh Provider work in the same retained
-- aggregate as cascade admission. A completed credential operation publishes
-- its bounded predecessor archive before a server-owned independent Agent
-- observation may advance the epoch. Tracked phases keep the immutable
-- archive link through later freeze, audit and revocation transitions.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
  ( ProviderAdmissionEpoch
  , ProviderAdmissionEpochView (..)
  , ProviderCredentialRecoveryView (..)
  , providerCredentialRecoveryViewInternal
  , providerCredentialServingOperationInternal
  , validateProviderCredentialRecoveryView
  , ProviderCredentialMutationReservation
  , ProviderCredentialMutationOrigin
  , ProviderCredentialMutationRefusal (..)
  , mkProviderCredentialInstallReservation
  , mkProviderCredentialMutationReservation
  , reserveProviderCredentialMutationInternal
  , reserveProviderCredentialCleanupInternal
  , providerCredentialCleanupOperationId
  , providerCredentialCleanupDraftMatches
  , fixedProviderCredentialCleanupRegression
  , reserveProviderCredentialMutationAfterPredecessorInternal
  , completeProviderCredentialRevokeInternal
  , providerCredentialLineageArchiveAction
  , providerCredentialLineageArchiveReservationInternal
  , fixedProviderCredentialMutationFenceRegression
  , reserveProviderCredentialInstallInternal
  , fixedProviderCredentialMutationReservationRegression
  , fixedProviderCredentialLineageRegression
  , ProviderCredentialLineageArchive
  , pendingProviderCredentialLineageArchiveInternal
  , encodeProviderCredentialLineageArchive
  , providerCredentialLineageArchiveCanonicalBytes
  , providerCredentialLineageArchiveOperationId
  , providerCredentialLineageArchiveGeneration
  , providerCredentialLineageArchiveRequestDigest
  , providerCredentialLineageArchiveCompletedReportDigest
  , decodeProviderCredentialLineageArchive
  , completeProviderCredentialInstallInternal
  , fixedOrdinaryProviderCredentialRetirementRegression
  , ProviderAdmissionEpochError (..)
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , providerAdmissionEpochView
  , initialLegacyProviderAdmissionEpochInternal
  , providerAdmissionNeedsCredentialQuiescenceInternal
  , providerCredentialRetirementInstallDraftMatchesInternal
  , validateProviderAdmissionEpochInternal
  , providerAdmissionFreshSubmissionRefusalInternal
  , CascadeAuditFreezeBinding
  , mkCascadeAuditFreezeBinding
  , cascadeAuditFreezeBindingExpectedSubmissions
  , ProviderPendingWork (..)
  , ProviderAdmissionFreezeRefusal (..)
  , bindProviderAdmissionServingGenerationInternal
  , freezeProviderAdmissionForCascadeAuditInternal
  , freezeProviderAdmissionAtGenerationInternal
  , ProviderAdmissionRecoveryObservation
  , ProviderAdmissionRecoveryPhase (..)
  , providerAdmissionRecoveryRequestDigest
  , providerAdmissionRecoveryPhase
  , cascadeAuditRecoveryRequestDigest
  , ProviderAdmissionRecoveryRefusal (..)
  , observeProviderAdmissionRecoveryInternal
  , observeProviderBootstrapPredecessorInternal
  , providerPredecessorCoordinatesInternal
  , ProviderBootstrapPredecessor
  , ProviderBootstrapPredecessorPhase (..)
  , providerBootstrapPredecessorPhase
  , providerBootstrapPredecessorRunId
  , providerBootstrapPredecessorGraphDigest
  , providerBootstrapPredecessorScopeDigest
  , validateProviderBootstrapPredecessor
  , restoreCascadeAuditRecoveryBinding
  , validateProviderAdmissionRecoveryObservation
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
  , ProviderCredentialRetirementConfirmation
  , confirmProviderCredentialRetirement
  , providerCredentialRetirementMatches
  , ProviderCredentialRevocationReceipt
  , mkProviderCredentialRevocationReceipt
  , ProviderAdmissionRevokeRefusal (..)
  , revokeCascadeProviderCredentialInternal
  , revokedCascadeTerminalAuditReceiptInternal
  , CascadeCredentialRevocationRegression (..)
  , fixedCascadeCredentialRevocationRegression
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, void)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.CompletedProviderPredecessor
  ( ObservedCompletedProviderPredecessor
  , ProviderPredecessorCoordinates (..)
  , completedProviderPredecessorCoordinates
  , completedProviderPredecessorReportDigest
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupDigestOfBytes
  , cleanupDigestText
  , cleanupNodeIdText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialAction (..)
  , OperatorMaterialOperationId
  , mkOperatorMaterialOperationId
  , operatorMaterialOperationIdText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
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

-- | Independently observed IAM and Target retirement digests. The receipt
-- itself is metadata; only its owned aggregate transition changes admission.
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
  | ProviderAdmissionCredentialMutationPendingInternal
      !ProviderCredentialMutationReservation
      !ProviderCredentialMutationOrigin
  | ProviderAdmissionTrackedInternal !ProviderCredentialServingLineage !ProviderAdmissionTrackedPhase
  | ProviderAdmissionOrdinaryCredentialRetiredInternal
      !ProviderCredentialGeneration
      !ProviderCredentialRevocationReceipt
      !(Maybe ProviderCredentialServingLineage)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderCredentialServingLineage = ProviderCredentialServingLineage !Text !CleanupDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderAdmissionTrackedPhase
  = ProviderTrackedServing !ProviderCredentialGeneration
  | ProviderTrackedFrozen !ProviderCredentialGeneration !CascadeAuditFreezeBinding
  | ProviderTrackedRecorded
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
  | ProviderTrackedRevoked
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
      !ProviderCredentialRevocationReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

untrackedEpoch :: ProviderAdmissionTrackedPhase -> ProviderAdmissionEpoch
untrackedEpoch phase = case phase of
  ProviderTrackedServing generation -> ProviderAdmissionServingInternal generation
  ProviderTrackedFrozen generation binding -> ProviderAdmissionCascadeAuditFrozenInternal generation binding
  ProviderTrackedRecorded generation binding audit -> ProviderAdmissionCascadeAuditRecordedInternal generation binding audit
  ProviderTrackedRevoked generation binding audit receipt -> ProviderAdmissionCascadeCredentialRevokedInternal generation binding audit receipt

trackEpoch :: ProviderCredentialServingLineage -> ProviderAdmissionEpoch -> ProviderAdmissionEpoch
trackEpoch lineage epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> epoch
  ProviderAdmissionServingInternal generation -> ProviderAdmissionTrackedInternal lineage (ProviderTrackedServing generation)
  ProviderAdmissionCascadeAuditFrozenInternal generation binding -> ProviderAdmissionTrackedInternal lineage (ProviderTrackedFrozen generation binding)
  ProviderAdmissionCascadeAuditRecordedInternal generation binding audit -> ProviderAdmissionTrackedInternal lineage (ProviderTrackedRecorded generation binding audit)
  ProviderAdmissionCascadeCredentialRevokedInternal generation binding audit receipt ->
    ProviderAdmissionTrackedInternal lineage (ProviderTrackedRevoked generation binding audit receipt)
  ProviderAdmissionCredentialMutationPendingInternal {} -> epoch
  ProviderAdmissionTrackedInternal {} -> epoch
  ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt _ -> ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt (Just lineage)

validateServingLineage :: ProviderCredentialServingLineage -> Either ProviderAdmissionEpochError ()
validateServingLineage (ProviderCredentialServingLineage operation digest) = do
  void
    ( first
        (ProviderAdmissionBootstrapPredecessorInvalid . Text.pack . show)
        (mkOperatorMaterialOperationId operation)
    )
  void
    (first ProviderAdmissionBootstrapPredecessorInvalid (mkCleanupDigest (cleanupDigestText digest)))

originEpoch :: ProviderCredentialMutationOrigin -> ProviderAdmissionEpoch
originEpoch origin = case origin of
  ProviderInstallInterruptedOrigin _ predecessor _ -> cleanupPredecessorEpoch predecessor
  ProviderInstallLegacyOrigin -> ProviderAdmissionLegacyServingUnboundInternal
  ProviderInstallRecordedOrigin generation binding audit lineage -> withLineage lineage (ProviderAdmissionCascadeAuditRecordedInternal generation binding audit)
  ProviderInstallOrdinaryRetiredOrigin generation receipt lineage -> ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt lineage
  ProviderInstallServingOrigin generation lineage -> withLineage lineage (ProviderAdmissionServingInternal generation)
  ProviderInstallRevokedOrigin generation binding audit receipt lineage ->
    withLineage
      lineage
      (ProviderAdmissionCascadeCredentialRevokedInternal generation binding audit receipt)
  ProviderInstallCompletedRevokedOrigin generation binding audit receipt lineage _ ->
    withLineage
      lineage
      (ProviderAdmissionCascadeCredentialRevokedInternal generation binding audit receipt)
 where
  withLineage Nothing = id
  withLineage (Just lineage) = trackEpoch lineage

data ProviderCredentialMutationReservation
  = ProviderCredentialMutationReservation
      !Text
      !ProviderCredentialGeneration
      !Text
      !ProviderCredentialMutationKind
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderCredentialMutationKind
  = ProviderCredentialInstall
  | ProviderCredentialRotate
  | ProviderCredentialRevoke
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- The origin is closed and nonrecursive. Pending reservation bytes cannot
-- embed another pending state or grow a recursive history in the aggregate.
data ProviderCredentialMutationOrigin
  = ProviderInstallLegacyOrigin
  | ProviderInstallServingOrigin !ProviderCredentialGeneration !(Maybe ProviderCredentialServingLineage)
  | ProviderInstallOrdinaryRetiredOrigin
      !ProviderCredentialGeneration
      !ProviderCredentialRevocationReceipt
      !(Maybe ProviderCredentialServingLineage)
  | ProviderInstallRecordedOrigin
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
      !(Maybe ProviderCredentialServingLineage)
  | ProviderInstallRevokedOrigin
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
      !ProviderCredentialRevocationReceipt
      !(Maybe ProviderCredentialServingLineage)
  | ProviderInstallCompletedRevokedOrigin
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !CascadeTerminalAuditReceipt
      !ProviderCredentialRevocationReceipt
      !(Maybe ProviderCredentialServingLineage)
      !CleanupDigest
  | ProviderInstallInterruptedOrigin
      !ProviderCredentialMutationReservation
      !ProviderCredentialCleanupPredecessor
      !CleanupDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- A closed, nonrecursive snapshot reuses the existing base phase vocabulary.
-- Frozen/recorded phases and a completed-report reference on serving are invalid.
data ProviderCredentialCleanupPredecessor
  = ProviderCleanupLegacyPredecessor
  | ProviderCleanupPhasePredecessor
      !(Maybe ProviderCredentialServingLineage)
      !ProviderAdmissionTrackedPhase
      !(Maybe CleanupDigest)
  | ProviderCleanupRetiredPredecessor
      !ProviderCredentialGeneration
      !ProviderCredentialRevocationReceipt
      !(Maybe ProviderCredentialServingLineage)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderCredentialMutationRefusal
  = ProviderCredentialInstallFrozen
  | ProviderCredentialMutationPendingWork !Int
  | ProviderCredentialInstallDifferentReservation
  | ProviderCredentialInstallMalformed !Text
  | ProviderCredentialInstallGenerationRegressed !Natural !Natural
  | ProviderCredentialInstallPredecessorMismatch
  deriving stock (Eq, Show)

mkProviderCredentialInstallReservation
  :: OperatorMaterialOperationId
  -> CredentialGeneration
  -> TargetValueDigest
  -> Either ProviderCredentialMutationRefusal ProviderCredentialMutationReservation
mkProviderCredentialInstallReservation = mkProviderCredentialMutationReservation InstallOperatorMaterial

mkProviderCredentialMutationReservation
  :: OperatorMaterialAction
  -> OperatorMaterialOperationId
  -> CredentialGeneration
  -> TargetValueDigest
  -> Either ProviderCredentialMutationRefusal ProviderCredentialMutationReservation
mkProviderCredentialMutationReservation action operation generation digest = do
  let operationText = operatorMaterialOperationIdText operation
      generationValue = credentialGenerationValue generation
      digestText = targetValueDigestText digest
  void
    ( first
        (ProviderCredentialInstallMalformed . Text.pack . show)
        (mkOperatorMaterialOperationId operationText)
    )
  bound <-
    first
      (ProviderCredentialInstallMalformed . Text.pack . show)
      (providerCredentialGeneration generationValue)
  void
    (first (ProviderCredentialInstallMalformed . Text.pack . show) (mkTargetValueDigest digestText))
  let kind = case action of
        InstallOperatorMaterial -> ProviderCredentialInstall
        RotateOperatorMaterial -> ProviderCredentialRotate
        RevokeOperatorMaterial -> ProviderCredentialRevoke
  Right (ProviderCredentialMutationReservation operationText bound digestText kind)

validateProviderCredentialMutationReservation
  :: ProviderCredentialMutationReservation -> Either ProviderCredentialMutationRefusal ()
validateProviderCredentialMutationReservation (ProviderCredentialMutationReservation operation generation digest kind) = do
  typedOperation <-
    first
      (ProviderCredentialInstallMalformed . Text.pack . show)
      (mkOperatorMaterialOperationId operation)
  typedGeneration <-
    first
      (ProviderCredentialInstallMalformed . Text.pack . show)
      (mkCredentialGeneration (providerCredentialGenerationValue generation))
  typedDigest <-
    first (ProviderCredentialInstallMalformed . Text.pack . show) (mkTargetValueDigest digest)
  void
    ( mkProviderCredentialMutationReservation
        (mutationAction kind)
        typedOperation
        typedGeneration
        typedDigest
    )

reserveProviderCredentialInstallInternal
  :: ProviderAdmissionEpoch
  -> ProviderPendingWork
  -> ProviderCredentialMutationReservation
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
reserveProviderCredentialInstallInternal epoch pending reservation = do
  validateProviderCredentialMutationReservation reservation
  unless
    (reservationKind reservation /= ProviderCredentialRevoke)
    (Left ProviderCredentialInstallDifferentReservation)
  case epoch of
    ProviderAdmissionCredentialMutationPendingInternal existing _
      | existing == reservation -> Right epoch
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    ProviderAdmissionCascadeAuditFrozenInternal {} -> Left ProviderCredentialInstallFrozen
    ProviderAdmissionCascadeAuditRecordedInternal {} -> Left ProviderCredentialInstallFrozen
    ProviderAdmissionTrackedInternal lineage phase -> case phase of
      ProviderTrackedServing old
        | reservationGeneration <= providerCredentialGenerationValue old ->
            Left
              ( ProviderCredentialInstallGenerationRegressed
                  (providerCredentialGenerationValue old)
                  reservationGeneration
              )
        | otherwise -> reserveOrigin (ProviderInstallServingOrigin old (Just lineage))
      ProviderTrackedRevoked old binding audit receipt -> reserveOrigin (ProviderInstallRevokedOrigin old binding audit receipt (Just lineage))
      ProviderTrackedFrozen {} -> Left ProviderCredentialInstallFrozen
      ProviderTrackedRecorded {} -> Left ProviderCredentialInstallFrozen
    ProviderAdmissionLegacyServingUnboundInternal -> reserveOrigin ProviderInstallLegacyOrigin
    ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt lineage -> reserveOrigin (ProviderInstallOrdinaryRetiredOrigin generation receipt lineage)
    ProviderAdmissionServingInternal old
      | reservationGeneration <= providerCredentialGenerationValue old ->
          Left
            ( ProviderCredentialInstallGenerationRegressed
                (providerCredentialGenerationValue old)
                reservationGeneration
            )
      | otherwise -> reserveOrigin (ProviderInstallServingOrigin old Nothing)
    ProviderAdmissionCascadeCredentialRevokedInternal old binding audit receipt ->
      reserveOrigin (ProviderInstallRevokedOrigin old binding audit receipt Nothing)
 where
  ProviderCredentialMutationReservation _ requestedGeneration _ _ = reservation
  reservationGeneration = providerCredentialGenerationValue requestedGeneration
  reserveOrigin origin = case pending of
    PendingProviderWork count -> Left (ProviderCredentialMutationPendingWork count)
    NoPendingProviderWork -> do
      void
        ( first
            ProviderCredentialInstallMalformed
            (encodeProviderCredentialLineageArchive (ProviderCredentialLineageArchive reservation origin))
        )
      Right (ProviderAdmissionCredentialMutationPendingInternal reservation origin)

-- | Non-authorizing retained-state view. It intentionally omits the hidden
-- freeze binding and revocation receipt.
data ProviderAdmissionEpochView
  = ProviderAdmissionLegacyServingUnbound
  | ProviderAdmissionServing !Natural
  | ProviderAdmissionCascadeAuditFrozen !Natural
  | ProviderAdmissionCascadeCredentialRevoked !Natural
  | ProviderAdmissionCascadeAuditRecorded !Natural
  | ProviderAdmissionCredentialMutationPending !Natural
  | ProviderAdmissionOrdinaryCredentialRetired !Natural
  deriving stock (Eq, Show)

-- Ordinary retained metadata; no constructor attests an effect or admits work.
data ProviderCredentialRecoveryView
  = ProviderCredentialRecoveryIdle
  | ProviderCredentialRecoveryPending !Text
  | ProviderCredentialRecoveryServing !Natural !Text
  | ProviderCredentialRecoveryRetired !Natural !Text
  | ProviderCredentialRecoveryClosed
  | ProviderCredentialRecoveryRevoked
  | ProviderCredentialRecoveryRecorded !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

validateProviderCredentialRecoveryView :: ProviderCredentialRecoveryView -> Either Text ()
validateProviderCredentialRecoveryView view = case view of
  ProviderCredentialRecoveryIdle -> Right ()
  ProviderCredentialRecoveryClosed -> Right ()
  ProviderCredentialRecoveryRevoked -> Right ()
  ProviderCredentialRecoveryRecorded generation -> void (firstShow (providerCredentialGeneration generation))
  ProviderCredentialRecoveryPending operation -> void (firstShow (mkOperatorMaterialOperationId operation))
  ProviderCredentialRecoveryServing generation scope -> do
    void (firstShow (providerCredentialGeneration generation))
    void (mkCleanupDigest scope)
  ProviderCredentialRecoveryRetired generation scope -> do
    void (firstShow (providerCredentialGeneration generation))
    void (mkCleanupDigest scope)

providerCredentialRecoveryViewInternal :: ProviderAdmissionEpoch -> ProviderCredentialRecoveryView
providerCredentialRecoveryViewInternal epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> ProviderCredentialRecoveryIdle
  ProviderAdmissionServingInternal generation -> serving generation
  ProviderAdmissionTrackedInternal _ phase -> case phase of
    ProviderTrackedServing generation -> serving generation
    ProviderTrackedFrozen {} -> ProviderCredentialRecoveryClosed
    ProviderTrackedRecorded generation _ _ -> ProviderCredentialRecoveryRecorded (providerCredentialGenerationValue generation)
    ProviderTrackedRevoked {} -> ProviderCredentialRecoveryRevoked
  ProviderAdmissionOrdinaryCredentialRetiredInternal generation _ _ ->
    ProviderCredentialRecoveryRetired (providerCredentialGenerationValue generation) scope
  ProviderAdmissionCredentialMutationPendingInternal
    (ProviderCredentialMutationReservation operation _ _ _)
    _ ->
      ProviderCredentialRecoveryPending operation
  ProviderAdmissionCascadeAuditFrozenInternal {} -> ProviderCredentialRecoveryClosed
  ProviderAdmissionCascadeAuditRecordedInternal generation _ _ -> ProviderCredentialRecoveryRecorded (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeCredentialRevokedInternal {} -> ProviderCredentialRecoveryRevoked
 where
  scope = cleanupDigestText (cleanupDigestOfBytes (LazyByteString.toStrict (serialise epoch)))
  serving generation = ProviderCredentialRecoveryServing (providerCredentialGenerationValue generation) scope

providerCredentialServingOperationInternal :: ProviderAdmissionEpoch -> Maybe Text
providerCredentialServingOperationInternal epoch = case epoch of
  ProviderAdmissionTrackedInternal
    (ProviderCredentialServingLineage operation _)
    (ProviderTrackedServing _) -> Just operation
  _ -> Nothing

data ProviderAdmissionRecoveryPhase
  = ProviderRecoveryLegacyServingUnbound
  | ProviderRecoveryServing !Natural
  | ProviderRecoveryFrozen !Natural !CleanupAttemptId
  | ProviderRecoveryRecorded !Natural !CleanupAttemptId !CascadeTerminalAuditReceipt
  | ProviderRecoveryRevoked
      !Natural
      !CleanupAttemptId
      !CascadeTerminalAuditReceipt
      !ProviderCredentialRevocationReceipt
  | ProviderRecoveryOrdinaryCredentialRetired !Natural
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderAdmissionRecoveryObservation = ProviderAdmissionRecoveryObservation
  { providerAdmissionRecoveryRequestDigest :: !Text
  , providerAdmissionRecoveryPhase :: !ProviderAdmissionRecoveryPhase
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Metadata-only proof retained across the final local uninstall. Re-decoding
-- this value still requires validation against the complete historical binding.
data ProviderCredentialRetirementConfirmation
  = ProviderCredentialRetirementConfirmation
      !CascadeAuditFreezeBinding
      !CleanupAttemptId
      !ProviderAdmissionRecoveryObservation
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

confirmProviderCredentialRetirement
  :: CascadeAuditFreezeBinding
  -> ProviderAdmissionRecoveryObservation
  -> Either ProviderAdmissionRecoveryRefusal ProviderCredentialRetirementConfirmation
confirmProviderCredentialRetirement requested observation = do
  restored <- restoreCascadeAuditRecoveryBinding requested observation
  let CascadeAuditFreezeBinding _ _ _ _ _ _ successfulAttempt _ = requested
  case providerAdmissionRecoveryPhase observation of
    ProviderRecoveryRevoked _ _ audit _
      | cascadeTerminalAuditReceiptVerdict audit == CascadeTerminalAuditReceiptClean ->
          Right (ProviderCredentialRetirementConfirmation restored successfulAttempt observation)
    _ -> Left ProviderRecoveryPhaseInvalid

-- | Check a decoded confirmation against the sealed run and its successful
-- audit attempt. It cannot license a different run, program, scope or operation.
providerCredentialRetirementMatches
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupDigest
  -> Text
  -> CleanupNodeId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> ProviderCredentialRetirementConfirmation
  -> Bool
providerCredentialRetirementMatches
  run
  descriptor
  graph
  scope
  node
  operation
  attempt
  confirmation@(ProviderCredentialRetirementConfirmation binding successfulAttempt observation) =
    let CascadeAuditFreezeBinding
          actualRun
          actualDescriptor
          actualGraph
          actualScope
          actualNode
          actualOperation
          _originalAttempt
          keys = binding
        requested =
          CascadeAuditFreezeBinding
            actualRun
            actualDescriptor
            actualGraph
            actualScope
            actualNode
            actualOperation
            successfulAttempt
            keys
     in actualRun == run
          && actualDescriptor == descriptor
          && actualGraph == graph
          && actualScope == scope
          && actualNode == node
          && actualOperation == operation
          && successfulAttempt == attempt
          && confirmProviderCredentialRetirement requested observation == Right confirmation

data ProviderAdmissionRecoveryRefusal
  = ProviderRecoveryBindingInvalid !ProviderAdmissionEpochError
  | ProviderRecoveryBindingMismatch
  | ProviderRecoveryResponseMismatch
  | ProviderRecoveryNotFrozen
  | ProviderRecoveryPhaseInvalid
  deriving stock (Eq, Show)

-- | The lease attempt may change on takeover; every other reservation field
-- remains part of this response/request binding.
cascadeAuditRecoveryRequestDigest :: CascadeAuditFreezeBinding -> Text
cascadeAuditRecoveryRequestDigest
  (CascadeAuditFreezeBinding run descriptor graph scope node operation _ keys) =
    cleanupDigestText
      ( cleanupDigestOfBytes
          ( LazyByteString.toStrict
              ( serialise
                  ( [ "provider-admission-recovery/v1"
                    , cleanupRunIdText run
                    , cleanupDigestText descriptor
                    , cleanupDigestText graph
                    , scope
                    , cleanupNodeIdText node
                    , cleanupOperationIdText operation
                    ]
                      ++ map clientSubmissionKeyText keys
                  )
              )
          )
      )

-- | Bounded, non-authorizing locator from the one retained admission
-- object. Submission keys and receipts stay at the Authority.
data ProviderBootstrapPredecessorPhase
  = ProviderBootstrapFrozen
  | ProviderBootstrapRecorded
  | ProviderBootstrapRevoked
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderBootstrapPredecessor = ProviderBootstrapPredecessor
  { providerBootstrapPredecessorRunId :: !CleanupRunId
  , providerBootstrapPredecessorGraphDigest :: !CleanupDigest
  , providerBootstrapPredecessorScopeDigest :: !Text
  , providerBootstrapPredecessorPhase :: !ProviderBootstrapPredecessorPhase
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

validateProviderBootstrapPredecessor
  :: ProviderBootstrapPredecessor -> Either ProviderAdmissionEpochError ()
validateProviderBootstrapPredecessor predecessor = do
  void
    ( first
        ProviderAdmissionBootstrapPredecessorInvalid
        (mkCleanupRunId (cleanupRunIdText (providerBootstrapPredecessorRunId predecessor)))
    )
  void
    ( first
        ProviderAdmissionBootstrapPredecessorInvalid
        (mkCleanupDigest (cleanupDigestText (providerBootstrapPredecessorGraphDigest predecessor)))
    )
  if isLowerHexSha256 (providerBootstrapPredecessorScopeDigest predecessor)
    then Right ()
    else
      Left
        (ProviderAdmissionFreezeScopeDigestInvalid (providerBootstrapPredecessorScopeDigest predecessor))

observeProviderBootstrapPredecessorInternal
  :: ProviderAdmissionEpoch -> Maybe ProviderBootstrapPredecessor
observeProviderBootstrapPredecessorInternal epoch = case epoch of
  ProviderAdmissionTrackedInternal _ phase -> observeProviderBootstrapPredecessorInternal (untrackedEpoch phase)
  ProviderAdmissionCredentialMutationPendingInternal _ origin -> observeProviderBootstrapPredecessorInternal (originEpoch origin)
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Nothing
  ProviderAdmissionCascadeAuditFrozenInternal _ binding -> Just (project ProviderBootstrapFrozen binding)
  ProviderAdmissionCascadeAuditRecordedInternal _ binding _ -> Just (project ProviderBootstrapRecorded binding)
  ProviderAdmissionCascadeCredentialRevokedInternal _ binding _ _ -> Just (project ProviderBootstrapRevoked binding)
 where
  project phase (CascadeAuditFreezeBinding runId _ graph scope _ _ _ _) =
    ProviderBootstrapPredecessor runId graph scope phase

observeProviderAdmissionRecoveryInternal
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> Either ProviderAdmissionRecoveryRefusal ProviderAdmissionRecoveryObservation
observeProviderAdmissionRecoveryInternal epoch requested = do
  first ProviderRecoveryBindingInvalid (validateCascadeAuditFreezeBinding requested)
  phase <- case epoch of
    ProviderAdmissionTrackedInternal _ trackedPhase ->
      providerAdmissionRecoveryPhase
        <$> observeProviderAdmissionRecoveryInternal (untrackedEpoch trackedPhase) requested
    ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderRecoveryPhaseInvalid
    ProviderAdmissionLegacyServingUnboundInternal -> Right ProviderRecoveryLegacyServingUnbound
    ProviderAdmissionOrdinaryCredentialRetiredInternal generation _ _ -> Right (ProviderRecoveryOrdinaryCredentialRetired (providerCredentialGenerationValue generation))
    ProviderAdmissionServingInternal generation ->
      Right (ProviderRecoveryServing (providerCredentialGenerationValue generation))
    ProviderAdmissionCascadeAuditFrozenInternal generation binding -> do
      attempt <- requireBinding binding
      Right (ProviderRecoveryFrozen (providerCredentialGenerationValue generation) attempt)
    ProviderAdmissionCascadeAuditRecordedInternal generation binding receipt -> do
      attempt <- requireBinding binding
      Right (ProviderRecoveryRecorded (providerCredentialGenerationValue generation) attempt receipt)
    ProviderAdmissionCascadeCredentialRevokedInternal generation binding receipt revocation -> do
      attempt <- requireBinding binding
      Right
        (ProviderRecoveryRevoked (providerCredentialGenerationValue generation) attempt receipt revocation)
  let observation = ProviderAdmissionRecoveryObservation expected phase
  validateProviderAdmissionRecoveryObservation requested observation
  Right observation
 where
  expected = cascadeAuditRecoveryRequestDigest requested
  requireBinding binding@(CascadeAuditFreezeBinding _ _ _ _ _ _ attempt _)
    | cascadeAuditRecoveryRequestDigest binding == expected = Right attempt
    | otherwise = Left ProviderRecoveryBindingMismatch

restoreCascadeAuditRecoveryBinding
  :: CascadeAuditFreezeBinding
  -> ProviderAdmissionRecoveryObservation
  -> Either ProviderAdmissionRecoveryRefusal CascadeAuditFreezeBinding
restoreCascadeAuditRecoveryBinding requested observation = do
  validateProviderAdmissionRecoveryObservation requested observation
  attempt <- case providerAdmissionRecoveryPhase observation of
    ProviderRecoveryLegacyServingUnbound -> Left ProviderRecoveryNotFrozen
    ProviderRecoveryServing _ -> Left ProviderRecoveryNotFrozen
    ProviderRecoveryOrdinaryCredentialRetired _ -> Left ProviderRecoveryNotFrozen
    ProviderRecoveryFrozen _ original -> Right original
    ProviderRecoveryRecorded _ original _ -> Right original
    ProviderRecoveryRevoked _ original _ _ -> Right original
  let CascadeAuditFreezeBinding run descriptor graph scope node operation _ keys = requested
  Right (CascadeAuditFreezeBinding run descriptor graph scope node operation attempt keys)

validateProviderAdmissionRecoveryObservation
  :: CascadeAuditFreezeBinding
  -> ProviderAdmissionRecoveryObservation
  -> Either ProviderAdmissionRecoveryRefusal ()
validateProviderAdmissionRecoveryObservation requested observation = do
  first ProviderRecoveryBindingInvalid (validateCascadeAuditFreezeBinding requested)
  if providerAdmissionRecoveryRequestDigest observation == cascadeAuditRecoveryRequestDigest requested
    then Right ()
    else Left ProviderRecoveryResponseMismatch
  case providerAdmissionRecoveryPhase observation of
    ProviderRecoveryLegacyServingUnbound -> Right ()
    ProviderRecoveryServing generation -> validateRecoveryGeneration generation
    ProviderRecoveryOrdinaryCredentialRetired generation -> validateRecoveryGeneration generation
    ProviderRecoveryFrozen generation attempt -> validateFrozen generation attempt
    ProviderRecoveryRecorded generation attempt receipt -> do
      validateFrozen generation attempt
      validateAudit receipt
    ProviderRecoveryRevoked generation attempt receipt revocation -> do
      validateFrozen generation attempt
      validateAudit receipt
      validateRevocation revocation
 where
  valid :: Either err value -> Either ProviderAdmissionRecoveryRefusal value
  valid = first (const ProviderRecoveryPhaseInvalid)
  validateRecoveryGeneration generation = void (valid (providerCredentialGeneration generation))
  validateFrozen generation attempt = do
    validateRecoveryGeneration generation
    _ <- valid (mkCleanupAttemptId (cleanupAttemptIdText attempt))
    Right ()
  validateAudit receipt@(CascadeTerminalAuditReceipt scope query retained verdict) = do
    unless
      (scope == cascadeAuditFreezeBindingScopeDigest requested)
      (Left ProviderRecoveryPhaseInvalid)
    rebuilt <- valid (mkCascadeTerminalAuditReceipt scope query retained verdict)
    unless (rebuilt == receipt) (Left ProviderRecoveryPhaseInvalid)
  validateRevocation receipt@(ProviderCredentialRevocationReceipt iam target) = do
    _ <- valid (mkCleanupDigest (cleanupDigestText iam))
    _ <- valid (mkCleanupDigest (cleanupDigestText target))
    rebuilt <- valid (mkProviderCredentialRevocationReceipt iam target)
    unless (rebuilt == receipt) (Left ProviderRecoveryPhaseInvalid)

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
  | ProviderAdmissionBootstrapPredecessorInvalid !Text
  | ProviderAdmissionCredentialMutationPendingError
  deriving stock (Eq, Show)

data ProviderAdmissionFreshSubmissionRefusal
  = ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  | ProviderAdmissionFreshSubmissionCredentialRevoked
  | ProviderAdmissionFreshSubmissionCredentialMutationPending
  deriving stock (Eq, Show)

maximumExpectedProviderSubmissions :: Int
maximumExpectedProviderSubmissions = 4096

initialLegacyProviderAdmissionEpochInternal :: ProviderAdmissionEpoch
initialLegacyProviderAdmissionEpochInternal =
  ProviderAdmissionLegacyServingUnboundInternal

providerAdmissionNeedsCredentialQuiescenceInternal :: ProviderAdmissionEpoch -> Bool
providerAdmissionNeedsCredentialQuiescenceInternal epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> True
  ProviderAdmissionServingInternal {} -> True
  ProviderAdmissionCascadeAuditFrozenInternal {} -> True
  ProviderAdmissionCascadeAuditRecordedInternal {} -> True
  ProviderAdmissionCascadeCredentialRevokedInternal {} -> True
  ProviderAdmissionTrackedInternal {} -> False
  ProviderAdmissionCredentialMutationPendingInternal {} -> False
  ProviderAdmissionOrdinaryCredentialRetiredInternal _ _ lineage -> case lineage of
    Nothing -> True
    Just _ -> False

providerCredentialRetirementInstallDraftMatchesInternal
  :: ProviderAdmissionEpoch -> ProviderCredentialMutationReservation -> Bool
providerCredentialRetirementInstallDraftMatchesInternal epoch draft@(ProviderCredentialMutationReservation _ generation _ kind) =
  kind == ProviderCredentialInstall
    && providerCredentialGenerationValue generation == 1
    && case epoch of
      ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> True
      ProviderAdmissionCredentialMutationPendingInternal
        reserved
        (ProviderInstallOrdinaryRetiredOrigin {}) -> reserved == draft
      _ -> False

providerAdmissionEpochView
  :: ProviderAdmissionEpoch -> ProviderAdmissionEpochView
providerAdmissionEpochView epoch = case epoch of
  ProviderAdmissionTrackedInternal _ phase -> providerAdmissionEpochView (untrackedEpoch phase)
  ProviderAdmissionCredentialMutationPendingInternal
    (ProviderCredentialMutationReservation _ generation _ _)
    _ ->
      ProviderAdmissionCredentialMutationPending (providerCredentialGenerationValue generation)
  ProviderAdmissionLegacyServingUnboundInternal ->
    ProviderAdmissionLegacyServingUnbound
  ProviderAdmissionOrdinaryCredentialRetiredInternal generation _ _ -> ProviderAdmissionOrdinaryCredentialRetired (providerCredentialGenerationValue generation)
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
  ProviderAdmissionTrackedInternal lineage phase -> validateServingLineage lineage >> validateProviderAdmissionEpochInternal (untrackedEpoch phase)
  ProviderAdmissionCredentialMutationPendingInternal reservation origin -> do
    first
      (ProviderAdmissionBootstrapPredecessorInvalid . Text.pack . show)
      (validateProviderCredentialMutationReservation reservation)
    validateProviderAdmissionEpochInternal (originEpoch origin)
    first ProviderAdmissionBootstrapPredecessorInvalid (validateOriginReportDigest origin)
    first ProviderAdmissionBootstrapPredecessorInvalid (validateCleanupOrigin reservation origin)
  ProviderAdmissionLegacyServingUnboundInternal -> Right ()
  ProviderAdmissionServingInternal generation -> validateGeneration generation
  ProviderAdmissionOrdinaryCredentialRetiredInternal
    generation
    (ProviderCredentialRevocationReceipt iam target)
    lineage -> do
      validateGeneration generation
      void (mkProviderCredentialRevocationReceipt iam target)
      maybe (Right ()) validateServingLineage lineage
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
  ProviderAdmissionTrackedInternal _ phase -> providerAdmissionFreshSubmissionRefusalInternal (untrackedEpoch phase) submissionKey
  ProviderAdmissionCredentialMutationPendingInternal {} -> Just ProviderAdmissionFreshSubmissionCredentialMutationPending
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Just ProviderAdmissionFreshSubmissionCredentialRevoked
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
  | ProviderAdmissionFreezeGenerationBindingRefused !ProviderAdmissionEpochError
  | ProviderAdmissionFreezeCredentialMutationPending
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
    ProviderAdmissionTrackedInternal lineage phase ->
      fmap
        (trackEpoch lineage)
        (bindProviderAdmissionServingGenerationInternal (untrackedEpoch phase) generation)
    ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderAdmissionCredentialMutationPendingError
    ProviderAdmissionOrdinaryCredentialRetiredInternal generationValue _ _ ->
      Left
        (ProviderAdmissionCredentialGenerationInvalid (providerCredentialGenerationValue generationValue))
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
    ProviderAdmissionTrackedInternal lineage phase ->
      fmap
        (trackEpoch lineage)
        (freezeProviderAdmissionForCascadeAuditInternal (untrackedEpoch phase) binding pending)
    ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderAdmissionFreezeCredentialMutationPending
    ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Left ProviderAdmissionFreezeCredentialRevoked
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

-- | Bind the serving generation and freeze in one pure transition. The caller
-- commits only the final result, so a rejected freeze retains no partial bind.
freezeProviderAdmissionAtGenerationInternal
  :: ProviderAdmissionEpoch
  -> Natural
  -> CascadeAuditFreezeBinding
  -> ProviderPendingWork
  -> Either ProviderAdmissionFreezeRefusal ProviderAdmissionEpoch
freezeProviderAdmissionAtGenerationInternal epoch generation binding pending = do
  requested <-
    either
      (Left . ProviderAdmissionFreezeGenerationBindingRefused)
      Right
      (providerCredentialGeneration generation)
  bound <- case epoch of
    ProviderAdmissionTrackedInternal lineage phase ->
      fmap
        (trackEpoch lineage)
        (freezeProviderAdmissionAtGenerationInternal (untrackedEpoch phase) generation binding pending)
    ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderAdmissionFreezeCredentialMutationPending
    ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Left ProviderAdmissionFreezeCredentialRevoked
    ProviderAdmissionLegacyServingUnboundInternal ->
      Right (ProviderAdmissionServingInternal requested)
    ProviderAdmissionServingInternal existing -> requireSame existing requested
    ProviderAdmissionCascadeAuditFrozenInternal existing _ -> requireSame existing requested
    ProviderAdmissionCascadeAuditRecordedInternal existing _ _ -> requireSame existing requested
    ProviderAdmissionCascadeCredentialRevokedInternal existing _ _ _ -> requireSame existing requested
  freezeProviderAdmissionForCascadeAuditInternal bound binding pending
 where
  requireSame existing requested
    | existing == requested = Right epoch
    | otherwise =
        Left
          ( ProviderAdmissionFreezeGenerationBindingRefused
              (ProviderAdmissionCredentialGenerationInvalid (providerCredentialGenerationValue existing))
          )

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
  ProviderAdmissionTrackedInternal lineage phase ->
    fmap
      (trackEpoch lineage)
      (revokeCascadeProviderCredentialInternal (untrackedEpoch phase) binding revocation)
  ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderAdmissionRevokeNotFrozen
  ProviderAdmissionLegacyServingUnboundInternal ->
    Left ProviderAdmissionRevokeNotFrozen
  ProviderAdmissionServingInternal _ -> Left ProviderAdmissionRevokeNotFrozen
  ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Left ProviderAdmissionRevokeNotFrozen
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
  ProviderAdmissionTrackedInternal _ phase -> revokedCascadeTerminalAuditReceiptInternal (untrackedEpoch phase)
  ProviderAdmissionCredentialMutationPendingInternal _ origin -> revokedCascadeTerminalAuditReceiptInternal (originEpoch origin)
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
    ProviderAdmissionTrackedInternal lineage phase ->
      fmap
        (trackEpoch lineage)
        (recordCascadeTerminalAuditReceiptInternal (untrackedEpoch phase) binding receipt)
    ProviderAdmissionCredentialMutationPendingInternal {} -> Left ProviderAdmissionAuditRecordNotFrozen
    ProviderAdmissionLegacyServingUnboundInternal ->
      Left ProviderAdmissionAuditRecordNotFrozen
    ProviderAdmissionServingInternal _ ->
      Left ProviderAdmissionAuditRecordNotFrozen
    ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Left ProviderAdmissionAuditRecordCredentialRevoked
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
  ProviderAdmissionTrackedInternal _ phase -> observedCascadeTerminalAuditReceiptInternal (untrackedEpoch phase)
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
    ProviderAdmissionTrackedInternal _ phase -> confirmCascadeTerminalAuditReceipt (untrackedEpoch phase) binding committed
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

fixedProviderCredentialMutationReservationRegression :: Either Text [(Text, Bool)]
fixedProviderCredentialMutationReservationRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  operation <- firstShow (mkOperatorMaterialOperationId "credential/reservation")
  otherOperation <- firstShow (mkOperatorMaterialOperationId "credential/foreign")
  generation <- firstShow (mkCredentialGeneration 1)
  later <- firstShow (mkCredentialGeneration 8)
  digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
  reservation <- firstShow (mkProviderCredentialInstallReservation operation generation digest)
  future <- firstShow (mkProviderCredentialInstallReservation operation later digest)
  foreignReservation <-
    firstShow (mkProviderCredentialInstallReservation otherOperation generation digest)
  let initial = initialLegacyProviderAdmissionEpochInternal
  pending <-
    firstShow (reserveProviderCredentialInstallInternal initial NoPendingProviderWork reservation)
  serving <- firstShow (bindProviderAdmissionServingGenerationInternal initial 7)
  frozen <-
    firstShow (freezeProviderAdmissionAtGenerationInternal serving 7 binding NoPendingProviderWork)
  audit <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cascadeAuditFreezeBindingScopeDigest binding)
          (Text.replicate 64 "1")
          (Text.replicate 64 "2")
          CascadeTerminalAuditReceiptClean
      )
  recorded <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding audit)
  iam <- mkCleanupDigest (Text.replicate 64 "c")
  target <- mkCleanupDigest (Text.replicate 64 "d")
  revokeReceipt <- firstShow (mkProviderCredentialRevocationReceipt iam target)
  revoked <- firstShow (revokeCascadeProviderCredentialInternal recorded binding revokeReceipt)
  successor <-
    firstShow (reserveProviderCredentialInstallInternal revoked NoPendingProviderWork reservation)
  key <- firstShow (mkClientSubmissionKey "credential/unrelated-provider")
  pure
    [
      ( "pending install fences fresh Provider"
      , providerAdmissionFreshSubmissionRefusalInternal pending key
          == Just ProviderAdmissionFreshSubmissionCredentialMutationPending
      )
    ,
      ( "same reservation replays"
      , reserveProviderCredentialInstallInternal pending NoPendingProviderWork reservation == Right pending
      )
    ,
      ( "foreign reservation refuses"
      , reserveProviderCredentialInstallInternal pending NoPendingProviderWork foreignReservation
          == Left ProviderCredentialInstallDifferentReservation
      )
    ,
      ( "frozen audit refuses install"
      , reserveProviderCredentialInstallInternal frozen NoPendingProviderWork future
          == Left ProviderCredentialInstallFrozen
      )
    ,
      ( "recorded audit refuses install"
      , reserveProviderCredentialInstallInternal recorded NoPendingProviderWork future
          == Left ProviderCredentialInstallFrozen
      )
    ,
      ( "pending Provider work refuses install"
      , reserveProviderCredentialInstallInternal serving (PendingProviderWork 1) future
          == Left (ProviderCredentialMutationPendingWork 1)
      )
    ,
      ( "serving generation cannot regress"
      , reserveProviderCredentialInstallInternal serving NoPendingProviderWork reservation
          == Left (ProviderCredentialInstallGenerationRegressed 7 1)
      )
    ,
      ( "pending cannot be rebound serving"
      , bindProviderAdmissionServingGenerationInternal pending 1
          == Left ProviderAdmissionCredentialMutationPendingError
      )
    ,
      ( "pending cannot freeze"
      , freezeProviderAdmissionAtGenerationInternal pending 1 binding NoPendingProviderWork
          == Left ProviderAdmissionFreezeCredentialMutationPending
      )
    ,
      ( "revoked successor retains predecessor locator"
      , observeProviderBootstrapPredecessorInternal successor
          == observeProviderBootstrapPredecessorInternal revoked
      )
    ,
      ( "revoked successor retains audit proof"
      , revokedCascadeTerminalAuditReceiptInternal successor == Just audit
      )
    ,
      ( "revoked successor may restart Target generation"
      , providerAdmissionEpochView successor == ProviderAdmissionCredentialMutationPending 1
      )
    , ("pending canonical codec", deserialiseOrFail (serialise successor) == Right successor)
    ,
      ( "new constructor appended at five"
      , LazyByteString.take 2 (serialise successor) == LazyByteString.pack [0x83, 5]
      )
    ,
      ( "legacy constructor preserved"
      , LazyByteString.take 2 (serialise initial) == LazyByteString.pack [0x81, 0]
      )
    , ("pending shape validates", validateProviderAdmissionEpochInternal successor == Right ())
    ]

-- Non-authorizing metadata to be published with the independently observed
-- completed Provisioner outbox before the private completion fold is called.
data ProviderCredentialLineageArchive
  = ProviderCredentialLineageArchive
      !ProviderCredentialMutationReservation
      !ProviderCredentialMutationOrigin
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

pendingProviderCredentialLineageArchiveInternal
  :: ProviderAdmissionEpoch -> Maybe ProviderCredentialLineageArchive
pendingProviderCredentialLineageArchiveInternal epoch = case epoch of
  ProviderAdmissionCredentialMutationPendingInternal reservation origin -> Just (ProviderCredentialLineageArchive reservation origin)
  _ -> Nothing

validateProviderCredentialLineageArchive :: ProviderCredentialLineageArchive -> Either Text ()
validateProviderCredentialLineageArchive (ProviderCredentialLineageArchive reservation origin) = do
  firstShow (validateProviderCredentialMutationReservation reservation)
  firstShow (validateProviderAdmissionEpochInternal (originEpoch origin))
  validateOriginReportDigest origin
  validateCleanupOrigin reservation origin

validateOriginReportDigest :: ProviderCredentialMutationOrigin -> Either Text ()
validateOriginReportDigest origin = case origin of
  ProviderInstallCompletedRevokedOrigin _ _ _ _ _ digest ->
    void (mkCleanupDigest (cleanupDigestText digest))
  _ -> Right ()

encodeProviderCredentialLineageArchive
  :: ProviderCredentialLineageArchive -> Either Text ByteString.ByteString
encodeProviderCredentialLineageArchive archive = do
  validateProviderCredentialLineageArchive archive
  let bytes = providerCredentialLineageArchiveCanonicalBytes archive
  if ByteString.length bytes > 65536
    then Left "provider credential lineage archive exceeds 64 KiB"
    else Right bytes

decodeProviderCredentialLineageArchive
  :: ByteString.ByteString -> Either Text ProviderCredentialLineageArchive
decodeProviderCredentialLineageArchive bytes = do
  if ByteString.length bytes > 65536
    then Left "provider credential lineage archive exceeds 64 KiB"
    else Right ()
  (version, archive) <- firstShow (deserialiseOrFail (LazyByteString.fromStrict bytes))
  if version /= (1 :: Word16) && version /= 2 && version /= 3
    then Left "provider credential lineage archive version invalid"
    else Right ()
  canonical <- encodeProviderCredentialLineageArchive archive
  if canonical == bytes
    then Right archive
    else Left "provider credential lineage archive is not canonical"

-- Private fold only. Production must first verify the attested completed
-- operation, independently read its archived bytes and re-observe the Agent.
completeProviderCredentialInstallInternal
  :: ProviderAdmissionEpoch
  -> ProviderCredentialMutationReservation
  -> ProviderCredentialLineageArchive
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
completeProviderCredentialInstallInternal epoch reservation archive@(ProviderCredentialLineageArchive archived origin) = do
  bytes <- first ProviderCredentialInstallMalformed (encodeProviderCredentialLineageArchive archive)
  let ProviderCredentialMutationReservation operation generation _ kind = reservation
      lineage = ProviderCredentialServingLineage operation (cleanupDigestOfBytes bytes)
  if archived /= reservation || kind == ProviderCredentialRevoke
    then Left ProviderCredentialInstallDifferentReservation
    else Right ()
  case epoch of
    ProviderAdmissionCredentialMutationPendingInternal pending old
      | pending == reservation && old == origin ->
          Right (ProviderAdmissionTrackedInternal lineage (ProviderTrackedServing generation))
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    ProviderAdmissionTrackedInternal existing (ProviderTrackedServing current)
      | existing == lineage && current == generation -> Right epoch
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    _ -> Left ProviderCredentialInstallDifferentReservation

fixedProviderCredentialLineageRegression :: Either Text [(Text, Bool)]
fixedProviderCredentialLineageRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  one <- reservationFor "lineage/first" 1
  two <- reservationFor "lineage/rotation" 2
  three <- reservationFor "lineage/after-revoke" 1
  let initial = initialLegacyProviderAdmissionEpochInternal
  pendingOne <- firstShow (reserveProviderCredentialInstallInternal initial NoPendingProviderWork one)
  archiveOne <- archiveFor pendingOne
  bytesOne <- encodeProviderCredentialLineageArchive archiveOne
  servingOne <- firstShow (completeProviderCredentialInstallInternal pendingOne one archiveOne)
  pendingTwo <-
    firstShow (reserveProviderCredentialInstallInternal servingOne NoPendingProviderWork two)
  archiveTwo <- archiveFor pendingTwo
  bytesTwo <- encodeProviderCredentialLineageArchive archiveTwo
  servingTwo <- firstShow (completeProviderCredentialInstallInternal pendingTwo two archiveTwo)
  frozen <-
    firstShow (freezeProviderAdmissionAtGenerationInternal servingTwo 2 binding NoPendingProviderWork)
  audit <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cascadeAuditFreezeBindingScopeDigest binding)
          (Text.replicate 64 "1")
          (Text.replicate 64 "2")
          CascadeTerminalAuditReceiptClean
      )
  recorded <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding audit)
  iam <- mkCleanupDigest (Text.replicate 64 "c")
  target <- mkCleanupDigest (Text.replicate 64 "d")
  receipt <- firstShow (mkProviderCredentialRevocationReceipt iam target)
  revoked <- firstShow (revokeCascadeProviderCredentialInternal recorded binding receipt)
  pendingThree <-
    firstShow (reserveProviderCredentialInstallInternal revoked NoPendingProviderWork three)
  archiveThree <- archiveFor pendingThree
  bytesThree <- encodeProviderCredentialLineageArchive archiveThree
  servingThree <-
    firstShow (completeProviderCredentialInstallInternal pendingThree three archiveThree)
  let lineOne = lineageOf servingOne
      lineTwo = lineageOf servingTwo
      lineThree = lineageOf servingThree
      ProviderCredentialLineageArchive _ originTwo = archiveTwo
      ProviderCredentialLineageArchive _ originThree = archiveThree
      foreignOrigin = ProviderCredentialLineageArchive two ProviderInstallLegacyOrigin
      linkedServing = case originTwo of
        ProviderInstallServingOrigin _ prior -> prior == lineOne
        _ -> False
      linkedRevoked = case originThree of
        ProviderInstallRevokedOrigin _ priorBinding priorAudit priorReceipt prior ->
          prior == lineTwo && priorBinding == binding && priorAudit == audit && priorReceipt == receipt
        _ -> False
  pure
    [
      ( "tracked constructor appends at six"
      , LazyByteString.take 2 (serialise servingOne) == LazyByteString.pack [0x83, 6]
      )
    ,
      ( "first archive decodes canonically"
      , decodeProviderCredentialLineageArchive bytesOne == Right archiveOne
      )
    , ("rotation archive links prior operation", linkedServing)
    , ("freeze preserves operation lineage", lineageOf frozen == lineTwo)
    , ("record preserves operation lineage", lineageOf recorded == lineTwo)
    , ("revoke preserves operation lineage", lineageOf revoked == lineTwo)
    , ("revoked archive retains full evidence and prior link", linkedRevoked)
    ,
      ( "generation reset is serving only after matching completion"
      , providerAdmissionEpochView servingThree == ProviderAdmissionServing 1
      )
    , ("generation reset produces distinct lineage", lineThree /= lineOne && lineThree /= lineTwo)
    ,
      ( "same generation old operation cannot replace new lineage"
      , completeProviderCredentialInstallInternal servingThree one archiveOne
          == Left ProviderCredentialInstallDifferentReservation
      )
    ,
      ( "matching completion replays exactly"
      , completeProviderCredentialInstallInternal servingTwo two archiveTwo == Right servingTwo
      )
    ,
      ( "unreserved completion refuses"
      , completeProviderCredentialInstallInternal initial one archiveOne
          == Left ProviderCredentialInstallDifferentReservation
      )
    ,
      ( "neighboring archived operation refuses"
      , completeProviderCredentialInstallInternal pendingTwo two archiveOne
          == Left ProviderCredentialInstallDifferentReservation
      )
    ,
      ( "caller-selected predecessor refuses"
      , completeProviderCredentialInstallInternal pendingTwo two foreignOrigin
          == Left ProviderCredentialInstallDifferentReservation
      )
    ,
      ( "all archive objects stay bounded"
      , all ((< 4096) . ByteString.length) [bytesOne, bytesTwo, bytesThree]
      )
    ,
      ( "trailing archive bytes refuse"
      , case decodeProviderCredentialLineageArchive (bytesThree <> ByteString.singleton 0) of
          Left _ -> True
          _ -> False
      )
    , ("tracked serving validates", validateProviderAdmissionEpochInternal servingThree == Right ())
    , ("tracked revoked validates", validateProviderAdmissionEpochInternal revoked == Right ())
    ,
      ( "tracked serving cannot bind another generation"
      , case bindProviderAdmissionServingGenerationInternal servingThree 2 of Left _ -> True; _ -> False
      )
    , ("tracked epoch canonical codec", deserialiseOrFail (serialise revoked) == Right revoked)
    ]
 where
  reservationFor operation generation = do
    op <- firstShow (mkOperatorMaterialOperationId operation)
    gen <- firstShow (mkCredentialGeneration generation)
    digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
    firstShow (mkProviderCredentialInstallReservation op gen digest)
  archiveFor =
    maybe (Left "pending epoch has no archive") Right . pendingProviderCredentialLineageArchiveInternal
  lineageOf epoch = case epoch of
    ProviderAdmissionTrackedInternal lineage _ -> Just lineage
    _ -> Nothing

providerCredentialLineageArchiveOperationId :: ProviderCredentialLineageArchive -> Text
providerCredentialLineageArchiveOperationId (ProviderCredentialLineageArchive (ProviderCredentialMutationReservation operation _ _ _) _) = operation
providerCredentialLineageArchiveGeneration :: ProviderCredentialLineageArchive -> Natural
providerCredentialLineageArchiveGeneration (ProviderCredentialLineageArchive (ProviderCredentialMutationReservation _ generation _ _) _) = providerCredentialGenerationValue generation
providerCredentialLineageArchiveRequestDigest :: ProviderCredentialLineageArchive -> Text
providerCredentialLineageArchiveRequestDigest (ProviderCredentialLineageArchive (ProviderCredentialMutationReservation _ _ digest _) _) = digest

providerCredentialLineageArchiveCanonicalBytes
  :: ProviderCredentialLineageArchive -> ByteString.ByteString
providerCredentialLineageArchiveCanonicalBytes archive@(ProviderCredentialLineageArchive _ origin) =
  LazyByteString.toStrict (serialise (version, archive))
 where
  version :: Word16
  version = case origin of
    ProviderInstallInterruptedOrigin {} -> 3
    ProviderInstallCompletedRevokedOrigin {} -> 2
    _ -> 1

-- Private metadata fold; a runtime caller must first fence the revoke and
-- independently confirm its attested completed operation plus Agent absence.
-- Ordinary retirement never substitutes for a cascade's clean audit/revoke.
retireOrdinaryProviderCredentialInternal
  :: ProviderAdmissionEpoch
  -> Natural
  -> ProviderCredentialRevocationReceipt
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
retireOrdinaryProviderCredentialInternal epoch generation receipt@(ProviderCredentialRevocationReceipt iam target) = do
  bound <-
    first
      (ProviderCredentialInstallMalformed . Text.pack . show)
      (providerCredentialGeneration generation)
  void
    ( first
        (ProviderCredentialInstallMalformed . Text.pack . show)
        (mkProviderCredentialRevocationReceipt iam target)
    )
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal -> Right (ProviderAdmissionOrdinaryCredentialRetiredInternal bound receipt Nothing)
    ProviderAdmissionServingInternal existing
      | existing == bound ->
          Right (ProviderAdmissionOrdinaryCredentialRetiredInternal bound receipt Nothing)
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    ProviderAdmissionTrackedInternal lineage (ProviderTrackedServing existing)
      | existing == bound ->
          Right (ProviderAdmissionOrdinaryCredentialRetiredInternal bound receipt (Just lineage))
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    ProviderAdmissionOrdinaryCredentialRetiredInternal existing recorded _
      | existing == bound && recorded == receipt -> Right epoch
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    _ -> Left ProviderCredentialInstallFrozen

fixedOrdinaryProviderCredentialRetirementRegression :: Either Text [(Text, Bool)]
fixedOrdinaryProviderCredentialRetirementRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  receipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "ordinary IAM absence")
          (cleanupDigestOfBytes "ordinary Target absence")
      )
  otherReceipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "other IAM absence")
          (cleanupDigestOfBytes "other Target absence")
      )
  audit <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cascadeAuditFreezeBindingScopeDigest binding)
          (Text.replicate 64 "a")
          (Text.replicate 64 "b")
          CascadeTerminalAuditReceiptClean
      )
  firstReservation <- reservationFor "ordinary/first" 7
  next <- reservationFor "ordinary/next" 1
  pending <-
    firstShow
      ( reserveProviderCredentialInstallInternal
          initialLegacyProviderAdmissionEpochInternal
          NoPendingProviderWork
          firstReservation
      )
  originalArchive <- archiveFor pending
  serving <-
    firstShow (completeProviderCredentialInstallInternal pending firstReservation originalArchive)
  retired <- firstShow (retireOrdinaryProviderCredentialInternal serving 7 receipt)
  nextPending <-
    firstShow (reserveProviderCredentialInstallInternal retired NoPendingProviderWork next)
  nextArchive <- archiveFor nextPending
  nextServing <- firstShow (completeProviderCredentialInstallInternal nextPending next nextArchive)
  frozen <-
    firstShow (freezeProviderAdmissionForCascadeAuditInternal serving binding NoPendingProviderWork)
  recorded <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding audit)
  revoked <- firstShow (revokeCascadeProviderCredentialInternal recorded binding receipt)
  afterCascade <-
    firstShow (reserveProviderCredentialInstallInternal revoked NoPendingProviderWork next)
  cascadeArchive <- archiveFor afterCascade
  cascadeSuccessor <-
    firstShow (completeProviderCredentialInstallInternal afterCascade next cascadeArchive)
  cascadeSuccessorRetired <-
    firstShow (retireOrdinaryProviderCredentialInternal cascadeSuccessor 1 otherReceipt)
  afterOrdinary <-
    firstShow
      ( reserveProviderCredentialInstallInternal
          cascadeSuccessorRetired
          NoPendingProviderWork
          firstReservation
      )
  afterOrdinaryArchive <- archiveFor afterOrdinary
  key <- firstShow (mkClientSubmissionKey "ordinary/fresh-provider-work")
  Right
    [
      ( "ordinary retirement retains the positive generation"
      , providerAdmissionEpochView retired == ProviderAdmissionOrdinaryCredentialRetired 7
      )
    ,
      ( "ordinary retirement fences Provider work"
      , providerAdmissionFreshSubmissionRefusalInternal retired key
          == Just ProviderAdmissionFreshSubmissionCredentialRevoked
      )
    ,
      ( "ordinary retirement exact replay"
      , retireOrdinaryProviderCredentialInternal retired 7 receipt == Right retired
      )
    ,
      ( "ordinary retirement different receipt refuses"
      , case retireOrdinaryProviderCredentialInternal retired 7 otherReceipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement wrong generation refuses"
      , case retireOrdinaryProviderCredentialInternal serving 1 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement cannot lift pending install"
      , case retireOrdinaryProviderCredentialInternal pending 7 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement cannot lift frozen audit"
      , case retireOrdinaryProviderCredentialInternal frozen 7 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement cannot lift recorded audit"
      , case retireOrdinaryProviderCredentialInternal recorded 7 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement cannot replace cascade revocation"
      , case retireOrdinaryProviderCredentialInternal revoked 7 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement permits next generation one"
      , providerAdmissionEpochView nextServing == ProviderAdmissionServing 1
      )
    ,
      ( "ordinary successor archive retains retirement"
      , case nextArchive of
          ProviderCredentialLineageArchive
            _
            (ProviderInstallOrdinaryRetiredOrigin generationValue recordedReceipt _) -> providerCredentialGenerationValue generationValue == 7 && recordedReceipt == receipt
          _ -> False
      )
    ,
      ( "ordinary successor archive retains predecessor link"
      , case nextArchive of
          ProviderCredentialLineageArchive _ (ProviderInstallOrdinaryRetiredOrigin _ _ link) -> link == lineageOf serving
          _ -> False
      )
    , ("ordinary retired state validates", validateProviderAdmissionEpochInternal retired == Right ())
    , ("ordinary retired state codec", deserialiseOrFail (serialise retired) == Right retired)
    ,
      ( "ordinary retired state cannot freeze"
      , freezeProviderAdmissionAtGenerationInternal retired 7 binding NoPendingProviderWork
          == Left ProviderAdmissionFreezeCredentialRevoked
      )
    ,
      ( "ordinary retired state cannot rebind"
      , case bindProviderAdmissionServingGenerationInternal retired 7 of Left _ -> True; _ -> False
      )
    ,
      ( "ordinary retirement adds no cascade locator"
      , observeProviderBootstrapPredecessorInternal retired == Nothing
      )
    ,
      ( "cascade audit remains in successor archive"
      , case cascadeArchive of
          ProviderCredentialLineageArchive _ (ProviderInstallRevokedOrigin _ _ oldAudit _ _) -> oldAudit == audit
          _ -> False
      )
    ,
      ( "later ordinary retirement preserves cascade archive link"
      , case afterOrdinaryArchive of
          ProviderCredentialLineageArchive _ (ProviderInstallOrdinaryRetiredOrigin _ _ link) -> link == lineageOf cascadeSuccessor
          _ -> False
      )
    ]
 where
  reservationFor operation generation = do
    op <- firstShow (mkOperatorMaterialOperationId operation)
    gen <- firstShow (mkCredentialGeneration generation)
    digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
    firstShow (mkProviderCredentialInstallReservation op gen digest)
  archiveFor =
    maybe (Left "pending epoch has no archive") Right . pendingProviderCredentialLineageArchiveInternal
  lineageOf epoch = case epoch of
    ProviderAdmissionTrackedInternal lineage _ -> Just lineage
    _ -> Nothing

mutationAction :: ProviderCredentialMutationKind -> OperatorMaterialAction
mutationAction kind = case kind of
  ProviderCredentialInstall -> InstallOperatorMaterial
  ProviderCredentialRotate -> RotateOperatorMaterial
  ProviderCredentialRevoke -> RevokeOperatorMaterial

reservationKind :: ProviderCredentialMutationReservation -> ProviderCredentialMutationKind
reservationKind (ProviderCredentialMutationReservation _ _ _ kind) = kind

providerCredentialLineageArchiveAction :: ProviderCredentialLineageArchive -> OperatorMaterialAction
providerCredentialLineageArchiveAction (ProviderCredentialLineageArchive reservation _) = mutationAction (reservationKind reservation)

reserveProviderCredentialMutationInternal
  :: ProviderAdmissionEpoch
  -> ProviderPendingWork
  -> ProviderCredentialMutationReservation
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
reserveProviderCredentialMutationInternal epoch pending reservation = do
  validateProviderCredentialMutationReservation reservation
  case reservationKind reservation of
    ProviderCredentialInstall -> reserveProviderCredentialInstallInternal epoch pending reservation
    ProviderCredentialRotate -> reserveProviderCredentialInstallInternal epoch pending reservation
    ProviderCredentialRevoke -> reserveRevoke epoch
 where
  ProviderCredentialMutationReservation _ requested _ _ = reservation
  reserveRevoke current = case current of
    ProviderAdmissionCredentialMutationPendingInternal existing _
      | existing == reservation -> Right current
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    ProviderAdmissionLegacyServingUnboundInternal -> reserveOrigin ProviderInstallLegacyOrigin
    ProviderAdmissionServingInternal generation -> requireGeneration generation >> reserveOrigin (ProviderInstallServingOrigin generation Nothing)
    ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt lineage -> reserveOrigin (ProviderInstallOrdinaryRetiredOrigin generation receipt lineage)
    ProviderAdmissionCascadeAuditRecordedInternal generation binding audit -> reserveRecorded generation binding audit Nothing
    ProviderAdmissionTrackedInternal lineage phase -> case phase of
      ProviderTrackedServing generation ->
        requireGeneration generation
          >> reserveOrigin (ProviderInstallServingOrigin generation (Just lineage))
      ProviderTrackedRecorded generation binding audit -> reserveRecorded generation binding audit (Just lineage)
      _ -> Left ProviderCredentialInstallFrozen
    _ -> Left ProviderCredentialInstallFrozen
  requireGeneration generation = unless (generation == requested) (Left ProviderCredentialInstallDifferentReservation)
  reserveRecorded generation binding audit lineage = do
    requireGeneration generation
    unless
      (cascadeTerminalAuditReceiptVerdict audit == CascadeTerminalAuditReceiptClean)
      (Left ProviderCredentialInstallFrozen)
    reserveOrigin (ProviderInstallRecordedOrigin generation binding audit lineage)
  reserveOrigin origin = case pending of
    PendingProviderWork count -> Left (ProviderCredentialMutationPendingWork count)
    NoPendingProviderWork -> do
      void
        ( first
            ProviderCredentialInstallMalformed
            (encodeProviderCredentialLineageArchive (ProviderCredentialLineageArchive reservation origin))
        )
      Right (ProviderAdmissionCredentialMutationPendingInternal reservation origin)

completeProviderCredentialRevokeInternal
  :: ProviderAdmissionEpoch
  -> ProviderCredentialMutationReservation
  -> ProviderCredentialLineageArchive
  -> ProviderCredentialRevocationReceipt
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
completeProviderCredentialRevokeInternal epoch reservation archive@(ProviderCredentialLineageArchive archived origin) receipt@(ProviderCredentialRevocationReceipt iam target) = do
  bytes <- first ProviderCredentialInstallMalformed (encodeProviderCredentialLineageArchive archive)
  void
    ( first
        (ProviderCredentialInstallMalformed . Text.pack . show)
        (mkProviderCredentialRevocationReceipt iam target)
    )
  let ProviderCredentialMutationReservation operation generation _ kind = reservation
      lineage = ProviderCredentialServingLineage operation (cleanupDigestOfBytes bytes)
      retired = ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt (Just lineage)
  unless
    (archived == reservation && kind == ProviderCredentialRevoke)
    (Left ProviderCredentialInstallDifferentReservation)
  next <- case origin of
    ProviderInstallInterruptedOrigin {} -> Right retired
    _ -> normalNext retired lineage
  case epoch of
    ProviderAdmissionCredentialMutationPendingInternal existing old
      | existing == reservation && old == origin -> Right next
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    _
      | epoch == next -> Right epoch
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
 where
  normalNext retired lineage = case originEpoch origin of
    ProviderAdmissionLegacyServingUnboundInternal -> Right retired
    ProviderAdmissionServingInternal _ -> Right retired
    ProviderAdmissionTrackedInternal _ (ProviderTrackedServing _) -> Right retired
    ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Right retired
    ProviderAdmissionCascadeAuditRecordedInternal _ binding _ ->
      fmap
        (trackEpoch lineage)
        ( first
            (const ProviderCredentialInstallFrozen)
            (revokeCascadeProviderCredentialInternal (originEpoch origin) binding receipt)
        )
    ProviderAdmissionTrackedInternal _ (ProviderTrackedRecorded _ binding _) ->
      fmap
        (trackEpoch lineage)
        ( first
            (const ProviderCredentialInstallFrozen)
            (revokeCascadeProviderCredentialInternal (originEpoch origin) binding receipt)
        )
    _ -> Left ProviderCredentialInstallFrozen

fixedProviderCredentialMutationFenceRegression :: Either Text [(Text, Bool)]
fixedProviderCredentialMutationFenceRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  install <- reservationFor InstallOperatorMaterial "mutation/install" 3
  revoke <- reservationFor RevokeOperatorMaterial "mutation/revoke" 3
  next <- reservationFor InstallOperatorMaterial "mutation/next" 1
  pending <-
    firstShow
      ( reserveProviderCredentialMutationInternal
          initialLegacyProviderAdmissionEpochInternal
          NoPendingProviderWork
          install
      )
  installArchive <- archiveFor pending
  serving <- firstShow (completeProviderCredentialInstallInternal pending install installArchive)
  revokePending <-
    firstShow (reserveProviderCredentialMutationInternal serving NoPendingProviderWork revoke)
  revokeArchive <- archiveFor revokePending
  receipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "fenced IAM absence")
          (cleanupDigestOfBytes "fenced Agent absence")
      )
  retired <-
    firstShow (completeProviderCredentialRevokeInternal revokePending revoke revokeArchive receipt)
  nextPending <-
    firstShow (reserveProviderCredentialMutationInternal retired NoPendingProviderWork next)
  nextArchive <- archiveFor nextPending
  nextServing <- firstShow (completeProviderCredentialInstallInternal nextPending next nextArchive)
  frozen <-
    firstShow (freezeProviderAdmissionForCascadeAuditInternal serving binding NoPendingProviderWork)
  clean <- auditFor CascadeTerminalAuditReceiptClean
  escaped <- auditFor (CascadeTerminalAuditReceiptEscaped 1)
  unknown <- auditFor (CascadeTerminalAuditReceiptUnobservable 1)
  recorded <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding clean)
  recordedEscape <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding escaped)
  recordedUnknown <- firstShow (recordCascadeTerminalAuditReceiptInternal frozen binding unknown)
  cascadePending <-
    firstShow (reserveProviderCredentialMutationInternal recorded NoPendingProviderWork revoke)
  cascadeArchive <- archiveFor cascadePending
  revoked <-
    firstShow (completeProviderCredentialRevokeInternal cascadePending revoke cascadeArchive receipt)
  key <- firstShow (mkClientSubmissionKey "mutation/provider-work")
  Right
    [
      ( "revoke reservation fences all Provider work"
      , providerAdmissionFreshSubmissionRefusalInternal revokePending key
          == Just ProviderAdmissionFreshSubmissionCredentialMutationPending
      )
    ,
      ( "revoke reservation fences freeze"
      , freezeProviderAdmissionForCascadeAuditInternal revokePending binding NoPendingProviderWork
          == Left ProviderAdmissionFreezeCredentialMutationPending
      )
    ,
      ( "revoke reservation exact replay"
      , reserveProviderCredentialMutationInternal revokePending NoPendingProviderWork revoke
          == Right revokePending
      )
    ,
      ( "install cannot supersede reserved revoke"
      , case reserveProviderCredentialMutationInternal revokePending NoPendingProviderWork next of
          Left _ -> True
          _ -> False
      )
    ,
      ( "pending Provider work blocks revoke"
      , reserveProviderCredentialMutationInternal serving (PendingProviderWork 1) revoke
          == Left (ProviderCredentialMutationPendingWork 1)
      )
    ,
      ( "revoke reservation cannot complete as install"
      , case completeProviderCredentialInstallInternal revokePending revoke revokeArchive of
          Left _ -> True
          _ -> False
      )
    ,
      ( "install reservation cannot complete as revoke"
      , case completeProviderCredentialRevokeInternal pending install installArchive receipt of
          Left _ -> True
          _ -> False
      )
    ,
      ( "revoke completion exact replay"
      , completeProviderCredentialRevokeInternal retired revoke revokeArchive receipt == Right retired
      )
    ,
      ( "ordinary fenced revoke permits next generation one"
      , providerAdmissionEpochView nextServing == ProviderAdmissionServing 1
      )
    ,
      ( "ordinary revoke archives original serving lineage"
      , case revokeArchive of
          ProviderCredentialLineageArchive _ (ProviderInstallServingOrigin _ (Just _)) -> True
          _ -> False
      )
    ,
      ( "revoke before audit record refuses"
      , reserveProviderCredentialMutationInternal frozen NoPendingProviderWork revoke
          == Left ProviderCredentialInstallFrozen
      )
    ,
      ( "revoke after escaped audit refuses"
      , reserveProviderCredentialMutationInternal recordedEscape NoPendingProviderWork revoke
          == Left ProviderCredentialInstallFrozen
      )
    ,
      ( "revoke after unobservable audit refuses"
      , reserveProviderCredentialMutationInternal recordedUnknown NoPendingProviderWork revoke
          == Left ProviderCredentialInstallFrozen
      )
    ,
      ( "clean audit licenses only fenced revoke"
      , providerAdmissionEpochView revoked == ProviderAdmissionCascadeCredentialRevoked 3
      )
    ,
      ( "cascade revoke keeps original audit"
      , revokedCascadeTerminalAuditReceiptInternal revoked == Just clean
      )
    ,
      ( "existing cascade confirmation remains exact replay"
      , revokeCascadeProviderCredentialInternal revoked binding receipt == Right revoked
      )
    ,
      ( "cascade revoke archive keeps recorded audit"
      , case cascadeArchive of
          ProviderCredentialLineageArchive _ (ProviderInstallRecordedOrigin _ oldBinding audit _) -> oldBinding == binding && audit == clean
          _ -> False
      )
    ,
      ( "cascade revoke cannot be replaced by generic retire"
      , case retireOrdinaryProviderCredentialInternal revoked 3 receipt of Left _ -> True; _ -> False
      )
    ,
      ( "completed cascade remains fenced"
      , providerAdmissionFreshSubmissionRefusalInternal revoked key
          == Just ProviderAdmissionFreshSubmissionCredentialRevoked
      )
    ]
 where
  reservationFor action operation generation = do
    op <- firstShow (mkOperatorMaterialOperationId operation)
    gen <- firstShow (mkCredentialGeneration generation)
    digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
    firstShow (mkProviderCredentialMutationReservation action op gen digest)
  archiveFor =
    maybe (Left "pending epoch has no archive") Right . pendingProviderCredentialLineageArchiveInternal
  auditFor verdict = do
    binding <- fixedCascadeAuditFreezeBinding
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cascadeAuditFreezeBindingScopeDigest binding)
          (Text.replicate 64 "a")
          (Text.replicate 64 "b")
          verdict
      )

-- | A distinct successor requires server-observed completion of the exact
-- revoked cascade. Keep the report reference with its original audit and
-- revocation evidence before permitting any credential effect.
reserveProviderCredentialMutationAfterPredecessorInternal
  :: ProviderAdmissionEpoch
  -> ProviderPendingWork
  -> ProviderCredentialMutationReservation
  -> ObservedCompletedProviderPredecessor
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
reserveProviderCredentialMutationAfterPredecessorInternal epoch pending reservation proof =
  case epoch of
    ProviderAdmissionCascadeCredentialRevokedInternal generation binding audit receipt ->
      reserveFrom generation binding audit receipt Nothing
    ProviderAdmissionTrackedInternal lineage (ProviderTrackedRevoked generation binding audit receipt) ->
      reserveFrom generation binding audit receipt (Just lineage)
    ProviderAdmissionCredentialMutationPendingInternal existing origin ->
      case origin of
        ProviderInstallCompletedRevokedOrigin _ binding _ _ _ digest
          | existing == reservation
              && matches binding
              && digest == completedProviderPredecessorReportDigest proof ->
              Right epoch
        _ -> Left ProviderCredentialInstallPredecessorMismatch
    _ -> Left ProviderCredentialInstallPredecessorMismatch
 where
  matches binding = coordinatesFor binding == Right (completedProviderPredecessorCoordinates proof)
  reserveFrom generation binding audit receipt lineage = do
    unless (matches binding) (Left ProviderCredentialInstallPredecessorMismatch)
    _ <- reserveProviderCredentialInstallInternal epoch pending reservation
    let origin =
          ProviderInstallCompletedRevokedOrigin
            generation
            binding
            audit
            receipt
            lineage
            (completedProviderPredecessorReportDigest proof)
    void
      ( first
          ProviderCredentialInstallMalformed
          (encodeProviderCredentialLineageArchive (ProviderCredentialLineageArchive reservation origin))
      )
    Right (ProviderAdmissionCredentialMutationPendingInternal reservation origin)

providerPredecessorCoordinatesInternal
  :: ProviderAdmissionEpoch -> Maybe ProviderPredecessorCoordinates
providerPredecessorCoordinatesInternal epoch = case epoch of
  ProviderAdmissionTrackedInternal _ phase -> providerPredecessorCoordinatesInternal (untrackedEpoch phase)
  ProviderAdmissionCredentialMutationPendingInternal _ origin -> providerPredecessorCoordinatesInternal (originEpoch origin)
  ProviderAdmissionCascadeAuditFrozenInternal _ binding -> either (const Nothing) Just (coordinatesFor binding)
  ProviderAdmissionCascadeAuditRecordedInternal _ binding _ -> either (const Nothing) Just (coordinatesFor binding)
  ProviderAdmissionCascadeCredentialRevokedInternal _ binding _ _ -> either (const Nothing) Just (coordinatesFor binding)
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionOrdinaryCredentialRetiredInternal {} -> Nothing

coordinatesFor :: CascadeAuditFreezeBinding -> Either Text ProviderPredecessorCoordinates
coordinatesFor (CascadeAuditFreezeBinding run descriptor graph scope _ _ _ _) =
  ProviderPredecessorCoordinates run descriptor graph <$> mkCleanupDigest scope

providerCredentialLineageArchiveReservationInternal
  :: ProviderCredentialLineageArchive -> ProviderCredentialMutationReservation
providerCredentialLineageArchiveReservationInternal (ProviderCredentialLineageArchive reservation _) = reservation

providerCredentialLineageArchiveCompletedReportDigest
  :: ProviderCredentialLineageArchive -> Maybe CleanupDigest
providerCredentialLineageArchiveCompletedReportDigest (ProviderCredentialLineageArchive _ origin) =
  case origin of
    ProviderInstallCompletedRevokedOrigin _ _ _ _ _ digest -> Just digest
    ProviderInstallInterruptedOrigin _ (ProviderCleanupPhasePredecessor _ _ report) _ -> report
    _ -> Nothing

cleanupPredecessorEpoch :: ProviderCredentialCleanupPredecessor -> ProviderAdmissionEpoch
cleanupPredecessorEpoch predecessor = case predecessor of
  ProviderCleanupLegacyPredecessor -> ProviderAdmissionLegacyServingUnboundInternal
  ProviderCleanupPhasePredecessor lineage phase _ -> maybe id trackEpoch lineage (untrackedEpoch phase)
  ProviderCleanupRetiredPredecessor generation receipt lineage -> ProviderAdmissionOrdinaryCredentialRetiredInternal generation receipt lineage

cleanupPredecessorFor
  :: ProviderCredentialMutationOrigin -> Either Text ProviderCredentialCleanupPredecessor
cleanupPredecessorFor origin = case origin of
  ProviderInstallLegacyOrigin -> Right ProviderCleanupLegacyPredecessor
  ProviderInstallServingOrigin generation lineage -> Right (ProviderCleanupPhasePredecessor lineage (ProviderTrackedServing generation) Nothing)
  ProviderInstallOrdinaryRetiredOrigin generation receipt lineage -> Right (ProviderCleanupRetiredPredecessor generation receipt lineage)
  ProviderInstallRevokedOrigin generation binding audit receipt lineage ->
    Right
      ( ProviderCleanupPhasePredecessor
          lineage
          (ProviderTrackedRevoked generation binding audit receipt)
          Nothing
      )
  ProviderInstallCompletedRevokedOrigin generation binding audit receipt lineage report ->
    Right
      ( ProviderCleanupPhasePredecessor
          lineage
          (ProviderTrackedRevoked generation binding audit receipt)
          (Just report)
      )
  ProviderInstallRecordedOrigin {} -> Left "cleanup parent cannot own a recorded audit"
  ProviderInstallInterruptedOrigin {} -> Left "cleanup cannot create another cleanup child"

providerCredentialCleanupOperationId
  :: ProviderCredentialMutationReservation -> Either Text OperatorMaterialOperationId
providerCredentialCleanupOperationId parent = do
  firstShow (validateProviderCredentialMutationReservation parent)
  unless
    (reservationKind parent /= ProviderCredentialRevoke)
    (Left "cleanup parent must install or rotate")
  let digest =
        cleanupDigestOfBytes
          (LazyByteString.toStrict (serialise ("provider-credential-cleanup/v1" :: Text, parent)))
  firstShow (mkOperatorMaterialOperationId ("credential-cleanup/" <> cleanupDigestText digest))

-- | Metadata preparation only. The owned runtime still proves the expired
-- parent's identity, workload absence and current Agent generation.
providerCredentialCleanupDraftMatches
  :: ProviderCredentialLineageArchive
  -> ProviderCredentialMutationReservation
  -> Bool
providerCredentialCleanupDraftMatches (ProviderCredentialLineageArchive parent origin) draft =
  case origin of
    ProviderInstallInterruptedOrigin {} -> draft == parent
    _ -> case providerCredentialCleanupOperationId parent of
      Left _ -> False
      Right operation ->
        reservationKind draft == ProviderCredentialRevoke
          && reservationOperation draft == operatorMaterialOperationIdText operation
          && reservationGeneration draft <= reservationGeneration parent
 where
  reservationOperation (ProviderCredentialMutationReservation operation _ _ _) = operation
  reservationGeneration (ProviderCredentialMutationReservation _ generation _ _) =
    providerCredentialGenerationValue generation

validateCleanupOrigin
  :: ProviderCredentialMutationReservation -> ProviderCredentialMutationOrigin -> Either Text ()
validateCleanupOrigin child origin = case origin of
  ProviderInstallInterruptedOrigin parent predecessor permitDigest -> do
    expected <- providerCredentialCleanupOperationId parent
    let ProviderCredentialMutationReservation childOperation childGeneration _ childKind = child
        ProviderCredentialMutationReservation _ parentGeneration _ _ = parent
    unless
      ( childOperation == operatorMaterialOperationIdText expected
          && childKind == ProviderCredentialRevoke
          && providerCredentialGenerationValue childGeneration
            <= providerCredentialGenerationValue parentGeneration
      )
      (Left "cleanup child does not bind the parent operation and generation ceiling")
    void (mkCleanupDigest (cleanupDigestText permitDigest))
    case predecessor of
      ProviderCleanupLegacyPredecessor -> Right ()
      ProviderCleanupRetiredPredecessor {} -> Right ()
      ProviderCleanupPhasePredecessor _ phase report -> case phase of
        ProviderTrackedServing _ -> unless (report == Nothing) (Left "serving predecessor cannot carry a cascade report")
        ProviderTrackedRevoked {} -> maybe (Right ()) (void . mkCleanupDigest . cleanupDigestText) report
        ProviderTrackedFrozen {} -> Left "cleanup predecessor cannot be frozen"
        ProviderTrackedRecorded {} -> Left "cleanup predecessor cannot be merely recorded"
  _ -> Right ()

reserveProviderCredentialCleanupInternal
  :: ProviderAdmissionEpoch
  -> ProviderCredentialLineageArchive
  -> ProviderCredentialMutationReservation
  -> CleanupDigest
  -> Either ProviderCredentialMutationRefusal ProviderAdmissionEpoch
reserveProviderCredentialCleanupInternal epoch parentArchive@(ProviderCredentialLineageArchive parent origin) child permitDigest = do
  void
    (first ProviderCredentialInstallMalformed (encodeProviderCredentialLineageArchive parentArchive))
  predecessor <- first ProviderCredentialInstallMalformed (cleanupPredecessorFor origin)
  let cleanupOrigin = ProviderInstallInterruptedOrigin parent predecessor permitDigest
      expected = ProviderAdmissionCredentialMutationPendingInternal child cleanupOrigin
  void
    ( first
        ProviderCredentialInstallMalformed
        (encodeProviderCredentialLineageArchive (ProviderCredentialLineageArchive child cleanupOrigin))
    )
  case epoch of
    ProviderAdmissionCredentialMutationPendingInternal current stored
      | current == parent && stored == origin -> Right expected
      | epoch == expected -> Right epoch
      | otherwise -> Left ProviderCredentialInstallDifferentReservation
    _ -> Left ProviderCredentialInstallDifferentReservation

fixedProviderCredentialCleanupRegression :: Either Text [(Text, Bool)]
fixedProviderCredentialCleanupRegression = do
  parent <- reservation InstallOperatorMaterial "cleanup/parent" 3
  let initial = initialLegacyProviderAdmissionEpochInternal
  pending <-
    firstShow (reserveProviderCredentialMutationInternal initial NoPendingProviderWork parent)
  parentArchive <- archiveFor pending
  parentServing <- firstShow (completeProviderCredentialInstallInternal pending parent parentArchive)
  childOperation <- providerCredentialCleanupOperationId parent
  child <- reservation RevokeOperatorMaterial (operatorMaterialOperationIdText childOperation) 2
  let permitDigest = cleanupDigestOfBytes "fixture exact expired parent permit"
  cleanup <-
    firstShow (reserveProviderCredentialCleanupInternal pending parentArchive child permitDigest)
  childArchive <- archiveFor cleanup
  bytes <- encodeProviderCredentialLineageArchive childArchive
  receipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "fixture IAM absence")
          (cleanupDigestOfBytes "fixture Target absence")
      )
  retired <- firstShow (completeProviderCredentialRevokeInternal cleanup child childArchive receipt)
  next <- reservation InstallOperatorMaterial "cleanup/next" 1
  fresh <- firstShow (reserveProviderCredentialMutationInternal retired NoPendingProviderWork next)
  wrongGenerationInstall <- reservation InstallOperatorMaterial "cleanup/next" 2
  childAbove <- reservation RevokeOperatorMaterial (operatorMaterialOperationIdText childOperation) 4
  childInstall <-
    reservation InstallOperatorMaterial (operatorMaterialOperationIdText childOperation) 2
  foreignChild <- reservation RevokeOperatorMaterial "cleanup/foreign-child" 2
  secondChild <- reservation RevokeOperatorMaterial "cleanup/recursive-child" 1
  let repairChecks =
        [
          ( "retirement permits generation-one metadata preparation"
          , providerCredentialRetirementInstallDraftMatchesInternal retired next
          )
        ,
          ( "retirement install preparation replays its exact reservation"
          , providerCredentialRetirementInstallDraftMatchesInternal fresh next
          )
        ,
          ( "retirement install preparation refuses another reservation"
          , not (providerCredentialRetirementInstallDraftMatchesInternal fresh foreignChild)
          )
        ,
          ( "retirement install preparation refuses another generation"
          , not (providerCredentialRetirementInstallDraftMatchesInternal retired wrongGenerationInstall)
          )
        ,
          ( "legacy metadata cannot assert retirement"
          , not (providerCredentialRetirementInstallDraftMatchesInternal initial next)
          )
        ,
          ( "serving metadata cannot assert retirement"
          , not (providerCredentialRetirementInstallDraftMatchesInternal parentServing next)
          )
        ]
      checks =
        repairChecks
          ++ [
               ( "recovery metadata observes legacy idle"
               , providerCredentialRecoveryViewInternal initial == ProviderCredentialRecoveryIdle
               )
             ,
               ( "recovery metadata observes the exact pending parent"
               , providerCredentialRecoveryViewInternal pending == ProviderCredentialRecoveryPending "cleanup/parent"
               )
             ,
               ( "recovery metadata observes serving generation without Target material"
               , case providerCredentialRecoveryViewInternal parentServing of
                   ProviderCredentialRecoveryServing 3 scope -> validateProviderCredentialRecoveryView (ProviderCredentialRecoveryServing 3 scope) == Right ()
                   _ -> False
               )
             ,
               ( "recovery metadata scopes retirement deterministically"
               , case providerCredentialRecoveryViewInternal retired of
                   view@(ProviderCredentialRecoveryRetired _ _) ->
                     validateProviderCredentialRecoveryView view == Right ()
                       && deserialiseOrFail (serialise view) == Right view
                   _ -> False
               )
             ,
               ( "recovery metadata rejects zero serving generation"
               , isLeft
                   (validateProviderCredentialRecoveryView (ProviderCredentialRecoveryServing 0 (Text.replicate 64 "a")))
               )
             ,
               ( "recovery metadata rejects malformed scope"
               , isLeft (validateProviderCredentialRecoveryView (ProviderCredentialRecoveryRetired 2 "bad scope"))
               )
             ,
               ( "recovery metadata rejects malformed operation"
               , isLeft (validateProviderCredentialRecoveryView (ProviderCredentialRecoveryPending "bad operation"))
               )
             ,
               ( "metadata preparation accepts the deterministic cleanup draft"
               , providerCredentialCleanupDraftMatches parentArchive child
               )
             ,
               ( "metadata preparation replays the exact child"
               , providerCredentialCleanupDraftMatches childArchive child
               )
             ,
               ( "metadata preparation rejects a recursive child"
               , not (providerCredentialCleanupDraftMatches childArchive secondChild)
               )
             ,
               ( "metadata preparation rejects a higher generation"
               , not (providerCredentialCleanupDraftMatches parentArchive childAbove)
               )
             ,
               ( "metadata preparation rejects an install"
               , not (providerCredentialCleanupDraftMatches parentArchive childInstall)
               )
             ,
               ( "cleanup child is the one deterministic operation"
               , providerCredentialLineageArchiveOperationId childArchive
                   == operatorMaterialOperationIdText childOperation
               )
             , ("cleanup archive uses version three", ByteString.take 2 bytes == ByteString.pack [0x82, 3])
             ,
               ( "cleanup archive is bounded and canonical"
               , ByteString.length bytes <= 65536
                   && decodeProviderCredentialLineageArchive bytes == Right childArchive
               )
             , ("pending cleanup aggregate round-trips", deserialiseOrFail (serialise cleanup) == Right cleanup)
             ,
               ( "cleanup reservation exact replay"
               , reserveProviderCredentialCleanupInternal cleanup parentArchive child permitDigest == Right cleanup
               )
             ,
               ( "cleanup replay cannot substitute the parent permit"
               , isLeft
                   ( reserveProviderCredentialCleanupInternal
                       cleanup
                       parentArchive
                       child
                       (cleanupDigestOfBytes "foreign parent permit")
                   )
               )
             ,
               ( "cleanup child cannot exceed parent generation"
               , isLeft (reserveProviderCredentialCleanupInternal pending parentArchive childAbove permitDigest)
               )
             ,
               ( "cleanup child cannot install"
               , isLeft (reserveProviderCredentialCleanupInternal pending parentArchive childInstall permitDigest)
               )
             ,
               ( "cleanup child cannot substitute its operation"
               , isLeft (reserveProviderCredentialCleanupInternal pending parentArchive foreignChild permitDigest)
               )
             ,
               ( "cleanup child cannot create another child"
               , isLeft (reserveProviderCredentialCleanupInternal cleanup childArchive secondChild permitDigest)
               )
             ,
               ( "parent completion cannot replace its cleanup child"
               , isLeft (completeProviderCredentialInstallInternal cleanup parent parentArchive)
               )
             ,
               ( "cleanup completion retires the exact observed generation"
               , providerAdmissionEpochView retired == ProviderAdmissionOrdinaryCredentialRetired 2
               )
             ,
               ( "cleanup completion exact replay"
               , completeProviderCredentialRevokeInternal retired child childArchive receipt == Right retired
               )
             ,
               ( "fresh install follows cleanup at generation one"
               , providerAdmissionEpochView fresh == ProviderAdmissionCredentialMutationPending 1
               )
             , ("pending cleanup validates", validateProviderAdmissionEpochInternal cleanup == Right ())
             ]
  parentRevoke <- reservation RevokeOperatorMaterial "cleanup/parent-revoke" 3
  revokePending <-
    firstShow (reserveProviderCredentialMutationInternal initial NoPendingProviderWork parentRevoke)
  revokeArchive <- archiveFor revokePending
  priorCases <- cleanupPredecessorSnapshotRegression
  Right
    ( checks
        ++ [
             ( "a revoke cannot become a cleanup parent"
             , isLeft (reserveProviderCredentialCleanupInternal revokePending revokeArchive child permitDigest)
             )
           ]
        ++ priorCases
    )
 where
  isLeft = either (const True) (const False)
  reservation action name generation = do
    operation <- firstShow (mkOperatorMaterialOperationId name)
    value <- firstShow (mkCredentialGeneration generation)
    digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
    firstShow (mkProviderCredentialMutationReservation action operation value digest)
  archiveFor =
    maybe (Left "cleanup fixture archive missing") Right
      . pendingProviderCredentialLineageArchiveInternal

cleanupPredecessorSnapshotRegression :: Either Text [(Text, Bool)]
cleanupPredecessorSnapshotRegression = do
  generation <- firstShow (providerCredentialGeneration 7)
  receipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "prior IAM")
          (cleanupDigestOfBytes "prior Target")
      )
  binding <- fixedCascadeAuditFreezeBinding
  audit <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cascadeAuditFreezeBindingScopeDigest binding)
          (Text.replicate 64 "a")
          (Text.replicate 64 "b")
          CascadeTerminalAuditReceiptClean
      )
  let lineage =
        Just
          (ProviderCredentialServingLineage "cleanup/prior-lineage" (cleanupDigestOfBytes "prior archive"))
      report = cleanupDigestOfBytes "prior completed report"
      origins =
        [ ("legacy", ProviderInstallLegacyOrigin)
        , ("serving", ProviderInstallServingOrigin generation Nothing)
        , ("tracked serving", ProviderInstallServingOrigin generation lineage)
        , ("ordinary retired", ProviderInstallOrdinaryRetiredOrigin generation receipt lineage)
        , ("revoked", ProviderInstallRevokedOrigin generation binding audit receipt lineage)
        ,
          ( "completed revoked"
          , ProviderInstallCompletedRevokedOrigin generation binding audit receipt lineage report
          )
        ]
  concat <$> traverse (one receipt) origins
 where
  one receipt (label, origin) = do
    operation <-
      firstShow (mkOperatorMaterialOperationId ("cleanup/snapshot/" <> Text.replace " " "-" label))
    generation <- firstShow (mkCredentialGeneration 8)
    digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "a"))
    parent <-
      firstShow
        (mkProviderCredentialMutationReservation InstallOperatorMaterial operation generation digest)
    childOperation <- providerCredentialCleanupOperationId parent
    child <-
      firstShow
        (mkProviderCredentialMutationReservation RevokeOperatorMaterial childOperation generation digest)
    let parentArchive = ProviderCredentialLineageArchive parent origin
        pending = ProviderAdmissionCredentialMutationPendingInternal parent origin
        permitDigest = cleanupDigestOfBytes "snapshot parent permit"
    cleanup <-
      firstShow (reserveProviderCredentialCleanupInternal pending parentArchive child permitDigest)
    archive <-
      maybe
        (Left "snapshot child archive missing")
        Right
        (pendingProviderCredentialLineageArchiveInternal cleanup)
    bytes <- encodeProviderCredentialLineageArchive archive
    retired <- firstShow (completeProviderCredentialRevokeInternal cleanup child archive receipt)
    let preserved = case archive of
          ProviderCredentialLineageArchive _ (ProviderInstallInterruptedOrigin old predecessor storedPermit) ->
            old == parent
              && cleanupPredecessorEpoch predecessor == originEpoch origin
              && storedPermit == permitDigest
          _ -> False
    Right
      [ (label <> " predecessor is preserved", preserved)
      ,
        ( label <> " predecessor archive round-trips"
        , decodeProviderCredentialLineageArchive bytes == Right archive
        )
      ,
        ( label <> " prior completed report is preserved"
        , providerCredentialLineageArchiveCompletedReportDigest archive
            == providerCredentialLineageArchiveCompletedReportDigest parentArchive
        )
      ,
        ( label <> " cleanup produces exact retired phase"
        , providerAdmissionEpochView retired == ProviderAdmissionOrdinaryCredentialRetired 8
        )
      ]
