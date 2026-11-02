{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared closed refusal vocabulary. Constructor order preserves the retained
-- aggregate's established wire tags; observations do not grant a permit.
module Prodbox.Lifecycle.Authority.AdmissionGate
  ( AuthoritySubmissionGateRefusal (..)
  , authoritySubmissionGateRefusalToken
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)

data AuthoritySubmissionGateRefusal
  = AuthorityGenesisFrozen
  | AuthorityGenesisEstablishing
  | AuthorityBackupRepairFrozen
  | AuthorityDecommissionAdmissionFrozen
  | AuthorityDecommissionPermanentlyStopped
  | AuthorityLegacyWriterActive
  | AuthorityMigrationWritersQuiesced
  | AuthorityProviderAdmissionCascadeFrozen
  | AuthorityProviderAdmissionCredentialRevoked
  | AuthorityProviderAdmissionCredentialMutationPending
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authoritySubmissionGateRefusalToken :: AuthoritySubmissionGateRefusal -> Text
authoritySubmissionGateRefusalToken refusal = case refusal of
  AuthorityGenesisFrozen -> "genesis-frozen"
  AuthorityGenesisEstablishing -> "genesis-establishing"
  AuthorityBackupRepairFrozen -> "backup-repair-frozen"
  AuthorityDecommissionAdmissionFrozen -> "decommission-frozen"
  AuthorityDecommissionPermanentlyStopped -> "permanently-stopped"
  AuthorityLegacyWriterActive -> "legacy-writer-active"
  AuthorityMigrationWritersQuiesced -> "migration-writers-quiesced"
  AuthorityProviderAdmissionCascadeFrozen -> "provider-cascade-frozen"
  AuthorityProviderAdmissionCredentialRevoked -> "provider-credential-revoked"
  AuthorityProviderAdmissionCredentialMutationPending -> "provider-credential-mutation-pending"
