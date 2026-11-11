{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module StaticDhallShapeFixtures (UnicodeRecord (..), Choice (..), Unsupported (..)) where

import Data.Text (Text)
import Dhall qualified
import Dhall.Core qualified as Core
import GHC.Generics (Generic)

data UnicodeRecord = UnicodeRecord {enabled :: Bool, values :: [Maybe Text]} deriving (Generic)
instance Dhall.ToDhall UnicodeRecord where
  injectWith _ = Dhall.genericToDhallWith Dhall.defaultInterpretOptions {Dhall.fieldModifier = ("λ😀-" <>)}
data Choice = Done | Detail UnicodeRecord deriving (Generic)
instance Dhall.ToDhall Choice

data Unsupported = Unsupported
instance Dhall.ToDhall Unsupported where
  injectWith _ =
    Dhall.Encoder
      { Dhall.embed = const (Core.NaturalLit 0)
      , Dhall.declared = Core.App Core.Text Core.Natural
      }
