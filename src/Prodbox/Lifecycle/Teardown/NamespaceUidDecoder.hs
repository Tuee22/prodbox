{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Select the first metadata/uid keys, matching the pinned Aeson decoder.
-- Ignored values are fully validated without constructing a Value tree.
module Prodbox.Lifecycle.Teardown.NamespaceUidDecoder (parseNamespaceUid) where

import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens
import Data.ByteString qualified as Bytes
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))

data RootProjection = NotObject | ObjectProjection !(Maybe MetadataProjection)
data MetadataProjection = NotMetadataObject | MetadataObject !(Maybe Text)
data UidProjection = UidUnseen | UidInvalid | UidText !Text

parseNamespaceUid :: Text -> Either ObservationFailure Text
parseNamespaceUid raw =
  root (bsToTokens (Encoding.encodeUtf8 raw)) bad $ \selected remaining ->
    if Bytes.all jsonSpace remaining
      then finish selected
      else bad "Trailing garbage"
 where
  bad detail = Left (ObservationFailure ("Kubernetes namespace document did not parse: " <> Text.pack detail))
  finish selected = case selected of
    NotObject -> Left (ObservationFailure "Kubernetes namespace document was not an object")
    ObjectProjection Nothing -> missingMetadata
    ObjectProjection (Just NotMetadataObject) -> missingMetadata
    ObjectProjection (Just (MetadataObject uid)) -> case uid of
      Just value | not (Text.null value) -> Right value
      _ -> Left (ObservationFailure "Kubernetes namespace document carried no UID")
  missingMetadata = Left (ObservationFailure "Kubernetes namespace document carried no metadata")
  jsonSpace byte = byte == 32 || byte == 10 || byte == 13 || byte == 9

root :: Tokens k e -> (e -> result) -> (RootProjection -> k -> result) -> result
root tokens bad done = case tokens of
  TkRecordOpen pairs -> rootPairs Nothing pairs bad done
  _ -> skip tokens bad (done NotObject)

rootPairs
  :: Maybe MetadataProjection
  -> TkRecord k e
  -> (e -> result)
  -> (RootProjection -> k -> result)
  -> result
rootPairs !selected pairs bad done = case pairs of
  TkPair key tokens -> case selected of
    Nothing | key == "metadata" -> metadata tokens bad $ \value next -> rootPairs (Just value) next bad done
    _ -> skip tokens bad (\next -> rootPairs selected next bad done)
  TkRecordEnd next -> done (ObjectProjection selected) next
  TkRecordErr cause -> bad cause

metadata :: Tokens k e -> (e -> result) -> (MetadataProjection -> k -> result) -> result
metadata tokens bad done = case tokens of
  TkRecordOpen pairs -> metadataPairs UidUnseen pairs bad done
  _ -> skip tokens bad (done NotMetadataObject)

-- A non-string first UID also consumes the first-key slot. A later valid
-- duplicate must not replace it, even though both project to no usable UID.
metadataPairs
  :: UidProjection
  -> TkRecord k e
  -> (e -> result)
  -> (MetadataProjection -> k -> result)
  -> result
metadataPairs !selected pairs bad done = case pairs of
  TkPair key tokens -> case selected of
    UidUnseen | key == "uid" -> case tokens of
      TkText text next -> metadataPairs (UidText text) next bad done
      _ -> skip tokens bad (\next -> metadataPairs UidInvalid next bad done)
    _ -> skip tokens bad (\next -> metadataPairs selected next bad done)
  TkRecordEnd next ->
    let uid = case selected of
          UidUnseen -> Nothing
          UidInvalid -> Nothing
          UidText text -> Just text
     in done (MetadataObject uid) next
  TkRecordErr cause -> bad cause

-- Continuation passing keeps flat arrays/records from retaining their
-- consumed tokens or accumulating an ignored list. Nesting still consumes
-- lexer/continuation state; this is not a constant-memory claim for depth.
skip :: Tokens k e -> (e -> result) -> (k -> result) -> result
skip tokens bad done = case tokens of
  TkLit _ next -> done next
  TkText _ next -> done next
  TkNumber _ next -> done next
  TkArrayOpen values -> skipArray values bad done
  TkRecordOpen pairs -> skipRecord pairs bad done
  TkErr cause -> bad cause

skipArray :: TkArray k e -> (e -> result) -> (k -> result) -> result
skipArray values bad done = case values of
  TkItem tokens -> skip tokens bad (\next -> skipArray next bad done)
  TkArrayEnd next -> done next
  TkArrayErr cause -> bad cause

skipRecord :: TkRecord k e -> (e -> result) -> (k -> result) -> result
skipRecord pairs bad done = case pairs of
  TkPair _ tokens -> skip tokens bad (\next -> skipRecord next bad done)
  TkRecordEnd next -> done next
  TkRecordErr cause -> bad cause
