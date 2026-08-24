{-# LANGUAGE OverloadedStrings #-}

-- | Narrow native S3 bucket client used by the one-shot Credential
-- Provisioner.  It owns only the deterministic long-lived bucket bootstrap
-- vocabulary: positive presence observation, create-if-absent, and exact
-- hardening configuration/read-back.  Object transport and arbitrary bucket
-- selection are deliberately outside this module.
module Prodbox.Aws.Native.S3
  ( S3Client (..)
  , S3BucketObservation (..)
  , S3BucketHardening (..)
  , expectedLongLivedBucketHardening
  , newS3Client
  , s3Endpoint
  , s3Scope
  , s3BucketPath
  , renderCreateBucketXml
  , renderBucketVersioningXml
  , renderBucketEncryptionXml
  , renderPublicAccessBlockXml
  , renderBucketTaggingXml
  , renderBucketLifecycleXml
  , parseBucketVersioning
  , parseBucketEncryption
  , parsePublicAccessBlock
  , parseBucketTagging
  , parseBucketLifecycle
  )
where

import Control.Monad (void)
import Crypto.Hash (Digest, MD5, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Prodbox.Aws.CredentialHandle
  ( CredentialHandle
  , credentialHandleRegion
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (AwsResponseParseFailure, AwsServiceError)
  , AwsEndpoint (AwsEndpoint)
  , AwsErrorFormat (XmlErrorFormat)
  , AwsScope (AwsScope)
  , AwsServiceFault (awsFaultCode, awsFaultHttpStatus)
  , AwsTimestamp
  , Idempotency (Idempotent)
  , NativeAwsSender
  , SignedHttpRequest
  , buildSignedRequest
  , performAwsRequest
  )
import Prodbox.Aws.Native.Xml (extractAll, extractFirst, xmlEscape)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Lifecycle.OwnedResourceTags
  ( OwnedResourceTag
  , longLivedPulumiStateBucketTags
  )

data S3BucketObservation
  = S3BucketAbsent
  | S3BucketPresent
  deriving (Eq, Show)

-- | Exact hardening state required before a long-lived bucket may be used by
-- the Backup or TLS adapters.
data S3BucketHardening = S3BucketHardening
  { s3BucketVersioningEnabled :: !Bool
  , s3BucketAes256Encryption :: !Bool
  , s3BucketPublicAccessBlocked :: !Bool
  , s3BucketManagedTags :: ![(Text, Text)]
  , s3BucketNoncurrentExpiryDays :: !(Maybe Int)
  }
  deriving (Eq, Show)

expectedLongLivedBucketHardening :: S3BucketHardening
expectedLongLivedBucketHardening =
  S3BucketHardening
    { s3BucketVersioningEnabled = True
    , s3BucketAes256Encryption = True
    , s3BucketPublicAccessBlocked = True
    , s3BucketManagedTags = sort longLivedPulumiStateBucketTags
    , s3BucketNoncurrentExpiryDays = Just 90
    }

data S3Client = S3Client
  { observeBucket :: Text -> IO (Either AwsClientError S3BucketObservation)
  , createBucket :: Text -> IO (Either AwsClientError ())
  , putBucketHardening :: Text -> IO (Either AwsClientError ())
  , observeBucketHardening :: Text -> IO (Either AwsClientError S3BucketHardening)
  }

newS3Client :: CredentialHandle origin -> NativeAwsSender -> S3Client
newS3Client handle sender =
  S3Client
    { observeBucket = runObserveBucket handle sender
    , createBucket = runCreateBucket handle sender
    , putBucketHardening = runPutBucketHardening handle sender
    , observeBucketHardening = runObserveBucketHardening handle sender
    }

s3Endpoint :: ByteString -> AwsEndpoint
s3Endpoint region =
  AwsEndpoint
    ("https://s3." <> ByteString8.unpack region <> ".amazonaws.com")
    ("s3." <> region <> ".amazonaws.com")

s3Scope :: ByteString -> AwsScope
s3Scope region = AwsScope region "s3"

s3BucketPath :: Text -> ByteString
s3BucketPath bucket = "/" <> encodeUtf8 bucket

renderCreateBucketXml :: ByteString -> ByteString
renderCreateBucketXml region
  | region == awsGlobalServiceRegion = ""
  | otherwise =
      "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        <> "<LocationConstraint>"
        <> xmlEscape region
        <> "</LocationConstraint></CreateBucketConfiguration>"

renderBucketVersioningXml :: ByteString
renderBucketVersioningXml =
  "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    <> "<Status>Enabled</Status></VersioningConfiguration>"

renderBucketEncryptionXml :: ByteString
renderBucketEncryptionXml =
  "<ServerSideEncryptionConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    <> "<Rule><ApplyServerSideEncryptionByDefault><SSEAlgorithm>AES256</SSEAlgorithm>"
    <> "</ApplyServerSideEncryptionByDefault></Rule></ServerSideEncryptionConfiguration>"

renderPublicAccessBlockXml :: ByteString
renderPublicAccessBlockXml =
  "<PublicAccessBlockConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    <> "<BlockPublicAcls>true</BlockPublicAcls><IgnorePublicAcls>true</IgnorePublicAcls>"
    <> "<BlockPublicPolicy>true</BlockPublicPolicy><RestrictPublicBuckets>true</RestrictPublicBuckets>"
    <> "</PublicAccessBlockConfiguration>"

-- | Render a tag set.  The set is a parameter rather than a literal because
-- the writer and the read-back expectation below are two statements of one
-- fact, and they were separately authored; both now read
-- 'longLivedPulumiStateBucketTags'.
renderBucketTaggingXml :: [OwnedResourceTag] -> ByteString
renderBucketTaggingXml tags =
  "<Tagging xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><TagSet>"
    <> foldMap renderTag tags
    <> "</TagSet></Tagging>"
 where
  renderTag (key, value) =
    "<Tag><Key>"
      <> xmlEscape (encodeUtf8 key)
      <> "</Key><Value>"
      <> xmlEscape (encodeUtf8 value)
      <> "</Value></Tag>"

renderBucketLifecycleXml :: ByteString
renderBucketLifecycleXml =
  "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
    <> "<Rule><ID>prodbox-noncurrent-90d-expiry</ID><Status>Enabled</Status><Filter><Prefix></Prefix></Filter>"
    <> "<NoncurrentVersionExpiration><NoncurrentDays>90</NoncurrentDays>"
    <> "</NoncurrentVersionExpiration></Rule></LifecycleConfiguration>"

parseBucketVersioning :: ByteString -> Either String Bool
parseBucketVersioning body =
  case extractFirst "<Status>" "</Status>" body of
    Nothing -> Right False
    Just "Enabled" -> Right True
    Just "Suspended" -> Right False
    Just _ -> Left "S3 GetBucketVersioning returned an unknown status"

parseBucketEncryption :: ByteString -> Either String Bool
parseBucketEncryption body =
  case extractAll "<SSEAlgorithm>" "</SSEAlgorithm>" body of
    ["AES256"] -> Right True
    [_] -> Right False
    [] -> Left "S3 GetBucketEncryption omitted the algorithm"
    _ -> Left "S3 GetBucketEncryption returned multiple rules"

parsePublicAccessBlock :: ByteString -> Either String Bool
parsePublicAccessBlock body =
  and
    <$> traverse
      (parseBooleanElement body)
      [ "BlockPublicAcls"
      , "IgnorePublicAcls"
      , "BlockPublicPolicy"
      , "RestrictPublicBuckets"
      ]

parseBucketTagging :: ByteString -> Either String [(Text, Text)]
parseBucketTagging body =
  sort <$> traverse parseTag (extractAll "<Tag>" "</Tag>" body)
 where
  parseTag raw = do
    key <- requiredText "Key" raw
    value <- requiredText "Value" raw
    pure (key, value)

parseBucketLifecycle :: ByteString -> Either String (Maybe Int)
parseBucketLifecycle body = do
  rule <-
    maybe
      (Left "S3 GetBucketLifecycleConfiguration omitted the managed rule")
      Right
      ( findManagedRule
          (extractAll "<Rule>" "</Rule>" body)
      )
  status <- requiredText "Status" rule
  days <- requiredText "NoncurrentDays" rule
  case (status, reads (Text.unpack days)) of
    ("Enabled", [(value, "")]) | value > 0 -> Right (Just value)
    ("Disabled", _) -> Right Nothing
    _ -> Left "S3 lifecycle managed rule has an invalid status or expiry"
 where
  findManagedRule = findFirst hasManagedId
  hasManagedId raw =
    extractFirst "<ID>" "</ID>" raw == Just "prodbox-noncurrent-90d-expiry"

runObserveBucket
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError S3BucketObservation)
runObserveBucket handle sender bucket = do
  result <- request handle sender "s3:HeadBucket" "HEAD" bucket [] ""
  pure $ case result of
    Right _ -> Right S3BucketPresent
    Left err
      | isHttpNotFound err -> Right S3BucketAbsent
      | otherwise -> Left err

runCreateBucket
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError ())
runCreateBucket handle sender bucket = do
  result <-
    request
      handle
      sender
      "s3:CreateBucket"
      "PUT"
      bucket
      []
      (renderCreateBucketXml (credentialHandleRegion handle))
  pure $ case result of
    Right _ -> Right ()
    Left err
      | isFaultCode "BucketAlreadyOwnedByYou" err -> Right ()
      | otherwise -> Left err

