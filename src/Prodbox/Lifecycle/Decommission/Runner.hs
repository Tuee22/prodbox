{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: receipt-driven decommission orchestration.
--
-- Recovery keeps the complete attempt state rather than reducing history to a
-- list of completed nodes.  A durable intent without a terminal result is first
-- re-observed under its recorded node/attempt IDs.  Positive absence closes it
-- without another mutation; presence permits retry of that same attempt; an
-- unavailable authority leaves it pending and refuses to mutate.
module Prodbox.Lifecycle.Decommission.Runner
  ( NodeResultStatus (..)
  , DecommissionEntry (..)
  , DecommissionAttempt (..)
  , ReceiptSemanticError (..)
  , DecommissionResume
  , emptyDecommissionResume
  , validateReceiptSemantics
  , completedNodes
  , pendingAttempt
  , DecommissionRunError (..)
  , BoundDecommissionRunError (..)
  , runDecommission
  , runDecommissionDurable
  , runBoundDecommission
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (foldM)
import Data.Either (fromLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame
  ( DecommissionFrame
  , FrameAttemptId
  , FrameNodeId
  , appendPayload
  , frameAttemptId
  , frameIndex
  , frameNodeId
  , framePayload
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( DecommissionReport (DecommissionReport)
  , NodeExecution (NodeExecution)
  , NodeVerdict (NodeBlocked, NodeFailed, NodeSucceeded)
  , decommissionRequiredPredecessors
  , decommissionTopologicalOrder
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode
  , VerifiedDecommissionManifest
  , decommissionNodeFrameId
  , manifestNodes
  , verifiedManifestDigest
  , verifiedManifestPlan
  , verifiedVerifierBinding
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( DecommissionNodeInterpreter
  , NodeObservation (NodeObservationUnavailable, NodeObservedAbsent, NodeObservedPresent)
  , classifyNodeObservation
  , destroyDecommissionNode
  , observeDecommissionNode
  )
import Prodbox.Lifecycle.Decommission.Permit
  ( DecommissionPreflightError
  , bindDecommissionPreflight
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( AcknowledgedExternalReceipt
  , BoundReceiptRefusal
  , BoundReceiptReopen (boundReopenFrames)
  , acknowledgedExternalReceiptHeader
  , acknowledgedExternalReceiptPath
  , appendBoundReceiptFrame
  , mkReceiptHeader
  , reopenBoundReceipt
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierBinding
  , VerifierPreflightRefusal
  , VerifierPreflightResult (VerifierReady, VerifierRefused)
  , decidePinnedArtifactExecution
  , externalReceiptPath
  , runVerifierPreflight
  )

-- | The outcome a terminal result frame records for a node attempt.
data NodeResultStatus
  = NodeDestroyed
  | NodeDestroyFailed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Typed receipt payload.  Observation is a first-class frame: a successful
-- result without a preceding positive-absence observation is semantically
-- invalid even if its CBOR/checksum/hash chain is structurally valid.
data DecommissionEntry
  = DecommissionIntent !DecommissionNode
  | DecommissionObservation !DecommissionNode !NodeObservation
  | DecommissionNodeResult !DecommissionNode !NodeResultStatus
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Stable identity supplied to every journal, observation, and destroy effect.
data DecommissionAttempt = DecommissionAttempt
  { decommissionAttemptNode :: !DecommissionNode
  , decommissionAttemptNodeId :: !FrameNodeId
  , decommissionAttemptId :: !FrameAttemptId
  }
  deriving stock (Eq, Show)

-- | A structurally valid receipt can still contradict the runner state machine.
-- These defects are committed-history refusals; none can be repaired by dropping
-- a complete frame.
data ReceiptSemanticError
  = ReceiptNodeIdMismatch !Word !FrameNodeId !FrameNodeId
  | ReceiptNodeIdConflict !Word !FrameNodeId !DecommissionNode !DecommissionNode
  | ReceiptAttemptIdConflict !Word !FrameAttemptId !DecommissionNode !DecommissionNode
  | ReceiptAttemptIdReused !Word !FrameAttemptId
  | ReceiptEntryWithoutIntent !Word !FrameAttemptId
  | ReceiptConcurrentAttempt !Word !DecommissionNode
  | ReceiptAttemptAfterSuccess !Word !DecommissionNode
  | ReceiptEntryAfterResult !Word !FrameAttemptId
  | ReceiptSuccessWithoutAbsentObservation !Word !FrameAttemptId
  | ReceiptFailureAfterAbsentObservation !Word !FrameAttemptId
  | ReceiptFailureAfterUnavailableObservation !Word !FrameAttemptId
  deriving stock (Eq, Show)

data NodeResumeState
  = ResumePending !DecommissionAttempt
  | ResumeFailed
  | ResumeCompleted
  deriving stock (Eq, Show)

-- | Opaque, semantically validated state reconstructed from receipt frames.
data DecommissionResume = DecommissionResume
  { resumeNodeStates :: !(Map DecommissionNode NodeResumeState)
  , resumeAttemptOwners :: !(Map FrameAttemptId DecommissionNode)
  }
  deriving stock (Eq, Show)

emptyDecommissionResume :: DecommissionResume
emptyDecommissionResume = DecommissionResume Map.empty Map.empty

data AttemptLedger
  = AttemptOpen !DecommissionAttempt !(Maybe NodeObservation)
  | AttemptClosed !DecommissionAttempt !NodeResultStatus
  deriving stock (Eq, Show)

data SemanticFold = SemanticFold
  { semanticNodeOwners :: !(Map FrameNodeId DecommissionNode)
  , semanticAttempts :: !(Map FrameAttemptId AttemptLedger)
  , semanticNodes :: !(Map DecommissionNode NodeResumeState)
  }

-- | Validate the runner-level meaning of an already structurally recovered
-- frame chain.  IDs must bind one exact node, an attempt starts with exactly one
-- intent, terminal attempts cannot be reused, only observed absence can support
-- success, and an unavailable observation cannot be closed as an ordinary
-- failure (which would otherwise permit a blind fresh retry).
validateReceiptSemantics
  :: [DecommissionFrame DecommissionEntry]
  -> Either ReceiptSemanticError DecommissionResume
validateReceiptSemantics frames = toResume <$> foldM validateFrame initial frames
 where
  initial = SemanticFold Map.empty Map.empty Map.empty
  toResume state =
    DecommissionResume
      { resumeNodeStates = semanticNodes state
      , resumeAttemptOwners =
          Map.map (decommissionAttemptNode . ledgerAttempt) (semanticAttempts state)
      }

validateFrame
  :: SemanticFold
  -> DecommissionFrame DecommissionEntry
  -> Either ReceiptSemanticError SemanticFold
validateFrame state frame
  | actualNodeId /= expectedNodeId =
      Left (ReceiptNodeIdMismatch index expectedNodeId actualNodeId)
  | Just priorNode <- Map.lookup actualNodeId (semanticNodeOwners state)
  , priorNode /= node =
      Left (ReceiptNodeIdConflict index actualNodeId priorNode node)
  | Just priorAttempt <- Map.lookup attemptId (semanticAttempts state)
  , decommissionAttemptNode (ledgerAttempt priorAttempt) /= node =
      Left
        ( ReceiptAttemptIdConflict
            index
            attemptId
            (decommissionAttemptNode (ledgerAttempt priorAttempt))
            node
        )
  | otherwise =
      validateEntry
        state
          { semanticNodeOwners = Map.insert actualNodeId node (semanticNodeOwners state)
          }
        frame
 where
  entry = framePayload frame
  node = entryNode entry
  index = frameIndex frame
  actualNodeId = frameNodeId frame
  expectedNodeId = decommissionNodeFrameId node
  attemptId = frameAttemptId frame

validateEntry
  :: SemanticFold
  -> DecommissionFrame DecommissionEntry
  -> Either ReceiptSemanticError SemanticFold
validateEntry state frame = case framePayload frame of
  DecommissionIntent node -> validateIntent state frame node
  DecommissionObservation _ observation -> validateObservation state frame observation
  DecommissionNodeResult _ result -> validateResult state frame result

validateIntent
  :: SemanticFold
  -> DecommissionFrame DecommissionEntry
  -> DecommissionNode
  -> Either ReceiptSemanticError SemanticFold
validateIntent state frame node =
  case Map.lookup attemptId (semanticAttempts state) of
    Just _ -> Left (ReceiptAttemptIdReused index attemptId)
    Nothing -> case Map.lookup node (semanticNodes state) of
      Just (ResumePending _) -> Left (ReceiptConcurrentAttempt index node)
      Just ResumeCompleted -> Left (ReceiptAttemptAfterSuccess index node)
      _ ->
        Right
          state
            { semanticAttempts =
                Map.insert attemptId (AttemptOpen attempt Nothing) (semanticAttempts state)
            , semanticNodes = Map.insert node (ResumePending attempt) (semanticNodes state)
            }
 where
  index = frameIndex frame
  attemptId = frameAttemptId frame
  attempt =
    DecommissionAttempt
      { decommissionAttemptNode = node
      , decommissionAttemptNodeId = frameNodeId frame
      , decommissionAttemptId = attemptId
      }

validateObservation
  :: SemanticFold
  -> DecommissionFrame DecommissionEntry
  -> NodeObservation
  -> Either ReceiptSemanticError SemanticFold
validateObservation state frame observation =
  case Map.lookup attemptId (semanticAttempts state) of
    Nothing -> Left (ReceiptEntryWithoutIntent index attemptId)
    Just (AttemptClosed _ _) -> Left (ReceiptEntryAfterResult index attemptId)
    Just (AttemptOpen attempt _) ->
      Right
        state
          { semanticAttempts =
              Map.insert attemptId (AttemptOpen attempt (Just observation)) (semanticAttempts state)
          }
 where
  index = frameIndex frame
  attemptId = frameAttemptId frame

validateResult
  :: SemanticFold
  -> DecommissionFrame DecommissionEntry
  -> NodeResultStatus
  -> Either ReceiptSemanticError SemanticFold
validateResult state frame result =
  case Map.lookup attemptId (semanticAttempts state) of
    Nothing -> Left (ReceiptEntryWithoutIntent index attemptId)
    Just (AttemptClosed _ _) -> Left (ReceiptEntryAfterResult index attemptId)
    Just (AttemptOpen attempt observation) -> do
      validateTerminalObservation index attemptId observation result
      let nextNodeState = case result of
            NodeDestroyed -> ResumeCompleted
            NodeDestroyFailed _ -> ResumeFailed
      Right
        state
          { semanticAttempts =
              Map.insert attemptId (AttemptClosed attempt result) (semanticAttempts state)
          , semanticNodes =
              Map.insert (decommissionAttemptNode attempt) nextNodeState (semanticNodes state)
          }
 where
  index = frameIndex frame
  attemptId = frameAttemptId frame

validateTerminalObservation
  :: Word
  -> FrameAttemptId
  -> Maybe NodeObservation
  -> NodeResultStatus
  -> Either ReceiptSemanticError ()
validateTerminalObservation index attemptId observation result = case (result, observation) of
  (NodeDestroyed, Just NodeObservedAbsent) -> Right ()
  (NodeDestroyed, _) -> Left (ReceiptSuccessWithoutAbsentObservation index attemptId)
  (NodeDestroyFailed _, Just NodeObservedAbsent) ->
    Left (ReceiptFailureAfterAbsentObservation index attemptId)
  (NodeDestroyFailed _, Just (NodeObservationUnavailable _)) ->
    Left (ReceiptFailureAfterUnavailableObservation index attemptId)
  (NodeDestroyFailed _, _) -> Right ()

ledgerAttempt :: AttemptLedger -> DecommissionAttempt
ledgerAttempt ledger = case ledger of
  AttemptOpen attempt _ -> attempt
  AttemptClosed attempt _ -> attempt

entryNode :: DecommissionEntry -> DecommissionNode
entryNode entry = case entry of
  DecommissionIntent node -> node
  DecommissionObservation node _ -> node
  DecommissionNodeResult node _ -> node

completedNodes :: DecommissionResume -> [DecommissionNode]
completedNodes resume =
  [node | (node, ResumeCompleted) <- Map.toAscList (resumeNodeStates resume)]

pendingAttempt :: DecommissionResume -> DecommissionNode -> Maybe DecommissionAttempt
pendingAttempt resume node = case Map.lookup node (resumeNodeStates resume) of
  Just (ResumePending attempt) -> Just attempt
  _ -> Nothing

-- | Run-plan failures are detected before the first new intent/effect.  A fresh
-- attempt ID may not collide with any prior receipt attempt or another planned
-- node, and recovered nodes must belong to this exact manifest inventory.
data DecommissionRunError
  = RunReceiptNodeOutsideInventory !DecommissionNode
  | RunAttemptIdReused !FrameAttemptId !DecommissionNode !DecommissionNode
  | RunReceiptAppendFailed !DecommissionNode !FrameAttemptId !Text
  deriving stock (Eq, Show)

data BoundDecommissionRunError
  = BoundRunReceiptAcknowledgementDrift
  | BoundRunVerifierRefused !VerifierPreflightRefusal
  | BoundRunPreflightRefused !DecommissionPreflightError
  | BoundRunReceiptRefused !BoundReceiptRefusal
  | BoundRunReceiptSemanticsRefused !ReceiptSemanticError
  | BoundRunExecutionRefused !DecommissionRunError
  deriving stock (Eq, Show)

-- | Drive a fresh or resumed run.  The supplied ID function is consulted only
-- for nodes with no pending attempt; all such IDs are validated up front.  The
-- journal/observe/destroy callbacks receive a 'DecommissionAttempt', ensuring the
-- persisted stable identity reaches every effect boundary.
runDecommission
  :: (Monad m)
  => [DecommissionNode]
  -> DecommissionResume
  -> (DecommissionNode -> FrameAttemptId)
  -> (DecommissionAttempt -> DecommissionEntry -> m ())
  -> (DecommissionAttempt -> m NodeObservation)
  -> (DecommissionAttempt -> m (Either Text ()))
  -> m (Either DecommissionRunError DecommissionReport)
runDecommission allNodes resume freshAttemptIdFor record observe destroy =
  runDecommissionDurable
    allNodes
    resume
    freshAttemptIdFor
    (\attempt entry -> record attempt entry >> pure (Right ()))
    observe
    destroy

-- | Production runner variant whose durable-record callback can refuse.  No
-- external mutation is attempted unless its intent append succeeded; an
-- observation/result append failure stops the run with the stable attempt still
-- recoverable from the previously committed intent.
runDecommissionDurable
  :: (Monad m)
  => [DecommissionNode]
  -> DecommissionResume
  -> (DecommissionNode -> FrameAttemptId)
  -> (DecommissionAttempt -> DecommissionEntry -> m (Either Text ()))
  -> (DecommissionAttempt -> m NodeObservation)
  -> (DecommissionAttempt -> m (Either Text ()))
  -> m (Either DecommissionRunError DecommissionReport)
runDecommissionDurable allNodes resume freshAttemptIdFor record observe destroy =
  case prepareAttempts allNodes resume freshAttemptIdFor of
    Left err -> pure (Left err)
    Right freshAttempts -> execute freshAttempts
 where
  execute freshAttempts = do
    result <-
      foldM
        (step freshAttempts)
        (Right (Map.empty, []))
        (decommissionTopologicalOrder allNodes)
    pure $ case result of
      Left err -> Left err
      Right (_, executions) -> Right (DecommissionReport (reverse executions))

  step _ failed@(Left _) _ = pure failed
  step freshAttempts (Right (verdicts, executions)) node = do
    verdictResult <- decideNode freshAttempts verdicts node
    pure $ case verdictResult of
      Left err -> Left err
      Right verdict ->
        Right
          ( Map.insert node verdict verdicts
          , NodeExecution node verdict : executions
          )

  decideNode freshAttempts verdicts node
    | node `elem` completedNodes resume = pure (Right NodeSucceeded)
    | not (null (unmetPredecessors verdicts node)) =
        pure (Right (NodeBlocked (unmetPredecessors verdicts node)))
    | Just attempt <- pendingAttempt resume node = resumeAttempt attempt
    | Just attempt <- Map.lookup node freshAttempts = freshAttempt attempt
    | otherwise = pure (Right (NodeFailed "decommission attempt plan omitted a runnable node"))

  freshAttempt attempt = do
    recorded <- recordEntry attempt (DecommissionIntent (decommissionAttemptNode attempt))
    case recorded of
      Left err -> pure (Left err)
      Right () -> destroyThenObserve attempt

  resumeAttempt attempt = do
    observation <- observe attempt
    recorded <-
      recordEntry attempt (DecommissionObservation (decommissionAttemptNode attempt) observation)
    case recorded of
      Left err -> pure (Left err)
      Right () -> case observation of
        NodeObservedAbsent -> closeSucceeded attempt
        NodeObservedPresent _ -> destroyThenObserve attempt
        NodeObservationUnavailable detail -> pure (Right (NodeFailed (observationFailure detail)))

  destroyThenObserve attempt = do
    destroyed <- destroy attempt
    case destroyed of
      Left detail -> closeFailed attempt detail
      Right () -> do
        observation <- observe attempt
        recorded <-
          recordEntry attempt (DecommissionObservation (decommissionAttemptNode attempt) observation)
        case recorded of
          Left err -> pure (Left err)
          Right () -> case observation of
            NodeObservedAbsent -> closeSucceeded attempt
            NodeObservedPresent detail -> closeFailed attempt (observationFailure detail)
            NodeObservationUnavailable detail ->
              pure (Right (NodeFailed (observationFailure detail)))

  closeSucceeded attempt = do
    recorded <-
      recordEntry attempt (DecommissionNodeResult (decommissionAttemptNode attempt) NodeDestroyed)
    pure (NodeSucceeded <$ recorded)

  closeFailed attempt detail = do
    recorded <-
      recordEntry
        attempt
        (DecommissionNodeResult (decommissionAttemptNode attempt) (NodeDestroyFailed detail))
    pure (NodeFailed detail <$ recorded)

  recordEntry attempt entry = do
    result <- record attempt entry
    pure $ case result of
      Left detail ->
        Left
          ( RunReceiptAppendFailed
              (decommissionAttemptNode attempt)
              (decommissionAttemptId attempt)
              detail
          )
      Right () -> Right ()

  observationFailure detail =
    fromLeft
      "read-back unexpectedly classified as absent"
      (classifyNodeObservation (NodeObservedPresent detail))

  unmetPredecessors verdicts node =
    filter (not . succeededIn verdicts) (decommissionRequiredPredecessors allNodes node)

  succeededIn verdicts node = Map.lookup node verdicts == Just NodeSucceeded

-- | Production composition for one fresh or resumed invocation.  It always
-- reopens the exact artifact bound by the authenticated manifest, refuses a
-- different running build, authenticates and structurally recovers the bound
-- receipt, validates its semantic node/attempt state, and only then delegates to
-- the failure-aware runner.  Every newly produced frame goes through the
-- full-chain fsync/read-back append primitive.
runBoundDecommission
  :: Int
  -> VerifiedDecommissionManifest
  -> VerifierBinding
  -> AcknowledgedExternalReceipt
  -> (DecommissionNode -> FrameAttemptId)
  -> DecommissionNodeInterpreter IO
  -> IO (Either BoundDecommissionRunError DecommissionReport)
runBoundDecommission maximumFrameBytes verified runningIdentity acknowledged freshAttemptIdFor interpreter
  | acknowledgedExternalReceiptHeader acknowledged /= mkReceiptHeader verified =
      pure (Left BoundRunReceiptAcknowledgementDrift)
  | otherwise = do
      verifierResult <- runVerifierPreflight (verifiedVerifierBinding verified)
      case verifierResult of
        VerifierRefused refusal -> pure (Left (BoundRunVerifierRefused refusal))
        VerifierReady preflighted ->
          case bindDecommissionPreflight
            verified
            preflighted
            (decidePinnedArtifactExecution preflighted runningIdentity) of
            Left refusal -> pure (Left (BoundRunPreflightRefused refusal))
            Right _ -> reopenAndRun
 where
  receiptPath = externalReceiptPath (acknowledgedExternalReceiptPath acknowledged)

  reopenAndRun = do
    reopened <- reopenBoundReceipt maximumFrameBytes verified receiptPath
    case reopened of
      Left refusal -> pure (Left (BoundRunReceiptRefused refusal))
      Right receipt -> case validateReceiptSemantics (boundReopenFrames receipt) of
        Left refusal -> pure (Left (BoundRunReceiptSemanticsRefused refusal))
        Right resume -> do
          previousRef <- newIORef (lastMaybe (boundReopenFrames receipt))
          result <-
            runDecommissionDurable
              (manifestNodes (verifiedManifestPlan verified))
              resume
              freshAttemptIdFor
              (appendEntry previousRef)
              observeAttempt
              destroyAttempt
          pure (either (Left . BoundRunExecutionRefused) Right result)

  appendEntry previousRef attempt entry = do
    previous <- readIORef previousRef
    let frame =
          appendPayload
            (verifiedManifestDigest verified)
            previous
            (decommissionAttemptNodeId attempt)
            (decommissionAttemptId attempt)
            entry
    appended <- appendBoundReceiptFrame maximumFrameBytes verified receiptPath frame
    case appended of
      Left refusal -> pure (Left (Text.pack (show refusal)))
      Right _ -> writeIORef previousRef (Just frame) >> pure (Right ())

  observeAttempt attempt =
    observeDecommissionNode
      interpreter
      (decommissionAttemptNode attempt)
      (decommissionAttemptNodeId attempt)
      (decommissionAttemptId attempt)

  destroyAttempt attempt =
    destroyDecommissionNode
      interpreter
      (decommissionAttemptNode attempt)
      (decommissionAttemptNodeId attempt)
      (decommissionAttemptId attempt)

lastMaybe :: [value] -> Maybe value
lastMaybe [] = Nothing
lastMaybe values = Just (last values)

prepareAttempts
  :: [DecommissionNode]
  -> DecommissionResume
  -> (DecommissionNode -> FrameAttemptId)
  -> Either DecommissionRunError (Map DecommissionNode DecommissionAttempt)
prepareAttempts allNodes resume freshAttemptIdFor = do
  case find (`notElem` allNodes) (Map.keys (resumeNodeStates resume)) of
    Just outside -> Left (RunReceiptNodeOutsideInventory outside)
    Nothing -> pure ()
  fst <$> foldM addFresh (Map.empty, resumeAttemptOwners resume) freshNodes
 where
  freshNodes =
    filter needsFreshAttempt (decommissionTopologicalOrder allNodes)
  needsFreshAttempt node = case Map.lookup node (resumeNodeStates resume) of
    Just (ResumePending _) -> False
    Just ResumeCompleted -> False
    _ -> True
  addFresh (planned, owners) node =
    let attemptId = freshAttemptIdFor node
     in case Map.lookup attemptId owners of
          Just priorNode -> Left (RunAttemptIdReused attemptId priorNode node)
          Nothing ->
            let attempt =
                  DecommissionAttempt
                    { decommissionAttemptNode = node
                    , decommissionAttemptNodeId = decommissionNodeFrameId node
                    , decommissionAttemptId = attemptId
                    }
             in Right
                  ( Map.insert node attempt planned
                  , Map.insert attemptId node owners
                  )
