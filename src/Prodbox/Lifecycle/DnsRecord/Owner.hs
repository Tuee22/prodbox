-- | DNS record ownership and the authority a running process holds over it.
--
-- 'DnsOwnerAuthority' is opaque here.  Its one minter is
-- 'dnsOwnerAuthorityForProcess', a total function of the two facts that
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
  , dnsOwnerAuthorityForProcess
  , authorizedDnsOwner
  )
where

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
-- this table instead of a silent 'Nothing'.
dnsOwnerAuthorityForProcess :: RuntimeRole -> Substrate -> Maybe DnsOwnerAuthority
dnsOwnerAuthorityForProcess role substrate = case (role, substrate) of
  (GatewayRuntime, SubstrateHomeLocal) -> Just (DnsOwnerAuthority HomeGatewayDnsOwner)
  (GatewayRuntime, SubstrateAws) -> Nothing
  (ProviderWorkerRuntime, SubstrateAws) -> Just (DnsOwnerAuthority AwsLifecycleProviderDnsOwner)
  (ProviderWorkerRuntime, SubstrateHomeLocal) -> Nothing
  (BootstrapBroker, SubstrateHomeLocal) -> Nothing
  (BootstrapBroker, SubstrateAws) -> Nothing
  (LifecycleAuthorityRuntime, SubstrateHomeLocal) -> Nothing
  (LifecycleAuthorityRuntime, SubstrateAws) -> Nothing
  (AuthorityBackupRuntime, SubstrateHomeLocal) -> Nothing
  (AuthorityBackupRuntime, SubstrateAws) -> Nothing
  (TlsRetentionRuntime, SubstrateHomeLocal) -> Nothing
  (TlsRetentionRuntime, SubstrateAws) -> Nothing
  (TargetSecretAgentRuntime, SubstrateHomeLocal) -> Nothing
  (TargetSecretAgentRuntime, SubstrateAws) -> Nothing

-- | The owner an authority entitles its holder to act as.
authorizedDnsOwner :: DnsOwnerAuthority -> DnsRecordOwner
authorizedDnsOwner (DnsOwnerAuthority owner) = owner
