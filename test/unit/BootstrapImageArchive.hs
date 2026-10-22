{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapImageArchive (bootstrapImageArchiveSuite) where

import Control.Exception (evaluate)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isRight)
import Data.List (nub)
import Data.Text (Text)
import Prodbox.Infra.BootstrapImageArchive
import System.Timeout (timeout)
import TestSupport

bootstrapImageArchiveSuite :: SuiteBuilder ()
bootstrapImageArchiveSuite =
  describe "Sprint 6.5 canonical source bootstrap image archives" $ do
    it "ignores metadata object insertion order and preserves the exact archive bytes" $ do
      let left =
            fixture
              { bootstrapInputSourceManifest = object ["schema" .= (1 :: Int), "source" .= ("pinned" :: Text)]
              }
          right =
            fixture
              { bootstrapInputSourceManifest = object ["source" .= ("pinned" :: Text), "schema" .= (1 :: Int)]
              }
          assembledLeft = assemble left
          assembledRight = assemble right
      fmap bootstrapImageArchiveIdentity assembledLeft `shouldSatisfy` isRight
      fmap bootstrapImageArchiveDigest assembledLeft
        `shouldBe` fmap bootstrapImageArchiveDigest assembledRight
      fmap bootstrapImageArchiveBytes assembledLeft
        `shouldBe` fmap bootstrapImageArchiveBytes assembledRight

    it "binds the component and target architecture to distinct image identities" $ do
      let identities =
            [ fmap bootstrapImageArchiveIdentity (assembleBootstrapImageArchive component architecture fixture)
            | component <- [BootstrapMinioServer, BootstrapMinioClient]
            , architecture <- [BootstrapImageAmd64, BootstrapImageArm64]
            ]
      all isRight identities `shouldBe` True
      length (nub identities) `shouldBe` 4

    it "changes the image identity when trust bundle bytes change" $ do
      let original = fmap bootstrapImageArchiveIdentity (assemble fixture)
          changed =
            fmap
              bootstrapImageArchiveIdentity
              (assemble fixture {bootstrapInputCertificateBundle = "different trust bundle"})
      original `shouldSatisfy` isRight
      changed `shouldSatisfy` isRight
      original `shouldNotBe` changed

    it "rejects every non-object history and source manifest before packaging" $
      mapM_
        ( \value -> do
            fmap bootstrapImageArchiveIdentity (assemble fixture {bootstrapInputBaseHistory = value})
              `shouldBe` Left (BootstrapImageMetadataInvalid BootstrapBaseHistory)
            fmap bootstrapImageArchiveIdentity (assemble fixture {bootstrapInputSourceManifest = value})
              `shouldBe` Left (BootstrapImageMetadataInvalid BootstrapSourceManifest)
        )
        [Null, Bool False, Number 1, String "wrong shape", Array mempty]

    it "refuses an empty required build input instead of emitting an incomplete image" $
      mapM_
        ( \(field, inputs) ->
            fmap bootstrapImageArchiveIdentity (assemble inputs)
              `shouldBe` Left (BootstrapImageInputEmpty field)
        )
        [ (BootstrapBaseLayer, fixture {bootstrapInputBaseLayer = ""})
        , (BootstrapBinary, fixture {bootstrapInputBinary = ""})
        , (BootstrapLicense, fixture {bootstrapInputLicense = ""})
        , (BootstrapCertificateBundle, fixture {bootstrapInputCertificateBundle = ""})
        ]

    it "bounds a hostile lazy binary by its prefix without traversing its tail" $ do
      let classified = case assemble fixture {bootstrapInputBinary = LazyByteString.repeat 0} of
            Left (BootstrapImageInputTooLarge BootstrapBinary observed maximumBytes) ->
              observed == 128 * 1024 * 1024 + 1 && maximumBytes == 128 * 1024 * 1024
            Left _ -> False
            Right _ -> False
      timeout 1_000_000 (evaluate classified) `shouldReturn` Just True

    it "bounds the retained licence and trust bundle independently" $ do
      fmap
        bootstrapImageArchiveIdentity
        (assemble fixture {bootstrapInputLicense = ByteString.replicate (128 * 1024 + 1) 65})
        `shouldBe` Left (BootstrapImageInputTooLarge BootstrapLicense (128 * 1024 + 1) (128 * 1024))
      fmap
        bootstrapImageArchiveIdentity
        (assemble fixture {bootstrapInputCertificateBundle = ByteString.replicate (512 * 1024 + 1) 65})
        `shouldBe` Left (BootstrapImageInputTooLarge BootstrapCertificateBundle (512 * 1024 + 1) (512 * 1024))

    it "uses owned bootstrap references and keeps the pinned releases distinct" $ do
      fmap bootstrapImageArchiveReference (assemble fixture)
        `shouldBe` Right "docker.io/prodbox/minio-bootstrap:RELEASE.2024-12-18T13-15-44Z-source-v1"
      fmap
        bootstrapImageArchiveReference
        (assembleBootstrapImageArchive BootstrapMinioClient BootstrapImageAmd64 fixture)
        `shouldBe` Right "docker.io/prodbox/mc-bootstrap:RELEASE.2024-11-21T17-21-54Z-source-v1"

assemble :: BootstrapImageInputs -> Either BootstrapImageArchiveError BootstrapImageArchive
assemble = assembleBootstrapImageArchive BootstrapMinioServer BootstrapImageAmd64

fixture :: BootstrapImageInputs
fixture =
  BootstrapImageInputs
    { bootstrapInputBaseLayer = "public base filesystem fixture"
    , bootstrapInputBaseHistory = object ["created_by" .= ("pinned base fixture" :: Text)]
    , bootstrapInputBinary = "public compiled binary fixture"
    , bootstrapInputLicense = "public licence fixture"
    , bootstrapInputCertificateBundle = "public trust bundle fixture"
    , bootstrapInputSourceManifest = object ["schema" .= (1 :: Int)]
    }
