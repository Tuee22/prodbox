{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.47: isolate the host @docker@ CLI's Harbor auth from the operator's
-- system-wide Docker Hub login using the **ephemeral** @DOCKER_CONFIG@ pattern
-- the operator's @hostbootstrap@ project uses (@HostBootstrap.Registry@).
--
-- prodbox must push the images it builds to the in-cluster Harbor NodePort
-- (@127.0.0.1:30080@), and must pull public images (the mirror + base-image
-- builds) using the operator's fixed-token Docker Hub login to avoid rate
-- limits. With no @DOCKER_CONFIG@ a Harbor @docker login@ would write the
-- global @~\/.docker\/config.json@ — leaking Harbor creds and risking the
-- operator's Docker Hub state.
--
-- Instead, every host-docker flow runs inside 'withEphemeralDockerConfig',
-- which:
--
--   * discovers the host's @docker.io@ auth **read-only** from
--     @${DOCKER_CONFIG:-$HOME\/.docker}\/config.json@, projected to a minimal
--     @docker.io@-only set ('dockerHubAuthFromConfig'); absent ⇒ anonymous;
--   * materialises a **throwaway** @DOCKER_CONFIG@ holding that @docker.io@ auth
--     plus an **inline** Harbor entry (so NO @docker login@ runs at all), points
--     the process at it, and **scrubs it on exit** (the temp dir is removed and
--     the prior @DOCKER_CONFIG@ restored).
--
-- The host @~\/.docker\/config.json@ is only ever read; nothing persists in
-- @~\/prodbox@. The @docker.io@ discovery/projection is the seam that later
-- swaps onto @HostBootstrap.Registry@ at the planned hostbootstrap refactor.
module Prodbox.DockerConfig
  ( dockerHubAuthFromConfig
  , renderEphemeralDockerConfig
  , withEphemeralDockerConfig
  )
where

import Control.Exception (SomeException, bracket, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ContainerImage (harborRegistryEndpoint)
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

-- | PURE render of the ephemeral @config.json@: the optional host @docker.io@
-- auth (for public pulls) plus an INLINE Harbor @127.0.0.1:30080@ entry
-- (@base64 user:password@) so pushes authenticate WITHOUT a @docker login@.
-- No @credsStore@/@credHelpers@. Unit-testable.
renderEphemeralDockerConfig
  :: String -> String -> Maybe (KeyMap.KeyMap Aeson.Value) -> BL.ByteString
renderEphemeralDockerConfig harborUser harborPassword hubAuth =
  Aeson.encode (Aeson.Object (KeyMap.singleton "auths" (Aeson.Object combinedAuths)))
 where
  combinedAuths =
    KeyMap.insert
      (Key.fromString harborRegistryEndpoint)
      harborEntry
      (fromMaybe KeyMap.empty hubAuth)
  harborEntry = Aeson.Object (KeyMap.singleton "auth" (Aeson.String harborAuthBase64))
  harborAuthBase64 =
    TextEncoding.decodeUtf8 (Base64.encode (BS8.pack (harborUser ++ ":" ++ harborPassword)))

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
-- subprocess it spawns: a throwaway temp dir holding the host @docker.io@ auth
-- (read-only, discovered BEFORE the redirect) + the inline Harbor entry. On exit
-- the temp dir is scrubbed and the prior @DOCKER_CONFIG@ restored — whatever
-- happens. No @docker login@, nothing persisted. Mirrors
-- @HostBootstrap.Registry.withEphemeralDockerConfig@.
withEphemeralDockerConfig :: String -> String -> IO a -> IO a
withEphemeralDockerConfig harborUser harborPassword action = do
  hubAuth <- discoverHostDockerHubAuth
  withSystemTempDirectory "prodbox-docker-config" $ \dir -> do
    BL.writeFile
      (dir </> "config.json")
      (renderEphemeralDockerConfig harborUser harborPassword hubAuth)
    bracket
      ( do
          previous <- lookupEnv "DOCKER_CONFIG"
          setEnv "DOCKER_CONFIG" dir
          pure previous
      )
      (maybe (unsetEnv "DOCKER_CONFIG") (setEnv "DOCKER_CONFIG"))
      (const action)
