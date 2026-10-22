{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Host-only public build artifacts. No operational AWS credential or retained
-- Authority state enters this interpreter.
module Prodbox.Infra.BootstrapImageSourceNative
  ( BootstrapSourceStage (..)
  , BootstrapSourceError (..)
  , BootstrapSourceArtifact
  , BootstrapSourceEffects (..)
  , ensureBootstrapSourceArtifactsWith
  , bootstrapSourceArtifactReference
  , bootstrapSourceArtifactIdentity
  , bootstrapSourceArtifactArchivePath
  , ensureBootstrapSourceArtifacts
  ) where

import Control.Exception (IOException, bracket, displayException, onException, try)
import Control.Monad (unless, void)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.DockerConfig (withEphemeralDockerConfig)
import Prodbox.Error (AppError (errorMsg))
import Prodbox.Infra.BootstrapImageArchive
import Prodbox.Infra.BootstrapImageSource
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Directory
  ( createDirectoryIfMissing
  , makeAbsolute
  , renameFile
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (SeekMode (AbsoluteSeek), hClose, hFlush)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (withTempDirectory, withTempFile)
import System.Posix.Files
  ( fileOwner
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , setFileMode
  )
import System.Posix.IO
  ( LockRequest (WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite)
  , closeFd
  , defaultFileFlags
  , dup
  , fdToHandle
  , openFd
  , setLock
  )
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)

-- Failures name a stage and bounded public diagnostics, never downloaded bodies.
data BootstrapSourceStage
  = SourceCache
  | SourceDownload
  | SourceExtract
  | SourceDockerInput
  | SourceCompile
  | SourcePackage
  | SourceLoad
  | SourceObserve
  | SourceCleanup
  deriving (Eq, Show)

data BootstrapSourceError
  = BootstrapSourceIo BootstrapSourceStage Text
  | BootstrapSourceCommand BootstrapSourceStage Int Text
  | BootstrapSourceInvalid BootstrapSourceStage Text
  | BootstrapSourceArchive BootstrapImageArchiveError
  deriving (Eq, Show)

data BootstrapSourceArtifact = BootstrapSourceArtifact
  { bootstrapSourceArtifactReference :: Text
  , bootstrapSourceArtifactIdentity :: Text
  , bootstrapSourceArtifactArchivePath :: FilePath
  }

-- | The only simulated boundary is the bounded subprocess interpreter.
-- Files, leases and atomic artifact publication remain real in the tests.
newtype BootstrapSourceEffects = BootstrapSourceEffects
  { bootstrapSourceCapture
      :: BoundedSubprocessLimits -> Subprocess -> IO (Either AppError ProcessOutput)
  }

data BootstrapSourceRuntime = BootstrapSourceRuntime
  { sourceRuntimeRoot :: FilePath
  , sourceRuntimeEffects :: BootstrapSourceEffects
  }

type Build = ExceptT BootstrapSourceError IO

data CacheInputs = CacheInputs
  { cacheBinaryDigest :: Text
  , cacheBaseDigest :: Text
  , cacheCaDigest :: Text
  , cacheLicenseDigest :: Text
  , cacheHistoryDigest :: Text
  }

ensureBootstrapSourceArtifacts
  :: FilePath -> BootstrapImageArchitecture -> IO (Either BootstrapSourceError [BootstrapSourceArtifact])
ensureBootstrapSourceArtifacts =
  ensureBootstrapSourceArtifactsWith (BootstrapSourceEffects captureSubprocessBounded)

ensureBootstrapSourceArtifactsWith
  :: BootstrapSourceEffects
  -> FilePath
  -> BootstrapImageArchitecture
  -> IO (Either BootstrapSourceError [BootstrapSourceArtifact])
ensureBootstrapSourceArtifactsWith effects repoRoot architecture =
  withEphemeralDockerConfig $ do
    resolved <- try (makeAbsolute (repoRoot </> ".build" </> "bootstrap-images-v1"))
    case resolved of
      Left (cause :: IOException) -> pure (Left (BootstrapSourceIo SourceCache (firstLine (displayException cause))))
      Right root -> do
        prepared <- runExceptT (ensureDirectory (takeDirectory root) >> ensureDirectory root)
        case prepared of
          Left cause -> pure (Left cause)
          Right () -> do
            leased <-
              try $
                bracket
                  ( openFd
                      (root </> "build.lock")
                      ReadWrite
                      (defaultFileFlags {creat = Just 0o600, nofollow = True, cloexec = True, nonBlock = True})
                  )
                  closeFd
                  ( \fd -> do
                      status <- getFdStatus fd
                      uid <- getEffectiveUserID
                      unless
                        (isRegularFile status && fileOwner status == uid)
                        (ioError (userError "the source build lock is not an owned regular file"))
                      setLock fd (WriteLock, AbsoluteSeek, 0, 0)
                      runExceptT
                        ( mapM
                            (ensureOne (BootstrapSourceRuntime repoRoot effects) root . (`bootstrapSourceRecipe` architecture))
                            [BootstrapMinioServer, BootstrapMinioClient]
                        )
                  )
            pure $ case leased of
              Left (cause :: IOException) -> Left (BootstrapSourceIo SourceCache (firstLine (displayException cause)))
              Right result -> result

ensureOne
  :: BootstrapSourceRuntime -> FilePath -> BootstrapSourceRecipe -> Build BootstrapSourceArtifact
ensureOne runtime root recipe = do
  let location = root </> Text.unpack (bootstrapSourceRecipeIdentity recipe)
      receipt = location </> "inputs.json"
      component = bootstrapSourceRecipeComponent recipe
  ensureDirectory location
  cached <- observeOptional SourceCache receipt
  case cached of
    Nothing -> freshInputs runtime root location recipe
    Just bytes -> verifyCachedInputs location recipe bytes
  base <- lazyFile SourceCache (16 * mib) (location </> "base.tar")
  binary <- lazyFile SourceCache (128 * mib) (location </> "binary")
  ca <- strictFile SourceCache (512 * 1024) (location </> "ca.pem")
  license <- strictFile SourceCache (128 * 1024) (location </> "LICENSE")
  historyBytes <- strictFile SourceCache (64 * 1024) (location </> "history.json")
  history <- decodeValue SourceCache historyBytes
  let manifest =
        bootstrapSourceInputManifest
          recipe
          (digest binary)
          (digest base)
          (digest (LazyByteString.fromStrict ca))
      inputs = BootstrapImageInputs base history binary license ca manifest
  archive <-
    either
      (throwE . BootstrapSourceArchive)
      pure
      (assembleBootstrapImageArchive component (bootstrapSourceRecipeArchitecture recipe) inputs)
  let archivePath = location </> Text.unpack (bootstrapImageArchiveDigest archive) <> ".tar"
  existing <- filePresent SourceCache archivePath
  case existing of
    False -> atomicBytes SourcePackage archivePath (bootstrapImageArchiveBytes archive)
    True -> do
      actual <- lazyFile SourceCache (192 * mib) archivePath
      require
        SourceCache
        "the content-addressed image archive is corrupt"
        (digest actual == bootstrapImageArchiveDigest archive)
  let reference = bootstrapImageArchiveReference archive
      expected = bootstrapImageArchiveIdentity archive
  void (command SourceLoad runtime 120 "docker" ["image", "load", "--input", archivePath])
  observed <- dockerImage runtime reference
  require
    SourceObserve
    "the loaded bootstrap image identity differs"
    (imageIdentity observed == expected)
  require
    SourceObserve
    "the loaded bootstrap image architecture differs"
    (imageArchitecture observed == architectureText (bootstrapSourceRecipeArchitecture recipe))
  pure (BootstrapSourceArtifact reference expected archivePath)

verifyCachedInputs :: FilePath -> BootstrapSourceRecipe -> ByteString.ByteString -> Build ()
verifyCachedInputs location recipe bytes = do
  value <- decodeValue SourceCache bytes
  (fingerprint, recorded) <- parsed SourceCache cacheParser value
  require
    SourceCache
    "the build-input receipt belongs to another recipe"
    (fingerprint == bootstrapSourceRecipeIdentity recipe)
  mapM_
    ( \(name, limit, expected) -> do
        actual <- lazyFile SourceCache limit (location </> name)
        require
          SourceCache
          ("the retained build input is corrupt: " <> Text.pack name)
          (digest actual == expected)
    )
    [ ("binary", 128 * mib, cacheBinaryDigest recorded)
    , ("base.tar", 16 * mib, cacheBaseDigest recorded)
    , ("ca.pem", 512 * 1024, cacheCaDigest recorded)
    , ("LICENSE", 128 * 1024, cacheLicenseDigest recorded)
    , ("history.json", 64 * 1024, cacheHistoryDigest recorded)
    ]

cacheParser :: Value -> Parser (Text, CacheInputs)
cacheParser = withObject "bootstrap input receipt" $ \fields -> do
  version <- fields .: "schema"
  unless (version == (1 :: Int)) (fail "unsupported bootstrap input receipt")
  fingerprint <- fields .: "recipe_sha256"
  inputs <-
    CacheInputs
      <$> fields .: "binary_sha256"
      <*> fields .: "base_sha256"
      <*> fields .: "ca_sha256"
      <*> fields .: "license_sha256"
      <*> fields .: "history_sha256"
  pure (fingerprint, inputs)

freshInputs :: BootstrapSourceRuntime -> FilePath -> FilePath -> BootstrapSourceRecipe -> Build ()
freshInputs runtime root location recipe = do
  archives <- mapM (downloadInput runtime root) (bootstrapSourceRecipeDownloads recipe)
  (sourceArchive, sdkArchive) <- case archives of
    [source, sdk] -> pure (source, sdk)
    _ -> throwE (BootstrapSourceInvalid SourceDownload "the closed recipe must contain source and SDK")
  void
    (command SourceDockerInput runtime 300 "docker" ["pull", Text.unpack bootstrapSourceRuntimeBase])
  void
    ( command
        SourceDockerInput
        runtime
        300
        "docker"
        ["pull", Text.unpack bootstrapSourceCertificateImage]
    )
  ca <- copiedCertificate runtime root
  base <- acquiredBase runtime location (bootstrapSourceRecipeArchitecture recipe)
  atomicBytes SourceCache (location </> "ca.pem") (LazyByteString.fromStrict ca)
  withBuildDirectory root $ \scratch -> do
    let source = scratch </> "source"
        sdk = scratch </> "toolchain"
    ensureDirectory sdk
    void
      (command SourceExtract runtime 120 "tar" ["-xzf", sdkArchive, "--strip-components=1", "-C", sdk])
    ensureDirectory source
    void
      ( command
          SourceExtract
          runtime
          120
          "tar"
          ["-xzf", sourceArchive, "--strip-components=1", "-C", source]
      )
    license <- strictFile SourceCache (128 * 1024) (source </> "LICENSE")
    atomicBytes SourceCache (location </> "LICENSE") (LazyByteString.fromStrict license)
    compileSource runtime root location sdk source recipe
  binary <- lazyFile SourceCompile (128 * mib) (location </> "binary")
  require SourceCompile "the compiler produced an empty binary" (not (LazyByteString.null binary))
  license <- lazyFile SourceCache (128 * 1024) (location </> "LICENSE")
  history <- lazyFile SourceCache (64 * 1024) (location </> "history.json")
  let receipt =
        encode
          ( object
              [ "schema" .= (1 :: Int)
              , "recipe_sha256" .= bootstrapSourceRecipeIdentity recipe
              , "binary_sha256" .= digest binary
              , "base_sha256" .= digest base
              , "ca_sha256" .= digest (LazyByteString.fromStrict ca)
              , "license_sha256" .= digest license
              , "history_sha256" .= digest history
              ]
          )
  atomicBytes SourceCache (location </> "inputs.json") receipt
  actual <- strictFile SourceCache (64 * 1024) (location </> "inputs.json")
  verifyCachedInputs location recipe actual

downloadInput :: BootstrapSourceRuntime -> FilePath -> BootstrapSourceDownload -> Build FilePath
downloadInput runtime root input = do
  let downloads = root </> "downloads"
      destination = downloads </> Text.unpack (bootstrapDownloadSha256 input) <> ".tar.gz"
  ensureDirectory downloads
  present <- filePresent SourceDownload destination
  unless present $ do
    withBuildDirectory downloads $ \scratch -> do
      let temporary = scratch </> "download"
      void
        ( command
            SourceDownload
            runtime
            330
            "curl"
            [ "--fail"
            , "--location"
            , "--proto"
            , "=https"
            , "--tlsv1.2"
            , "--connect-timeout"
            , "15"
            , "--max-time"
            , "300"
            , "--max-filesize"
            , show (bootstrapDownloadMaximumBytes input)
            , "--output"
            , temporary
            , Text.unpack (bootstrapDownloadUrl input)
            ]
        )
      bytes <- lazyFile SourceDownload (bootstrapDownloadMaximumBytes input) temporary
      require
        SourceDownload
        "the official source/SDK checksum differs"
        (digest bytes == bootstrapDownloadSha256 input)
      atomicBytes SourceDownload destination bytes
  bytes <- lazyFile SourceDownload (bootstrapDownloadMaximumBytes input) destination
  require
    SourceDownload
    "the retained source/SDK checksum differs"
    (digest bytes == bootstrapDownloadSha256 input)
  pure destination

copiedCertificate :: BootstrapSourceRuntime -> FilePath -> Build ByteString.ByteString
copiedCertificate runtime root =
  withBuildDirectory root $ \scratch ->
    withCreatedContainer
      runtime
      root
      "certificates"
      bootstrapSourceCertificateImage
      ["--entrypoint", "/bin/true"]
      []
      $ \container -> do
        let destination = scratch </> "ca.pem"
        void
          ( command
              SourceDockerInput
              runtime
              30
              "docker"
              ["cp", Text.unpack container <> ":/etc/ssl/certs/ca-certificates.crt", destination]
          )
        strictFile SourceDockerInput (512 * 1024) destination

data DockerImage = DockerImage
  { imageIdentity :: Text
  , imageArchitecture :: Text
  , imageLayers :: [Text]
  , imageRepositories :: [Text]
  }

dockerImage :: BootstrapSourceRuntime -> Text -> Build DockerImage
dockerImage runtime reference = do
  output <- command SourceObserve runtime 30 "docker" ["image", "inspect", Text.unpack reference]
  value <- decodeValue SourceObserve (TextEncoding.encodeUtf8 (Text.pack (processStdout output)))
  parsed SourceObserve parser value
 where
  parser value = do
    images <- Aeson.parseJSON value
    case images of
      [selected] -> withObject "Docker image" readImage selected
      _ -> fail "expected exactly one Docker image"
  readImage fields = do
    imageId <- fields .: "Id"
    architecture <- fields .: "Architecture"
    filesystem <- fields .: "RootFS"
    layers <- withObject "root filesystem" (.: "Layers") filesystem
    repositories <- fields .: "RepoDigests"
    pure (DockerImage imageId architecture layers repositories)

acquiredBase
  :: BootstrapSourceRuntime -> FilePath -> BootstrapImageArchitecture -> Build LazyByteString.ByteString
acquiredBase runtime location architecture = do
  observed <- dockerImage runtime bootstrapSourceRuntimeBase
  require
    SourceDockerInput
    "the runtime base image architecture differs"
    (imageArchitecture observed == architectureText architecture)
  require
    SourceDockerInput
    "the base-image identity is malformed"
    (canonicalImageId (imageIdentity observed))
  require
    SourceDockerInput
    "the pinned base repository digest was not observed"
    (any (Text.isSuffixOf ("@" <> imageIndex bootstrapSourceRuntimeBase)) (imageRepositories observed))
  layerDigest <- case imageLayers observed of
    [single] -> pure single
    _ ->
      throwE
        (BootstrapSourceInvalid SourceDockerInput "the pinned BusyBox base must contain exactly one layer")
  withBuildDirectory location $ \scratch -> do
    let archive = scratch </> "base-image.tar"
        extracted = scratch </> "files"
    ensureDirectory extracted
    void
      ( command
          SourceDockerInput
          runtime
          120
          "docker"
          ["image", "save", "--output", archive, Text.unpack (imageIdentity observed)]
      )
    void (lazyFile SourceDockerInput (32 * mib) archive)
    metadata <- command SourceDockerInput runtime 30 "tar" ["-xOf", archive, "manifest.json"]
    value <-
      decodeValue SourceDockerInput (TextEncoding.encodeUtf8 (Text.pack (processStdout metadata)))
    (configMember, layerMember) <- parsed SourceDockerInput manifestParser value
    mapM_
      (require SourceDockerInput "the Docker archive member path is unsafe" . safeMember)
      [configMember, layerMember]
    void
      ( command
          SourceDockerInput
          runtime
          30
          "tar"
          [ "-xf"
          , archive
          , "--no-same-owner"
          , "-C"
          , extracted
          , "--"
          , Text.unpack configMember
          , Text.unpack layerMember
          ]
      )
    config <- strictFile SourceDockerInput (64 * 1024) (extracted </> Text.unpack configMember)
    require
      SourceDockerInput
      "the base config bytes do not match the observed identity"
      ("sha256:" <> digest (LazyByteString.fromStrict config) == imageIdentity observed)
    configValue <- decodeValue SourceDockerInput config
    history <- parsed SourceDockerInput historyParser configValue
    base <- lazyFile SourceDockerInput (16 * mib) (extracted </> Text.unpack layerMember)
    require
      SourceDockerInput
      "the base layer bytes do not match the observed filesystem"
      ("sha256:" <> digest base == layerDigest)
    atomicBytes SourceCache (location </> "base.tar") base
    atomicBytes SourceCache (location </> "history.json") (encode history)
    pure base
 where
  manifestParser value = do
    images <- Aeson.parseJSON value
    case images of
      [selected] -> withObject "Docker archive manifest" readManifest selected
      _ -> fail "expected one saved Docker image"
  readManifest fields = do
    config <- fields .: "Config"
    layers <- fields .: "Layers"
    case layers of
      [layer] -> pure (config, layer)
      _ -> fail "expected one saved base layer"
  historyParser = withObject "Docker base config" $ \fields -> do
    history <- fields .: "history"
    case history of
      first : _ -> pure (first :: Value)
      [] -> fail "the base image history is missing"

compileSource
  :: BootstrapSourceRuntime
  -> FilePath
  -> FilePath
  -> FilePath
  -> FilePath
  -> BootstrapSourceRecipe
  -> Build ()
compileSource runtime root location sdk source recipe = do
  uid <- io SourceCompile getEffectiveUserID
  gid <- io SourceCompile getEffectiveGroupID
  let modules = root </> "modules"
      buildCache = root </> "go-cache"
      work = takeDirectory source </> "work"
      componentName = bootstrapImageComponentName (bootstrapSourceRecipeComponent recipe)
  mapM_ ensureDirectory [modules, buildCache, work]
  mapM_
    (require SourceCompile "a build-cache path contains a Docker mount delimiter" . safeMount)
    [location, sdk, source, modules, buildCache, work]
  let options =
        [ "--init"
        , "--read-only"
        , "--user"
        , show uid <> ":" <> show gid
        , "--memory"
        , show bootstrapSourceCompilerMemoryBytes
        , "--cpu-period"
        , show bootstrapSourceCompilerCpuPeriod
        , "--cpu-quota"
        , show bootstrapSourceCompilerCpuQuota
        , "--pids-limit"
        , show bootstrapSourceCompilerPidMaximum
        , "--oom-score-adj"
        , "500"
        , "--network"
        , "bridge"
        , "--workdir"
        , "/src"
        , "--mount"
        , mount source "/src" True
        , "--mount"
        , mount sdk "/toolchain" True
        , "--mount"
        , mount location "/out" False
        , "--mount"
        , mount modules "/modules" False
        , "--mount"
        , mount buildCache "/go-cache" False
        , "--mount"
        , mount work "/work" False
        , "--mount"
        , mount (location </> "ca.pem") "/etc/ssl/certs/ca-certificates.crt" True
        , "--tmpfs"
        , "/tmp:size=67108864"
        ]
          <> concatMap
            (\(key, value) -> ["--env", Text.unpack (key <> "=" <> value)])
            (bootstrapSourceCompileEnvironment recipe)
  withCreatedContainer
    runtime
    root
    componentName
    bootstrapSourceRuntimeBase
    options
    (map Text.unpack (bootstrapSourceCompileArguments recipe))
    $ \container -> do
      void
        ( command
            SourceCompile
            runtime
            930
            "docker"
            ["container", "start", "--attach", Text.unpack container]
        )
      bytes <- lazyFile SourceCompile (128 * mib) (location </> Text.unpack componentName)
      require SourceCompile "the compiler output is empty" (not (LazyByteString.null bytes))
      require
        SourceCompile
        "the compiler output is not an ELF binary"
        (LazyByteString.take 4 bytes == "\DEL\&ELF")
      atomicBytes SourceCache (location </> "binary") bytes
 where
  safeMount path = all (`notElem` [',', ':', '\n', '\r']) path
  mount host destination readOnly = "type=bind,source=" <> host <> ",target=" <> destination <> if readOnly then ",readonly" else ""

-- A lost create reply is settled by exact-name/owner observation. The OS lease
-- excludes a second caller. Cleanup is independently observed on normal/error
-- paths; the in-container timeout also bounds a process after host SIGKILL.
withCreatedContainer
  :: BootstrapSourceRuntime
  -> FilePath
  -> Text
  -> Text
  -> [String]
  -> [String]
  -> (Text -> Build result)
  -> Build result
withCreatedContainer runtime root purpose image options arguments action = ExceptT $ do
  let owner = digest (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (Text.pack root)))
      name = "prodbox-bootstrap-" <> Text.take 12 owner <> "-" <> purpose
      cleanup = cleanupContainer runtime owner purpose image name
      run = do
        cleanup
        created <-
          command
            SourceCompile
            runtime
            60
            "docker"
            ( [ "container"
              , "create"
              , "--name"
              , Text.unpack name
              , "--label"
              , "io.prodbox.bootstrap.owner=" <> Text.unpack owner
              , "--label"
              , "io.prodbox.bootstrap.kind=" <> Text.unpack purpose
              ]
                <> options
                <> [Text.unpack image]
                <> arguments
            )
        let container = Text.strip (Text.pack (processStdout created))
        require SourceCompile "the created container ID is malformed" (canonicalHex container)
        action container
  outcome <- runExceptT run `onException` void (runExceptT cleanup)
  retired <- runExceptT cleanup
  pure $ case (outcome, retired) of
    (_, Left cause) -> Left cause
    (Left cause, Right ()) -> Left cause
    (Right value, Right ()) -> Right value

