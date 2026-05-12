{-# LANGUAGE OverloadedStrings #-}

module Prodbox.CLI.Output
  ( renderError
  , writeError
  )
where

import Data.Text (Text)
import Data.Text.IO qualified as TextIO
import Prodbox.Error (AppError (..))
import System.IO (stderr)

renderError :: AppError -> Text
renderError = errorMsg

writeError :: AppError -> IO ()
writeError = TextIO.hPutStrLn stderr . renderError
