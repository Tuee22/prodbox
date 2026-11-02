{-# LANGUAGE ImportQualifiedPost #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, unless)
import Data.Int (Int64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.ControlPlane.RpcAdmissionBirthClock
import Prodbox.ControlPlane.RpcAdmissionBirthNative (rpcBirthSystemTime)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)

main :: IO ()
main = do
  authority <- rpcBirthSystemTime
  started <- getMonotonicTimeNSec
  let deadline = authorityTimeFromMicros (authorityTimeMicros authority + 2500000)
      outer = started + 3000000000
      work = started + 2000000000
      delayed = do
        value <- rpcBirthSystemTime
        threadDelay 1000000
        pure value
      readers = RpcBirthHostClockReaders getMonotonicTimeNSec delayed
  result <- observeRpcBirthHostWindowWith readers (work, outer) deadline
  closingAuthority <- rpcBirthSystemTime
  closingMonotonic <- getMonotonicTimeNSec
  case result of
    Left RpcBirthHostClockOutsideAuthorityBound ->
      putStrLn
        "PASS real delayed UTC read cannot admit an original host window outside its Authority bound"
    Left cause -> fail ("unexpected delayed-read refusal: " ++ show cause)
    Right _ -> do
      let actualAuthorityRemaining = toInteger (authorityTimeMicros deadline) - toInteger (authorityTimeMicros closingAuthority)
          actualHostRemaining = toInteger outer - toInteger closingMonotonic
      unless
        (actualAuthorityRemaining > 0 && actualHostRemaining > actualAuthorityRemaining * 1000)
        (fail "delayed-read recording did not isolate the unsafe admission")
      fail "accepted original host window beyond independently observed Authority remainder"
  now <- rpcBirthSystemTime
  mono <- getMonotonicTimeNSec
  positive <-
    observeRpcBirthHostWindow
      (mono + 1000000000, mono + 2000000000)
      (authorityTimeFromMicros (authorityTimeMicros now + 5000000))
  unless
    (case positive of Right remaining -> remaining > 0 && remaining <= 1000000000; Left _ -> False)
    (fail "safe real clock pair refused or renewed work")
  putStrLn "PASS safe native read retains only original remaining work"
  let sample before utc after = RpcBirthHostClockSample before (authorityTimeFromMicros utc) after
      check bounds deadlineValue = checkRpcBirthHostClockSample bounds (authorityTimeFromMicros deadlineValue)
      cases =
        [ ("inclusive safe ceiling", check (19000, 20000) 100 (sample 1000 80 2000), Right 17000)
        ,
          ( "one nanosecond outside"
          , check (19000, 20001) 100 (sample 1000 80 2000)
          , Left RpcBirthHostClockOutsideAuthorityBound
          )
        ,
          ( "read latency"
          , check (20000, 25000) 100 (sample 1000 80 11000)
          , Left RpcBirthHostClockOutsideAuthorityBound
          )
        ,
          ( "UTC microsecond uncertainty"
          , check (19000, 21000) 100 (sample 1000 80 1000)
          , Left RpcBirthHostClockOutsideAuthorityBound
          )
        , ("elapsed Authority", check (19000, 20000) 80 (sample 1000 80 2000), Left RpcBirthHostClockExpired)
        , ("passed Authority", check (19000, 20000) 79 (sample 1000 80 2000), Left RpcBirthHostClockExpired)
        , ("exact work end", check (2000, 20000) 100 (sample 1000 80 2000), Left RpcBirthHostClockExpired)
        , ("passed work end", check (1999, 20000) 100 (sample 1000 80 2000), Left RpcBirthHostClockExpired)
        ,
          ( "reversed sample"
          , check (19000, 20000) 100 (sample 3000 80 2000)
          , Left RpcBirthHostClockSampleInvalid
          )
        ,
          ( "invalid window"
          , check (20000, 19000) 100 (sample 1000 80 2000)
          , Left RpcBirthHostClockSampleInvalid
          )
        ,
          ( "work conversion overflow"
          , check
              (fromIntegral (maxBound :: Int64) + 1, fromIntegral (maxBound :: Int64) + 2)
              10000000000000000
              (sample 0 0 0)
          , Left RpcBirthHostClockRemainingOverflow
          )
        ,
          ( "near Word64 ceiling"
          , check (maxBound - 2, maxBound - 1) 3 (sample (maxBound - 100) 1 (maxBound - 50))
          , Right 48
          )
        ]
  forM_ cases $ \(label, actual, expected) -> unless (actual == expected) (fail (label ++ ": " ++ show actual))
  putStrLn "PASS 12 clock-sample boundary laws"
