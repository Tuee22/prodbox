{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Output
  ( ColorMode (..)
  , OutputFormat (..)
  , OutputOptions (..)
  , defaultOutputOptions
  , renderError
  , renderOutput
  , writeDiagnostic
  , writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
where

import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Prodbox.Error (AppError (..))
import System.IO
  ( hPutStr
  , hPutStrLn
  , stderr
  )

data OutputFormat
  = OutputPlain
  | OutputTable
  | OutputJson
  deriving (Eq, Show)

data ColorMode
  = ColorAuto
  | ColorAlways
  | ColorNever
  deriving (Eq, Show)

data OutputOptions = OutputOptions
  { outputFormat :: OutputFormat
  , outputColor :: ColorMode
  }
  deriving (Eq, Show)

defaultOutputOptions :: OutputOptions
defaultOutputOptions =
  OutputOptions
    { outputFormat = OutputPlain
    , outputColor = ColorAuto
    }

renderError :: AppError -> Text
renderError = errorMsg

renderOutput :: (ToJSON value) => OutputOptions -> Text -> value -> Text
renderOutput options plainText jsonValue =
  case outputFormat options of
    OutputPlain -> plainText
    OutputTable -> plainText
    OutputJson -> Text.pack (BL8.unpack (encode jsonValue))

writeError :: AppError -> IO ()
writeError = TextIO.hPutStrLn stderr . renderError

writeOutput :: String -> IO ()
writeOutput = putStr

writeOutputLine :: String -> IO ()
writeOutputLine = putStrLn

writeDiagnostic :: String -> IO ()
writeDiagnostic = hPutStr stderr

writeDiagnosticLine :: String -> IO ()
writeDiagnosticLine = hPutStrLn stderr