cleanupContainer :: BootstrapSourceRuntime -> Text -> Text -> Text -> Text -> Build ()
cleanupContainer runtime owner purpose image name = do
  prior <- containerNamed runtime name
  case prior of
    Nothing -> pure ()
    Just container -> do
      observed <-
        command
          SourceCleanup
          runtime
          30
          "docker"
          ["container", "inspect", "--format", "{{json .Config}}", Text.unpack container]
      value <- decodeValue SourceCleanup (TextEncoding.encodeUtf8 (Text.pack (processStdout observed)))
      (actualImage, actualOwner, actualKind) <- parsed SourceCleanup parser value
      require
        SourceCleanup
        "a different container occupies the bootstrap build name"
        (actualImage == image && actualOwner == owner && actualKind == purpose)
      void
        (command SourceCleanup runtime 30 "docker" ["container", "rm", "--force", Text.unpack container])
      after <- containerNamed runtime name
      require SourceCleanup "the source build container remains after removal" (after == Nothing)
 where
  parser = withObject "source build container" $ \fields -> do
    actualImage <- fields .: "Image"
    labels <- fields .: "Labels"
    (actualOwner, actualKind) <-
      withObject
        "source build labels"
        (\values -> (,) <$> values .: "io.prodbox.bootstrap.owner" <*> values .: "io.prodbox.bootstrap.kind")
        labels
    pure (actualImage, actualOwner, actualKind)

