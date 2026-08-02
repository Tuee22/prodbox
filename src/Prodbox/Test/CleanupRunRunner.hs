{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Total durable cleanup driver. The primary action is admitted only after
-- the complete run has been committed. Cleanup failures are data, so one node
-- cannot short-circuit an independent or RequiresAttempt successor.
module Prodbox.Test.CleanupRunRunner
  ( CleanupRunDriverError (..)
  , CleanupRunDriverResult (..)
  , runWithDurableCleanup
  , runWithDurableCleanupOutcome
  , claimAndResumeDurableCleanup
  , recoverNonterminalCleanupRuns
  , compactEligibleCleanupRuns
  , resumeDurableCleanup
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , displayException
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.Either (partitionEithers)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (..)
  , CleanupRunClientError
  )
import Prodbox.ControlPlane.CleanupRunEndpoint (CleanupRunCommand (..))
import Prodbox.Test.CleanupRun
  ( CleanupDependency (..)
  , CleanupDependencyKind (..)
  , CleanupLease (..)
  , CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupNodeState (..)
  , CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRun (..)
  , CleanupRunCodecError
  , CleanupRunReport
  , cleanupAttemptIdText
  , cleanupGraphNodes
  , cleanupNodeDependencies
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupOwnerIdText
  , cleanupRunIdText
  , cleanupRunTerminal
  , compactCleanupRun
  , encodeCleanupRun
  , mkCleanupAttemptId
  )
import System.Timeout (timeout)

data CleanupRunDriverError
  = CleanupRunDriverCodecFailed !CleanupRunCodecError
  | CleanupRunDriverClientFailed !CleanupRunClientError
  | CleanupRunDriverMissing
  | CleanupRunDriverAttemptInvalid !Text
  | CleanupRunDriverNoProgress
  | CleanupRunDriverCompactionFailed !Text
  | CleanupRunDriverShieldExpired
  deriving stock (Eq, Show)

data CleanupRunDriverResult value = CleanupRunDriverResult
  { cleanupDriverPrimaryValue :: !(Maybe value)
  , cleanupDriverReport :: !CleanupRunReport
  }
  deriving stock (Eq, Show)

runWithDurableCleanup
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO value
  -> (CleanupNodePlan -> IO CleanupNodeOutcome)
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanup maximumBytes client initial owner shieldMicros primary cleanup =
  runWithDurableCleanupOutcome
    maximumBytes
    client
    initial
    owner
    shieldMicros
    (Right <$> primary)
    cleanup

-- | Variant for command-style primaries whose non-zero result is ordinary,
-- structured failure rather than an exception. This prevents an 'ExitFailure'
-- value from being durably misreported as a successful suite outcome.
runWithDurableCleanupOutcome
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO (Either Text value)
  -> (CleanupNodePlan -> IO CleanupNodeOutcome)
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanupOutcome maximumBytes client initial owner shieldMicros primary cleanup =
  mask $ \restore -> do
    created <- create
    case created of
      Left err -> pure (Left err)
      Right committed -> do
        primaryResult <- try (restore primary)
        let outcome = case primaryResult of
              Right (Right _) -> CleanupPrimarySucceeded
              Right (Left detail) -> CleanupPrimaryFailed detail
              Left exception
                | isAsync exception -> CleanupPrimaryCancelled
                | otherwise -> CleanupPrimaryFailed (Text.pack (displayException exception))
        recorded <- command (recordCommand committed outcome)
        driven <- case recorded of
          Left err -> pure (Just (Left err))
          Right run -> timeout shieldMicros (resumeDurableCleanup client owner cleanup run)
        case (primaryResult, driven) of
          (Left exception, Just (Right result))
            | isAsync exception -> throwIO exception
            | otherwise -> pure (Right (CleanupRunDriverResult Nothing result))
          (_, Nothing) -> pure (Left CleanupRunDriverShieldExpired)
          (_, Just (Left err)) -> pure (Left err)
          (Right (Left _), Just (Right result)) ->
            pure (Right (CleanupRunDriverResult Nothing result))
          (Right (Right value), Just (Right result)) ->
            pure (Right (CleanupRunDriverResult (Just value) result))
 where
  create = case encodeCleanupRun maximumBytes initial of
    Left err -> pure (Left (CleanupRunDriverCodecFailed err))
    Right bytes -> command (CleanupRunCreate runId bytes)
  runId = cleanupRunIdText (cleanupRunId initial)
  recordCommand run outcome =
    CleanupRunRecordPrimary
      runId
      (cleanupOwnerIdText owner)
      (cleanupLeaseFence (cleanupRunLease run))
      outcome
  command request = do
    result <- executeCleanupRunCommand client request
    pure $ case result of
      Left err -> Left (CleanupRunDriverClientFailed err)
      Right Nothing -> Left CleanupRunDriverMissing
      Right (Just run) -> Right run

resumeDurableCleanup
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> (CleanupNodePlan -> IO CleanupNodeOutcome)
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
resumeDurableCleanup client owner runAction = go
 where
  go run = case compactCleanupRun run of
    Right report -> pure (Right report)
    Left _ -> case nextPending run of
      Nothing -> pure (Left CleanupRunDriverNoProgress)
      Just plan -> do
        let node = cleanupNodeId plan
            fence = cleanupLeaseFence (cleanupRunLease run)
        case attemptFor fence node of
          Left err -> pure (Left err)
          Right attempt -> do
            begun <- call (beginCommand run node attempt)
            case begun of
              Left err -> pure (Left err)
              Right running -> do
                attempted <- try (runAction plan) :: IO (Either SomeException CleanupNodeOutcome)
                outcome <- case attempted of
                  Left exception
                    | isAsync exception -> throwIO exception
                    | otherwise -> pure (CleanupNodeFailed (Text.pack (displayException exception)))
                  Right value -> pure value
                completed <- call (completeCommand running node attempt outcome)
                either (pure . Left) go completed

  nextPending run =
    find
      ( \plan ->
          Map.lookup (cleanupNodeId plan) (cleanupRunNodeStates run) == Just CleanupNodePending
            && all (dependencySatisfied run) (cleanupNodeDependencies plan)
      )
      (cleanupGraphNodes (cleanupRunGraph run))

  dependencySatisfied run dependency =
    case Map.lookup (cleanupDependencyNode dependency) (cleanupRunNodeStates run) of
      Just (CleanupNodeCompleted _ CleanupNodeSucceeded) -> True
      Just (CleanupNodeCompleted _ (CleanupNodeFailed _)) ->
        cleanupDependencyKind dependency == CleanupRequiresAttempt
      _ -> False

  attemptFor fence node =
    case mkCleanupAttemptId (cleanupNodeIdText node <> ":fence-" <> Text.pack (show fence)) of
      Left detail -> Left (CleanupRunDriverAttemptInvalid detail)
      Right attempt -> Right attempt

  beginCommand run node attempt =
    CleanupRunBeginNode
      (cleanupRunIdText (cleanupRunId run))
      (cleanupOwnerIdText owner)
      (cleanupLeaseFence (cleanupRunLease run))
      (cleanupNodeIdText node)
      (cleanupAttemptIdText attempt)

  completeCommand run node attempt outcome =
    CleanupRunCompleteNode
      (cleanupRunIdText (cleanupRunId run))
      (cleanupOwnerIdText owner)
      (cleanupLeaseFence (cleanupRunLease run))
      (cleanupNodeIdText node)
      (cleanupAttemptIdText attempt)
      outcome

  call request = do
    result <- executeCleanupRunCommand client request
    pure $ case result of
      Left err -> Left (CleanupRunDriverClientFailed err)
      Right Nothing -> Left CleanupRunDriverMissing
      Right (Just observed) -> Right observed

-- | Recovery entrypoint used by suite preflight. The greater fence is
-- acquired durably before any cleanup action is retried.
claimAndResumeDurableCleanup
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> (CleanupNodePlan -> IO CleanupNodeOutcome)
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
claimAndResumeDurableCleanup client owner now expires runAction observed = do
  claimed <-
    executeCleanupRunCommand
      client
      ( CleanupRunClaim
          (cleanupRunIdText (cleanupRunId observed))
          (cleanupOwnerIdText owner)
          now
          expires
      )
  case claimed of
    Left err -> pure (Left (CleanupRunDriverClientFailed err))
    Right Nothing -> pure (Left CleanupRunDriverMissing)
    Right (Just run) -> resumeDurableCleanup client owner runAction run

-- | Authority-scope preflight. Every indexed nonterminal is observed and
-- attempted before the caller may admit a successor mutation; failures are
-- accumulated so one damaged run cannot hide another cleanup obligation.
recoverNonterminalCleanupRuns
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> (CleanupNodePlan -> IO CleanupNodeOutcome)
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
recoverNonterminalCleanupRuns client owner now expires runAction = do
  scanned <- scanNonterminalCleanupRuns client
  case scanned of
    Left err -> pure (Left [CleanupRunDriverClientFailed err])
    Right runIds -> do
      recovered <- mapM recover runIds
      let (failures, reports) = partitionEithers recovered
      pure $
        if null failures
          then Right reports
          else Left failures
 where
  recover runId = do
    observed <- executeCleanupRunCommand client (CleanupRunObserve runId)
    case observed of
      Left err -> pure (Left (CleanupRunDriverClientFailed err))
      Right Nothing -> pure (Left CleanupRunDriverMissing)
      Right (Just run) ->
        claimAndResumeDurableCleanup client owner now expires runAction run

compactEligibleCleanupRuns
  :: CleanupRunClient IO
  -> Natural
  -> Natural
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
compactEligibleCleanupRuns client now retention = do
  scanned <- scanNonterminalCleanupRuns client
  case scanned of
    Left err -> pure (Left [CleanupRunDriverClientFailed err])
    Right runIds -> do
      attempted <- mapM compactIfTerminal runIds
      let (failures, reports) = partitionEithers attempted
      pure $
        if null failures
          then Right (catMaybes reports)
          else Left failures
 where
  compactIfTerminal runId = do
    observed <- executeCleanupRunCommand client (CleanupRunObserve runId)
    case observed of
      Left err -> pure (Left (CleanupRunDriverClientFailed err))
      Right Nothing -> pure (Left CleanupRunDriverMissing)
      Right (Just run)
        | not (cleanupRunTerminal run) -> pure (Right Nothing)
        | otherwise -> do
            compacted <- compactTerminalCleanupRun client runId now retention
            pure $ case compacted of
              Left err -> Left (CleanupRunDriverClientFailed err)
              Right report -> Right (Just report)

isAsync :: SomeException -> Bool
isAsync exception = case fromException exception :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False
