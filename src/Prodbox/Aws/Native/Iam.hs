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
  , IamUserObservation (..)
  , IamUserPolicyObservation (..)
  , IamRoleObservation (..)
  , IamRolePolicyObservation (..)
  , AccessKeyStatus (..)
  , AccessKeyMetadata (..)
  , IamTag (..)
  , newIamClient
  , iamEndpoint
  , iamScope
  , encodeCreateUserForm
  , encodeGetUserForm
  , encodeCreateAccessKeyForm
  , encodeListAccessKeysForm
  , encodeDeleteAccessKeyForm
  , encodePutUserPolicyForm
  , encodeGetUserPolicyForm
  , encodeDeleteUserPolicyForm
  , encodeDeleteUserForm
  , encodeTagUserForm
  , encodeListUserTagsForm
  , encodeCreateRoleForm
  , encodeGetRoleForm
  , encodeUpdateAssumeRolePolicyForm
  , encodePutRolePolicyForm
  , encodeGetRolePolicyForm
  , encodeDeleteRolePolicyForm
  , encodeDeleteRoleForm
  , parseCreateUserResponse
  , parseGetUserResponse
  , parseCreateAccessKeyResponse
  , parseListAccessKeysResponse
  , parseGetUserPolicyResponse
  , parseListUserTagsResponse
  , parseGetRoleResponse
  , parseGetRolePolicyResponse
  )