containerNamed :: BootstrapSourceRuntime -> Text -> Build (Maybe Text)
containerNamed runtime name = do
  observed <-
    command
      SourceCleanup
      runtime
      30
      "docker"
      [ "container"
      , "ls"
      , "--all"
      , "--no-trunc"
      , "--filter"
      , "name=^/" <> Text.unpack name <> "$"
      , "--format"
      , "{{.ID}}"
      ]
  case filter (not . Text.null) (map Text.strip (Text.lines (Text.pack (processStdout observed)))) of
    [] -> pure Nothing
    [container] -> do
      require SourceCleanup "the observed container ID is malformed" (canonicalHex container)
      pure (Just container)
    _ -> throwE (BootstrapSourceInvalid SourceCleanup "the exact build name returned several containers")

command
  :: BootstrapSourceStage -> BootstrapSourceRuntime -> Int -> FilePath -> [String] -> Build ProcessOutput
command stage runtime seconds executable arguments = do
  result <-
    io stage $
      bootstrapSourceCapture
        (sourceRuntimeEffects runtime)
        BoundedSubprocessLimits
          { boundedSubprocessMaximumInputBytes = 1
          , boundedSubprocessMaximumStdoutBytes = 1024 * 1024
          , boundedSubprocessMaximumStderrBytes = 1024 * 1024
          , boundedSubprocessTimeoutMicros = seconds * 1_000_000
          }
        Subprocess
          { subprocessPath = executable
          , subprocessArguments = arguments
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just (sourceRuntimeRoot runtime)
          }
  case result of
    Left cause -> throwE (BootstrapSourceIo stage (firstLine (Text.unpack (errorMsg cause))))
    Right output -> case processExitCode output of
      ExitSuccess -> pure output
      ExitFailure code ->
        throwE (BootstrapSourceCommand stage code (Text.takeEnd 4096 (Text.pack (processStderr output))))

