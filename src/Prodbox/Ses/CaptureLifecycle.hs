{-# LANGUAGE OverloadedStrings #-}

-- | Desired retention for captured mail. The Provider supplies its fenced,
-- bounded subprocess runner; no AWS credential or host fallback lives here.
module Prodbox.Ses.CaptureLifecycle
  ( CaptureLifecycleObservation (..)
  , sesCaptureMailPrefix
  , sesCaptureReadinessObjectKey
  , desiredCaptureLifecycle
  , maximumCaptureLifecycleChars
  , classifyCaptureLifecycle
  , observeCaptureLifecycle
  , applyCaptureLifecycle
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Settings.Coordinate (S3BucketName, s3BucketNameText)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

data CaptureLifecycleObservation
  = CaptureLifecycleCurrent
  | CaptureLifecycleMissing
  | CaptureLifecycleDifferent
  | CaptureLifecycleUnobservable !Text
  deriving (Eq, Show)

sesCaptureMailPrefix :: String
sesCaptureMailPrefix = "inbound/"

-- This stable, empty capability probe is retained independently of mail.
sesCaptureReadinessObjectKey :: String
sesCaptureReadinessObjectKey = ".prodbox-readiness-capability-probe"

desiredCaptureLifecycle :: Value
desiredCaptureLifecycle =
  object
    [ "Rules"
        .= [ object
               [ "ID" .= ("prodbox-inbound-mail-expiry-v1" :: Text)
               , "Status" .= ("Enabled" :: Text)
               , "Filter" .= object ["Prefix" .= sesCaptureMailPrefix]
               , "Expiration" .= object ["Days" .= (1 :: Int)]
               , "NoncurrentVersionExpiration" .= object ["NoncurrentDays" .= (1 :: Int)]
               , "AbortIncompleteMultipartUpload" .= object ["DaysAfterInitiation" .= (1 :: Int)]
               ]
           , object
               [ "ID" .= ("prodbox-inbound-delete-marker-expiry-v1" :: Text)
               , "Status" .= ("Enabled" :: Text)
               , "Filter" .= object ["Prefix" .= sesCaptureMailPrefix]
               , "Expiration" .= object ["ExpiredObjectDeleteMarker" .= True]
               ]
           ]
    ]

-- The desired document is under one KiB. This bound also lets the observer
-- refuse a foreign oversized rule set before allocating its complete JSON AST.
maximumCaptureLifecycleChars :: Int
maximumCaptureLifecycleChars = 64 * 1024

classifyCaptureLifecycle :: ProcessOutput -> CaptureLifecycleObservation
classifyCaptureLifecycle output = case processExitCode output of
  ExitFailure _
    | "An error occurred (NoSuchLifecycleConfiguration) when calling the GetBucketLifecycleConfiguration operation:"
        `Text.isPrefixOf` serviceError ->
        CaptureLifecycleMissing
    | otherwise -> CaptureLifecycleUnobservable "SES capture lifecycle could not be read"
  ExitSuccess
    | length (take (maximumCaptureLifecycleChars + 1) (processStdout output))
        > maximumCaptureLifecycleChars ->
        CaptureLifecycleUnobservable "SES capture lifecycle exceeds its decoder bound"
    | otherwise -> case readRules (Text.pack (processStdout output)) of
        Left detail -> CaptureLifecycleUnobservable detail
        Right actual -> case normalizeRules desiredCaptureLifecycle of
          Left detail -> CaptureLifecycleUnobservable detail
          Right expected
            | actual == expected -> CaptureLifecycleCurrent
            | otherwise -> CaptureLifecycleDifferent
 where
  stderrText = Text.strip (Text.pack (processStderr output))
  serviceError = maybe stderrText Text.strip (Text.stripPrefix "aws: [ERROR]:" stderrText)

readRules :: Text -> Either Text [Value]
readRules raw = do
  value <-
    first
      (const "SES capture lifecycle is not valid JSON")
      (eitherDecodeStrict' (TextEncoding.encodeUtf8 raw))
  normalizeRules value

normalizeRules :: Value -> Either Text [Value]
normalizeRules value = case value of
  Object document -> case KeyMap.lookup "Rules" document of
    Just (Array rules) -> map snd . sortOn fst <$> traverse identifiedRule (Vector.toList rules)
    _ -> Left "SES capture lifecycle has no Rules array"
  _ -> Left "SES capture lifecycle is not an object"
 where
  identifiedRule rule = case rule of
    Object fields -> case KeyMap.lookup "ID" fields of
      Just (String identifier) -> Right (identifier, rule)
      Nothing -> Right ("", rule)
      _ -> Left "SES capture lifecycle rule ID is not text"
    _ -> Left "SES capture lifecycle rule is not an object"

observeCaptureLifecycle
  :: (Monad m)
  => ([String] -> m ProcessOutput)
  -> S3BucketName
  -> m (CaptureLifecycleObservation, ProcessOutput)
observeCaptureLifecycle run bucket = do
  observed <-
    run
      [ "s3api"
      , "get-bucket-lifecycle-configuration"
      , "--bucket"
      , Text.unpack (s3BucketNameText bucket)
      , "--output"
      , "json"
      ]
  pure (classifyCaptureLifecycle observed, observed)

-- | A successful write is provisional; the owning Provider mutation's normal
-- observation must read the complete desired policy back before completion.
applyCaptureLifecycle
  :: (Monad m)
  => ([String] -> m ProcessOutput)
  -> S3BucketName
  -> m (Either Text ())
applyCaptureLifecycle run bucket = do
  written <-
    run
      [ "s3api"
      , "put-bucket-lifecycle-configuration"
      , "--bucket"
      , Text.unpack (s3BucketNameText bucket)
      , "--lifecycle-configuration"
      , Text.unpack (TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode desiredCaptureLifecycle)))
      , "--output"
      , "json"
      ]
  pure $ case processExitCode written of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left "SES capture lifecycle update was not acknowledged; read it before retrying"
