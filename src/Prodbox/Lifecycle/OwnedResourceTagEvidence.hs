{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the canonical text form of one owned-resource tag query and
-- the resources it returned.
--
-- The Provider Worker renders this form and the cascade's terminal-audit
-- adapter parses it, so the two live here together rather than as a writer and
-- a reader that can drift apart.  The module knows nothing about the provider
-- API that produced the rows or about the audit that consumes them; it owns
-- exactly the wire shape.
--
-- Three properties are deliberate.
--
--   * __The query is echoed.__  An answer that names a different tag family
--     than the one asked about is a different question's answer, and the
--     consumer must be able to see that rather than classify it.
--   * __Completion is stated, never inferred.__  A paginated listing that
--     stopped early looks exactly like a short one, and a short family answer
--     read as absence is the defect class this evidence is most exposed to.
--     The terminator line carries the page count, and evidence without it does
--     not parse.
--   * __A resource with no tags is representable.__  The Tagging API returns
--     only tagged resources today, but "returned carrying no tags" and "not
--     returned" are different facts and are encoded differently.
module Prodbox.Lifecycle.OwnedResourceTagEvidence
  ( OwnedResourceTagQueryEcho (..)
  , OwnedResourceTagEntry (..)
  , OwnedResourceTagObservation (..)
  , renderOwnedResourceTagObservation
  , parseOwnedResourceTagObservation
  , OwnedResourceTagEvidenceError (..)
  , renderOwnedResourceTagEvidenceError
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Text.Read (readMaybe)

-- | Which tag family the query asked about.  A key-only query asks for every
-- resource carrying that key at any value; a pair query asks for one exact
-- value.
data OwnedResourceTagQueryEcho
  = OwnedResourceTagKeyEcho !Text
  | OwnedResourceTagPairEcho !Text !Text
  deriving (Eq, Ord, Show)

-- | One returned resource and its complete tag set, in the order the provider
-- returned them.
data OwnedResourceTagEntry = OwnedResourceTagEntry
  { ownedResourceTagEntryArn :: !Text
  , ownedResourceTagEntryTags :: ![(Text, Text)]
  }
  deriving (Eq, Show)

-- | A complete answer: which query, what came back, and over how many pages.
data OwnedResourceTagObservation = OwnedResourceTagObservation
  { ownedResourceTagObservationQuery :: !OwnedResourceTagQueryEcho
  , ownedResourceTagObservationEntries :: ![OwnedResourceTagEntry]
  , ownedResourceTagObservationPages :: !Natural
  }
  deriving (Eq, Show)

data OwnedResourceTagEvidenceError
  = -- | A field carries a separator this encoding uses, so it cannot be
    -- rendered without corrupting the row.
    OwnedResourceTagFieldSeparatorPresent !Text
  | OwnedResourceTagEvidenceEmpty
  | OwnedResourceTagQueryLineInvalid !Text
  | OwnedResourceTagResourceLineInvalid !Text
  | -- | The evidence ended without its completion terminator, so the listing
    -- may have been truncated.  This is never lowered to an empty family.
    OwnedResourceTagEvidenceIncomplete
  | OwnedResourceTagCompletionLineInvalid !Text
  deriving (Eq, Show)

renderOwnedResourceTagEvidenceError :: OwnedResourceTagEvidenceError -> Text
renderOwnedResourceTagEvidenceError = \case
  OwnedResourceTagFieldSeparatorPresent field ->
    "owned-resource tag evidence cannot encode a field carrying a separator: "
      <> field
  OwnedResourceTagEvidenceEmpty ->
    "owned-resource tag evidence carried no query line"
  OwnedResourceTagQueryLineInvalid line ->
    "owned-resource tag evidence query line is not readable: " <> line
  OwnedResourceTagResourceLineInvalid line ->
    "owned-resource tag evidence resource line is not readable: " <> line
  OwnedResourceTagEvidenceIncomplete ->
    "owned-resource tag evidence ended without its completion terminator, so \
    \the listing may be truncated and is not an answer"
  OwnedResourceTagCompletionLineInvalid line ->
    "owned-resource tag evidence completion line is not readable: " <> line

separator :: Text
separator = "\t"

renderOwnedResourceTagObservation
  :: OwnedResourceTagObservation
  -> Either OwnedResourceTagEvidenceError Text
renderOwnedResourceTagObservation observation = do
  queryLine <- case ownedResourceTagObservationQuery observation of
    OwnedResourceTagKeyEcho key -> do
      safe key
      Right (Text.intercalate separator ["query", "key", key])
    OwnedResourceTagPairEcho key value -> do
      safe key
      safe value
      Right (Text.intercalate separator ["query", "pair", key, value])
  resourceLines <-
    traverse renderEntry (ownedResourceTagObservationEntries observation)
  let completionLine =
        Text.intercalate
          separator
          [ "complete"
          , Text.pack (show (ownedResourceTagObservationPages observation))
          ]
  Right
    ( Text.intercalate
        "\n"
        (queryLine : concat resourceLines ++ [completionLine])
    )
 where
  renderEntry entry = do
    safe (ownedResourceTagEntryArn entry)
    case ownedResourceTagEntryTags entry of
      [] ->
        Right
          [ Text.intercalate
              separator
              ["resource", ownedResourceTagEntryArn entry]
          ]
      tags ->
        traverse
          ( \(key, value) -> do
              safe key
              safe value
              Right
                ( Text.intercalate
                    separator
                    ["resource", ownedResourceTagEntryArn entry, key, value]
                )
          )
          tags

  safe field
    | Text.any (\character -> character == '\t' || character == '\n') field =
        Left (OwnedResourceTagFieldSeparatorPresent field)
    | otherwise = Right ()

-- | Read the canonical form back.
--
-- Contiguous rows naming one ARN are merged into one entry.  Non-contiguous
-- rows stay separate entries on purpose: this parser reports what the evidence
-- said, and joining a resource's tag rows across the whole listing is the
-- consumer's normalization step, which already refuses rows that disagree.
parseOwnedResourceTagObservation
  :: Text
  -> Either OwnedResourceTagEvidenceError OwnedResourceTagObservation
parseOwnedResourceTagObservation evidence = case Text.lines evidence of
  [] -> Left OwnedResourceTagEvidenceEmpty
  queryLine : remaining -> do
    query <- parseQueryLine queryLine
    (entries, pages) <- parseBody remaining [] Nothing
    Right
      OwnedResourceTagObservation
        { ownedResourceTagObservationQuery = query
        , ownedResourceTagObservationEntries = entries
        , ownedResourceTagObservationPages = pages
        }

parseQueryLine
  :: Text -> Either OwnedResourceTagEvidenceError OwnedResourceTagQueryEcho
parseQueryLine line = case Text.splitOn separator line of
  ["query", "key", key]
    | not (Text.null key) -> Right (OwnedResourceTagKeyEcho key)
  ["query", "pair", key, value]
    | not (Text.null key) -> Right (OwnedResourceTagPairEcho key value)
  _ -> Left (OwnedResourceTagQueryLineInvalid line)

-- | Accumulate resource rows until the completion terminator.  Anything after
-- the terminator, and evidence with no terminator at all, is refused.
parseBody
  :: [Text]
  -> [(Text, [(Text, Text)])]
  -> Maybe Natural
  -> Either OwnedResourceTagEvidenceError ([OwnedResourceTagEntry], Natural)
parseBody [] accumulated pages = case pages of
  Nothing -> Left OwnedResourceTagEvidenceIncomplete
  Just consumed -> Right (map toEntry (reverse accumulated), consumed)
 where
  toEntry (arn, tags) = OwnedResourceTagEntry arn (reverse tags)
parseBody (line : remaining) accumulated pages = case pages of
  Just _ -> Left (OwnedResourceTagResourceLineInvalid line)
  Nothing -> case Text.splitOn separator line of
    ["complete", count] -> case readMaybe (Text.unpack count) :: Maybe Natural of
      Just parsed -> parseBody remaining accumulated (Just parsed)
      Nothing -> Left (OwnedResourceTagCompletionLineInvalid line)
    ["resource", arn]
      | not (Text.null arn) ->
          parseBody remaining (addResource arn Nothing accumulated) Nothing
    ["resource", arn, key, value]
      | not (Text.null arn) && not (Text.null key) ->
          parseBody remaining (addResource arn (Just (key, value)) accumulated) Nothing
    _ -> Left (OwnedResourceTagResourceLineInvalid line)

addResource
  :: Text
  -> Maybe (Text, Text)
  -> [(Text, [(Text, Text)])]
  -> [(Text, [(Text, Text)])]
addResource arn tag accumulated = case accumulated of
  (existingArn, tags) : rest
    | existingArn == arn -> (existingArn, maybe tags (: tags) tag) : rest
  _ -> (arn, maybe [] pure tag) : accumulated
