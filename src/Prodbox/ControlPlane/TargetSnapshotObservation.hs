{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | A signed Target observation tied to the Authority snapshot from which its
-- response-verification key was selected. This module does not authenticate the
-- repository, map the origin to a physical Pod, or commit a readback.
module Prodbox.ControlPlane.TargetSnapshotObservation
  ( TargetSnapshotObservation
  , TargetSnapshotObservationError (..)
  , observeTargetFromSnapshot
  , targetSnapshotObservationValue
  , targetSnapshotObservationAuthoritySnapshot
  )
where

import Data.Bifunctor (first)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , authenticatedClientTransportWithin
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionSnapshot)
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.RpcKeyRegistry (RpcKeyOrigin, rpcKeyOriginScope)
import Prodbox.ControlPlane.TargetAuthorityEpochClient
  ( TargetEpochClientError
  , observeTargetAuthorityEpochWithVerifiedResponse
  )
import Prodbox.ControlPlane.TargetAuthorityEpochExecution (TargetEpochObservation)
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetResponseTrust
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , targetAgentClusterIdentity
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

data TargetSnapshotObservation revision
  = TargetSnapshotObservation
      !(TargetResponseTrust revision)
      !TargetEpochObservation

data TargetSnapshotObservationError
  = TargetSnapshotAgentScopeMismatch
  | TargetSnapshotTrustRefused !TargetResponseTrustError
  | TargetSnapshotClientRefused !TargetEpochClientError
  deriving stock (Eq, Show)

-- | The caller must obtain the snapshot and origin from authenticated owners,
-- enforce the original physical deadline around the entire call, and use this
-- exact snapshot revision for any subsequent readback CAS. A successful response
-- is not proof of the Agent's physical Pod or of a completed cutover.
observeTargetFromSnapshot
  :: AuthorityScope
  -> RpcKeyOrigin
  -> TargetAgentIdentity
  -> AuthorityAdmissionSnapshot revision
  -> AuthorityTime
  -> AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetSecretId
  -> IO (Either TargetSnapshotObservationError (TargetSnapshotObservation revision))
observeTargetFromSnapshot scope origin agent snapshot deadline transport target
  | targetAgentClusterIdentity agent /= authorityScopeText (rpcKeyOriginScope origin) =
      pure (Left TargetSnapshotAgentScopeMismatch)
  | otherwise = case first TargetSnapshotTrustRefused (selectTargetResponseTrust scope origin snapshot) of
      Left failure -> pure (Left failure)
      Right trust -> do
        result <-
          observeTargetAuthorityEpochWithVerifiedResponse
            (authenticatedClientTransportWithin deadline transport)
            agent
            (targetResponseTrustKey trust)
            target
        pure (TargetSnapshotObservation trust <$> first TargetSnapshotClientRefused result)

targetSnapshotObservationValue :: TargetSnapshotObservation revision -> TargetEpochObservation
targetSnapshotObservationValue (TargetSnapshotObservation _ value) = value

targetSnapshotObservationAuthoritySnapshot
  :: TargetSnapshotObservation revision -> AuthorityAdmissionSnapshot revision
targetSnapshotObservationAuthoritySnapshot (TargetSnapshotObservation trust _) = targetResponseTrustSnapshot trust
