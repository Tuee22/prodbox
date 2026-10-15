{-# LANGUAGE OverloadedStrings #-}

-- | A closed, value-free token for a refusal text that crossed a boundary which
-- erased its cause.
--
-- The retained-material delivery path answers a refusal with a text: some are
-- fixed sentences this code authors, some are a fixed prefix followed by the
-- @show@ of an error value (the constructors name the stage that refused, and
-- the arguments may carry anything), and the rest are the @show@ itself. A
-- boundary that must not echo arbitrary text still has to say which stage
-- refused, or a first live failure is a bare @delivery-failed@ with nothing to
-- follow. The token is built, segment by segment (a segment ends at @": "@),
-- from only three sources: an exact fixed sentence listed here; plain prose
-- (letters, spaces and hyphens only, so no digit, quote, path or digest can be
-- in it); and the leading constructor names of a @show@, stopping at the first
-- argument that is not itself a constructor. Everything else is dropped, and a
-- text with nothing left becomes @other@.
module Prodbox.ControlPlane.ClosedRefusalToken
  ( closedRefusalToken
  )
where

import Data.Char (isAlpha, isAlphaNum, isAscii, isAsciiLower, isAsciiUpper, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text

-- | The token for one refusal text.
closedRefusalToken :: Text -> Text
closedRefusalToken detail
  | Text.strip detail `elem` knownRefusalSentences = sentenceToken (Text.strip detail)
  | otherwise = case segmentTokens <> wrapped of
      [] -> "other"
      tokens -> Text.take maximumTokenLength (Text.intercalate "/" tokens)
 where
  segmentTokens = take maximumSegments (concatMap segmentToken (Text.splitOn ": " detail))
  wrapped =
    [ sentenceToken sentence
    | sentence <- knownRefusalSentences
    , sentence `Text.isInfixOf` detail
    , sentenceToken sentence `notElem` segmentTokens
    ]

maximumTokenLength :: Int
maximumTokenLength = 240

maximumConstructors :: Int
maximumConstructors = 4

maximumSegments :: Int
maximumSegments = 6

-- | The tokens of one segment: its sentence token when it is a known sentence or
-- plain prose, and otherwise the constructor chain it begins with.
segmentToken :: Text -> [Text]
segmentToken raw
  | Text.null segment = []
  | segment `elem` knownRefusalSentences = [sentenceToken segment]
  | isProse segment = [sentenceToken segment]
  | otherwise = constructorChain segment
 where
  segment = Text.strip raw

-- | Plain prose: at least two words of ASCII letters, joined by spaces or hyphens,
-- and short. No digit, quote, bracket, slash, colon or underscore can be in it.
isProse :: Text -> Bool
isProse segment =
  Text.length segment <= 96
    && Text.all
      (\character -> isAscii character && (isAlpha character || character == ' ' || character == '-'))
      segment
    && length (Text.words (Text.map (\character -> if character == '-' then ' ' else character) segment))
      >= 2

-- | The leading constructor names of a @show@, in order, stopping at the first
-- token that is not a constructor name (a string, a number, a field name).
constructorChain :: Text -> [Text]
constructorChain =
  take maximumConstructors
    . takeWhile isConstructorName
    . filter (not . Text.null)
    . Text.split separator
 where
  separator character = isSpace character || character `elem` ("()[]{},=" :: String)

isConstructorName :: Text -> Bool
isConstructorName token = case Text.uncons token of
  Just (first, rest) ->
    isAsciiUpper first
      && Text.length token <= 64
      && Text.all (\character -> isAlphaNum character || character == '_') rest
      && Text.any isAsciiLower rest
  Nothing -> False

sentenceToken :: Text -> Text
sentenceToken = Text.intercalate "-" . Text.words . Text.map hyphenate . Text.toLower
 where
  hyphenate character
    | isAsciiLower character || character `elem` ("0123456789" :: String) = character
    | otherwise = ' '

-- | Every fixed refusal sentence the retained-material delivery path authors that
-- plain prose cannot spell (a capital letter, a digit, or a hyphen run). A
-- sentence is matched exactly, as a substring, so a @show@ that wraps one still
-- names it.
knownRefusalSentences :: [Text]
knownRefusalSentences =
  [ "request-codec-rejected"
  , "authority-clock-unavailable"
  , "retained delivery target is not the registered Target Agent"
  , "retained material delivery deadline elapsed"
  , "retained rewrap envelope digest mismatch"
  , "Target worker controller auditor login unavailable"
  , "Target worker controller auditor login was not bounded batch"
  , "target is not a retained-material schema"
  , "retained-material observation deadline elapsed"
  , "retained-material delivery deadline elapsed"
  , "retained source operation mismatch"
  , "retained source generation mismatch"
  , "retained source is absent"
  , "retained source digest mismatches metadata"
  , "retained source is corrupt"
  , "retained source is unobservable"
  , "retained source binding mismatch"
  ]
