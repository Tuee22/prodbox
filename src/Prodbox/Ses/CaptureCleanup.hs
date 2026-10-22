{-# LANGUAGE OverloadedStrings #-}

-- | All-age, version-aware cleanup of registered validation mail. Delete
-- markers contain no message data and remain retained bucket metadata under
-- the prefix lifecycle rule; every live and noncurrent data version is read.
module Prodbox.Ses.CaptureCleanup
  ( CapturedMailVersion
  , capturedMailVersionIdentity
  , observeCapturedMailVersions
  , deleteCapturedMailVersions
  , maximumCleanupMailVersions
  )
where

import Control.Monad (foldM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Capacity.SesCaptureCleanupBudget
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Ses.Capture (CaptureRunner (..), messageAddressees)
import Prodbox.Ses.CaptureLifecycle (sesCaptureMailPrefix)
import Prodbox.Settings.Coordinate (s3BucketNameText)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import System.IO (IOMode (ReadMode), hClose, withBinaryFile)
import System.IO.Temp (withSystemTempFile)

data CapturedMailVersion = CapturedMailVersion !Text !Text
  deriving (Eq, Show)

capturedMailVersionIdentity :: CapturedMailVersion -> Text
capturedMailVersionIdentity (CapturedMailVersion key version) =
  TextEncoding.decodeUtf8 (convertToBase Base16 (SHA256.hash bytes))
 where
  bytes = TextEncoding.encodeUtf8 (key <> "\NUL" <> version)

maximumMailBytes :: Int
maximumMailBytes = maximumCleanupMailMessageBytes

-- | Complete, bounded enumeration precedes any message read or deletion.
-- A failed page/read, repeated cursor or malformed row never means absence.
observeCapturedMailVersions
  :: CaptureRunner -> InviteMailScope -> IO (Either Text [CapturedMailVersion])
observeCapturedMailVersions runner scope = do
  listed <- walk Nothing [] (0 :: Int) (0 :: Int) []
  case listed of
    Left detail -> pure (Left detail)
    Right versions -> foldM readMatching (Right []) versions
 where
  bucket = Text.unpack (s3BucketNameText (inviteMailBucket scope))
  walk cursor seen pages count versions = do
    output <-
      runCaptureAws
        runner
        ( [ "s3api"
          , "list-object-versions"
          , "--bucket"
          , bucket
          , "--prefix"
          , sesCaptureMailPrefix
          , "--max-keys"
          , "1000"
          , "--no-paginate"
          , "--output"
          , "json"
          ]
            <> cursorArgs cursor
        )
    case processExitCode output of
      ExitFailure _ -> pure (Left "capture cleanup version listing failed")
      ExitSuccess -> case decodePage output of
        Left detail -> pure (Left detail)
        Right (dataVersions, rows, next) ->
          let allVersions = versions <> dataVersions
              allRows = count + rows
           in if allRows > maximumCleanupMailListedRows || length allVersions > maximumCleanupMailVersions
                then pure (Left "capture cleanup exceeds its complete listing or data-version read bound")
                else
                  if length (nub allVersions) /= length allVersions
                    then pure (Left "capture cleanup listing repeated a data version")
                    else case next of
                      Nothing -> pure (Right allVersions)
                      Just marker
                        | pages + 1 >= maximumCleanupMailListingPages || marker `elem` seen ->
                            pure (Left "capture cleanup listing did not terminate")
                        | otherwise -> walk (Just marker) (marker : seen) (pages + 1) allRows allVersions
  readMatching (Left detail) _ = pure (Left detail)
  readMatching (Right found) version@(CapturedMailVersion key versionId) =
    withSystemTempFile "prodbox-ses-cleanup-" $ \path handle -> do
      hClose handle
      output <-
        runCaptureAws
          runner
          [ "s3api"
          , "get-object"
          , "--bucket"
          , bucket
          , "--key"
          , Text.unpack key
          , "--version-id"
          , Text.unpack versionId
          , "--range"
          , "bytes=0-" <> show maximumMailBytes
          , path
          ]
      case processExitCode output of
        ExitFailure _ -> pure (Left "capture cleanup could not read a listed data version")
        ExitSuccess -> do
          bytes <- withBinaryFile path ReadMode (\file -> ByteString.hGet file (maximumMailBytes + 1))
          pure $
            if ByteString.length bytes > maximumMailBytes
              then Left "capture cleanup message exceeds its bounded read"
              else
                Right
                  ( found
                      <> [ version
                         | any (inviteMailRecipientMatches scope) (messageAddressees (LazyByteString.fromStrict bytes))
                         ]
                  )

cursorArgs :: Maybe (Text, Text) -> [String]
cursorArgs cursor = case cursor of
  Nothing -> []
  Just (key, version) -> ["--key-marker", Text.unpack key, "--version-id-marker", Text.unpack version]

decodePage :: ProcessOutput -> Either Text ([CapturedMailVersion], Int, Maybe (Text, Text))
decodePage output = do
  value <-
    either
      (const (Left "capture cleanup listing JSON is unreadable"))
      Right
      (eitherDecode (LazyChar8.pack (processStdout output)))
  fields <- case value of
    Object obj -> Right obj
    _ -> Left "capture cleanup listing is not an object"
  versions <- rows "Versions" fields
  markers <- rows "DeleteMarkers" fields
  checkedMarkers <- traverse decodeVersion markers
  checkedVersions <- traverse decodeDataVersion versions
  next <- case KeyMap.lookup "IsTruncated" fields of
    Just (Bool False) -> Right Nothing
    Just (Bool True) ->
      Just <$> ((,) <$> requiredText "NextKeyMarker" fields <*> requiredText "NextVersionIdMarker" fields)
    _ -> Left "capture cleanup listing has no complete pagination disposition"
  Right (checkedVersions, length checkedVersions + length checkedMarkers, next)
 where
  rows name fields = case KeyMap.lookup name fields of
    Nothing -> Right []
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left "capture cleanup listing has a malformed row array"
  decodeVersion value = case value of
    Object fields -> do
      key <- requiredText "Key" fields
      version <- requiredText "VersionId" fields
      if Text.pack sesCaptureMailPrefix `Text.isPrefixOf` key
        then Right (CapturedMailVersion key version)
        else Left "capture cleanup listing escaped its inbound prefix"
    _ -> Left "capture cleanup version row is not an object"
  decodeDataVersion value = do
    version <- decodeVersion value
    case value of
      Object fields -> case KeyMap.lookup "Size" fields of
        Just (Number size) | size >= 0 && size <= fromIntegral maximumMailBytes -> Right version
        _ -> Left "capture cleanup data version has an invalid or oversized length"
      _ -> Left "capture cleanup data version is not an object"

requiredText :: Key.Key -> KeyMap.KeyMap Value -> Either Text Text
requiredText key fields = case KeyMap.lookup key fields of
  Just (String value)
    | not (Text.null value), Text.length value <= 1024, not (Text.any isControl value) -> Right value
  _ -> Left "capture cleanup listing has an invalid public coordinate"

-- | Acknowledgements are provisional. The registered read-back performs a new
-- complete version listing and message read under its own operation identity.
deleteCapturedMailVersions
  :: CaptureRunner -> InviteMailScope -> [CapturedMailVersion] -> IO (Either Text ())
deleteCapturedMailVersions runner scope = foldM deleteOne (Right ())
 where
  deleteOne (Left detail) _ = pure (Left detail)
  deleteOne (Right ()) (CapturedMailVersion key version) = do
    output <-
      runCaptureAws
        runner
        [ "s3api"
        , "delete-object"
        , "--bucket"
        , Text.unpack (s3BucketNameText (inviteMailBucket scope))
        , "--key"
        , Text.unpack key
        , "--version-id"
        , Text.unpack version
        ]
    pure $ case processExitCode output of
      ExitSuccess -> Right ()
      ExitFailure _ -> Left "capture cleanup data-version deletion remains unresolved"
