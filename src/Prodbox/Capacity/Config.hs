{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.Config
  ( CapacityBudget (..)
  , CapacitySection (..)
  , defaultCapacitySection
  , fitsWithin
  , storageFitsWithin
  , plusBudget
  , validateCapacitySection
  )
where

import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall
  ( FromDhall (..)
  , InterpretOptions (..)
  , ToDhall (..)
  , defaultInterpretOptions
  , genericAutoWith
  , genericToDhallWith
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data CapacityBudget = CapacityBudget
  { budgetCpu :: Natural
  , budgetMemory :: Natural
  , budgetStorage :: Natural
  }
  deriving (Eq, Show, Generic)

instance FromDhall CapacityBudget where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = stripBudgetPrefix}

instance ToDhall CapacityBudget where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = stripBudgetPrefix}

stripBudgetPrefix :: Text -> Text
stripBudgetPrefix value =
  case Text.stripPrefix "budget" value of
    Just stripped -> lowerFirst stripped
    Nothing -> value

data CapacitySection = CapacitySection
  { node_budget :: CapacityBudget
  , workload_budget :: CapacityBudget
  , region_quota :: CapacityBudget
  }
  deriving (Eq, Show, Generic, FromDhall, ToDhall)

defaultCapacitySection :: CapacitySection
defaultCapacitySection =
  CapacitySection
    { node_budget = CapacityBudget 8 16 100
    , workload_budget = CapacityBudget 4 8 40
    , region_quota = CapacityBudget 32 64 500
    }

fitsWithin :: CapacityBudget -> CapacityBudget -> Bool
fitsWithin inner outer =
  budgetCpu inner <= budgetCpu outer
    && budgetMemory inner <= budgetMemory outer
    && budgetStorage inner <= budgetStorage outer

storageFitsWithin :: CapacityBudget -> CapacityBudget -> Bool
storageFitsWithin inner outer =
  budgetStorage inner <= budgetStorage outer

plusBudget :: CapacityBudget -> CapacityBudget -> CapacityBudget
plusBudget left right =
  CapacityBudget
    { budgetCpu = budgetCpu left + budgetCpu right
    , budgetMemory = budgetMemory left + budgetMemory right
    , budgetStorage = budgetStorage left + budgetStorage right
    }

validateCapacitySection :: CapacitySection -> Either String ()
validateCapacitySection section = do
  unlessFits
    "capacity.workload_budget must fit within capacity.node_budget"
    (workload_budget section)
    (node_budget section)
  unlessFits
    "capacity.node_budget must fit within capacity.region_quota"
    (node_budget section)
    (region_quota section)

unlessFits :: String -> CapacityBudget -> CapacityBudget -> Either String ()
unlessFits message inner outer =
  if fitsWithin inner outer
    then Right ()
    else Left message

lowerFirst :: Text -> Text
lowerFirst value =
  case Text.uncons value of
    Just (firstChar, rest) -> Text.cons (Char.toLower firstChar) rest
    Nothing -> value
