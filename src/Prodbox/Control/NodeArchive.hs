{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Read an OCI image layout without extracting or loading it. The selected
-- digest is a configured input; this check does not establish provenance.
module Prodbox.Control.NodeArchive
  ( NodeArchiveObservation (..)
  , VerifiedNodeArchive (..)
  , NodeLoadPlan (..)
  , NodeLoadBlob (..)
  , ArchiveReferenceFootprint (..)
  , InspectedArchiveResult (..)
  , ArchiveCallbackProgress (..)
  , classifyArchiveInterruption
  , normalizeNodeArchivePath
  , observeNodeArchive
  , withInspectedNodeArchive
  ) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as Entry
import Control.Exception (IOException, bracket, evaluate, mask, onException, try)
import Crypto.Hash.SHA256 qualified as SHA
import Data.Aeson (Value, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  )
import Prodbox.Config.DeploymentScope
  ( HeldArtifactResult (..)
  , ScopeArtifactObservation
  , ScopeGenerationObservation (..)
  , observeScopeGeneration
  , withVerifiedScopeArtifact
  )
import Prodbox.Config.KindPlan (kindPlanNodeImage, kindPlanScope)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.IO (SeekMode (AbsoluteSeek), hClose, hSetBinaryMode)
import System.Info qualified as SystemInfo
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd)
import System.Timeout (timeout)

data NodeArchiveObservation
  = NodeArchiveNotDeclared
  | NodeArchiveGenerationUnavailable
  | NodeArchiveArtifactRefused !ScopeArtifactObservation
  | NodeArchiveUnobservable
  | NodeArchiveTimedOut
  | NodeArchiveUnsupported
  | NodeArchiveMismatch
  | NodeArchiveChanged
  | NodeArchiveMatches !VerifiedNodeArchive
  deriving (Eq, Show)

data VerifiedNodeArchive = VerifiedNodeArchive
  { nodeSelectedDigest :: !String
  , nodeManifestDigest :: !String
  , nodeConfigDigest :: !String
  , nodeArchitecture :: !String
  , nodeReferenceFootprint :: !ArchiveReferenceFootprint
  , nodeLoadPlan :: !(Maybe NodeLoadPlan)
  }
  deriving (Eq, Show)

data NodeLoadBlob = NodeLoadBlob
  { nodeBlobDigest :: !String
  , nodeBlobSize :: !Integer
  , nodeBlobMediaType :: !String
  }
  deriving (Eq, Show)

data NodeLoadPlan = NodeLoadPlan
  { nodeLoadConfig :: !NodeLoadBlob
  , nodeLoadLayers :: ![NodeLoadBlob]
  , nodeLoadDiffIds :: ![String]
  }
  deriving (Eq, Show)

-- Only the top-level OCI index is counted. This is not a complete set of
-- effects a particular daemon may perform when loading an archive.
data ArchiveReferenceFootprint = ArchiveReferenceFootprint
  { archiveTopLevelDescriptors :: !Int
  , archiveDescriptorsWithNameMetadata :: !Int
  }
  deriving (Eq, Show)

data Blob = Blob !Integer !(Maybe BS.ByteString)
data Descriptor = Descriptor !String !Integer !String !(Maybe (String, String))

data InspectedArchiveResult value
  = InspectedArchiveRefused !NodeArchiveObservation
  | InspectedArchiveCompleted !value
  | InspectedArchiveChanged !value
  | InspectedArchiveUnconfirmed !NodeArchiveObservation
  | InspectedArchiveUnconfirmedAfter !value !NodeArchiveObservation
  deriving (Eq, Show)

data ArchiveCallbackProgress value
  = ArchiveCallbackNotStarted
  | ArchiveCallbackStarted
  | ArchiveCallbackReturned !value
  deriving (Eq, Show)

-- | A started callback is unconfirmed; a returned value remains available
-- even if a subsequent observation cannot be completed.
classifyArchiveInterruption
  :: ArchiveCallbackProgress value -> NodeArchiveObservation -> InspectedArchiveResult value
classifyArchiveInterruption progress failure = case progress of
  ArchiveCallbackNotStarted -> InspectedArchiveRefused failure
  ArchiveCallbackStarted -> InspectedArchiveUnconfirmed failure
  ArchiveCallbackReturned value -> InspectedArchiveUnconfirmedAfter value failure

