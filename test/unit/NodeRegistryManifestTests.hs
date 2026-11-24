{-# LANGUAGE OverloadedStrings #-}

module NodeRegistryManifestTests (nodeRegistryManifestSuite) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as TarEntry
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Prodbox.Control.NodeRegistryArchive
  ( NodeRegistryArchiveResult (..)
  , writeNodeRegistryArchive
  )
import Prodbox.Control.NodeRegistryBlob (NodeBlobVerification (..), verifyNodeRegistryBlob)
import Prodbox.Control.NodeRegistryClient
  ( NodeRegistryDocument (..)
  , NodeRegistryReadError (..)
  , fetchNodeRegistryBlob
  , fetchNodeRegistryManifest
  , fetchPinnedKindTool
  )
import Prodbox.Control.NodeRegistryManifest
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode, WriteMode), withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import TestSupport (SuiteBuilder, assertMutationInvariant, describe, it, shouldBe)

nodeRegistryManifestSuite :: SuiteBuilder ()
nodeRegistryManifestSuite = describe "node registry manifest" $ do
  it "refuses an invalid selected digest before attempting a registry read" $ do
    fetchNodeRegistryManifest "sha256:BAD" >>= (`shouldBe` Left NodeRegistryReadInvalidDigest)
    withSystemTempDirectory "prodbox-invalid-node-blob" $ \directory -> do
      let path = directory </> "blob"
      withBinaryFile
        path
        WriteMode
        (fetchNodeRegistryBlob validLayer {nodeRegistryBlobDigest = "invalid"})
        >>= (`shouldBe` Left NodeRegistryReadInvalidDigest)
      ByteString.readFile path >>= (`shouldBe` ByteString.empty)
      withBinaryFile path WriteMode (fetchPinnedKindTool "sha256:BAD" 1048576)
        >>= (`shouldBe` Left NodeRegistryReadInvalidDigest)
      ByteString.readFile path >>= (`shouldBe` ByteString.empty)

  it "binds a valid manifest to its exact digest and bounded blob descriptors" $ do
    let bytes = manifest 2 validConfig [validLayer]
    parseNodeRegistryManifest (digest bytes) bytes
      `shouldBe` Right (NodeRegistryPlan validConfig [validLayer])
    parseNodeRegistryManifest ("sha256:" <> Text.replicate 64 "0") bytes
      `shouldBe` Left NodeRegistryDigestMismatch
    parseNodeRegistryManifest "sha256:BAD" bytes
      `shouldBe` Left NodeRegistryInvalidDigest
    parseNodeRegistryManifest (digest bytes) (ByteString.replicate 1048577 32)
      `shouldBe` Left NodeRegistryManifestTooLarge

  it "rejects unsupported versions, sizes, duplicate digests and media types" $ do
    let rejected version config layers =
          let bytes = manifest version config layers
           in parseNodeRegistryManifest (digest bytes) bytes
    rejected 1 validConfig [validLayer] `shouldBe` Left NodeRegistryMalformedManifest
    rejected 2 validConfig [] `shouldBe` Left NodeRegistryMalformedManifest
    rejected 2 validConfig [validLayer {nodeRegistryBlobSize = 0}]
      `shouldBe` Left NodeRegistryMalformedManifest
    rejected 2 validConfig [validLayer, validLayer] `shouldBe` Left NodeRegistryMalformedManifest
    rejected 2 validConfig [validLayer {nodeRegistryBlobMediaType = "text/plain"}]
      `shouldBe` Left NodeRegistryMalformedManifest
    rejected
      2
      validConfig
      [validLayer {nodeRegistryBlobMediaType = "application/vnd.docker.image.rootfs.diff.tar.gzip"}]
      `shouldBe` Left NodeRegistryMalformedManifest

  it "checks actual blob bytes and exact size rather than its descriptor alone" $
    withSystemTempDirectory "prodbox-node-blob" $ \directory -> do
      let path = directory </> "blob"
          original = "synthetic-content"
          descriptor =
            validLayer
              { nodeRegistryBlobDigest = digest original
              , nodeRegistryBlobSize = fromIntegral (ByteString.length original)
              }
          verify value = withBinaryFile path ReadMode (verifyNodeRegistryBlob value)
      ByteString.writeFile path original
      verify descriptor >>= (`shouldBe` NodeBlobVerified)
      verify descriptor {nodeRegistryBlobSize = nodeRegistryBlobSize descriptor + 1}
        >>= (`shouldBe` NodeBlobSizeMismatch)
      verify descriptor {nodeRegistryBlobSize = nodeRegistryBlobSize descriptor - 1}
        >>= (`shouldBe` NodeBlobSizeMismatch)
      ByteString.writeFile path "synthetic-conteng"
      altered <- verify descriptor
      assertMutationInvariant "artifact.rejects_changed_bytes" (altered == NodeBlobDigestMismatch)

  it "writes a digest-bound archive and refuses changed source bytes" $
    withSystemTempDirectory "prodbox-node-archive" $ \directory -> do
      let configBytes = "config-content"
          layerBytes = "layer-content"
          config =
            validConfig
              { nodeRegistryBlobDigest = digest configBytes
              , nodeRegistryBlobSize = fromIntegral (ByteString.length configBytes)
              }
          layer =
            validLayer
              { nodeRegistryBlobDigest = digest layerBytes
              , nodeRegistryBlobSize = fromIntegral (ByteString.length layerBytes)
              }
          bytes = manifest 2 config [layer]
          document = NodeRegistryDocument bytes (NodeRegistryPlan config [layer])
          configPath = directory </> "config"
          layerPath = directory </> "layer"
          outputPath = directory </> "archive"
          runArchive = withBinaryFile configPath ReadMode $ \configHandle ->
            withBinaryFile layerPath ReadMode $ \layerHandle ->
              withBinaryFile
                outputPath
                WriteMode
                (writeNodeRegistryArchive (digest bytes) document [configHandle, layerHandle])
      ByteString.writeFile configPath configBytes
      ByteString.writeFile layerPath layerBytes
      result <- runArchive
      archive <- ByteString.readFile outputPath
      let archiveEntries = Tar.read (LazyByteString.fromStrict archive)
          names entries = case entries of
            Tar.Done -> Just []
            Tar.Fail _ -> Nothing
            Tar.Next entry rest -> (TarEntry.entryPath entry :) <$> names rest
          blobName value = "blobs/sha256/" ++ Text.unpack (Text.drop 7 value)
      names archiveEntries
        `shouldBe` Just
          [ "oci-layout"
          , "index.json"
          , blobName (digest bytes)
          , blobName (digest configBytes)
          , blobName (digest layerBytes)
          ]
      case result of
        NodeRegistryArchiveWritten observed size -> do
          observed `shouldBe` digest archive
          size `shouldBe` fromIntegral (ByteString.length archive)
        _ -> result `shouldBe` NodeRegistryArchiveWritten "expected" 0
      ByteString.writeFile layerPath "layer-contenu"
      changed <- runArchive
      assertMutationInvariant "artifact.rejects_changed_bytes" (changed == NodeRegistryArchiveMismatch)

validConfig, validLayer :: NodeRegistryBlob
validConfig =
  NodeRegistryBlob ("sha256:" <> Text.replicate 64 "a") 24 "application/vnd.oci.image.config.v1+json"
validLayer =
  NodeRegistryBlob
    ("sha256:" <> Text.replicate 64 "b")
    99
    "application/vnd.oci.image.layer.v1.tar+gzip"

digest :: ByteString.ByteString -> Text.Text
digest bytes = "sha256:" <> Text.pack (show (hash bytes :: Digest SHA256))

manifest :: Int -> NodeRegistryBlob -> [NodeRegistryBlob] -> ByteString.ByteString
manifest version config layers =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schemaVersion" .= version
        , "mediaType" .= ("application/vnd.oci.image.manifest.v1+json" :: Text.Text)
        , "config" .= blob config
        , "layers" .= map blob layers
        ]
 where
  blob value =
    Aeson.object
      [ "digest" .= nodeRegistryBlobDigest value
      , "size" .= nodeRegistryBlobSize value
      , "mediaType" .= nodeRegistryBlobMediaType value
      ]
