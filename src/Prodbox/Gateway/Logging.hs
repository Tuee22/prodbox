{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Logging
  ( Severity (..)
  , field
  , logDebug
  , logError
  , logInfo
  , logStructured
  , logWarn
  , renderSeverity
  )
where

import Data.Aeson (ToJSON, Value, encode, object, toJSON)
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
import System.IO (stderr)

data Severity
  = Debug
  | Info
  | Warn
  | Error
  deriving (Eq, Ord, Show)

field :: (ToJSON value) => Text -> value -> (Text, Value)
field name value = (name, toJSON value)

logDebug :: Text -> [(Text, Value)] -> IO ()
logDebug = logStructured Debug

logInfo :: Text -> [(Text, Value)] -> IO ()
logInfo = logStructured Info

logWarn :: Text -> [(Text, Value)] -> IO ()
logWarn = logStructured Warn

logError :: Text -> [(Text, Value)] -> IO ()
logError = logStructured Error

logStructured :: Severity -> Text -> [(Text, Value)] -> IO ()
logStructured severity eventName fields = do
  now <- getCurrentTime
  BL8.hPutStrLn stderr $
    encode $
      object
        ( [ "timestamp_utc" .= formatShow iso8601Format now
          , "severity" .= renderSeverity severity
          , "event" .= eventName
          ]
            ++ map dynamicField fields
        )

renderSeverity :: Severity -> Text
renderSeverity severity =
  case severity of
    Debug -> "debug"
    Info -> "info"
    Warn -> "warn"
    Error -> "error"

dynamicField :: (Text, Value) -> (Key.Key, Value)
dynamicField (name, value) =
  (Key.fromText ("field_" <> Text.replace "." "_" name), value)

(.=) :: (ToJSON value) => Key.Key -> value -> (Key.Key, Value)
(.=) key value = (key, toJSON value)
