-- | Read-only facade for the retained Provider admission epoch.  Generation
-- adoption, Cascade freeze bindings, pending-operation classification, and
-- revocation receipts remain package-private until the canonical terminal
-- audit route exists.
--
-- Sprint 4.85 added the generation-binding and Cascade-audit freeze
-- transitions, but only as package-private aggregate commands consumed by
-- @Prodbox.Lifecycle.Authority.Admission@.  Nothing here mints, transitions, or
-- reserves; the fixed regressions below expose decided facts about those
-- transitions without exporting a way to perform one.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderAdmissionEpoch
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
