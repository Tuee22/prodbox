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
  , Dns01ChallengeDesiredAbsence (..)
  , mkDns01ChallengeDesiredAbsence
  , dns01ChallengeDesiredAbsenceOutcome
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind (CleanupRequiresAttempt)
  , CleanupNodeId
  , mkCleanupNodeId
  )
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

-- | Sprint 4.85: the desired-absence obligation, as data.
--
-- This replaces the Sprint-@5.29@ registry entry, which was a 'ManagedResource'
-- built from two caller-supplied @FilePath -> IO@ closures. That shape had two
-- defects independent of whether it worked. It let a caller substitute the
-- effect *after* the registry entry was projected, so registry membership did
-- not determine one legal program; and it made this production module import
-- @Prodbox.Test.ManagedCleanupPlan@ for its dependency edge. Neither closure
-- was ever wired to a production caller, so nothing was lost by removing them.
--
-- What survives unchanged is everything Sprint @5.29@ actually established:
-- the exact pre-issuance coordinate, the three-valued absence classification,
-- and the always-run edge.
data Dns01ChallengeDesiredAbsence = Dns01ChallengeDesiredAbsence
  { dns01ChallengeAbsenceIntent :: !Dns01ChallengeIntent
  , dns01ChallengeAbsenceNode :: !CleanupNodeId
  , dns01ChallengeAbsenceDependency :: !CleanupDependency
  }
  deriving stock (Eq, Show)

-- | Build the obligation. The node id is the record name itself, so a node and
-- the TXT it removes cannot drift apart, and the edge is always-run:
-- 'CleanupRequiresAttempt' on the issuance node, so an issuance that /failed/
-- still has its record removed. A 'CleanupRequiresSuccess' edge here would be
-- precisely wrong — the failure case is the one that leaves residue.
mkDns01ChallengeDesiredAbsence
  :: CleanupNodeId
  -- ^ the issuance node this cleanup follows
  -> Dns01ChallengeIntent
  -> Either Text Dns01ChallengeDesiredAbsence
mkDns01ChallengeDesiredAbsence issuanceNode intent = do
  node <- mkCleanupNodeId (dnsCoordinateName (dns01ChallengeCoordinate intent))
  pure
    Dns01ChallengeDesiredAbsence
      { dns01ChallengeAbsenceIntent = intent
      , dns01ChallengeAbsenceNode = node
      , dns01ChallengeAbsenceDependency =
          CleanupDependency
            { cleanupDependencyNode = issuanceNode
            , cleanupDependencyKind = CleanupRequiresAttempt
            }
      }

-- | The desired-absence decision, as a total pure function of both results.
--
-- The interpreter deletes the Kubernetes object that owns the record and then
-- reads the TXT back. The read-back runs whether or not the delete reported
-- success — a delete that worked and a delete that lost its response are
-- indistinguishable from the call, and only the read-back separates them — and
-- the delete result is therefore deliberately not a parameter of the verdict.
-- It is retained separately as evidence.
--
-- Only an observed absence closes the obligation. A still-present record and an
-- unobservable one are different failures and stay different.
dns01ChallengeDesiredAbsenceOutcome
  :: DnsRecordObservation -> Dns01ChallengeAbsence
dns01ChallengeDesiredAbsenceOutcome = dns01ChallengeAbsenceFrom
