{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Native provider/lifetime controls. The fake owner runs only on an isolated bus.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, throwIO, try)
import Control.Monad (forM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Foreign (FunPtr, Ptr, alloca, nullPtr, peek, poke)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import Prodbox.Subprocess.SystemdProviderProfile qualified as Profile
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Posix.DynamicLinker (RTLDFlags (RTLD_NOW), dlclose, dlopen, dlsym)

data NativeBus

type Allocate = Ptr (Ptr NativeBus) -> IO CInt
type Address = Ptr NativeBus -> CString -> IO CInt
type Client = Ptr NativeBus -> CInt -> IO CInt
type State = Ptr NativeBus -> IO CInt
type Request = Ptr NativeBus -> CString -> Word64 -> IO CInt
type Release = Ptr NativeBus -> IO (Ptr NativeBus)
type Timeout = Ptr NativeBus -> Word64 -> IO CInt

foreign import ccall "dynamic" allocateCall :: FunPtr Allocate -> Allocate
foreign import ccall "dynamic" addressCall :: FunPtr Address -> Address
foreign import ccall "dynamic" clientCall :: FunPtr Client -> Client
foreign import ccall "dynamic" stateCall :: FunPtr State -> State
foreign import ccall "dynamic" requestCall :: FunPtr Request -> Request
foreign import ccall "dynamic" releaseCall :: FunPtr Release -> Release
foreign import ccall "dynamic" timeoutCall :: FunPtr Timeout -> Timeout

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
  arguments <- getArgs
  case arguments of
    ["supported", socket] -> supported socket
    ["unsupported", socket] -> unsupported socket
    ["fake-manager", socket, ready] -> fakeManager socket ready
    _ -> fail "expected supported/unsupported socket, or fake-manager socket ready"

supported :: FilePath -> IO ()
supported socket = do
  started <- getMonotonicTimeNSec
  let ending = started + 10000000000
  escaped <-
    right
      =<< right
      =<< Bus.withSystemdBus
        ending
        socket
        ( \connection -> lift $ preserveFailure $ do
            provider <- right =<< Provider.withQualifiedProvider connection pure
            assert "escaped provider remained live" . refused Provider.ProviderLeaseClosed
              =<< Provider.verifyQualifiedProvider provider
            assert "expired borrowed deadline was renewed" . refused Provider.ProviderExpired
              =<< Provider.withQualifiedProvider (Bus.systemdBusWithin 0 connection) pure
            right
              =<< Provider.withQualifiedProvider
                connection
                ( \held -> do
                    right =<< Provider.verifyQualifiedProvider held
                    assert "short verification deadline was renewed" . refused Provider.ProviderExpired
                      =<< Provider.verifyQualifiedProviderBefore 0 held
                    let binding = Provider.qualifiedProviderBinding held
                        bytes = Provider.encodeProviderBinding binding
                    assert
                      "binding roundtrip changed provenance"
                      (Provider.decodeProviderBinding bytes == Right binding)
                    forM_ [BS.empty, BS.init bytes, bytes <> "\NUL", BS.replicate 1025 0] $ \malformed ->
                      assert "malformed provider binding decoded" (isLeft (Provider.decodeProviderBinding malformed))
                    let reference = Profile.providerContractReference Profile.ProviderAmd64
                        (prefix, suffix) = BS.breakSubstring reference bytes
                    assert "native binding omitted the exact policy reference" (not (BS.null suffix))
                    unknown <- right (Provider.decodeProviderBinding (prefix <> BS.replicate 32 0 <> BS.drop 32 suffix))
                    assert "unknown reference relabelled as current" (unknown /= binding)
                    assert
                      "architecture missing from policy identity"
                      (reference /= Profile.providerContractReference Profile.ProviderArm64)
                    assert
                      "unknown provider platform admitted"
                      (Profile.selectProviderProfile "linux" "unknown" == Nothing)
                    putStrLn "PASS native images, strict binding, unknown reference and original deadline"
                )
            cancelledOwner <- newIORef Nothing
            cancelled <-
              try
                ( Provider.withQualifiedProvider
                    connection
                    ( \held -> do
                        writeIORef cancelledOwner (Just held)
                        throwIO ThreadKilled
                    )
                )
                :: IO (Either AsyncException (Either Provider.ProviderError ()))
            assert "provider swallowed cancellation" (cancelled == Left ThreadKilled)
            owner <- readIORef cancelledOwner >>= maybe (fail "cancelled callback never entered") pure
            assert "cancelled provider remained live" . refused Provider.ProviderLeaseClosed
              =<< Provider.verifyQualifiedProvider owner
            before <- length <$> listDirectory "/proc/self/fd"
            forM_ [1 .. 4 :: Int] $ \_ -> void (right =<< Provider.withQualifiedProvider connection (const (pure ())))
            after <- length <$> listDirectory "/proc/self/fd"
            assert "provider leaked descriptors" (before == after)
            putStrLn "PASS escaped/cancelled provider and descriptor retirement"
            pure connection
        )
  assert "closed connection reached its native pointer" . refused Bus.BusConnectionClosed
    =<< runExceptT (Bus.observeBusSender escaped)
  assert "borrowed view escaped connection closure" . refused Bus.BusConnectionClosed
    =<< runExceptT (Bus.observeBusSender (Bus.systemdBusWithin (ending + 1) escaped))
  assert "closed connection qualified a provider"
    . refused (Provider.ProviderBusRefused Bus.BusConnectionClosed)
    =<< Provider.withQualifiedProvider escaped pure
  putStrLn "PASS closed connection and borrowed view refuse before native use"

unsupported :: FilePath -> IO ()
unsupported socket = do
  ending <- (+ 2000000000) <$> getMonotonicTimeNSec
  right
    =<< right
    =<< Bus.withSystemdBus
      ending
      socket
      ( \connection -> lift $ preserveFailure $ do
          result <-
            Provider.withQualifiedProvider connection (const (fail "unreviewed manager entered callback"))
          assert
            "name/UID/PID metadata qualified unreviewed manager code"
            (refused (Provider.ProviderMappingRefused Profile.ManagerExecutable) result)
          putStrLn "PASS authenticated same-UID fake manager refused by executable mapping"
      )

-- This fixture claims the manager name but has no method dispatcher. A delayed
-- or asynchronous implementation cannot qualify through matching metadata.
fakeManager :: FilePath -> FilePath -> IO ()
fakeManager socket ready = bracket (dlopen "libsystemd.so.0" [RTLD_NOW]) dlclose $ \library -> do
  allocate <- allocateCall <$> dlsym library "sd_bus_new"
  address <- addressCall <$> dlsym library "sd_bus_set_address"
  client <- clientCall <$> dlsym library "sd_bus_set_bus_client"
  start <- stateCall <$> dlsym library "sd_bus_start"
  request <- requestCall <$> dlsym library "sd_bus_request_name"
  release <- releaseCall <$> dlsym library "sd_bus_unref"
  timeout <- timeoutCall <$> dlsym library "sd_bus_set_method_call_timeout"
  let checked action = action >>= \status -> assert "fake-manager native setup refused" (status >= 0)
      acquire = alloca $ \output -> do
        poke output nullPtr
        checked (allocate output)
        pointer <- peek output
        assert "fake-manager allocation absent" (pointer /= nullPtr)
        pure pointer
  bracket acquire (void . release) $ \bus -> do
    withCString ("unix:path=" <> socket) (checked . address bus)
    checked (client bus 1)
    checked (timeout bus 200000)
    checked (start bus)
    withCString "org.freedesktop.systemd1" (\name -> checked (request bus name 0))
    BS.writeFile ready "ready"
    threadDelay 15000000
