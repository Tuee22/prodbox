{-# LANGUAGE ImportQualifiedPost #-}

module RegisteredCallerBudgetStorage (registeredCallerBudgetStorageSuite) where

import Control.Concurrent.Async
  ( AsyncCancelled (..)
  , async
  , cancel
  , mapConcurrently_
  , replicateConcurrently
  , wait
  , waitCatch
  , withAsync
  )
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , evaluate
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, replicateM, replicateM_, (>=>))
import Data.Bits (finiteBitSize)
import Data.Word (Word64)
import GHC.Exts.Heap qualified as Heap
import PinnedHeapGraph (observeCellGraphBytes)
import Prodbox.Capacity.OrdinaryRecoveryObservationSchedule qualified as RecoverySchedule
import Prodbox.Capacity.RegisteredCallerTraffic
import Prodbox.ControlPlane.CleanupRunEndpoint (cleanupRunDescriptorResponseMaximumBytes)
import Prodbox.ControlPlane.RegisteredCallerBudget
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleCleanupRun, LifecycleProviderScopeObserve)
  )
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

registeredCallerBudgetStorageSuite :: SuiteBuilder ()
registeredCallerBudgetStorageSuite = describe "shared caller counter cell" $ do
  it "prices the two fixed recovery observations and rejects each insufficient counter" $ do
    let traffic = RecoverySchedule.recoveryObservationTraffic
        steps = RecoverySchedule.recoveryObservationSteps
    map RecoverySchedule.recoveryObservationRoute steps
      @?= [LifecycleProviderScopeObserve, LifecycleCleanupRun]
    map RecoverySchedule.recoveryObservationResponseMaximumBytes steps
      @?= [4096, cleanupRunDescriptorResponseMaximumBytes]
    ordinaryFrames traffic @?= 2
    registryObservations traffic @?= 6
    totalSignedFrames traffic @?= 14
    protocolHttpRequests traffic @?= 20
    homeScopeEntries traffic @?= 2
    perExchangeForwards traffic @?= 10
    assertBool
      "exact recovery traffic is not covered"
      (RecoverySchedule.recoveryObservationTrafficCoveredBy traffic)
    forM_
      [ traffic {ordinaryFrames = ordinaryFrames traffic - 1}
      , traffic {registryObservations = registryObservations traffic - 1}
      , traffic {publicHints = publicHints traffic - 1}
      , traffic {metadataSignedFrames = metadataSignedFrames traffic - 1}
      , traffic {totalSignedFrames = totalSignedFrames traffic - 1}
      , traffic {protocolHttpRequests = protocolHttpRequests traffic - 1}
      , traffic {homeScopeEntries = homeScopeEntries traffic - 1}
      , traffic {perExchangeForwards = perExchangeForwards traffic - 1}
      ]
      $ \underfunded ->
        assertBool
          "underfunded recovery traffic was accepted"
          (not (RecoverySchedule.recoveryObservationTrafficCoveredBy underfunded))
    case RecoverySchedule.recoveryObservationCallerCost 1 1000000000 of
      Left failure -> assertFailure (show failure)
      Right cost -> callerCostTraffic cost @?= traffic

  it "funds valid large count values within the existing domain" $ do
    let maximumWord = fromIntegral (maxBound :: Word64)
        traffic = registeredCallerTraffic (maximumWord `div` 1000) 3
    budget <- right =<< newCallerBudget traffic (maximumWord `div` 8) maxBound
    checkGraph budget

  it "fresh cell has only its closed data and scalar graph" $ newBudget >>= checkGraph
  it "each debit preserves the closed cell representation" $
    forM_ [minBound .. maxBound] $ \kind -> do
      budget <- newBudget
      consumeCallerBudget budget kind >>= (@?= Right ())
      checkGraph budget
  it "exhaustion preserves the cell and cannot reopen the quota" $ do
    budget <- newBudget
    replicateM_ 100 (consumeCallerBudget budget CallerOrdinaryFrame >>= (@?= Right ()))
    replicateM_
      3
      ( consumeCallerBudget budget CallerOrdinaryFrame
          >>= (@?= Left (CallerBudgetExhausted CallerOrdinaryFrame))
      )
    checkGraph budget
  it "settled contention has 100 winners and a closed cell" $ do
    budget <- newBudget
    results <- replicateConcurrently 128 (consumeCallerBudget budget CallerOrdinaryFrame)
    length [() | Right () <- results] @?= 100
    length [() | Left (CallerBudgetExhausted CallerOrdinaryFrame) <- results] @?= 28
    checkGraph budget
  it "cancellation before claiming leaves the fresh cell available" $ do
    budget <- newBudget
    started <- newEmptyMVar
    gate <- newEmptyMVar
    withAsync (putMVar started () >> readMVar gate >> consumeCallerBudget budget CallerOrdinaryFrame) $ \worker -> do
      readMVar started
      cancel worker
      waitCatch worker >>= requireExpectedCancellation
    checkGraph budget
    replicateM_ 100 (consumeCallerBudget budget CallerOrdinaryFrame >>= (@?= Right ()))
    consumeCallerBudget budget CallerOrdinaryFrame
      >>= (@?= Left (CallerBudgetExhausted CallerOrdinaryFrame))
  it "settled cancellation races retain no updater or selector" $
    forM_ [1 :: Int .. 32] $ \_ -> do
      budget <- newBudget
      gate <- newEmptyMVar
      workers <- replicateM 128 (async (readMVar gate >> consumeCallerBudget budget CallerTokenLogin))
      canceller <- async (mapConcurrently_ cancel workers)
      putMVar gate ()
      wait canceller
      mapM_ (waitCatch >=> requireExpectedCancellation) workers
      checkGraph budget
  it "a nonce producer exception consumes its quota without changing the cell shape" $ do
    let traffic = registeredCallerTraffic 0 0
    prepared <- newCallerBudget traffic 1 1000000000
    budget <- right prepared
    failed <-
      try (nextCallerBudgetedNonce budget (throwIO ThreadKilled :: IO ()))
        :: IO (Either AsyncException (Either CallerBudgetError ()))
    failed @?= Left ThreadKilled
    checkGraph budget
    replicateM_
      (fromIntegral (totalSignedFrames traffic - 1))
      (nextCallerBudgetedNonce budget (pure ()) >>= (@?= Right ()))
    nextCallerBudgetedNonce budget (assertFailure "exhausted nonce producer ran" :: IO ())
      >>= (@?= Left (CallerBudgetExhausted CallerSignedNonce))