where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.HTTP.Types.URI (urlDecode)
import Prodbox.Aws.CredentialHandle
  ( CredentialHandle
  , SecretString (SecretString)
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Wire
  ( AmbiguityCause (AmbiguousLostResult)
  , AwsClientError
    ( AwsAmbiguousOutcome
    , AwsResponseParseFailure
    , AwsServiceError
    )
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsServiceFault (awsFaultCode)
  , AwsTimestamp
  , Idempotency (Idempotent, Mutating)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , formContentType
  , performAwsRequest
  , renderFormBody
  )
import Prodbox.Aws.Native.Xml (extractAll, extractFirst)

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

-- | Exact user observation.  A missing user is a successful authoritative
-- absence result, not a transport or decoding failure.
data IamUserObservation
  = IamUserAbsent
  | IamUserPresent !CreateUserResult
  deriving (Eq, Show)

data IamUserPolicyObservation
  = IamUserPolicyAbsent
  | IamUserPolicyPresent !Text
  deriving (Eq, Show)

data IamRoleObservation
  = IamRoleAbsent
  | IamRolePresent
      { iamRoleName :: !Text
      , iamRoleArn :: !Text
      , iamRoleAssumePolicyDocument :: !Text
      }
  deriving (Eq, Show)

data IamRolePolicyObservation
  = IamRolePolicyAbsent
  | IamRolePolicyPresent !Text
  deriving (Eq, Show)

data AccessKeyStatus
  = AccessKeyActive
  | AccessKeyInactive
  deriving (Eq, Show)

data AccessKeyMetadata = AccessKeyMetadata
  { accessKeyMetadataId :: !Text
  , accessKeyMetadataStatus :: !AccessKeyStatus
  }
  deriving (Eq, Show)

data IamTag = IamTag
  { iamTagKey :: !Text
  , iamTagValue :: !Text
  }
  deriving (Eq, Ord, Show)

data IamClient = IamClient
  { createUser :: Text -> IO (Either AwsClientError CreateUserResult)
  , observeUser :: Text -> IO (Either AwsClientError IamUserObservation)
  , createAccessKey :: Text -> IO (Either AwsClientError CreateAccessKeyResult)
  , listAccessKeys :: Text -> IO (Either AwsClientError [AccessKeyMetadata])
  , deleteAccessKey :: Text -> Text -> IO (Either AwsClientError ())
  , putUserInlinePolicy :: Text -> Text -> Text -> IO (Either AwsClientError ())
  , observeUserInlinePolicy
      :: Text
      -> Text
      -> IO (Either AwsClientError IamUserPolicyObservation)
  , deleteUserInlinePolicy :: Text -> Text -> IO (Either AwsClientError ())
  , tagUser :: Text -> [IamTag] -> IO (Either AwsClientError ())
  , listUserTags :: Text -> IO (Either AwsClientError [IamTag])
  , deleteUser :: Text -> IO (Either AwsClientError ())
  , createRole :: Text -> Text -> IO (Either AwsClientError ())
  , observeRole :: Text -> IO (Either AwsClientError IamRoleObservation)
  , updateAssumeRolePolicy :: Text -> Text -> IO (Either AwsClientError ())
  , putRoleInlinePolicy :: Text -> Text -> Text -> IO (Either AwsClientError ())
  , observeRoleInlinePolicy
      :: Text -> Text -> IO (Either AwsClientError IamRolePolicyObservation)
  , deleteRoleInlinePolicy :: Text -> Text -> IO (Either AwsClientError ())
  , deleteRole :: Text -> IO (Either AwsClientError ())
  }

newIamClient :: CredentialHandle origin -> NativeAwsSender -> IamClient
newIamClient handle sender =
  IamClient
    { createUser = runCreateUser handle sender
    , observeUser = runObserveUser handle sender
    , createAccessKey = runCreateAccessKey handle sender
    , listAccessKeys = runListAccessKeys handle sender
    , deleteAccessKey = runDeleteAccessKey handle sender
    , putUserInlinePolicy = runPutUserPolicy handle sender
    , observeUserInlinePolicy = runObserveUserPolicy handle sender
    , deleteUserInlinePolicy = runDeleteUserPolicy handle sender
    , tagUser = runTagUser handle sender
    , listUserTags = runListUserTags handle sender
    , deleteUser = runDeleteUser handle sender
    , createRole = runCreateRole handle sender
    , observeRole = runObserveRole handle sender
    , updateAssumeRolePolicy = runUpdateAssumeRolePolicy handle sender
    , putRoleInlinePolicy = runPutRolePolicy handle sender
    , observeRoleInlinePolicy = runObserveRolePolicy handle sender
    , deleteRoleInlinePolicy = runDeleteRolePolicy handle sender
    , deleteRole = runDeleteRole handle sender
    }

iamEndpoint :: AwsEndpoint
iamEndpoint = AwsEndpoint "https://iam.amazonaws.com" "iam.amazonaws.com"

-- | IAM is a global service; sign under the fixed @us-east-1@ region.
iamScope :: AwsScope
iamScope = AwsScope "us-east-1" "iam"

encodeCreateUserForm :: Text -> [(ByteString, ByteString)]
encodeCreateUserForm userName =
  [("Action", "CreateUser"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

encodeGetUserForm :: Text -> [(ByteString, ByteString)]
encodeGetUserForm userName =
  [("Action", "GetUser"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

encodeCreateAccessKeyForm :: Text -> [(ByteString, ByteString)]
encodeCreateAccessKeyForm userName =
  [("Action", "CreateAccessKey"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

-- | Ask for one more than IAM's documented two-key user bound.  A future
-- service-side drift therefore becomes an explicit over-bound inventory in
-- the Provisioner instead of a silently truncated response.
encodeListAccessKeysForm :: Text -> [(ByteString, ByteString)]
encodeListAccessKeysForm userName =
  [ ("Action", "ListAccessKeys")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("MaxItems", "3")
  ]

encodeDeleteAccessKeyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeDeleteAccessKeyForm userName accessKeyId =
  [ ("Action", "DeleteAccessKey")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("AccessKeyId", encodeUtf8 accessKeyId)
  ]

encodePutUserPolicyForm :: Text -> Text -> Text -> [(ByteString, ByteString)]
encodePutUserPolicyForm userName policyName policyDocument =
  [ ("Action", "PutUserPolicy")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("PolicyName", encodeUtf8 policyName)
  , ("PolicyDocument", encodeUtf8 policyDocument)
  ]

encodeGetUserPolicyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeGetUserPolicyForm userName policyName =
  [ ("Action", "GetUserPolicy")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("PolicyName", encodeUtf8 policyName)
  ]

encodeDeleteUserPolicyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeDeleteUserPolicyForm userName policyName =
  [ ("Action", "DeleteUserPolicy")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("PolicyName", encodeUtf8 policyName)
  ]

encodeDeleteUserForm :: Text -> [(ByteString, ByteString)]
encodeDeleteUserForm userName =
  [("Action", "DeleteUser"), ("Version", "2010-05-08"), ("UserName", encodeUtf8 userName)]

encodeTagUserForm :: Text -> [IamTag] -> [(ByteString, ByteString)]
encodeTagUserForm userName tags =
  [ ("Action", "TagUser")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  ]
    <> concatMap encodeTag (zip [(1 :: Int) ..] tags)
 where
  encodeTag (index, IamTag key value) =
    [ (member index "Key", encodeUtf8 key)
    , (member index "Value", encodeUtf8 value)
    ]
  member index field =
    BS8.pack ("Tags.member." <> show index <> "." <> field)

encodeListUserTagsForm :: Text -> [(ByteString, ByteString)]
encodeListUserTagsForm userName =
  [ ("Action", "ListUserTags")
  , ("Version", "2010-05-08")
  , ("UserName", encodeUtf8 userName)
  , ("MaxItems", "100")
  ]

encodeCreateRoleForm :: Text -> Text -> [(ByteString, ByteString)]
encodeCreateRoleForm roleName trustPolicy =
  [ ("Action", "CreateRole")
  , ("Version", "2010-05-08")
  , ("RoleName", encodeUtf8 roleName)
  , ("AssumeRolePolicyDocument", encodeUtf8 trustPolicy)
  ]

encodeGetRoleForm :: Text -> [(ByteString, ByteString)]
encodeGetRoleForm roleName =
  [("Action", "GetRole"), ("Version", "2010-05-08"), ("RoleName", encodeUtf8 roleName)]

encodeUpdateAssumeRolePolicyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeUpdateAssumeRolePolicyForm roleName trustPolicy =
  [ ("Action", "UpdateAssumeRolePolicy")
  , ("Version", "2010-05-08")
  , ("RoleName", encodeUtf8 roleName)
  , ("PolicyDocument", encodeUtf8 trustPolicy)
  ]

encodePutRolePolicyForm :: Text -> Text -> Text -> [(ByteString, ByteString)]
encodePutRolePolicyForm roleName policyName policyDocument =
  [ ("Action", "PutRolePolicy")
  , ("Version", "2010-05-08")
  , ("RoleName", encodeUtf8 roleName)
  , ("PolicyName", encodeUtf8 policyName)
  , ("PolicyDocument", encodeUtf8 policyDocument)
  ]

encodeGetRolePolicyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeGetRolePolicyForm roleName policyName =
  [ ("Action", "GetRolePolicy")
  , ("Version", "2010-05-08")
  , ("RoleName", encodeUtf8 roleName)
  , ("PolicyName", encodeUtf8 policyName)
  ]

encodeDeleteRolePolicyForm :: Text -> Text -> [(ByteString, ByteString)]
encodeDeleteRolePolicyForm roleName policyName =
  [ ("Action", "DeleteRolePolicy")
  , ("Version", "2010-05-08")
  , ("RoleName", encodeUtf8 roleName)
  , ("PolicyName", encodeUtf8 policyName)
  ]

encodeDeleteRoleForm :: Text -> [(ByteString, ByteString)]
encodeDeleteRoleForm roleName =
  [("Action", "DeleteRole"), ("Version", "2010-05-08"), ("RoleName", encodeUtf8 roleName)]

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
  parseUser user

parseGetUserResponse :: ByteString -> Either String CreateUserResult
parseGetUserResponse body = do
  user <- note "GetUser: missing <User>" (extractFirst "<User>" "</User>" body)
  parseUser user

parseUser :: ByteString -> Either String CreateUserResult
parseUser user = do
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

parseListAccessKeysResponse :: ByteString -> Either String [AccessKeyMetadata]
parseListAccessKeysResponse body = do
  result <-
    note
      "ListAccessKeys: missing <ListAccessKeysResult>"
      (extractFirst "<ListAccessKeysResult>" "</ListAccessKeysResult>" body)
  truncated <- elementText "IsTruncated" result
  if truncated == "false"
    then traverse parseMetadata (extractAll "<member>" "</member>" result)
    else
      if truncated == "true"
        then Left "ListAccessKeys: bounded inventory was truncated"
        else Left "ListAccessKeys: invalid <IsTruncated> value"
 where
  parseMetadata member = do
    keyId <- elementText "AccessKeyId" member
    statusText <- elementText "Status" member
    status <- case statusText of
      "Active" -> Right AccessKeyActive
      "Inactive" -> Right AccessKeyInactive
      _ -> Left "ListAccessKeys: unsupported key status"
    pure AccessKeyMetadata {accessKeyMetadataId = keyId, accessKeyMetadataStatus = status}

parseGetUserPolicyResponse :: ByteString -> Either String Text
parseGetUserPolicyResponse body = do
  result <-
    note
      "GetUserPolicy: missing <GetUserPolicyResult>"
      (extractFirst "<GetUserPolicyResult>" "</GetUserPolicyResult>" body)
  encodedDocument <- elementBytes "PolicyDocument" result
  pure (decodeUtf8 (urlDecode True encodedDocument))

parseListUserTagsResponse :: ByteString -> Either String [IamTag]
parseListUserTagsResponse body = do
  result <-
    note
      "ListUserTags: missing <ListUserTagsResult>"
      (extractFirst "<ListUserTagsResult>" "</ListUserTagsResult>" body)
  truncated <- elementText "IsTruncated" result
  if truncated == "false"
    then traverse parseTag (extractAll "<member>" "</member>" result)
    else
      if truncated == "true"
        then Left "ListUserTags: bounded tag inventory was truncated"
        else Left "ListUserTags: invalid <IsTruncated> value"
 where
  parseTag member =
    IamTag
      <$> elementText "Key" member
      <*> elementText "Value" member

parseGetRoleResponse :: ByteString -> Either String IamRoleObservation
parseGetRoleResponse body = do
  role <- note "GetRole: missing <Role>" (extractFirst "<Role>" "</Role>" body)
  roleName <- elementText "RoleName" role
  roleArn <- elementText "Arn" role
  encodedTrust <- elementBytes "AssumeRolePolicyDocument" role
  pure
    IamRolePresent
      { iamRoleName = roleName
      , iamRoleArn = roleArn
      , iamRoleAssumePolicyDocument = decodeUtf8 (urlDecode True encodedTrust)
      }

parseGetRolePolicyResponse :: ByteString -> Either String Text
parseGetRolePolicyResponse body = do
  result <-
    note
      "GetRolePolicy: missing <GetRolePolicyResult>"
      (extractFirst "<GetRolePolicyResult>" "</GetRolePolicyResult>" body)
  encodedDocument <- elementBytes "PolicyDocument" result
  pure (decodeUtf8 (urlDecode True encodedDocument))

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

runObserveUser
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError IamUserObservation)
runObserveUser handle sender userName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeGetUserForm userName))
      "iam:GetUser"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right IamUserAbsent
      | otherwise -> Left err
    Right body ->
      IamUserPresent
        <$> first AwsResponseParseFailure (parseGetUserResponse body)

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

runListAccessKeys
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError [AccessKeyMetadata])
runListAccessKeys handle sender userName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeListAccessKeysForm userName))
      "iam:ListAccessKeys"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right []
      | otherwise -> Left err
    Right body -> first AwsResponseParseFailure (parseListAccessKeysResponse body)

runDeleteAccessKey
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runDeleteAccessKey handle sender userName accessKeyId =
  runIdempotentVoidAllowNoSuchEntity
    handle
    sender
    "iam:DeleteAccessKey"
    (encodeDeleteAccessKeyForm userName accessKeyId)

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

runObserveUserPolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError IamUserPolicyObservation)
runObserveUserPolicy handle sender userName policyName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeGetUserPolicyForm userName policyName))
      "iam:GetUserPolicy"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right IamUserPolicyAbsent
      | otherwise -> Left err
    Right body ->
      IamUserPolicyPresent
        <$> first AwsResponseParseFailure (parseGetUserPolicyResponse body)

runDeleteUserPolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runDeleteUserPolicy handle sender userName policyName =
  runIdempotentVoidAllowNoSuchEntity
    handle
    sender
    "iam:DeleteUserPolicy"
    (encodeDeleteUserPolicyForm userName policyName)

runTagUser
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> [IamTag]
  -> IO (Either AwsClientError ())
runTagUser handle sender userName tags
  | null tags = pure (Right ())
  | otherwise = do
      raw <-
        performAwsRequest
          sender
          (\ts -> signIamForm handle ts (encodeTagUserForm userName tags))
          "iam:TagUser"
          Idempotent
          XmlErrorFormat
      pure (void raw)

runListUserTags
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError [IamTag])
runListUserTags handle sender userName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeListUserTagsForm userName))
      "iam:ListUserTags"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right []
      | otherwise -> Left err
    Right body -> first AwsResponseParseFailure (parseListUserTagsResponse body)

runDeleteUser
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError ())
runDeleteUser handle sender userName =
  runIdempotentVoidAllowNoSuchEntity
    handle
    sender
    "iam:DeleteUser"
    (encodeDeleteUserForm userName)

runCreateRole
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runCreateRole handle sender roleName trustPolicy = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeCreateRoleForm roleName trustPolicy))
      "iam:CreateRole"
      Idempotent
      XmlErrorFormat
  pure (void raw)

