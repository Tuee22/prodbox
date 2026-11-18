{-# LANGUAGE ScopedTypeVariables #-}

-- | The Docker bridge client used when the operator is installed as
-- "docker" in a kind worker's private bridge directory. The lifecycle owner
-- must confine and settle the worker and authenticate the server separately.
module Prodbox.Control.KindDockerClient (runKindDockerClient, validKindDockerBridgePath, prepareKindDockerRequest) where

import Control.Exception (IOException, bracket, try)
import Data.ByteString qualified as ByteString
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerEndpointResult (KindDockerEndpointObserved)
  , exchangeBoundKindDockerRequest
  )
import Prodbox.Control.KindDockerReadGate (KindDockerReply (..))
import Prodbox.Control.KindDockerReadProtocol (KindDockerClientFailure, KindDockerRequest (..))
import Prodbox.Control.SealedTool (isSealedToolDescriptor)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName)
import System.IO qualified as IO
import System.Posix.Files (deviceID, fileID, getFdStatus, getSymbolicLinkStatus, isDirectory)
import System.Posix.IO qualified as Posix
import System.Timeout (timeout)

-- | A changed endpoint is an unconfirmed exchange and must never be rendered
-- as a successful response. Docker and kubeconfig settings do not select it.
runKindDockerClient :: [String] -> IO ExitCode
runKindDockerClient arguments = do
  let flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  result <-
    try $ do
      directory <- clientDirectory
      case directory of
        Nothing -> pure Nothing
        Just selected -> bracket (Posix.openFd selected Posix.ReadOnly flags) Posix.closeFd $ \root -> do
          initial <- getFdStatus root
          let stable = do
                held <- getFdStatus root
                named <- getSymbolicLinkStatus selected
                pure (isDirectory held && isDirectory named && same initial held && same held named)
          request <- prepareKindDockerRequest IO.stdin arguments
          case request of
            Nothing -> pure Nothing
            Just bounded -> Just <$> exchangeBoundKindDockerRequest 5000000 root stable bounded
  case ( result
           :: Either
                IOException
                (Maybe (KindDockerEndpointResult (Either KindDockerClientFailure KindDockerReply)))
       ) of
    Right (Just (KindDockerEndpointObserved (Right reply))) -> do
      ByteString.hPut IO.stdout (kindDockerReplyStdout reply)
      ByteString.hPut IO.stderr (kindDockerReplyStderr reply)
      pure (if kindDockerReplyExit reply == 0 then ExitSuccess else ExitFailure 1)
    _ -> IO.hPutStrLn IO.stderr "Error: kind Docker bridge unavailable" >> pure (ExitFailure 1)
 where
  same left right = deviceID left == deviceID right && fileID left == fileID right

-- Only the exact observed copy request consumes stdin. The bytes remain
-- transient and no input is dispatched on overflow or timeout.
prepareKindDockerRequest :: IO.Handle -> [String] -> IO (Maybe KindDockerRequest)
prepareKindDockerRequest input arguments = case arguments of
  ["exec", "--privileged", "-i", _, "cp", "/dev/stdin", "/kind/kubeadm.conf"] -> do
    received <- timeout 5000000 (ByteString.hGet input 65537)
    pure $ case received of
      Just bytes
        | not (ByteString.null bytes) && ByteString.length bytes <= 65536 ->
            Just (KindDockerRequest arguments bytes)
      _ -> Nothing
  _ -> pure (Just (KindDockerRequest arguments ByteString.empty))

-- The explicit bridge path is only used by a fully sealed memory snapshot of
-- the operator. It is an endpoint selector, not proof of worker or server
-- identity; the lifecycle owner must establish both independently.
clientDirectory :: IO (Maybe FilePath)
clientDirectory = do
  executable <- getExecutablePath
  if isAbsolute executable && normalise executable == executable && takeFileName executable == "docker"
    then pure (Just (takeDirectory executable))
    else
      if executable == "/memfd:prodbox-kind-tool (deleted)"
        then do
          sealed <-
            bracket
              (Posix.openFd "/proc/self/exe" Posix.ReadOnly Posix.defaultFileFlags)
              Posix.closeFd
              isSealedToolDescriptor
          selected <- lookupEnv "PRODBOX_KIND_BRIDGE"
          pure $ case selected of
            Just directory | sealed && validKindDockerBridgePath directory -> Just directory
            _ -> Nothing
        else pure Nothing

validKindDockerBridgePath :: FilePath -> Bool
validKindDockerBridgePath directory =
  length (take 4097 directory) <= 4096
    && isAbsolute directory
    && normalise directory == directory
    && ".." `notElem` splitDirectories directory
    && ':' `notElem` directory
    && '\0' `notElem` directory
