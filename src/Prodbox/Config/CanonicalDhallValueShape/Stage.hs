{-# LANGUAGE ImportQualifiedPost #-}

module Prodbox.Config.CanonicalDhallValueShape.Stage
  ( staticShapeTemplateExpression
  , discoverSchemaSourceDependencies
  , SchemaStageError (..)
  ) where

import Data.Proxy (Proxy)
import Dhall qualified
import Language.Haskell.TH.Syntax
  ( Exp
  , Q
  , addDependentFile
  , loc_filename
  , location
  , runIO
  , unTypeCode
  )
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.SchemaSourceDependencies
  ( SchemaStageError (..)
  , discoverSchemaSourceDependencies
  )

staticShapeTemplateExpression
  :: (Dhall.ToDhall value) => Proxy value -> [StaticShapeTransform] -> Q Exp
staticShapeTemplateExpression producer transforms = do
  here <- location
  sources <- runIO (discoverSchemaSourceDependencies (loc_filename here))
  paths <- either (fail . show) pure sources
  mapM_ addDependentFile paths
  either
    (fail . show)
    (unTypeCode . liftStaticShapeDefinition)
    (prepareStaticShapeDefinition producer transforms)
