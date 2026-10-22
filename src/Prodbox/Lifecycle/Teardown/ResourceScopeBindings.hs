{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Public resource coordinates retained with a cleanup run. Configuration
-- changes and a fresh invocation must not change the field an adopted run owns.
-- Closed coordinate codecs validate before construction. ScopeCodec embeds
-- this one representation in every durable scope and identity.
module Prodbox.Lifecycle.Teardown.ResourceScopeBindings
  ( ResourceScopeBindings
  , emptyResourceScopeBindings
  , mkResourceScopeBindings
  , mkResourceScopeBindingsWithAudit
  , resourceScopeAuditRetainedNames
  , resourceScopeHomeDns01
  , resourceScopeInviteMail
  , HomeDns01Scope
  , mkHomeDns01Scope
  , mkHomeDns01ScopeForRecords
  , homeDns01HostedZone
  , homeDns01RecordNames
  , InviteMailScope
  , InviteMailSelector (..)
  , mkInviteMailScope
  , inviteMailBucket
  , inviteMailSelector
  , inviteMailRecipientMatches
  , homeDns01ScopeWireText
  , homeDns01ScopeFromWireText
  , inviteMailScopeWireText
  , inviteMailScopeFromWireText
  , ResourceScopeBindingError (..)
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise (Serialise (..), deserialiseOrFail, serialise)
import Control.Monad (replicateM, unless)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isControl, isDigit)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Capacity.Dns01CleanupBudget (dns01CleanupMaximumRecordNames)
import Prodbox.Lifecycle.DnsRecord
  ( HostedZoneId
  , dns01ChallengeRecordName
  , hostedZoneIdText
  , mkHostedZoneId
  )
import Prodbox.Lifecycle.Teardown.RetainedNames (RetainedNameBinding)
import Prodbox.Settings.Coordinate (S3BucketName, mkS3BucketName, s3BucketNameText)
import Prodbox.Tls.CertScope (fqdnText, mkFqdn)

data ResourceScopeBindings = ResourceScopeBindings
  { resourceScopeHomeDns01 :: !(Maybe HomeDns01Scope)
  , resourceScopeInviteMail :: !(Maybe InviteMailScope)
  , resourceScopeAuditRetainedNames :: !(Maybe RetainedNameBinding)
  }
  deriving stock (Eq, Ord, Show)

data HomeDns01Scope = HomeDns01Scope
  { homeDns01HostedZone :: !HostedZoneId
  , homeDns01RecordNames :: !(NonEmpty Text)
  }
  deriving stock (Eq, Ord, Show)

data InviteMailSelector
  = ExactInviteRecipient !Text
  | ValidationInviteDomain !Text
  deriving stock (Eq, Ord, Show)

data InviteMailScope = InviteMailScope
  { inviteMailBucket :: !S3BucketName
  , inviteMailSelector :: !InviteMailSelector
  }
  deriving stock (Eq, Ord, Show)

data ResourceScopeBindingError
  = HomeDns01RecordInvalid
  | HomeDns01RecordSetTooLarge !Int !Int
  | InviteMailRecipientInvalid
  | InviteMailDomainInvalid
  deriving stock (Eq, Show)

emptyResourceScopeBindings :: ResourceScopeBindings
emptyResourceScopeBindings = ResourceScopeBindings Nothing Nothing Nothing

mkResourceScopeBindings :: Maybe HomeDns01Scope -> Maybe InviteMailScope -> ResourceScopeBindings
mkResourceScopeBindings home mail = ResourceScopeBindings home mail Nothing

mkResourceScopeBindingsWithAudit
  :: Maybe HomeDns01Scope -> Maybe InviteMailScope -> RetainedNameBinding -> ResourceScopeBindings
mkResourceScopeBindingsWithAudit home mail names = ResourceScopeBindings home mail (Just names)

mkHomeDns01Scope
  :: HostedZoneId -> NonEmpty Text -> Either ResourceScopeBindingError HomeDns01Scope
mkHomeDns01Scope zone certificateNames = do
  records <- traverse recordForCertificate certificateNames
  mkHomeDns01ScopeForRecords zone records
 where
  recordForCertificate raw = do
    let name = maybe raw id (Text.stripPrefix "*." raw)
    parsed <- either (const (Left HomeDns01RecordInvalid)) Right (mkFqdn name)
    Right (dns01ChallengeRecordName parsed <> ".")

mkHomeDns01ScopeForRecords
  :: HostedZoneId -> NonEmpty Text -> Either ResourceScopeBindingError HomeDns01Scope
mkHomeDns01ScopeForRecords zone rawRecords = do
  normalized <- traverse normalizeRecord rawRecords
  let records = sort (nub (NonEmpty.toList normalized))
      count = length records
  if count > dns01CleanupMaximumRecordNames
    then Left (HomeDns01RecordSetTooLarge count dns01CleanupMaximumRecordNames)
    else case records of
      [] -> Left HomeDns01RecordInvalid
      first : rest -> Right (HomeDns01Scope zone (first :| rest))
 where
  normalizeRecord raw = do
    if Text.any isControl raw then Left HomeDns01RecordInvalid else Right ()
    suffix <-
      maybe
        (Left HomeDns01RecordInvalid)
        Right
        (Text.stripPrefix "_acme-challenge." (Text.toLower (Text.strip raw)))
    fqdn <-
      either
        (const (Left HomeDns01RecordInvalid))
        Right
        (mkFqdn (Text.dropWhileEnd (== '.') suffix))
    let record = dns01ChallengeRecordName fqdn <> "."
    if Text.length record > 254
      then Left HomeDns01RecordInvalid
      else Right record

mkInviteMailScope
  :: S3BucketName -> InviteMailSelector -> Either ResourceScopeBindingError InviteMailScope
mkInviteMailScope bucket selector =
  InviteMailScope bucket <$> case selector of
    ExactInviteRecipient recipient -> do
      (local, domain) <- splitInviteRecipient recipient
      canonicalDomain <- normalizeDomain InviteMailRecipientInvalid domain
      let address = local <> "@" <> canonicalDomain
      if Text.length address > 254
        then Left InviteMailRecipientInvalid
        else Right (ExactInviteRecipient address)
    ValidationInviteDomain domain ->
      ValidationInviteDomain <$> normalizeDomain InviteMailDomainInvalid domain

inviteMailRecipientMatches :: InviteMailScope -> Text -> Bool
inviteMailRecipientMatches scope recipient = case splitInviteRecipient recipient of
  Left _ -> False
  Right (local, domain) -> case normalizeDomain InviteMailRecipientInvalid domain of
    Left _ -> False
    Right canonicalDomain -> case inviteMailSelector scope of
      ExactInviteRecipient expected -> local <> "@" <> canonicalDomain == expected
      ValidationInviteDomain expected -> canonicalDomain == expected

splitInviteRecipient :: Text -> Either ResourceScopeBindingError (Text, Text)
splitInviteRecipient recipient = case Text.splitOn "@" recipient of
  [local, domain] -> do
    nonce <- maybe (Left InviteMailRecipientInvalid) Right (Text.stripPrefix "test-" local)
    if Text.null nonce || Text.length local > 64 || not (Text.all hexadecimal nonce)
      then Left InviteMailRecipientInvalid
      else Right (local, domain)
  _ -> Left InviteMailRecipientInvalid
 where
  hexadecimal character = isDigit character || (isAsciiLower character && character <= 'f')

normalizeDomain :: ResourceScopeBindingError -> Text -> Either ResourceScopeBindingError Text
normalizeDomain failure raw
  | Text.any isControl raw = Left failure
  | otherwise = either (const (Left failure)) (Right . fqdnText) (mkFqdn raw)

-- These same constructor bodies serve standalone Provider coordinates and the
-- optional fields of a durable resource binding. No second wire projection is
-- allowed to reconstruct a normalized value from noncanonical stored bytes.
instance Serialise HomeDns01Scope where
  encode scope = Cbor.encodeListLen 2 <> encodeHomeBody scope
  decode = do
    count <- Cbor.decodeListLen
    unless (count == 2) (fail "home DNS01 scope shape")
    decodeHomeBody

instance Serialise InviteMailScope where
  encode scope = Cbor.encodeListLen 3 <> encodeMailBody scope
  decode = do
    count <- Cbor.decodeListLen
    unless (count == 3) (fail "invite mail scope shape")
    decodeMailBody

instance Serialise ResourceScopeBindings where
  encode bindings =
    Cbor.encodeListLen (if hasAudit then 4 else 3)
      <> Cbor.encodeWord (if hasAudit then 1 else 0)
      <> maybe (Cbor.encodeListLen 0) encode (resourceScopeHomeDns01 bindings)
      <> maybe (Cbor.encodeListLen 0) encode (resourceScopeInviteMail bindings)
      <> maybe mempty encode (resourceScopeAuditRetainedNames bindings)
   where
    hasAudit = case resourceScopeAuditRetainedNames bindings of
      Nothing -> False
      Just _ -> True
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    format <- case (fields, tag :: Word) of
      (3, 0) -> pure CoordinatesOnly
      (4, 1) -> pure CoordinatesWithAudit
      _ -> fail "resource scope bindings format"
    home <- decodeOptional 2 decodeHomeBody
    mail <- decodeOptional 3 decodeMailBody
    names <- case format of
      CoordinatesOnly -> pure Nothing
      CoordinatesWithAudit -> Just <$> decode
    pure (ResourceScopeBindings home mail names)

data ResourceBindingWireFormat = CoordinatesOnly | CoordinatesWithAudit

encodeHomeBody :: HomeDns01Scope -> Cbor.Encoding
encodeHomeBody scope =
  encode (hostedZoneIdText (homeDns01HostedZone scope))
    <> Cbor.encodeListLen (fromIntegral (NonEmpty.length (homeDns01RecordNames scope)))
    <> foldMap encode (homeDns01RecordNames scope)

decodeHomeBody :: Cbor.Decoder s HomeDns01Scope
decodeHomeBody = do
  zoneText <- decode
  count <- Cbor.decodeListLen
  unless
    (count >= 1 && count <= dns01CleanupMaximumRecordNames)
    (fail "resource scope DNS01 record count")
  names <- replicateM count decode
  zone <- either (fail . show) pure (mkHostedZoneId zoneText)
  selected <- maybe (fail "empty DNS01 names") pure (NonEmpty.nonEmpty names)
  scope <- either (fail . show) pure (mkHomeDns01ScopeForRecords zone selected)
  unless
    (hostedZoneIdText zone == zoneText && NonEmpty.toList (homeDns01RecordNames scope) == names)
    (fail "noncanonical DNS01 coordinates")
  pure scope

encodeMailBody :: InviteMailScope -> Cbor.Encoding
encodeMailBody scope =
  encode (s3BucketNameText (inviteMailBucket scope))
    <> encode (selectorTag (inviteMailSelector scope))
    <> encode (selectorText (inviteMailSelector scope))

decodeMailBody :: Cbor.Decoder s InviteMailScope
decodeMailBody = do
  bucketText <- decode
  tag <- decode
  selected <- decode
  bucket <- either (fail . show) pure (mkS3BucketName bucketText)
  selector <- case (tag :: Int) of
    0 -> pure (ExactInviteRecipient selected)
    1 -> pure (ValidationInviteDomain selected)
    _ -> fail "unknown invite selector"
  scope <- either (fail . show) pure (mkInviteMailScope bucket selector)
  unless
    (s3BucketNameText bucket == bucketText && inviteMailSelector scope == selector)
    (fail "noncanonical invite coordinates")
  pure scope

decodeOptional :: Int -> Cbor.Decoder s value -> Cbor.Decoder s (Maybe value)
decodeOptional expected decoder = do
  count <- Cbor.decodeListLen
  case count of
    0 -> pure Nothing
    _ | count == expected -> Just <$> decoder
    _ -> fail "resource scope optional coordinate shape"

selectorTag :: InviteMailSelector -> Int
selectorTag selector = case selector of
  ExactInviteRecipient _ -> 0
  ValidationInviteDomain _ -> 1

selectorText :: InviteMailSelector -> Text
selectorText selector = case selector of
  ExactInviteRecipient value -> value
  ValidationInviteDomain value -> value

homeDns01ScopeWireText :: HomeDns01Scope -> Text
homeDns01ScopeWireText = coordinateWireText

homeDns01ScopeFromWireText :: Text -> Either Text HomeDns01Scope
homeDns01ScopeFromWireText = coordinateFromWireText

inviteMailScopeWireText :: InviteMailScope -> Text
inviteMailScopeWireText = coordinateWireText

inviteMailScopeFromWireText :: Text -> Either Text InviteMailScope
inviteMailScopeFromWireText = coordinateFromWireText

coordinateWireText :: (Serialise value) => value -> Text
coordinateWireText = TextEncoding.decodeUtf8 . Base64.encode . LazyByteString.toStrict . serialise

coordinateFromWireText :: (Serialise value) => Text -> Either Text value
coordinateFromWireText encoded = do
  unless (Text.length encoded <= 8192) (Left "cleanup coordinate exceeds its wire bound")
  bytes <-
    either
      (const (Left "cleanup coordinate base64 is invalid"))
      Right
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  value <-
    either
      (const (Left "cleanup coordinate is malformed"))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless (coordinateWireText value == encoded) (Left "cleanup coordinate is noncanonical")
  Right value
