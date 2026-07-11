{-# LANGUAGE OverloadedStrings #-}

-- | Typed S3-compatible object access for the prodbox-owned MinIO object
-- store. Logical names are owned by "Prodbox.Minio.EncryptedObject"; this
-- module only moves opaque object bytes.
module Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , ConditionalPutResult (..)
  , ObjectVersion (..)
  , VersionedObject (..)
  , defaultObjectStoreBucket
  , deleteObject
  , ensureObjectStoreBucket
  , getObject
  , getObjectVersioned
  , isNoSuchBucketOutput
  , listKeys
  , objectStoreCreateBucketArgs
  , objectStoreDeleteObjectArgs
  , objectStoreHeadBucketArgs
  , objectStoreListKeysArgs
  , putIfAbsent
  , putIfAbsentObserved
  , putIfVersion
  , putIfVersionObserved
  , putObject
  )
where

import Control.Exception (IOException, try)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.MinioBackend
  ( minioAwsEnv
  , minioGetObjectArgs
  , minioPutObjectArgs
  )
import Prodbox.Service
  ( AsServiceError
  , runMinIOWithEnv
  , serviceErrorMessage
  , toServiceError
  )
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

data ObjectStoreConfig = ObjectStoreConfig
  { objectStoreEndpoint :: String
  , objectStoreBucket :: String
  , objectStoreAccessKey :: String
  , objectStoreSecretKey :: String
  }
  deriving (Eq, Show)

-- | Opaque object generation returned by the S3-compatible store.  Callers
-- may compare or feed it back to 'putIfVersion', but cannot manufacture a
-- generation from untrusted payload data.
newtype ObjectVersion = ObjectVersion {objectVersionEtag :: Text}
  deriving (Eq, Ord, Show)

data VersionedObject = VersionedObject
  { versionedObjectBytes :: ByteString
  , versionedObjectVersion :: ObjectVersion
  }
  deriving (Eq, Show)

data ConditionalPutResult
  = ConditionalPutApplied
  | ConditionalPutConflict
  deriving (Eq, Show)

defaultObjectStoreBucket :: String
defaultObjectStoreBucket = "prodbox-state"

getObject :: ObjectStoreConfig -> Text -> IO (Either String (Maybe ByteString))
getObject config key =
  withSystemTempDirectory "prodbox-object-store" $ \tmpDir -> do
    let outputPath = tmpDir </> "object.enc"
    result <-
      runMinIOWithEnv
        (Just (objectStoreEnv config))
        ( minioGetObjectArgs
            (objectStoreEndpoint config)
            (objectStoreBucket config)
            (Text.unpack key)
            outputPath
        )
    case result of
      Left err -> pure (Left ("failed to fetch object-store object: " ++ renderMinIOError err))
      Right output ->
        case processExitCode output of
          ExitFailure _ ->
            -- A missing key OR a missing bucket is definitive absence of the
            -- object (Right Nothing). A missing bucket happens on first-ever
            -- bring-up before the SSoT bucket is created, and the seed's
            -- presence probe must read that as "absent → seed" (the seed write
            -- then creates the bucket) rather than a hard failure that would
            -- abort the seal and leave the bucket forever uncreated. A
            -- connection/credential failure stays a Left, so it never reads as
            -- absence (failure to observe is not absence).
            if isNoSuchKeyOutput output || isNoSuchBucketOutput output
              then pure (Right Nothing)
              else pure (Left ("aws s3api get-object failed: " ++ trim (processStderr output)))
          ExitSuccess -> do
            readResult <- try (BS.readFile outputPath) :: IO (Either IOException ByteString)
            pure $ case readResult of
              Left err -> Left ("failed to read fetched object-store object: " ++ show err)
              Right bytes -> Right (Just bytes)

-- | Fetch an object together with the store generation used for a subsequent
-- compare-and-swap.  Failure to observe is never collapsed into absence.
getObjectVersioned
  :: ObjectStoreConfig
  -> Text
  -> IO (Either String (Maybe VersionedObject))
