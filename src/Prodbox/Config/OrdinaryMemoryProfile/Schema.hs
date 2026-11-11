{-# LANGUAGE OverloadedStrings #-}

-- | Fixed ordinary-profile schema shared by its independent reader and writer.
module Prodbox.Config.OrdinaryMemoryProfile.Schema
  ( OrdinaryMemoryProfileError (..)
  , ordinaryMemoryProfileIdentity
  , ordinaryMemoryProfileRoles
  , ordinaryMemoryProfileMaximumBytes
  ) where

import Data.Text (Text)

data OrdinaryMemoryProfileError
  = OrdinaryMemoryProfileTooLarge
  | OrdinaryMemoryProfileInvalid
  | OrdinaryMemoryProfileMalformed
  | OrdinaryMemoryProfileNonCanonical
  deriving (Eq, Show)

ordinaryMemoryProfileIdentity :: Text
ordinaryMemoryProfileIdentity = "ordinary-cascade-host"

ordinaryMemoryProfileRoles :: Int
ordinaryMemoryProfileRoles = 2

ordinaryMemoryProfileMaximumBytes :: Int
ordinaryMemoryProfileMaximumBytes = 65536
