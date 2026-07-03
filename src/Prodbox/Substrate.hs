{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Substrate
  ( Substrate (..)
  , ElasticScalingBounds (..)
  , ScalingPolicy (..)
  , ScalingPolicyBySubstrate (..)
  , fixedScalingPolicyBySubstrate
  , replicasForSubstrate
  , scalingPolicyForSubstrate
  , substrateId
  , parseSubstrate
  , defaultSubstrate
  , allSubstrates
  , validateScalingPolicyBySubstrate
  )
where

import Data.Char qualified as Char
import Data.Maybe (fromMaybe)
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

data Substrate
  = SubstrateHomeLocal
  | SubstrateAws
  deriving (Eq, Show)

data ElasticScalingBounds = ElasticScalingBounds
  { elasticMin :: Natural
  , elasticMax :: Natural
  }
  deriving (Eq, Show, Generic)

instance FromDhall ElasticScalingBounds where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = stripPrefixLowerFirst "elastic"}

instance ToDhall ElasticScalingBounds where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = stripPrefixLowerFirst "elastic"}

data ScalingPolicy
  = ScalingPolicyFixed Natural
  | ScalingPolicyElastic ElasticScalingBounds
  deriving (Eq, Show, Generic)

instance FromDhall ScalingPolicy where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {constructorModifier = stripPrefix "ScalingPolicy"}

instance ToDhall ScalingPolicy where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {constructorModifier = stripPrefix "ScalingPolicy"}

data ScalingPolicyBySubstrate = ScalingPolicyBySubstrate
  { scalingHomeLocal :: ScalingPolicy
  , scalingAws :: ScalingPolicy
  }
  deriving (Eq, Show, Generic)

instance FromDhall ScalingPolicyBySubstrate where
  autoWith _ =
    genericAutoWith
      defaultInterpretOptions {fieldModifier = scalingPolicyBySubstrateField}

instance ToDhall ScalingPolicyBySubstrate where
  injectWith _ =
    genericToDhallWith
      defaultInterpretOptions {fieldModifier = scalingPolicyBySubstrateField}

fixedScalingPolicyBySubstrate :: Natural -> ScalingPolicyBySubstrate
fixedScalingPolicyBySubstrate count =
  ScalingPolicyBySubstrate
    { scalingHomeLocal = ScalingPolicyFixed count
    , scalingAws = ScalingPolicyFixed count
    }

scalingPolicyForSubstrate :: Substrate -> ScalingPolicyBySubstrate -> ScalingPolicy
scalingPolicyForSubstrate substrate policies =
  case substrate of
    SubstrateHomeLocal -> scalingHomeLocal policies
    SubstrateAws -> scalingAws policies

replicasForSubstrate :: Substrate -> ScalingPolicyBySubstrate -> Natural
replicasForSubstrate substrate policies =
  case scalingPolicyForSubstrate substrate policies of
    ScalingPolicyFixed count -> count
    -- Phase 4 owns autoscaler reconciliation. Until then, render a stable
    -- lower-bound replica count for an elastic cloud policy.
    ScalingPolicyElastic bounds -> elasticMin bounds

validateScalingPolicyBySubstrate :: String -> ScalingPolicyBySubstrate -> Either String ()
validateScalingPolicyBySubstrate fieldName policies = do
  validateScalingPolicy fieldName SubstrateHomeLocal (scalingHomeLocal policies)
  validateScalingPolicy fieldName SubstrateAws (scalingAws policies)

validateScalingPolicy :: String -> Substrate -> ScalingPolicy -> Either String ()
validateScalingPolicy fieldName substrate policy =
  case (substrate, policy) of
    (SubstrateHomeLocal, ScalingPolicyElastic _) ->
      Left (fieldName ++ ".home_local must be Fixed; Elastic scaling is only valid for aws")
    (_, ScalingPolicyFixed count)
      | count >= 1 -> Right ()
      | otherwise -> Left (fieldName ++ "." ++ substrateId substrate ++ ".Fixed must be at least 1")
    (_, ScalingPolicyElastic bounds)
      | elasticMin bounds == 0 ->
          Left (fieldName ++ "." ++ substrateId substrate ++ ".Elastic.min must be at least 1")
      | elasticMin bounds > elasticMax bounds ->
          Left (fieldName ++ "." ++ substrateId substrate ++ ".Elastic.min must be less than or equal to max")
      | otherwise -> Right ()

defaultSubstrate :: Substrate
defaultSubstrate = SubstrateHomeLocal

allSubstrates :: [Substrate]
allSubstrates = [SubstrateHomeLocal, SubstrateAws]

substrateId :: Substrate -> String
substrateId substrate =
  case substrate of
    SubstrateHomeLocal -> "home-local"
    SubstrateAws -> "aws"

parseSubstrate :: String -> Either String Substrate
parseSubstrate raw =
  case raw of
    "home-local" -> Right SubstrateHomeLocal
    "aws" -> Right SubstrateAws
    _ -> Left "--substrate must be one of: home-local, aws"

stripPrefix :: Text -> Text -> Text
stripPrefix prefix name =
  fromMaybe name (Text.stripPrefix prefix name)

stripPrefixLowerFirst :: Text -> Text -> Text
stripPrefixLowerFirst prefix name =
  lowerFirst (stripPrefix prefix name)

lowerFirst :: Text -> Text
lowerFirst value =
  case Text.uncons value of
    Just (firstChar, rest) -> Text.cons (Char.toLower firstChar) rest
    Nothing -> value

scalingPolicyBySubstrateField :: Text -> Text
scalingPolicyBySubstrateField value =
  case value of
    "scalingHomeLocal" -> "home_local"
    "scalingAws" -> "aws"
    _ -> value
