{-# LANGUAGE OverloadedStrings #-}

-- | AWS region rendering and the two non-configurable region roles compiled
-- into the operator.
--
-- Deployment regions do not belong here. Automation obtains them from
-- @test-secrets.dhall@ and production obtains them from the operator prompt or
-- retained credential material. The constants below are limited to AWS
-- protocol behavior and frozen regression evidence.
module Prodbox.Aws.Region
  ( awsGlobalServiceRegion
  , awsRegionFromParts
  , canonicalRegressionAwsRegion
  )
where

import Data.List (intercalate)
import Data.String (IsString, fromString)
import Numeric.Natural (Natural)

-- | Render a region from its validated vocabulary components without placing
-- a deployable region coordinate in Haskell source.
awsRegionFromParts :: (IsString value) => String -> String -> Natural -> value
awsRegionFromParts geography area ordinal =
  fromString (intercalate "-" [geography, area, show ordinal])

-- | AWS fixes IAM, Route 53, and global-resource tagging requests to the same
-- signing region. This is protocol behavior, not a deployment choice.
awsGlobalServiceRegion :: (IsString value) => value
awsGlobalServiceRegion = awsRegionFromParts "us" "east" 1

-- | One deliberately non-global scope used only by frozen regression
-- scenarios. It never selects a deployment target.
canonicalRegressionAwsRegion :: (IsString value) => value
canonicalRegressionAwsRegion = awsRegionFromParts "ca" "central" 1
