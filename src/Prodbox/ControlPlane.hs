-- | Sprint 1.61: the operation-indexed capability algebra — the additive
-- foundation that replaces nominal component readiness and caller-injected
-- arbitrary @IO@ with an indexed algebra in which the exact reference used to
-- execute an operation also owns its observation and admission evidence.
--
-- This umbrella re-exports the public surface (opaque types WITHOUT their
-- constructors; all smart constructors, accessors, and classifiers). It is a
-- PURE foundation — no @IO@. The interpreter, the component-graph lowering over
-- capabilities, and the migration of the existing readiness/effect consumers are
-- a deferred follow-on; this increment provides the sanctioned target so that
-- follow-on has something to migrate onto.
--
-- Doctrine: exact-operation readiness
-- (bootstrap_readiness_doctrine.md (historical bootstrap_readiness_doctrine.md at revision `583443f`)),
-- indexed operations + flat external evidence
-- (pure_fp_standards.md (historical pure_fp_standards.md at revision `583443f`)), and
-- the capability + evidence algebra
-- (lifecycle_control_plane_architecture.md (historical lifecycle_control_plane_architecture.md at revision `583443f`)).
module Prodbox.ControlPlane
  ( module Prodbox.ControlPlane.CapabilityKind
  , module Prodbox.ControlPlane.Coordinate
  , module Prodbox.ControlPlane.CapabilityRef
  , module Prodbox.ControlPlane.Observation
  , module Prodbox.ControlPlane.Permit
  , module Prodbox.ControlPlane.Program
  )
where

import Prodbox.ControlPlane.CapabilityKind
import Prodbox.ControlPlane.CapabilityRef
import Prodbox.ControlPlane.Coordinate
import Prodbox.ControlPlane.Observation
import Prodbox.ControlPlane.Permit
import Prodbox.ControlPlane.Program