runPutBucketHardening
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError ())
runPutBucketHardening handle sender bucket =
  sequenceEffects
    [ put "s3:PutBucketVersioning" "versioning" renderBucketVersioningXml
    , put "s3:PutBucketEncryption" "encryption" renderBucketEncryptionXml
    , put "s3:PutPublicAccessBlock" "publicAccessBlock" renderPublicAccessBlockXml
    , put
        "s3:PutBucketTagging"
        "tagging"
        (renderBucketTaggingXml longLivedPulumiStateBucketTags)
    , put "s3:PutBucketLifecycleConfiguration" "lifecycle" renderBucketLifecycleXml
    ]
 where
  put label subresource body =
    void <$> request handle sender label "PUT" bucket [(subresource, "")] body

runObserveBucketHardening
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> IO (Either AwsClientError S3BucketHardening)
runObserveBucketHardening handle sender bucket = do
  versioning <- getAndParse "s3:GetBucketVersioning" "versioning" parseBucketVersioning
  encryption <-
    getAndParseMissing
      "s3:GetBucketEncryption"
      "encryption"
      "ServerSideEncryptionConfigurationNotFoundError"
      parseBucketEncryption
      False
  publicAccess <-
    getAndParseMissing
      "s3:GetPublicAccessBlock"
      "publicAccessBlock"
      "NoSuchPublicAccessBlockConfiguration"
      parsePublicAccessBlock
      False
  tags <-
    getAndParseMissing
      "s3:GetBucketTagging"
      "tagging"
      "NoSuchTagSet"
      parseBucketTagging
      []
  lifecycle <-
    getAndParseMissing
      "s3:GetBucketLifecycleConfiguration"
      "lifecycle"
      "NoSuchLifecycleConfiguration"
      parseBucketLifecycle
      Nothing
  pure $ do
    observedVersioning <- versioning
    observedEncryption <- encryption
    observedPublicAccess <- publicAccess
    observedTags <- tags
    observedLifecycle <- lifecycle
    Right
      S3BucketHardening
        { s3BucketVersioningEnabled = observedVersioning
        , s3BucketAes256Encryption = observedEncryption
        , s3BucketPublicAccessBlocked = observedPublicAccess
        , s3BucketManagedTags = sort observedTags
        , s3BucketNoncurrentExpiryDays = observedLifecycle
        }
 where
  getAndParse label subresource parser = do
    result <- request handle sender label "GET" bucket [(subresource, "")] ""
    pure $ case result of
      Left err -> Left err
      Right body -> firstParse parser body

  getAndParseMissing label subresource missingCode parser missingValue = do
    result <- request handle sender label "GET" bucket [(subresource, "")] ""
    pure $ case result of
      Left err
        | isFaultCode missingCode err -> Right missingValue
        | otherwise -> Left err
      Right body -> firstParse parser body

