{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.36: storage-specific capacity planning on top of the shared
-- finite 'CapacityBudget' algebra from Sprint 1.51.
module Prodbox.Capacity.Storage
  ( AwsRegionQuotaObservation (..)
  , DurableStoreCapacity (..)
  , DurableStoreClaim (..)
  , DurableStoreCapacityRequest (..)
  , MlCacheBudget (..)
  , MlEngineStorageBudget (..)
  , RegionQuotaShortfall (..)
  , ScalingPolicyWitness
  , StorageCapacityPlan (..)
  , StorageCapacityRefusal (..)
  , durableStoreCapacityConstructors
  , durableStoreDraw
  , mlCacheTotal
  , mlEngineStorageTotal
  , regionQuotaPreflight
  , scalingPolicyWitness
  , storageCapacityPlanDraw
  , validateDurableStoreCapacityRequest
  , validateStorageCapacityPlan
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Capacity.Config
  ( CapacityBudget (..)
  , fitsWithin
  , plusBudget
  )

newtype ScalingPolicyWitness = ScalingPolicyWitness Text
  deriving (Eq, Show)

scalingPolicyWitness :: Text -> Either StorageCapacityRefusal ScalingPolicyWitness
scalingPolicyWitness raw
  | Text.null (Text.strip raw) = Left (StorageInvalidScalingWitness raw)
  | otherwise = Right (ScalingPolicyWitness raw)

data DurableStoreCapacity
  = DurableStoreBounded CapacityBudget
  | DurableStoreAutoscaled ScalingPolicyWitness
  deriving (Eq, Show)

data DurableStoreCapacityRequest
  = DurableStoreCapacityRequestBounded CapacityBudget
  | DurableStoreCapacityRequestAutoscaled (Maybe ScalingPolicyWitness)
  deriving (Eq, Show)

data DurableStoreClaim = DurableStoreClaim
  { durableStoreName :: Text
  , durableStoreBudget :: CapacityBudget
  , durableStoreCapacity :: DurableStoreCapacity
  }
  deriving (Eq, Show)

data MlCacheBudget = MlCacheBudget
  { mlJitArtifactCacheBudget :: CapacityBudget
  , mlModelCacheBudget :: CapacityBudget
  }
  deriving (Eq, Show)

data MlEngineStorageBudget = MlEngineStorageBudget
  { mlEngineName :: Text
  , mlHostBudget :: MlCacheBudget
  , mlClusterBudget :: MlCacheBudget
  }
  deriving (Eq, Show)

data StorageCapacityPlan = StorageCapacityPlan
  { storageCapacityBudget :: CapacityBudget
  , storageCapacityStores :: [DurableStoreClaim]
  , storageCapacityMlEngines :: [MlEngineStorageBudget]
  }
  deriving (Eq, Show)

data AwsRegionQuotaObservation = AwsRegionQuotaObservation
  { regionQuotaName :: Text
  , regionQuotaCurrentValue :: Double
  , regionQuotaTargetValue :: Double
  , regionQuotaMeetsTarget :: Bool
  }
  deriving (Eq, Show)

data RegionQuotaShortfall = RegionQuotaShortfall
  { regionQuotaShortfallName :: Text
  , regionQuotaShortfallCurrentValue :: Double
  , regionQuotaShortfallTargetValue :: Double
  }
  deriving (Eq, Show)

data StorageCapacityRefusal
  = StorageInvalidScalingWitness Text
  | StorageAutoscaledSinkMissingWitness Text
  | StorageCapacityBudgetExceeded CapacityBudget CapacityBudget
  | StorageRegionQuotaShortfall [RegionQuotaShortfall]
  deriving (Eq, Show)

durableStoreCapacityConstructors :: [Text]
durableStoreCapacityConstructors =
  [ "Bounded"
  , "Autoscaled"
  ]

validateDurableStoreCapacityRequest
  :: Text
  -> DurableStoreCapacityRequest
  -> Either StorageCapacityRefusal DurableStoreCapacity
validateDurableStoreCapacityRequest storeName request =
  case request of
    DurableStoreCapacityRequestBounded budget ->
      Right (DurableStoreBounded budget)
    DurableStoreCapacityRequestAutoscaled maybeWitness ->
      case maybeWitness of
        Nothing -> Left (StorageAutoscaledSinkMissingWitness storeName)
        Just witness -> Right (DurableStoreAutoscaled witness)

durableStoreDraw :: DurableStoreClaim -> CapacityBudget
durableStoreDraw =
  durableStoreBudget

mlCacheTotal :: MlCacheBudget -> CapacityBudget
mlCacheTotal budget =
  mlJitArtifactCacheBudget budget `plusBudget` mlModelCacheBudget budget

mlEngineStorageTotal :: MlEngineStorageBudget -> CapacityBudget
mlEngineStorageTotal budget =
  mlCacheTotal (mlHostBudget budget) `plusBudget` mlCacheTotal (mlClusterBudget budget)

storageCapacityPlanDraw :: StorageCapacityPlan -> CapacityBudget
storageCapacityPlanDraw plan =
  foldl'
    plusBudget
    zeroBudget
    ( map durableStoreDraw (storageCapacityStores plan)
        ++ map mlEngineStorageTotal (storageCapacityMlEngines plan)
    )

validateStorageCapacityPlan :: StorageCapacityPlan -> Either StorageCapacityRefusal ()
validateStorageCapacityPlan plan =
  let draw = storageCapacityPlanDraw plan
   in if draw `fitsWithin` storageCapacityBudget plan
        then Right ()
        else Left (StorageCapacityBudgetExceeded draw (storageCapacityBudget plan))

regionQuotaPreflight :: [AwsRegionQuotaObservation] -> Either StorageCapacityRefusal ()
regionQuotaPreflight observations =
  case map observationShortfall (filter (not . regionQuotaMeetsTarget) observations) of
    [] -> Right ()
    shortfalls -> Left (StorageRegionQuotaShortfall shortfalls)

observationShortfall :: AwsRegionQuotaObservation -> RegionQuotaShortfall
observationShortfall observation =
  RegionQuotaShortfall
    { regionQuotaShortfallName = regionQuotaName observation
    , regionQuotaShortfallCurrentValue = regionQuotaCurrentValue observation
    , regionQuotaShortfallTargetValue = regionQuotaTargetValue observation
    }

zeroBudget :: CapacityBudget
zeroBudget = CapacityBudget 0 0 0
