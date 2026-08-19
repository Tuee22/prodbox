-- | Public facade over the Authority's accepted-readiness namespace.
--
-- The opaque 'AcceptedHostCleanupReadiness' crosses this boundary without an
-- accessor for the durable binding it holds: restoring readiness needs the
-- exact 'Prodbox.Lifecycle.CleanupRun.CleanupRun' and its observation scope, so
-- only the lifecycle-owned runner arms in
-- "Prodbox.Lifecycle.HostCleanupAuthorityArms" can turn one back into proof.
module Prodbox.ControlPlane.HostCleanupReadinessRepository
  ( HostCleanupReadinessAuthorityClient
  , modelBHostCleanupReadinessRepository
  , hostCleanupReadinessAuthorityLogicalName
  , hostCleanupReadinessModelBCodec
  , HostCleanupReadinessAcceptResult (..)
  , acceptHostCleanupReadinessAttempt
  , HostCleanupReadinessRepositoryError (..)
  , renderHostCleanupReadinessRepositoryError
  , AcceptedHostCleanupReadiness
  , acceptedHostCleanupReadinessRunId
  , independentlyReadBackAcceptedHostCleanupReadiness
  )
where

import Prodbox.ControlPlane.HostCleanupReadinessRepository.Internal
