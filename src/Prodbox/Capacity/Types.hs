{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Prodbox.Capacity.Types
  ( ResourceVector (..)
  , ResourceEnvelope (..)
  , WorkloadQoS (..)
  , CpuDemandSpec (..)
  , MemoryDemandSpec (..)
  , EphemeralDemandSpec (..)
  , WorkloadDemandSpec (..)
  )
where

import Data.Text (Text)
import Dhall (FromDhall, ToDhall)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data ResourceVector = ResourceVector
  { milli_cpu :: Natural
  , memory_mib :: Natural
  , ephemeral_storage_mib :: Natural
  , durable_storage_mib :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data ResourceEnvelope = ResourceEnvelope
  { request :: ResourceVector
  , limit :: ResourceVector
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data WorkloadQoS = Guaranteed | Burstable
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Pure CPU demand contract. At the reference calibration,
-- @requests_per_second * service_cpu_micros@ is the steady CPU demand. The
-- headroom ratio is parts-per-million above that demand; the bounded burst is a
-- containment allowance above the derived request.
data CpuDemandSpec = CpuDemandSpec
  { requests_per_second :: Natural
  , service_cpu_micros :: Natural
  , cpu_headroom_ppm :: Natural
  , bounded_cpu_burst_milli :: Natural
  , calibration_profile_id :: Text
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Structural memory terms. The request is the sum of terms required during
-- steady service; the bounded burst is explicit runtime/native headroom.
data MemoryDemandSpec = MemoryDemandSpec
  { steady_memory_terms_mib :: [Natural]
  , bounded_memory_burst_mib :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

-- | Structural writable-layer, scratch, and bounded-log terms.
data EphemeralDemandSpec = EphemeralDemandSpec
  { ephemeral_terms_mib :: [Natural]
  , bounded_ephemeral_burst_mib :: Natural
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

data WorkloadDemandSpec = WorkloadDemandSpec
  { cpu_demand :: CpuDemandSpec
  , memory_demand :: MemoryDemandSpec
  , ephemeral_demand :: EphemeralDemandSpec
  , demanded_durable_storage_mib :: Natural
  , demand_qos :: WorkloadQoS
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)