observeNodeArchive :: BootstrapProjection -> IO NodeArchiveObservation
observeNodeArchive bootstrap = do
  result <- withInspectedNodeArchive bootstrap (\verified _ _ -> pure verified)
  pure $ case result of
    InspectedArchiveRefused failure -> failure
    InspectedArchiveCompleted verified -> NodeArchiveMatches verified
    InspectedArchiveChanged _ -> NodeArchiveChanged
    InspectedArchiveUnconfirmed failure -> failure
    InspectedArchiveUnconfirmedAfter _ failure -> failure

-- | Hold the exact verified archive descriptor while the caller observes or
-- uses it. The descriptor is positioned at its start before the callback.
-- A completed callback's value is retained if inputs change afterward. A
-- timeout or exception can leave a callback unconfirmed. This grants no
-- admission; callers must separately journal, bound and settle effects.
withInspectedNodeArchive
  :: BootstrapProjection
  -> (VerifiedNodeArchive -> Fd -> IO Bool -> IO value)
  -> IO (InspectedArchiveResult value)
withInspectedNodeArchive bootstrap action = case (bootstrapNodeArtifact bootstrap, architecture) of
  (Nothing, _) -> pure (InspectedArchiveRefused NodeArchiveNotDeclared)
  (_, Nothing) -> pure (InspectedArchiveRefused NodeArchiveUnsupported)
  (Just artifact, Just arch) -> do
    progress <- newIORef ArchiveCallbackNotStarted
    result <- timeout 180000000
      $ try
      $ withVerifiedScopeArtifact
        scope
        (artifactPath artifact)
        (artifactDigest artifact)
        (artifactMaximumBytes artifact)
      $ \fd stable -> do
        let recheck = do
              before <- stable
              current <- observeScopeGeneration scope generation
              after <- stable
              pure (before && current == Right ScopeGenerationMatches && after)
        initialGeneration <- observeScopeGeneration scope generation
        ready <- recheck
        if initialGeneration /= Right ScopeGenerationMatches
          then pure (Left NodeArchiveGenerationUnavailable)
          else
            if not ready
              then pure (Left NodeArchiveChanged)
              else do
                observed <- bracket
                  ( mask $ \_ -> do
                      copy <- Posix.dup fd
                      Posix.fdToHandle copy `onException` Posix.closeFd copy
                  )
                  hClose
                  $ \handle -> do
                    hSetBinaryMode handle True
                    _ <- Posix.fdSeek fd AbsoluteSeek 0
                    input <- BL.hGetContents handle
                    scanned <- scanArchive (Tar.read input)
                    case scanned of
                      Left failure -> pure failure
                      Right (index, blobs) -> inspectIndex selected arch index blobs
                readyAfterScan <- recheck
                if not readyAfterScan
                  then pure (Left NodeArchiveChanged)
                  else case observed of
                    NodeArchiveMatches verified -> do
                      _ <- Posix.fdSeek fd AbsoluteSeek 0
                      value <- mask $ \restore -> do
                        writeIORef progress ArchiveCallbackStarted
                        resultValue <- restore (action verified fd recheck)
                        writeIORef progress (ArchiveCallbackReturned resultValue)
                        pure resultValue
                      readyAfterAction <- recheck
                      pure (Right (value, readyAfterAction))
                    failure -> pure (Left failure)
    observedProgress <- readIORef progress
    let incomplete = classifyArchiveInterruption observedProgress
    pure $ case result of
      Nothing -> incomplete NodeArchiveTimedOut
      Just (Left (_ :: IOException)) -> incomplete NodeArchiveUnobservable
      Just (Right (Left _)) -> incomplete NodeArchiveUnobservable
      Just (Right (Right (HeldArtifactRefused failure))) -> InspectedArchiveRefused (NodeArchiveArtifactRefused failure)
      Just (Right (Right (HeldArtifactObserved (Left failure) True))) -> InspectedArchiveRefused failure
      Just (Right (Right (HeldArtifactObserved (Left _) False))) -> InspectedArchiveRefused NodeArchiveChanged
      Just (Right (Right (HeldArtifactObserved (Right (value, afterAction)) finalStable))) ->
        if afterAction && finalStable
          then InspectedArchiveCompleted value
          else InspectedArchiveChanged value
 where
  scope = kindPlanScope (bootstrapKindPlan bootstrap)
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  selected = drop 1 (dropWhile (/= '@') (kindPlanNodeImage (bootstrapKindPlan bootstrap)))
  architecture = case SystemInfo.arch of
    "x86_64" -> Just "amd64"
    "aarch64" -> Just "arm64"
    _ -> Nothing