request
  :: CredentialHandle origin
  -> NativeAwsSender
  -> Text
  -> ByteString
  -> Text
  -> [(ByteString, ByteString)]
  -> ByteString
  -> IO (Either AwsClientError ByteString)
request handle sender label method bucket query body =
  performAwsRequest
    sender
    (\timestamp -> signS3Request handle timestamp method bucket query body)
    label
    Idempotent
    XmlErrorFormat

signS3Request
  :: CredentialHandle origin
  -> AwsTimestamp
  -> ByteString
  -> Text
  -> [(ByteString, ByteString)]
  -> ByteString
  -> SignedHttpRequest
signS3Request handle timestamp method bucket query body =
  buildSignedRequest
    (toSigV4Credentials handle)
    (credentialHandleSecurityToken handle)
    (s3Scope region)
    (s3Endpoint region)
    timestamp
    method
    (s3BucketPath bucket)
    query
    body
    headers
 where
  region = credentialHandleRegion handle
  headers
    | method == "PUT" && not (null query) =
        [ ("content-type", "application/xml")
        , ("content-md5", contentMd5 body)
        ]
    | method == "PUT" && not (ByteString8.null body) =
        [("content-type", "application/xml")]
    | otherwise = []

contentMd5 :: ByteString -> ByteString
contentMd5 body = Base64.encode (convert (hash body :: Digest MD5))

