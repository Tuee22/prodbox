{-# LANGUAGE OverloadedStrings #-}

-- | Derive the SES SMTP password from an IAM access-key secret per AWS's published
-- IAM-to-SMTP-credentials algorithm. The output is the literal string injected into
-- Keycloak's `KC_SMTP_PASSWORD` environment variable; SES authenticates SMTP sessions
-- against `(smtp_iam_access_key_id, derived_password)`.
--
-- Algorithm (from
-- <https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html>):
--   1. Compute an AWS SigV4 signing key with the fixed date `11111111`, the configured
--      AWS region, the service name `ses`, and the terminator `aws4_request`.
--   2. Sign the action string `SendRawEmail` with that signing key.
--   3. Prepend the version byte `0x04` to the resulting 32-byte signature.
--   4. Base64-encode the 33-byte (version + signature) sequence.
module Prodbox.Ses.SmtpPassword
  ( derivedSesSmtpPassword
  )
where

import Crypto.Hash.SHA256 (hmac)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)

derivedSesSmtpPassword :: Text -> Text -> Text
derivedSesSmtpPassword region secretAccessKey =
  TextEncoding.decodeUtf8 (Base64.encode versionedSignature)
 where
  versionedSignature :: ByteString
  versionedSignature = BS.cons sesSmtpPasswordVersion signature

  signature :: ByteString
  signature = hmac signingKey messageBytes

  signingKey :: ByteString
  signingKey =
    foldl
      hmac
      (BS.append (BS8.pack "AWS4") (TextEncoding.encodeUtf8 secretAccessKey))
      [dateBytes, regionBytes, serviceBytes, terminatorBytes]

  dateBytes :: ByteString
  dateBytes = BS8.pack sesSmtpPasswordDate

  regionBytes :: ByteString
  regionBytes = TextEncoding.encodeUtf8 (Text.strip region)

  serviceBytes :: ByteString
  serviceBytes = BS8.pack sesSmtpPasswordService

  terminatorBytes :: ByteString
  terminatorBytes = BS8.pack sesSmtpPasswordTerminator

  messageBytes :: ByteString
  messageBytes = BS8.pack sesSmtpPasswordAction

sesSmtpPasswordVersion :: Word8
sesSmtpPasswordVersion = 0x04

sesSmtpPasswordDate :: String
sesSmtpPasswordDate = "11111111"

sesSmtpPasswordService :: String
sesSmtpPasswordService = "ses"

sesSmtpPasswordTerminator :: String
sesSmtpPasswordTerminator = "aws4_request"

sesSmtpPasswordAction :: String
sesSmtpPasswordAction = "SendRawEmail"
