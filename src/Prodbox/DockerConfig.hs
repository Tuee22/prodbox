{-# LANGUAGE OverloadedStrings #-}

-- | Isolate the host @docker@ CLI's pull auth from the operator's system-wide
-- Docker Hub login using the **ephemeral** @DOCKER_CONFIG@ pattern the
-- operator's @hostbootstrap@ project uses (@HostBootstrap.Registry@).
--
-- prodbox pushes the images it builds to the in-cluster registry NodePort
-- (@127.0.0.1:30080@) and pulls public images (the mirror + base-image builds)
-- using the operator's fixed-token Docker Hub login to avoid rate limits. The
-- in-cluster registry is the single-binary CNCF @distribution@ (@registry:2@)
-- served **anonymous over HTTP** on a @localhost@ NodePort (insecure-by-default
-- in Docker), so pushes need **no credentials, no @docker login@, and no TLS** —
-- the ephemeral config exists purely to carry the read-only @docker.io@ pull
-- auth without touching the operator's global @~\/.docker\/config.json@.
--
-- Every host-docker flow runs inside 'withEphemeralDockerConfig', which:
--
--   * discovers the host's @docker.io@ auth **read-only** from
--     @${DOCKER_CONFIG:-$HOME\/.docker}\/config.json@, projected to a minimal
--     @docker.io@-only set ('dockerHubAuthFromConfig'); absent ⇒ anonymous;
--   * materialises a **throwaway** @DOCKER_CONFIG@ holding just that @docker.io@
--     auth (no registry credential at all), points the process at it, and
--     **scrubs it on exit** (the temp dir is removed and the prior
--     @DOCKER_CONFIG@ restored).
--
-- The host @~\/.docker\/config.json@ is only ever read; nothing persists in
-- @~\/prodbox@. The @docker.io@ discovery/projection is the seam that later
-- swaps onto @HostBootstrap.Registry@ at the planned hostbootstrap refactor.
module Prodbox.DockerConfig
  ( dockerHubAuthFromConfig
  , dockerLinuxFrameDispatch
  , hostFrameDockerSupported
  , renderEphemeralDockerConfig
  , withEphemeralDockerConfig
  )
where

import Control.Exception (SomeException, bracket, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Prodbox.Host.Lift
  ( HostDispatch
  , SelfRef
  , clusterFrame
  , foldHostLift
  )
import Prodbox.Host.Substrate
  ( HostSubstrate (..)
  , detectHostSubstrate
  , renderHostSubstrate
  )
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | PURE @docker.io@-only projection of a Docker @config.json@: parse the bytes,
-- keep only the @auths@ entries whose registry key mentions @docker.io@ (so a
-- local Harbor / other private registries are excluded), and return them iff
-- non-empty. Mirrors @HostBootstrap.Registry.dockerHubAuthFromConfig@.
-- Unit-testable.
dockerHubAuthFromConfig :: BL.ByteString -> Maybe (KeyMap.KeyMap Aeson.Value)
dockerHubAuthFromConfig raw =
  case Aeson.decode raw of
    Just (Aeson.Object top) ->
      case KeyMap.lookup "auths" top of
        Just (Aeson.Object auths) ->
          let hub = KeyMap.filterWithKey (\key _ -> isDockerHubKey key) auths
           in if KeyMap.null hub then Nothing else Just hub
        _ -> Nothing
    _ -> Nothing
 where
  isDockerHubKey key = "docker.io" `isInfixOf` Key.toString key

-- | PURE render of the ephemeral @config.json@: just the optional host
-- @docker.io@ auth (for public pulls). The in-cluster @registry:2@ NodePort is
-- anonymous over HTTP, so no registry credential is written — pushes need no
-- @docker login@. No @credsStore@/@credHelpers@. Unit-testable.
renderEphemeralDockerConfig
  :: Maybe (KeyMap.KeyMap Aeson.Value) -> BL.ByteString
renderEphemeralDockerConfig hubAuth =
  Aeson.encode (Aeson.Object (KeyMap.singleton "auths" (Aeson.Object hubAuths)))
 where
  hubAuths = fromMaybe KeyMap.empty hubAuth

dockerLinuxFrameDispatch :: SelfRef -> HostSubstrate -> [String] -> HostDispatch
dockerLinuxFrameDispatch self substrate =
  foldHostLift self (clusterFrame substrate)

-- | Discover the host's @docker.io@ auth read-only from
-- @${DOCKER_CONFIG:-$HOME\/.docker}\/config.json@. Any failure (no file, no
-- @docker.io@ entry, unreadable) yields 'Nothing' and callers degrade to
-- anonymous pulls. The ONLY place the host credential is read.
discoverHostDockerHubAuth :: IO (Maybe (KeyMap.KeyMap Aeson.Value))
discoverHostDockerHubAuth = do
  path <- hostDockerConfigPath
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      readResult <- try (BL.readFile path) :: IO (Either SomeException BL.ByteString)
      pure (either (const Nothing) dockerHubAuthFromConfig readResult)

hostDockerConfigPath :: IO FilePath
hostDockerConfigPath = do
  override <- lookupEnv "DOCKER_CONFIG"
  case override of
    Just dir | not (null dir) -> pure (dir </> "config.json")
    _ -> do
      home <- getHomeDirectory
      pure (home </> ".docker" </> "config.json")

-- | Run an action with an ephemeral @DOCKER_CONFIG@ active for every @docker@
-- subprocess it spawns: a throwaway temp dir holding just the host @docker.io@
-- auth (read-only, discovered BEFORE the redirect). On exit the temp dir is
-- scrubbed and the prior @DOCKER_CONFIG@ restored — whatever happens. No
-- @docker login@, nothing persisted, no registry credential (the in-cluster
-- @registry:2@ NodePort is anonymous). Mirrors
-- @HostBootstrap.Registry.withEphemeralDockerConfig@.
withEphemeralDockerConfig :: IO a -> IO a
withEphemeralDockerConfig action = do
  substrateResult <- detectHostSubstrate
  case substrateResult >>= hostFrameDockerSupported of
    Left err -> ioError (userError err)
    Right () -> withEphemeralDockerConfigUnchecked action

hostFrameDockerSupported :: HostSubstrate -> Either String ()
hostFrameDockerSupported substrate =
  case substrate of
    LinuxCpu -> Right ()
    LinuxGpu -> Right ()
    _ ->
      Left
        ( "host-frame docker is unavailable on "
            ++ renderHostSubstrate substrate
            ++ "; descend into the Linux lift frame first"
        )

withEphemeralDockerConfigUnchecked :: IO a -> IO a
withEphemeralDockerConfigUnchecked action = do
  hubAuth <- discoverHostDockerHubAuth
  withSystemTempDirectory "prodbox-docker-config" $ \dir -> do
    BL.writeFile
      (dir </> "config.json")
      (renderEphemeralDockerConfig hubAuth)
    bracket
      ( do
          previous <- lookupEnv "DOCKER_CONFIG"
          setEnv "DOCKER_CONFIG" dir
          pure previous
      )
      (maybe (unsetEnv "DOCKER_CONFIG") (setEnv "DOCKER_CONFIG"))
      (const action)
