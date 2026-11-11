{-# LANGUAGE DeriveGeneric #-}

-- The single typed owner of the unchanged settings/context wire envelope.
module Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope (..)) where

import Dhall qualified
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Capacity.SettingsExtractedData (RawData)
import Prodbox.Settings qualified as Settings

data SettingsEnvelope = SettingsEnvelope
  { schema_version :: Natural
  , context :: Settings.DeploymentContextInput
  , parameters :: Settings.ConfigFile
  }
  deriving (Generic)
instance Dhall.FromDhall SettingsEnvelope
instance Dhall.ToDhall SettingsEnvelope
instance RawData SettingsEnvelope
