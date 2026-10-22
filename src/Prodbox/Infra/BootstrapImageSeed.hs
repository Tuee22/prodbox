{-# LANGUAGE ImportQualifiedPost #-}

-- | Import retained source-built images only after both stores report the exact
-- canonical config digest. An unobservable read cannot prove identity.
module Prodbox.Infra.BootstrapImageSeed
  ( BootstrapImageSeedEffects (..)
  , BootstrapImageSeedInput (..)
  , BootstrapImageObservation (..)
  , BootstrapImageSeedAction (..)
  , BootstrapImageSeedOutcome (..)
  , bootstrapSeedImages
  , decideBootstrapImageSeed
  , seedBootstrapImages
  , renderBootstrapImageSeedOutcome
  ) where

import Prodbox.ContainerImage (ImageRef, publicMinioImage, publicMinioMcImage, renderImageRef)

bootstrapSeedImages :: [ImageRef]
bootstrapSeedImages = [publicMinioImage, publicMinioMcImage]

data BootstrapImageSeedInput = BootstrapImageSeedInput
  { seedImageReference :: ImageRef
  , seedImageIdentity :: String
  }
  deriving (Eq, Show)

data BootstrapImageSeedEffects = BootstrapImageSeedEffects
  { seedEffectContainerdIdentity :: String -> IO (Maybe String)
  , seedEffectHostDockerIdentity :: String -> IO (Maybe String)
  , seedEffectImportIntoContainerd :: String -> IO (Either String ())
  }

data BootstrapImageObservation = BootstrapImageObservation
  { observedContainerdIdentity :: Maybe String
  , observedHostDockerIdentity :: Maybe String
  }
  deriving (Eq, Show)

data BootstrapImageSeedAction
  = BootstrapImagePresent
  | BootstrapImageImportFromVerifiedArtifact
  | BootstrapImageVerifiedArtifactUnavailable
  deriving (Eq, Show)

data BootstrapImageSeedOutcome
  = BootstrapImageAlreadyPresent String
  | BootstrapImageSeededFromVerifiedArtifact String
  deriving (Eq, Show)

decideBootstrapImageSeed :: String -> BootstrapImageObservation -> BootstrapImageSeedAction
decideBootstrapImageSeed expected observation
  | observedContainerdIdentity observation == Just expected = BootstrapImagePresent
  | observedHostDockerIdentity observation == Just expected = BootstrapImageImportFromVerifiedArtifact
  | otherwise = BootstrapImageVerifiedArtifactUnavailable

seedBootstrapImages
  :: BootstrapImageSeedEffects
  -> [BootstrapImageSeedInput]
  -> IO (Either String [BootstrapImageSeedOutcome])
seedBootstrapImages effects = go []
 where
  go outcomes [] = pure (Right (reverse outcomes))
  go outcomes (image : remaining) = do
    result <- seedOne image
    case result of
      Left cause -> pure (Left cause)
      Right outcome -> go (outcome : outcomes) remaining
  seedOne image = do
    let reference = renderImageRef (seedImageReference image)
        expected = seedImageIdentity image
    containerd <- seedEffectContainerdIdentity effects reference
    docker <- case containerd == Just expected of
      True -> pure Nothing
      False -> seedEffectHostDockerIdentity effects reference
    case decideBootstrapImageSeed expected (BootstrapImageObservation containerd docker) of
      BootstrapImagePresent -> pure (Right (BootstrapImageAlreadyPresent reference))
      BootstrapImageVerifiedArtifactUnavailable ->
        pure
          ( Left
              ( "Bootstrap image "
                  <> reference
                  <> " does not match its retained source artifact in Docker. Rerun `prodbox cluster reconcile` to reload and verify that artifact."
              )
          )
      BootstrapImageImportFromVerifiedArtifact -> do
        imported <- seedEffectImportIntoContainerd effects reference
        case imported of
          Left cause ->
            pure
              ( Left
                  ("Bootstrap image " <> reference <> " could not be imported into RKE2 containerd: " <> take 512 cause)
              )
          Right () -> do
            observed <- seedEffectContainerdIdentity effects reference
            pure $ case observed == Just expected of
              True -> Right (BootstrapImageSeededFromVerifiedArtifact reference)
              False ->
                Left
                  ( "Bootstrap image "
                      <> reference
                      <> " was imported but RKE2 containerd did not report its expected config digest. Rerun `prodbox cluster reconcile` to retry the verified import."
                  )

renderBootstrapImageSeedOutcome :: BootstrapImageSeedOutcome -> String
renderBootstrapImageSeedOutcome outcome = case outcome of
  BootstrapImageAlreadyPresent reference -> "Bootstrap image has its verified source identity in RKE2 containerd: " <> reference
  BootstrapImageSeededFromVerifiedArtifact reference -> "Bootstrap image imported into RKE2 containerd from its verified source artifact: " <> reference
