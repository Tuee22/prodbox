-- | Authoritative derivation of the Target-Agent requirement from a sealed
-- compiled lifecycle graph and an Authority-reobserved durable CleanupRun.
-- This facade is deliberately read-only: the future Authority interpreter is
-- the only production boundary allowed to call the package-private join.
module Prodbox.Lifecycle.Teardown.RecoveryRequirement
  ( DerivedOrdinaryTeardownRecoveryRequirement
  , RecoveryRequirementDiagnostic
  , RecoveryRequirementError (..)
  , derivedOrdinaryTeardownTargetAgent
  , derivedRecoveryRequirementDiagnostic
  , recoveryRequirementDiagnosticRunId
  , recoveryRequirementDiagnosticGraphDigest
  , recoveryRequirementDiagnosticCapabilityCatalogDigest
  , recoveryRequirementDiagnosticNonterminalCapabilities
  , recoveryRequirementDiagnosticIdentityDigest
  , RecoveryRequirementFixtureRegression
  , fixedRecoveryRequirementFixtureRegression
  , recoveryFixtureCatalogConstructionRefused
  , recoveryFixtureCurrentProgramTargetAgents
  , recoveryFixtureCapabilityIdentitySeparated
  , recoveryFixtureFullCatalogIdentitySeparated
  , recoveryFixturePendingTargetAgent
  , recoveryFixtureRunningTargetAgent
  , recoveryFixtureCompletedTargetAgent
  , recoveryFixtureBlockedTargetAgent
  , recoveryFixtureTerminalStatesPreserved
  , recoveryFixtureBindingMismatchesRefused
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryRequirement.Internal