-- Entries and retained metadata are bounded independently of artifact size.
-- Large blobs are hashed with one strict streaming pass and are not retained.
scanArchive
  :: Tar.Entries Tar.FormatError
  -> IO (Either NodeArchiveObservation (BS.ByteString, Map.Map String Blob))
scanArchive = go Set.empty Map.empty Nothing False (0 :: Int) (0 :: Integer)
 where
  go paths blobs index layout count retained entries
    | count > 16384 || retained > 16777216 = pure (Left NodeArchiveUnsupported)
    | otherwise = case entries of
        Tar.Fail _ -> pure (Left NodeArchiveUnsupported)
        Tar.Done -> pure $ case (index, layout) of
          (Just value, True) -> Right (value, blobs)
          _ -> Left NodeArchiveUnsupported
        Tar.Next entry rest -> case normalizeNodeArchivePath (Entry.entryPath entry) of
          Nothing -> pure (Left NodeArchiveUnsupported)
          Just name | Set.member name paths -> pure (Left NodeArchiveUnsupported)
          Just name -> case Entry.entryContent entry of
            Entry.Directory
              | name `elem` ["", "blobs", "blobs/sha256"] ->
                  go (Set.insert name paths) blobs index layout (count + 1) retained rest
            Entry.NormalFile contents size
              | size >= 0 ->
                  if name == "oci-layout" || name == "index.json"
                    then do
                      small <- readSmall contents size
                      value <- case small of Nothing -> pure Nothing; Just bytes -> jsonValue bytes
                      case (name, small, value) of
                        ("oci-layout", Just bytes, Just parsed)
                          | Right () <- parseEither parseLayout parsed ->
                              go
                                (Set.insert name paths)
                                blobs
                                index
                                True
                                (count + 1)
                                (retained + toInteger (BS.length bytes))
                                rest
                        ("index.json", Just bytes, Just _) ->
                          go
                            (Set.insert name paths)
                            blobs
                            (Just bytes)
                            layout
                            (count + 1)
                            (retained + toInteger (BS.length bytes))
                            rest
                        _ -> pure (Left NodeArchiveUnsupported)
                    else case stripPrefix "blobs/sha256/" name of
                      Just digest | validHex digest -> do
                        (actual, observed, small) <-
                          if size <= 1048576
                            then do
                              content <- readSmall contents size
                              pure $ case content of
                                Nothing -> ("", -1, Nothing)
                                Just bytes -> (renderDigest (SHA.update SHA.init bytes), toInteger (BS.length bytes), Just bytes)
                            else do
                              let (!context, !lengthObserved) =
                                    BL.foldlChunks
                                      (\(!ctx, !n) chunk -> (SHA.update ctx chunk, n + toInteger (BS.length chunk)))
                                      (SHA.init, 0)
                                      contents
                              pure (renderDigest context, lengthObserved, Nothing)
                        if actual /= "sha256:" ++ digest || observed /= toInteger size
                          then pure (Left NodeArchiveMismatch)
                          else
                            go
                              (Set.insert name paths)
                              (Map.insert actual (Blob observed small) blobs)
                              index
                              layout
                              (count + 1)
                              (retained + maybe 0 (toInteger . BS.length) small)
                              rest
                      _ -> pure (Left NodeArchiveUnsupported)
            _ -> pure (Left NodeArchiveUnsupported)
  readSmall contents size
    | size > 1048576 = pure Nothing
    | otherwise = do
        let strict = BL.toStrict contents
        observed <- evaluate (BS.length strict)
        pure (if toInteger observed == toInteger size then Just strict else Nothing)

