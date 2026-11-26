{-# LANGUAGE OverloadedStrings #-}

-- | Shared building blocks of the service deployment modules.
module Prodbox.Control.ServiceSupport
  ( ServiceStep (..)
  , run
  , runWithEnvironment
  , importImageStep
  , maxServiceAttempts
  , serviceAttemptNamespace
  , serviceAttemptRecordName
  , serviceOperationRecordNames
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Exit (ExitCode (..))
import System.IO (IOMode (ReadMode), withBinaryFile)

data ServiceStep = ServiceStep
  { serviceStepName :: !String
  , serviceStepOk :: !Bool
  , serviceStepDetail :: !String
  }
  deriving (Eq, Show)

maxServiceAttempts :: Int
maxServiceAttempts = 64

serviceAttemptNamespace :: String -> Int -> String
serviceAttemptNamespace operation index = "prodbox-service-" ++ operation ++ "-" ++ show index

serviceAttemptRecordName :: String -> Int -> String -> FilePath
serviceAttemptRecordName operation index record =
  "kind-services-" ++ operation ++ "-" ++ show index ++ "-" ++ record ++ ".json"

-- Move these records only after the exact old node and its dependants retire.
-- An incomplete service attempt remains evidence in the old operation history.
serviceOperationRecordNames :: String -> [FilePath]
serviceOperationRecordNames operation =
  ["kind-services-attempt.json", "kind-services-result.json"]
    ++ probeRecords "prodbox-services-gate"
    ++ concatMap attemptRecords [1 .. maxServiceAttempts]
 where
  attemptRecords index =
    map (serviceAttemptRecordName operation index) ["attempt", "result"]
      ++ probeRecords (serviceAttemptNamespace operation index)
  probeRecords namespace =
    [ "kind-network-probe-" ++ namespace ++ "-" ++ record ++ ".json"
    | record <- ["intent", "created", "removed"]
    ]

limits :: Int -> BoundedSubprocessLimits
limits seconds = BoundedSubprocessLimits (1024 * 1048576) (4 * 1048576) (256 * 1024) (seconds * 1000000)

run
  :: Int -> FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String))
run = runWithEnvironment [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]

-- | Like 'run' with an explicit environment, for tools such as the Docker
-- builder that need a writable home.
runWithEnvironment
  :: [(String, String)]
  -> Int
  -> FilePath
  -> [String]
  -> ByteString.ByteString
  -> IO (Either String (Int, String, String))
runWithEnvironment environment seconds program arguments input = do
  result <-
    captureSubprocessWithInputBounded
      (limits seconds)
      input
      (Subprocess program arguments (Just environment) Nothing)
  pure $ case result of
    Right output ->
      Right
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , processStdout output
        , processStderr output
        )
    Left failure -> Left (show failure)

importImageStep
  :: (Int -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String)))
  -> String
  -> FilePath
  -> String
  -> String
  -> IO ServiceStep
importImageStep docker name path reference node = do
  -- An image already registered under this exact reference is not imported
  -- again: re-importing under running Pods churns containerd and was observed
  -- to coincide with exec failures in the client Pod.
  present <-
    docker
      60
      ["exec", node, "ctr", "--namespace", "k8s.io", "images", "ls", "-q"]
      ByteString.empty
  bytes <-
    try (withBinaryFile path ReadMode ByteString.hGetContents)
      :: IO (Either IOException ByteString.ByteString)
  case (present, bytes) of
    (Right (0, out, _), _)
      | reference `elem` lines out ->
          pure (ServiceStep name True (reference ++ " is already registered in the node's containerd"))
    (_, Left failure) -> pure (ServiceStep name False ("archive unreadable: " ++ show failure))
    (_, Right archive) -> do
      imported <-
        docker
          300
          ["exec", "-i", node, "ctr", "--namespace", "k8s.io", "images", "import", "--all-platforms", "-"]
          archive
      listed <-
        docker
          60
          ["exec", node, "ctr", "--namespace", "k8s.io", "images", "ls", "-q"]
          ByteString.empty
      pure $ case (imported, listed) of
        (Right (0, _, _), Right (0, out, _))
          | reference `elem` lines out ->
              ServiceStep name True (reference ++ " registered in the node's containerd")
        (Right (code, _, err), _) | code /= 0 -> ServiceStep name False ("import exit " ++ show code ++ ": " ++ take 200 err)
        (Left failure, _) -> ServiceStep name False ("import not run: " ++ take 200 failure)
        _ -> ServiceStep name False (reference ++ " not listed in the node after import")
