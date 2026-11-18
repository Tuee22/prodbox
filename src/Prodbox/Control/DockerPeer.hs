{-# LANGUAGE ScopedTypeVariables #-}

-- | A held local Docker-socket connection and kernel-reported peer credentials.
-- A peer observation is not daemon authentication or permission for effects.
module Prodbox.Control.DockerPeer
  ( DockerPeer (..)
  , DockerPeerFailure (..)
  , DockerPeerResult (..)
  , withConnectedDockerPeer
  , observeDockerPeer
  ) where

import Control.Exception (IOException, bracket, mask, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Network.Socket qualified as Socket
import Prodbox.Control.DockerIdentity (DockerSocketIdentity, observeDockerSocketIdentity)
import System.FilePath (isAbsolute, normalise)
import System.Timeout (timeout)

data DockerPeer = DockerPeer !Integer !Integer !Integer !DockerSocketIdentity
  deriving (Eq, Show)

data DockerPeerFailure
  = DockerPeerInvalidInput
  | DockerPeerEndpointUnavailable
  | DockerPeerEndpointChanged
  | DockerPeerCredentialsUnavailable
  | DockerPeerIoFailure
  | DockerPeerTimedOut
  deriving (Eq, Show)

data DockerPeerResult value
  = DockerPeerRefused !DockerPeerFailure
  | DockerPeerCompleted !value
  | DockerPeerChanged !value
  | DockerPeerUnconfirmed !DockerPeerFailure
  | DockerPeerUnconfirmedAfter !value !DockerPeerFailure
  deriving (Eq, Show)

data CallbackProgress value = NotStarted | Started | Returned !value

-- | The callback borrows the connected socket and must not retain or close it.
-- A caller must independently establish admission, scope, durable intent and
-- settlement before sending effects. Peer credentials do not prove which
-- process handles HTTP requests, especially with socket activation or proxies.
withConnectedDockerPeer
  :: Int
  -> FilePath
  -> (Socket.Socket -> DockerPeer -> IO Bool -> IO value)
  -> IO (DockerPeerResult value)
withConnectedDockerPeer limit path action
  | limit <= 0
      || limit > 180000000
      || not (isAbsolute path)
      || normalise path /= path
      || '\0' `elem` path =
      pure (DockerPeerRefused DockerPeerInvalidInput)
  | otherwise = do
      progress <- newIORef NotStarted
      result <- timeout limit $ try $ Socket.withSocketsDo $ do
        first <- observeDockerSocketIdentity path
        case first of
          Nothing -> pure (Left DockerPeerEndpointUnavailable)
          Just identity ->
            bracket
              (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol)
              Socket.close
              (inspectConnection progress identity)
      current <- readIORef progress
      let interrupted failure = case current of
            NotStarted -> DockerPeerRefused failure
            Started -> DockerPeerUnconfirmed failure
            Returned value -> DockerPeerUnconfirmedAfter value failure
      pure $ case result of
        Nothing -> interrupted DockerPeerTimedOut
        Just (Left (_ :: IOException)) -> interrupted DockerPeerIoFailure
        Just (Right (Left failure)) -> interrupted failure
        Just (Right (Right (value, stable))) -> if stable then DockerPeerCompleted value else DockerPeerChanged value
 where
  inspectConnection progress identity connection = do
    Socket.connect connection (Socket.SockAddrUnix path)
    peer <- credentials connection identity
    second <- observeDockerSocketIdentity path
    case (peer, second) of
      (Nothing, _) -> pure (Left DockerPeerCredentialsUnavailable)
      (_, Nothing) -> pure (Left DockerPeerEndpointChanged)
      (Just actual, Just later)
        | identity /= later -> pure (Left DockerPeerEndpointChanged)
        | otherwise -> inspectStable progress identity connection actual
  inspectStable progress identity connection actual = do
    let recheck = do
          current <- observeDockerSocketIdentity path
          observed <- credentials connection identity
          pure (current == Just identity && observed == Just actual)
    ready <- recheck
    if not ready
      then pure (Left DockerPeerEndpointChanged)
      else do
        value <- mask $ \restore -> do
          writeIORef progress Started
          outcome <- restore (action connection actual recheck)
          writeIORef progress (Returned outcome)
          pure outcome
        final <- recheck
        pure (Right (value, final))

credentials :: Socket.Socket -> DockerSocketIdentity -> IO (Maybe DockerPeer)
credentials socket identity = do
  (pid, uid, gid) <- Socket.getPeerCredential socket
  pure $ case (pid, uid, gid) of
    (Just process, Just user, Just group)
      | process > 0 ->
          Just (DockerPeer (toInteger process) (toInteger user) (toInteger group) identity)
    _ -> Nothing

-- | Open a separate read-only connection and observe only its peer. The result
-- is not bound to any separate Docker CLI request or later connection.
observeDockerPeer :: FilePath -> IO (DockerPeerResult DockerPeer)
observeDockerPeer path = withConnectedDockerPeer 5000000 path (\_ peer _ -> pure peer)