io :: BootstrapSourceStage -> IO value -> Build value
io stage operation = ExceptT $ do
  result <- try operation
  pure $ case result of
    Left (cause :: IOException) -> Left (BootstrapSourceIo stage (firstLine (displayException cause)))
    Right value -> Right value

require :: BootstrapSourceStage -> Text -> Bool -> Build ()
require stage detail condition = unless condition (throwE (BootstrapSourceInvalid stage detail))

ensureDirectory :: FilePath -> Build ()
ensureDirectory path = do
  io SourceCache (createDirectoryIfMissing True path)
  status <- io SourceCache (getSymbolicLinkStatus path)
  uid <- io SourceCache getEffectiveUserID
  require
    SourceCache
    "the build cache path is not an owned directory"
    (isDirectory status && not (isSymbolicLink status) && fileOwner status == uid)
  io SourceCache (setFileMode path 0o700)

filePresent :: BootstrapSourceStage -> FilePath -> Build Bool
filePresent stage path = ExceptT $ do
  result <- try (getSymbolicLinkStatus path)
  pure $ case result of
    Left (cause :: IOException)
      | isDoesNotExistError cause -> Right False
      | otherwise -> Left (BootstrapSourceIo stage (firstLine (displayException cause)))
    Right status
      | isRegularFile status && not (isSymbolicLink status) -> Right True
      | otherwise -> Left (BootstrapSourceInvalid stage "a non-regular file occupies a build artifact")