runObserveRole
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError IamRoleObservation)
runObserveRole handle sender roleName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeGetRoleForm roleName))
      "iam:GetRole"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right IamRoleAbsent
      | otherwise -> Left err
    Right body -> first AwsResponseParseFailure (parseGetRoleResponse body)

runUpdateAssumeRolePolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runUpdateAssumeRolePolicy handle sender roleName trustPolicy = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeUpdateAssumeRolePolicyForm roleName trustPolicy))
      "iam:UpdateAssumeRolePolicy"
      Idempotent
      XmlErrorFormat
  pure (void raw)

runPutRolePolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runPutRolePolicy handle sender roleName policyName policyDocument = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodePutRolePolicyForm roleName policyName policyDocument))
      "iam:PutRolePolicy"
      Idempotent
      XmlErrorFormat
  pure (void raw)

runObserveRolePolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError IamRolePolicyObservation)
runObserveRolePolicy handle sender roleName policyName = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts (encodeGetRolePolicyForm roleName policyName))
      "iam:GetRolePolicy"
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right IamRolePolicyAbsent
      | otherwise -> Left err
    Right body ->
      IamRolePolicyPresent
        <$> first AwsResponseParseFailure (parseGetRolePolicyResponse body)

runDeleteRolePolicy
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> Text
  -> IO (Either AwsClientError ())
