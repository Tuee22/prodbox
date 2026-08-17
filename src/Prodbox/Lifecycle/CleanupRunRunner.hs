{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Total durable cleanup driver. The primary action is admitted only after
-- the complete run has been committed. Cleanup failures are data, so one node
-- cannot short-circuit an independent or RequiresAttempt successor.
module Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupDependencyReceipt
  , cleanupDependencyReceiptNodeId
  , cleanupDependencyReceiptOperationId
  , cleanupDependencyReceiptAttemptId
  , cleanupDependencyReceiptKind
  , cleanupDependencyReceiptOutcome
  , CleanupTerminalDependencyResult (..)
  , CleanupTerminalDependencyReceipt
  , cleanupTerminalDependencyReceiptNodeId
  , cleanupTerminalDependencyReceiptOperationId
  , cleanupTerminalDependencyReceiptResult
  , CleanupNodeExecutionContext
  , cleanupNodeExecutionAttemptId
  , cleanupNodeExecutionRunId
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionDependencyReceipts
  , cleanupNodeExecutionTerminalDependencyReceipts
  , CleanupNodeExecutionAction
  , DescriptorBoundCleanupNodeExecutionAction
  , descriptorBoundCleanupNodeAction
  , descriptorBoundCleanupNodeExecutionContext
  , CleanupNodeAttemptAction
  , CleanupRunDriverError (..)
  , CleanupRunDriverResult (..)
  , runWithDurableCleanup
  , runWithDurableCleanupWithAttempt
  , runWithDurableCleanupWithContext
  , runWithDurableCleanupOutcome
  , runWithDurableCleanupOutcomeWithAttempt
  , runWithDurableCleanupOutcomeWithContext
  , claimAndResumeDurableCleanup
  , claimAndResumeDurableCleanupWithAttempt
  , claimAndResumeDurableCleanupWithContext
  , recoverNonterminalCleanupRuns
  , recoverNonterminalCleanupRunsWithAttempt
  , recoverNonterminalCleanupRunsWithContext
  , compactEligibleCleanupRuns
  , resumeDurableCleanup
  , resumeDurableCleanupWithAttempt
  , resumeDurableCleanupWithContext
  , runWithDescriptorBoundDurableCleanupOutcomeWithContext
  , resumeDescriptorBoundDurableCleanupWithContext
  , recoverDescriptorBoundCleanupRunsWithContext
  , compactDescriptorBoundCleanupRuns
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
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (..)
  , CleanupRunClientError
  , DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunLease
  , descriptorBoundCleanupRunNodeStates
  , descriptorBoundCleanupRunReport
  , descriptorBoundCleanupRunTerminal
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.CleanupRunEndpoint (CleanupRunCommand (..))
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDependency (..)
  , CleanupDependencyKind (..)
  , CleanupDigest
  , CleanupLease (..)
  , CleanupNodeId
  , CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRun (..)
  , CleanupRunCodecError
  , CleanupRunId
  , CleanupRunReport
  , cleanupAttemptIdText
  , cleanupDigestText
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeDependencies
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupOwnerIdText
  , cleanupRunIdText
  , cleanupRunTerminal
  , compactCleanupRun
  , encodeCleanupRun
  , mkCleanupAttemptId
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  )
import Prodbox.Lifecycle.Teardown.Graph (CompiledDesiredAbsenceProgram)
import Prodbox.Lifecycle.Teardown.Model (CleanupSurfaceWitness)
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

-- | Authority-observed completion of one direct dependency.  The constructor
-- is private: callers cannot turn a compiled edge into evidence that the
-- predecessor actually reached a durable terminal outcome.
data CleanupDependencyReceipt = CleanupDependencyReceipt
  { cleanupDependencyReceiptNodeId :: !CleanupNodeId
  , cleanupDependencyReceiptOperationId :: !CleanupOperationId
  , cleanupDependencyReceiptAttemptId :: !CleanupAttemptId
  , cleanupDependencyReceiptKind :: !CleanupDependencyKind
  , cleanupDependencyReceiptOutcome :: !CleanupNodeOutcome
  }
  deriving stock (Eq, Show)

