{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Construct an untagged OCI layout from held, digest-verified inputs. A
-- caller must discard incomplete output and import the finished artifact
-- through the ordinary scoped artifact boundary.
module Prodbox.Control.NodeRegistryArchive
  ( NodeRegistryArchiveResult (..)
  , writeNodeRegistryArchive
  ) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Entry
import Control.Exception (IOException, try)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Control.NodeRegistryClient (NodeRegistryDocument (..))
import Prodbox.Control.NodeRegistryManifest
import System.IO (Handle, SeekMode (AbsoluteSeek), hFlush, hSeek)
import System.Timeout (timeout)

data NodeRegistryArchiveResult
  = NodeRegistryArchiveInvalid
  | NodeRegistryArchiveMismatch
  | NodeRegistryArchiveUnavailable
  | NodeRegistryArchiveTimedOut
  | NodeRegistryArchiveWritten !Text !Integer
  deriving (Eq, Show)

-- | Handles correspond to config followed by the manifest layers. They must
-- remain held and readable for this call; no path, daemon or publication is
-- touched. A digest mismatch can leave partial bytes in the output handle.
writeNodeRegistryArchive
  :: Text -> NodeRegistryDocument -> [Handle] -> Handle -> IO NodeRegistryArchiveResult
writeNodeRegistryArchive selected document sources output
  | parseNodeRegistryManifest selected manifest /= Right plan = pure NodeRegistryArchiveInvalid
  | length sources /= length blobs = pure NodeRegistryArchiveInvalid
  | total > 4294967296 = pure NodeRegistryArchiveInvalid
  | otherwise = do
      result <- timeout 540000000 (try writeArchive)
      pure $ case result of
        Nothing -> NodeRegistryArchiveTimedOut
        Just (Left (_ :: IOException)) -> NodeRegistryArchiveUnavailable
        Just (Right value) -> value
 where
  manifest = nodeRegistryManifestBytes document
  plan = nodeRegistryManifestPlan document
  blobs = nodeRegistryConfig plan : nodeRegistryLayers plan
  layout = "{\"imageLayoutVersion\":\"1.0.0\"}"
  media =
    if nodeRegistryBlobMediaType (nodeRegistryConfig plan) == "application/vnd.oci.image.config.v1+json"
      then "application/vnd.oci.image.manifest.v1+json" :: Text
      else "application/vnd.docker.distribution.manifest.v2+json"
  index =
    BL.toStrict $
      Aeson.encode $
        Aeson.object
          [ "schemaVersion" Aeson..= (2 :: Int)
          , "manifests"
              Aeson..= [ Aeson.object
                           [ "mediaType" Aeson..= media
                           , "digest" Aeson..= selected
                           , "size" Aeson..= BS.length manifest
                           ]
                       ]
          ]
  entrySize n = 512 + n + (512 - n `mod` 512) `mod` 512
  total =
    1024
      + sum
        ( map
            entrySize
            ( [fromIntegral (BS.length layout), fromIntegral (BS.length index), fromIntegral (BS.length manifest)]
                ++ map nodeRegistryBlobSize blobs
            )
        )
  writeArchive = do
    outputDigest <- newIORef (hashInit :: Context SHA256)
    count <- newIORef (0 :: Integer)
    let emit bytes = do
          BS.hPut output bytes
          modifyIORef' outputDigest (`hashUpdate` bytes)
          modifyIORef' count (+ fromIntegral (BS.length bytes))
        small path bytes = do
          emit (header path (fromIntegral (BS.length bytes)))
          emit bytes
          emit (padding (fromIntegral (BS.length bytes)))
    small "oci-layout" layout
    small "index.json" index
    small (blobPath selected) manifest
    checked <- writeBlobs emit (zip blobs sources)
    if not checked
      then pure NodeRegistryArchiveMismatch
      else do
        emit (BS.replicate 1024 0)
        hFlush output
        actual <- readIORef count
        digest <- hashFinalize <$> readIORef outputDigest
        if actual == total
          then
            pure (NodeRegistryArchiveWritten ("sha256:" <> Text.pack (show (digest :: Digest SHA256))) actual)
          else pure NodeRegistryArchiveMismatch
  writeBlobs _ [] = pure True
  writeBlobs emit ((blob, source) : rest) = do
    hSeek source AbsoluteSeek 0
    _ <- emit (header (blobPath (nodeRegistryBlobDigest blob)) (nodeRegistryBlobSize blob))
    checked <- copyBlob emit source blob 0 (hashInit :: Context SHA256)
    if checked
      then emit (padding (nodeRegistryBlobSize blob)) >> writeBlobs emit rest
      else pure False
  copyBlob emit source blob !count !context = do
    chunk <- BS.hGetSome source 65536
    let next = count + fromIntegral (BS.length chunk)
    if BS.null chunk
      then
        pure
          ( count == nodeRegistryBlobSize blob
              && "sha256:" <> Text.pack (show (hashFinalize context :: Digest SHA256)) == nodeRegistryBlobDigest blob
          )
      else
        if next > nodeRegistryBlobSize blob
          then pure False
          else emit chunk >> copyBlob emit source blob next (hashUpdate context chunk)

blobPath :: Text -> FilePath
blobPath digest = "blobs/sha256/" ++ Text.unpack (Text.drop 7 digest)

header :: FilePath -> Integer -> BS.ByteString
header path size = case Entry.toTarPath False path of
  Left _ -> BS.empty
  Right name ->
    BL.toStrict
      (BL.take 512 (Tar.write [Entry.simpleEntry name (Entry.NormalFile BL.empty (fromInteger size))]))

padding :: Integer -> BS.ByteString
padding size = BS.replicate (fromInteger ((512 - size `mod` 512) `mod` 512)) 0
