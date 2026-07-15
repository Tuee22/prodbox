{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.66: the native SigV4 Model-B object-store client.
--
-- This replaces the @aws@ CLI subprocess (and its per-operation temp-file
-- bodies) under every Model-B object-store operation with in-memory,
-- SigV4-signed S3 requests sent over the one shared TLS 'Manager' from
-- Sprint 1.64 ("Prodbox.Http.Client"). It removes the third gateway hot-path
-- CPU driver behind counterexample @LCPC-2026-07-11@.
--
-- Every function mirrors the subprocess client's signature and outcome taxonomy
-- ("Prodbox.Minio.ObjectStore") so the two are drop-in interchangeable: a
-- missing key or bucket is @Right Nothing@ (positively absent), a conditional-put
-- precondition failure is 'ConditionalPutConflict', and failure-to-observe stays
-- @Left@. The signing algebra ('signS3Request') is pure and, together with
-- "Prodbox.Aws.SigV4", unit-tested; the live native-vs-subprocess parity against
-- a real MinIO endpoint is a Standard-O live-proof axis.
module Prodbox.Minio.ObjectStoreNative
  ( getObject
  , getObjectVersioned
  , putObject
  , putIfAbsent
  , putIfAbsentObserved
  , putIfVersion
  , putIfVersionObserved
  , deleteObject
  , listKeys
  , ensureObjectStoreBucket
  , S3Timestamp (..)
  , signS3Request
  , objectStoreRegion
  , objectStoreService
  )
where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Network.HTTP.Client
  ( Request (..)
  , RequestBody (..)
  , Response (..)
  , httpLbs
  , parseRequest
  )
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)
import Prodbox.Aws.SigV4
import Prodbox.Http.Client (sharedTlsManager)
import Prodbox.Minio.ObjectStoreTypes

objectStoreRegion :: ByteString
objectStoreRegion = "us-east-1"

objectStoreService :: ByteString
objectStoreService = "s3"

-- | The two SigV4 timestamps: @amzDate@ is @YYYYMMDDTHHMMSSZ@ and @dateStamp@
-- is @YYYYMMDD@. Split out so the signing algebra is pure and testable.
data S3Timestamp = S3Timestamp
  { s3AmzDate :: ByteString
  , s3DateStamp :: ByteString
  }
  deriving (Eq, Show)

s3TimestampFromUtc :: UTCTime -> S3Timestamp
s3TimestampFromUtc now =
  S3Timestamp
    { s3AmzDate = BS8.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now)
    , s3DateStamp = BS8.pack (formatTime defaultTimeLocale "%Y%m%d" now)
    }

-- | The full signed header set for one S3 request, given the endpoint host
-- header, method, raw path, raw query, body, extra headers, credentials, and
-- timestamp. Pure and deterministic; the IO layer copies these onto the
-- 'Request'.
signS3Request
  :: SigV4Credentials
  -> ByteString
  -- ^ host header value (e.g. @127.0.0.1:39000@)
  -> ByteString
  -- ^ HTTP method
  -> ByteString
  -- ^ raw (un-encoded) absolute path
  -> [(ByteString, ByteString)]
  -- ^ raw (un-encoded) query pairs
  -> ByteString
  -- ^ request body (in memory)
  -> [(ByteString, ByteString)]
  -- ^ extra headers to sign (e.g. conditional If-None-Match)
  -> S3Timestamp
  -> [(ByteString, ByteString)]
signS3Request credentials hostHeader httpMethod rawPath rawQuery body extraHeaders timestamp =
  ("Authorization", authorization) : baseHeaders
 where
  payloadHash = hexSha256 body
  baseHeaders =
    [ ("host", hostHeader)
    , ("x-amz-content-sha256", payloadHash)
    , ("x-amz-date", s3AmzDate timestamp)
    ]
      ++ extraHeaders
  scope =
    SigV4Scope
      { sigV4DateStamp = s3DateStamp timestamp
      , sigV4Region = objectStoreRegion
      , sigV4Service = objectStoreService
      }
  request =
    SigV4Request
      { sigV4Method = httpMethod
      , sigV4Path = rawPath
      , sigV4Query = rawQuery
      , sigV4Headers = baseHeaders
      , sigV4PayloadHashHex = payloadHash
      }
  authorization = sigV4AuthorizationHeader credentials scope (s3AmzDate timestamp) request

