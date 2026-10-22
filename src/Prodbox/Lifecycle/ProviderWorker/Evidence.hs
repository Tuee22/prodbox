{-# LANGUAGE OverloadedStrings #-}

-- | The one canonical provider-evidence codec.  Sprint @4.99@.
--
-- Six families each rendered their own wire format before this module, in three
-- different source files, none derived from a shared writer and none aware of
-- the rule the Provider Worker applies on the way out.  All six emitted a
-- character at or below @0x1f@, which that rule refuses, so three of them could
-- never settle and three settled only when they had nothing to report.  The
-- grammar here is the replacement, and it is one renderer and one parser so the
-- two ends cannot drift.
--
-- The grammar, in full:
--
-- > <prefix>/v2:absent
-- > <prefix>/v2:present:<row>[,<row>]*        row = <field>[|<field>]*
--
-- Four properties are load-bearing and each answers a way the superseded
-- encodings failed.
--
-- * __Printable.__  Fields are percent-escaped for @%@, @,@ and @|@ and refuse
--   any character at or below @0x1f@ or equal to @0x7f@.  Escaping is
--   unconditional rather than per-family: a family-specific switch is one more
--   thing to get wrong, and the families with closed alphabets render
--   identically either way.
--
-- * __Absence is stated.__  An empty row set renders as @absent@ and a
--   @present:@ arm carrying nothing is refused.  A short listing and a listing
--   of nothing are different facts
--   (@lifecycle_reconciliation_doctrine.md § 3.0@).
--
-- * __Canonical.__  Rows are sorted and deduplicated by the encoder, and a
--   decoder refuses bytes that are not.  One observation therefore renders to
--   exactly one string, which is what makes the Authority's byte-equality
--   replay comparison safe rather than merely tidy.
--
-- * __Bounded from one number.__  A family declares how many rows it admits and
--   how long a row may be; the character bound follows from those.  No codec
--   authors a size the wire does not also use.
--
-- Version retirement follows the rule stated for the ownership manifest: a
-- decoder accepts exactly the prefix its own build writes and refuses an older
-- one __by name__ rather than upgrading it.
module Prodbox.Lifecycle.ProviderWorker.Evidence
  ( ProviderEvidence
  , ProviderEvidenceBound
  , ProviderEvidenceFamily
  , ProviderEvidenceRefusal (..)
  , maximumStackPreviewEvidenceBytes
  , providerEvidenceFamily
  , providerEvidenceFamilyBound
  , providerEvidenceFamilyOwnBound
  , decodeProviderEvidenceText
  , providerEvidenceText
  , encodeProviderEvidence
  , decodeProviderEvidence
  , providerEvidenceFromWire
  , providerEvidenceFromWireText
  , renderProviderEvidenceRefusal
  , providerEvidenceVersion
  )
where

import Data.Bifunctor (first)
import Data.Char (isHexDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.ProviderWorker.Evidence.Internal

-- Names-only previews may exceed the short observation bound. This byte
-- ceiling also bounds character count and leaves room in the 64 KiB reply.
maximumStackPreviewEvidenceBytes :: Int
maximumStackPreviewEvidenceBytes = 32 * 1024

-- | The version every family carries.  Families move together when the grammar
-- changes, including families whose existing bytes were already legal: a reader
-- that accepted two spellings of absence would be carrying exactly the drift
-- this codec removes.
providerEvidenceVersion :: Text
providerEvidenceVersion = "v2"

-- | Declare a family.  @maximumRows@ and @maximumRowCharacters@ are the only
-- sizes a family states; its character bound is derived from them by
-- 'providerEvidenceFamilyBound'.
providerEvidenceFamily :: Text -> Int -> Int -> ProviderEvidenceFamily
providerEvidenceFamily prefix maximumRows maximumRowCharacters =
  ProviderEvidenceFamily
    { providerEvidenceFamilyPrefix = prefix
    , providerEvidenceFamilyMaximumRows = max 0 maximumRows
    , providerEvidenceFamilyMaximumRowCharacters = max 1 maximumRowCharacters
    }

-- | The longest evidence this family can render: the header, every admitted row
-- at its longest, and one separator between each pair.  A family whose derived
-- bound exceeds the intent's bound cannot settle, which is the arithmetic the
-- superseded encoders never did.
providerEvidenceFamilyBound :: ProviderEvidenceFamily -> Int
providerEvidenceFamilyBound family =
  Text.length (headerFor family "present:")
    + (rows * perRow)
    + max 0 (rows - 1)
 where
  rows = providerEvidenceFamilyMaximumRows family
  perRow = providerEvidenceFamilyMaximumRowCharacters family

headerFor :: ProviderEvidenceFamily -> Text -> Text
headerFor family arm =
  providerEvidenceFamilyPrefix family <> "/" <> providerEvidenceVersion <> ":" <> arm

-- | The bound a family imposes on itself.
--
-- A decoder uses this rather than the intent's bound, because a family that
-- declares what it can carry has already said what it will accept; the
-- registered-families test asserts this is never wider than the wire.
providerEvidenceFamilyOwnBound :: ProviderEvidenceFamily -> ProviderEvidenceBound
providerEvidenceFamilyOwnBound = ProviderEvidenceBound . providerEvidenceFamilyBound

-- | Decode bytes that crossed a process boundary, re-applying the wire rules
-- first.  The refusal is rendered, for callers that carry text.
decodeProviderEvidenceText
  :: ProviderEvidenceFamily -> Text -> Either Text [[Text]]
decodeProviderEvidenceText family value =
  first renderProviderEvidenceRefusal $ do
    evidence <- providerEvidenceFromWire (providerEvidenceFamilyOwnBound family) value
    decodeProviderEvidence family evidence

-- | The total projection.  Deliberately the only way out: a caller that holds
-- evidence can render it, and cannot take it apart any other way.
providerEvidenceText :: ProviderEvidence -> Text
providerEvidenceText (ProviderEvidence value) = value

-- | Render rows for a family against the bound of the intent being served.
encodeProviderEvidence
  :: ProviderEvidenceBound
  -> ProviderEvidenceFamily
  -> [[Text]]
  -> Either ProviderEvidenceRefusal ProviderEvidence
encodeProviderEvidence bound family rows
  | length canonical > providerEvidenceFamilyMaximumRows family =
      Left
        ( ProviderEvidenceOverCardinality
            (length canonical)
            (providerEvidenceFamilyMaximumRows family)
        )
  | otherwise = do
      rendered <- traverse renderRow canonical
      let body =
            case rendered of
              [] -> headerFor family "absent"
              _ -> headerFor family "present:" <> Text.intercalate "," rendered
      withinBound bound body
 where
  canonical = dedupe (sort rows)
  renderRow fields = Text.intercalate "|" <$> traverse escapeField fields

-- | Recover the rows a family's evidence carries.
decodeProviderEvidence
  :: ProviderEvidenceFamily
  -> ProviderEvidence
  -> Either ProviderEvidenceRefusal [[Text]]
decodeProviderEvidence family (ProviderEvidence value)
  | value == headerFor family "absent" = Right []
  | Just body <- Text.stripPrefix (headerFor family "present:") value = do
      let rendered = Text.splitOn "," body
      if null rendered || any Text.null rendered
        then Left (ProviderEvidenceEmptyRowSet (providerEvidenceFamilyPrefix family))
        else Right ()
      if length rendered > providerEvidenceFamilyMaximumRows family
        then
          Left
            ( ProviderEvidenceOverCardinality
                (length rendered)
                (providerEvidenceFamilyMaximumRows family)
            )
        else Right ()
      rows <- traverse decodeRow rendered
      if rows == dedupe (sort rows)
        then Right rows
        else Left (ProviderEvidenceNotCanonical (providerEvidenceFamilyPrefix family))
  | Just found <- retiredVersion family value =
      Left (ProviderEvidenceRetiredVersion found providerEvidenceVersion)
  | otherwise = Left (ProviderEvidenceUnsupportedEncoding (providerEvidenceFamilyPrefix family))
 where
  decodeRow rendered = traverse unescapeField (Text.splitOn "|" rendered)

-- | Re-derive evidence from bytes that crossed a process boundary.  The rules
-- are re-applied rather than assumed, because past that boundary the value has
-- left the region its type covered.
providerEvidenceFromWire
  :: ProviderEvidenceBound -> Text -> Either ProviderEvidenceRefusal ProviderEvidence
providerEvidenceFromWire bound value
  | Text.null value = Left ProviderEvidenceEmpty
  | otherwise = withinBound bound value

-- | 'providerEvidenceFromWire' with the refusal already rendered, for callers
-- that carry text rather than a constructor.  The wire boundary and every fake
-- standing in for one use this, so a stub cannot admit bytes production would
-- refuse.
providerEvidenceFromWireText
  :: ProviderEvidenceBound -> Text -> Either Text ProviderEvidence
providerEvidenceFromWireText bound =
  first renderProviderEvidenceRefusal . providerEvidenceFromWire bound

withinBound :: ProviderEvidenceBound -> Text -> Either ProviderEvidenceRefusal ProviderEvidence
withinBound (ProviderEvidenceBound maximumCharacters) value
  | Text.null value = Left ProviderEvidenceEmpty
  | Text.length value > maximumCharacters =
      Left (ProviderEvidenceOverBound (Text.length value) maximumCharacters)
  | Text.any control value = Left ProviderEvidenceControlCharacter
  | otherwise = Right (ProviderEvidence value)
 where
  control character = character <= '\x1f' || character == '\x7f'

-- | A value that names this family at some other version.  Reported by name so
-- an operator reading a refusal learns which build wrote the bytes.
retiredVersion :: ProviderEvidenceFamily -> Text -> Maybe Text
retiredVersion family value = do
  rest <- Text.stripPrefix (providerEvidenceFamilyPrefix family <> "/") value
  let found = Text.takeWhile (/= ':') rest
  if Text.null found || found == providerEvidenceVersion
    then Nothing
    else Just found

escapeField :: Text -> Either ProviderEvidenceRefusal Text
escapeField field
  | Text.any control field = Left ProviderEvidenceControlCharacter
  | otherwise = Right (Text.concatMap escapeCharacter field)
 where
  control character = character <= '\x1f' || character == '\x7f'
  escapeCharacter character = case character of
    '%' -> "%25"
    ',' -> "%2C"
    '|' -> "%7C"
    _ -> Text.singleton character

unescapeField :: Text -> Either ProviderEvidenceRefusal Text
unescapeField field = go field
 where
  go remaining = case Text.uncons remaining of
    Nothing -> Right Text.empty
    Just ('%', rest)
      | Text.length rest >= 2
      , let digits = Text.take 2 rest
      , Text.all isCanonicalHexDigit digits
      , Just character <- decodeHexPair digits ->
          Text.cons character <$> go (Text.drop 2 rest)
      | otherwise -> Left (ProviderEvidenceMalformedEscape field)
    Just (character, rest) -> Text.cons character <$> go rest
  isCanonicalHexDigit character = isHexDigit character && not (isLowerHexLetter character)
  isLowerHexLetter character = character `elem` ("abcdef" :: String)

decodeHexPair :: Text -> Maybe Char
decodeHexPair digits =
  case [character | (character, escaped) <- escapes, escaped == digits] of
    [character] -> Just character
    _ -> Nothing
 where
  escapes = [('%', "25"), (',', "2C"), ('|', "7C")]

dedupe :: (Eq value) => [value] -> [value]
dedupe values = case values of
  [] -> []
  value : rest -> value : dedupe (dropWhile (== value) rest)

-- | Render a refusal for a caller that carries text rather than a constructor.
--
-- The first three arms keep the exact wording the superseded validator used, so
-- a refusal a live transcript already contains stays greppable across this
-- change.
renderProviderEvidenceRefusal :: ProviderEvidenceRefusal -> Text
renderProviderEvidenceRefusal refusal = case refusal of
  ProviderEvidenceEmpty -> "the provider returned no evidence"
  ProviderEvidenceOverBound actual maximumCharacters ->
    "provider evidence is "
      <> Text.pack (show actual)
      <> " characters, over the maximum of "
      <> Text.pack (show maximumCharacters)
  ProviderEvidenceControlCharacter -> "provider evidence carries a control character"
  ProviderEvidenceOverCardinality actual maximumRows ->
    "provider evidence carries "
      <> Text.pack (show actual)
      <> " rows, over the maximum of "
      <> Text.pack (show maximumRows)
  ProviderEvidenceRetiredVersion found expected ->
    "provider evidence is version "
      <> found
      <> ", which is retired; this build writes and accepts "
      <> expected
  ProviderEvidenceUnsupportedEncoding prefix ->
    "provider evidence does not carry the " <> prefix <> " encoding"
  ProviderEvidenceEmptyRowSet prefix ->
    "provider evidence states "
      <> prefix
      <> " is present and carries no rows; absence is stated, never implied"
  ProviderEvidenceMalformedEscape field ->
    "provider evidence carries a malformed percent escape in " <> field
  ProviderEvidenceNotCanonical prefix ->
    "provider evidence rows for "
      <> prefix
      <> " are not in canonical order; byte-equal replay depends on one spelling per observation"
