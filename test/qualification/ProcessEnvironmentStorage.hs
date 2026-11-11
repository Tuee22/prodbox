{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Exts (isTrue#, sameMutableByteArray#)
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Subprocess.ProcessEnvironment
import System.Environment (lookupEnv)
import System.Mem (performGC)
import System.Posix.Env.ByteString qualified as Native
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Runners (NumThreads (..))

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

capture :: IO ProcessEnvironment
capture = do
  now <- getMonotonicTimeNSec
  right =<< captureProcessEnvironmentBefore (now + 5000000000)

empty :: IO ProcessEnvironment
empty = filterProcessEnvironment (const False) <$> capture

main :: IO ()
main = do
  sentinel <- lookupEnv "PRODBOX_ENV_FIXTURE"
  case sentinel of
    Just "synthetic-no-secrets" -> runControls
    _ -> fail "complete synthetic environment required"

runControls :: IO ()
runControls =
  defaultMain $
    localOption (NumThreads 1) $
      testGroup
        "native environment quiescent storage"
        [ testCase "empty filtered environment" $ empty >>= checkGraph
        , testCase "separate compact overlay allocations" $ do
            base <- empty
            forM_ [[], [("A", "")], [("A", "B"), ("C", "D")], [("λKEY", "😀value")]] $ \pairs -> do
              environment <- right =<< overlayProcessEnvironment pairs base
              checkGraph environment
        , testCase "large native entry keeps its shared key/value origin" $ do
            Native.setEnv "NF_CONTROLLED_STORAGE" (Bytes.replicate 1048576 88) True
            full <- capture
            let environment = filterProcessEnvironment (== "NF_CONTROLLED_STORAGE") full
            case processEnvironmentNativeEntries environment of
              [(key, value)] -> do
                Bytes.length value @?= 1048576
                sharedOrigin key value @?= True
                checkGraph environment
              _ -> assertFailure "expected the single controlled entry"
        , testCase "many encoded overlay entries" $ do
            base <- empty
            environment <-
              right
                =<< overlayProcessEnvironment [("NF_" <> show n, replicate 63 'x') | n <- [1 :: Int .. 256]] base
            processEnvironmentEntryCount (processEnvironmentUsage environment) @?= 256
            checkGraph environment
        , testCase "filtering/replacing does not retain the rejected environment" $ do
            Native.setEnv "NF_REJECTED_STORAGE" (Bytes.replicate 1048576 88) True
            Native.setEnv "NF_SELECTED_STORAGE" "small" True
            original <- capture
            let filtered = filterProcessEnvironment (== "NF_SELECTED_STORAGE") original
            environment <- right =<< overlayProcessEnvironment [("NF_SELECTED_STORAGE", "replacement")] filtered
            checkGraph environment
            (observed, _) <- observeGraphBytes environment
            assertBool "selected environment retained the rejected large backing" (observed < 1048576)
        ]

checkGraph :: ProcessEnvironment -> IO ()
checkGraph environment = do
  declared <- evaluate (processEnvironmentNormalFormBytes environment)
  performGC
  (observed, nodes) <- observeGraphBytes environment
  putStrLn ("observed=" <> show observed <> " nodes=" <> show nodes <> " declared=" <> show declared)
  assertBool "environment graph exceeds paired-origin term" (observed <= toInteger declared)

sharedOrigin :: Bytes.ByteString -> Bytes.ByteString -> Bool
sharedOrigin first second = case (origin first, origin second) of
  (PlainPtr a, PlainPtr b) -> isTrue# (sameMutableByteArray# a b)
  _ -> False
 where
  origin value = case BytesInternal.toForeignPtr value of
    (ForeignPtr _ contents, _, _) -> contents