getObjectVersioned config key =
  withSystemTempDirectory "prodbox-object-store-versioned" $ \tmpDir -> do
    let outputPath = tmpDir </> "object.enc"
    result <-
      runMinIOWithEnv
        (Just (objectStoreEnv config))
        ( minioGetObjectArgs
            (objectStoreEndpoint config)
            (objectStoreBucket config)
            (Text.unpack key)
            outputPath
        )
    case result of
      Left err -> pure (Left ("failed to fetch versioned object-store object: " ++ renderMinIOError err))
      Right output ->
        case processExitCode output of
          ExitFailure _
            | isNoSuchKeyOutput output || isNoSuchBucketOutput output -> pure (Right Nothing)
            | otherwise ->
                pure (Left ("aws s3api get-object failed: " ++ trim (processStderr output)))
          ExitSuccess -> do
            readResult <- try (BS.readFile outputPath) :: IO (Either IOException ByteString)
            pure $ do
              bytes <-
                case readResult of
                  Left err -> Left ("failed to read fetched object-store object: " ++ show err)
                  Right value -> Right value
              version <- parseObjectVersion (processStdout output)
              Right (Just (VersionedObject bytes version))

putObject :: ObjectStoreConfig -> Text -> ByteString -> IO (Either String ())
putObject config key bytes =
  putObjectWithArgs config key bytes id

putIfAbsent :: ObjectStoreConfig -> Text -> ByteString -> IO (Either String ())
putIfAbsent config key bytes =
  putObjectWithArgs config key bytes (++ ["--if-none-match", "*"])

putIfAbsentObserved
  :: ObjectStoreConfig
  -> Text
  -> ByteString
  -> IO (Either String ConditionalPutResult)
putIfAbsentObserved config key bytes =
  putObjectConditional config key bytes (++ ["--if-none-match", "*"])

-- | Replace an object only when its current store generation is the one the
-- caller observed.  A conflict is returned as a structured 'Left'; callers
-- must re-read rather than retrying an unobserved write blindly.
putIfVersion
  :: ObjectStoreConfig
  -> Text
  -> ObjectVersion
  -> ByteString
  -> IO (Either String ())
putIfVersion config key version bytes =
  putObjectWithArgs
    config
    key
    bytes
    (++ ["--if-match", Text.unpack (objectVersionEtag version)])

putIfVersionObserved
  :: ObjectStoreConfig
  -> Text
  -> ObjectVersion
  -> ByteString
  -> IO (Either String ConditionalPutResult)
putIfVersionObserved config key version bytes =
  putObjectConditional
    config
    key
    bytes
    (++ ["--if-match", Text.unpack (objectVersionEtag version)])

putObjectConditional
  :: ObjectStoreConfig
  -> Text
  -> ByteString
  -> ([String] -> [String])
  -> IO (Either String ConditionalPutResult)
putObjectConditional config key bytes adjustArgs = do
  bucketResult <- ensureObjectStoreBucket config
  case bucketResult of
    Left err -> pure (Left err)
    Right () ->
      withSystemTempDirectory "prodbox-object-store-conditional" $ \tmpDir -> do
        let inputPath = tmpDir </> "object.enc"
        writeResult <- try (BS.writeFile inputPath bytes) :: IO (Either IOException ())
        case writeResult of
          Left err -> pure (Left ("failed to stage object-store object: " ++ show err))
          Right () -> do
            result <-
              runMinIOWithEnv
                (Just (objectStoreEnv config))
                ( adjustArgs
                    ( minioPutObjectArgs
                        (objectStoreEndpoint config)
                        (objectStoreBucket config)
                        (Text.unpack key)
                        inputPath
                    )
                )
            pure $ case result of
              Left err -> Left ("failed to conditionally store object: " ++ renderMinIOError err)
              Right output ->
                case processExitCode output of
                  ExitSuccess -> Right ConditionalPutApplied
                  ExitFailure _
                    | isConditionalConflictOutput output -> Right ConditionalPutConflict
                    | otherwise ->
                        Left ("aws s3api conditional put-object failed: " ++ trim (processStderr output))

putObjectWithArgs
  :: ObjectStoreConfig
  -> Text
  -> ByteString
  -> ([String] -> [String])
  -> IO (Either String ())
