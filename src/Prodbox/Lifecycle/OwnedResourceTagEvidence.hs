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

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( decodeProviderEvidenceText
  , encodeProviderEvidence
  , providerEvidenceFamilyOwnBound
  , providerEvidenceText
  , renderProviderEvidenceRefusal
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ownedResourceTagEvidenceFamily)
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
  = -- | The canonical codec refused the rows, naming the rule that refused.
    -- Sprint @4.99@ replaced a bespoke separator check with this, because the
    -- separators the old check defended were themselves characters the wire
    -- refuses.
    OwnedResourceTagEvidenceRefused !Text
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
  OwnedResourceTagEvidenceRefused detail ->
    "owned-resource tag evidence was refused by the canonical codec: " <> detail
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

-- | Render the audit's answer.  Sprint @4.99@.
--
-- The superseded form delimited with a tab and a newline, both of which
-- 'Prodbox.Lifecycle.ProviderWorker.ProviderWork.validateProviderIntentEvidence'
-- refuses, so this observation could never settle on any AWS cascade -- and the
-- cascade's clean-audit arm was unreachable rather than merely unobserved.  It
-- also declared no bound of any kind, on a listing that follows the provider's
-- pagination to a hundred pages.
--
-- Three properties of the old form are kept exactly, because each answers a way
-- an audit can lie: the query is echoed, so an answer cannot be read as
-- belonging to a wider question; completion is a terminator carrying the page
-- count rather than something a short listing implies; and a resource returned
-- carrying no tags is a two-field row, distinct from a resource not returned at
-- all.
--
-- One property is new.  Rows used to be emitted in the provider's return order,
-- so two identical listings paginated differently produced different bytes --
-- which the Authority's byte-equality replay comparison reads as a mismatch.
-- The canonical ordering removes that, and it fixes the echo and terminator
-- positions as a side effect, since @complete@ and @query@ sort before
-- @resource@.
renderOwnedResourceTagObservation
  :: OwnedResourceTagObservation
  -> Either OwnedResourceTagEvidenceError Text
renderOwnedResourceTagObservation observation =
  first
    (OwnedResourceTagEvidenceRefused . renderProviderEvidenceRefusal)
    ( fmap
        providerEvidenceText
        ( encodeProviderEvidence
            (providerEvidenceFamilyOwnBound ownedResourceTagEvidenceFamily)
            ownedResourceTagEvidenceFamily
            (queryRow : completionRow : concatMap renderEntry entries)
        )
    )
 where
  entries = ownedResourceTagObservationEntries observation
  queryRow = case ownedResourceTagObservationQuery observation of
    OwnedResourceTagKeyEcho key -> ["query", "key", key]
    OwnedResourceTagPairEcho key value -> ["query", "pair", key, value]
  completionRow =
    ["complete", Text.pack (show (ownedResourceTagObservationPages observation))]
  renderEntry entry = case ownedResourceTagEntryTags entry of
    [] -> [["resource", ownedResourceTagEntryArn entry]]
    tags ->
      [ ["resource", ownedResourceTagEntryArn entry, key, value]
      | (key, value) <- tags
      ]

-- | Read the canonical form back.
--
-- Rows naming one ARN merge into one entry.  The canonical ordering makes them
-- contiguous, so that is now a property of the grammar rather than of the order
-- the provider happened to return them in.
parseOwnedResourceTagObservation
  :: Text
  -> Either OwnedResourceTagEvidenceError OwnedResourceTagObservation
parseOwnedResourceTagObservation evidence = do
  rows <-
    first
      OwnedResourceTagEvidenceRefused
      (decodeProviderEvidenceText ownedResourceTagEvidenceFamily evidence)
  query <- case [row | row <- rows, take 1 row == ["query"]] of
    [row] -> parseQueryRow row
    _ -> Left (OwnedResourceTagQueryLineInvalid (flatten rows))
  pages <- case [count | ["complete", count] <- rows] of
    [count] -> case readMaybe (Text.unpack count) :: Maybe Natural of
      Just parsed -> Right parsed
      Nothing -> Left (OwnedResourceTagCompletionLineInvalid count)
    _ -> Left OwnedResourceTagEvidenceIncomplete
  entries <-
    traverse parseResourceRow [row | row <- rows, take 1 row == ["resource"]]
  Right
    OwnedResourceTagObservation
      { ownedResourceTagObservationQuery = query
      , ownedResourceTagObservationEntries = mergeEntries entries
      , ownedResourceTagObservationPages = pages
      }
 where
  flatten rows = Text.intercalate "|" (concat rows)

parseQueryRow
  :: [Text] -> Either OwnedResourceTagEvidenceError OwnedResourceTagQueryEcho
parseQueryRow row = case row of
  ["query", "key", key]
    | not (Text.null key) -> Right (OwnedResourceTagKeyEcho key)
  ["query", "pair", key, value]
    | not (Text.null key) -> Right (OwnedResourceTagPairEcho key value)
  _ -> Left (OwnedResourceTagQueryLineInvalid (Text.intercalate "|" row))

parseResourceRow
  :: [Text] -> Either OwnedResourceTagEvidenceError (Text, Maybe (Text, Text))
parseResourceRow row = case row of
  ["resource", arn]
    | not (Text.null arn) -> Right (arn, Nothing)
  ["resource", arn, key, value]
    | not (Text.null arn) && not (Text.null key) -> Right (arn, Just (key, value))
  _ -> Left (OwnedResourceTagResourceLineInvalid (Text.intercalate "|" row))

-- | Fold the flat rows into one entry per ARN, preserving tag order.
mergeEntries :: [(Text, Maybe (Text, Text))] -> [OwnedResourceTagEntry]
mergeEntries = foldr step []
 where
  step (arn, tag) accumulated = case accumulated of
    OwnedResourceTagEntry existingArn tags : rest
      | existingArn == arn ->
          OwnedResourceTagEntry existingArn (maybe tags (: tags) tag) : rest
    _ -> OwnedResourceTagEntry arn (maybe [] pure tag) : accumulated
