{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Error
  ( AppError (..)
  , ErrorKind (..)
  , appError
  , fatalError
  , recoverableError
  )
where

import Control.Exception (SomeException)
import Data.Text (Text)

data ErrorKind
  = Recoverable
  | Fatal
  deriving (Eq, Show)

data AppError = AppError
  { errorKind :: ErrorKind
  , errorMsg :: Text
  , errorCause :: Maybe SomeException
  }
  deriving (Show)

appError :: ErrorKind -> Text -> Maybe SomeException -> AppError
appError = AppError

fatalError :: Text -> AppError
fatalError message =
  AppError
    { errorKind = Fatal
    , errorMsg = message
    , errorCause = Nothing
    }

recoverableError :: Text -> AppError
recoverableError message =
  AppError
    { errorKind = Recoverable
    , errorMsg = message
    , errorCause = Nothing
    }