newBudget :: IO CallerBudget
newBudget = right =<< newCallerBudget (registeredCallerTraffic 100 3) 97 1000000000

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

requireExpectedCancellation :: Either SomeException (Either CallerBudgetError ()) -> IO ()
requireExpectedCancellation result = case result of
  Right _ -> pure ()
  Left cause -> case fromException cause of
    Just AsyncCancelled -> pure ()
    Nothing -> fail (show cause)

checkGraph :: CallerBudget -> IO ()
checkGraph budget = do
  finiteBitSize (0 :: Word) @?= 64
  declared <- evaluate (callerBudgetNormalFormBytes budget)
  performGC
  root <- Heap.getBoxedClosureData (Heap.asBox budget)
  case root of
    Heap.ConstrClosure _ [mutable] _ _ _ "STRef" -> do
      reference <- Heap.getBoxedClosureData mutable
      case reference of
        Heap.MutVarClosure _ payload -> Heap.getBoxedClosureData payload >>= requireRemaining
        other -> fail ("unexpected caller reference: " <> take 300 (show other))
    other -> fail ("unexpected caller cell root: " <> take 300 (show other))
  (observed, nodes) <- observeCellGraphBytes budget
  assertBool
    ("cell graph=" <> show observed <> " bytes, nodes=" <> show nodes <> "; declared=" <> show declared)
    (observed <= toInteger declared)

requireRemaining :: Heap.Closure -> IO ()
requireRemaining closure = case closure of
  Heap.ConstrClosure _ pointers words_ _ moduleName constructor ->
    (moduleName, constructor, length pointers, length words_)
      @?= ("Prodbox.ControlPlane.RegisteredCallerBudget", "Remaining", 8, 0)
  other -> fail ("caller cell retained an unevaluated or executable payload: " <> take 300 (show other))