observeOptional :: BootstrapSourceStage -> FilePath -> Build (Maybe ByteString.ByteString)
observeOptional stage path = do
  present <- filePresent stage path
  case present of
    True -> Just <$> strictFile stage (64 * 1024) path
    False -> pure Nothing

lazyFile :: BootstrapSourceStage -> Integer -> FilePath -> Build LazyByteString.ByteString
lazyFile stage maximumBytes path = do
  result <-
    io stage $
      bracket
        (openFd path ReadOnly (defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True}))
        closeFd
        ( \fd -> do
            status <- getFdStatus fd
            uid <- getEffectiveUserID
            if not (isRegularFile status && fileOwner status == uid)
              then pure (Left "the build artifact is not an owned regular file")
              else do
                -- Duplicate ownership of the descriptor is avoided by reading
                -- through a duplicate handle and keeping the bounded read strict.
                bytes <-
                  bracket
                    (fdToHandle =<< dup fd)
                    hClose
                    (\handle -> ByteString.hGet handle (fromInteger maximumBytes + 1))
                pure $
                  if toInteger (ByteString.length bytes) > maximumBytes
                    then Left "a build artifact exceeds its declared byte bound"
                    else Right (LazyByteString.fromStrict bytes)
        )
  either (throwE . BootstrapSourceInvalid stage) pure result

