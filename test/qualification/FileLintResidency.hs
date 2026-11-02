{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Run an actual operator's file-lint command under a fixed native memory
-- profile. Usage: FileLintResidency REPOSITORY OPERATOR. Type=oneshot makes a
-- signal a failure rather than a successful service termination.
module Main (main) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as Lazy
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (canonicalizePath)
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.Posix.Process (getProcessID)
import System.Posix.User (getEffectiveUserID)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [repository, operator] -> runProbe repository operator
    _ -> fail "usage: FileLintResidency REPOSITORY OPERATOR"

runProbe :: FilePath -> FilePath -> IO ()
runProbe repository operator = do
  root <- canonicalizePath repository
  executable <- canonicalizePath operator
  uid <- getEffectiveUserID
  pid <- getProcessID
  inherited <- getEnvironment
  started <- getMonotonicTimeNSec
  let runtimeDirectory = "/run/user/" <> show uid
      environment =
        ("XDG_RUNTIME_DIR", runtimeDirectory)
          : ("DBUS_SESSION_BUS_ADDRESS", "unix:path=" <> runtimeDirectory <> "/bus")
          : filter (keepVariable . fst) inherited
      unit = "prodbox-file-lint-residency-" <> show pid <> "-" <> show started
      command =
        ( proc
            "systemd-run"
            [ "--user"
            , "--quiet"
            , "--wait"
            , "--pipe"
            , "--collect"
            , "--service-type=oneshot"
            , "--expand-environment=no"
            , "--unit=" <> unit
            , "--working-directory=" <> root
            , "--property=MemoryMax=3221225472"
            , "--property=MemorySwapMax=0"
            , "--property=TasksMax=64"
            , "--property=OOMPolicy=kill"
            , "--property=OOMScoreAdjust=1000"
            , "--property=KillMode=control-group"
            , "--property=TimeoutStartSec=600s"
            , "--property=TimeoutStopSec=2s"
            , "--"
            , executable
            , "dev"
            , "lint"
            , "files"
            , "+RTS"
            , "-M1073741824"
            , "-s"
            , "-RTS"
            ]
        )
          { env = Just environment
          , cwd = Just root
          }
  (result, output, errors) <- readCreateProcessWithExitCode command ""
  finished <- getMonotonicTimeNSec
  Lazy.putStrLn
    ( encode
        ( object
            [ "operator" .= executable
            , "repository" .= root
            , "heap_limit_bytes" .= (1073741824 :: Integer)
            , "cgroup_memory_limit_bytes" .= (3221225472 :: Integer)
            , "swap_limit_bytes" .= (0 :: Integer)
            , "task_limit" .= (64 :: Int)
            , "elapsed_micros" .= ((finished - started) `div` 1000)
            , "exit_code" .= exitNumber result
            , "stdout" .= output
            , "stderr" .= errors
            ]
        )
    )
  exitWith result

keepVariable :: String -> Bool
keepVariable name = name `notElem` ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]

exitNumber :: ExitCode -> Int
exitNumber ExitSuccess = 0
exitNumber (ExitFailure value) = value
