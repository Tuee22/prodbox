{-# LANGUAGE DerivingStrategies #-}

-- | Package-internal representation of DNS record ownership.
--
-- The 'DnsOwnerAuthority' constructor lives here and nowhere else.  A value of
-- that type asserts that the process holding it /is/ the named owner, and that
-- assertion is worth something only while one module can make it.  Sprint
-- @3.32@ adds a @prodbox dev check@ rule so that naming this module from any
-- other @src\/@ path fails the build; import
-- "Prodbox.Lifecycle.DnsRecord.Owner" instead, which exports the type
-- abstractly beside its sole minter.
module Prodbox.Lifecycle.DnsRecord.Owner.Internal
  ( DnsRecordOwner (..)
  , DnsOwnerAuthority (..)
  )
where

-- | The closed set of owners a registered DNS coordinate can be bound to.
--
-- Three of them name a prodbox process; two name the substrate-local
-- cert-manager installation, which is not a prodbox process and therefore holds
-- no 'DnsOwnerAuthority' — see 'Prodbox.Lifecycle.DnsRecord.Owner' for what
-- that excludes.
--
-- Sprint @4.73@ adds 'AwsSesDnsOwner' rather than reusing
-- 'AwsLifecycleProviderDnsOwner' for the SES identity, DKIM, and inbound
-- records, and the reason is that an owner decides two things a shared owner
-- would decide wrongly. It decides the lifecycle class, and the SES records
-- live in the operator's long-lived parent zone while the provider lane's
-- records are per-run. It also decides the admissible record types, so folding
-- SES into the provider lane would hand the public A-record writer TXT, CNAME,
-- and MX authority over the same zone.
data DnsRecordOwner
  = HomeGatewayDnsOwner
  | AwsLifecycleProviderDnsOwner
  | AwsSesDnsOwner
  | HomeCertManagerDns01Owner
  | AwsCertManagerDns01Owner
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Evidence that the running process holds a DNS ownership.
--
-- Deliberately not a second copy of a coordinate's owner: a comparison between
-- two caller-supplied owners proves the caller is self-consistent, not that it
-- is entitled to act.  Provenance and Direction classes,
-- @chaos_hardening_doctrine.md § 21@.
newtype DnsOwnerAuthority = DnsOwnerAuthority DnsRecordOwner
  deriving stock (Eq, Show)
