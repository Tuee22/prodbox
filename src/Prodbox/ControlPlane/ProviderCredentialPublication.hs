-- | Read-only publication proof. Repository construction and the actual
-- positive read-back producer remain package-private.
module Prodbox.ControlPlane.ProviderCredentialPublication
  ( ObservedAwsAdminProviderLineage
  , observedAwsAdminProviderLineageArchive
  , observedAwsAdminProviderLineagePermit
  , observedAwsAdminProviderLineageReceipt
  ) where

import Prodbox.ControlPlane.ProviderCredentialPublication.Internal
