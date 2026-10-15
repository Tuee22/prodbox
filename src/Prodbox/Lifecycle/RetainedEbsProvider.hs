{-# LANGUAGE OverloadedStrings #-}

-- | The host half of the retained-EBS ensure.
--
-- The host holds no AWS credential, so the retained volumes the AWS substrate's
-- PersistentVolumes bind to are created by the Provider Worker under its
-- assumed-role session. The host names the required volumes, the Provider
-- creates what is missing and reads every volume back, and the evidence is one
-- line of bindings the host splits into the same 'StaticEbsVolumeBinding'
-- values the manifest renderers already consume.
module Prodbox.Lifecycle.RetainedEbsProvider
  ( ensureRetainedEbsVolumesThroughProvider
  , retainedEbsEnsureIntent
  , parseRetainedEbsBindingsEvidence
  )
where

import Data.Bifunctor (first)
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchHostProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Lib.Storage (StaticEbsVolumeBinding (..))
import Prodbox.Lifecycle.EbsVolume (EbsRequiredVolume (..))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (EnsureRetainedEbsVolumes)
  )
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsEbsVolumeType
  , awsEbsVolumeTypeText
  )

-- | Ensure the required retained volumes through the Provider and return one
-- binding per required volume, in the order required.
ensureRetainedEbsVolumesThroughProvider
  :: FilePath
  -> AwsEbsVolumeType
  -> [EbsRequiredVolume]
  -> IO (Either String [StaticEbsVolumeBinding])
ensureRetainedEbsVolumesThroughProvider repoRoot volumeType required = do
  dispatched <-
    dispatchHostProviderIntentFresh
      LifecycleAuthorityOperator
      repoRoot
      "aws-retained-ebs-ensure"
      (retainedEbsEnsureIntent volumeType required)
  pure $ do
    evidence <- first renderProviderCallerError dispatched
    bindings <- parseRetainedEbsBindingsEvidence evidence
    if map staticEbsVolumeBindingPersistentVolumeName bindings
      == map ebsRequiredPersistentVolumeName required
      then Right bindings
      else Left "the Provider's retained EBS bindings do not name the required volumes in order"

-- | The intent for a set of required volumes: the volume type, and the volumes
-- as @name:size-gib:zone@ entries joined by commas.
retainedEbsEnsureIntent :: AwsEbsVolumeType -> [EbsRequiredVolume] -> ProviderIntent
retainedEbsEnsureIntent volumeType required =
  EnsureRetainedEbsVolumes
    (awsEbsVolumeTypeText volumeType)
    (Text.intercalate "," (map entry required))
 where
  entry volume =
    Text.pack
      ( intercalate
          ":"
          [ ebsRequiredPersistentVolumeName volume
          , show (ebsRequiredSizeGiB volume)
          , ebsRequiredAvailabilityZone volume
          ]
      )

-- | Split @retained-ebs-bindings:name=volume=zone,...@ back into bindings.
parseRetainedEbsBindingsEvidence :: Text -> Either String [StaticEbsVolumeBinding]
parseRetainedEbsBindingsEvidence evidence =
  case Text.stripPrefix "retained-ebs-bindings:" evidence of
    Nothing -> Left ("unexpected retained EBS evidence: " ++ Text.unpack evidence)
    Just body
      | Text.null body -> Left "the Provider returned no retained EBS bindings"
      | otherwise -> traverse parseEntry (Text.splitOn "," body)
 where
  parseEntry entry = case Text.splitOn "=" entry of
    [name, volumeId, zone]
      | not (Text.null name) && not (Text.null volumeId) && not (Text.null zone) ->
          Right
            StaticEbsVolumeBinding
              { staticEbsVolumeBindingPersistentVolumeName = Text.unpack name
              , staticEbsVolumeBindingVolumeHandle = Text.unpack volumeId
              , staticEbsVolumeBindingAvailabilityZone = Text.unpack zone
              }
    _ -> Left ("malformed retained EBS binding: " ++ Text.unpack entry)
