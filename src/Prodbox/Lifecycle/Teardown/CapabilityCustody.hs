-- | Sprint 4.89: the capability-custody boundary.
--
-- A zero-definition facade, in the placement the cascade-evidence boundary
-- already uses: the vocabulary an outside caller may name is re-exported from
-- the exposed @Universe@ module, and every eliminator, the derived dependant
-- set, and the destructive boundary's argument type stay Cabal-hidden in
-- @Internal@.
--
-- Holding a value from here authorizes nothing. The disposition is what a
-- destructive boundary consumes, and it cannot be constructed from a capability
-- alone.
module Prodbox.Lifecycle.Teardown.CapabilityCustody
  ( CustodialCapability (..)
  , custodialCapabilityUniverse
  , renderCustodialCapability
  , CustodyIndex (..)
  , CapabilityDisposition
  , dispositionCapability
  , retireDispositionCount
  , holdDispositionCount
  , InertnessProof (..)
  , DependantAbsenceProof (..)
  , SuccessorCapability (..)
  , JointDestructionProof (..)

    -- * Non-authorizing diagnostics
  , CapabilityCustodyRegression
  , fixedCapabilityCustodyRegression
  , capabilityCustodyUniverseClosed
  , capabilityCustodyDischargeMandatory
  , capabilityCustodyDependantsDerived
  , capabilityCustodyUnderivableNotEmpty
  , capabilityCustodyGateMeasuredAgainstDefect
  , capabilityCustodyReleaseRefusalsExact
  , capabilityCustodyLiftInvariant
  , capabilityCustodyCheckpointArmsExact
  , capabilityCustodyRunReadBackDischargeExact
  , capabilityCustodyInertnessOnlyFromEmptiness
  , capabilityCustodyRetirementRotatesOntoRetained
  , capabilityCustodyRevocationIsInertnessOnly
  )
where

import Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
