{-# LANGUAGE OverloadedStrings #-}

-- | Operator-supplied secret input: a hidden prompt on a terminal, otherwise
-- one line of standard input. Absent input is 'Nothing'; the value is only
-- bytes handed to the command that needs it and is never printed.
module Prodbox.Control.OperatorInput
  ( readSecretLine
  ) where

import Control.Exception (IOException, bracket_, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Prodbox.CLI.Output (writeDiagnostic, writeDiagnosticLine)
import System.IO (hGetEcho, hIsTerminalDevice, hSetEcho, stdin)
import System.IO.Error (isEOFError)

-- | A hidden prompt on a terminal, otherwise one line of standard input. End
-- of input or an empty answer is "no input".
readSecretLine :: String -> IO (Maybe ByteString.ByteString)
readSecretLine prompt = do
  terminal <- hIsTerminalDevice stdin
  line <-
    if terminal
      then do
        writeDiagnostic prompt
        prior <- hGetEcho stdin
        bracket_ (hSetEcho stdin False) (hSetEcho stdin prior >> writeDiagnosticLine "") readOneLine
      else readOneLine
  pure $ case fmap (filter (`notElem` ("\r\n " :: String))) line of
    Just text | not (null text) -> Just (ByteString8.pack text)
    _ -> Nothing
 where
  readOneLine = do
    result <- try getLine :: IO (Either IOException String)
    pure $ case result of
      Right text -> Just text
      Left failure | isEOFError failure -> Nothing
      Left _ -> Nothing
