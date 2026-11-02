{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Compile with the exact package-private transport source listed explicitly.
-- Socket fixtures and their independent clock/closure observations are external.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Subprocess.SystemdBus
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.Timeout (timeout)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["identity-guards"] -> identityGuards
    [mode, socket] -> run mode socket
    _ -> fail "expected qualification mode and owned socket path"

run :: String -> FilePath -> IO ()
run mode socket = do
  started <- getMonotonicTimeNSec
  entered <- newIORef False
  peer <- newIORef Nothing
  let cancellation = mode `elem` ["cancel", "cancel-reply"]
      duration = if cancellation then 500000000 else 200000000
      deadline = if mode == "expired" then started - 1 else started + duration
      action connection = do
        lift (writeIORef entered True >> writeIORef peer (managerPeerIdentity connection))
        unless
          (systemdBusDeadline (systemdBusWithin (deadline + 1000000000) connection) == deadline)
          (throwE BusInputRefused)
        case mode of
          "continuation-refusal" -> throwE BusInputRefused
          "continuation-io" -> lift (ioError (userError "private fixture detail must not escape"))
          "late-continuation" -> lift (threadDelay 250000) >> pure "late"
          "nested-budget" -> do
            first <-
              lift
                ( runExceptT
                    ( callManager
                        (systemdBusWithin (started + 75000000) connection)
                        GetUnit
                        (\message -> appendString message "app.slice")
                        (`readString` 'o')
                    )
                )
            unless (first == Left (BusDeadlineReached BusReply)) (throwE BusMalformedReply)
            second <-
              lift
                ( runExceptT
                    ( callManager
                        connection
                        GetUnit
                        (\message -> appendString message "prodbox-native-qualification-absent.scope")
                        (`readString` 'o')
                    )
                )
            case second of
              Left (BusMethodRefused 2) -> pure "recovered-missing"
              Left cause -> throwE cause
              Right _ -> throwE BusMalformedReply
          _ ->
            callManager
              connection
              GetUnit
              ( \message ->
                  appendString
                    message
                    (if mode == "missing" then "prodbox-native-qualification-absent.scope" else "app.slice")
              )
              (`readString` 'o')
  result <-
    timeout (if cancellation then 20000 else 1000000) (withSystemdBus deadline socket action)
  stopped <- getMonotonicTimeNSec
  callbackEntered <- readIORef entered
  observedPeer <- readIORef peer
  let elapsed = (stopped - started) `div` 1000
      expected = case mode of
        "lookup" -> case result of
          Just (Right path) -> path == "/org/freedesktop/systemd1/unit/app_2eslice"
          _ -> False
        "missing" -> result == Just (Left (BusMethodRefused 2))
        "authentication-stall" -> result == Just (Left (BusDeadlineReached BusAuthenticate)) && elapsed < 300000
        "reply-stall" -> result == Just (Left (BusDeadlineReached BusReply)) && elapsed < 300000
        "cancel" -> result == Nothing && elapsed < 100000
        "cancel-reply" -> result == Nothing && elapsed < 100000
        "expired" -> result == Just (Left (BusDeadlineReached BusConnect)) && elapsed < 50000
        "invalid" -> result == Just (Left BusSocketRefused)
        "continuation-refusal" -> result == Just (Left BusInputRefused)
        "continuation-io" -> result == Just (Left BusIoRefused)
        "late-continuation" -> result == Just (Left (BusDeadlineReached BusRelease))
        "peer-rejected" -> result == Just (Left BusManagerIdentityRefused) && not callbackEntered
        "nested-budget" -> result == Just (Right "recovered-missing") && elapsed >= 75000 && elapsed < 250000
        _ -> False
  Lazy.putStrLn
    ( encode
        ( object
            [ "mode" .= mode
            , "elapsed_micros" .= elapsed
            , "result" .= show result
            , "passed" .= expected
            , "callback_entered" .= callbackEntered
            , "manager_peer" .= observedPeer
            , "production_owned_process_repair" .= False
            ]
        )
    )
  unless expected exitFailure

identityGuards :: IO ()
identityGuards = do
  started <- getMonotonicTimeNSec
  identifier <-
    maybe (fail "invalid fixed identity fixture") pure (invocationIdFromBytes (Bytes.pack [1 .. 16]))
  letter <-
    maybe (fail "invalid letter fixture") pure (invocationIdFromBytes (Bytes.pack (171 : [1 .. 15])))
  let prefix = "/org/freedesktop/systemd1/unit/"
      digitPath = prefix <> "_30102030405060708090a0b0c0d0e0f10"
      letterPath = prefix <> "ab0102030405060708090a0b0c0d0e0f"
      refuses path = invocationPathFromReply identifier path == Nothing
      rows :: [(String, Bool)]
      rows =
        [ ("nil identifier", invocationIdFromBytes (Bytes.replicate 16 0) == Nothing)
        ,
          ( "nil observation is not an identity"
          , invocationObservationFromBytes (Bytes.replicate 16 0) == Just InvocationAbsent
          )
        ,
          ( "present observation retains identity"
          , invocationObservationFromBytes (Bytes.pack [1 .. 16]) == Just (InvocationPresent identifier)
          )
        , ("short observation refuses", invocationObservationFromBytes (Bytes.replicate 15 0) == Nothing)
        , ("long observation refuses", invocationObservationFromBytes (Bytes.replicate 17 0) == Nothing)
        , ("empty observation refuses", invocationObservationFromBytes Bytes.empty == Nothing)
        , ("short identifier", invocationIdFromBytes (Bytes.replicate 15 1) == Nothing)
        , ("long identifier", invocationIdFromBytes (Bytes.replicate 17 1) == Nothing)
        , ("empty identifier", invocationIdFromBytes Bytes.empty == Nothing)
        ,
          ( "escaped leading digit"
          , fmap invocationPathText (invocationPathFromReply identifier digitPath) == Just digitPath
          )
        ,
          ( "letter alias"
          , fmap invocationPathText (invocationPathFromReply letter letterPath) == Just letterPath
          )
        ,
          ( "retains exact identifier"
          , fmap invocationPathId (invocationPathFromReply identifier digitPath) == Just identifier
          )
        , ("name path", refuses (prefix <> "fixture_2escope"))
        , ("foreign identifier", invocationPathFromReply letter digitPath == Nothing)
        , ("nil alias", refuses (prefix <> replicate 32 '0'))
        , ("wrong prefix", refuses ("/another/unit/" <> "0102030405060708090a0b0c0d0e0f10"))
        , ("truncated escape", refuses (prefix <> "_3"))
        , ("invalid hex", refuses (prefix <> replicate 32 'g'))
        , ("trailing component", refuses (digitPath <> "/other"))
        , ("empty label", refuses prefix)
        , ("escaped null", refuses (prefix <> "_00" <> replicate 31 '0'))
        , ("infinite label refuses within prefix bound", refuses (prefix <> repeat 'a'))
        ]
      passed = all snd rows
  unless passed (fail (show (filter (not . snd) rows)))
  finished <- getMonotonicTimeNSec
  Lazy.putStrLn
    ( encode
        ( object
            [ "mode" .= ("identity-guards" :: String)
            , "count" .= length rows
            , "passed" .= passed
            , "elapsed_micros" .= ((finished - started) `div` 1000)
            ]
        )
    )
