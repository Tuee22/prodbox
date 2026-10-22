{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Next-bootstrap import of historical local completion. No provider effect
-- runs here. A separately authenticated final read precedes intent retirement.
module Prodbox.Lifecycle.HostCleanupHistoryReconcile
  ( HistoricalCleanupImportError (..)
  , ReconciledHostCleanupHistory
  , reconciledHostCleanupReport
  , reconcileHistoricalHostCleanup
  ) where

import Control.Monad (foldM, unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.HostCleanupCompletion
import Prodbox.Lifecycle.HostCleanupIntent

data ReconciledHostCleanupHistory = ReconciledHostCleanupHistory
  {reconciledHostCleanupReport :: CleanupRunReport}

data HistoricalCleanupImportError
  = HistoricalCleanupAuthorityReadFailed CleanupRunClientError
  | HistoricalCleanupClaimUnconfirmed (Maybe CleanupRunClientError)
  | HistoricalCleanupBindingConflict
  | HistoricalCleanupNodeConflict CleanupNodeId
  | HistoricalCleanupTransitionUnconfirmed CleanupNodeId (Maybe CleanupRunClientError)
  | HistoricalCleanupFinalReportMismatch
  | HistoricalCleanupIntentNoLongerExact
  | HistoricalCleanupIntentRetirementFailed HostCleanupIntentError
  | HistoricalCleanupIdentityInvalid Text
  deriving (Eq, Show)

type Import = ExceptT HistoricalCleanupImportError IO

reconcileHistoricalHostCleanup
  :: DescriptorBoundCleanupRunClient IO
  -> HostCleanupIntentStore
  -> Natural
  -> HistoricalHostCleanupCompletion
  -> IO (Either HistoricalCleanupImportError ReconciledHostCleanupHistory)
reconcileHistoricalHostCleanup client store now history = runExceptT $ do
  owner <- either (throwE . HistoricalCleanupIdentityInvalid) pure (mkCleanupOwnerId ownerText)
  first <- observeHistory
  final <- case first of
    Left report -> pure (Left report)
    Right bound -> do
      validate bound
      if descriptorBoundCleanupRunTerminal bound
        then pure (Right bound)
        else do
          claimAnswer <-
            liftImport (claimDescriptorBoundCleanupRun client bound owner now (now + 240_000_000))
          claimed <- observe
          validate claimed
          let lease = descriptorBoundCleanupRunLease claimed
          unless
            (cleanupLeaseOwner lease == owner && cleanupLeaseExpiresAtMicros lease > now)
            (throwE (HistoricalCleanupClaimUnconfirmed (failure claimAnswer)))
          Right <$> foldM (importNode owner (cleanupLeaseFence lease)) claimed localPlans
  confirmReport final
  -- The effect replies above do not license retirement. Read the complete
  -- Authority aggregate independently and compare the exact historical report.
  independentlyObserved <- observeHistory
  confirmReport independentlyObserved
  current <- liftImport (observeHostCleanupIntentForResume store)
  case current of
    Right (Just exact) | observedHostCleanupIntent exact == intent -> pure ()
    Right Nothing | historicalHostCleanupIntentRetired history -> pure ()
    _ -> throwE HistoricalCleanupIntentNoLongerExact
  receipt <-
    maybe (throwE HistoricalCleanupFinalReportMismatch) pure (hostCleanupCompletionReceiptDigest intent)
  retired <- liftImport (retireHostCleanupIntent store intent receipt)
  either
    (throwE . HistoricalCleanupIntentRetirementFailed)
    (const (pure (ReconciledHostCleanupHistory expected)))
    retired
 where
  intent = historicalHostCleanupIntent history
  handoff = historicalHostCleanupHandoff history
  prefix = hostCleanupTerminalHandoffPrefix handoff
  expected = historicalHostCleanupReport history
  runId = hostCleanupRunId intent
  localPlans =
    [ plan
    | plan <- cleanupGraphNodes (cleanupRunGraph prefix)
    , Map.lookup (cleanupNodeId plan) (cleanupRunNodeStates prefix) == Just CleanupNodePending
    ]
  localIds = map cleanupNodeId localPlans
  ownerText =
    "cascade-history/"
      <> Text.take
        32
        (cleanupDigestText (cleanupDigestOfBytes (TextEncoding.encodeUtf8 (cleanupRunIdText runId))))
  observe = do
    result <- liftImport (observeDescriptorBoundCleanupRun client runId)
    either (throwE . HistoricalCleanupAuthorityReadFailed) pure result
  observeHistory = do
    result <- liftImport (observeDescriptorBoundCleanupRun client runId)
    case result of
      Right bound -> pure (Right bound)
      Left (CleanupRunClientDescriptorTombstoned digest _)
        | digest == hostCleanupTerminalHandoffDescriptorDigest handoff -> do
            completion <- liftImport (observeDescriptorBoundCleanupRunCompletion client runId digest)
            report <- either (throwE . HistoricalCleanupAuthorityReadFailed) pure completion
            maybe (throwE HistoricalCleanupFinalReportMismatch) (pure . Left) report
      Left cause -> throwE (HistoricalCleanupAuthorityReadFailed cause)
  confirmReport observed = do
    report <- case observed of
      Left report -> pure report
      Right bound -> do
        validate bound
        either
          (const (throwE HistoricalCleanupFinalReportMismatch))
          pure
          (descriptorBoundCleanupRunReport bound)
    unless (report == expected) (throwE HistoricalCleanupFinalReportMismatch)
  validate bound = do
    unless
      ( descriptorBoundCleanupRunId bound == runId
          && descriptorBoundCleanupRunDescriptorDigest bound
            == hostCleanupTerminalHandoffDescriptorDigest handoff
          && descriptorBoundCleanupRunGraphDigest bound == hostCleanupGraphDigest intent
          && descriptorBoundCleanupRunGraph bound == cleanupRunGraph prefix
          && descriptorBoundCleanupRunPrimaryOutcome bound == Just (cleanupReportPrimaryOutcome expected)
          && Map.keys (descriptorBoundCleanupRunNodeStates bound) == Map.keys (cleanupReportNodeStates expected)
      )
      (throwE HistoricalCleanupBindingConflict)
    mapM_
      ( \(node, state) ->
          unless
            (node `elem` localIds || Map.lookup node (descriptorBoundCleanupRunNodeStates bound) == Just state)
            (throwE (HistoricalCleanupNodeConflict node))
      )
      (Map.toList (cleanupRunNodeStates prefix))
  importNode owner fence bound plan = do
    let node = cleanupNodeId plan
        state = Map.lookup node (cleanupReportNodeStates expected)
        current = Map.lookup node (descriptorBoundCleanupRunNodeStates bound)
    unless
      ( cleanupLeaseOwner (descriptorBoundCleanupRunLease bound) == owner
          && cleanupLeaseFence (descriptorBoundCleanupRunLease bound) == fence
      )
      (throwE HistoricalCleanupBindingConflict)
    case state of
      Just target@(CleanupNodeCompleted attempt CleanupNodeSucceeded)
        | current == Just target -> pure bound
        | current == Just CleanupNodePending || current == Just (CleanupNodeRunning attempt) -> do
            answer <- liftImport (beginDescriptorBoundCleanupNode client bound owner fence node attempt)
            begun <- observe
            validate begun
            case Map.lookup node (descriptorBoundCleanupRunNodeStates begun) of
              Just observed | observed == target -> pure begun
              Just (CleanupNodeRunning observedAttempt) | observedAttempt == attempt -> do
                completed <-
                  liftImport
                    (completeDescriptorBoundCleanupNode client begun owner fence node attempt CleanupNodeSucceeded)
                readBack <- observe
                validate readBack
                unless
                  (Map.lookup node (descriptorBoundCleanupRunNodeStates readBack) == Just target)
                  (throwE (HistoricalCleanupTransitionUnconfirmed node (failure completed)))
                pure readBack
              _ -> throwE (HistoricalCleanupTransitionUnconfirmed node (failure answer))
      _ -> throwE (HistoricalCleanupNodeConflict node)

liftImport :: IO value -> Import value
liftImport = ExceptT . fmap Right
failure :: Either cause value -> Maybe cause
failure result = case result of
  Left cause -> Just cause
  Right _ -> Nothing
