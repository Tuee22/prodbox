-- | How the home cluster's pre-registry public images reach RKE2 containerd.
--
-- MinIO is the in-cluster registry's own storage backend, so the MinIO server
-- and the @mc@ client its two bootstrap Jobs run are the only images the home
-- reconcile cannot take from the registry: they are named by their public
-- source and left to the kubelet to pull. That worked while the source answered
-- an anonymous pull. It no longer does: @quay.io/minio/*@ now refuses one with
-- HTTP 401 (a token is issued, the manifest and tag-list requests are refused;
-- measured 2026-10-08), and the kubelet's own image garbage collection, which
-- prodbox runs with a 70 % high and 60 % low threshold, deletes an image no
-- container uses once the disk crosses 70 %. So a reconcile that left the two
-- images to the kubelet worked only for as long as both stayed cached in
-- containerd, and a rebuilt cluster, whose containerd is empty, could not start
-- MinIO at all.
--
-- The host Docker cache is the seed. Immediately before each consumer, every
-- image here is looked up in containerd; one containerd lacks is imported from
-- the Docker cache, and one the Docker cache also lacks is pulled into it first
-- (which is the old behaviour, moved off the kubelet, and the only step that
-- needs the network). Every failure names the image and the way to restore it.
--
-- The module is a leaf and holds the policy only: the observations and actions
-- are an 'BootstrapImageSeedEffects' record, so the algorithm runs over scripted
-- effects in the unit suite and over the Docker and containerd clients in
-- "Prodbox.CLI.Rke2".
module Prodbox.Infra.BootstrapImageSeed
  ( BootstrapImageSeedEffects (..)
  , BootstrapImageObservation (..)
  , BootstrapImageSeedAction (..)
  , BootstrapImageSeedOutcome (..)
  , bootstrapSeedImages
  , decideBootstrapImageSeed
  , seedBootstrapImages
  , renderBootstrapImageSeedOutcome
  , renderBootstrapImagePullFailure
  )
where

import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Prodbox.ContainerImage (ImageRef, publicMinioImage, publicMinioMcImage, renderImageRef)

-- | The images the home reconcile starts before any registry exists, from their
-- public names: the MinIO server and the client its bootstrap Jobs run. Every
-- consumer of either image names it through the same two constants, so this list
-- is the one place a third pre-registry image has to be added.
bootstrapSeedImages :: [ImageRef]
bootstrapSeedImages = [publicMinioImage, publicMinioMcImage]

-- | What the seeding reads and does. Each effect takes the rendered image
-- reference. The production record is built in "Prodbox.CLI.Rke2"; the unit
-- suite scripts one.
data BootstrapImageSeedEffects = BootstrapImageSeedEffects
  { seedEffectContainerdHolds :: String -> IO Bool
  -- ^ Whether RKE2 containerd lists the reference under that exact name.
  , seedEffectHostDockerHolds :: String -> IO Bool
  -- ^ Whether the host Docker cache holds the reference.
  , seedEffectPullIntoHostDocker :: String -> IO (Either String ())
  -- ^ Pull the reference from its public source into the host Docker cache.
  , seedEffectImportIntoContainerd :: String -> IO (Either String ())
  -- ^ Save the reference out of the Docker cache and import it into containerd.
  }

-- | What was observed about one image before anything was done.
data BootstrapImageObservation = BootstrapImageObservation
  { observedInContainerd :: Bool
  , observedInHostDocker :: Bool
  }
  deriving (Eq, Show)

-- | What one image needs.
data BootstrapImageSeedAction
  = -- | containerd already lists it: the kubelet can start a container from it
    -- without a pull, whatever digest it carries.
    BootstrapImagePresent
  | -- | containerd lacks it and the Docker cache holds it.
    BootstrapImageImportFromHostDocker
  | -- | neither holds it: the network is the only source left.
    BootstrapImagePullThenImport
  deriving (Eq, Show)

-- | What was done for one image, for the narration.
data BootstrapImageSeedOutcome
  = BootstrapImageAlreadyPresent String
  | BootstrapImageSeededFromHostDocker String
  | BootstrapImageSeededByPull String
  deriving (Eq, Show)

-- | The decision is by name, not by digest: the need is that the kubelet finds
-- the reference locally, and containerd listing it is exactly that. The Docker
-- cache is not consulted at all once containerd holds the image.
decideBootstrapImageSeed :: BootstrapImageObservation -> BootstrapImageSeedAction
decideBootstrapImageSeed observation
  | observedInContainerd observation = BootstrapImagePresent
  | observedInHostDocker observation = BootstrapImageImportFromHostDocker
  | otherwise = BootstrapImagePullThenImport

-- | Seed every image in order, stopping at the first failure. An import is read
-- back: a seed that reports success while containerd still does not list the
-- reference would leave the kubelet to pull it.
seedBootstrapImages
  :: BootstrapImageSeedEffects
  -> [ImageRef]
  -> IO (Either String [BootstrapImageSeedOutcome])
seedBootstrapImages effects = go []
 where
  go outcomes [] = pure (Right (reverse outcomes))
  go outcomes (image : remaining) = do
    seeded <- seedOne effects (renderImageRef image)
    case seeded of
      Left failure -> pure (Left failure)
      Right outcome -> go (outcome : outcomes) remaining

seedOne :: BootstrapImageSeedEffects -> String -> IO (Either String BootstrapImageSeedOutcome)
seedOne effects reference = do
  inContainerd <- seedEffectContainerdHolds effects reference
  inHostDocker <-
    if inContainerd
      then pure False
      else seedEffectHostDockerHolds effects reference
  case decideBootstrapImageSeed (BootstrapImageObservation inContainerd inHostDocker) of
    BootstrapImagePresent -> pure (Right (BootstrapImageAlreadyPresent reference))
    BootstrapImageImportFromHostDocker ->
      importAndRead effects reference (BootstrapImageSeededFromHostDocker reference)
    BootstrapImagePullThenImport -> pullThenImport effects reference

pullThenImport
  :: BootstrapImageSeedEffects -> String -> IO (Either String BootstrapImageSeedOutcome)
pullThenImport effects reference = do
  pulled <- seedEffectPullIntoHostDocker effects reference
  either
    (pure . Left . renderBootstrapImagePullFailure reference)
    (const (importAndRead effects reference (BootstrapImageSeededByPull reference)))
    pulled

-- | Import, then read containerd back for the exact name.
importAndRead
  :: BootstrapImageSeedEffects
  -> String
  -> BootstrapImageSeedOutcome
  -> IO (Either String BootstrapImageSeedOutcome)
importAndRead effects reference outcome = do
  imported <- seedEffectImportIntoContainerd effects reference
  either
    (pure . Left . importFailure)
    (const readBack)
    imported
 where
  importFailure detail =
    "Bootstrap image "
      <> reference
      <> " could not be imported into RKE2 containerd: "
      <> firstLine detail
  readBack = do
    listed <- seedEffectContainerdHolds effects reference
    pure $
      if listed
        then Right outcome
        else
          Left
            ( "Bootstrap image "
                <> reference
                <> " was imported but RKE2 containerd still does not list it under that name."
            )

renderBootstrapImageSeedOutcome :: BootstrapImageSeedOutcome -> String
renderBootstrapImageSeedOutcome outcome =
  case outcome of
    BootstrapImageAlreadyPresent reference ->
      "Bootstrap image already in RKE2 containerd: " <> reference
    BootstrapImageSeededFromHostDocker reference ->
      "Bootstrap image imported into RKE2 containerd from the host Docker cache: " <> reference
    BootstrapImageSeededByPull reference ->
      "Bootstrap image pulled into the host Docker cache and imported into RKE2 containerd: "
        <> reference

-- | The refusal when no store holds the image and the public pull failed. It
-- says what each store lacked, what the registry answered, and the two ways to
-- put the image where the next run will find it.
renderBootstrapImagePullFailure :: String -> String -> String
renderBootstrapImagePullFailure reference detail =
  "Bootstrap image "
    <> reference
    <> " is not available: RKE2 containerd does not list it, the host Docker cache does not hold it, and a public pull failed ("
    <> firstLine detail
    <> "). Restore it into the host Docker cache under this exact name, either with `docker load -i <archive>` or with `docker pull <mirror-reference>` followed by `docker tag <mirror-reference> "
    <> reference
    <> "`, then rerun the command."

-- | The first non-empty line, trimmed and bounded, so one multi-line registry
-- answer cannot bury the remedy that follows it.
firstLine :: String -> String
firstLine text =
  case filter (not . null) (map trim (lines text)) of
    line : _ -> bounded line
    [] -> "no detail"
 where
  trim = dropWhileEnd isSpace . dropWhile isSpace
  bounded line
    | length line > 240 = take 240 line <> "..."
    | otherwise = line
