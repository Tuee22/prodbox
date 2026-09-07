{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (STS): native @AssumeRole@ (query protocol, XML
-- response). The interpreter takes a 'BaseCredentialHandle' and yields a
-- closed 'AssumedRoleSession' carrying the TEMPORARY credentials both as a
-- distinct native handle and as the subprocess projection made from the same
-- STS response. There is no exported base→session widening;
-- 'mkSessionCredentialHandle' is called only here, so base→session is
-- non-convertible by construction.
--
-- Downstream (NOTE, not 1.62 work): replaces @LeaseRuntime.hs@'s @runAwsAssumeRole@
-- / @sts get-caller-identity@ CLI sites.
module Prodbox.Aws.Native.Sts
  ( StsClient (..)
  , AssumeRoleRequest (..)
  , AssumeRoleCredentials (..)
  , AssumedRoleSession
  , assumedRoleSessionHandle
  , assumedRoleSessionCredentials
  , CallerIdentity (..)
  , newStsClient
  , getCallerIdentityForSession
  , stsEndpoint
  , stsScope
  , encodeAssumeRoleForm
  , encodeGetCallerIdentityForm
  , signAssumeRoleRequest
  , parseAssumeRoleResponse
  , parseGetCallerIdentityResponse
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
  , CredentialHandle
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
import Prodbox.Settings (Credentials (..))

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

data CallerIdentity = CallerIdentity
  { callerIdentityAccount :: !Text
  , callerIdentityArn :: !Text
  , callerIdentityUserId :: !Text
  }
  deriving (Eq, Show)

-- | One STS-proven temporary session. The constructor is hidden so a base
-- credential cannot be relabelled as assumed-role material. There is
-- intentionally no 'Show' instance: its subprocess projection contains the
-- temporary secret and token.
data AssumedRoleSession = AssumedRoleSession
  { internalAssumedRoleSessionHandle :: !SessionCredentialHandle
  , internalAssumedRoleSessionCredentials :: !Credentials
  }

assumedRoleSessionHandle :: AssumedRoleSession -> SessionCredentialHandle
assumedRoleSessionHandle = internalAssumedRoleSessionHandle

assumedRoleSessionCredentials :: AssumedRoleSession -> Credentials
assumedRoleSessionCredentials = internalAssumedRoleSessionCredentials

data StsClient = StsClient
  { assumeRole :: AssumeRoleRequest -> IO (Either AwsClientError AssumedRoleSession)
  , getCallerIdentity :: IO (Either AwsClientError CallerIdentity)
  }

newStsClient :: BaseCredentialHandle -> NativeAwsSender -> StsClient
newStsClient handle sender =
  StsClient
    { assumeRole = runAssumeRole handle sender
    , getCallerIdentity = runGetCallerIdentity handle sender
    }

-- | Prove which caller the temporary credentials actually name without
-- widening them back to a base credential.
getCallerIdentityForSession
  :: SessionCredentialHandle
  -> NativeAwsSender
  -> IO (Either AwsClientError CallerIdentity)
getCallerIdentityForSession = runGetCallerIdentity

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

encodeGetCallerIdentityForm :: [(ByteString, ByteString)]
encodeGetCallerIdentityForm =
  [ ("Action", "GetCallerIdentity")
  , ("Version", "2011-06-15")
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

parseGetCallerIdentityResponse :: ByteString -> Either String CallerIdentity
parseGetCallerIdentityResponse body = do
  identity <-
    note
      "GetCallerIdentity: missing <GetCallerIdentityResult>"
      (extractFirst "<GetCallerIdentityResult>" "</GetCallerIdentityResult>" body)
  account <- decodeUtf8 <$> element "Account" identity
  arn <- decodeUtf8 <$> element "Arn" identity
  userId <- decodeUtf8 <$> element "UserId" identity
  pure (CallerIdentity account arn userId)
 where
  element name hay =
    note
      ("GetCallerIdentity: missing <" ++ name ++ ">")
      (extractFirst (BS8.pack ("<" ++ name ++ ">")) (BS8.pack ("</" ++ name ++ ">")) hay)

runAssumeRole
  :: BaseCredentialHandle
  -> NativeAwsSender
  -> AssumeRoleRequest
  -> IO (Either AwsClientError AssumedRoleSession)
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
    sessionHandle <-
      first
        credentialErrorToClient
        ( mkSessionCredentialHandle
            (arcAccessKeyId arc)
            (unSecret (arcSecret arc))
            (unSecret (arcToken arc))
            (credentialHandleRegion handle)
        )
    pure
      AssumedRoleSession
        { internalAssumedRoleSessionHandle = sessionHandle
        , internalAssumedRoleSessionCredentials =
            Credentials
              { access_key_id = decodeUtf8 (arcAccessKeyId arc)
              , secret_access_key = decodeUtf8 (unSecret (arcSecret arc))
              , session_token = Just (decodeUtf8 (unSecret (arcToken arc)))
              , region = decodeUtf8 (credentialHandleRegion handle)
              }
        }

runGetCallerIdentity
  :: CredentialHandle origin
  -> NativeAwsSender
  -> IO (Either AwsClientError CallerIdentity)
runGetCallerIdentity handle sender = do
  raw <-
    performAwsRequest
      sender
      ( \ts ->
          buildSignedRequest
            (toSigV4Credentials handle)
            (credentialHandleSecurityToken handle)
            (stsScope region)
            (stsEndpoint region)
            ts
            "POST"
            "/"
            []
            (renderFormBody encodeGetCallerIdentityForm)
            formContentType
      )
      "sts:GetCallerIdentity"
      Idempotent
      XmlErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseGetCallerIdentityResponse)
 where
  region = credentialHandleRegion handle

credentialErrorToClient :: CredentialError -> AwsClientError
credentialErrorToClient err =
  AwsResponseParseFailure ("AssumeRole returned unusable credentials: " ++ show err)

note :: String -> Maybe a -> Either String a
note message = maybe (Left message) Right