-- | Exact terminal state of a direct 'CleanupRequiresTerminal' predecessor.
-- A blocked node was never attempted, so it deliberately carries no invented
-- attempt identity or mutation outcome.
data CleanupTerminalDependencyResult
  = CleanupTerminalDependencyCompleted !CleanupAttemptId !CleanupNodeOutcome
  | CleanupTerminalDependencyBlocked ![CleanupNodeId]
  deriving stock (Eq, Show)

-- | Authority-observed terminal dependency.  The constructor is private;
-- only the durable runner can project it from the persisted CleanupRun.
data CleanupTerminalDependencyReceipt = CleanupTerminalDependencyReceipt
  { cleanupTerminalDependencyReceiptNodeId :: !CleanupNodeId
  , cleanupTerminalDependencyReceiptOperationId :: !CleanupOperationId
  , cleanupTerminalDependencyReceiptResult :: !CleanupTerminalDependencyResult
  }
  deriving stock (Eq, Show)

-- | Exact execution admission minted by the durable runner after it has
-- committed the node attempt and re-read every dependency state from the
-- authoritative CleanupRun aggregate.
data CleanupNodeExecutionContext = CleanupNodeExecutionContext
  { cleanupNodeExecutionAttemptId :: !CleanupAttemptId
  , cleanupNodeExecutionRunId :: !CleanupRunId
  , cleanupNodeExecutionGraphDigest :: !CleanupDigest
  , cleanupNodeExecutionNodeId :: !CleanupNodeId
  , cleanupNodeExecutionDependencyReceipts :: ![CleanupDependencyReceipt]
  , cleanupNodeExecutionTerminalDependencyReceipts
      :: ![CleanupTerminalDependencyReceipt]
  }
  deriving stock (Eq, Show)

type CleanupNodeExecutionAction =
  CleanupNodeExecutionContext -> CleanupNodePlan -> IO CleanupNodeOutcome

-- | Restart-safe descriptor-bound action. The post-Begin opaque handle
-- carries the independently read-back committed descriptor, allowing the
-- caller to recover the exact surface-indexed semantic operation without any
-- raw CleanupRun or descriptor bytes.
type DescriptorBoundCleanupNodeExecutionAction =
  DescriptorBoundCleanupRun
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> IO CleanupNodeOutcome

-- | Lift a surface-polymorphic semantic interpreter into the restart-safe
-- descriptor runner. The opaque handle is revalidated against its committed
-- descriptor before the exact compiled program is passed to the interpreter.
-- 'runCompiledTeardownNodeWithContext' remains responsible for revalidating
-- run, graph, node, and predecessor receipt identity at effect admission.
descriptorBoundCleanupNodeAction
  :: ( forall surface
        . DescriptorBoundCleanupRun
       -> CleanupSurfaceWitness surface
       -> CompiledDesiredAbsenceProgram surface
       -> CleanupNodeExecutionContext
       -> CleanupNodePlan
       -> IO CleanupNodeOutcome
     )
  -> DescriptorBoundCleanupNodeExecutionAction
descriptorBoundCleanupNodeAction interpret running context plan =
  case withDescriptorBoundCleanupProgram running $ \witness compiled _ ->
    interpret running witness compiled context plan of
    Left failure -> pure (CleanupNodeFailed (Text.pack (show failure)))
    Right action -> action

-- | Project effect admission only from the exact post-Begin opaque handle.
-- Pending, blocked, or already completed nodes cannot manufacture an
-- execution context, and the existing dependency projection revalidates every
-- durable predecessor receipt against the same handle.
descriptorBoundCleanupNodeExecutionContext
  :: DescriptorBoundCleanupRun
  -> CleanupNodePlan
  -> Either Text CleanupNodeExecutionContext
