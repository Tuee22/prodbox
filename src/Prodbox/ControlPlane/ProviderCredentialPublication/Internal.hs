{-# LANGUAGE OverloadedStrings #-}

-- | Package-private actual publication observer. A public library caller
-- cannot supply a repository callback to manufacture this proof.
module Prodbox.ControlPlane.ProviderCredentialPublication.Internal
  ( ObservedAwsAdminProviderLineage
  , observedAwsAdminProviderLineageArchive
  , observedAwsAdminProviderLineagePermit
  , observedAwsAdminProviderLineageReceipt
  , publishAwsAdminProviderLineage
  ) where

import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch (ProviderCredentialLineageArchive)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorityRepository (..)
  , AwsAdminAuthorityRepositoryError (..)
  , AwsAdminAuthoritySnapshot (..)
  , AwsAdminAuthorityState (..)
  , commitAwsAdminProviderLineage
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution (AwsAdminWorkerReceipt)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit (SignedAwsAdminPermit)

data ObservedAwsAdminProviderLineage
  = ObservedAwsAdminProviderLineage
      !ProviderCredentialLineageArchive
      !SignedAwsAdminPermit
      !AwsAdminWorkerReceipt

observedAwsAdminProviderLineageArchive
  :: ObservedAwsAdminProviderLineage -> ProviderCredentialLineageArchive
observedAwsAdminProviderLineageArchive (ObservedAwsAdminProviderLineage archive _ _) = archive

observedAwsAdminProviderLineagePermit :: ObservedAwsAdminProviderLineage -> SignedAwsAdminPermit
observedAwsAdminProviderLineagePermit (ObservedAwsAdminProviderLineage _ permit _) = permit

observedAwsAdminProviderLineageReceipt :: ObservedAwsAdminProviderLineage -> AwsAdminWorkerReceipt
observedAwsAdminProviderLineageReceipt (ObservedAwsAdminProviderLineage _ _ receipt) = receipt

publishAwsAdminProviderLineage
  :: (Monad m)
  => AwsAdminAuthorityRepository m revision
  -> ProviderCredentialLineageArchive
  -> m (Either AwsAdminAuthorityRepositoryError ObservedAwsAdminProviderLineage)
publishAwsAdminProviderLineage repository archive = do
  initial <- readAwsAdminAuthority repository
  case initial of
    Left detail -> pure (Left (AwsAdminAuthorityRepositoryUnavailable detail))
    Right snapshot -> case commitAwsAdminProviderLineage archive (awsAdminAuthoritySnapshotState snapshot) of
      Left cause -> pure (Left (AwsAdminAuthorityRepositoryStateRejected cause))
      Right expected -> do
        confirmed <- commitAndRead snapshot expected
        case confirmed of
          Left cause -> pure (Left cause)
          Right () -> do
            independent <- readAwsAdminAuthority repository
            pure $ case independent of
              Left detail -> Left (AwsAdminAuthorityRepositoryUnavailable detail)
              Right final -> case awsAdminAuthoritySnapshotState final of
                AwsAdminAuthorityCompletedWithLineage permit receipt observed
                  | awsAdminAuthoritySnapshotState final == expected && observed == archive ->
                      Right (ObservedAwsAdminProviderLineage observed permit receipt)
                _ -> Left (AwsAdminAuthorityRepositoryCommitFailed "independent provider lineage read did not match")
 where
  commitAndRead snapshot expected
    | awsAdminAuthoritySnapshotState snapshot == expected = pure (Right ())
    | otherwise = do
        _ <- compareAndSwapAwsAdminAuthority repository (awsAdminAuthorityRevision snapshot) expected
        readback <- readAwsAdminAuthority repository
        pure $ case readback of
          Left detail -> Left (AwsAdminAuthorityRepositoryUnavailable detail)
          Right observed
            | awsAdminAuthoritySnapshotState observed == expected -> Right ()
            | otherwise ->
                Left
                  (AwsAdminAuthorityRepositoryCommitFailed "provider lineage CAS was not independently confirmed")