sequenceEffects :: [IO (Either error ())] -> IO (Either error ())
sequenceEffects effects = go effects
 where
  go remaining = case remaining of
    [] -> pure (Right ())
    effect : rest -> do
      result <- effect
      case result of
        Left err -> pure (Left err)
        Right () -> go rest

parseBooleanElement :: ByteString -> ByteString -> Either String Bool
parseBooleanElement body name = case extractFirst open close body of
  Just "true" -> Right True
  Just "false" -> Right False
  Just _ -> Left ("S3 boolean field is invalid: " <> ByteString8.unpack name)
  Nothing -> Left ("S3 boolean field is missing: " <> ByteString8.unpack name)
 where
  open = "<" <> name <> ">"
  close = "</" <> name <> ">"

requiredText :: ByteString -> ByteString -> Either String Text
requiredText name body =
  maybe
    (Left ("S3 XML field is missing: " <> ByteString8.unpack name))
    (Right . decodeUtf8)
    (extractFirst ("<" <> name <> ">") ("</" <> name <> ">") body)

findFirst :: (value -> Bool) -> [value] -> Maybe value
findFirst predicate values = case values of
  [] -> Nothing
  value : rest
    | predicate value -> Just value
    | otherwise -> findFirst predicate rest

firstParse
  :: (ByteString -> Either String value)
  -> ByteString
  -> Either AwsClientError value
firstParse parser = either (Left . AwsResponseParseFailure) Right . parser

isHttpNotFound :: AwsClientError -> Bool
isHttpNotFound err = case err of
  AwsServiceError fault -> awsFaultHttpStatus fault == 404
  _ -> False

isFaultCode :: Text -> AwsClientError -> Bool
isFaultCode expected err = case err of
  AwsServiceError fault -> awsFaultCode fault == expected
  _ -> False
