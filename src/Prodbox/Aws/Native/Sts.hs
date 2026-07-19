{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (STS): native @AssumeRole@ (query protocol, XML
-- response). The interpreter takes a 'BaseCredentialHandle' and yields a
-- 'SessionCredentialHandle' carrying the TEMPORARY credentials — a distinct
-- handle. There is no exported base→session widening; 'mkSessionCredentialHandle'
-- is called only here, so base→session is non-convertible by construction.
--
-- Downstream (NOTE, not 1.62 work): replaces @LeaseRuntime.hs@'s @runAwsAssumeRole@
-- / @sts get-caller-identity@ CLI sites.
module Prodbox.Aws.Native.Sts
  ( StsClient (..)
  , AssumeRoleRequest (..)
  , AssumeRoleCredentials (..)
  , newStsClient
  , stsEndpoint
  , stsScope
  , encodeAssumeRoleForm
  , signAssumeRoleRequest
  , parseAssumeRoleResponse
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Numeric.Natural (Natural)
import Prodbox.Aws.CredentialHandle
  ( BaseCredentialHandle
  , CredentialError
  , SecretString (SecretString)
  , SessionCredentialHandle
  , credentialHandleRegion
  , credentialHandleSecurityToken
  , mkSessionCredentialHandle
  , toSigV4Credentials
  , unSecret
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsResponseParseFailure)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsTimestamp
  , Idempotency (Idempotent)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , formContentType
  , performAwsRequest
  , renderFormBody
  )
import Prodbox.Aws.Native.Xml (extractFirst)

data AssumeRoleRequest = AssumeRoleRequest
  { assumeRoleArn :: !Text
  , assumeRoleSessionName :: !Text
  , assumeRoleDurationSeconds :: !Natural
  }
  deriving (Eq, Show)

-- | The parsed temporary credentials (redacting 'Show' via 'SecretString').
data AssumeRoleCredentials = AssumeRoleCredentials
  { arcAccessKeyId :: !ByteString
  , arcSecret :: !SecretString
  , arcToken :: !SecretString
  , arcExpiration :: !Text
  }
  deriving (Eq, Show)

newtype StsClient = StsClient
  { assumeRole :: AssumeRoleRequest -> IO (Either AwsClientError SessionCredentialHandle)
  }

newStsClient :: BaseCredentialHandle -> NativeAwsSender -> StsClient
newStsClient handle sender = StsClient {assumeRole = runAssumeRole handle sender}

stsEndpoint :: ByteString -> AwsEndpoint
stsEndpoint region =
  AwsEndpoint
    ("https://sts." <> BS8.unpack region <> ".amazonaws.com")
    ("sts." <> region <> ".amazonaws.com")

stsScope :: ByteString -> AwsScope
stsScope region = AwsScope region "sts"

encodeAssumeRoleForm :: AssumeRoleRequest -> [(ByteString, ByteString)]
encodeAssumeRoleForm req =
  [ ("Action", "AssumeRole")
  , ("Version", "2011-06-15")
  , ("RoleArn", encodeUtf8 (assumeRoleArn req))
  , ("RoleSessionName", encodeUtf8 (assumeRoleSessionName req))
  , ("DurationSeconds", BS8.pack (show (assumeRoleDurationSeconds req)))
  ]

signAssumeRoleRequest
  :: BaseCredentialHandle -> AwsTimestamp -> AssumeRoleRequest -> SignedHttpRequest
signAssumeRoleRequest handle ts req =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    (stsScope region)
    (stsEndpoint region)
    ts
    "POST"
    "/"
    []
    (renderFormBody (encodeAssumeRoleForm req))
    formContentType
 where
  region = credentialHandleRegion handle

parseAssumeRoleResponse :: ByteString -> Either String AssumeRoleCredentials
parseAssumeRoleResponse body = do
  creds <-
    note "AssumeRole: missing <Credentials>" (extractFirst "<Credentials>" "</Credentials>" body)
  akid <- element "AccessKeyId" creds
  secret <- element "SecretAccessKey" creds
  token <- element "SessionToken" creds
  expiry <- element "Expiration" creds
  pure (AssumeRoleCredentials akid (SecretString secret) (SecretString token) (decodeUtf8 expiry))
 where
  element name hay =
    note
      ("AssumeRole: missing <" ++ name ++ ">")
      (extractFirst (BS8.pack ("<" ++ name ++ ">")) (BS8.pack ("</" ++ name ++ ">")) hay)

runAssumeRole
  :: BaseCredentialHandle
  -> NativeAwsSender
  -> AssumeRoleRequest
  -> IO (Either AwsClientError SessionCredentialHandle)
runAssumeRole handle sender req = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signAssumeRoleRequest handle ts req)
      "sts:AssumeRole"
      Idempotent
      XmlErrorFormat
  pure $ do
    body <- raw
    arc <- first AwsResponseParseFailure (parseAssumeRoleResponse body)
    first
      credentialErrorToClient
      ( mkSessionCredentialHandle
          (arcAccessKeyId arc)
          (unSecret (arcSecret arc))
          (unSecret (arcToken arc))
          (credentialHandleRegion handle)
      )

credentialErrorToClient :: CredentialError -> AwsClientError
credentialErrorToClient err =
  AwsResponseParseFailure ("AssumeRole returned unusable credentials: " ++ show err)

note :: String -> Maybe a -> Either String a
note message = maybe (Left message) Right