strictFile :: BootstrapSourceStage -> Integer -> FilePath -> Build ByteString.ByteString
strictFile stage maximumBytes path = LazyByteString.toStrict <$> lazyFile stage maximumBytes path

atomicBytes :: BootstrapSourceStage -> FilePath -> LazyByteString.ByteString -> Build ()
atomicBytes stage destination bytes = io stage $
  withTempFile (takeDirectory destination) ".bootstrap-partial" $ \temporary handle -> do
    setFileMode temporary 0o600
    LazyByteString.hPut handle bytes
    hFlush handle
    bracket
      (openFd temporary ReadOnly (defaultFileFlags {nofollow = True, cloexec = True}))
      closeFd
      fileSynchronise
    renameFile temporary destination
    bracket
      (openFd (takeDirectory destination) ReadOnly (defaultFileFlags {nofollow = True, cloexec = True}))
      closeFd
      fileSynchronise

withBuildDirectory :: FilePath -> (FilePath -> Build value) -> Build value
withBuildDirectory parent action = ExceptT $ do
  result <- try (withTempDirectory parent "bootstrap-job" (runExceptT . action))
  pure $ case result of
    Left (cause :: IOException) -> Left (BootstrapSourceIo SourceCache (firstLine (displayException cause)))
    Right value -> value

