{-# LANGUAGE ImportQualifiedPost #-}

module BootstrapImageSeed (bootstrapImageSeedSuite) where

import Control.Monad (when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf, isSuffixOf, sort)
import Prodbox.ContainerImage
  ( publicMinioImage
  , publicMinioMcImage
  , renderImageRef
  , requiredPublicImagePairs
  )
import Prodbox.Infra.BootstrapImageSeed
import TestSupport

expected :: String
expected = "sha256:" <> replicate 64 'a'
wrong :: String
wrong = "sha256:" <> replicate 64 'b'
server :: String
server = renderImageRef publicMinioImage
input :: BootstrapImageSeedInput
input = BootstrapImageSeedInput publicMinioImage expected

bootstrapImageSeedSuite :: SuiteBuilder ()
bootstrapImageSeedSuite = describe "Sprint 6.5 exact source artifact seeding" $ do
  it "accepts only the expected config digest and requires a verified import for a wrong cached tag" $ do
    mapM_
      ( \(containerd, docker, outcome) ->
          decideBootstrapImageSeed expected (BootstrapImageObservation containerd docker) `shouldBe` outcome
      )
      [ (Just expected, Nothing, BootstrapImagePresent)
      , (Just expected, Just wrong, BootstrapImagePresent)
      , (Just wrong, Just expected, BootstrapImageImportFromVerifiedArtifact)
      , (Nothing, Just expected, BootstrapImageImportFromVerifiedArtifact)
      , (Just wrong, Just wrong, BootstrapImageVerifiedArtifactUnavailable)
      , (Nothing, Nothing, BootstrapImageVerifiedArtifactUnavailable)
      ]

  it
    "uses the same own source references and versioned mirror targets before and after registry bootstrap"
    $ do
      let refs = map renderImageRef bootstrapSeedImages
          pairs = [(source, target) | (source, target) <- requiredPublicImagePairs, source `elem` refs]
      sort refs `shouldBe` sort (map renderImageRef [publicMinioImage, publicMinioMcImage])
      all ("docker.io/prodbox/" `isPrefixOf`) refs `shouldBe` True
      all
        (\(source, target) -> "-source-v1" `isSuffixOf` source && "-source-v1" `isSuffixOf` target)
        pairs
        `shouldBe` True
      length pairs `shouldBe` 2

  it "leaves the expected containerd config alone without consulting Docker" $ do
    calls <- newIORef []
    let effects =
          BootstrapImageSeedEffects
            (\ref -> modifyIORef' calls (++ ["observe " <> ref]) >> pure (Just expected))
            (\_ -> expectationFailure "Docker must not be consulted" >> pure Nothing)
            (\_ -> expectationFailure "no import required" >> pure (Right ()))
    seedBootstrapImages effects [input] `shouldReturn` Right [BootstrapImageAlreadyPresent server]
    readIORef calls `shouldReturn` ["observe " <> server]

  it "replaces a wrong containerd tag from the verified host artifact and independently reads it back" $ do
    imported <- newIORef False
    calls <- newIORef []
    let record event = modifyIORef' calls (++ [event])
        effects =
          BootstrapImageSeedEffects
            ( \_ -> do
                record "containerd"
                done <- readIORef imported
                pure (Just (if done then expected else wrong))
            )
            (\_ -> record "docker" >> pure (Just expected))
            (\_ -> record "import" >> modifyIORef' imported (const True) >> pure (Right ()))
    seedBootstrapImages effects [input]
      `shouldReturn` Right [BootstrapImageSeededFromVerifiedArtifact server]
    readIORef calls `shouldReturn` ["containerd", "docker", "import", "containerd"]

  it "refuses a wrong Docker identity before invoking an import" $ do
    mutation <- newIORef False
    let effects =
          BootstrapImageSeedEffects
            (const (pure Nothing))
            (const (pure (Just wrong)))
            (\_ -> modifyIORef' mutation (const True) >> pure (Right ()))
    result <- seedBootstrapImages effects [input]
    result `shouldSatisfy` failed
    readIORef mutation `shouldReturn` False
    case result of
      Left cause -> cause `shouldContain` "prodbox cluster reconcile"
      Right _ -> expectationFailure "unverified image was accepted"

  it "refuses false-success imports whose final observation is wrong or unobservable" $
    mapM_
      ( \observed -> do
          let effects =
                BootstrapImageSeedEffects
                  (const (pure observed))
                  (const (pure (Just expected)))
                  (const (pure (Right ())))
          result <- seedBootstrapImages effects [input]
          result `shouldSatisfy` failed
      )
      [Nothing, Just wrong]

  it "preserves a failed import and stops before the next image or a success read-back" $ do
    calls <- newIORef []
    let effects =
          BootstrapImageSeedEffects
            (\ref -> modifyIORef' calls (++ [ref]) >> pure Nothing)
            (const (pure (Just expected)))
            (const (pure (Left "archive import failed")))
    result <- seedBootstrapImages effects [input, BootstrapImageSeedInput publicMinioMcImage expected]
    case result of
      Left cause -> cause `shouldContain` "archive import failed"
      Right _ -> expectationFailure "failed import was accepted"
    readIORef calls `shouldReturn` [server]

  it "keeps successful narration distinct for verified presence and verified import" $ do
    let present = renderBootstrapImageSeedOutcome (BootstrapImageAlreadyPresent server)
        imported = renderBootstrapImageSeedOutcome (BootstrapImageSeededFromVerifiedArtifact server)
    present `shouldContain` "verified source identity"
    imported `shouldContain` "verified source artifact"
    when (present == imported) (expectationFailure "seed outcomes are indistinguishable")

failed :: Either String value -> Bool
failed result = case result of
  Left _ -> True
  Right _ -> False
