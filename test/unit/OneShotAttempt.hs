{-# LANGUAGE ImportQualifiedPost #-}

module OneShotAttempt (oneShotAttemptSuite) where

import Control.Concurrent.Async (cancel, replicateConcurrently, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), evaluate, throwIO, try)
import Control.Monad (unless)
import Data.Bits (finiteBitSize)
import Data.Either (isLeft)
import GHC.Exts.Heap qualified as Heap
import GHC.Exts.Heap.Closures (closureSize)
import Prodbox.Subprocess.OneShotAttempt qualified as Attempt
import System.Mem (performGC)
import TestSupport

oneShotAttemptSuite :: SuiteBuilder ()
oneShotAttemptSuite = describe "Sprint 6.5 one-shot operation attempt" $ do
  it "admits exactly one concurrent claimant and never resets" $ do
    attempt <- Attempt.newOneShotAttempt
    winners <- replicateConcurrently 128 (Attempt.claimOneShotAttempt attempt)
    length (filter id winners) `shouldBe` 1
    denied <- replicateConcurrently 128 (Attempt.claimOneShotAttempt attempt)
    or denied `shouldBe` False

  it "keeps an attempt consumed when its claimant is cancelled" $ do
    attempt <- cancelledClaimant
    Attempt.claimOneShotAttempt attempt `shouldReturn` False

  it "leaves the attempt available when a caller is cancelled before claiming" $ do
    attempt <- Attempt.newOneShotAttempt
    ready <- newEmptyMVar
    blocked <- newEmptyMVar
    withAsync (putMVar ready () >> takeMVar blocked >> Attempt.claimOneShotAttempt attempt) $ \worker -> do
      takeMVar ready
      cancel worker
    Attempt.claimOneShotAttempt attempt `shouldReturn` True

  it "keeps an attempt consumed after a claimant exception" $ do
    attempt <- failedClaimant
    Attempt.claimOneShotAttempt attempt `shouldReturn` False

  it "funds the complete fresh claim-cell graph on the pinned ABI" $
    Attempt.newOneShotAttempt >>= checkGraph

  it "funds the complete cell graph after concurrent claims settle" $ do
    attempt <- Attempt.newOneShotAttempt
    _ <- replicateConcurrently 128 (Attempt.claimOneShotAttempt attempt)
    checkGraph attempt

  it "funds the complete cell graph after owner cancellation" $
    cancelledClaimant >>= checkGraph

  it "funds the complete cell graph after an owner exception" $
    failedClaimant >>= checkGraph

cancelledClaimant :: IO Attempt.OneShotAttempt
cancelledClaimant = do
  attempt <- Attempt.newOneShotAttempt
  reached <- newEmptyMVar
  blocked <- newEmptyMVar
  withAsync (Attempt.claimOneShotAttempt attempt >>= putMVar reached >> takeMVar blocked) $ \worker -> do
    takeMVar reached `shouldReturn` True
    cancel worker
    outcome <- waitCatch worker
    outcome `shouldSatisfy` isLeft
  pure attempt

failedClaimant :: IO Attempt.OneShotAttempt
failedClaimant = do
  attempt <- Attempt.newOneShotAttempt
  outcome <-
    try (Attempt.claimOneShotAttempt attempt >> throwIO ThreadKilled) :: IO (Either AsyncException ())
  outcome `shouldBe` Left ThreadKilled
  pure attempt

checkGraph :: Attempt.OneShotAttempt -> IO ()
checkGraph attempt = do
  finiteBitSize (0 :: Word) `shouldBe` 64
  _ <- evaluate (Attempt.oneShotAttemptNormalFormBytes attempt)
  performGC
  bytes <- observedBytes [] [Heap.asBox attempt] 0
  bytes `shouldSatisfy` (<= fromIntegral (Attempt.oneShotAttemptNormalFormBytes attempt))
  bytes `shouldBe` 48

observedBytes :: [Heap.Box] -> [Heap.Box] -> Integer -> IO Integer
observedBytes _ [] total = pure total
observedBytes seen (box : remaining) total = do
  known <- or <$> traverse (Heap.areBoxesEqual box) seen
  if known
    then observedBytes seen remaining total
    else do
      unless (length seen < 3) (fail "one-shot graph contains an unexpected extra closure")
      closure <- Heap.getBoxedClosureData box
      requireClaimClosure closure
      let bytes = fromIntegral (closureSize box * 8)
      observedBytes (box : seen) (Heap.allClosures closure <> remaining) (total + bytes)

requireClaimClosure :: Heap.Closure -> IO ()
requireClaimClosure closure = case closure of
  Heap.ConstrClosure _ pointers payloadWords packageName moduleName constructor ->
    requireClaimConstructor (packageName, moduleName, constructor, length pointers, length payloadWords)
  Heap.MutVarClosure {} -> pure ()
  other -> fail ("unexpected one-shot closure: " <> show other)

requireClaimConstructor :: (String, String, String, Int, Int) -> IO ()
requireClaimConstructor shape =
  unless
    (shape `elem` pinnedConstructors)
    (fail ("unexpected one-shot constructor shape: " <> show shape))
 where
  pinnedConstructors =
    [ ("ghc-internal", "GHC.Internal.STRef", "STRef", 1, 0)
    , ("ghc-prim", "GHC.Types", "True", 0, 0)
    , ("ghc-prim", "GHC.Types", "True", 0, 1)
    , ("ghc-prim", "GHC.Types", "False", 0, 0)
    , ("ghc-prim", "GHC.Types", "False", 0, 1)
    ]
