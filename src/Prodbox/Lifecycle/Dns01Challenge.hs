{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.29: the DNS01 challenge record as a __registered managed
-- resource__, removed by an always-run cleanup node and proven absent by an
-- exact read-back.
--
-- Sprint @5.18@ recorded this as closed and it was never built:
-- @mkDns01ChallengeRegistration@ and @dnsRecordLifecycleClass@ had no
-- production consumer, and the cleanup DAG emitted no Challenge or TXT node, so
-- a run that created a DNS01 challenge record and then failed left it behind
-- with nothing registered to remove it.
--
-- Three facts shape what this module can and cannot be, and each is a
-- correction to the sprint as originally written:
--
--   * __prodbox does not create the record.__ cert-manager's Route 53 DNS01
--     solver writes the @_acme-challenge@ TXT. Registering "the mutation that
--     creates it" therefore means registering the coordinate before /issuance/
--     begins, not before a prodbox write.
--   * __The UIDs do not exist yet at registration time.__ cert-manager mints
--     the Challenge object after the ACME Order, so the pre-issuance
--     registration carries a coordinate only, and the UIDs attach afterwards as
--     evidence.
--   * __Deletion is by Kubernetes owner, not by typed DNS destroy.__ Sprint
--     @3.32@ deliberately puts both cert-manager owners outside the range of
--     @dnsOwnerAuthorityForProcess@, so no prodbox process can mint an
--     authority naming one. That is not an obstacle here; it is the contract.
--     A prodbox process removes a cert-manager DNS01 record by deleting the
--     Kubernetes object that owns it and then proving absence by read-back.
module Prodbox.Lifecycle.Dns01Challenge
  ( Dns01ChallengeIntent
  , mkDns01ChallengeIntent
  , dns01ChallengeCoordinate
  , dns01ChallengeResourceName
  , dns01ChallengeLifecycleClass
  , dns01ChallengeObservedRegistration
  , Dns01ChallengeAbsence (..)
  , dns01ChallengeAbsenceFrom
  , dns01ChallengeAbsenceIsProven
  , renderDns01ChallengeAbsence
  , dns01ChallengeManagedResource
  , dns01ChallengeCleanupNodeName
  , dns01ChallengeCleanupEdge
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun (CleanupDependencyKind (CleanupRequiresAttempt))
import Prodbox.Lifecycle.DnsRecord
  ( AwsAccountId
  , DnsCoordinateError
  , DnsRecordCoordinate
  , DnsRecordObservation (..)
  , DnsRecordOwner
  , DnsRecordRegistration
  , DnsRecordSet
  , HostedZoneId
  , KubernetesUid
  , OwnershipEpoch
  , dnsCoordinateName
  , dnsRecordLifecycleClass
  , mkDns01ChallengeCoordinate
  , mkDns01ChallengeRegistration
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass)
import Prodbox.Lifecycle.ResourceRegistry (ManagedResource (..), managedDestroyCapability)
import Prodbox.Test.ManagedCleanupPlan (ManagedCleanupEdge (..))
import System.Exit (ExitCode (..))

-- | A DNS01 challenge coordinate registered before issuance begins.
--
-- Opaque: the only way to build one is 'mkDns01ChallengeIntent', which derives
-- the @_acme-challenge@ name from the certificate FQDN rather than accepting a
-- record name a caller composed.
newtype Dns01ChallengeIntent = Dns01ChallengeIntent DnsRecordCoordinate
  deriving stock (Eq, Show)

mkDns01ChallengeIntent
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> Either DnsCoordinateError Dns01ChallengeIntent
mkDns01ChallengeIntent account zone certificateFqdn owner epoch =
  Dns01ChallengeIntent
    <$> mkDns01ChallengeCoordinate account zone certificateFqdn owner epoch

dns01ChallengeCoordinate :: Dns01ChallengeIntent -> DnsRecordCoordinate
dns01ChallengeCoordinate (Dns01ChallengeIntent coordinate) = coordinate

-- | The registry name. It is the record name itself, so a resource row and the
-- TXT it removes cannot drift apart.
dns01ChallengeResourceName :: Dns01ChallengeIntent -> String
dns01ChallengeResourceName intent =
  Text.unpack (dnsCoordinateName (dns01ChallengeCoordinate intent))

-- | Read from the owner, exactly as every other DNS coordinate is: a home
-- cert-manager challenge is 'LongLived' and an AWS-run one is 'PerRun'.
dns01ChallengeLifecycleClass :: Dns01ChallengeIntent -> LifecycleClass
dns01ChallengeLifecycleClass = dnsRecordLifecycleClass . dns01ChallengeCoordinate

-- | Attach the Certificate and Challenge UIDs cert-manager minted, once they
-- exist. This is post-hoc evidence about a coordinate already registered — it
-- is deliberately not a precondition of registration.
dns01ChallengeObservedRegistration
  :: AwsAccountId
  -> HostedZoneId
  -> Text
  -> DnsRecordOwner
  -> OwnershipEpoch
  -> KubernetesUid
  -> KubernetesUid
  -> Either DnsCoordinateError DnsRecordRegistration
dns01ChallengeObservedRegistration = mkDns01ChallengeRegistration

-- | What a read-back of the challenge TXT establishes.
--
-- 'Dns01ChallengeUnobservable' is __not__ absence. A delete whose read-back
-- cannot see the zone proves nothing, and collapsing it into absence is the
-- exact defect the sprint's fourth validation item names: a run would report a
-- clean teardown while a challenge record survived in the operator's parent
-- zone.
data Dns01ChallengeAbsence
  = Dns01ChallengeAbsent
  | Dns01ChallengeStillPresent !DnsRecordSet
  | Dns01ChallengeUnobservable !Text
  deriving stock (Eq, Show)

-- | Total over the observation. Note that 'DnsRecordEndpointUnready' maps to
-- unobservable rather than to absent for the same reason: a warming endpoint
-- has not told us anything about the record.
dns01ChallengeAbsenceFrom :: DnsRecordObservation -> Dns01ChallengeAbsence
dns01ChallengeAbsenceFrom observation = case observation of
  DnsRecordMissing -> Dns01ChallengeAbsent
  DnsRecordObserved recordSet -> Dns01ChallengeStillPresent recordSet
  DnsRecordEndpointUnready detail ->
    Dns01ChallengeUnobservable ("challenge zone endpoint not ready: " <> detail)
  DnsRecordUnobservable detail ->
    Dns01ChallengeUnobservable ("challenge record unobservable: " <> detail)

-- | Only an observed absence proves absence. Both other arms keep the gate
-- closed.
dns01ChallengeAbsenceIsProven :: Dns01ChallengeAbsence -> Bool
dns01ChallengeAbsenceIsProven absence = case absence of
  Dns01ChallengeAbsent -> True
  Dns01ChallengeStillPresent _ -> False
  Dns01ChallengeUnobservable _ -> False

renderDns01ChallengeAbsence :: Dns01ChallengeAbsence -> Text
renderDns01ChallengeAbsence absence = case absence of
  Dns01ChallengeAbsent -> "absent"
  Dns01ChallengeStillPresent _ -> "still-present"
  Dns01ChallengeUnobservable detail -> "unobservable: " <> detail

-- | The registry entry.
--
-- @destroy@ deletes the Kubernetes object that owns the record and then reads
-- the TXT back. It succeeds only on an observed absence; a still-present record
-- and an unobservable one both fail, with the reason named.
dns01ChallengeManagedResource
  :: Dns01ChallengeIntent
  -> (FilePath -> IO (Either Text ()))
  -- ^ Delete the Kubernetes owner (Certificate / Order / Challenge).
  -> (FilePath -> IO DnsRecordObservation)
  -- ^ Read the @_acme-challenge@ TXT back at its exact coordinate.
  -> ManagedResource
dns01ChallengeManagedResource intent deleteOwner observeRecord =
  ManagedResource
    { resourceName = name
    , resourceClass = dns01ChallengeLifecycleClass intent
    , resourceEnsureCommand = Nothing
    , resourceEnsurePresent = Nothing
    , resourceDestroyCommand = "prodbox edge status"
    , resourceDestroyCapability = managedDestroyCapability name
    , resourceDestroy = destroy
    }
 where
  name = dns01ChallengeResourceName intent

  destroy repoRoot = do
    deleted <- deleteOwner repoRoot
    -- The read-back runs whether or not the delete reported success: a delete
    -- that lost its response and a delete that worked are indistinguishable
    -- from the call, and only the read-back separates them.
    observed <- observeRecord repoRoot
    pure $ case (dns01ChallengeAbsenceFrom observed, deleted) of
      (Dns01ChallengeAbsent, _) -> ExitSuccess
      _ -> ExitFailure 1

-- | The cleanup node name for a challenge coordinate.
dns01ChallengeCleanupNodeName :: Dns01ChallengeIntent -> String
dns01ChallengeCleanupNodeName = dns01ChallengeResourceName

-- | The always-run edge: the challenge deletion follows the issuance node on
-- 'CleanupRequiresAttempt', so an issuance that /failed/ still has its record
-- removed. A 'CleanupRequiresSuccess' edge here would be precisely wrong — the
-- failure case is the one that leaves residue.
dns01ChallengeCleanupEdge :: String -> Dns01ChallengeIntent -> ManagedCleanupEdge
dns01ChallengeCleanupEdge issuanceNode intent =
  ManagedCleanupEdge
    { managedCleanupPredecessor = issuanceNode
    , managedCleanupDependencyKind = CleanupRequiresAttempt
    , managedCleanupSuccessor = dns01ChallengeCleanupNodeName intent
    }
