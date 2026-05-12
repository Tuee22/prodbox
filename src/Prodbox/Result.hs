{-# LANGUAGE DeriveFunctor #-}

module Prodbox.Result
  ( Result (..)
  , eitherToResult
  , resultToEither
  )
where

data Result a
  = Success a
  | Failure String
  deriving (Eq, Functor, Show)

resultToEither :: Result a -> Either String a
resultToEither result =
  case result of
    Success value -> Right value
    Failure err -> Left err

eitherToResult :: Either String a -> Result a
eitherToResult value =
  case value of
    Left err -> Failure err
    Right success -> Success success
