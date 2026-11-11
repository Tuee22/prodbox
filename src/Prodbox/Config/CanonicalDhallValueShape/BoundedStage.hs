{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE TemplateHaskell #-}

-- Finite structural counts only. Text/scalar bytes, working set and admission
-- retain independent limits and evidence.
module Prodbox.Config.CanonicalDhallValueShape.BoundedStage
  ( BoundedStaticShapeTemplate
  , boundedStaticShapeTemplate
  , BoundedStaticShapeError (..)
  , prepareBoundedStaticShapeDefinition
  , boundedStaticShapeTemplateExpression
  ) where

import Data.Bifunctor (first)
import Data.Proxy (Proxy)
import Dhall qualified
import Language.Haskell.TH.Syntax (Exp (..), Q)
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CanonicalDhallValueShape.Stage (staticShapeTemplateExpression)

type role BoundedStaticShapeTemplate nominal
newtype BoundedStaticShapeTemplate value = BoundedStaticShapeTemplate (StaticShapeTemplate value)

data BoundedStaticShapeError
  = BoundedStaticPreparationRefused !StaticShapeTemplateError
  | BoundedStaticValueListUnbounded
  deriving (Eq, Show)

boundedStaticShapeTemplate :: BoundedStaticShapeTemplate value -> StaticShapeTemplate value
boundedStaticShapeTemplate (BoundedStaticShapeTemplate template) = template

prepareBoundedStaticShapeDefinition
  :: (Dhall.ToDhall value)
  => Proxy value
  -> [StaticShapeTransform]
  -> Either BoundedStaticShapeError (StaticShapeDefinition value)
prepareBoundedStaticShapeDefinition producer transforms = do
  definition <-
    first BoundedStaticPreparationRefused (prepareStaticShapeDefinition producer transforms)
  case boundCanonicalDhallValueShape (staticShapeDefinitionShape definition) of
    Nothing -> Left BoundedStaticValueListUnbounded
    Just _ -> Right definition

boundedStaticShapeTemplateExpression
  :: (Dhall.ToDhall value) => Proxy value -> [StaticShapeTransform] -> Q Exp
boundedStaticShapeTemplateExpression producer transforms = do
  _ <- either (fail . show) pure (prepareBoundedStaticShapeDefinition producer transforms)
  expression <- staticShapeTemplateExpression producer transforms
  pure (AppE (ConE 'BoundedStaticShapeTemplate) expression)
