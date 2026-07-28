module Prodbox.Capacity.Derivation
  ( DerivedResourceEnvelope
  , DerivationError (..)
  , deriveResourceEnvelope
  , derivedResourceEnvelope
  )
where

import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Capacity.Types

data DerivationError
  = EmptyCalibrationProfile
  | ZeroRequestsPerSecond
  | ZeroServiceCpuMicros
  | EmptyMemoryDemand
  | EmptyEphemeralDemand
  deriving (Eq, Show)

newtype DerivedResourceEnvelope = DerivedResourceEnvelope ResourceEnvelope
  deriving (Eq, Show)

derivedResourceEnvelope :: DerivedResourceEnvelope -> ResourceEnvelope
derivedResourceEnvelope (DerivedResourceEnvelope envelope) = envelope

deriveResourceEnvelope :: WorkloadDemandSpec -> Either DerivationError DerivedResourceEnvelope
deriveResourceEnvelope spec = do
  let cpu = cpu_demand spec
      memory = memory_demand spec
      ephemeral = ephemeral_demand spec
  if nullText (calibration_profile_id cpu) then Left EmptyCalibrationProfile else Right ()
  if requests_per_second cpu == 0 then Left ZeroRequestsPerSecond else Right ()
  if service_cpu_micros cpu == 0 then Left ZeroServiceCpuMicros else Right ()
  if null (steady_memory_terms_mib memory) then Left EmptyMemoryDemand else Right ()
  if null (ephemeral_terms_mib ephemeral) then Left EmptyEphemeralDemand else Right ()
  let requested =
        ResourceVector
          { milli_cpu = derivedCpuRequest cpu
          , memory_mib = sumNaturals (steady_memory_terms_mib memory)
          , ephemeral_storage_mib = sumNaturals (ephemeral_terms_mib ephemeral)
          , durable_storage_mib = demanded_durable_storage_mib spec
          }
      burstLimit =
        requested
          { milli_cpu = milli_cpu requested + bounded_cpu_burst_milli cpu
          , memory_mib = memory_mib requested + bounded_memory_burst_mib memory
          , ephemeral_storage_mib =
              ephemeral_storage_mib requested + bounded_ephemeral_burst_mib ephemeral
          }
      limited =
        case demand_qos spec of
          Guaranteed -> requested
          Burstable -> burstLimit
  pure (DerivedResourceEnvelope (ResourceEnvelope requested limited))

derivedCpuRequest :: CpuDemandSpec -> Natural
derivedCpuRequest cpu =
  ceilingDivide
    ( requests_per_second cpu
        * service_cpu_micros cpu
        * (1_000_000 + cpu_headroom_ppm cpu)
    )
    1_000_000_000

ceilingDivide :: Natural -> Natural -> Natural
ceilingDivide numerator denominator =
  (numerator + denominator - 1) `div` denominator

sumNaturals :: [Natural] -> Natural
sumNaturals = foldl' (+) 0

nullText :: Text.Text -> Bool
nullText = Text.null . Text.strip