credentialsOf :: ObjectStoreConfig -> SigV4Credentials
credentialsOf config =
  SigV4Credentials
    { sigV4AccessKeyId = BS8.pack (objectStoreAccessKey config)
    , sigV4SecretAccessKey = BS8.pack (objectStoreSecretKey config)
    }

-- | The @host:port@ header value http-client sends for the endpoint, so the
-- signed @host@ header matches the wire exactly.
hostHeaderFor :: Request -> ByteString
hostHeaderFor req
  | isDefaultPort = host req
  | otherwise = host req <> BS8.pack (":" ++ show (port req))
 where
  isDefaultPort =
    (secure req && port req == 443) || (not (secure req) && port req == 80)

-- | Build and send one signed S3 request, returning @(status, headers, body)@.
performS3
  :: ObjectStoreConfig
  -> ByteString
  -- ^ method
  -> ByteString
  -- ^ raw path (e.g. @/bucket/key@)
  -> [(ByteString, ByteString)]
  -- ^ raw query pairs
  -> ByteString
  -- ^ body
  -> [(ByteString, ByteString)]
  -- ^ extra headers to sign
  -> IO (Either String (Int, [Header], BS.ByteString))
performS3 config httpMethod rawPath rawQuery body extraHeaders = do
  baseResult <- try (parseRequest (objectStoreEndpoint config)) :: IO (Either SomeException Request)
  case baseResult of
    Left err -> pure (Left ("invalid object-store endpoint: " ++ show err))
    Right base -> do
      now <- getCurrentTime
      let timestamp = s3TimestampFromUtc now
          hostHeader = hostHeaderFor base
          wirePath = canonicalUri rawPath :: ByteString
          wireQuery =
            if null rawQuery
              then ""
              else "?" <> canonicalQueryString rawQuery
          signed =
            signS3Request
              (credentialsOf config)
              hostHeader
              httpMethod
              rawPath
              rawQuery
              body
              extraHeaders
              timestamp
          request =
            base
              { method = httpMethod
              , path = wirePath
              , queryString = wireQuery
              , requestHeaders = [(CI.mk name, value) | (name, value) <- signed]
              , requestBody = RequestBodyBS body
              }
      sendResult <-
        try (httpLbs request sharedTlsManager) :: IO (Either SomeException (Response BL.ByteString))
      pure $ case sendResult of
        Left err -> Left ("object-store request failed: " ++ show err)
        Right response ->
          Right
            ( statusCode (responseStatus response)
            , responseHeaders response
            , BL.toStrict (responseBody response)
            )

objectPath :: ObjectStoreConfig -> Text -> ByteString
objectPath config key =
  BS8.pack ("/" ++ objectStoreBucket config ++ "/") <> TextEncoding.encodeUtf8 key

bucketPath :: ObjectStoreConfig -> ByteString
bucketPath config = BS8.pack ("/" ++ objectStoreBucket config)

lookupHeader :: ByteString -> [Header] -> Maybe ByteString
lookupHeader name headers = snd <$> find ((== CI.mk name) . fst) headers

etagOf :: [Header] -> Maybe ObjectVersion
etagOf headers = do
  raw <- lookupHeader "ETag" headers
  pure (ObjectVersion (Text.pack (BS8.unpack (stripQuotes raw))))

stripQuotes :: ByteString -> ByteString
stripQuotes value =
  case BS8.uncons value of
    Just ('"', rest) -> BS.take (BS.length rest - 1) rest
    _ -> value

