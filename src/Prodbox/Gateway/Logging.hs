{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Gateway.Logging
  ( Severity (..)
  , field
  , logDebug
  , logError
  , logInfo
  , logStructured
  , logStructuredAt
  , logWarn
  , renderSeverity
  , severityFromLogLevel
  , shouldLogSeverity
  )
where

import Colog.Actions (logByteStringStderr)
import Colog.Core (LogAction (..))
import Control.Monad (when)
import Data.Aeson (ToJSON, Value, encode, object, toJSON)
import Data.Aeson.Key qualified as Key
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)

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
logStructured = logStructuredAt Debug

logStructuredAt :: Severity -> Severity -> Text -> [(Text, Value)] -> IO ()
logStructuredAt minimumSeverity severity eventName fields =
  when (shouldLogSeverity minimumSeverity severity) $ do
    now <- getCurrentTime
    unLogAction daemonLogAction $
      BL.toStrict $
        encode $
          object
            ( [ "timestamp_utc" .= formatShow iso8601Format now
              , "severity" .= renderSeverity severity
              , "event" .= eventName
              ]
                ++ map dynamicField fields
            )

daemonLogAction :: LogAction IO BS.ByteString
daemonLogAction = logByteStringStderr

severityFromLogLevel :: String -> Severity
severityFromLogLevel rawLevel =
  case map toLower rawLevel of
    "debug" -> Debug
    "info" -> Info
    "warn" -> Warn
    "warning" -> Warn
    "error" -> Error
    _ -> Info

shouldLogSeverity :: Severity -> Severity -> Bool
shouldLogSeverity minimumSeverity severity =
  severity >= minimumSeverity

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
