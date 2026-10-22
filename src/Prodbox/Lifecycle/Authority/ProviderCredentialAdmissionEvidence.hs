-- | Read-only view of the server-owned publication and fresh-Agent proof.
-- There is no constructor, serializer or wire decoder at this boundary.
module Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence
  ( ObservedProviderCredentialAdmission
  , ProviderCredentialAdmissionKind (..)
  , observedProviderCredentialAdmissionArchive
  , observedProviderCredentialAdmissionKind
  ) where

import Prodbox.Lifecycle.Authority.ProviderCredentialAdmissionEvidence.Internal
