{-# LANGUAGE ScopedTypeVariables #-}

module CapacityRpcBirthTraffic (capacityRpcBirthTrafficSuite) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (cancel, replicateConcurrently, withAsync)
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM_, replicateM, when)
import Data.Either (isLeft, isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Prodbox.Capacity.RpcBirthTraffic
import Prodbox.ControlPlane.RpcBirthSigningBudget
import TestSupport

capacityRpcBirthTrafficSuite :: SuiteBuilder ()
capacityRpcBirthTrafficSuite = describe "closed caller signed-request allowance" $
  forM_ [(RpcBirthInitialTraffic, 12, 0, 2), (RpcBirthRegisteredTraffic, 44, 18, 1)] $
    \(mode, maximumRequests, registryReads, mutations) -> describe (show mode) $ do
      it "derives the complete ordinary and bootstrap traffic" $ do
        rpcBirthSignedRequestMaximum mode `shouldBe` maximumRequests
        rpcBirthRegistryReadMaximum mode `shouldBe` registryReads
        rpcBirthMutationMaximum mode `shouldBe` mutations

      it "shares one debit across copied owners and refuses before another nonce effect" $ do
        calls <- newIORef (0 :: Int)
        budget <- newRpcBirthNonceBudget mode (atomicModifyIORef' calls (\n -> (n + 1, n)))
        let copied = budget
            attempts = take (fromIntegral maximumRequests + 2) (cycle [budget, copied])
        results <- mapM nextRpcBirthBudgetedNonce attempts
        length (filter isRight results) `shouldBe` fromIntegral maximumRequests
        drop (fromIntegral maximumRequests) results
          `shouldBe` replicate 2 (Left (RpcBirthSigningAllowanceExhausted mode))
        readIORef calls `shouldReturn` fromIntegral maximumRequests

      it "atomically enforces the same ceiling under concurrent requests" $ do
        calls <- newIORef (0 :: Int)
        budget <- newRpcBirthNonceBudget mode (atomicModifyIORef' calls (\n -> (n + 1, n)))
        results <-
          replicateConcurrently (2 * fromIntegral maximumRequests) (nextRpcBirthBudgetedNonce budget)
        length (filter isRight results) `shouldBe` fromIntegral maximumRequests
        readIORef calls `shouldReturn` fromIntegral maximumRequests

      it "does not refund a failed nonce source" $ do
        calls <- newIORef (0 :: Int)
        let generate = do
              index <- atomicModifyIORef' calls (\n -> (n + 1, n))
              when (index == 0) (throwIO (userError "authored nonce-source failure"))
              pure index
        budget <- newRpcBirthNonceBudget mode generate
        failed <- try (nextRpcBirthBudgetedNonce budget)
        (failed :: Either IOException (Either RpcBirthTrafficError Int))
          `shouldSatisfy` isLeft
        remaining <- replicateM (fromIntegral maximumRequests - 1) (nextRpcBirthBudgetedNonce budget)
        all isRight remaining `shouldBe` True
        nextRpcBirthBudgetedNonce budget `shouldReturn` Left (RpcBirthSigningAllowanceExhausted mode)
        readIORef calls `shouldReturn` fromIntegral maximumRequests

      it "does not refund a cancelled nonce source" $ do
        calls <- newIORef (0 :: Int)
        entered <- newEmptyMVar
        blocked <- newEmptyMVar
        let generate = do
              index <- atomicModifyIORef' calls (\n -> (n + 1, n))
              when (index == 0) (putMVar entered () >> takeMVar blocked)
              pure index
        budget <- newRpcBirthNonceBudget mode generate
        withAsync (nextRpcBirthBudgetedNonce budget) $ \worker -> do
          takeMVar entered
          cancel worker
        remaining <- replicateM (fromIntegral maximumRequests - 1) (nextRpcBirthBudgetedNonce budget)
        all isRight remaining `shouldBe` True
        nextRpcBirthBudgetedNonce budget `shouldReturn` Left (RpcBirthSigningAllowanceExhausted mode)
        readIORef calls `shouldReturn` fromIntegral maximumRequests