runDeleteRolePolicy handle sender roleName policyName =
  runIdempotentVoidAllowNoSuchEntity
    handle
    sender
    "iam:DeleteRolePolicy"
    (encodeDeleteRolePolicyForm roleName policyName)

runDeleteRole
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError ())
runDeleteRole handle sender roleName =
  runIdempotentVoidAllowNoSuchEntity
    handle
    sender
    "iam:DeleteRole"
    (encodeDeleteRoleForm roleName)

runIdempotentVoidAllowNoSuchEntity
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> [(ByteString, ByteString)]
  -> IO (Either AwsClientError ())
runIdempotentVoidAllowNoSuchEntity handle sender label form = do
  raw <-
    performAwsRequest
      sender
      (\ts -> signIamForm handle ts form)
      label
      Idempotent
      XmlErrorFormat
  pure $ case raw of
    Left err
      | isNoSuchEntity err -> Right ()
      | otherwise -> Left err
    Right _ -> Right ()

isNoSuchEntity :: AwsClientError -> Bool
isNoSuchEntity err = case err of
  AwsServiceError fault -> awsFaultCode fault == "NoSuchEntity"
  _ -> False

elementText :: String -> ByteString -> Either String Text
elementText name hay = decodeUtf8 <$> elementBytes name hay

elementBytes :: String -> ByteString -> Either String ByteString
elementBytes name hay =
  note
    ("IAM: missing <" ++ name ++ ">")
    (extractFirst (BS8.pack ("<" ++ name ++ ">")) (BS8.pack ("</" ++ name ++ ">")) hay)

note :: String -> Maybe a -> Either String a
note message = maybe (Left message) Right
