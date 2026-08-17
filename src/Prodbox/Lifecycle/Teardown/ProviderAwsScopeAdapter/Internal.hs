{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Provider-owned canonical evidence codec.  Encoding is intentionally kept
-- behind the package boundary; the public lifecycle adapter can validate
-- evidence produced by the Provider Worker but cannot construct it from raw
-- account/region fields.
module Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal
  ( ProviderAwsScopeEvidenceError (..)
  , maximumProviderAwsScopeEvidenceLength
  , encodeProviderAwsScopeEvidence
  , decodeProviderAwsScopeEvidence
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)

data ProviderAwsScopeEvidenceError
  = ProviderAwsScopeEvidenceTooLarge !Int !Int
  | ProviderAwsScopeEvidencePrefixInvalid
  | ProviderAwsScopeEvidenceBase64Invalid
  | ProviderAwsScopeEvidenceMalformed
  | ProviderAwsScopeEvidenceNonCanonical
  | ProviderAwsScopeEvidenceVersionUnsupported !Word16
  | ProviderAwsScopeEvidenceAccountInvalid
  | ProviderAwsScopeEvidenceRegionInvalid
  deriving stock (Eq, Show)

data WireProviderAwsScopeEvidence = WireProviderAwsScopeEvidence
  { wireProviderAwsScopeEvidenceVersion :: !Word16
  , wireProviderAwsScopeEvidenceAccount :: !Text
  , wireProviderAwsScopeEvidenceRegion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

providerAwsScopeEvidenceVersion :: Word16
providerAwsScopeEvidenceVersion = 1

providerAwsScopeEvidencePrefix :: Text
providerAwsScopeEvidencePrefix = "provider-aws-scope-v1:"

-- | Deliberately much smaller than the generic Provider evidence limit.  The
-- payload contains two bounded identifiers and no credentials or service
-- response body.
maximumProviderAwsScopeEvidenceLength :: Int
maximumProviderAwsScopeEvidenceLength = 512

encodeProviderAwsScopeEvidence
  :: Text
  -> Text
  -> Either ProviderAwsScopeEvidenceError Text
encodeProviderAwsScopeEvidence account region = do
  validateAccount account
  validateRegion region
  let bytes =
        LazyByteString.toStrict
          ( serialise
              WireProviderAwsScopeEvidence
                { wireProviderAwsScopeEvidenceVersion = providerAwsScopeEvidenceVersion
                , wireProviderAwsScopeEvidenceAccount = account
                , wireProviderAwsScopeEvidenceRegion = region
                }
          )
      evidence =
        providerAwsScopeEvidencePrefix
          <> TextEncoding.decodeUtf8 (Base64.encode bytes)
  if Text.length evidence > maximumProviderAwsScopeEvidenceLength
    then
      Left
        ( ProviderAwsScopeEvidenceTooLarge
            (Text.length evidence)
            maximumProviderAwsScopeEvidenceLength
        )
    else Right evidence

decodeProviderAwsScopeEvidence
  :: Text
  -> Either ProviderAwsScopeEvidenceError (Text, Text)
decodeProviderAwsScopeEvidence evidence = do
  if Text.length evidence > maximumProviderAwsScopeEvidenceLength
    then
      Left
        ( ProviderAwsScopeEvidenceTooLarge
            (Text.length evidence)
            maximumProviderAwsScopeEvidenceLength
        )
    else Right ()
  encoded <-
    maybe
      (Left ProviderAwsScopeEvidencePrefixInvalid)
      Right
      (Text.stripPrefix providerAwsScopeEvidencePrefix evidence)
  bytes <-
    either
      (const (Left ProviderAwsScopeEvidenceBase64Invalid))
      Right
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  if Base64.encode bytes == TextEncoding.encodeUtf8 encoded
    then Right ()
    else Left ProviderAwsScopeEvidenceNonCanonical
  if ByteString.length bytes > maximumProviderAwsScopeEvidenceLength
    then
      Left
        ( ProviderAwsScopeEvidenceTooLarge
            (ByteString.length bytes)
            maximumProviderAwsScopeEvidenceLength
        )
    else Right ()
  wire <-
    either
      (const (Left ProviderAwsScopeEvidenceMalformed))
      Right
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  if LazyByteString.toStrict (serialise wire) == bytes
    then Right ()
    else Left ProviderAwsScopeEvidenceNonCanonical
  if wireProviderAwsScopeEvidenceVersion wire == providerAwsScopeEvidenceVersion
    then Right ()
    else
      Left
        ( ProviderAwsScopeEvidenceVersionUnsupported
            (wireProviderAwsScopeEvidenceVersion wire)
        )
  let account = wireProviderAwsScopeEvidenceAccount wire
      region = wireProviderAwsScopeEvidenceRegion wire
  validateAccount account
  validateRegion region
  Right (account, region)

validateAccount :: Text -> Either ProviderAwsScopeEvidenceError ()
validateAccount account
  | Text.length account == 12 && Text.all isAsciiDigit account = Right ()
  | otherwise = Left ProviderAwsScopeEvidenceAccountInvalid

validateRegion :: Text -> Either ProviderAwsScopeEvidenceError ()
validateRegion region
  | Text.length region < 3 || Text.length region > 63 = invalid
  | Text.head region == '-' || Text.last region == '-' = invalid
  | not (Text.all isRegionCharacter region) = invalid
  | length segments < 3 || any Text.null segments = invalid
  | not (Text.all isAsciiDigit (last segments)) = invalid
  | not (any (Text.any isAsciiLower) (init segments)) = invalid
  | otherwise = Right ()
 where
  segments = Text.splitOn "-" region
  invalid = Left ProviderAwsScopeEvidenceRegionInvalid

isRegionCharacter :: Char -> Bool
isRegionCharacter character =
  isAsciiLower character || isAsciiDigit character || character == '-'

isAsciiLower :: Char -> Bool
isAsciiLower character = character >= 'a' && character <= 'z'

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'