descriptorBoundCleanupNodeExecutionContext running plan =
  case Map.lookup
    (cleanupNodeId plan)
    (descriptorBoundCleanupRunNodeStates running) of
    Just (CleanupNodeRunning attempt) ->
      descriptorExecutionContextFor running plan attempt
    _ -> Left "descriptor-bound cleanup node is not running"

-- | The fenced attempt is part of effect identity, not an incidental runner
-- detail.  Interpreters that create ephemeral destinations (notably remote
-- EKS client-auth projections) must derive their at-least-once submission
-- coordinate from this value.
type CleanupNodeAttemptAction =
  CleanupAttemptId -> CleanupNodePlan -> IO CleanupNodeOutcome

-- | Pre-cutover compatibility entrypoint for legacy raw CleanupRun callers.
-- New production composition must use the descriptor-bound entrypoints below.
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
  runWithDurableCleanupWithAttempt
    maximumBytes
    client
    initial
    owner
    shieldMicros
    primary
    (\_ -> cleanup)

runWithDurableCleanupWithAttempt
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO value
  -> CleanupNodeAttemptAction
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanupWithAttempt maximumBytes client initial owner shieldMicros primary cleanup =
  runWithDurableCleanupWithContext
    maximumBytes
    client
    initial
    owner
    shieldMicros
    primary
    (\context -> cleanup (cleanupNodeExecutionAttemptId context))

runWithDurableCleanupWithContext
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO value
  -> CleanupNodeExecutionAction
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanupWithContext maximumBytes client initial owner shieldMicros primary cleanup =
  runWithDurableCleanupOutcomeWithContext
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
  runWithDurableCleanupOutcomeWithAttempt
    maximumBytes
    client
    initial
    owner
    shieldMicros
    primary
    (\_ -> cleanup)

runWithDurableCleanupOutcomeWithAttempt
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO (Either Text value)
  -> CleanupNodeAttemptAction
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanupOutcomeWithAttempt maximumBytes client initial owner shieldMicros primary cleanup =
  runWithDurableCleanupOutcomeWithContext
    maximumBytes
    client
    initial
    owner
    shieldMicros
    primary
    (\context -> cleanup (cleanupNodeExecutionAttemptId context))

runWithDurableCleanupOutcomeWithContext
  :: Int
  -> CleanupRunClient IO
  -> CleanupRun
  -> CleanupOwnerId
  -> Int
  -> IO (Either Text value)
  -> CleanupNodeExecutionAction
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDurableCleanupOutcomeWithContext maximumBytes client initial owner shieldMicros primary cleanup =
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
          Right run ->
            timeout
              shieldMicros
              (resumeDurableCleanupWithContext client owner cleanup run)
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
resumeDurableCleanup client owner runAction =
  resumeDurableCleanupWithAttempt client owner (\_ -> runAction)

resumeDurableCleanupWithAttempt
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> CleanupNodeAttemptAction
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
resumeDurableCleanupWithAttempt client owner runAction =
  resumeDurableCleanupWithContext
    client
    owner
    (\context -> runAction (cleanupNodeExecutionAttemptId context))

