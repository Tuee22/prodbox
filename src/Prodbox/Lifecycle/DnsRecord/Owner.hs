-- | DNS record ownership and the authority a running process holds over it.
--
-- 'DnsOwnerAuthority' is opaque here.  Its one minter is
-- 'dnsOwnerAuthoritiesForProcess', a total function of the two facts that
-- identify a running prodbox process: the 'RuntimeRole' it selected before it
-- decoded configuration ("Prodbox.Runtime.Role") and the 'Substrate' that
-- configuration declares.  A destroy program consumes the authority rather than
-- a second copy of the coordinate's owner, so naming an owner is no longer the
-- same thing as holding it.
--
-- Two consequences are worth stating plainly, because they are what the type
-- buys:
--
--   * __Neither cert-manager owner is in the minter's range.__ cert-manager is
--     not a prodbox process; it has no 'RuntimeRole', so no @(role, substrate)@
--     pair yields 'HomeCertManagerDns01Owner' or 'AwsCertManagerDns01Owner'.
--     A prodbox process removes a cert-manager DNS01 record by deleting the
--     Kubernetes object that owns it and proving absence by read-back — never
--     by naming the owner on both sides of a comparison.
--
--   * __The gateway holds no AWS DNS ownership.__ EKS DNS mutation is disabled
--     in the target architecture, so @(GatewayRuntime, SubstrateAws)@ mints
--     nothing.
--
-- What this does /not/ prove is stated in @chaos_hardening_doctrine.md § 22@: a
-- ring-2 gate bounds a process, not a protocol.  It makes an unauthorized
-- destroy unconstructible inside this binary; it says nothing about a second
-- writer reaching Route 53 by another route.
module Prodbox.Lifecycle.DnsRecord.Owner
  ( DnsRecordOwner (..)
  , DnsOwnerAuthority
  , allDnsRecordOwners
  , dnsOwnerAuthoritiesForProcess
  , dnsOwnerAuthorityForProcess
  , authorizedDnsOwner
  )
where

import Data.List (find)
import Prodbox.Lifecycle.DnsRecord.Owner.Internal
  ( DnsOwnerAuthority (..)
  , DnsRecordOwner (..)
  )
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Substrate (Substrate (..))

-- | Every owner, for total folds and inventory proofs.
allDnsRecordOwners :: [DnsRecordOwner]
allDnsRecordOwners = [minBound .. maxBound]

-- | The sole minter of a 'DnsOwnerAuthority'.
--
-- Total over @'RuntimeRole' × 'Substrate'@ and written out pair by pair rather
-- than with a wildcard, so adding a role or a substrate is a compile error at
-- this table instead of a silent empty list.
--
-- Sprint @4.73@ widened the range from one owner to a list, because one process
-- legitimately owns more than one DNS lane: the Provider Worker writes both the
-- per-run public A record and the long-lived SES identity, DKIM, and inbound
-- records, and those lanes differ in lifecycle class and in admissible record
-- type.  What did __not__ widen is who may hold a lane — a pair still holds
-- exactly the owners written beside it, and there is no other way to build the
-- value.
dnsOwnerAuthoritiesForProcess :: RuntimeRole -> Substrate -> [DnsOwnerAuthority]
dnsOwnerAuthoritiesForProcess role substrate = case (role, substrate) of
  (GatewayRuntime, SubstrateHomeLocal) -> [DnsOwnerAuthority HomeGatewayDnsOwner]
  (GatewayRuntime, SubstrateAws) -> []
  (ProviderWorkerRuntime, SubstrateAws) ->
    [ DnsOwnerAuthority AwsLifecycleProviderDnsOwner
    , DnsOwnerAuthority AwsSesDnsOwner
    ]
  (ProviderWorkerRuntime, SubstrateHomeLocal) -> []
  (BootstrapBroker, SubstrateHomeLocal) -> []
  (BootstrapBroker, SubstrateAws) -> []
  (LifecycleAuthorityRuntime, SubstrateHomeLocal) -> []
  (LifecycleAuthorityRuntime, SubstrateAws) -> []
  (AuthorityBackupRuntime, SubstrateHomeLocal) -> []
  (AuthorityBackupRuntime, SubstrateAws) -> []
  (TlsRetentionRuntime, SubstrateHomeLocal) -> []
  (TlsRetentionRuntime, SubstrateAws) -> []
  (TargetSecretAgentRuntime, SubstrateHomeLocal) -> []
  (TargetSecretAgentRuntime, SubstrateAws) -> []

-- | The authority for exactly one lane, when this process holds that lane.
--
-- The caller names the lane it wants and the table decides whether the process
-- holds it, so naming an owner is still not the same thing as holding one: a
-- lane this @(role, substrate)@ does not own answers 'Nothing', and 'Nothing'
-- is the only other inhabitant.
dnsOwnerAuthorityForProcess
  :: RuntimeRole
  -> Substrate
  -> DnsRecordOwner
  -> Maybe DnsOwnerAuthority
dnsOwnerAuthorityForProcess role substrate owner =
  find ((== owner) . authorizedDnsOwner) (dnsOwnerAuthoritiesForProcess role substrate)

-- | The owner an authority entitles its holder to act as.
authorizedDnsOwner :: DnsOwnerAuthority -> DnsRecordOwner
authorizedDnsOwner (DnsOwnerAuthority owner) = owner
