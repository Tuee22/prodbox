{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Native file/descriptor controls. These grant no manager or Authority receipt.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, unless, void)
import Data.ByteString qualified as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.HostControllerInputs
import System.Directory
  ( createDirectory
  , listDirectory
  , makeAbsolute
  , removeFile
  , renameDirectory
  , renameFile
  )
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hSetFileSize, withBinaryFile)
import System.Posix.Files (createLink, createNamedPipe, createSymbolicLink, setFileMode)

right :: (Show error) => Either error value -> IO value
right = either (fail . show) pure

expectLeft :: (error -> Bool) -> Either error value -> IO ()
expectLeft predicate result = case result of
  Left cause | predicate cause -> pure ()
  _ -> fail "native input refusal did not match its exact boundary"

deadline :: IO Word64
deadline = (+ 5000000000) <$> getMonotonicTimeNSec

main :: IO ()
main = do
  [supplied] <- getArgs
  root <- makeAbsolute supplied
  setFileMode root 0o700
  forM_ controls $ \name -> do
    let directory = root </> name
        configuration = directory </> "config.dhall"
        request = directory </> "request"
    createDirectory directory
    setFileMode directory 0o700
    BS.writeFile configuration configBytes
    BS.writeFile request requestBytes
    mapM_ (`setFileMode` 0o600) [configuration, request]
    ending <- deadline
    exercise name directory configuration request ending
    putStrLn ("PASS " ++ name)
  putStrLn ("PASS all " ++ show (length controls) ++ " native input controls")

controls :: [String]
controls =
  [ "raw-read"
  , "matching-pin"
  , "wrong-pin"
  , "escaped"
  , "descriptor-release"
  , "in-place-change"
  , "same-bytes-replacement"
  , "parent-replacement"
  , "symlink"
  , "directory"
  , "fifo"
  , "permissions"
  , "hardlink"
  , "parent-permissions"
  , "oversized"
  , "exact-ceiling"
  , "expired"
  , "held-expiry"
  , "overlong-path"
  ]

configBytes, requestBytes :: BS.ByteString
configBytes = BS.pack [0, 255, 195, 169, 10]
requestBytes = BS.pack [232, 175, 183, 230, 177, 130, 10]

