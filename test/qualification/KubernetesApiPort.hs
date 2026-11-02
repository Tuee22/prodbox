{-# LANGUAGE ImportQualifiedPost #-}

-- The actual compiled chart parser is the subject in both frozen and repaired
-- binaries. No cluster, subprocess observer or rendering replacement is used.
module Main (main) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_, unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Prodbox.Lib.ChartPlatform (kubernetesApiEgressPort, parseKubernetesApiEgressCoordinate)
import System.Exit (exitFailure)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  forM_ [1 .. 65535 :: Int] $ \port ->
    unless (observed (show port) == Just port) (fail "valid TCP port refused or changed")
  putStrLn "PASS complete positive TCP port domain: 65535 values"
  forM_ cases $ \(label, input, expected) -> do
    attempted <- try (evaluate (observed input == expected)) :: IO (Either SomeException Bool)
    case attempted of
      Right True -> putStrLn ("PASS " ++ label)
      _ -> do
        modifyIORef' failures (+ 1)
        putStrLn ("FAIL " ++ label)
  count <- readIORef failures
  if count == 0
    then putStrLn ("PASS all " ++ show (length cases) ++ " port boundary/sibling controls")
    else exitFailure
 where
  observed port =
    either
      (const Nothing)
      (Just . kubernetesApiEgressPort)
      (parseKubernetesApiEgressCoordinate ("10.0.0.1|" ++ port))

cases :: [(String, String, Maybe Int)]
cases =
  [ ("lower-bound", "1", Just 1)
  , ("upper-bound", "65535", Just 65535)
  , ("ordinary-api-port", "6443", Just 6443)
  , ("repeated-port", "6443 6443", Just 6443)
  , ("padded-five-digit-port", "00001", Just 1)
  , ("surrounding-whitespace", " \t6443\n", Just 6443)
  , ("zero", "0", Nothing)
  , ("padded-zero", "00000", Nothing)
  , ("above-upper-bound", "65536", Nothing)
  , ("decimal-five-digit-high", "99999", Nothing)
  , ("signed-negative", "-1", Nothing)
  , ("explicit-plus", "+6443", Nothing)
  , ("missing-port", "", Nothing)
  , ("ambiguous-ports", "6443 8443", Nothing)
  , ("machine-word-high", "18446744073709551615", Nothing)
  , ("machine-word-wrap-to-one", "18446744073709551617", Nothing)
  , ("large-decimal", replicate 4096 '9', Nothing)
  , ("overlong-padded-decimal", "000001", Nothing)
  , ("hexadecimal", "0x192b", Nothing)
  , ("exponent", "6.443e3", Nothing)
  , ("non-ascii-digit", "\1633", Nothing)
  ]
