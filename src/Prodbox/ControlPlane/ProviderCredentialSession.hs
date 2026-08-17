-- | Read-only facade for one exact Provider operational-credential session.
-- Constructors, raw Vault observations, metadata parsing, and wire restoration
-- remain package-private.
module Prodbox.ControlPlane.ProviderCredentialSession
  ( ProviderCredentialSessionBinding
  , providerCredentialSessionGeneration
  , providerCredentialSessionVaultVersion
  , providerCredentialSessionReceiptDigest
  , ProviderAcceptedAuthorityDigest
  , providerAcceptedAuthorityDigestText
  , ProviderCredentialSessionError (..)
  , ProviderCredentialSessionRegression
  , fixedProviderCredentialSessionRegression
  , providerCredentialSessionRegressionExactJoinAccepted
  , providerCredentialSessionRegressionMetadataRaceRefused
  , providerCredentialSessionRegressionLegacyMetadataRefused
  , providerCredentialSessionRegressionLegacyMetadataReadinessAccepted
  , providerCredentialSessionRegressionWrongExactVersionRefused
  , providerCredentialSessionRegressionDestroyedVersionRefused
  , providerCredentialSessionRegressionMissingDataRefused
  , providerCredentialSessionRegressionExtraSecretFieldRefused
  , providerCredentialSessionRegressionBindingSecretOpaque
  , providerCredentialSessionRegressionErrorSecretOpaque
  )
where

import Prodbox.ControlPlane.ProviderCredentialSession.Internal
  ( ProviderAcceptedAuthorityDigest
  , ProviderCredentialSessionBinding
  , ProviderCredentialSessionError (..)
  , ProviderCredentialSessionRegression
  , fixedProviderCredentialSessionRegression
  , providerAcceptedAuthorityDigestText
  , providerCredentialSessionGeneration
  , providerCredentialSessionReceiptDigest
  , providerCredentialSessionRegressionBindingSecretOpaque
  , providerCredentialSessionRegressionDestroyedVersionRefused
  , providerCredentialSessionRegressionErrorSecretOpaque
  , providerCredentialSessionRegressionExactJoinAccepted
  , providerCredentialSessionRegressionExtraSecretFieldRefused
  , providerCredentialSessionRegressionLegacyMetadataReadinessAccepted
  , providerCredentialSessionRegressionLegacyMetadataRefused
  , providerCredentialSessionRegressionMetadataRaceRefused
  , providerCredentialSessionRegressionMissingDataRefused
  , providerCredentialSessionRegressionWrongExactVersionRefused
  , providerCredentialSessionVaultVersion
  )