exercise :: String -> FilePath -> FilePath -> FilePath -> Word64 -> IO ()
exercise name directory configuration request ending = case name of
  "raw-read" ->
    void $
      right
        =<< withHostControllerInputs ending configuration request (checkBytes configBytes requestBytes)
  "matching-pin" ->
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \outer ->
              right
                =<< withPinnedHostControllerInputs
                  ending
                  (hostControllerInputFingerprint outer)
                  configuration
                  request
                  (checkBytes configBytes requestBytes)
          )
  "wrong-pin" ->
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \outer -> do
              let original = hostControllerInputFingerprintText (hostControllerInputFingerprint outer)
                  changed = (if take 1 original == "a" then "b" else "a") ++ drop 1 original
              fingerprint <-
                maybe (fail "valid changed fingerprint") pure (parseHostControllerInputFingerprint changed)
              entered <- newIORef False
              refused <-
                withPinnedHostControllerInputs
                  ending
                  fingerprint
                  configuration
                  request
                  (\_ -> writeIORef entered True)
              expectLeft (== ControllerInputFingerprintMismatch) refused
              reached <- readIORef entered
              unless (not reached) (fail "wrong fingerprint entered the decoder")
          )
  "escaped" -> do
    saved <- newIORef Nothing
    _ <-
      right
        =<< withHostControllerInputs ending configuration request (\inputs -> writeIORef saved (Just inputs))
    inputs <- readIORef saved >>= maybe (fail "missing escaped input lease") pure
    expectLeft (== ControllerInputsClosed) =<< verifyHostControllerInputs inputs
    expectLeft (== ControllerInputsClosed) =<< readHostControllerInputs inputs
  "descriptor-release" -> do
    _ <- right =<< withHostControllerInputs ending configuration request verifyHostControllerInputs
    before <- length <$> listDirectory "/proc/self/fd"
    forM_ [1 .. 128 :: Int] $ \_ -> do
      value <- right =<< withHostControllerInputs ending configuration request verifyHostControllerInputs
      right value
    after <- length <$> listDirectory "/proc/self/fd"
    unless (before == after) (fail "input scope leaked a descriptor")
  "in-place-change" ->
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \inputs -> do
              BS.writeFile request "different fixture bytes"
              expectLeft (== ControllerInputChanged ControllerRequest) =<< verifyHostControllerInputs inputs
              expectLeft (== ControllerInputChanged ControllerRequest) =<< readHostControllerInputs inputs
          )
  "same-bytes-replacement" ->
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \inputs -> do
              renameFile request (request ++ ".retained")
              BS.writeFile request requestBytes
              setFileMode request 0o600
              expectLeft (== ControllerInputChanged ControllerRequest) =<< verifyHostControllerInputs inputs
              refused <-
                withPinnedHostControllerInputs
                  ending
                  (hostControllerInputFingerprint inputs)
                  configuration
                  request
                  (const (fail "replacement entered decoder"))
              expectLeft (== ControllerInputFingerprintMismatch) refused
          )
  "parent-replacement" ->
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \inputs -> do
              renameDirectory directory (directory ++ ".retained")
              createDirectory directory
              setFileMode directory 0o700
              BS.writeFile configuration configBytes
              BS.writeFile request requestBytes
              mapM_ (`setFileMode` 0o600) [configuration, request]
              expectLeft (== ControllerInputChanged ControllerConfiguration) =<< verifyHostControllerInputs inputs
          )
  "symlink" -> do
    renameFile configuration (configuration ++ ".target")
    createSymbolicLink (configuration ++ ".target") configuration
    refused <-
      withHostControllerInputs ending configuration request (const (fail "symlink entered decoder"))
    expectLeft symlinkRefusal refused
  "directory" -> do
    removeFile request
    createDirectory request
    unsafeRequest
  "fifo" -> do
    removeFile request
    createNamedPipe request 0o600
    unsafeRequest
  "permissions" -> setFileMode configuration 0o640 >> unsafeConfiguration
  "hardlink" -> createLink configuration (configuration ++ ".link") >> unsafeConfiguration
  "parent-permissions" -> setFileMode directory 0o755 >> unsafeConfiguration
  "oversized" -> do
    withBinaryFile configuration WriteMode (\file -> hSetFileSize file (1024 * 1024 + 1))
    refused <-
      withHostControllerInputs
        ending
        configuration
        request
        (const (fail "oversized input entered decoder"))
    expectLeft (== ControllerInputTooLarge ControllerConfiguration) refused
  "exact-ceiling" -> do
    mapM_
      (\path -> withBinaryFile path WriteMode (\file -> hSetFileSize file (1024 * 1024)))
      [configuration, request]
    void $
      right
        =<< withHostControllerInputs
          ending
          configuration
          request
          ( \inputs -> do
              bytes <- right =<< readHostControllerInputs inputs
              forM_ [hostControllerConfigurationBytes bytes, hostControllerRequestBytes bytes] $ \value ->
                unless
                  (BS.length value == 1024 * 1024 && BS.all (== 0) value)
                  (fail "exact serialized input ceiling changed")
              again <- right =<< readHostControllerInputs inputs
              unless
                (hostControllerConfigurationBytes again == hostControllerConfigurationBytes bytes)
                (fail "same-descriptor read did not reset offset")
          )
  "expired" -> do
    now <- getMonotonicTimeNSec
    refused <-
      withHostControllerInputs now configuration request (const (fail "expired input entered decoder"))
    expectLeft (== ControllerInputsExpired) refused
  "held-expiry" -> do
    short <- (+ 30000000) <$> getMonotonicTimeNSec
    void $
      right
        =<< withHostControllerInputs
          short
          configuration
          request
          ( \inputs -> do
              threadDelay 40000
              expectLeft (== ControllerInputsExpired) =<< verifyHostControllerInputs inputs
              expectLeft (== ControllerInputsExpired) =<< readHostControllerInputs inputs
          )
  "overlong-path" -> do
    let path = replicate 4097 '/' ++ error "over-limit path tail evaluated"
    refused <-
      withHostControllerInputs ending path request (const (fail "over-limit path entered decoder"))
    expectLeft (== ControllerInputUnsafe ControllerConfiguration) refused
  _ -> fail "unregistered native input control"
 where
  unsafeRequest = do
    refused <-
      withHostControllerInputs
        ending
        configuration
        request
        (const (fail "unsafe request entered decoder"))
    expectLeft (== ControllerInputUnsafe ControllerRequest) refused
  unsafeConfiguration = do
    refused <-
      withHostControllerInputs
        ending
        configuration
        request
        (const (fail "unsafe configuration entered decoder"))
    expectLeft (== ControllerInputUnsafe ControllerConfiguration) refused
  symlinkRefusal cause = case cause of
    ControllerInputIoRefused ControllerConfiguration _ _ -> True
    _ -> False

checkBytes :: BS.ByteString -> BS.ByteString -> HostControllerInputs -> IO ()
checkBytes configuration request inputs = do
  bytes <- right =<< readHostControllerInputs inputs
  unless
    ( hostControllerConfigurationBytes bytes == configuration
        && hostControllerRequestBytes bytes == request
    )
    (fail "raw input bytes changed")
  right =<< verifyHostControllerInputs inputs
