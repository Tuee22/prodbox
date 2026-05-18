module Prodbox.Substrate
  ( Substrate (..)
  , substrateId
  , parseSubstrate
  , defaultSubstrate
  , allSubstrates
  )
where

data Substrate
  = SubstrateHomeLocal
  | SubstrateAws
  deriving (Eq, Show)

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