isAbsent :: Int -> Bool
isAbsent status = status == 404

isConditionalConflict :: Int -> Bool
isConditionalConflict status = status == 412

getObject :: ObjectStoreConfig -> Text -> IO (Either String (Maybe ByteString))
getObject config key = do
  result <- performS3 config "GET" (objectPath config key) [] "" []
  pure $ case result of
    Left err -> Left err
    Right (status, _, body)
      | status >= 200 && status < 300 -> Right (Just body)
      | isAbsent status -> Right Nothing
      | otherwise -> Left ("object-store GET failed (" ++ show status ++ "): " ++ shortBody body)

getObjectVersioned :: ObjectStoreConfig -> Text -> IO (Either String (Maybe VersionedObject))
getObjectVersioned config key = do
  result <- performS3 config "GET" (objectPath config key) [] "" []
  pure $ case result of
    Left err -> Left err
    Right (status, headers, body)
      | status >= 200 && status < 300 ->
          case etagOf headers of
            Nothing -> Left "object-store GET succeeded but returned no ETag version"
            Just version -> Right (Just (VersionedObject body version))
      | isAbsent status -> Right Nothing
      | otherwise -> Left ("object-store GET failed (" ++ show status ++ "): " ++ shortBody body)

putObject :: ObjectStoreConfig -> Text -> ByteString -> IO (Either String ())
putObject config key bytes = putGuarded config key bytes []

putIfAbsent :: ObjectStoreConfig -> Text -> ByteString -> IO (Either String ())
putIfAbsent config key bytes = putGuarded config key bytes [("If-None-Match", "*")]

putIfAbsentObserved
  :: ObjectStoreConfig -> Text -> ByteString -> IO (Either String ConditionalPutResult)
putIfAbsentObserved config key bytes = putConditional config key bytes [("If-None-Match", "*")]

putIfVersion :: ObjectStoreConfig -> Text -> ObjectVersion -> ByteString -> IO (Either String ())
putIfVersion config key version bytes =
  putGuarded config key bytes [("If-Match", ifMatchValue version)]

putIfVersionObserved
  :: ObjectStoreConfig -> Text -> ObjectVersion -> ByteString -> IO (Either String ConditionalPutResult)
putIfVersionObserved config key version bytes =
  putConditional config key bytes [("If-Match", ifMatchValue version)]

ifMatchValue :: ObjectVersion -> ByteString
ifMatchValue version = "\"" <> TextEncoding.encodeUtf8 (objectVersionEtag version) <> "\""

-- | An unconditional-or-guarded put that treats a precondition failure as a
-- 'Left' error (the non-observed variants).
putGuarded
  :: ObjectStoreConfig -> Text -> ByteString -> [(ByteString, ByteString)] -> IO (Either String ())
putGuarded config key bytes extraHeaders = do
  ensured <- ensureObjectStoreBucket config
  case ensured of
    Left err -> pure (Left err)
    Right () -> do
      result <- performS3 config "PUT" (objectPath config key) [] bytes extraHeaders
      pure $ case result of
        Left err -> Left err
        Right (status, _, body)
          | status >= 200 && status < 300 -> Right ()
          | otherwise -> Left ("object-store PUT failed (" ++ show status ++ "): " ++ shortBody body)

-- | A conditional put that maps a precondition failure to
-- 'ConditionalPutConflict' (the observed variants).
putConditional
  :: ObjectStoreConfig
  -> Text
  -> ByteString
  -> [(ByteString, ByteString)]
  -> IO (Either String ConditionalPutResult)
putConditional config key bytes extraHeaders = do
  ensured <- ensureObjectStoreBucket config
  case ensured of
    Left err -> pure (Left err)
    Right () -> do
      result <- performS3 config "PUT" (objectPath config key) [] bytes extraHeaders
      pure $ case result of
        Left err -> Left err
        Right (status, _, body)
          | status >= 200 && status < 300 -> Right ConditionalPutApplied
          | isConditionalConflict status -> Right ConditionalPutConflict
          | otherwise ->
              Left ("object-store conditional PUT failed (" ++ show status ++ "): " ++ shortBody body)