resumeDurableCleanupWithContext
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> CleanupNodeExecutionAction
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
resumeDurableCleanupWithContext client owner runAction = go
 where
  go run = case compactCleanupRun run of
    Right report -> pure (Right report)
    Left _ -> case nextPending run of
      Nothing -> pure (Left CleanupRunDriverNoProgress)
      Just plan -> do
        let node = cleanupNodeId plan
        case attemptFor run plan of
          Left err -> pure (Left err)
          Right attempt -> do
            begun <- call (beginCommand run node attempt)
            case begun of
              Left err -> pure (Left err)
              Right running -> do
                outcome <- case executionContextFor running plan attempt of
                  Left detail -> pure (CleanupNodeFailed detail)
                  Right executionContext -> do
                    attempted <-
                      try (runAction executionContext plan)
                        :: IO (Either SomeException CleanupNodeOutcome)
                    case attempted of
                      Left exception
                        | isAsync exception -> throwIO exception
                        | otherwise ->
                            pure
                              (CleanupNodeFailed (Text.pack (displayException exception)))
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
        cleanupDependencyKind dependency /= CleanupRequiresSuccess
      Just (CleanupNodeCompleted _ (CleanupNodeEffectUnconfirmed _)) ->
        cleanupDependencyKind dependency /= CleanupRequiresSuccess
      Just (CleanupNodeBlocked _) ->
        cleanupDependencyKind dependency == CleanupRequiresTerminal
      _ -> False

  executionContextFor run plan attempt = do
    receipts <-
      mapM
        (dependencyReceipt run)
        [ dependency
        | dependency <- cleanupNodeDependencies plan
        , cleanupDependencyKind dependency /= CleanupRequiresTerminal
        ]
    terminalReceipts <-
      mapM
        (terminalDependencyReceipt run)
        [ dependency
        | dependency <- cleanupNodeDependencies plan
        , cleanupDependencyKind dependency == CleanupRequiresTerminal
        ]
    pure
      CleanupNodeExecutionContext
        { cleanupNodeExecutionAttemptId = attempt
        , cleanupNodeExecutionRunId = cleanupRunId run
        , cleanupNodeExecutionGraphDigest = cleanupGraphDigest (cleanupRunGraph run)
        , cleanupNodeExecutionNodeId = cleanupNodeId plan
        , cleanupNodeExecutionDependencyReceipts = receipts
        , cleanupNodeExecutionTerminalDependencyReceipts = terminalReceipts
        }

  dependencyReceipt run dependency = do
    dependencyPlan <-
      maybe
        ( Left
            ( "cleanup dependency is missing from the authoritative graph: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
        )
        Right
        ( find
            ((== cleanupDependencyNode dependency) . cleanupNodeId)
            (cleanupGraphNodes (cleanupRunGraph run))
        )
    (dependencyAttempt, outcome) <-
      case Map.lookup (cleanupDependencyNode dependency) (cleanupRunNodeStates run) of
        Just (CleanupNodeCompleted completedAttempt completed) ->
          Right (completedAttempt, completed)
        _ ->
          Left
            ( "cleanup dependency has no authoritative completed outcome: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
    if dependencyOutcomeSatisfies (cleanupDependencyKind dependency) outcome
      then
        Right
          CleanupDependencyReceipt
            { cleanupDependencyReceiptNodeId = cleanupNodeId dependencyPlan
            , cleanupDependencyReceiptOperationId = cleanupNodeOperationId dependencyPlan
            , cleanupDependencyReceiptAttemptId = dependencyAttempt
            , cleanupDependencyReceiptKind = cleanupDependencyKind dependency
            , cleanupDependencyReceiptOutcome = outcome
            }
      else
        Left
          ( "cleanup dependency outcome does not satisfy its edge: "
              <> cleanupNodeIdText (cleanupDependencyNode dependency)
          )

  terminalDependencyReceipt run dependency = do
    dependencyPlan <-
      maybe
        ( Left
            ( "cleanup terminal dependency is missing from the authoritative graph: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
        )
        Right
        ( find
            ((== cleanupDependencyNode dependency) . cleanupNodeId)
            (cleanupGraphNodes (cleanupRunGraph run))
        )
    terminalResult <-
      case Map.lookup (cleanupDependencyNode dependency) (cleanupRunNodeStates run) of
        Just (CleanupNodeCompleted completedAttempt completed) ->
          Right (CleanupTerminalDependencyCompleted completedAttempt completed)
        Just (CleanupNodeBlocked blockers) ->
          Right (CleanupTerminalDependencyBlocked blockers)
        _ ->
          Left
            ( "cleanup terminal dependency has no authoritative terminal state: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
    Right
      CleanupTerminalDependencyReceipt
        { cleanupTerminalDependencyReceiptNodeId = cleanupNodeId dependencyPlan
        , cleanupTerminalDependencyReceiptOperationId =
            cleanupNodeOperationId dependencyPlan
        , cleanupTerminalDependencyReceiptResult = terminalResult
        }

  dependencyOutcomeSatisfies kind outcome = case outcome of
    CleanupNodeSucceeded -> True
    CleanupNodeFailed _ -> kind == CleanupRequiresAttempt
    CleanupNodeEffectUnconfirmed _ -> kind == CleanupRequiresAttempt

  attemptFor run plan =
    case mkCleanupAttemptId ("cleanup-attempt/" <> attemptDigest) of
      Left detail -> Left (CleanupRunDriverAttemptInvalid detail)
      Right attempt -> Right attempt
   where
    attemptDigest =
      TextEncoding.decodeUtf8
        (hexSha256 (TextEncoding.encodeUtf8 canonicalAttempt))
    canonicalAttempt =
      Text.concat
        ( map
            frame
            [ "cleanup-node-attempt/v2"
            , cleanupRunIdText (cleanupRunId run)
            , cleanupDigestText (cleanupGraphDigest (cleanupRunGraph run))
            , cleanupNodeIdText (cleanupNodeId plan)
            , cleanupOperationIdText (cleanupNodeOperationId plan)
            , Text.pack (show (cleanupLeaseFence (cleanupRunLease run)))
            ]
        )
    frame value = Text.pack (show (Text.length value)) <> ":" <> value

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
claimAndResumeDurableCleanup client owner now expires runAction observed =
  claimAndResumeDurableCleanupWithAttempt
    client
    owner
    now
    expires
    (\_ -> runAction)
    observed

claimAndResumeDurableCleanupWithAttempt
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> CleanupNodeAttemptAction
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
claimAndResumeDurableCleanupWithAttempt client owner now expires runAction observed =
  claimAndResumeDurableCleanupWithContext
    client
    owner
    now
    expires
    (\context -> runAction (cleanupNodeExecutionAttemptId context))
    observed

claimAndResumeDurableCleanupWithContext
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> CleanupNodeExecutionAction
  -> CleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
claimAndResumeDurableCleanupWithContext client owner now expires runAction observed = do
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
    Right (Just run) ->
      resumeDurableCleanupWithContext client owner runAction run

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
recoverNonterminalCleanupRuns client owner now expires runAction =
  recoverNonterminalCleanupRunsWithAttempt
    client
    owner
    now
    expires
    (\_ -> runAction)

recoverNonterminalCleanupRunsWithAttempt
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> CleanupNodeAttemptAction
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
recoverNonterminalCleanupRunsWithAttempt client owner now expires runAction =
  recoverNonterminalCleanupRunsWithContext
    client
    owner
    now
    expires
    (\context -> runAction (cleanupNodeExecutionAttemptId context))

recoverNonterminalCleanupRunsWithContext
  :: CleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> CleanupNodeExecutionAction
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
recoverNonterminalCleanupRunsWithContext client owner now expires runAction = do
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
        claimAndResumeDurableCleanupWithContext
          client
          owner
          now
          expires
          runAction
          run

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

-- | Canonical descriptor-bound creation path. The primary action is not
-- admitted until the Authority has independently read back the committed
-- descriptor, published and read back the descriptor-bound index entry, and
-- independently read back the exact per-run aggregate. Publishing discovery
-- first makes a crash before the primary write repairable by the scan path.
runWithDescriptorBoundDurableCleanupOutcomeWithContext
  :: DescriptorBoundCleanupRunClient IO
  -> CleanupProgramDescriptor
  -> CleanupOwnerId
  -> Int
  -> IO (Either Text value)
  -> DescriptorBoundCleanupNodeExecutionAction
  -> IO (Either CleanupRunDriverError (CleanupRunDriverResult value))
runWithDescriptorBoundDurableCleanupOutcomeWithContext
  client
  descriptor
  owner
  shieldMicros
  primary
  cleanup =
    mask $ \restore -> do
      created <- createDescriptorBoundCleanupRun client descriptor
      case created of
        Left err -> pure (Left (CleanupRunDriverClientFailed err))
        Right committed -> do
          primaryResult <- try (restore primary)
          let outcome = case primaryResult of
                Right (Right _) -> CleanupPrimarySucceeded
                Right (Left detail) -> CleanupPrimaryFailed detail
                Left exception
                  | isAsync exception -> CleanupPrimaryCancelled
                  | otherwise ->
                      CleanupPrimaryFailed (Text.pack (displayException exception))
          recorded <-
            recordDescriptorBoundCleanupPrimary
              client
              committed
              owner
              (cleanupLeaseFence (descriptorBoundCleanupRunLease committed))
              outcome
          driven <- case recorded of
            Left err -> pure (Just (Left (CleanupRunDriverClientFailed err)))
            Right run ->
              timeout
                shieldMicros
                ( resumeDescriptorBoundDurableCleanupWithContext
                    client
                    owner
                    cleanup
                    run
                )
          case (primaryResult, driven) of
            (Left exception, Just (Right report))
              | isAsync exception -> throwIO exception
              | otherwise ->
                  pure (Right (CleanupRunDriverResult Nothing report))
            (_, Nothing) -> pure (Left CleanupRunDriverShieldExpired)
            (_, Just (Left err)) -> pure (Left err)
            (Right (Left _), Just (Right report)) ->
              pure (Right (CleanupRunDriverResult Nothing report))
            (Right (Right value), Just (Right report)) ->
              pure (Right (CleanupRunDriverResult (Just value) report))

resumeDescriptorBoundDurableCleanupWithContext
  :: DescriptorBoundCleanupRunClient IO
  -> CleanupOwnerId
  -> DescriptorBoundCleanupNodeExecutionAction
  -> DescriptorBoundCleanupRun
  -> IO (Either CleanupRunDriverError CleanupRunReport)
resumeDescriptorBoundDurableCleanupWithContext client owner runAction = go
 where
  go bound = case descriptorBoundCleanupRunReport bound of
    Right report -> pure (Right report)
    Left _ -> case nextPending bound of
      Nothing -> pure (Left CleanupRunDriverNoProgress)
      Just plan -> do
        let node = cleanupNodeId plan
        case descriptorAttemptFor bound plan of
          Left err -> pure (Left err)
          Right attempt -> do
            begun <-
              beginDescriptorBoundCleanupNode
                client
                bound
                owner
                (cleanupLeaseFence (descriptorBoundCleanupRunLease bound))
                node
                attempt
            case begun of
              Left err -> pure (Left (CleanupRunDriverClientFailed err))
              Right running -> do
                outcome <- case descriptorExecutionContextFor running plan attempt of
                  Left detail -> pure (CleanupNodeFailed detail)
                  Right executionContext -> do
                    attempted <-
                      try (runAction running executionContext plan)
                        :: IO (Either SomeException CleanupNodeOutcome)
                    case attempted of
                      Left exception
                        | isAsync exception -> throwIO exception
                        | otherwise ->
                            pure
                              (CleanupNodeFailed (Text.pack (displayException exception)))
                      Right value -> pure value
                completed <-
                  completeDescriptorBoundCleanupNode
                    client
                    running
                    owner
                    (cleanupLeaseFence (descriptorBoundCleanupRunLease running))
                    node
                    attempt
                    outcome
                case completed of
                  Left err -> pure (Left (CleanupRunDriverClientFailed err))
                  Right next -> go next

  nextPending bound =
    find
      ( \plan ->
          Map.lookup
            (cleanupNodeId plan)
            (descriptorBoundCleanupRunNodeStates bound)
            == Just CleanupNodePending
            && all
              (descriptorDependencySatisfied bound)
              (cleanupNodeDependencies plan)
      )
      (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound))

descriptorDependencySatisfied
  :: DescriptorBoundCleanupRun -> CleanupDependency -> Bool
descriptorDependencySatisfied bound dependency =
  case Map.lookup
    (cleanupDependencyNode dependency)
    (descriptorBoundCleanupRunNodeStates bound) of
    Just (CleanupNodeCompleted _ CleanupNodeSucceeded) -> True
    Just (CleanupNodeCompleted _ (CleanupNodeFailed _)) ->
      cleanupDependencyKind dependency /= CleanupRequiresSuccess
    Just (CleanupNodeCompleted _ (CleanupNodeEffectUnconfirmed _)) ->
      cleanupDependencyKind dependency /= CleanupRequiresSuccess
    Just (CleanupNodeBlocked _) ->
      cleanupDependencyKind dependency == CleanupRequiresTerminal
    _ -> False

descriptorExecutionContextFor
  :: DescriptorBoundCleanupRun
  -> CleanupNodePlan
  -> CleanupAttemptId
  -> Either Text CleanupNodeExecutionContext
descriptorExecutionContextFor bound plan attempt = do
  receipts <-
    mapM
      descriptorDependencyReceipt
      [ dependency
      | dependency <- cleanupNodeDependencies plan
      , cleanupDependencyKind dependency /= CleanupRequiresTerminal
      ]
  terminalReceipts <-
    mapM
      descriptorTerminalDependencyReceipt
      [ dependency
      | dependency <- cleanupNodeDependencies plan
      , cleanupDependencyKind dependency == CleanupRequiresTerminal
      ]
  Right
    CleanupNodeExecutionContext
      { cleanupNodeExecutionAttemptId = attempt
      , cleanupNodeExecutionRunId = descriptorBoundCleanupRunId bound
      , cleanupNodeExecutionGraphDigest = descriptorBoundCleanupRunGraphDigest bound
      , cleanupNodeExecutionNodeId = cleanupNodeId plan
      , cleanupNodeExecutionDependencyReceipts = receipts
      , cleanupNodeExecutionTerminalDependencyReceipts = terminalReceipts
      }
 where
  graphPlans = cleanupGraphNodes (descriptorBoundCleanupRunGraph bound)
  states = descriptorBoundCleanupRunNodeStates bound

  planFor label dependency =
    maybe
      ( Left
          ( label
              <> cleanupNodeIdText (cleanupDependencyNode dependency)
          )
      )
      Right
      (find ((== cleanupDependencyNode dependency) . cleanupNodeId) graphPlans)

  descriptorDependencyReceipt dependency = do
    dependencyPlan <-
      planFor
        "cleanup dependency is missing from the descriptor-bound graph: "
        dependency
    (dependencyAttempt, outcome) <-
      case Map.lookup (cleanupDependencyNode dependency) states of
        Just (CleanupNodeCompleted completedAttempt completed) ->
          Right (completedAttempt, completed)
        _ ->
          Left
            ( "cleanup dependency has no descriptor-bound completed outcome: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
    if dependencyOutcomeSatisfies (cleanupDependencyKind dependency) outcome
      then
        Right
          CleanupDependencyReceipt
            { cleanupDependencyReceiptNodeId = cleanupNodeId dependencyPlan
            , cleanupDependencyReceiptOperationId =
                cleanupNodeOperationId dependencyPlan
            , cleanupDependencyReceiptAttemptId = dependencyAttempt
            , cleanupDependencyReceiptKind = cleanupDependencyKind dependency
            , cleanupDependencyReceiptOutcome = outcome
            }
      else
        Left
          ( "cleanup dependency outcome does not satisfy its edge: "
              <> cleanupNodeIdText (cleanupDependencyNode dependency)
          )

  descriptorTerminalDependencyReceipt dependency = do
    dependencyPlan <-
      planFor
        "cleanup terminal dependency is missing from the descriptor-bound graph: "
        dependency
    terminalResult <-
      case Map.lookup (cleanupDependencyNode dependency) states of
        Just (CleanupNodeCompleted completedAttempt completed) ->
          Right (CleanupTerminalDependencyCompleted completedAttempt completed)
        Just (CleanupNodeBlocked blockers) ->
          Right (CleanupTerminalDependencyBlocked blockers)
        _ ->
          Left
            ( "cleanup terminal dependency has no descriptor-bound terminal state: "
                <> cleanupNodeIdText (cleanupDependencyNode dependency)
            )
    Right
      CleanupTerminalDependencyReceipt
        { cleanupTerminalDependencyReceiptNodeId = cleanupNodeId dependencyPlan
        , cleanupTerminalDependencyReceiptOperationId =
            cleanupNodeOperationId dependencyPlan
        , cleanupTerminalDependencyReceiptResult = terminalResult
        }

  dependencyOutcomeSatisfies kind outcome = case outcome of
    CleanupNodeSucceeded -> True
    CleanupNodeFailed _ -> kind == CleanupRequiresAttempt
    CleanupNodeEffectUnconfirmed _ -> kind == CleanupRequiresAttempt

descriptorAttemptFor
  :: DescriptorBoundCleanupRun
  -> CleanupNodePlan
  -> Either CleanupRunDriverError CleanupAttemptId
descriptorAttemptFor bound plan =
  case mkCleanupAttemptId ("cleanup-attempt/" <> attemptDigest) of
    Left detail -> Left (CleanupRunDriverAttemptInvalid detail)
    Right attempt -> Right attempt
 where
  attemptDigest =
    TextEncoding.decodeUtf8
      (hexSha256 (TextEncoding.encodeUtf8 canonicalAttempt))
  canonicalAttempt =
    Text.concat
      ( map
          frame
          [ "cleanup-node-attempt/v3"
          , cleanupRunIdText (descriptorBoundCleanupRunId bound)
          , cleanupDigestText (descriptorBoundCleanupRunGraphDigest bound)
          , cleanupDigestText (descriptorBoundCleanupRunDescriptorDigest bound)
          , cleanupNodeIdText (cleanupNodeId plan)
          , cleanupOperationIdText (cleanupNodeOperationId plan)
          , Text.pack
              ( show
                  (cleanupLeaseFence (descriptorBoundCleanupRunLease bound))
              )
          ]
      )
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

recoverDescriptorBoundCleanupRunsWithContext
  :: DescriptorBoundCleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> DescriptorBoundCleanupNodeExecutionAction
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
recoverDescriptorBoundCleanupRunsWithContext client owner now expires runAction = do
  scanned <- scanDescriptorBoundCleanupRuns client
  case scanned of
    Left err -> pure (Left [CleanupRunDriverClientFailed err])
    Right runs -> do
      recovered <- mapM recover runs
      let (failures, reports) = partitionEithers recovered
      pure $ if null failures then Right reports else Left failures
 where
  recover observed = do
    claimed <-
      claimDescriptorBoundCleanupRun client observed owner now expires
    case claimed of
      Left err -> pure (Left (CleanupRunDriverClientFailed err))
      Right run ->
        resumeDescriptorBoundDurableCleanupWithContext
          client
          owner
          runAction
          run

compactDescriptorBoundCleanupRuns
  :: DescriptorBoundCleanupRunClient IO
  -> Natural
  -> Natural
  -> IO (Either [CleanupRunDriverError] [CleanupRunReport])
compactDescriptorBoundCleanupRuns client now retention = do
  scanned <- scanDescriptorBoundCleanupRuns client
  case scanned of
    Left err -> pure (Left [CleanupRunDriverClientFailed err])
    Right runs -> do
      attempted <- mapM compactIfTerminal runs
      let (failures, reports) = partitionEithers attempted
      pure $
        if null failures
          then Right (catMaybes reports)
          else Left failures
 where
  compactIfTerminal run
    | not (descriptorBoundCleanupRunTerminal run) = pure (Right Nothing)
    | otherwise = do
        compacted <-
          compactDescriptorBoundCleanupRun client run now retention
        pure $ case compacted of
          Left err -> Left (CleanupRunDriverClientFailed err)
          Right report -> Right (Just report)

isAsync :: SomeException -> Bool
isAsync exception = case fromException exception :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False
