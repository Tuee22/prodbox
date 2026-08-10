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
  , AdmissionSet (..)
  , noAdmissions
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
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

-- | The admissions accumulated so far in one reconcile run.
--
-- Sprint @4.64@ moved this type and 'noAdmissions' here from the public module.
-- The reason is the defect Sprint @4.61@ fixed by hand: a reconcile runs its
-- phases as separate calls, each threading the previous phase's set, and
-- nothing stopped a later phase being handed an /empty/ set instead. That is
-- the reset, and re-typing it as \"a value only an earlier phase can produce\"
-- is what makes it unrepresentable rather than merely refused.
--
-- Every @src\/@ path other than this module's two allowed importers is barred
-- from naming this module by @prodbox dev check@, so an empty admission set is
-- a compile error at every production call site. Test modules import it
-- directly and deliberately: a suite must be able to construct the empty case
-- in order to assert what it refuses.
newtype AdmissionSet = AdmissionSet (Map ComponentId DependencyAdmission)
  deriving stock (Eq, Show)

-- | The empty admission set — the start of a reconcile run and nothing else.
noAdmissions :: AdmissionSet
noAdmissions = AdmissionSet Map.empty
