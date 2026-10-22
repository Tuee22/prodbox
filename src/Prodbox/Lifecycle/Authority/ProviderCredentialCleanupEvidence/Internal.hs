-- | Private transient proof of an exact expired parent and its bounded child.
module Prodbox.Lifecycle.Authority.ProviderCredentialCleanupEvidence.Internal
  ( ObservedProviderCredentialCleanup (..)
  , observedCredentialCleanupParent
  , observedCredentialCleanupReservation
  , observedCredentialCleanupPermitDigest
  ) where

import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderCredentialLineageArchive
  , ProviderCredentialMutationReservation
  )
import Prodbox.Lifecycle.CleanupRun (CleanupDigest)

data ObservedProviderCredentialCleanup
  = ObservedProviderCredentialCleanup
      !ProviderCredentialLineageArchive
      !ProviderCredentialMutationReservation
      !CleanupDigest

observedCredentialCleanupParent
  :: ObservedProviderCredentialCleanup -> ProviderCredentialLineageArchive
observedCredentialCleanupParent (ObservedProviderCredentialCleanup parent _ _) = parent

observedCredentialCleanupReservation
  :: ObservedProviderCredentialCleanup -> ProviderCredentialMutationReservation
observedCredentialCleanupReservation (ObservedProviderCredentialCleanup _ child _) = child

observedCredentialCleanupPermitDigest :: ObservedProviderCredentialCleanup -> CleanupDigest
observedCredentialCleanupPermitDigest (ObservedProviderCredentialCleanup _ _ digest) = digest
