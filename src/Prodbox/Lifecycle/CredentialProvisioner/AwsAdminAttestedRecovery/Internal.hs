-- | Private transient evidence from the actual Kubernetes observer.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAttestedRecovery.Internal
  ( AwsAdminAttestedRecoveryProof (..)
  ) where

import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)

data AwsAdminAttestedRecoveryProof
  = AwsAdminAttestedRecoveryProof !AuthorityTime !AwsAdminPermitIntent !AwsAdminJobBinding
  deriving (Eq, Show)
