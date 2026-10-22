{-# LANGUAGE OverloadedStrings #-}

-- | Metadata-only AWS CLI service errors. Both the legacy bare header and
-- CLI 2.34.18's measured prefix/retry-context header decode to the same code
-- and operation. Unknown framing never becomes a service absence.
module Prodbox.Aws.CliError
  ( AwsCliServiceError
  , awsCliServiceErrorCode
  , awsCliServiceErrorOperation
  , decodeAwsCliServiceError
  , awsCliServiceErrorMatches
  ) where

import Data.Char (isAlphaNum, isAscii)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

data AwsCliServiceError = AwsCliServiceError
  { awsCliServiceErrorCode :: !Text
  , awsCliServiceErrorOperation :: !Text
  }
  deriving (Eq, Show)

decodeAwsCliServiceError :: ProcessOutput -> Maybe AwsCliServiceError
decodeAwsCliServiceError output = case processExitCode output of
  ExitSuccess -> Nothing
  ExitFailure _
    | Text.length diagnostic > 16 * 1024 -> Nothing
    | otherwise -> case mapMaybe serviceHeader (Text.lines diagnostic) of
        [observed] -> Just observed
        _ -> Nothing
 where
  diagnostic = Text.pack (processStderr output)

serviceHeader :: Text -> Maybe AwsCliServiceError
serviceHeader line = do
  let stripped = Text.strip line
      unprefixed = maybe stripped id (Text.stripPrefix "aws: [ERROR]: " stripped)
  payload <- Text.stripPrefix "An error occurred (" unprefixed
  let (code, remainder) = Text.breakOn ") when calling the " payload
  operationPayload <- Text.stripPrefix ") when calling the " remainder
  let (operation, suffix) = Text.breakOn " operation" operationPayload
  ending <- Text.stripPrefix " operation" suffix
  if validToken code && validToken operation && completeEnding ending
    then Just (AwsCliServiceError code operation)
    else Nothing
 where
  validToken value =
    not (Text.null value)
      && Text.length value <= 128
      && Text.all (\char -> isAscii char && (isAlphaNum char || char `elem` ("._-" :: String))) value
  completeEnding value
    | ":" `Text.isPrefixOf` value = True
    | otherwise = case Text.stripPrefix " (reached max retries: " value of
        Nothing -> False
        Just retryContext ->
          let (attempts, remaining) = Text.breakOn "):" retryContext
           in not (Text.null attempts)
                && Text.length attempts <= 10
                && Text.all (`elem` ("0123456789" :: String)) attempts
                && "):" `Text.isPrefixOf` remaining

awsCliServiceErrorMatches :: Text -> Text -> ProcessOutput -> Bool
awsCliServiceErrorMatches code operation output =
  decodeAwsCliServiceError output == Just (AwsCliServiceError code operation)
