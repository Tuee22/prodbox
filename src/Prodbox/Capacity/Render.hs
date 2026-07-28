{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.Render
  ( cpuQuantity
  , memoryQuantity
  , resourceVectorRuntimeValue
  , resourceQuotaSpec
  , resourceQuotaEnvelopeSpec
  , limitRangeValue
  , renderResourceVectorRuntime
  )
where

import Data.Aeson (Value, object, (.=))
import Data.List (intercalate)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config
  ( ResourceEnvelope (..)
  , ResourceVector (..)
  )

cpuQuantity :: Natural -> String
cpuQuantity value = show value ++ "m"

memoryQuantity :: Natural -> String
memoryQuantity value = show value ++ "Mi"

resourceVectorRuntimeValue :: ResourceVector -> Value
resourceVectorRuntimeValue vector =
  object
    [ "cpu" .= cpuQuantity (milli_cpu vector)
    , "memory" .= memoryQuantity (memory_mib vector)
    , "ephemeral-storage" .= memoryQuantity (ephemeral_storage_mib vector)
    ]

resourceQuotaSpec :: ResourceVector -> Value
resourceQuotaSpec vector =
  object ["hard" .= resourceQuotaHard vector]

resourceQuotaEnvelopeSpec :: ResourceEnvelope -> Value
resourceQuotaEnvelopeSpec envelope =
  object
    [ "hard"
        .= object
          [ "requests.cpu" .= cpuQuantity (milli_cpu (request envelope))
          , "limits.cpu" .= cpuQuantity (milli_cpu (limit envelope))
          , "requests.memory" .= memoryQuantity (memory_mib (request envelope))
          , "limits.memory" .= memoryQuantity (memory_mib (limit envelope))
          , "requests.ephemeral-storage"
              .= memoryQuantity (ephemeral_storage_mib (request envelope))
          , "limits.ephemeral-storage"
              .= memoryQuantity (ephemeral_storage_mib (limit envelope))
          , "requests.storage" .= memoryQuantity (durable_storage_mib (request envelope))
          ]
    ]

resourceQuotaHard :: ResourceVector -> Value
resourceQuotaHard vector =
  object
    [ "requests.cpu" .= cpuQuantity (milli_cpu vector)
    , "limits.cpu" .= cpuQuantity (milli_cpu vector)
    , "requests.memory" .= memoryQuantity (memory_mib vector)
    , "limits.memory" .= memoryQuantity (memory_mib vector)
    , "requests.ephemeral-storage" .= memoryQuantity (ephemeral_storage_mib vector)
    , "limits.ephemeral-storage" .= memoryQuantity (ephemeral_storage_mib vector)
    , "requests.storage" .= memoryQuantity (durable_storage_mib vector)
    ]

limitRangeValue :: ResourceEnvelope -> Value
limitRangeValue envelope =
  object
    [ "defaultRequest" .= resourceVectorRuntimeValue (request envelope)
    , "default" .= resourceVectorRuntimeValue (limit envelope)
    ]

renderResourceVectorRuntime :: ResourceVector -> String
renderResourceVectorRuntime vector =
  intercalate
    ","
    [ "cpu=" ++ cpuQuantity (milli_cpu vector)
    , "memory=" ++ memoryQuantity (memory_mib vector)
    , "ephemeral-storage=" ++ memoryQuantity (ephemeral_storage_mib vector)
    , "durable-storage=" ++ memoryQuantity (durable_storage_mib vector)
    ]
