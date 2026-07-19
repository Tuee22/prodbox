{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3 (IAM): native @CreateUser@ \/ @CreateAccessKey@ \/
-- @PutUserPolicy@ (query protocol, XML responses). The interpreter is
-- origin-polymorphic (signs under a base OR a session handle).
--
-- The headline correctness asymmetry: @CreateAccessKey@ is the ONE 'Mutating' op
-- (unrepeatable payload — the secret is returned exactly once). A transport
-- failure whose bytes may have reached AWS, OR a 2xx whose one-time secret cannot
-- be parsed, becomes 'AwsAmbiguousOutcome' — NEVER a false "created" or a blind
-- retry. @CreateUser@\/@PutUserPolicy@ are 'Idempotent'; a parse failure there is
-- an ordinary retry-safe 'AwsResponseParseFailure'.
--
-- Downstream (NOTE, not 1.62 work): replaces @Aws.hs@'s @ensureOperationalIamUser@
-- \/ @installOperationalIamPolicyForConfig@ \/ access-key CLI sites.
module Prodbox.Aws.Native.Iam
  ( IamClient (..)
  , CreateUserResult (..)
  , CreateAccessKeyResult (..)
  , newIamClient
  , iamEndpoint
  , iamScope
  , encodeCreateUserForm
  , encodeCreateAccessKeyForm
  , encodePutUserPolicyForm
  , parseCreateUserResponse
  , parseCreateAccessKeyResponse
  )
where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Prodbox.Aws.CredentialHandle
  ( CredentialHandle
  , SecretString (SecretString)
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Wire
  ( AmbiguityCause (AmbiguousLostResult)
  , AwsClientError (AwsAmbiguousOutcome, AwsResponseParseFailure)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsTimestamp
  , Idempotency (Idempotent, Mutating)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , formContentType
  , performAwsRequest
  , renderFormBody
  )
import Prodbox.Aws.Native.Xml (extractFirst)

data CreateUserResult = CreateUserResult
  { createUserName :: !Text
  , createUserArn :: !Text
  , createUserId :: !Text
  }
  deriving (Eq, Show)

-- | The one-time access key. 'Show' redacts the secret via 'SecretString'.
data CreateAccessKeyResult = CreateAccessKeyResult
  { createdAccessKeyId :: !Text
  , createdSecretAccessKey :: !SecretString
  , createdAccessKeyUser :: !Text
  }
  deriving (Eq, Show)

data IamClient = IamClient
  { createUser :: Text -> IO (Either AwsClientError CreateUserResult)
  , createAccessKey :: Text -> IO (Either AwsClientError CreateAccessKeyResult)
  , putUserInlinePolicy :: Text -> Text -> Text -> IO (Either AwsClientError ())
  }

newIamClient :: CredentialHandle origin -> NativeAwsSender -> IamClient
newIamClient handle sender =
  IamClient
    { createUser = runCreateUser handle sender
    , createAccessKey = runCreateAccessKey handle sender
    , putUserInlinePolicy = runPutUserPolicy handle sender
    }

iamEndpoint :: AwsEndpoint
iamEndpoint = AwsEndpoint "https://iam.amazonaws.com" "iam.amazonaws.com"

-- | IAM is a global service; sign under the fixed @us-east-1@ region.
iamScope :: AwsScope
iamScope = AwsScope "us-east-1" "iam"

encodeCreateUserForm :: Text -> [(ByteString, ByteString)]
encodeCreateUserForm userName =
  [("Action", "CreateUser"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

encodeCreateAccessKeyForm :: Text -> [(ByteString, ByteString)]
encodeCreateAccessKeyForm userName =
  [("Action", "CreateAccessKey"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

encodePutUserPolicyForm :: Text -> Text -> Text -> [(ByteString, ByteString)]
encodePutUserPolicyForm userName policyName policyDocument =
  [ ("Action", "PutUserPolicy")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("PolicyName", encodeUtf8 policyName)
  , ("PolicyDocument", encodeUtf8 policyDocument)
  ]

signIamForm
  :: CredentialHandle origin -> AwsTimestamp -> [(ByteString, ByteString)] -> SignedHttpRequest
signIamForm handle ts pairs =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    iamScope
    iamEndpoint
    ts
    "POST"
    "/"
    []
    (renderFormBody pairs)
    formContentType

parseCreateUserResponse :: ByteString -> Either String CreateUserResult
parseCreateUserResponse body = do
  user <- note "CreateUser: missing <User>" (extractFirst "<User>" "</User>" body)
  name <- elementText "UserName" user
  arn <- elementText "Arn" user
  userId <- elementText "UserId" user
  pure (CreateUserResult name arn userId)

parseCreateAccessKeyResponse :: ByteString -> Either String CreateAccessKeyResult
parseCreateAccessKeyResponse body = do
  accessKey <-
    note "CreateAccessKey: missing <AccessKey>" (extractFirst "<AccessKey>" "</AccessKey>" body)
  keyId <- elementText "AccessKeyId" accessKey
  secret <- elementBytes "SecretAccessKey" accessKey
  userName <- elementText "UserName" accessKey
  pure (CreateAccessKeyResult keyId (SecretString secret) userName)

runCreateUser
  :: CredentialHandle origin -> NativeAwsSender -> Text -> IO (Either AwsClientError CreateUserResult)
runCreateUser handle sender userName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeCreateUserForm userName))
      "iam:CreateUser"
      Idempotent
      XmlErrorFormat
  pure (raw >>= first AwsResponseParseFailure . parseCreateUserResponse)

runCreateAccessKey
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError CreateAccessKeyResult)
runCreateAccessKey handle sender userName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeCreateAccessKeyForm userName))
      "iam:CreateAccessKey"
      Mutating
      XmlErrorFormat
  pure $ case raw of
    Left err -> Left err
    Right body -> case parseCreateAccessKeyResponse body of
      Right result -> Right result
      Left parseError ->
        Left (AwsAmbiguousOutcome (AmbiguousLostResult "iam:CreateAccessKey" (lostSecretDetail parseError)))
 where
  lostSecretDetail parseError =
    "2xx received but the one-time secret could not be parsed; the access key WAS created and its "
      ++ "secret is unrecoverable — reconcile by listing and deleting the orphaned key for user "
      ++ show userName
      ++ ". "
      ++ parseError

runPutUserPolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runPutUserPolicy handle sender userName policyName policyDocument = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodePutUserPolicyForm userName policyName policyDocument))
      "iam:PutUserPolicy"
      Idempotent
      XmlErrorFormat
  pure (void raw)

elementText :: String -> ByteString -> Either String Text
elementText name hay = decodeUtf8 <$> elementBytes name hay

elementBytes :: String -> ByteString -> Either String ByteString
elementBytes name hay =
  note
    ("IAM: missing <" ++ name ++ ">")
    (extractFirst (BS8.pack ("<" ++ name ++ ">")) (BS8.pack ("</" ++ name ++ ">")) hay)

note :: String -> Maybe a -> Either String a
note message = maybe (Left message) Right
