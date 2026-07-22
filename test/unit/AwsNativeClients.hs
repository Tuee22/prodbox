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
import Data.List (isInfixOf)
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
  ( CreateAccessKeyResult (..)
  , CreateUserResult (..)
  , IamClient (..)
  , encodeCreateAccessKeyForm
  , newIamClient
  )
import Prodbox.Aws.Native.Route53
  ( ChangeAction (..)
  , ChangeId (..)
  , ChangeStatus (..)
  , RecordType (..)
  , ResourceRecordSet (..)
  , Route53Client (..)
  , changeRecordSetsPath
  , newRoute53Client
  , parseChangeInfoResponse
  , parseGetChangeResponse
  , renderChangeBatchXml
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
  , StsClient (..)
  , newStsClient
  , parseAssumeRoleResponse
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
  , SignedHttpRequest (shrHeaders)
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

assumeRoleBody :: ByteString
assumeRoleBody =
  "<AssumeRoleResponse><AssumeRoleResult><Credentials>"
    <> "<AccessKeyId>ASIAFAKE</AccessKeyId><SecretAccessKey>tmpSecret</SecretAccessKey>"
    <> "<SessionToken>tmpToken</SessionToken><Expiration>2026-07-18T00:00:00Z</Expiration>"
    <> "</Credentials></AssumeRoleResult></AssumeRoleResponse>"

-- Route 53 expected request bodies ------------------------------------------

singleAExpected :: ByteString
singleAExpected =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    <> "<Name>demo.resolvefintech.com.</Name><Type>A</Type><TTL>60</TTL>"
    <> "<ResourceRecords><ResourceRecord><Value>1.2.3.4</Value></ResourceRecord></ResourceRecords>"
    <> "</ResourceRecordSet></Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>"

multiAExpected :: ByteString
multiAExpected =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\">"
    <> "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
    <> "<Name>demo.resolvefintech.com.</Name><Type>A</Type><TTL>60</TTL><ResourceRecords>"
    <> "<ResourceRecord><Value>1.2.3.4</Value></ResourceRecord>"
    <> "<ResourceRecord><Value>5.6.7.8</Value></ResourceRecord>"
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

-- No-seams source scan -------------------------------------------------------

nativeModulePaths :: [FilePath]
nativeModulePaths =
  [ "src/Prodbox/Aws/CredentialHandle.hs"
  , "src/Prodbox/Aws/Native/Xml.hs"
  , "src/Prodbox/Aws/Native/Wire.hs"
  , "src/Prodbox/Aws/Native/Sts.hs"
  , "src/Prodbox/Aws/Native/Iam.hs"
  , "src/Prodbox/Aws/Native/Route53.hs"
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

    describe "Route 53 change-batch XML is a deterministic function of the desired records" $ do
      it "renders a single A UPSERT with a trailing dot" $
        renderChangeBatchXml [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["1.2.3.4"])]
          `shouldBe` singleAExpected
      it "renders multiple values in list order" $
        renderChangeBatchXml
          [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordA 60 ["1.2.3.4", "5.6.7.8"])]
          `shouldBe` multiAExpected
      it "escapes quotes in a TXT value" $
        renderChangeBatchXml
          [(Upsert, ResourceRecordSet "demo.resolvefintech.com" RecordTXT 300 ["\"v=spf1 -all\""])]
          `shouldBe` txtExpected
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
      it "refuses an empty change set before signing" $ do
        let r53 = newRoute53Client baseHandle (respond 200 "")
        result <- changeResourceRecordSets r53 "Z123" []
        result `shouldBe` Left (AwsSigningError "refusing to write empty Route 53 change set")

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
      it "none of the seven native modules contains an env/profile/temp-file/subprocess reference" $ do
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