putObjectWithArgs config key bytes adjustArgs =
  do
    bucketResult <- ensureObjectStoreBucket config
    case bucketResult of
      Left err -> pure (Left err)
      Right () ->
        withSystemTempDirectory "prodbox-object-store" $ \tmpDir -> do
          let inputPath = tmpDir </> "object.enc"
          writeResult <- try (BS.writeFile inputPath bytes) :: IO (Either IOException ())
          case writeResult of
            Left err -> pure (Left ("failed to stage object-store object: " ++ show err))
            Right () -> do
              result <-
                runMinIOWithEnv
                  (Just (objectStoreEnv config))
                  ( adjustArgs
                      ( minioPutObjectArgs
                          (objectStoreEndpoint config)
                          (objectStoreBucket config)
                          (Text.unpack key)
                          inputPath
                      )
                  )
              pure $ case result of
                Left err -> Left ("failed to store object-store object: " ++ renderMinIOError err)
                Right output ->
                  case processExitCode output of
                    ExitFailure _ -> Left ("aws s3api put-object failed: " ++ trim (processStderr output))
                    ExitSuccess -> Right ()

ensureObjectStoreBucket :: ObjectStoreConfig -> IO (Either String ())
ensureObjectStoreBucket config = do
  let environment = objectStoreEnv config
      endpoint = objectStoreEndpoint config
      bucket = objectStoreBucket config
  headResult <-
    runMinIOWithEnv
      (Just environment)
      (objectStoreHeadBucketArgs endpoint bucket)
  case headResult of
    Left err -> pure (Left ("failed to check object-store bucket: " ++ renderMinIOError err))
    Right headOutput ->
      case processExitCode headOutput of
        ExitSuccess -> verifyObjectStoreBucketListable config
        ExitFailure _ -> do
          createResult <-
            runMinIOWithEnv
              (Just environment)
              (objectStoreCreateBucketArgs endpoint bucket)
          case createResult of
            Left err -> pure (Left ("failed to create object-store bucket: " ++ renderMinIOError err))
            Right createOutput ->
              case processExitCode createOutput of
                ExitSuccess -> verifyObjectStoreBucketListable config
                ExitFailure _ ->
                  pure (Left ("aws s3api create-bucket failed: " ++ trim (processStderr createOutput)))

verifyObjectStoreBucketListable :: ObjectStoreConfig -> IO (Either String ())
verifyObjectStoreBucketListable config = do
  result <-
    runMinIOWithEnv
      (Just (objectStoreEnv config))
      ( objectStoreListKeysArgs (objectStoreEndpoint config) (objectStoreBucket config)
          ++ ["--max-keys", "1"]
      )
  pure $
    case result of
      Left err -> Left ("failed to verify object-store bucket listing: " ++ renderMinIOError err)
      Right output ->
        case processExitCode output of
          ExitFailure _ ->
            Left ("object-store bucket is not listable: " ++ trim (processStderr output))
          ExitSuccess -> Right ()

listKeys :: ObjectStoreConfig -> IO (Either String [Text])
listKeys config = do
  result <-
    runMinIOWithEnv
      (Just (objectStoreEnv config))
      (objectStoreListKeysArgs (objectStoreEndpoint config) (objectStoreBucket config))
  pure $ case result of
    Left err -> Left ("failed to list object-store bucket: " ++ renderMinIOError err)
    Right output ->
      case processExitCode output of
        ExitFailure _ -> Left ("aws s3api list-objects-v2 failed: " ++ trim (processStderr output))
        ExitSuccess -> parseListObjectsKeys (processStdout output)

deleteObject :: ObjectStoreConfig -> Text -> IO (Either String ())
deleteObject config key = do
  result <-
    runMinIOWithEnv
      (Just (objectStoreEnv config))
      ( objectStoreDeleteObjectArgs
          (objectStoreEndpoint config)
          (objectStoreBucket config)
          (Text.unpack key)
      )
  pure $ case result of
    Left err -> Left ("failed to delete object-store object: " ++ renderMinIOError err)
    Right output ->
      case processExitCode output of
        ExitFailure _ -> Left ("aws s3api delete-object failed: " ++ trim (processStderr output))
        ExitSuccess -> Right ()