decodeValue :: BootstrapSourceStage -> ByteString.ByteString -> Build Value
decodeValue stage bytes = either (throwE . BootstrapSourceInvalid stage . firstLine) pure (eitherDecodeStrict' bytes)

parsed :: BootstrapSourceStage -> (Value -> Parser value) -> Value -> Build value
parsed stage parser value = either (throwE . BootstrapSourceInvalid stage . firstLine) pure (parseEither parser value)

canonicalHex :: Text -> Bool
canonicalHex value = Text.length value == 64 && Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') value

canonicalImageId :: Text -> Bool
canonicalImageId value = Text.isPrefixOf "sha256:" value && canonicalHex (Text.drop 7 value)

safeMember :: Text -> Bool
safeMember value =
  not (Text.null value)
    && Text.length value <= 200
    && Text.all (\c -> isAscii c && not (isControl c) && c /= '\\') value
    && all (\part -> not (Text.null part) && part /= "." && part /= "..") (Text.splitOn "/" value)

imageIndex :: Text -> Text
imageIndex = snd . Text.breakOnEnd "@"

architectureText :: BootstrapImageArchitecture -> Text
architectureText architecture = case architecture of
  BootstrapImageAmd64 -> "amd64"
  BootstrapImageArm64 -> "arm64"

firstLine :: String -> Text
firstLine = Text.take 512 . Text.pack . takeWhile (/= '\n')

digest :: LazyByteString.ByteString -> Text
digest bytes = TextEncoding.decodeUtf8 (convertToBase Base16 (hashlazy bytes :: Digest SHA256))

mib :: Integer
mib = 1024 * 1024
