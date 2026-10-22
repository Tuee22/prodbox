{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The invite URL and password form travel on bounded stdin, never argv or
-- a rendered subprocess error. Temporary cookie/body files remain caller-owned.
module Prodbox.Keycloak.InviteHttp
  ( InviteHttpRequest
  , mkInviteHttpRequest
  , runInviteHttp
  , runInviteHttpWith
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isAscii, isControl)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Prodbox.Error (AppError)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))

newtype InviteHttpRequest = InviteHttpRequest ByteString

instance Show InviteHttpRequest where
  show _ = "<invite-http-request>"

mkInviteHttpRequest :: String -> String -> Maybe String -> Either String InviteHttpRequest
mkInviteHttpRequest expectedHost rawUrl postBody
  | null expectedHost || any invalidHost expectedHost = Left "invite HTTP host is invalid"
  | any (<= ' ') rawUrl || any isControl rawUrl = Left "invite HTTP URL is invalid"
  | otherwise = do
      afterScheme <-
        maybe (Left "invite HTTP URL must use HTTPS") Right (Text.stripPrefix "https://" (Text.pack rawUrl))
      let (authority, path) = Text.breakOn "/" afterScheme
          expected = Text.toCaseFold (Text.pack expectedHost)
      if Text.null path || Text.toCaseFold authority `notElem` [expected, expected <> ":443"]
        then Left "invite HTTP URL does not name the configured public host"
        else do
          bodyLines <- case postBody of
            Nothing -> Right []
            Just body
              | any isControl body -> Left "invite HTTP form contains a control character"
              | otherwise ->
                  Right
                    ["header = \"Content-Type: application/x-www-form-urlencoded\"", "data-raw = " <> quoted body]
          let input = Encoding.encodeUtf8 (Text.pack (unlines ("url = " <> quoted rawUrl : bodyLines)))
          if BS.length input > maximumInviteHttpInputBytes
            then Left "invite HTTP request exceeds its stdin bound"
            else Right (InviteHttpRequest input)
 where
  invalidHost character =
    not (isAscii character && (isAlphaNum character || character `elem` (".-" :: String)))

runInviteHttp :: FilePath -> FilePath -> FilePath -> InviteHttpRequest -> IO (Either String ())
runInviteHttp = runInviteHttpWith captureSubprocessWithInputBounded

runInviteHttpWith
  :: (Monad m)
  => (BoundedSubprocessLimits -> ByteString -> Subprocess -> m (Either AppError ProcessOutput))
  -> FilePath
  -> FilePath
  -> FilePath
  -> InviteHttpRequest
  -> m (Either String ())
runInviteHttpWith run repoRoot cookieJar outputPath (InviteHttpRequest input) = do
  observed <-
    run
      limits
      input
      Subprocess
        { subprocessPath = "curl"
        , subprocessArguments =
            [ "--disable"
            , "--silent"
            , "--show-error"
            , "--location"
            , "--fail-with-body"
            , "--globoff"
            , "--proto"
            , "=https"
            , "--proto-redir"
            , "=https"
            , "--max-redirs"
            , "5"
            , "--max-time"
            , "25"
            , "--max-filesize"
            , "1048576"
            , "--cookie-jar"
            , cookieJar
            , "--cookie"
            , cookieJar
            , "--output"
            , outputPath
            , "--config"
            , "-"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case observed of
    Left _ -> Left "invite HTTP request did not complete within its process bounds"
    Right output -> case processExitCode output of
      ExitFailure _ -> Left "invite HTTP request failed"
      ExitSuccess -> Right ()
 where
  limits = BoundedSubprocessLimits maximumInviteHttpInputBytes (16 * 1024) (16 * 1024) 30_000_000

maximumInviteHttpInputBytes :: Int
maximumInviteHttpInputBytes = 64 * 1024

quoted :: String -> String
quoted value = '"' : concatMap escape value <> "\""
 where
  escape character = case character of
    '"' -> "\\\""
    '\\' -> "\\\\"
    _ -> [character]