normalizeNodeArchivePath :: FilePath -> Maybe FilePath
normalizeNodeArchivePath raw
  | raw `elem` [".", "./"] = Just ""
  | otherwise =
      let clean = reverse (dropWhile (== '/') (reverse (dropPrefix raw)))
       in if null clean || "/" `prefixOf` clean || any (`elem` ["", ".", ".."]) (parts clean)
            then Nothing
            else Just clean
 where
  dropPrefix value = maybe value dropPrefix (stripPrefix "./" value)
  prefixOf prefix value = case stripPrefix prefix value of Just _ -> True; Nothing -> False
  parts value = case break (== '/') value of (part, []) -> [part]; (part, _ : remaining) -> part : parts remaining

validHex :: String -> Bool
validHex value = length value == 64 && all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) value
renderDigest :: SHA.Ctx -> String
renderDigest context = "sha256:" ++ concatMap hexByte (BS.unpack (SHA.finalize context))
 where
  hexByte byte = let value = showHex byte "" in if length value == 1 then '0' : value else value

inspectIndex
  :: String -> String -> BS.ByteString -> Map.Map String Blob -> IO NodeArchiveObservation
inspectIndex selected arch index blobs = do
  parsed <- jsonValue index
  case parsed >>= either (const Nothing) Just . parseEither parseRootIndex of
    Just (descriptors, footprint) -> case filter selectedDescriptor descriptors of
      [descriptor] -> inspectSelected footprint descriptor
      _ -> pure NodeArchiveMismatch
    Nothing -> pure NodeArchiveUnsupported
 where
  selectedDescriptor (Descriptor digest _ _ _) = digest == selected
  inspectSelected footprint descriptor@(Descriptor _ _ media _) = case descriptorBytes descriptor blobs of
    Nothing -> pure NodeArchiveMismatch
    Just bytes | indexMedia media -> do
      value <- jsonValue bytes
      case value >>= either (const Nothing) Just . parseEither parseIndex of
        Nothing -> pure NodeArchiveUnsupported
        Just descriptors -> case filter (matchesPlatform arch) descriptors of
          [manifest] -> inspectManifest footprint manifest
          _ -> pure NodeArchiveMismatch
    Just _ | manifestMedia media -> inspectManifest footprint descriptor
    _ -> pure NodeArchiveUnsupported
  inspectManifest footprint descriptor@(Descriptor digest _ media _)
    | not (manifestMedia media) = pure NodeArchiveUnsupported
    | otherwise = do
        value <- maybe (pure Nothing) jsonValue (descriptorBytes descriptor blobs)
        case value >>= either (const Nothing) Just . parseEither (parseManifest media) of
          Nothing -> pure NodeArchiveUnsupported
          Just (config@(Descriptor configDigest _ _ _), layers) -> do
            configValue <- maybe (pure Nothing) jsonValue (descriptorBytes config blobs)
            let platform = configValue >>= either (const Nothing) Just . parseEither parseConfig
                diffIds = configValue >>= either (const Nothing) Just . parseEither parseDiffIds
                loadPlan = case diffIds of
                  Just values
                    | length values == length layers ->
                        Just (NodeLoadPlan (toLoadBlob config) (map toLoadBlob layers) values)
                  _ -> Nothing
            pure $
              if platform == Just ("linux", arch) && all (`descriptorPresent` blobs) (config : layers)
                then NodeArchiveMatches (VerifiedNodeArchive selected digest configDigest arch footprint loadPlan)
                else NodeArchiveMismatch

  toLoadBlob (Descriptor digest size media _) = NodeLoadBlob digest size media

matchesPlatform :: String -> Descriptor -> Bool
matchesPlatform arch (Descriptor _ _ _ platform) = platform == Just ("linux", arch)
descriptorPresent :: Descriptor -> Map.Map String Blob -> Bool
descriptorPresent (Descriptor digest size _ _) blobs = case Map.lookup digest blobs of Just (Blob actual _) -> actual == size; Nothing -> False
descriptorBytes :: Descriptor -> Map.Map String Blob -> Maybe BS.ByteString
descriptorBytes descriptor@(Descriptor digest _ _ _) blobs = do
  if descriptorPresent descriptor blobs then Just () else Nothing
  Blob _ content <- Map.lookup digest blobs
  content
jsonValue :: BS.ByteString -> IO (Maybe Value)
jsonValue bytes = do
  checked <- decodeBoundedYamlValue bytes
  pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right other) | value == other -> Just value
    _ -> Nothing