objectStoreListKeysArgs :: String -> String -> [String]
objectStoreListKeysArgs endpoint bucket =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "list-objects-v2"
  , "--bucket"
  , bucket
  ]

objectStoreHeadBucketArgs :: String -> String -> [String]
objectStoreHeadBucketArgs endpoint bucket =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "head-bucket"
  , "--bucket"
  , bucket
  ]

objectStoreCreateBucketArgs :: String -> String -> [String]
objectStoreCreateBucketArgs endpoint bucket =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "create-bucket"
  , "--bucket"
  , bucket
  ]

objectStoreDeleteObjectArgs :: String -> String -> String -> [String]
objectStoreDeleteObjectArgs endpoint bucket key =
  [ "--endpoint-url"
  , endpoint
  , "s3api"
  , "delete-object"
  , "--bucket"
  , bucket
  , "--key"
  , key
  ]

objectStoreEnv :: ObjectStoreConfig -> [(String, String)]
objectStoreEnv config =
  minioAwsEnv (objectStoreAccessKey config) (objectStoreSecretKey config)

parseListObjectsKeys :: String -> Either String [Text]
parseListObjectsKeys payload =
  case eitherDecode (BL8.pack payload) of
    Left err -> Left ("failed to parse list-objects-v2 JSON: " ++ err)
    Right (Object root) ->
      case KeyMap.lookup (Key.fromString "Contents") root of
        Nothing -> Right []
        Just (Array values) -> traverse parseKey (toList values)
        _ -> Left "failed to parse list-objects-v2 JSON: Contents is not an array"
    Right _ -> Left "failed to parse list-objects-v2 JSON: root is not an object"
 where
  toList = foldr (:) []
  parseKey value =
    case value of
      Object item ->
        case KeyMap.lookup (Key.fromString "Key") item of
          Just (String key) -> Right key
          _ -> Left "failed to parse list-objects-v2 JSON: object missing Key"
      _ -> Left "failed to parse list-objects-v2 JSON: Contents member is not an object"

parseObjectVersion :: String -> Either String ObjectVersion
parseObjectVersion payload =
  case eitherDecode (BL8.pack payload) of
    Left err -> Left ("failed to parse get-object generation JSON: " ++ err)
    Right (Object root) ->
      case KeyMap.lookup (Key.fromString "ETag") root of
        Just (String rawEtag)
          | not (Text.null (Text.strip rawEtag)) ->
              -- S3 returns the entity tag including its RFC validator quotes;
              -- If-Match requires that exact validator value.
              Right (ObjectVersion (Text.strip rawEtag))
        _ -> Left "failed to parse get-object generation JSON: ETag is absent"
    Right _ -> Left "failed to parse get-object generation JSON: root is not an object"

isNoSuchKeyOutput :: ProcessOutput -> Bool
isNoSuchKeyOutput output =
  any (`Text.isInfixOf` stderrText) ["NoSuchKey", "Not Found", "404"]
 where
  stderrText = Text.pack (processStderr output)

-- | A @NoSuchBucket@ response is a DEFINITIVE statement that the object is
-- absent (the storage location does not exist), unlike a connection/credential
-- failure (e.g. @InvalidAccessKeyId@), which is indeterminate and must stay a
-- @Left@. 'getObject' treats this as @Right Nothing@ so first-ever bring-up
-- (before the @prodbox-state@ bucket exists) seeds the SSoT instead of aborting.
isNoSuchBucketOutput :: ProcessOutput -> Bool
isNoSuchBucketOutput output =
  any (`Text.isInfixOf` stderrText) ["NoSuchBucket", "The specified bucket does not exist"]
 where
  stderrText = Text.pack (processStderr output)

isConditionalConflictOutput :: ProcessOutput -> Bool
isConditionalConflictOutput output =
  any
    (`Text.isInfixOf` stderrText)
    [ "PreconditionFailed"
    , "ConditionalRequestConflict"
    , "412"
    , "409"
    ]
 where
  stderrText = Text.pack (processStderr output)

trim :: String -> String
trim =
  Text.unpack . Text.strip . Text.pack

renderMinIOError :: (AsServiceError errorType) => errorType -> String
renderMinIOError =
  Text.unpack . serviceErrorMessage . toServiceError
