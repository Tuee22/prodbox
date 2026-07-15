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
-- ([bootstrap_readiness_doctrine.md](../../documents/engineering/bootstrap_readiness_doctrine.md)),
-- indexed operations + flat external evidence
-- ([pure_fp_standards.md](../../documents/engineering/pure_fp_standards.md)), and
-- the capability + evidence algebra
-- ([lifecycle_control_plane_architecture.md](../../documents/engineering/lifecycle_control_plane_architecture.md)).
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
