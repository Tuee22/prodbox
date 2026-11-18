{-# LANGUAGE OverloadedStrings #-}

-- | Exact image metadata is a point observation, not proof of ownership,
-- provenance, absence, or permission to remove an image.
module Prodbox.Control.ImageIdObservation
  ( ImageIdObservation (..)
  , validImageId
  , parseImageIdObservation
  ) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.Char (isAsciiLower)

data ImageIdObservation
  = ImageIdUnobservable
  | ImageIdObserved !String !String !Int
  deriving (Eq, Show)

validImageId :: String -> Bool
validImageId ('s' : 'h' : 'a' : '2' : '5' : '6' : ':' : rest) =
  length rest == 64 && all hexadecimal rest
 where
  hexadecimal character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')
validImageId _ = False

parseImageIdObservation :: String -> Aeson.Value -> Either String ImageIdObservation
parseImageIdObservation expected = parseEither $ Aeson.withObject "image" $ \value -> do
  identifier <- value .: "Id"
  os <- value .: "Os"
  arch <- value .: "Architecture"
  tags <- value .: "RepoTags" :: Parser (Maybe [String])
  let references = maybe [] id tags
  if not (validImageId expected)
    || identifier /= expected
    || not (safeImageWord os)
    || not (safeImageWord arch)
    || length references > 1024
    || any (\tag -> null tag || length tag > 512) references
    then fail "invalid exact image observation"
    else pure (ImageIdObserved os arch (length references))

safeImageWord :: String -> Bool
safeImageWord word =
  not (null word)
    && length word <= 32
    && all (\c -> isAsciiLower c || (c >= '0' && c <= '9') || c `elem` ("_-" :: String)) word
