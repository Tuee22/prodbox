{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Read-only native retirement controls over exact historical fixture records.
module Main (main) where

import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , bracket
  , bracket_
  , throwIO
  , try
  )
import Control.Monad (forM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Directory (createDirectory, listDirectory, removeDirectory, removeFile)
import System.Environment (getArgs)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Posix.IO qualified as Posix
import System.Posix.User (getEffectiveUserID)

right :: (Show failure) => Either failure value -> IO value
right = either (fail . show) pure

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail label)

refused :: (Eq failure) => failure -> Either failure value -> Bool
refused expected result = case result of
  Left actual -> actual == expected
  Right _ -> False

preserveFailure :: IO value -> IO (Either SomeException value)
preserveFailure = try

main :: IO ()
main = do
  [request, text, foreignRequest, foreignText] <- getArgs
  key <- maybe (fail "key") pure (Identity.hostExecutionKeyFromText text)
  foreignKey <- maybe (fail "foreign key") pure (Identity.hostExecutionKeyFromText foreignText)
  ending <- (+ 10000000000) <$> getMonotonicTimeNSec
  record <- right =<< Inputs.readHostControllerSubmission ending request key
  foreignRecord <- right =<< Inputs.readHostControllerSubmission ending foreignRequest foreignKey
  uid <- getEffectiveUserID
  right
    =<< right
    =<< Bus.withSystemdBus
      ending
      ("/run/user/" <> show uid <> "/bus")
      ( \connection -> lift $ preserveFailure $ do
          let acquire = Retirement.withHostOperationRetirement connection record
              workspace =
                "/run/user/"
                  <> show uid
                  <> "/"
                  <> Family.hostOperationFieldRuntimeDirectory
                    (Family.hostControllerSubmissionField record)
          owner <-
            right
              =<< acquire
                ( \held -> do
                    assert
                      "retirement did not bind original record"
                      (Retirement.hostOperationRetirementMatches held record)
                    assert
                      "retirement authorized another record"
                      (not (Retirement.hostOperationRetirementMatches held foreignRecord))
                    right =<< Retirement.verifyHostOperationRetirement held
                    assert "shortened retirement deadline renewed" . refused Retirement.RetirementExpired
                      =<< Retirement.verifyHostOperationRetirementBefore 0 held
                    pure held
                )
          assert "escaped retirement owner remained live" . refused Retirement.RetirementClosed
            =<< Retirement.verifyHostOperationRetirement owner
          assert "expired native retirement attempt renewed"
            . refused
              ( Retirement.RetirementProcessingRefused
                  (Family.HostOperationProviderRefused Provider.ProviderExpired)
              )
            =<< Retirement.withHostOperationRetirement (Bus.systemdBusWithin 0 connection) record pure
          putStrLn "PASS qualified historical retirement, exact record and original deadline"
          let expectWorkspaceRefusal = do
                result <- acquire (const (fail "present workspace entered callback"))
                assert
                  "present workspace acquired retirement"
                  (refused Retirement.RetirementWorkspacePresent result)
              expectUnobservable = do
                result <- acquire (const (fail "invalid workspace entered callback"))
                assert
                  "invalid workspace became absence"
                  (case result of Left (Retirement.RetirementIoRefused _ _) -> True; _ -> False)
          bracket_
            (createDirectory workspace >> setFileMode workspace 0o700)
            (removeDirectory workspace)
            expectWorkspaceRefusal
          bracket_ (BS.writeFile workspace "fixture") (removeFile workspace) expectUnobservable
          bracket_
            (createSymbolicLink (workspace <> "-missing-target") workspace)
            (removeFile workspace)
            expectUnobservable
          putStrLn "PASS present, non-directory and dangling-link workspace refusal"
          cancelledOwner <- newIORef Nothing
          cancelled <-
            try (acquire (\held -> writeIORef cancelledOwner (Just held) >> throwIO ThreadKilled))
              :: IO (Either AsyncException (Either Retirement.RetirementError ()))
          assert "retirement swallowed cancellation" (cancelled == Left ThreadKilled)
          cancelledLease <- readIORef cancelledOwner >>= maybe (fail "cancelled owner absent") pure
          assert "cancelled retirement owner remained live" . refused Retirement.RetirementClosed
            =<< Retirement.verifyHostOperationRetirement cancelledLease
          before <- length <$> listDirectory "/proc/self/fd"
          forM_ [1 .. 4 :: Int] $ \_ -> void (right =<< acquire (const (pure ())))
          after <- length <$> listDirectory "/proc/self/fd"
          assert "retirement owner leaked descriptors" (before == after)
          bracket
            ( Posix.openFd
                "/"
                Posix.ReadOnly
                Posix.defaultFileFlags {Posix.directory = True, Posix.cloexec = True}
            )
            Posix.closeFd
            $ \fd ->
              assert "non-cgroup anchor was accepted" . refused Kernel.KernelScopeFilesystemRefused
                =<< Kernel.verifyCgroupDescriptorsBefore ending [fd]
          putStrLn "PASS cancellation, descriptor retirement and cgroup mount refusal"
      )
