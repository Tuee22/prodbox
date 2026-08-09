{-# LANGUAGE DerivingStrategies #-}

-- | Package-internal representation of a dependency admission.
--
-- The two constructors live here and nowhere else. Sprint @4.56@ adds a
-- @prodbox dev check@ rule so that naming this module from any other @src\/@
-- path fails the build; import "Prodbox.Lifecycle.DependencyAdmission", which
-- exports both types abstractly beside their sole minters.
module Prodbox.Lifecycle.DependencyAdmission.Internal
  ( DependencyAdmission (..)
  , MutationAdmission (..)
  )
where

import Numeric.Natural (Natural)
import Prodbox.Config.ComponentGraph (ComponentId)

-- | Evidence that one graph-declared dependency was observed ready, and when.
--
-- Minted only from a @VerdictReady@ — the sole arm of 'ReadinessVerdict' that
-- carries an @AdmissionTicket@, which @classifyObservation@ in turn produces
-- only after same-reference, same-service, same-authority, freshness, and
-- generation gates have all passed.
data DependencyAdmission = DependencyAdmission
  { admittedComponent :: !ComponentId
  , admittedAtMicros :: !Natural
  }
  deriving stock (Eq, Show)

-- | Evidence that /every/ graph-declared dependency of a component was admitted
-- recently enough to act on.
--
-- This is the value a mutating step takes as an argument. It carries the
-- component it admits and the instant the re-validation ran, so a step cannot
-- be handed one minted for a different component.
data MutationAdmission = MutationAdmission
  { mutationAdmittedComponent :: !ComponentId
  , mutationAdmittedAtMicros :: !Natural
  , mutationAdmittedDependencies :: ![DependencyAdmission]
  }
  deriving stock (Eq, Show)