parseLayout :: Value -> Parser ()
parseLayout = withObject "layout" $ \object -> do
  version <- object .: "imageLayoutVersion"
  if version == ("1.0.0" :: String) then pure () else fail "unsupported layout"
parseIndex :: Value -> Parser [Descriptor]
parseIndex = withObject "index" $ \object -> do
  version <- object .: "schemaVersion"
  values <- object .: "manifests"
  if version /= (2 :: Int) || null values || length values > 128
    then fail "invalid index"
    else traverse parseDescriptor values
parseRootIndex :: Value -> Parser ([Descriptor], ArchiveReferenceFootprint)
parseRootIndex value = do
  descriptors <- parseIndex value
  named <-
    withObject "root index" (\object -> object .: "manifests" >>= traverse hasNameMetadata) value
  pure (descriptors, ArchiveReferenceFootprint (length descriptors) (length (filter id named)))
 where
  hasNameMetadata = withObject "root descriptor" hasAnnotations
  hasAnnotations object =
    case KeyMap.lookup "annotations" object of
      Nothing -> pure False
      Just annotationValue -> do
        annotations <- Aeson.parseJSON annotationValue :: Parser (Map.Map Text.Text Text.Text)
        pure $
          Map.member "org.opencontainers.image.ref.name" annotations
            || Map.member "io.containerd.image.name" annotations
indexMedia :: String -> Bool
indexMedia value =
  value
    `elem` [ "application/vnd.oci.image.index.v1+json"
           , "application/vnd.docker.distribution.manifest.list.v2+json"
           ]
manifestMedia :: String -> Bool
manifestMedia value =
  value
    `elem` [ "application/vnd.oci.image.manifest.v1+json"
           , "application/vnd.docker.distribution.manifest.v2+json"
           ]
parseManifest :: String -> Value -> Parser (Descriptor, [Descriptor])
parseManifest manifestType = withObject "manifest" $ \object -> do
  version <- object .: "schemaVersion"
  config <- object .: "config" >>= parseDescriptor
  values <- object .: "layers"
  layers <- traverse parseDescriptor values
  let media (Descriptor _ _ value _) = value
      (configType, layerTypes) =
        if manifestType == "application/vnd.docker.distribution.manifest.v2+json"
          then
            ( "application/vnd.docker.container.image.v1+json"
            ,
              [ "application/vnd.docker.image.rootfs.diff.tar.gzip"
              , "application/vnd.docker.image.rootfs.foreign.diff.tar.gzip"
              ]
            )
          else
            ( "application/vnd.oci.image.config.v1+json"
            ,
              [ "application/vnd.oci.image.layer.v1.tar"
              , "application/vnd.oci.image.layer.v1.tar+gzip"
              , "application/vnd.oci.image.layer.v1.tar+zstd"
              ]
            )
  if version /= (2 :: Int)
    || null layers
    || length layers > 1024
    || media config /= configType
    || any
      ( \layer ->
          media layer
            `notElem` layerTypes
      )
      layers
    then fail "unsupported manifest"
    else pure (config, layers)
parseDescriptor :: Value -> Parser Descriptor
parseDescriptor = withObject "descriptor" $ \object -> do
  digest <- object .: "digest"
  size <- object .: "size"
  media <- object .: "mediaType"
  platform <-
    object .:? "platform"
      >>= traverse (withObject "platform" (\value -> (,) <$> value .: "os" <*> value .: "architecture"))
  if take 7 digest /= "sha256:"
    || not (validHex (drop 7 digest))
    || size < 0
    || size > 4294967296
    || length media > 256
    then fail "invalid descriptor"
    else pure (Descriptor digest size media platform)
parseConfig :: Value -> Parser (String, String)
parseConfig = withObject "config" $ \object -> (,) <$> object .: "os" <*> object .: "architecture"
parseDiffIds :: Value -> Parser [String]
parseDiffIds = withObject "config" $ \object -> do
  root <- object .: "rootfs"
  withObject
    "rootfs"
    ( \rootfs -> do
        kind <- rootfs .: "type"
        values <- rootfs .: "diff_ids"
        if kind /= ("layers" :: String)
          || null values
          || length values > 1024
          || any (\digest -> take 7 digest /= "sha256:" || not (validHex (drop 7 digest))) values
          then fail "invalid rootfs"
          else pure values
    )
    root
