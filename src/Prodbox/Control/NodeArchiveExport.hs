{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Streaming conversion of a held node archive to an untagged Docker image
-- archive. This does not invoke a daemon or authorize an effect.
module Prodbox.Control.NodeArchiveExport
  ( DockerArchiveFailure (..)
  , DockerArchiveResult (..)
  , maximumDockerArchiveBytes
  , dockerArchiveRequiredBytes
  , writeUntaggedDockerArchive
  ) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Entry
import Control.Exception (IOException, bracket, mask, onException, try)
import Crypto.Hash.SHA256 qualified as SHA
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Numeric (showHex)
import Prodbox.Control.NodeArchive
  ( NodeLoadBlob (..)
  , NodeLoadPlan (..)
  , VerifiedNodeArchive (..)
  , normalizeNodeArchivePath
  )
import System.IO (Handle, SeekMode (AbsoluteSeek), hClose, hFlush, hSetBinaryMode)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd)

data DockerArchiveFailure
  = DockerArchiveUnsupportedConfig
  | DockerArchiveInvalidPlan
  | DockerArchiveSizeLimitExceeded
  | DockerArchiveChanged
  | DockerArchiveInvalidSource
  | DockerArchiveIoFailure
  deriving (Eq, Show)

data DockerArchiveResult
  = DockerArchiveNotStarted !DockerArchiveFailure
  | DockerArchiveIncomplete !DockerArchiveFailure
  | DockerArchiveWritten !String !Integer
  deriving (Eq, Show)

-- | Emit only the selected config and layers plus a generated manifest with
-- no RepoTags. The caller supplies the descriptor and recheck from the held
-- archive callback. A partial output must not be treated as a completed load;
-- no daemon identity, decompressed layer, capacity or effect is verified here.
writeUntaggedDockerArchive
  :: VerifiedNodeArchive -> Fd -> IO Bool -> Handle -> IO DockerArchiveResult
writeUntaggedDockerArchive verified source stable output = case preparePlan verified of
  Left failure -> pure (DockerArchiveNotStarted failure)
  Right (plan, required, _) -> do
    touched <- newIORef False
    result <- try $ do
      ready <- stable
      if not ready
        then pure (Left DockerArchiveChanged)
        else do
          digestRef <- newIORef SHA.init
          countRef <- newIORef (0 :: Integer)
          let emit bytes = do
                if BS.null bytes
                  then pure ()
                  else do
                    count <- readIORef countRef
                    let !nextCount = count + toInteger (BS.length bytes)
                    if nextCount > maximumDockerArchiveBytes
                      then ioError (userError "Docker archive stage size limit exceeded")
                      else pure ()
                    writeIORef touched True
                    BS.hPut output bytes
                    current <- readIORef digestRef
                    let !next = SHA.update current bytes
                    writeIORef digestRef next
                    writeIORef countRef nextCount
          hSetBinaryMode output True
          let manifest = renderManifest plan
          wroteManifest <- emitSmallEntry emit "manifest.json" manifest
          if not wroteManifest
            then pure (Left DockerArchiveInvalidPlan)
            else do
              scanned <- bracket
                (mask $ \_ -> do copy <- Posix.dup source; Posix.fdToHandle copy `onException` Posix.closeFd copy)
                hClose
                $ \input -> do
                  hSetBinaryMode input True
                  _ <- Posix.fdSeek source AbsoluteSeek 0
                  bytes <- BL.hGetContents input
                  copyEntries emit stable required Set.empty (Tar.read bytes)
              case scanned of
                Left failure -> pure (Left failure)
                Right () -> do
                  emit (BS.replicate 1024 0)
                  hFlush output
                  final <- stable
                  if not final
                    then pure (Left DockerArchiveChanged)
                    else do
                      context <- readIORef digestRef
                      count <- readIORef countRef
                      pure (Right (renderDigest context, count))
    changed <- readIORef touched
    pure $ case result of
      Left (_ :: IOException) -> failed changed DockerArchiveIoFailure
      Right (Left failure) -> failed changed failure
      Right (Right (digest, count)) -> DockerArchiveWritten digest count
 where
  failed True = DockerArchiveIncomplete
  failed False = DockerArchiveNotStarted

-- Include all tar headers, padding and the end marker in the preflight, not
-- just the selected blob sizes. The streaming check also guards each write.
maximumDockerArchiveBytes :: Integer
maximumDockerArchiveBytes = 4294967296

-- | Exact output size for a valid plan, before the archive is read or any
-- bytes are emitted. The archive and output still require independent checks.
dockerArchiveRequiredBytes :: VerifiedNodeArchive -> Either DockerArchiveFailure Integer
dockerArchiveRequiredBytes verified = do
  (_, _, size) <- preparePlan verified
  pure size

preparePlan
  :: VerifiedNodeArchive
  -> Either DockerArchiveFailure (NodeLoadPlan, Map.Map FilePath NodeLoadBlob, Integer)
preparePlan verified = do
  plan <- maybe (Left DockerArchiveUnsupportedConfig) Right (nodeLoadPlan verified)
  required <- maybe (Left DockerArchiveInvalidPlan) Right (validatePlan verified plan)
  let size = projectedSize plan required
  if size > maximumDockerArchiveBytes
    then Left DockerArchiveSizeLimitExceeded
    else Right (plan, required, size)

projectedSize :: NodeLoadPlan -> Map.Map FilePath NodeLoadBlob -> Integer
projectedSize plan required =
  entrySize (toInteger (BS.length (renderManifest plan)))
    + sum (map (entrySize . nodeBlobSize) (Map.elems required))
    + 1024
 where
  entrySize size = 512 + size + ((512 - size `mod` 512) `mod` 512)

