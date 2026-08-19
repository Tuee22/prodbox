-- | Read-only facade for the retained Provider admission epoch.  Generation
-- adoption, pending-operation classification, and revocation receipts remain
-- package-private.
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
  )
where

import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
