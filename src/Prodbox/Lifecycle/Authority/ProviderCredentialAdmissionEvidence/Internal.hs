-- | Private transient proof representation. Only the actual control-plane
-- publication/Agent observer and its public read-only facade may import this
-- module. Positional fields prevent record-update fabrication.
module Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence.Internal
  ( ObservedProviderCredentialAdmission (..)
  , ProviderCredentialAdmissionKind (..)
  , observedProviderCredentialAdmissionArchive
  , observedProviderCredentialAdmissionKind
  ) where

import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderCredentialLineageArchive
  , ProviderCredentialRevocationReceipt
  )

data ProviderCredentialAdmissionKind
  = ProviderCredentialAdmissionInstalled
  | ProviderCredentialAdmissionRevoked !ProviderCredentialRevocationReceipt
  deriving (Eq, Show)

data ObservedProviderCredentialAdmission
  = ObservedProviderCredentialAdmission
      !ProviderCredentialLineageArchive
      !ProviderCredentialAdmissionKind

observedProviderCredentialAdmissionArchive
  :: ObservedProviderCredentialAdmission -> ProviderCredentialLineageArchive
observedProviderCredentialAdmissionArchive (ObservedProviderCredentialAdmission archive _) = archive

observedProviderCredentialAdmissionKind
  :: ObservedProviderCredentialAdmission -> ProviderCredentialAdmissionKind
observedProviderCredentialAdmissionKind (ObservedProviderCredentialAdmission _ kind) = kind
