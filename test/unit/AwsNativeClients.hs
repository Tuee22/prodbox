{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.62 deliverable 3: fake-protocol tests for the native AWS service
-- clients. No cluster, no AWS, no @aws@ CLI — every client is driven over a
-- canned 'NativeAwsSender', and the pure cores are checked against exact strings.
-- The headline proof is that @iam:CreateAccessKey@ can never falsely read as
-- "created": a lost ACK or an unparsable one-time secret both become an ambiguous
-- outcome. The final case source-scans the seven native modules to prove they
-- carry no env/profile/temp-file/subprocess credential seam.
module AwsNativeClients
  ( awsNativeClientsSuite
  )
where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isSuffixOf)
import Prodbox.Aws.CredentialHandle
  ( BaseCredentialHandle
  , CredentialHandle
  , SecretString (SecretString)
  , credentialHandleAccessKeyId
  , credentialHandleSecurityToken
  , mkBaseCredentialHandle
  , mkSessionCredentialHandle
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Iam
  ( AccessKeyMetadata (..)
  , AccessKeyStatus (..)
  , CreateAccessKeyResult (..)
  , CreateUserResult (..)
  , IamClient (..)
  , IamRoleObservation (..)
  , IamRolePolicyObservation (..)
  , IamTag (..)
  , IamUserObservation (..)
  , IamUserPolicyObservation (..)
  , encodeCreateAccessKeyForm
  , encodeCreateRoleForm
  , encodeDeleteAccessKeyForm
  , encodeListAccessKeysForm
  , encodePutRolePolicyForm
  , encodeTagUserForm
  , newIamClient
  , parseGetRolePolicyResponse
  , parseGetRoleResponse
  , parseGetUserPolicyResponse
  , parseListAccessKeysResponse
  , parseListUserTagsResponse
  )
import Prodbox.Aws.Native.Route53
  ( ChangeAction (..)
  , ChangeId (..)
  , ChangeStatus (..)
  , RecordType (..)
  , ResourceRecordSet (..)
  , Route53Client (..)
  , changeRecordSetsPath
  , listRecordSetsQuery
  , newRoute53Client
  , parseChangeInfoResponse
  , parseGetChangeResponse
  , parseListResourceRecordSetsResponse
  , renderChangeBatchXml
  )
import Prodbox.Aws.Native.S3
  ( S3BucketObservation (..)
  , S3Client (..)
  , expectedLongLivedBucketHardening
  , newS3Client
  , parseBucketEncryption
  , parseBucketLifecycle
  , parseBucketTagging
  , parseBucketVersioning
  , parsePublicAccessBlock
  , renderBucketEncryptionXml
  , renderBucketLifecycleXml
  , renderBucketTaggingXml
  , renderBucketVersioningXml
  , renderCreateBucketXml
  , renderPublicAccessBlockXml
  )
import Prodbox.Aws.Native.ServiceQuotas
  ( QuotaIncreaseRequest (..)
  , RequestStatus (..)
  , RequestedQuotaChange (..)
  , ServiceQuotaValue (..)
  , ServiceQuotasClient (..)
  , newServiceQuotasClient
  , quotaTarget
  , renderQuotaIncreaseBody
  )
import Prodbox.Aws.Native.Sts
  ( AssumeRoleCredentials (..)
  , AssumeRoleRequest (..)
  , CallerIdentity (..)
  , StsClient (..)
  , encodeGetCallerIdentityForm
  , newStsClient
  , parseAssumeRoleResponse
  , parseGetCallerIdentityResponse
  )
import Prodbox.Aws.Native.Wire
  ( AmbiguityCause (..)
  , AwsClientError (..)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsServiceFault (..)
  , AwsTimestamp (AwsTimestamp)
  , DispatchPhase (..)
  , HttpOutcome (HttpOutcome)
  , Idempotency (..)
  , NativeAwsResponseByteLimit
  , NativeAwsSender
  , SignedHttpRequest (shrBody, shrHeaders, shrMethod, shrUrl)
  , TransportFailure (TransportFailure)
  , buildSignedRequest
  , classifyOutcome
  , defaultNativeAwsResponseByteLimit
  , formContentType
  , mkNativeAwsResponseByteLimit
  , nativeAwsResponseByteLimitBytes
  , readBoundedNativeAwsHttpOutcome
  , renderFormBody
  )
import Prodbox.Lifecycle.OwnedResourceTags (longLivedPulumiStateBucketTags)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

-- Fake senders ---------------------------------------------------------------

respond :: Int -> ByteString -> NativeAwsSender
respond status body _ = pure (Right (HttpOutcome status [] body))

dropAfterSend :: NativeAwsSender
dropAfterSend _ = pure (Left (TransportFailure "reset after write" PossiblySent))

refuseConnect :: NativeAwsSender
refuseConnect _ = pure (Left (TransportFailure "connection refused" DefinitelyNotSent))

-- Sample handles -------------------------------------------------------------

baseHandle :: BaseCredentialHandle
baseHandle =
  either (error . show) id (mkBaseCredentialHandle "AKIABASE" "baseSecret" Nothing "us-east-1")

fixedTs :: AwsTimestamp
fixedTs = AwsTimestamp "20260718T000000Z" "20260718"

-- Predicates -----------------------------------------------------------------

isAmbiguousDispatch :: Either AwsClientError a -> Bool
isAmbiguousDispatch (Left (AwsAmbiguousOutcome (AmbiguousDispatchFailure op _))) = op == "iam:CreateAccessKey"
isAmbiguousDispatch _ = False

isAmbiguousLost :: Either AwsClientError a -> Bool
isAmbiguousLost (Left (AwsAmbiguousOutcome (AmbiguousLostResult _ _))) = True
isAmbiguousLost _ = False

isTransportError :: Either AwsClientError a -> Bool
isTransportError (Left (AwsTransportError _)) = True
isTransportError _ = False

isParseFailure :: Either AwsClientError a -> Bool
isParseFailure (Left (AwsResponseParseFailure _)) = True
isParseFailure _ = False

-- Golden response bodies -----------------------------------------------------

createAccessKeyFullBody :: ByteString
createAccessKeyFullBody =
  "<CreateAccessKeyResponse><CreateAccessKeyResult><AccessKey>"
    <> "<UserName>prodbox</UserName><AccessKeyId>AKIAFAKE</AccessKeyId>"
    <> "<Status>Active</Status><SecretAccessKey>fakeSecret</SecretAccessKey>"
    <> "</AccessKey></CreateAccessKeyResult></CreateAccessKeyResponse>"

createAccessKeyNoSecretBody :: ByteString
createAccessKeyNoSecretBody =
  "<CreateAccessKeyResponse><CreateAccessKeyResult><AccessKey>"
    <> "<UserName>prodbox</UserName><AccessKeyId>AKIAFAKE</AccessKeyId>"
    <> "</AccessKey></CreateAccessKeyResult></CreateAccessKeyResponse>"

createUserFullBody :: ByteString
createUserFullBody =
  "<CreateUserResponse><CreateUserResult><User>"
    <> "<UserName>prodbox</UserName><UserId>AIDFAKE</UserId>"
    <> "<Arn>arn:aws:iam::123456789012:user/prodbox</Arn>"
    <> "</User></CreateUserResult></CreateUserResponse>"

getUserFullBody :: ByteString
getUserFullBody =
  "<GetUserResponse><GetUserResult><User>"
    <> "<UserName>prodbox</UserName><UserId>AIDFAKE</UserId>"
    <> "<Arn>arn:aws:iam::123456789012:user/prodbox</Arn>"
    <> "</User></GetUserResult></GetUserResponse>"

getRoleFullBody :: ByteString
getRoleFullBody =
  "<GetRoleResponse><GetRoleResult><Role>"
    <> "<RoleName>prodbox-lifecycle-provider</RoleName>"
    <> "<Arn>arn:aws:iam::123456789012:role/prodbox-lifecycle-provider</Arn>"
    <> "<AssumeRolePolicyDocument>%7B%22Version%22%3A%222012-10-17%22%7D</AssumeRolePolicyDocument>"
    <> "</Role></GetRoleResult></GetRoleResponse>"

getRolePolicyBody :: ByteString
getRolePolicyBody =
  "<GetRolePolicyResponse><GetRolePolicyResult>"
    <> "<RoleName>prodbox-lifecycle-provider</RoleName><PolicyName>runtime</PolicyName>"
    <> "<PolicyDocument>%7B%22Version%22%3A%222012-10-17%22%7D</PolicyDocument>"
    <> "</GetRolePolicyResult></GetRolePolicyResponse>"

listAccessKeysBody :: ByteString
listAccessKeysBody =
  "<ListAccessKeysResponse><ListAccessKeysResult>"
    <> "<AccessKeyMetadata>"
    <> "<member><UserName>prodbox</UserName><AccessKeyId>AKIAONE</AccessKeyId><Status>Active</Status></member>"
    <> "<member><UserName>prodbox</UserName><AccessKeyId>AKIATWO</AccessKeyId><Status>Inactive</Status></member>"
    <> "</AccessKeyMetadata><IsTruncated>false</IsTruncated>"
    <> "</ListAccessKeysResult></ListAccessKeysResponse>"

noSuchEntityBody :: ByteString
noSuchEntityBody =
  "<ErrorResponse><Error><Type>Sender</Type><Code>NoSuchEntity</Code>"
    <> "<Message>missing</Message></Error><RequestId>request-1</RequestId></ErrorResponse>"

assumeRoleBody :: ByteString
assumeRoleBody =
  "<AssumeRoleResponse><AssumeRoleResult><Credentials>"
    <> "<AccessKeyId>ASIAFAKE</AccessKeyId><SecretAccessKey>tmpSecret</SecretAccessKey>"
    <> "<SessionToken>tmpToken</SessionToken><Expiration>2026-07-18T00:00:00Z</Expiration>"
    <> "</Credentials></AssumeRoleResult></AssumeRoleResponse>"

callerIdentityBody :: ByteString
callerIdentityBody =
  "<GetCallerIdentityResponse><GetCallerIdentityResult>"
    <> "<Arn>arn:aws:iam::123456789012:user/prodbox</Arn>"
    <> "<UserId>AIDFAKE</UserId><Account>123456789012</Account>"
    <> "</GetCallerIdentityResult></GetCallerIdentityResponse>"

-- Route 53 expected request bodies ------------------------------------------

singleAExpected :: ByteString
singleAExpected =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    <> "<Name>demo.resolvefintech.com.</Name><Type>A</Type><TTL>60</TTL>"
    <> "<ResourceRecords><ResourceRecord><Value>192.0.2.1</Value></ResourceRecord></ResourceRecords>"
    <> "</ResourceRecordSet></Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>"

multiAExpected :: ByteString
multiAExpected =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    <> "<Name>demo.resolvefintech.com.</Name><Type>A</Type><TTL>60</TTL><ResourceRecords>"
    <> "<ResourceRecord><Value>192.0.2.1</Value></ResourceRecord>"
    <> "<ResourceRecord><Value>192.0.2.2</Value></ResourceRecord>"
    <> "</ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch>"
    <> "</ChangeResourceRecordSetsRequest>"

txtExpected :: ByteString
txtExpected =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    <> "<Name>demo.resolvefintech.com.</Name><Type>TXT</Type><TTL>300</TTL><ResourceRecords>"
    <> "<ResourceRecord><Value>&quot;v=spf1 -all&quot;</Value></ResourceRecord>"
    <> "</ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch>"
    <> "</ChangeResourceRecordSetsRequest>"

listExactAResponse :: ByteString
listExactAResponse =
  "<ListResourceRecordSetsResponse xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ResourceRecordSets><ResourceRecordSet>"
    <> "<Name>Demo.ResolveFintech.com.</Name><Type>A</Type><TTL>60</TTL>"
    <> "<ResourceRecords><ResourceRecord><Value>192.0.2.1</Value></ResourceRecord>"
    <> "</ResourceRecords></ResourceRecordSet></ResourceRecordSets>"
    <> "<IsTruncated>false</IsTruncated><MaxItems>1</MaxItems>"
    <> "</ListResourceRecordSetsResponse>"

listSubsequentResponse :: ByteString
listSubsequentResponse =
  "<ListResourceRecordSetsResponse><ResourceRecordSets><ResourceRecordSet>"
    <> "<Name>next.resolvefintech.com.</Name><Type>A</Type><AliasTarget>"
    <> "<HostedZoneId>ZALIAS</HostedZoneId><DNSName>target.example.com.</DNSName>"
    <> "</AliasTarget></ResourceRecordSet></ResourceRecordSets>"
    <> "</ListResourceRecordSetsResponse>"

-- No-seams source scan -------------------------------------------------------

nativeModulePaths :: [FilePath]
nativeModulePaths =
  [ "src/Prodbox/Aws/CredentialHandle.hs"
  , "src/Prodbox/Aws/Native/Xml.hs"
  , "src/Prodbox/Aws/Native/Wire.hs"
  , "src/Prodbox/Aws/Native/Sts.hs"
  , "src/Prodbox/Aws/Native/Iam.hs"
  , "src/Prodbox/Aws/Native/Route53.hs"
  , "src/Prodbox/Aws/Native/S3.hs"
  , "src/Prodbox/Aws/Native/ServiceQuotas.hs"
  ]

bannedSeams :: [String]
bannedSeams =
  [ "getEnv"
  , "lookupEnv"
  , "getEnvironment"
  , "setEnv"
  , "System.Environment"
  , "System.Process"
  , "typed-process"
  , "readFile"
  , "writeFile"
  , "System.Directory"
  , "withSystemTempDirectory"
  , "AWS_ACCESS_KEY_ID"
  , "AWS_SECRET_ACCESS_KEY"
  , "AWS_SESSION_TOKEN"
  , "AWS_PROFILE"
  , ".aws/credentials"
  , "unsafePerformIO"
  , "Prodbox.AwsEnvironment"
  , "Prodbox.Aws.AdminCredentials"
  ]

awsNativeClientsSuite :: SuiteBuilder ()
awsNativeClientsSuite =
  describe "Sprint 1.62 native AWS clients" $ do
    describe "bounded native AWS response transport" $ do
      it "rejects zero and negative response-byte limits" $ do
        mkNativeAwsResponseByteLimit 0
          `shouldBe` Left "native AWS response-byte limit must be positive"
        mkNativeAwsResponseByteLimit (-1)
          `shouldBe` Left "native AWS response-byte limit must be positive"
        mkNativeAwsResponseByteLimit maxBound
          `shouldBe` Left "native AWS response-byte limit is too large"
      it "accepts an empty fragmented response body" $ do
        (readChunk, _) <- fragmentedBodyReader []
        result <- readBoundedNativeAwsHttpOutcome (responseLimit 5) 204 [] readChunk
        result `shouldBe` Right (HttpOutcome 204 [] "")
      it "accepts exactly the limit across arbitrary response fragments" $ do
        (readChunk, remainingFragments) <- fragmentedBodyReader ["ab", "c", "de"]
        result <- readBoundedNativeAwsHttpOutcome (responseLimit 5) 200 [] readChunk
        result `shouldBe` Right (HttpOutcome 200 [] "abcde")
        remainingFragments `shouldReturn` []
      it "rejects max+1 across fragments without returning a partial body or draining the stream" $ do
        (readChunk, remainingFragments) <- fragmentedBodyReader ["ab", "cde", "f", "unread"]
        result <- readBoundedNativeAwsHttpOutcome (responseLimit 5) 200 [] readChunk
        result
          `shouldBe` Left
            (TransportFailure "native AWS HTTP response exceeds the 5-byte bound" PossiblySent)
        remainingFragments `shouldReturn` ["unread"]
      it "classifies a fake transport overflow conservatively after a mutating dispatch" $ do
        (readChunk, _) <- fragmentedBodyReader ["123", "456"]
        outcome <- readBoundedNativeAwsHttpOutcome (responseLimit 5) 200 [] readChunk
        classifyOutcome "iam:CreateAccessKey" Mutating XmlErrorFormat outcome
          `shouldBe` Left
            ( AwsAmbiguousOutcome
                ( AmbiguousDispatchFailure
                    "iam:CreateAccessKey"
                    "native AWS HTTP response exceeds the 5-byte bound"
                )
            )
      it "ships a fixed positive one-MiB default limit" $
        nativeAwsResponseByteLimitBytes defaultNativeAwsResponseByteLimit
          `shouldBe` (1024 * 1024)

    describe "classifyOutcome ambiguity gate (pure truth table)" $ do
      it "idempotent + not-sent transport failure is a plain transport error" $
        classifyOutcome "op" Idempotent XmlErrorFormat (Left (TransportFailure "d" DefinitelyNotSent))
          `shouldBe` Left (AwsTransportError "d")
      it "idempotent + possibly-sent transport failure is still a plain transport error" $
        classifyOutcome "op" Idempotent XmlErrorFormat (Left (TransportFailure "d" PossiblySent))
          `shouldBe` Left (AwsTransportError "d")
      it "mutating + not-sent transport failure is a plain transport error" $
        classifyOutcome "op" Mutating XmlErrorFormat (Left (TransportFailure "d" DefinitelyNotSent))
          `shouldBe` Left (AwsTransportError "d")
      it "mutating + possibly-sent transport failure is AMBIGUOUS" $
        classifyOutcome "op" Mutating XmlErrorFormat (Left (TransportFailure "d" PossiblySent))
          `shouldBe` Left (AwsAmbiguousOutcome (AmbiguousDispatchFailure "op" "d"))
      it "a 2xx yields the body" $
        classifyOutcome "op" Idempotent XmlErrorFormat (Right (HttpOutcome 200 [] "body"))
          `shouldBe` Right "body"
      it "a non-2xx yields a parsed service fault" $
        classifyOutcome
          "op"
          Idempotent
          XmlErrorFormat
          (Right (HttpOutcome 400 [] "<Error><Code>X</Code><Message>m</Message></Error>"))
          `shouldBe` Left (AwsServiceError (AwsServiceFault 400 "X" "m" Nothing))

    describe "IAM CreateAccessKey response-loss is ambiguous, never false-created" $ do
      it "a lost ACK on the mutating op is an ambiguous dispatch outcome" $ do
        let iam = newIamClient baseHandle dropAfterSend
        result <- createAccessKey iam "prodbox"
        result `shouldSatisfy` isAmbiguousDispatch
      it "a 2xx whose one-time secret is unparsable is an ambiguous lost result" $ do
        let iam = newIamClient baseHandle (respond 200 createAccessKeyNoSecretBody)
        result <- createAccessKey iam "prodbox"
        result `shouldSatisfy` isAmbiguousLost
      it "a full 2xx yields the created key (secret carried, redacted on show)" $ do
        let iam = newIamClient baseHandle (respond 200 createAccessKeyFullBody)
        result <- createAccessKey iam "prodbox"
        result `shouldBe` Right (CreateAccessKeyResult "AKIAFAKE" (SecretString "fakeSecret") "prodbox")
      it "the request was actually delivered on a lost ACK (not a pre-send refusal)" $ do
        ref <- newIORef (0 :: Int)
        let capturing req = do
              writeIORef ref 1
              _ <- pure req
              pure (Left (TransportFailure "reset" PossiblySent))
            iam = newIamClient baseHandle capturing
        _ <- createAccessKey iam "prodbox"
        delivered <- readIORef ref
        delivered `shouldBe` 1
      it "the idempotent CreateUser escalates a truncated 2xx only to a plain parse failure" $ do
        let iam = newIamClient baseHandle (respond 200 "<CreateUserResponse></CreateUserResponse>")
        result <- createUser iam "prodbox"
        result `shouldSatisfy` isParseFailure
      it "a pre-connection refusal on CreateAccessKey is a plain transport error (never ambiguous)" $ do
        let iam = newIamClient baseHandle refuseConnect
        result <- createAccessKey iam "prodbox"
        result `shouldSatisfy` isTransportError
      it "a full CreateUser 2xx parses" $ do
        let iam = newIamClient baseHandle (respond 200 createUserFullBody)
        result <- createUser iam "prodbox"
        result
          `shouldBe` Right
            (CreateUserResult "prodbox" "arn:aws:iam::123456789012:user/prodbox" "AIDFAKE")

    describe "IAM bounded inventory and exact absence read-back" $ do
      it "parses both active and inactive access-key metadata without secret material" $
        parseListAccessKeysResponse listAccessKeysBody
          `shouldBe` Right
            [ AccessKeyMetadata "AKIAONE" AccessKeyActive
            , AccessKeyMetadata "AKIATWO" AccessKeyInactive
            ]
      it "refuses a truncated finite inventory" $
        parseListAccessKeysResponse
          "<ListAccessKeysResponse><ListAccessKeysResult><AccessKeyMetadata></AccessKeyMetadata><IsTruncated>true</IsTruncated></ListAccessKeysResult></ListAccessKeysResponse>"
          `shouldBe` Left "ListAccessKeys: bounded inventory was truncated"
      it "observes a present user through GetUser" $ do
        let iam = newIamClient baseHandle (respond 200 getUserFullBody)
        observeUser iam "prodbox"
          `shouldReturn` Right
            ( IamUserPresent
                (CreateUserResult "prodbox" "arn:aws:iam::123456789012:user/prodbox" "AIDFAKE")
            )
      it "maps NoSuchEntity to positive user absence and idempotent key deletion" $ do
        let iam = newIamClient baseHandle (respond 404 noSuchEntityBody)
        observeUser iam "prodbox" `shouldReturn` Right IamUserAbsent
        deleteAccessKey iam "prodbox" "AKIAMISSING" `shouldReturn` Right ()
      it "dispatches bounded ListAccessKeys and exact DeleteAccessKey forms" $ do
        encodeListAccessKeysForm "prodbox"
          `shouldBe` [ ("Action", "ListAccessKeys")
                     , ("Version", "2010-05-08")
                     , ("UserName", "prodbox")
                     , ("MaxItems", "3")
                     ]
        encodeDeleteAccessKeyForm "prodbox" "AKIAONE"
          `shouldBe` [ ("Action", "DeleteAccessKey")
                     , ("Version", "2010-05-08")
                     , ("UserName", "prodbox")
                     , ("AccessKeyId", "AKIAONE")
                     ]
      it "decodes and observes the exact URL-encoded inline policy document" $ do
        let body =
              "<GetUserPolicyResponse><GetUserPolicyResult><UserName>prodbox</UserName>"
                <> "<PolicyName>prodbox</PolicyName>"
                <> "<PolicyDocument>%7B%22Version%22%3A%222012-10-17%22%7D</PolicyDocument>"
                <> "</GetUserPolicyResult></GetUserPolicyResponse>"
            iam = newIamClient baseHandle (respond 200 body)
        parseGetUserPolicyResponse body
          `shouldBe` Right "{\"Version\":\"2012-10-17\"}"
        observeUserInlinePolicy iam "prodbox" "prodbox"
          `shouldReturn` Right
            (IamUserPolicyPresent "{\"Version\":\"2012-10-17\"}")
      it "encodes and reads back the bounded ownership-tag inventory" $ do
        encodeTagUserForm
          "prodbox"
          [IamTag "prodbox.io/managed-by" "prodbox", IamTag "prodbox.io/class" "gateway-dns"]
          `shouldBe` [ ("Action", "TagUser")
                     , ("Version", "2010-05-08")
                     , ("UserName", "prodbox")
                     , ("Tags.member.1.Key", "prodbox.io/managed-by")
                     , ("Tags.member.1.Value", "prodbox")
                     , ("Tags.member.2.Key", "prodbox.io/class")
                     , ("Tags.member.2.Value", "gateway-dns")
                     ]
        parseListUserTagsResponse
          "<ListUserTagsResponse><ListUserTagsResult><Tags><member><Key>prodbox.io/class</Key><Value>gateway-dns</Value></member></Tags><IsTruncated>false</IsTruncated></ListUserTagsResult></ListUserTagsResponse>"
          `shouldBe` Right [IamTag "prodbox.io/class" "gateway-dns"]
      it "encodes and reads back the exact Lifecycle-provider role policies" $ do
        encodeCreateRoleForm "prodbox-lifecycle-provider" "{\"trust\":true}"
          `shouldBe` [ ("Action", "CreateRole")
                     , ("Version", "2010-05-08")
                     , ("RoleName", "prodbox-lifecycle-provider")
                     , ("AssumeRolePolicyDocument", "{\"trust\":true}")
                     ]
        encodePutRolePolicyForm
          "prodbox-lifecycle-provider"
          "runtime"
          "{\"Version\":\"2012-10-17\"}"
          `shouldBe` [ ("Action", "PutRolePolicy")
                     , ("Version", "2010-05-08")
                     , ("RoleName", "prodbox-lifecycle-provider")
                     , ("PolicyName", "runtime")
                     , ("PolicyDocument", "{\"Version\":\"2012-10-17\"}")
                     ]
        parseGetRoleResponse getRoleFullBody
          `shouldBe` Right
            IamRolePresent
              { iamRoleName = "prodbox-lifecycle-provider"
              , iamRoleArn = "arn:aws:iam::123456789012:role/prodbox-lifecycle-provider"
              , iamRoleAssumePolicyDocument = "{\"Version\":\"2012-10-17\"}"
              }
        parseGetRolePolicyResponse getRolePolicyBody
          `shouldBe` Right "{\"Version\":\"2012-10-17\"}"
        let roleClient = newIamClient baseHandle (respond 200 getRoleFullBody)
            policyClient = newIamClient baseHandle (respond 200 getRolePolicyBody)
        observeRole roleClient "prodbox-lifecycle-provider"
          `shouldReturn` Right
            IamRolePresent
              { iamRoleName = "prodbox-lifecycle-provider"
              , iamRoleArn = "arn:aws:iam::123456789012:role/prodbox-lifecycle-provider"
              , iamRoleAssumePolicyDocument = "{\"Version\":\"2012-10-17\"}"
              }
        observeRoleInlinePolicy policyClient "prodbox-lifecycle-provider" "runtime"
          `shouldReturn` Right
            (IamRolePolicyPresent "{\"Version\":\"2012-10-17\"}")

    describe "STS AssumeRole yields a distinct session handle with the temporary creds" $ do
      it "parses the temporary credentials block" $ do
        let parsed = parseAssumeRoleResponse assumeRoleBody
        fmap arcAccessKeyId parsed `shouldBe` Right "ASIAFAKE"
        fmap arcExpiration parsed `shouldBe` Right "2026-07-18T00:00:00Z"
      it "assumeRole returns a session whose non-secret fields are the temporary ones" $ do
        let sts = newStsClient baseHandle (respond 200 assumeRoleBody)
        result <- assumeRole sts (AssumeRoleRequest "arn:aws:iam::123:role/r" "sess" 900)
        fmap credentialHandleAccessKeyId result `shouldBe` Right "ASIAFAKE"
        fmap credentialHandleSecurityToken result `shouldBe` Right (Just "tmpToken")
      it "the session handle signs with the temporary secret (signature equality)" $ do
        let sts = newStsClient baseHandle (respond 200 assumeRoleBody)
        result <- assumeRole sts (AssumeRoleRequest "arn:aws:iam::123:role/r" "sess" 900)
        let reference =
              either (error . show) id (mkSessionCredentialHandle "ASIAFAKE" "tmpSecret" "tmpToken" "us-east-1")
        case result of
          Left err -> expectationFailure ("assumeRole failed: " <> show err)
          Right session -> do
            probeSign session `shouldBe` probeSign reference
            elem ("x-amz-security-token", "tmpToken") (shrHeaders (probeSign session)) `shouldBe` True
      it "parses and dispatches GetCallerIdentity without inventing the account coordinate" $ do
        parseGetCallerIdentityResponse callerIdentityBody
          `shouldBe` Right
            (CallerIdentity "123456789012" "arn:aws:iam::123456789012:user/prodbox" "AIDFAKE")
        encodeGetCallerIdentityForm
          `shouldBe` [("Action", "GetCallerIdentity"), ("Version", "2011-06-15")]
        captured <- newIORef Nothing
        let sender request = do
              writeIORef captured (Just request)
              pure (Right (HttpOutcome 200 [] callerIdentityBody))
            sts = newStsClient baseHandle sender
        result <- getCallerIdentity sts
        fmap callerIdentityAccount result `shouldBe` Right "123456789012"
        request <- readIORef captured
        fmap shrMethod request `shouldBe` Just "POST"
        fmap shrBody request
          `shouldBe` Just "Action=GetCallerIdentity&Version=2011-06-15"

    describe "Route 53 change-batch XML is a deterministic function of the desired records" $ do
      it "renders a single A UPSERT with a trailing dot" $
        renderChangeBatchXml
          [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["192.0.2.1"])]
          `shouldBe` singleAExpected
      it "renders multiple values in list order" $
        renderChangeBatchXml
          [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["192.0.2.1", "192.0.2.2"])]
          `shouldBe` multiAExpected
      it "escapes quotes in a TXT value" $
        renderChangeBatchXml
          [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordTXT 300 ["\"v=spf1 -all\""])]
          `shouldBe` txtExpected
      it "renders the exact regional SES MX value" $ do
        let rendered =
              renderChangeBatchXml
                [
                  ( Upsert
                  , ResourceRecordSet
                      "inbox.example.test"
                      RecordMX
                      300
                      ["10 inbound-smtp.us-west-2.amazonaws.com."]
                  )
                ]
        rendered `shouldSatisfy` (BS8.isInfixOf "<Type>MX</Type>")
        rendered
          `shouldSatisfy` ( BS8.isInfixOf
                              "<Value>10 inbound-smtp.us-west-2.amazonaws.com.</Value>"
                          )
      it "normalizes a hosted-zone path with or without the /hostedzone/ prefix" $ do
        changeRecordSetsPath "/hostedzone/Z123" `shouldBe` "/2013-04-01/hostedzone/Z123/rrset/"
        changeRecordSetsPath "Z123" `shouldBe` "/2013-04-01/hostedzone/Z123/rrset/"
      it "parses a ChangeInfo response" $
        parseChangeInfoResponse
          "<ChangeResourceRecordSetsResponse><ChangeInfo><Id>/change/C123</Id><Status>PENDING</Status></ChangeInfo></ChangeResourceRecordSetsResponse>"
          `shouldBe` Right (ChangeId "/change/C123", ChangePending)
      it "parses a GetChange INSYNC status" $
        parseGetChangeResponse
          "<GetChangeResponse><ChangeInfo><Id>/change/C123</Id><Status>INSYNC</Status></ChangeInfo></GetChangeResponse>"
          `shouldBe` Right ChangeInsync
      it "builds a one-record authoritative lookup query" $
        listRecordSetsQuery "demo.resolvefintech.com" RecordA
          `shouldBe` [("name", "demo.resolvefintech.com."), ("type", "A"), ("maxitems", "1")]
      it "uses the MX selector for an SES receive lookup" $
        listRecordSetsQuery "inbox.example.test" RecordMX
          `shouldBe` [("name", "inbox.example.test."), ("type", "MX"), ("maxitems", "1")]
      it "parses only an exact name/type record with TTL and values" $
        parseListResourceRecordSetsResponse "demo.resolvefintech.com" RecordA listExactAResponse
          `shouldBe` Right (Just (ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["192.0.2.1"]))
      it "reports a lexicographically subsequent first record as exact absence" $
        parseListResourceRecordSetsResponse "demo.resolvefintech.com" RecordA listSubsequentResponse
          `shouldBe` Right Nothing
      it "fails closed on an exact alias record" $
        parseListResourceRecordSetsResponse
          "next.resolvefintech.com"
          RecordA
          listSubsequentResponse
          `shouldBe` Left "Route53: exact record uses an unsupported alias or routing policy"
      it "dispatches ListResourceRecordSets with the canonical bounded query" $ do
        captured <- newIORef Nothing
        let sender request = do
              writeIORef captured (Just request)
              pure (Right (HttpOutcome 200 [] listExactAResponse))
            r53 = newRoute53Client baseHandle sender
        result <- listExactResourceRecordSet r53 "Z123" "demo.resolvefintech.com" RecordA
        result
          `shouldBe` Right
            (Just (ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["192.0.2.1"]))
        request <- readIORef captured
        fmap shrMethod request `shouldBe` Just "GET"
        fmap shrUrl request
          `shouldBe` Just
            "https://route53.amazonaws.com/2013-04-01/hostedzone/Z123/rrset/?maxitems=1&name=demo.resolvefintech.com.&type=A"
      it "refuses an empty change set before signing" $ do
        let r53 = newRoute53Client baseHandle (respond 200 "")
        result <- changeResourceRecordSets r53 "Z123" []
        result `shouldBe` Left (AwsSigningError "refusing to write empty Route 53 change set")

    describe "S3 long-lived bucket hardening is exact and read back" $ do
      it "renders region-correct create bodies and the five fixed hardening documents" $ do
        renderCreateBucketXml "us-east-1" `shouldBe` ""
        renderCreateBucketXml "ca-central-1"
          `shouldBe` "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>ca-central-1</LocationConstraint></CreateBucketConfiguration>"
        renderBucketVersioningXml `shouldSatisfy` BS8.isInfixOf "<Status>Enabled</Status>"
        renderBucketEncryptionXml `shouldSatisfy` BS8.isInfixOf "<SSEAlgorithm>AES256</SSEAlgorithm>"
        renderPublicAccessBlockXml
          `shouldSatisfy` BS8.isInfixOf "<RestrictPublicBuckets>true</RestrictPublicBuckets>"
        renderBucketTaggingXml longLivedPulumiStateBucketTags
          `shouldSatisfy` BS8.isInfixOf "<Key>prodbox.io/managed-by</Key>"
        renderBucketLifecycleXml `shouldSatisfy` BS8.isInfixOf "<NoncurrentDays>90</NoncurrentDays>"
      it "parses each authoritative hardening projection" $ do
        parseBucketVersioning renderBucketVersioningXml `shouldBe` Right True
        parseBucketEncryption renderBucketEncryptionXml `shouldBe` Right True
        parsePublicAccessBlock renderPublicAccessBlockXml `shouldBe` Right True
        parseBucketTagging (renderBucketTaggingXml longLivedPulumiStateBucketTags)
          `shouldBe` Right
            [ ("prodbox.io/managed-by", "prodbox")
            , ("prodbox.io/role", "long-lived-pulumi-state")
            ]
        parseBucketLifecycle renderBucketLifecycleXml `shouldBe` Right (Just 90)
      it "maps a HEAD 404 to positive absence" $ do
        let s3 = newS3Client baseHandle (respond 404 "")
        observeBucket s3 "prodbox-long-lived" `shouldReturn` Right S3BucketAbsent
      it "reads the complete expected hardening state from five bounded GETs" $ do
        let sender request
              | "?versioning=" `isSuffixOf` shrUrl request =
                  pure (Right (HttpOutcome 200 [] renderBucketVersioningXml))
              | "?encryption=" `isSuffixOf` shrUrl request =
                  pure (Right (HttpOutcome 200 [] renderBucketEncryptionXml))
              | "?publicAccessBlock=" `isSuffixOf` shrUrl request =
                  pure (Right (HttpOutcome 200 [] renderPublicAccessBlockXml))
              | "?tagging=" `isSuffixOf` shrUrl request =
                  pure
                    ( Right
                        ( HttpOutcome
                            200
                            []
                            (renderBucketTaggingXml longLivedPulumiStateBucketTags)
                        )
                    )
              | "?lifecycle=" `isSuffixOf` shrUrl request =
                  pure (Right (HttpOutcome 200 [] renderBucketLifecycleXml))
              | otherwise = pure (Left (TransportFailure "unexpected S3 request" DefinitelyNotSent))
            s3 = newS3Client baseHandle sender
        observeBucketHardening s3 "prodbox-long-lived"
          `shouldReturn` Right expectedLongLivedBucketHardening
      it "PUTs every hardening document with a signed content MD5" $ do
        requests <- newIORef []
        let sender request = do
              existing <- readIORef requests
              writeIORef requests (existing ++ [request])
              pure (Right (HttpOutcome 200 [] ""))
            s3 = newS3Client baseHandle sender
        putBucketHardening s3 "prodbox-long-lived" `shouldReturn` Right ()
        captured <- readIORef requests
        length captured `shouldBe` 5
        all ((== "PUT") . shrMethod) captured `shouldBe` True
        all (maybe False (not . BS8.null) . lookup "content-md5" . shrHeaders) captured
          `shouldBe` True

    describe "Service Quotas request / status read-back" $ do
      it "renders a deterministic request body and target" $ do
        renderQuotaIncreaseBody (QuotaIncreaseRequest "ec2" "L-1216C47A" 64)
          `shouldBe` "{\"ServiceCode\":\"ec2\",\"QuotaCode\":\"L-1216C47A\",\"DesiredValue\":64.0}"
        quotaTarget "RequestServiceQuotaIncrease"
          `shouldBe` "ServiceQuotasV20190624.RequestServiceQuotaIncrease"
      it "submits a request then reads its status back" $ do
        let submit =
              newServiceQuotasClient
                baseHandle
                (respond 200 "{\"RequestedQuota\":{\"Id\":\"req-1\",\"Status\":\"PENDING\"}}")
        submitted <- requestServiceQuotaIncrease submit (QuotaIncreaseRequest "ec2" "L-1216C47A" 64)
        submitted `shouldBe` Right (RequestedQuotaChange "req-1" QuotaPending)
        let poll =
              newServiceQuotasClient
                baseHandle
                (respond 200 "{\"RequestedQuota\":{\"Id\":\"req-1\",\"Status\":\"CASE_OPENED\"}}")
        polled <- getRequestedServiceQuotaChange poll "req-1"
        polled `shouldBe` Right (RequestedQuotaChange "req-1" QuotaCaseOpened)
      it "reads a service quota value" $ do
        let sq =
              newServiceQuotasClient
                baseHandle
                (respond 200 "{\"Quota\":{\"QuotaCode\":\"L-1216C47A\",\"Value\":32.0}}")
        result <- getServiceQuota sq "ec2" "L-1216C47A"
        result `shouldBe` Right (ServiceQuotaValue "L-1216C47A" 32.0)
      it "maps a throttling JSON fault" $ do
        let sq =
              newServiceQuotasClient
                baseHandle
                (respond 400 "{\"__type\":\"com.amazon.coral.service#ThrottlingException\",\"message\":\"rate\"}")
        result <- getServiceQuota sq "ec2" "L-1216C47A"
        result `shouldBe` Left (AwsServiceError (AwsServiceFault 400 "ThrottlingException" "rate" Nothing))

    describe "SigV4 signing conformance" $
      it "IAM signs content-type;host;x-amz-date under the iam credential scope" $ do
        let signed =
              buildSignedRequest
                (toSigV4Credentials baseHandle)
                (credentialHandleSecurityToken baseHandle)
                (AwsScope "us-east-1" "iam")
                (AwsEndpoint "https://iam.amazonaws.com" "iam.amazonaws.com")
                fixedTs
                "POST"
                "/"
                []
                (renderFormBody (encodeCreateAccessKeyForm "prodbox"))
                formContentType
            authorization = maybe "" BS8.unpack (lookup "Authorization" (shrHeaders signed))
        ("/20260718/us-east-1/iam/aws4_request" `isInfixOf` authorization) `shouldBe` True
        ("SignedHeaders=content-type;host;x-amz-date" `isInfixOf` authorization) `shouldBe` True

    describe "no native module carries a credential seam" $
      it "none of the native modules contains an env/profile/temp-file/subprocess reference" $ do
        repoRoot <- getCurrentDirectory
        scanned <- forM nativeModulePaths $ \path -> do
          contents <- readFile (repoRoot </> path)
          pure (path, filter (`isInfixOf` contents) bannedSeams)
        filter (not . null . snd) scanned `shouldBe` []

-- | Sign a fixed probe request under any credential handle, exercising the
-- secret + session token through 'toSigV4Credentials'. Two handles carrying the
-- same credentials produce identical signed requests, so signature equality
-- proves the temporary secret propagated.
probeSign :: CredentialHandle origin -> SignedHttpRequest
probeSign handle =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    (AwsScope "us-east-1" "sts")
    (AwsEndpoint "https://sts.us-east-1.amazonaws.com" "sts.us-east-1.amazonaws.com")
    fixedTs
    "POST"
    "/"
    []
    "probe"
    formContentType

responseLimit :: Int -> NativeAwsResponseByteLimit
responseLimit bytes =
  either
    (error . ("invalid native AWS response test limit: " ++))
    id
    (mkNativeAwsResponseByteLimit bytes)

fragmentedBodyReader :: [ByteString] -> IO (IO ByteString, IO [ByteString])
fragmentedBodyReader initialFragments = do
  fragmentsRef <- newIORef initialFragments
  let readChunk = do
        fragments <- readIORef fragmentsRef
        case fragments of
          [] -> pure ""
          chunk : remaining -> do
            writeIORef fragmentsRef remaining
            pure chunk
  pure (readChunk, readIORef fragmentsRef)
