{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Json
  ( renderCommandJson
  )
where

import Data.Aeson (Value (Array), encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.CLI.Spec
  ( CommandSpec (..)
  , Example (..)
  , OptionSpec (..)
  )

renderCommandJson :: CommandSpec -> String
renderCommandJson = (++ "\n") . BL8.unpack . encode . encodeSpec

encodeSpec :: CommandSpec -> Value
encodeSpec spec =
  object
    [ "name" .= commandName
    , "summary" .= commandSummary
    , "description" .= commandDescription
    , "children" .= Array (Vector.fromList (map encodeSpec commandChildren))
    , "options" .= Array (Vector.fromList (map encodeOption commandOptions))
    , "examples" .= Array (Vector.fromList (map encodeExample commandExamples))
    ]
 where
  CommandSpec
    { name = commandName
    , summary = commandSummary
    , description = commandDescription
    , children = commandChildren
    , options = commandOptions
    , examples = commandExamples
    } = spec

encodeOption :: OptionSpec -> Value
encodeOption optionSpec =
  object
    [ "longName" .= optionLongName
    , "shortName" .= fmap Text.singleton optionShortName
    , "metavar" .= optionMetavar
    , "description" .= optionDescription
    , "required" .= optionRequired
    ]
 where
  OptionSpec
    { longName = optionLongName
    , shortName = optionShortName
    , optionMetavar = optionMetavar
    , description = optionDescription
    , required = optionRequired
    } = optionSpec

encodeExample :: Example -> Value
encodeExample ex =
  object
    [ "exampleCommand" .= exampleCommand ex
    , "exampleDescription" .= exampleDescription ex
    ]