deleteObject :: ObjectStoreConfig -> Text -> IO (Either String ())
deleteObject config key = do
  result <- performS3 config "DELETE" (objectPath config key) [] "" []
  pure $ case result of
    Left err -> Left err
    Right (status, _, body)
      -- S3 delete-object is idempotent: 204/200 on success, and a missing key
      -- also returns 204. A missing bucket (404) is treated as already-absent.
      | (status >= 200 && status < 300) || isAbsent status -> Right ()
      | otherwise -> Left ("object-store DELETE failed (" ++ show status ++ "): " ++ shortBody body)

listKeys :: ObjectStoreConfig -> IO (Either String [Text])
listKeys config = do
  result <- performS3 config "GET" (bucketPath config) [("list-type", "2")] "" []
  pure $ case result of
    Left err -> Left err
    Right (status, _, body)
      | status >= 200 && status < 300 -> parseListKeysXml body
      | otherwise -> Left ("object-store list failed (" ++ show status ++ "): " ++ shortBody body)

ensureObjectStoreBucket :: ObjectStoreConfig -> IO (Either String ())
ensureObjectStoreBucket config = do
  headResult <- performS3 config "HEAD" (bucketPath config) [] "" []
  case headResult of
    Left err -> pure (Left err)
    Right (status, _, _)
      | status >= 200 && status < 300 -> verifyListable config
      | isAbsent status -> do
          createResult <- performS3 config "PUT" (bucketPath config) [] "" []
          case createResult of
            Left err -> pure (Left err)
            Right (createStatus, _, createBody)
              | createStatus >= 200 && createStatus < 300 -> verifyListable config
              | otherwise ->
                  pure
                    (Left ("object-store create-bucket failed (" ++ show createStatus ++ "): " ++ shortBody createBody))
      | otherwise ->
          pure (Left ("object-store head-bucket failed (" ++ show status ++ ")"))

verifyListable :: ObjectStoreConfig -> IO (Either String ())
verifyListable config = do
  result <- performS3 config "GET" (bucketPath config) [("list-type", "2"), ("max-keys", "1")] "" []
  pure $ case result of
    Left err -> Left err
    Right (status, _, body)
      | status >= 200 && status < 300 -> Right ()
      | otherwise ->
          Left ("object-store bucket is not listable (" ++ show status ++ "): " ++ shortBody body)

-- | Extract @<Key>…</Key>@ values from an S3 @ListObjectsV2@ XML response. The
-- store returns XML (not JSON) on the native path; this is a deliberately small
-- extractor over the one element the callers need.
parseListKeysXml :: ByteString -> Either String [Text]
parseListKeysXml body =
  Right (map (Text.pack . BS8.unpack) (extractBetween "<Key>" "</Key>" body))

extractBetween :: ByteString -> ByteString -> ByteString -> [ByteString]
extractBetween open close = go
 where
  go haystack =
    case breakAfter open haystack of
      Nothing -> []
      Just afterOpen ->
        case breakBefore close afterOpen of
          Nothing -> []
          Just (value, rest) -> value : go rest

breakAfter :: ByteString -> ByteString -> Maybe ByteString
breakAfter needle haystack =
  let (_, matched) = BS.breakSubstring needle haystack
   in if BS.null matched
        then Nothing
        else Just (BS.drop (BS.length needle) matched)

breakBefore :: ByteString -> ByteString -> Maybe (ByteString, ByteString)
breakBefore needle haystack =
  let (before, matched) = BS.breakSubstring needle haystack
   in if BS.null matched
        then Nothing
        else Just (before, BS.drop (BS.length needle) matched)

shortBody :: ByteString -> String
shortBody body =
  let text = BS8.unpack body
   in if length text > 200 then take 200 text ++ "…" else text
