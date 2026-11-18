{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only Docker daemon and socket observations. These do not authenticate
-- the daemon or authorize any mutation.
module Prodbox.Control.DockerIdentity
  ( DockerSocketIdentity (..)
  , DockerDaemonObservation (..)
  , classifyDockerDaemon
  , parseDockerDaemonId
  , observeDockerDaemon
  , observeDockerSocketIdentity
  , readDocker
  ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (ExitSuccess))
import System.Posix.Files qualified as Files

data DockerSocketIdentity = DockerSocketIdentity !Integer !Integer !Integer !Integer
  deriving (Eq, Show)

data DockerDaemonObservation
  = DockerDaemonUnobservable
  | DockerDaemonChanged
  | DockerDaemonObserved !String !DockerSocketIdentity
  deriving (Eq, Show)

parseDockerDaemonId :: String -> Maybe String
parseDockerDaemonId input = case Aeson.eitherDecodeStrict' (BS.pack input) of
  Right value | validDaemonId value -> Just value
  _ -> Nothing

validDaemonId :: String -> Bool
validDaemonId value = not (null value) && length value <= 128 && all permitted value
 where
  permitted c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` (":-_." :: String)

-- | Compare repeated endpoint and daemon observations. This cannot rule out a
-- replacement between observations, a cloned daemon ID, or an untrusted daemon.
classifyDockerDaemon
  :: Maybe DockerSocketIdentity
  -> Maybe String
  -> Maybe DockerSocketIdentity
  -> Maybe String
  -> Maybe DockerSocketIdentity
  -> DockerDaemonObservation
classifyDockerDaemon first before middle after lastSocket = case (first, before, middle, after, lastSocket) of
  (Just a, Just firstId, Just b, Just secondId, Just c)
    | not (validDaemonId firstId && validDaemonId secondId) -> DockerDaemonUnobservable
    | a /= b || b /= c || firstId /= secondId -> DockerDaemonChanged
    | otherwise -> DockerDaemonObserved firstId a
  _ -> DockerDaemonUnobservable

observeDockerDaemon :: FilePath -> IO DockerDaemonObservation
observeDockerDaemon socket = do
  first <- observeDockerSocketIdentity socket
  case first of
    Nothing -> pure DockerDaemonUnobservable
    Just identity -> do
      before <- readDocker socket ["info", "--format", "{{json .ID}}"]
      middle <- observeDockerSocketIdentity socket
      case middle of
        Nothing -> pure DockerDaemonUnobservable
        Just current | current /= identity -> pure DockerDaemonChanged
        Just _ -> do
          after <- readDocker socket ["info", "--format", "{{json .ID}}"]
          lastSocket <- observeDockerSocketIdentity socket
          pure
            ( classifyDockerDaemon
                first
                (before >>= parseDockerDaemonId)
                middle
                (after >>= parseDockerDaemonId)
                lastSocket
            )

observeDockerSocketIdentity :: FilePath -> IO (Maybe DockerSocketIdentity)
observeDockerSocketIdentity path = do
  result <- try (Files.getSymbolicLinkStatus path)
  pure $ case result of
    Right status
      | Files.isSocket status ->
          Just
            ( DockerSocketIdentity
                (toInteger (Files.deviceID status))
                (toInteger (Files.fileID status))
                (toInteger (Files.fileOwner status))
                (toInteger (Files.fileMode status))
            )
    Left (_ :: IOException) -> Nothing
    _ -> Nothing

-- | Explicit selected socket and empty Docker configuration. Process failure or
-- bounded-output failure is unobservable rather than an absence finding.
readDocker :: FilePath -> [String] -> IO (Maybe String)
readDocker socket arguments = do
  result <-
    captureSubprocessBounded (BoundedSubprocessLimits 1 65536 8192 5000000) $
      Subprocess
        "/usr/bin/docker"
        (["--host", "unix://" ++ socket] ++ arguments)
        (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("DOCKER_CONFIG", "/nonexistent")])
        Nothing
  pure $ case result of
    Right output | processExitCode output == ExitSuccess -> Just (processStdout output)
    _ -> Nothing
