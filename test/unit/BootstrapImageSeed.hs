-- | Sprint 4.106: how the pre-registry public images reach RKE2 containerd, over
-- a scripted Docker cache and containerd.
--
-- The MinIO server and the @mc@ client its bootstrap Jobs run are the home
-- cluster's only images that cannot come from the in-cluster registry, and their
-- upstream no longer serves an anonymous pull. The seeding must therefore leave
-- an image containerd already lists alone, import one the Docker cache holds,
-- pull one nothing holds, read every import back, and say which image it could
-- not obtain and how to restore it. None of that needs a cluster: the effects are
-- a record, and the cases below script the world they act on.
module BootstrapImageSeed (bootstrapImageSeedSuite) where

import Control.Monad (when)
import Data.Either (isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import Prodbox.ContainerImage
  ( ImageRef
  , publicMinioImage
  , publicMinioMcImage
  , renderImageRef
  , requiredPublicImagePairs
  )
import Prodbox.Infra.BootstrapImageSeed
  ( BootstrapImageObservation (..)
  , BootstrapImageSeedAction (..)
  , BootstrapImageSeedEffects (..)
  , BootstrapImageSeedOutcome (..)
  , bootstrapSeedImages
  , decideBootstrapImageSeed
  , renderBootstrapImagePullFailure
  , renderBootstrapImageSeedOutcome
  , seedBootstrapImages
  )
import TestSupport

-- | The two stores and the order every call reached them in.
data World = World
  { worldContainerd :: IORef [String]
  , worldDocker :: IORef [String]
  , worldEvents :: IORef [String]
  }

newWorld :: [String] -> [String] -> IO World
newWorld inContainerd inDocker =
  World <$> newIORef inContainerd <*> newIORef inDocker <*> newIORef []

-- | Effects over a world. A pull lands in the Docker cache when it succeeds, an
-- import lands in containerd when it succeeds and when the world lets it (the
-- last flag scripts an import that reports success and lists nothing).
effectsOver
  :: World
  -> Either String ()
  -> Either String ()
  -> Bool
  -> BootstrapImageSeedEffects
effectsOver world pullAnswer importAnswer importLands =
  BootstrapImageSeedEffects
    { seedEffectContainerdHolds = \reference -> do
        record ("containerd-holds " <> reference)
        elem reference <$> readIORef (worldContainerd world)
    , seedEffectHostDockerHolds = \reference -> do
        record ("docker-holds " <> reference)
        elem reference <$> readIORef (worldDocker world)
    , seedEffectPullIntoHostDocker = \reference -> do
        record ("pull " <> reference)
        when (isRight pullAnswer) (modifyIORef' (worldDocker world) (reference :))
        pure pullAnswer
    , seedEffectImportIntoContainerd = \reference -> do
        record ("import " <> reference)
        when (isRight importAnswer && importLands) (modifyIORef' (worldContainerd world) (reference :))
        pure importAnswer
    }
 where
  record event = modifyIORef' (worldEvents world) (++ [event])

events :: World -> IO [String]
events = readIORef . worldEvents

minioServer :: String
minioServer = renderImageRef publicMinioImage

minioClient :: String
minioClient = renderImageRef publicMinioMcImage

both :: [ImageRef]
both = [publicMinioImage, publicMinioMcImage]

failureOf :: Either String [BootstrapImageSeedOutcome] -> String
failureOf (Left failure) = failure
failureOf (Right outcomes) = "unexpected success: " <> show outcomes

bootstrapImageSeedSuite :: SuiteBuilder ()
bootstrapImageSeedSuite =
  describe "Sprint 4.106 the pre-registry public images are seeded into RKE2 containerd" $ do
    it "decides by name, from containerd first and the Docker cache second" $ do
      decideBootstrapImageSeed (BootstrapImageObservation True True) `shouldBe` BootstrapImagePresent
      -- Whether the Docker cache also holds it is irrelevant once containerd lists the name.
      decideBootstrapImageSeed (BootstrapImageObservation True False) `shouldBe` BootstrapImagePresent
      decideBootstrapImageSeed (BootstrapImageObservation False True)
        `shouldBe` BootstrapImageImportFromHostDocker
      decideBootstrapImageSeed (BootstrapImageObservation False False)
        `shouldBe` BootstrapImagePullThenImport

    it
      "seeds exactly the public MinIO references the mirror table names, so a third one cannot be forgotten"
      $ do
        let seeded = sort (map renderImageRef bootstrapSeedImages)
            publicMinioSources =
              sort
                [ source
                | (source, _target) <- requiredPublicImagePairs
                , "quay.io/minio/" `isPrefixOf` source
                ]
        seeded `shouldBe` publicMinioSources
        seeded `shouldBe` sort [minioServer, minioClient]

    it "leaves an image containerd already lists alone and never asks the Docker cache" $ do
      world <- newWorld [minioServer, minioClient] []
      outcomes <-
        seedBootstrapImages (effectsOver world (Left "unused") (Left "unused") True) both
      outcomes
        `shouldBe` Right [BootstrapImageAlreadyPresent minioServer, BootstrapImageAlreadyPresent minioClient]
      events world
        `shouldReturn` ["containerd-holds " <> minioServer, "containerd-holds " <> minioClient]

    it "imports from the Docker cache what containerd lacks, then reads containerd back" $ do
      world <- newWorld [] [minioServer, minioClient]
      outcomes <- seedBootstrapImages (effectsOver world (Left "unused") (Right ()) True) both
      outcomes
        `shouldBe` Right
          [ BootstrapImageSeededFromHostDocker minioServer
          , BootstrapImageSeededFromHostDocker minioClient
          ]
      events world
        `shouldReturn` [ "containerd-holds " <> minioServer
                       , "docker-holds " <> minioServer
                       , "import " <> minioServer
                       , "containerd-holds " <> minioServer
                       , "containerd-holds " <> minioClient
                       , "docker-holds " <> minioClient
                       , "import " <> minioClient
                       , "containerd-holds " <> minioClient
                       ]

    it "pulls into the Docker cache only what no store holds, then imports it" $ do
      world <- newWorld [minioClient] []
      outcomes <- seedBootstrapImages (effectsOver world (Right ()) (Right ()) True) both
      outcomes
        `shouldBe` Right [BootstrapImageSeededByPull minioServer, BootstrapImageAlreadyPresent minioClient]
      events world
        `shouldReturn` [ "containerd-holds " <> minioServer
                       , "docker-holds " <> minioServer
                       , "pull " <> minioServer
                       , "import " <> minioServer
                       , "containerd-holds " <> minioServer
                       , "containerd-holds " <> minioClient
                       ]

    it "names the image, the registry's answer and both ways to restore it when the pull is refused" $ do
      world <- newWorld [] []
      let registryAnswer =
            unlines
              [ "Error response from daemon: unauthorized: access to the requested resource is not authorized"
              , "a second line the operator does not need first"
              ]
      outcomes <-
        seedBootstrapImages (effectsOver world (Left registryAnswer) (Right ()) True) both
      let failure = failureOf outcomes
      failure `shouldContain` minioServer
      failure `shouldContain` "unauthorized: access to the requested resource is not authorized"
      failure `shouldNotContain` "a second line"
      failure `shouldContain` "docker load -i <archive>"
      failure `shouldContain` ("docker tag <mirror-reference> " <> minioServer)
      failure `shouldContain` "RKE2 containerd does not list it"
      failure `shouldContain` "host Docker cache does not hold it"
      -- Nothing was imported, and the second image was never touched: the first
      -- failure stops the fold.
      eventLog <- events world
      eventLog
        `shouldBe` [ "containerd-holds " <> minioServer
                   , "docker-holds " <> minioServer
                   , "pull " <> minioServer
                   ]

    it "refuses an import that fails, naming the image, and does not read back" $ do
      world <- newWorld [] [minioServer]
      outcomes <-
        seedBootstrapImages
          (effectsOver world (Left "unused") (Left "docker save or ctr import exited with status 1") True)
          [publicMinioImage]
      let failure = failureOf outcomes
      failure `shouldContain` minioServer
      failure `shouldContain` "could not be imported into RKE2 containerd"
      failure `shouldContain` "exited with status 1"
      events world
        `shouldReturn` [ "containerd-holds " <> minioServer
                       , "docker-holds " <> minioServer
                       , "import " <> minioServer
                       ]

    it "does not trust an import that reports success while containerd still lists nothing" $ do
      world <- newWorld [] [minioServer]
      outcomes <-
        seedBootstrapImages (effectsOver world (Left "unused") (Right ()) False) [publicMinioImage]
      let failure = failureOf outcomes
      failure `shouldContain` minioServer
      failure `shouldContain` "still does not list it under that name"
      events world
        `shouldReturn` [ "containerd-holds " <> minioServer
                       , "docker-holds " <> minioServer
                       , "import " <> minioServer
                       , "containerd-holds " <> minioServer
                       ]

    it "bounds a registry answer to its first line so the remedy stays in view" $ do
      let long = replicate 1000 'x'
          rendered = renderBootstrapImagePullFailure minioServer long
      rendered `shouldContain` (replicate 240 'x' <> "...")
      rendered `shouldNotContain` replicate 241 'x'
      rendered `shouldContain` "docker load -i <archive>"
      renderBootstrapImagePullFailure minioServer "" `shouldContain` "no detail"

    it "narrates each outcome with the image it concerns, in three different sentences" $ do
      let narration =
            map
              renderBootstrapImageSeedOutcome
              [ BootstrapImageAlreadyPresent minioServer
              , BootstrapImageSeededFromHostDocker minioServer
              , BootstrapImageSeededByPull minioServer
              ]
      all (minioServer `isInfixOf`) narration `shouldBe` True
      length (nub narration) `shouldBe` 3
      case narration of
        [present, fromDocker, pulled] -> do
          present `shouldContain` "already in RKE2 containerd"
          fromDocker `shouldContain` "from the host Docker cache"
          pulled `shouldContain` "pulled into the host Docker cache"
        _ -> expectationFailure "expected exactly one sentence per outcome"
