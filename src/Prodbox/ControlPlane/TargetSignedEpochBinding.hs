{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Opt-in signed Target row reads for a snapshot-aware Authority readback.
-- Construction does not attest an origin or a physical Agent; the caller owns
-- those observations, the original deadline and all resource admission.
module Prodbox.ControlPlane.TargetSignedEpochBinding
  ( TargetSignedAgentRegistry
  , TargetSignedAgentRegistryError (..)
  , mkTargetSignedAgentRegistry
  , targetSignedEpochBindingInterpreter
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientTransport)
import Prodbox.ControlPlane.AuthenticationRegistry (controlPlaneSigningKeyPrincipal)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint (AuthorityAdmissionSnapshot)
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.RequestAuthentication (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.RpcKeyRegistry (RpcKeyOrigin, rpcKeyOriginRef, rpcKeyOriginScope)
import Prodbox.ControlPlane.TargetAuthorityEpochBinding
  ( TargetEpochBindingEffect (..)
  , TargetEpochBindingFailure (..)
  , TargetEpochBindingInterpreter (..)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , targetAgentClusterIdentity
  )
import Prodbox.ControlPlane.TargetSnapshotObservation
  ( observeTargetFromSnapshot
  , targetSnapshotObservationValue
  )
import Prodbox.Lifecycle.Authority.EpochTopology (CutoverSubstrate (CutoverHome))
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetSignedAgentRegistry
  = TargetSignedAgentRegistry
      ( Map
          CutoverSubstrate
          (TargetAgentIdentity, RpcKeyOrigin, AuthenticatedClientTransport 'TargetSecretAgentRuntime)
      )

data TargetSignedAgentRegistryError
  = TargetSignedRegistryHomeMissing
  | TargetSignedRegistryDuplicateSubstrate
  | TargetSignedRegistryAliasedCluster
  | TargetSignedRegistryAliasedOrigin
  | TargetSignedRegistryOriginMismatch
  deriving stock (Eq, Show)

mkTargetSignedAgentRegistry
  :: [ ( CutoverSubstrate
       , TargetAgentIdentity
       , RpcKeyOrigin
       , AuthenticatedClientTransport 'TargetSecretAgentRuntime
       )
     ]
  -> Either TargetSignedAgentRegistryError TargetSignedAgentRegistry
mkTargetSignedAgentRegistry entries
  | Map.notMember CutoverHome rows = Left TargetSignedRegistryHomeMissing
  | Map.size rows /= length entries = Left TargetSignedRegistryDuplicateSubstrate
  | Set.size clusters /= length entries = Left TargetSignedRegistryAliasedCluster
  | Set.size origins /= length entries = Left TargetSignedRegistryAliasedOrigin
  | any invalid entries = Left TargetSignedRegistryOriginMismatch
  | otherwise = Right (TargetSignedAgentRegistry rows)
 where
  rows =
    Map.fromList
      [(substrate, (agent, origin, transport)) | (substrate, agent, origin, transport) <- entries]
  clusters = Set.fromList [targetAgentClusterIdentity agent | (_, agent, _, _) <- entries]
  origins = Set.fromList [origin | (_, _, origin, _) <- entries]
  invalid (_, agent, origin, _) =
    targetAgentClusterIdentity agent /= authorityScopeText (rpcKeyOriginScope origin)
      || controlPlaneSigningKeyPrincipal (rpcKeyOriginRef origin) /= CallerService TargetSecretAgentRuntime

-- | Replace only Agent selection and row reads. Other effects remain with the
-- supplied interpreter. The enclosing Authority readback must pass its own
-- snapshot here, enforce its physical deadline, and CAS that snapshot revision.
targetSignedEpochBindingInterpreter
  :: AuthorityScope
  -> AuthorityAdmissionSnapshot revision
  -> TargetSignedAgentRegistry
  -> TargetEpochBindingInterpreter IO
  -> TargetEpochBindingInterpreter IO
targetSignedEpochBindingInterpreter scope snapshot (TargetSignedAgentRegistry agents) base =
  TargetEpochBindingInterpreter interpret
 where
  interpret :: TargetEpochBindingEffect result -> IO (Either TargetEpochBindingFailure result)
  interpret effect = case effect of
    ReadTargetBindingAgent substrate -> pure $ do
      (agent, _, _) <- registered substrate
      pure agent
    ReadTargetBindingRow deadline substrate target -> case registered substrate of
      Left failure -> pure (Left failure)
      Right (agent, origin, transport) -> do
        observed <- observeTargetFromSnapshot scope origin agent snapshot deadline transport target
        pure $ case observed of
          Left _ -> Left (TargetBindingRowUnavailable target)
          Right value -> Right (targetSnapshotObservationValue value)
    ReadTargetBindingTime -> runTargetEpochBindingEffect base effect
    ReadTargetBindingEpoch _ -> runTargetEpochBindingEffect base effect
    ReadTargetBindingIssuer _ -> runTargetEpochBindingEffect base effect
  registered substrate = maybe (Left TargetBindingAgentUnregistered) Right (Map.lookup substrate agents)
