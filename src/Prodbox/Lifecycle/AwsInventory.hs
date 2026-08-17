{-# LANGUAGE OverloadedStrings #-}

-- | Pure normalization of AWS discovery rows into domain resources.  One ARN
-- is one resource regardless of tag count, pagination overlap, or retries.
module Prodbox.Lifecycle.AwsInventory
  ( Arn
  , ArnError (..)
  , mkArn
  , arnText
  , AwsResourceType (..)
  , AwsResourceCoordinate (..)
  , AwsTag (..)
  , AwsTagRow (..)
  , AwsResource (..)
  , AwsInventory
  , AwsInventoryFailure (..)
  , normalizeAwsTagRows
  , awsInventoryMap
  , awsInventoryResources
  , awsInventoryLookup
  , awsInventorySize
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.Model (AwsScope)

newtype Arn = Arn Text
  deriving (Eq, Ord, Show)

data ArnError
  = ArnEmpty
  | ArnPrefixInvalid !Text
  deriving (Eq, Show)

mkArn :: Text -> Either ArnError Arn
mkArn raw
  | Text.null normalized = Left ArnEmpty
  | not ("arn:" `Text.isPrefixOf` normalized) = Left (ArnPrefixInvalid normalized)
  | otherwise = Right (Arn normalized)
 where
  normalized = Text.strip raw

arnText :: Arn -> Text
arnText (Arn value) = value

newtype AwsResourceType = AwsResourceType Text
  deriving (Eq, Ord, Show)

newtype AwsResourceCoordinate = AwsResourceCoordinate Text
  deriving (Eq, Ord, Show)

data AwsTag = AwsTag
  { awsTagKey :: !Text
  , awsTagValue :: !Text
  }
  deriving (Eq, Ord, Show)

-- | One decoder row.  A provider ResourceTagMapping with two tags may yield
-- two rows with the same ARN and core facts; an untagged resource yields one
-- row with 'Nothing'.
data AwsTagRow = AwsTagRow
  { awsTagRowArn :: !Arn
  , awsTagRowScope :: !AwsScope
  , awsTagRowResourceType :: !AwsResourceType
  , awsTagRowCoordinate :: !AwsResourceCoordinate
  , awsTagRowTag :: !(Maybe AwsTag)
  }
  deriving (Eq, Show)

data AwsResource = AwsResource
  { awsResourceArn :: !Arn
  , awsResourceScope :: !AwsScope
  , awsResourceType :: !AwsResourceType
  , awsResourceCoordinate :: !AwsResourceCoordinate
  , awsResourceTags :: !(Map Text Text)
  }
  deriving (Eq, Show)

newtype AwsInventory = AwsInventory (Map Arn AwsResource)
  deriving (Eq, Show)

data AwsInventoryFailure
  = AwsResourceScopeConflict !Arn !AwsScope !AwsScope
  | AwsResourceTypeConflict !Arn !AwsResourceType !AwsResourceType
  | AwsResourceCoordinateConflict
      !Arn
      !AwsResourceCoordinate
      !AwsResourceCoordinate
  | AwsResourceTagConflict !Arn !Text !Text !Text
  | AwsResourceTagKeyEmpty !Arn
  deriving (Eq, Show)

normalizeAwsTagRows :: [AwsTagRow] -> Either AwsInventoryFailure AwsInventory
normalizeAwsTagRows rows = AwsInventory <$> foldl' addRow (Right Map.empty) rows
 where
  addRow failure@(Left _) _ = failure
  addRow (Right resources) row = do
    validateTag row
    case Map.lookup (awsTagRowArn row) resources of
      Nothing ->
        Right
          ( Map.insert
              (awsTagRowArn row)
              (resourceFromRow row)
              resources
          )
      Just existing -> do
        merged <- mergeRow existing row
        Right (Map.insert (awsTagRowArn row) merged resources)

awsInventoryMap :: AwsInventory -> Map Arn AwsResource
awsInventoryMap (AwsInventory resources) = resources

awsInventoryResources :: AwsInventory -> [AwsResource]
awsInventoryResources = Map.elems . awsInventoryMap

awsInventoryLookup :: Arn -> AwsInventory -> Maybe AwsResource
awsInventoryLookup arn = Map.lookup arn . awsInventoryMap

awsInventorySize :: AwsInventory -> Int
awsInventorySize = Map.size . awsInventoryMap

resourceFromRow :: AwsTagRow -> AwsResource
resourceFromRow row =
  AwsResource
    { awsResourceArn = awsTagRowArn row
    , awsResourceScope = awsTagRowScope row
    , awsResourceType = awsTagRowResourceType row
    , awsResourceCoordinate = awsTagRowCoordinate row
    , awsResourceTags = case awsTagRowTag row of
        Nothing -> Map.empty
        Just tag -> Map.singleton (awsTagKey tag) (awsTagValue tag)
    }

validateTag :: AwsTagRow -> Either AwsInventoryFailure ()
validateTag row = case awsTagRowTag row of
  Just tag
    | Text.null (Text.strip (awsTagKey tag)) ->
        Left (AwsResourceTagKeyEmpty (awsTagRowArn row))
  _ -> Right ()

mergeRow :: AwsResource -> AwsTagRow -> Either AwsInventoryFailure AwsResource
mergeRow existing row
  | awsResourceScope existing /= awsTagRowScope row =
      Left
        ( AwsResourceScopeConflict
            arn
            (awsResourceScope existing)
            (awsTagRowScope row)
        )
  | awsResourceType existing /= awsTagRowResourceType row =
      Left
        ( AwsResourceTypeConflict
            arn
            (awsResourceType existing)
            (awsTagRowResourceType row)
        )
  | awsResourceCoordinate existing /= awsTagRowCoordinate row =
      Left
        ( AwsResourceCoordinateConflict
            arn
            (awsResourceCoordinate existing)
            (awsTagRowCoordinate row)
        )
  | otherwise = addTag existing (awsTagRowTag row)
 where
  arn = awsResourceArn existing

addTag :: AwsResource -> Maybe AwsTag -> Either AwsInventoryFailure AwsResource
addTag existing maybeTag = case maybeTag of
  Nothing -> Right existing
  Just tag -> case Map.lookup (awsTagKey tag) (awsResourceTags existing) of
    Nothing ->
      Right
        existing
          { awsResourceTags =
              Map.insert
                (awsTagKey tag)
                (awsTagValue tag)
                (awsResourceTags existing)
          }
    Just oldValue
      | oldValue == awsTagValue tag -> Right existing
      | otherwise ->
          Left
            ( AwsResourceTagConflict
                (awsResourceArn existing)
                (awsTagKey tag)
                oldValue
                (awsTagValue tag)
            )
