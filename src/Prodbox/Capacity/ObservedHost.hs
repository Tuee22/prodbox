{-# LANGUAGE DerivingStrategies #-}

-- | Observed host capacity with explicit identities for the kubelet and
-- retained-PV storage devices.
module Prodbox.Capacity.ObservedHost
  ( StorageDeviceId
  , mkStorageDeviceId
  , storageDeviceIdText
  , ObservedHostRoot
  , mkObservedHostRoot
  , observedHostVector
  , observedEphemeralDevice
  , observedDurableDevice
  , observedStorageDevicesCoincide
  )
where

import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Capacity.Config (ResourceVector (..))

newtype StorageDeviceId = StorageDeviceId Text
  deriving stock (Eq, Ord, Show)

mkStorageDeviceId :: Text -> Maybe StorageDeviceId
mkStorageDeviceId value
  | Text.null stripped = Nothing
  | Text.length stripped > 512 = Nothing
  | Text.any isControl stripped = Nothing
  | otherwise = Just (StorageDeviceId stripped)
 where
  stripped = Text.strip value

storageDeviceIdText :: StorageDeviceId -> Text
storageDeviceIdText (StorageDeviceId value) = value

data ObservedHostRoot = ObservedHostRoot
  { observedHostVector_ :: !ResourceVector
  , observedEphemeralDevice_ :: !StorageDeviceId
  , observedDurableDevice_ :: !StorageDeviceId
  }
  deriving stock (Eq, Show)

mkObservedHostRoot
  :: ResourceVector
  -> StorageDeviceId
  -> StorageDeviceId
  -> Either String ObservedHostRoot
mkObservedHostRoot vector ephemeralDevice durableDevice
  | milli_cpu vector == 0 = Left "observed host milli_cpu must be positive"
  | memory_mib vector == 0 = Left "observed host memory_mib must be positive"
  | ephemeral_storage_mib vector == 0 =
      Left "observed host ephemeral_storage_mib must be positive"
  | durable_storage_mib vector == 0 =
      Left "observed host durable_storage_mib must be positive"
  | otherwise =
      Right
        ObservedHostRoot
          { observedHostVector_ = vector
          , observedEphemeralDevice_ = ephemeralDevice
          , observedDurableDevice_ = durableDevice
          }

observedHostVector :: ObservedHostRoot -> ResourceVector
observedHostVector = observedHostVector_

observedEphemeralDevice :: ObservedHostRoot -> StorageDeviceId
observedEphemeralDevice = observedEphemeralDevice_

observedDurableDevice :: ObservedHostRoot -> StorageDeviceId
observedDurableDevice = observedDurableDevice_

observedStorageDevicesCoincide :: ObservedHostRoot -> Bool
observedStorageDevicesCoincide observed =
  observedEphemeralDevice_ observed == observedDurableDevice_ observed