renderManifest :: NodeLoadPlan -> BS.ByteString
renderManifest plan =
  BL.toStrict $
    Aeson.encode
      [ Aeson.object
          [ "Config" Aeson..= blobPath (nodeLoadConfig plan)
          , "RepoTags" Aeson..= ([] :: [String])
          , "Layers" Aeson..= map blobPath (nodeLoadLayers plan)
          ]
      ]

validatePlan :: VerifiedNodeArchive -> NodeLoadPlan -> Maybe (Map.Map FilePath NodeLoadBlob)
validatePlan verified plan = do
  let config = nodeLoadConfig plan
      layers = nodeLoadLayers plan
      blobs = config : layers
      entries = [(blobPath blob, blob) | blob <- blobs]
      unique = Map.fromList entries
      sizesAgree (path, blob) = maybe False ((== nodeBlobSize blob) . nodeBlobSize) (Map.lookup path unique)
      layerTypes = case nodeBlobMediaType config of
        "application/vnd.docker.container.image.v1+json" ->
          [ "application/vnd.docker.image.rootfs.diff.tar.gzip"
          , "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip"
          ]
        "application/vnd.oci.image.config.v1+json" ->
          [ "application/vnd.oci.image.layer.v1.tar"
          , "application/vnd.oci.image.layer.v1.tar+gzip"
          , "application/vnd.oci.image.layer.v1.tar+zstd"
          ]
        _ -> []
  if nodeBlobDigest config /= nodeConfigDigest verified
    || any ((`notElem` layerTypes) . nodeBlobMediaType) layers
    || any (not . validDigest) (nodeLoadDiffIds plan)
    || null layers
    || length layers > 1024
    || length (nodeLoadDiffIds plan) /= length layers
    || any
      ( \blob ->
          nodeBlobSize blob < 0 || nodeBlobSize blob > 4294967296 || not (validDigest (nodeBlobDigest blob))
      )
      blobs
    || not (all sizesAgree entries)
    || sum (map nodeBlobSize (Map.elems unique)) > 4294967296
    then Nothing
    else Just unique

blobPath :: NodeLoadBlob -> FilePath
blobPath blob = "blobs/sha256/" ++ drop 7 (nodeBlobDigest blob)
validDigest :: String -> Bool
validDigest value =
  take 7 value == "sha256:"
    && length value == 71
    && all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) (drop 7 value)

emitSmallEntry :: (BS.ByteString -> IO ()) -> FilePath -> BS.ByteString -> IO Bool
emitSmallEntry emit name bytes = case header name (toInteger (BS.length bytes)) of
  Nothing -> pure False
  Just prefix -> do
    emit prefix
    emit bytes
    emitPadding emit (toInteger (BS.length bytes))
    pure True

header :: FilePath -> Integer -> Maybe BS.ByteString
header name size = do
  path <- either (const Nothing) Just (Entry.toTarPath False name)
  let entry = Entry.simpleEntry path (Entry.NormalFile BL.empty (fromInteger size))
  pure (BL.toStrict (BL.take 512 (Tar.write [entry])))

emitPadding :: (BS.ByteString -> IO ()) -> Integer -> IO ()
emitPadding emit size = emit (BS.replicate (fromInteger ((512 - size `mod` 512) `mod` 512)) 0)

copyEntries
  :: (BS.ByteString -> IO ())
  -> IO Bool
  -> Map.Map FilePath NodeLoadBlob
  -> Set.Set FilePath
  -> Tar.Entries Tar.FormatError
  -> IO (Either DockerArchiveFailure ())
copyEntries emit stable required seen entries = case entries of
  Tar.Fail _ -> pure (Left DockerArchiveInvalidSource)
  Tar.Done -> pure $ if seen == Map.keysSet required then Right () else Left DockerArchiveInvalidSource
  Tar.Next entry rest -> case normalizeNodeArchivePath (Entry.entryPath entry) >>= (`Map.lookup` required) of
    Nothing -> copyEntries emit stable required seen rest
    Just blob -> do
      let name = blobPath blob
      ready <- stable
      case (ready, Set.member name seen, Entry.entryContent entry, header name (nodeBlobSize blob)) of
        (False, _, _, _) -> pure (Left DockerArchiveChanged)
        (_, True, _, _) -> pure (Left DockerArchiveInvalidSource)
        (_, _, Entry.NormalFile content size, Just prefix) | toInteger size == nodeBlobSize blob -> do
          emit prefix
          (context, count) <- copyContent emit content
          if count /= nodeBlobSize blob || renderDigest context /= nodeBlobDigest blob
            then pure (Left DockerArchiveChanged)
            else do
              emitPadding emit count
              copyEntries emit stable required (Set.insert name seen) rest
        _ -> pure (Left DockerArchiveInvalidSource)

copyContent :: (BS.ByteString -> IO ()) -> BL.ByteString -> IO (SHA.Ctx, Integer)
copyContent emit = go SHA.init 0 . BL.toChunks
 where
  go !context !count chunks = case chunks of
    [] -> pure (context, count)
    chunk : rest -> do
      emit chunk
      let !next = SHA.update context chunk
          !newCount = count + toInteger (BS.length chunk)
      go next newCount rest

renderDigest :: SHA.Ctx -> String
renderDigest context = "sha256:" ++ concatMap hexByte (BS.unpack (SHA.finalize context))
 where
  hexByte byte = let value = showHex byte "" in if length value == 1 then '0' : value else value
