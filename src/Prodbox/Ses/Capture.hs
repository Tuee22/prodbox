{-# LANGUAGE OverloadedStrings #-}

-- | SES capture-bucket polling helper for the Phase 8 `ValidationKeycloakInvite` flow.
--
-- The shared SES infrastructure (Sprint 8.1) routes inbound mail addressed to
-- `ses.receive_subdomain` into the `ses.capture_bucket` S3 bucket under the `inbound/`
-- key prefix. `pollSesCapture` blocks until a captured message matches the recipient
-- the canonical-suite validation generated or until the configured deadline elapses.
--
-- Reuses the AWS CLI subprocess shape and `awsCommandEnvironment` projection that the
-- existing Route 53 and SES prerequisite validators already use in
-- `Prodbox.EffectInterpreter`. The actual subprocess composition lives here to keep
-- the validation arm in `Prodbox.TestValidation` thin.
module Prodbox.Ses.Capture
  ( CapturedEmail (..)
  , pollSesCapture
  , deleteCapturedEmail
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( SesSection (..)
  , ValidatedSettings (..)
  , capture_bucket
  , ses
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))
import System.IO (hClose)
import System.IO.Temp (withSystemTempFile)

-- | An inbound RFC-822 email captured by the SES receive rule.
data CapturedEmail = CapturedEmail
  { capturedEmailKey :: Text
  -- ^ The S3 object key (e.g. `inbound/abc123def…`).
  , capturedEmailBody :: ByteString
  -- ^ The raw RFC-822 body bytes.
  }
  deriving (Eq, Show)

-- | Poll the capture bucket for an inbound message matching the recipient.
--
-- The recipient is matched against the RFC-822 `To:` header substring (case-sensitive,
-- after newline normalization). Polls every 1 second up to the configured deadline.
-- Returns the first matching object's key + body.
pollSesCapture
  :: [(String, String)]
  -- ^ AWS-CLI environment (typically `awsCommandEnvironment settings`).
  -> ValidatedSettings
  -> Text
  -- ^ recipient email address to match in the inbound `To:` header
  -> Int
  -- ^ deadline in seconds (e.g. 60)
  -> IO (Result CapturedEmail)
pollSesCapture environment settings recipient deadlineSeconds =
  let bucket = Text.unpack (Text.strip (capture_bucket (ses (validatedConfig settings))))
   in if null bucket
        then
          pure
            ( Failure
                "pollSesCapture: ses.capture_bucket is empty; populate the Sprint 8.1 SES config block."
            )
        else loop bucket deadlineSeconds
 where
  loop _ remaining
    | remaining <= 0 =
        pure
          ( Failure
              ( "pollSesCapture: no inbound message matching `"
                  <> Text.unpack recipient
                  <> "` arrived within the configured deadline."
              )
          )
  loop bucket remaining = do
    listResult <- listInboundKeys environment bucket
    case listResult of
      Failure err -> pure (Failure err)
      Success keys -> do
        match <- findMatching environment bucket recipient keys
        case match of
          Just captured -> pure (Success captured)
          Nothing -> do
            threadDelay 1000000 -- 1 second
            loop bucket (remaining - 1)

-- | Hard-delete a captured email object after the validation arm consumes it.
deleteCapturedEmail :: [(String, String)] -> ValidatedSettings -> Text -> IO (Result ())
deleteCapturedEmail environment settings keyText =
  let bucket = Text.unpack (Text.strip (capture_bucket (ses (validatedConfig settings))))
   in if null bucket
        then pure (Failure "deleteCapturedEmail: ses.capture_bucket is empty.")
        else do
          result <-
            captureSubprocessResult
              Subprocess
                { subprocessPath = "aws"
                , subprocessArguments =
                    [ "s3api"
                    , "delete-object"
                    , "--bucket"
                    , bucket
                    , "--key"
                    , Text.unpack keyText
                    ]
                , subprocessEnvironment = Just environment
                , subprocessWorkingDirectory = Nothing
                }
          pure $ case result of
            Failure err -> Failure ("aws s3api delete-object failed: " <> err)
            Success output ->
              case processExitCode output of
                ExitSuccess -> Success ()
                ExitFailure code ->
                  Failure
                    ( "aws s3api delete-object exit "
                        <> show code
                        <> ": "
                        <> trim (processStderr output)
                    )

listInboundKeys :: [(String, String)] -> String -> IO (Result [Text])
listInboundKeys environment bucket = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "s3api"
            , "list-objects-v2"
            , "--bucket"
            , bucket
            , "--prefix"
            , "inbound/"
            , "--max-items"
            , "100"
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Failure err -> Failure ("aws s3api list-objects-v2 failed to start: " <> err)
    Success output ->
      case processExitCode output of
        ExitFailure code ->
          Failure
            ( "aws s3api list-objects-v2 exit "
                <> show code
                <> ": "
                <> trim (processStderr output)
            )
        ExitSuccess ->
          case eitherDecode (BL8.pack (processStdout output)) of
            Left err -> Failure ("could not decode list-objects-v2 JSON: " <> err)
            Right value -> Success (extractKeys value)

extractKeys :: Value -> [Text]
extractKeys (Object obj) =
  case KeyMap.lookup (Key.fromString "Contents") obj of
    Just (Array arr) ->
      [ keyText
      | Object item <- Vector.toList arr
      , Just (String keyText) <- [KeyMap.lookup (Key.fromString "Key") item]
      ]
    _ -> []
extractKeys _ = []

findMatching
  :: [(String, String)]
  -> String
  -> Text
  -> [Text]
  -> IO (Maybe CapturedEmail)
findMatching _ _ _ [] = pure Nothing
findMatching environment bucket recipient (keyText : rest) = do
  fetched <- getInboundObject environment bucket keyText
  case fetched of
    Failure _ -> findMatching environment bucket recipient rest
    Success body ->
      if recipientMatches recipient body
        then
          pure
            ( Just
                CapturedEmail
                  { capturedEmailKey = keyText
                  , capturedEmailBody = body
                  }
            )
        else findMatching environment bucket recipient rest

getInboundObject :: [(String, String)] -> String -> Text -> IO (Result ByteString)
getInboundObject environment bucket keyText =
  withSystemTempFile "prodbox-ses-capture-" $ \tempPath handle -> do
    hClose handle
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments =
              [ "s3api"
              , "get-object"
              , "--bucket"
              , bucket
              , "--key"
              , Text.unpack keyText
              , tempPath
              ]
          , subprocessEnvironment = Just environment
          , subprocessWorkingDirectory = Nothing
          }
    case result of
      Failure err -> pure (Failure ("aws s3api get-object failed to start: " <> err))
      Success output ->
        case processExitCode output of
          ExitFailure code ->
            pure
              ( Failure
                  ( "aws s3api get-object exit "
                      <> show code
                      <> ": "
                      <> trim (processStderr output)
                  )
              )
          ExitSuccess -> do
            body <- BL.readFile tempPath
            pure (Success body)

recipientMatches :: Text -> ByteString -> Bool
recipientMatches recipient body =
  let bodyText = BL8.unpack body
      needle = "To:"
      lines' = lines bodyText
      toLines = filter (\l -> needle `isPrefixOfCI` l) lines'
   in any (Text.unpack recipient `isInfixOf`) toLines

isPrefixOfCI :: String -> String -> Bool
isPrefixOfCI needle haystack =
  map lower (take (length needle) haystack) == map lower needle
 where
  lower c
    | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
    | otherwise = c

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
