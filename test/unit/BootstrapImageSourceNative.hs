{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapImageSourceNative (bootstrapImageSourceNativeSuite) where

import BootstrapSourceFixture (writeBootstrapSourceFixture)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.BootstrapImageArchive (BootstrapImageArchitecture (BootstrapImageAmd64))
import Prodbox.Infra.BootstrapImageSourceNative
import Prodbox.Subprocess (ProcessOutput (..), Subprocess (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createNamedPipe, createSymbolicLink)
import System.Timeout (timeout)
import TestSupport

bootstrapImageSourceNativeSuite :: SuiteBuilder ()
bootstrapImageSourceNativeSuite = describe "Sprint 6.5 retained source-built bootstrap artifacts" $ do
  it "reassembles both retained artifacts, verifies actual loaded IDs and reuses identical archives" $
    withSystemTempDirectory "bootstrap-source" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      calls <- newIORef []
      let effects = fakeDocker fixtures (\arguments -> modifyIORef' calls (++ [arguments])) False
      first <- ensureBootstrapSourceArtifactsWith effects root BootstrapImageAmd64
      second <- ensureBootstrapSourceArtifactsWith effects root BootstrapImageAmd64
      fmap identities first `shouldBe` Right (map (\(ref, identity, _) -> (ref, identity)) fixtures)
      fmap paths first `shouldBe` fmap paths second
      fmap identities first `shouldBe` fmap identities second
      observed <- readIORef calls
      length observed `shouldBe` 8
      all (\arguments -> take 2 arguments `elem` [["image", "load"], ["image", "inspect"]]) observed
        `shouldBe` True

  it "refuses changed retained compiler output before Docker sees it" $
    withSystemTempDirectory "bootstrap-source-corrupt" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      case fixtures of
        (_, _, location) : _ -> writeFile (location </> "binary") "changed bytes"
        [] -> expectationFailure "missing source fixture"
      calls <- newIORef []
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker fixtures (\args -> modifyIORef' calls (++ [args])) False)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceCache
      readIORef calls `shouldReturn` []

  it "refuses an image load whose independently observed config digest differs" $
    withSystemTempDirectory "bootstrap-source-id" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker fixtures (const (pure ())) True)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceObserve

  it "refuses a corrupted content-addressed archive before loading it" $
    withSystemTempDirectory "bootstrap-source-archive" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      let effects = fakeDocker fixtures (const (pure ())) False
      first <- ensureBootstrapSourceArtifactsWith effects root BootstrapImageAmd64
      case first of
        Right (artifact : _) -> writeFile (bootstrapSourceArtifactArchivePath artifact) "corrupt archive"
        _ -> expectationFailure "fixture did not publish an archive"
      calls <- newIORef []
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker fixtures (\args -> modifyIORef' calls (++ [args])) False)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceCache
      readIORef calls `shouldReturn` []

  it "refuses a FIFO receipt without waiting for a writer" $
    withSystemTempDirectory "bootstrap-source-fifo" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      case fixtures of
        (_, _, location) : _ -> do
          removeFile (location </> "inputs.json")
          createNamedPipe (location </> "inputs.json") 0o600
        [] -> expectationFailure "missing source fixture"
      result <-
        timeout
          1_000_000
          ( ensureBootstrapSourceArtifactsWith
              (fakeDocker fixtures (const (pure ())) False)
              root
              BootstrapImageAmd64
          )
      case result of
        Just failure -> failure `shouldSatisfy` isFailureAt SourceCache
        Nothing -> expectationFailure "FIFO blocked the bounded receipt read"

  it "rejects a symlink build lock without changing its target" $
    withSystemTempDirectory "bootstrap-source-lock" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      let target = root </> "foreign"
      writeFile target "unchanged"
      createSymbolicLink target (root </> ".build" </> "bootstrap-images-v1" </> "build.lock")
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker fixtures (const (pure ())) False)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isLeft
      readFile target `shouldReturn` "unchanged"

  it "refuses a symlink cache directory before acquiring or loading anything" $
    withSystemTempDirectory "bootstrap-source-directory" $ \root -> do
      createDirectoryIfMissing True (root </> ".build")
      let target = root </> "foreign"
      createDirectoryIfMissing True target
      createSymbolicLink target (root </> ".build" </> "bootstrap-images-v1")
      calls <- newIORef []
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker [] (\args -> modifyIORef' calls (++ [args])) False)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceCache
      readIORef calls `shouldReturn` []

  it "rejects a symlink .build parent before creating a cache outside the repository" $
    withSystemTempDirectory "bootstrap-source-parent" $ \root -> do
      let target = root </> "foreign"
      createDirectoryIfMissing True target
      createSymbolicLink target (root </> ".build")
      result <-
        ensureBootstrapSourceArtifactsWith (fakeDocker [] (const (pure ())) False) root BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceCache
      doesDirectoryExist (target </> "bootstrap-images-v1") `shouldReturn` False

  it "bounds a retained certificate independently of the large binary allowance" $
    withSystemTempDirectory "bootstrap-source-size" $ \root -> do
      fixtures <- writeBootstrapSourceFixture root
      case fixtures of
        (_, _, location) : _ -> writeFile (location </> "ca.pem") (replicate (512 * 1024 + 1) 'x')
        [] -> expectationFailure "missing source fixture"
      result <-
        ensureBootstrapSourceArtifactsWith
          (fakeDocker fixtures (const (pure ())) False)
          root
          BootstrapImageAmd64
      result `shouldSatisfy` isFailureAt SourceCache

identities :: [BootstrapSourceArtifact] -> [(Text, Text)]
identities =
  map
    (\artifact -> (bootstrapSourceArtifactReference artifact, bootstrapSourceArtifactIdentity artifact))
paths :: [BootstrapSourceArtifact] -> [FilePath]
paths = map bootstrapSourceArtifactArchivePath
isFailureAt :: BootstrapSourceStage -> Either BootstrapSourceError value -> Bool
isFailureAt expected result = case result of
  Left (BootstrapSourceInvalid stage _) -> stage == expected
  Left (BootstrapSourceIo stage _) -> stage == expected
  Left (BootstrapSourceCommand stage _ _) -> stage == expected
  Left (BootstrapSourceArchive _) -> False
  Right _ -> False

fakeDocker :: [(Text, Text, FilePath)] -> ([String] -> IO ()) -> Bool -> BootstrapSourceEffects
fakeDocker fixtures record wrongIdentity = BootstrapSourceEffects $ \_ subprocess -> do
  let arguments = subprocessArguments subprocess
      success output = pure (Right (ProcessOutput ExitSuccess output ""))
  record arguments
  case arguments of
    ["image", "load", "--input", _] -> success "loaded"
    ["image", "inspect", reference] -> case [identity | (ref, identity, _) <- fixtures, Text.unpack ref == reference] of
      [identity] ->
        success
          ( LazyChar8.unpack
              ( encode
                  [ object
                      [ "Id" .= (if wrongIdentity then "sha256:" <> Text.replicate 64 "a" else identity)
                      , "Architecture" .= ("amd64" :: Text)
                      , "RootFS" .= object ["Layers" .= ([] :: [Text])]
                      , "RepoDigests" .= ([] :: [Text])
                      ]
                  ]
              )
          )
      _ -> pure (Right (ProcessOutput (ExitFailure 1) "" "unknown image"))
    _ -> pure (Right (ProcessOutput (ExitFailure 1) "" "unexpected source acquisition"))
