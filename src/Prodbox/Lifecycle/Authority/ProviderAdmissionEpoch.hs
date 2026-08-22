-- | Read-only facade for the retained Provider admission epoch.  Generation
-- adoption and pending-operation classification remain package-private.
--
-- Sprint 7.36 exports the terminal-audit receipt and the credential-revocation
-- receipt together with their smart constructors, for the same reason Sprint
-- 4.85 exported the freeze binding: an authenticated control route now carries
-- each of them.  What stays package-private is every way to /apply/ one — the
-- record, revoke, freeze, and generation-binding transitions, and the epoch
-- constructors themselves.  A caller can state the audit it took and the two
-- read-backs it performed, and can transition nothing.
--
-- Sprint 4.85 exports the Cascade-audit freeze __binding__ and its smart
-- constructor, because the authenticated control route that carries one now
-- exists.  What stays package-private is every way to /apply/ it: the epoch
-- constructors, the freeze and generation-binding transitions, and the
-- revocation receipt.  A caller can therefore state the reservation it owns —
-- its own run, node, operation, attempt, and the submission keys it will use —
-- and cannot transition the epoch itself.
--
-- Sprint 4.85 added the generation-binding and Cascade-audit freeze
-- transitions, but only as package-private aggregate commands consumed by
-- @Prodbox.Lifecycle.Authority.Admission@.  Nothing here mints, transitions, or
-- reserves; the fixed regressions below expose decided facts about those
-- transitions without exporting a way to perform one.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderAdmissionEpoch
  , CascadeAuditFreezeBinding
  , mkCascadeAuditFreezeBinding
  , ProviderAdmissionEpochView (..)
  , ProviderAdmissionEpochError (..)
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , providerAdmissionEpochView
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
  , confirmCascadeTerminalAuditReceipt
  , CascadeTerminalAuditReceiptRegression (..)
  , fixedCascadeTerminalAuditReceiptRegression
  , ProviderCredentialRevocationReceipt
  , mkProviderCredentialRevocationReceipt
  , ProviderAdmissionRevokeRefusal (..)
  , CascadeCredentialRevocationRegression (..)
  , fixedCascadeCredentialRevocationRegression
  )
where

import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
