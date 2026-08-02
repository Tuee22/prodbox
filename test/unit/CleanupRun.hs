{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module CleanupRun
  ( cleanupRunSuite
  )
where

import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Data.ByteString qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityAggregateEnvelope)
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (ManagedDestroy))
import Prodbox.ControlPlane.CapabilityRef (CapabilityRef, mkCapabilityRef)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClient (..)
  , CleanupRunClientError (CleanupRunClientHttpStatus)
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (..)
  , CleanupRunEndpointResult (..)
  , CleanupRunRepositoryProvider (..)
  , cleanupRunEndpointBody
  , decodeCleanupRunScanResponse
  , serveCleanupRunRequest
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (PerRun))
import Prodbox.Lifecycle.ResourceRegistry
  ( ManagedResource (..)
  , managedDestroyCapability
  , perRunManagedResources
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  )
import Prodbox.Test.CleanupRun
import Prodbox.Test.CleanupRunRunner
  ( CleanupRunDriverError (..)
  , CleanupRunDriverResult (..)
  , claimAndResumeDurableCleanup
  , compactEligibleCleanupRuns
  , recoverNonterminalCleanupRuns
  , runWithDurableCleanup
  , runWithDurableCleanupOutcome
  )
import Prodbox.Test.ManagedCleanupPlan
  ( compileManagedCleanupPlan
  , managedCleanupGraph
  , runManagedCleanupNode
  )
import System.Exit (ExitCode (ExitSuccess))
import TestSupport

cleanupRunSuite :: SuiteBuilder ()
cleanupRunSuite =
  describe "Sprint 5.18 durable capability-bound CleanupRun" $ do
    it "refuses duplicate nodes, duplicate operations, unknown dependencies, and cycles" $ do
      mkCleanupGraph [nodeA, nodeA] `shouldBe` Left (CleanupGraphDuplicateNode nodeAId)
      mkCleanupGraph [nodeA, nodePlan nodeBId (cleanupNodeOperationId nodeA) [] "cleanup/destroy"]
        `shouldBe` Left (CleanupGraphDuplicateOperation (cleanupNodeOperationId nodeA))
      mkCleanupGraph
        [nodePlan nodeAId (cleanupNodeOperationId nodeA) [requiresSuccess unknownId] "cleanup/drain"]
        `shouldBe` Left (CleanupGraphUnknownDependency nodeAId unknownId)
      mkCleanupGraph
        [ nodePlan nodeAId (cleanupNodeOperationId nodeA) [requiresSuccess nodeBId] "cleanup/drain"
        , nodePlan nodeBId (cleanupNodeOperationId nodeB) [requiresSuccess nodeAId] "cleanup/destroy"
        ]
        `shouldBe` Left CleanupGraphCyclic

    it "commits the complete graph, digest, stable operations, and lease before work" $ do
      let run = freshRun graphBoth
      cleanupRunGraph run `shouldBe` graphBoth
      cleanupRunGraphDigest run `shouldBe` cleanupGraphDigest graphBoth
      cleanupLeaseFence (cleanupRunLease run) `shouldBe` 1
      cleanupRunPrimaryOutcome run `shouldBe` Nothing
      Map.elems (cleanupRunNodeStates run) `shouldBe` [CleanupNodePending, CleanupNodePending]

    it "refuses a live competing owner and records RunnerLost before expired takeover" $ do
      claimCleanupRun ownerB 50 200 (freshRun graphBoth)
        `shouldBe` Left (CleanupLeaseHeld ownerA)
      let running = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA (freshRun graphBoth))
          resumed = expectRight (claimCleanupRun ownerB 101 300 running)
      cleanupRunPrimaryOutcome resumed `shouldBe` Just CleanupPrimaryRunnerLost
      cleanupLeaseOwner (cleanupRunLease resumed) `shouldBe` ownerB
      cleanupLeaseFence (cleanupRunLease resumed) `shouldBe` 2
      Map.lookup nodeAId (cleanupRunNodeStates resumed) `shouldBe` Just CleanupNodePending

    it "makes begin, completion, and primary recording idempotent by exact identity" $ do
      let run0 = freshRun graphA
          run1 = expectRight (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded run0)
          run2 = expectRight (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded run1)
          run3 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA run2)
          run4 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA run3)
          run5 = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA CleanupNodeSucceeded run4)
          run6 = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA CleanupNodeSucceeded run5)
      run2 `shouldBe` run1
      run4 `shouldBe` run3
      run6 `shouldBe` run5
      cleanupRunTerminal run6 `shouldBe` True

    it "runs RequiresAttempt after failure and blocks RequiresSuccess without losing either outcome" $ do
      let run0 = expectRight (recordPrimaryOutcome ownerA 1 (CleanupPrimaryFailed "body") (freshRun graphBoth))
          run1 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA run0)
          run2 = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA (CleanupNodeFailed "drain") run1)
      Map.lookup nodeBId (cleanupRunNodeStates run2) `shouldBe` Just CleanupNodePending
      let run3 = expectRight (beginCleanupNode ownerA 1 nodeBId attemptB run2)
          run4 = expectRight (completeCleanupNode ownerA 1 nodeBId attemptB CleanupNodeSucceeded run3)
      cleanupRunTerminal run4 `shouldBe` True
      cleanupReportPrimaryOutcome (expectRight (compactCleanupRun run4))
        `shouldBe` CleanupPrimaryFailed "body"

      let blocked0 = expectRight (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded (freshRun graphSuccess))
          blocked1 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA blocked0)
          blocked2 = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA (CleanupNodeFailed "drain") blocked1)
      Map.lookup nodeBId (cleanupRunNodeStates blocked2)
        `shouldBe` Just (CleanupNodeBlocked [nodeAId])
      cleanupRunTerminal blocked2 `shouldBe` True

    it "refuses stale fences and conflicting attempt IDs" $ do
      beginCleanupNode ownerA 2 nodeAId attemptA (freshRun graphA)
        `shouldBe` Left (CleanupFenceMismatch 2 1)
      let running = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA (freshRun graphA))
      completeCleanupNode ownerA 1 nodeAId attemptB CleanupNodeSucceeded running
        `shouldBe` Left (CleanupAttemptConflict nodeAId)

    it "round-trips only bounded canonical state" $ do
      let run = freshRun graphBoth
          encoded = expectRight (encodeCleanupRun 16384 run)
      decodeCleanupRun 16384 encoded `shouldBe` Right run
      encodeCleanupRun 1 run `shouldSatisfy` isTooLarge
      decodeCleanupRun 16384 (ByteString.snoc encoded 0) `shouldBe` Left CleanupRunEnvelopeNonCanonical

    it "recovers an applied cleanup CAS whose response was lost by exact read-back" $ do
      state <- newIORef (freshRun graphA)
      let repository =
            CleanupRunRepository
              { readCleanupRun = Right . CleanupRunObserved (1 :: Int) <$> readIORef state
              , compareAndSwapCleanupRun = \_ next -> do
                  writeIORef state next
                  pure (Left "response lost")
              , compareAndSwapCleanupRunTombstone = \_ _ -> pure (Left "not used")
              }
      result <-
        applyCleanupRunTransition
          repository
          (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded)
      case result of
        Left err -> expectationFailure (show err)
        Right observed -> cleanupRunPrimaryOutcome observed `shouldBe` Just CleanupPrimarySucceeded

    it "receipt-confirms immutable backup bytes before publishing the primary revision" $ do
      backupBytes <- newIORef Nothing
      primaryState <- newIORef Nothing
      effects <- newIORef ([] :: [String])
      let backup =
            AuthorityAggregateBackupClient
              { copyAuthorityAggregateBackup = \bytes -> do
                  modifyIORef' effects (++ ["backup"])
                  writeIORef backupBytes (Just bytes)
                  pure (Right (receiptFor bytes))
              , observeAuthorityAggregateBackup = \_ -> do
                  stored <- readIORef backupBytes
                  pure $ case stored of
                    Nothing -> Right AuthorityAggregateBackupMissing
                    Just bytes ->
                      Right
                        ( AuthorityAggregateBackupCurrent
                            (expectRight (mkAuthorityBackupCiphertext bytes))
                            (receiptFor bytes)
                        )
              }
          primary =
            CleanupRunRepository
              { readCleanupRun = do
                  stored <- readIORef primaryState
                  pure (Right (maybe CleanupRunMissing (uncurry CleanupRunObserved) stored))
              , compareAndSwapCleanupRun = \_ run -> do
                  modifyIORef' effects (++ ["primary"])
                  writeIORef primaryState (Just (1 :: Int, run))
                  pure (Right ())
              , compareAndSwapCleanupRunTombstone = \_ _ -> pure (Left "not used")
              }
          replicated = replicatedCleanupRunRepository 16384 backup primary
      created <- createCleanupRunDurably replicated (freshRun graphA)
      created `shouldBe` Right (freshRun graphA)
      readIORef effects `shouldReturn` ["backup", "primary"]
      readCleanupRun replicated `shouldReturn` Right (CleanupRunObserved 1 (freshRun graphA))

    it "serves logical cleanup commands only through validated authenticated-endpoint identities" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      let repository = memoryRepository state
          provider =
            CleanupRunRepositoryProvider
              { cleanupRunRepositoryFor = const repository
              , cleanupRunIndexRepository = memoryIndexRepository indexState
              , cleanupRunAggregateBackup = inertBackup
              }
          call command =
            serveCleanupRunRequest provider (encodeControlPlaneRequest command)
          encoded = expectRight (encodeCleanupRun 16384 (freshRun graphA))
      call (CleanupRunCreate "run-1" encoded)
        `shouldReturn` CleanupRunEndpointSucceeded (freshRun graphA)
      call (CleanupRunObserve "run-1")
        `shouldReturn` CleanupRunEndpointSucceeded (freshRun graphA)
      call CleanupRunScan
        `shouldReturn` CleanupRunEndpointScanned ["run-1"]
      decodeCleanupRunScanResponse
        (cleanupRunEndpointBody (CleanupRunEndpointScanned ["run-1"]))
        `shouldBe` Right ["run-1"]
      call (CleanupRunObserve "not allowed!")
        `shouldReturn` CleanupRunEndpointInvalidIdentity "cleanup run id contains an invalid character"
      call (CleanupRunCreate "other-run" encoded)
        `shouldReturn` CleanupRunEndpointInvalidState "cleanup run id/body mismatch"

    it
      "receipt-registers the complete immutable plan and repairs an indexed missing primary during scan"
      $ do
        state <- newIORef Nothing
        indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive (freshRun graphA)]))
        let client = endpointClient state indexState
        scanNonterminalCleanupRuns client `shouldReturn` Right ["run-1"]
        readCleanupRun (memoryRepository state)
          `shouldReturn` Right (CleanupRunObserved 1 (freshRun graphA))

    it "durably records a primary failure and still runs every RequiresAttempt cleanup" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      effects <- newIORef ([] :: [Text])
      result <-
        runWithDurableCleanup
          16384
          (endpointClient state indexState)
          (freshRun graphBoth)
          ownerA
          1000000
          (fail "primary failed" :: IO ())
          ( \plan -> do
              modifyIORef' effects (++ [cleanupNodeIdText (cleanupNodeId plan)])
              pure $
                if cleanupNodeId plan == nodeAId then CleanupNodeFailed "drain failed" else CleanupNodeSucceeded
          )
      readIORef effects `shouldReturn` ["drain", "destroy"]
      case result of
        Left err -> expectationFailure (show err)
        Right completed -> do
          cleanupDriverPrimaryValue completed `shouldBe` Nothing
          cleanupReportPrimaryOutcome (cleanupDriverReport completed)
            `shouldBe` CleanupPrimaryFailed "user error (primary failed)"

    it "records a command-style non-zero primary as failure rather than successful data" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      result <-
        runWithDurableCleanupOutcome
          16384
          (endpointClient state indexState)
          (freshRun graphA)
          ownerA
          1000000
          (pure (Left "suite exited 23") :: IO (Either Text ()))
          (const (pure CleanupNodeSucceeded))
      case result of
        Left err -> expectationFailure (show err)
        Right completed -> do
          cleanupDriverPrimaryValue completed `shouldBe` Nothing
          cleanupReportPrimaryOutcome (cleanupDriverReport completed)
            `shouldBe` CleanupPrimaryFailed "suite exited 23"

    it "runs cleanup under cancellation and rethrows the original async exception afterward" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      effects <- newIORef ([] :: [Text])
      attempted <-
        try
          ( runWithDurableCleanup
              16384
              (endpointClient state indexState)
              (freshRun graphA)
              ownerA
              1000000
              (throwIO ThreadKilled)
              ( \plan -> modifyIORef' effects (++ [cleanupNodeIdText (cleanupNodeId plan)]) >> pure CleanupNodeSucceeded
              )
          )
          :: IO (Either SomeException (Either CleanupRunDriverError (CleanupRunDriverResult ())))
      readIORef effects `shouldReturn` ["drain"]
      attempted `shouldSatisfy` isThreadKilled

    it "takes over an expired in-flight run before retrying its stable cleanup operation" $ do
      let inFlight = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA (freshRun graphA))
      state <- newIORef (Just (1, CleanupRunStoredActive inFlight))
      indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive inFlight]))
      effects <- newIORef ([] :: [Text])
      recovered <-
        claimAndResumeDurableCleanup
          (endpointClient state indexState)
          ownerB
          101
          200
          ( \plan -> modifyIORef' effects (++ [cleanupNodeIdText (cleanupNodeId plan)]) >> pure CleanupNodeSucceeded
          )
          inFlight
      readIORef effects `shouldReturn` ["drain"]
      case recovered of
        Left err -> expectationFailure (show err)
        Right report -> cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimaryRunnerLost

    it "scans and closes every indexed nonterminal before successor mutation is admitted" $ do
      let inFlight = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA (freshRun graphA))
      state <- newIORef (Just (1, CleanupRunStoredActive inFlight))
      indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive (freshRun graphA)]))
      recovered <-
        recoverNonterminalCleanupRuns
          (endpointClient state indexState)
          ownerB
          101
          200
          (const (pure CleanupNodeSucceeded))
      case recovered of
        Left failures -> expectationFailure (show failures)
        Right [report] -> cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimaryRunnerLost
        Right reports -> expectationFailure ("unexpected recovery reports: " ++ show reports)

    it "compacts a terminal run to a non-reusable report-digest tombstone" $ do
      let run0 = expectRight (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded (freshRun graphA))
          run1 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA run0)
          terminal = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA CleanupNodeSucceeded run1)
          report = expectRight (compactCleanupRun terminal)
          reportBytes = expectRight (encodeCleanupRunReport 16384 report)
      decodeCleanupRunReport 16384 reportBytes `shouldBe` Right report
      runState <- newIORef (Just (1, CleanupRunStoredActive terminal))
      indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive (freshRun graphA)]))
      backupBytes <- newIORef Nothing
      effects <- newIORef ([] :: [Text])
      let baseIndex = memoryIndexRepository indexState
          tracedIndex =
            baseIndex
              { compareAndSwapCleanupRunIndex = \revision index -> do
                  modifyIORef' effects (++ ["index"])
                  compareAndSwapCleanupRunIndex baseIndex revision index
              }
          backup =
            AuthorityAggregateBackupClient
              { copyAuthorityAggregateBackup = \bytes -> do
                  modifyIORef' effects (++ ["backup"])
                  writeIORef backupBytes (Just bytes)
                  pure (Right (receiptFor bytes))
              , observeAuthorityAggregateBackup = \_ -> do
                  stored <- readIORef backupBytes
                  pure $ case stored of
                    Nothing -> Right AuthorityAggregateBackupMissing
                    Just bytes ->
                      Right
                        ( AuthorityAggregateBackupCurrent
                            (expectRight (mkAuthorityBackupCiphertext bytes))
                            (receiptFor bytes)
                        )
              }
      compacted <-
        compactCleanupRunDurably
          16384
          backup
          (memoryRepository runState)
          tracedIndex
          terminal
      compacted `shouldBe` Right report
      readIORef effects `shouldReturn` ["backup", "index"]
      readCleanupRun (memoryRepository runState)
        `shouldReturn` Right
          ( CleanupRunTombstoned
              2
              ( CleanupRunTombstone
                  (cleanupRunId terminal)
                  (authorityBackupDigestText (authorityBackupReceiptDigest (receiptFor reportBytes)))
              )
          )
      indexed <- readCleanupRunIndex baseIndex
      case indexed of
        Left detail -> expectationFailure (Text.unpack detail)
        Right CleanupRunIndexMissing -> expectationFailure "compacted index disappeared"
        Right (CleanupRunIndexObserved _ compactedIndex) -> case compactedIndex of
          CleanupRunIndex [CleanupRunIndexTombstone tombstone] -> do
            cleanupRunTombstoneId tombstone `shouldBe` cleanupRunId terminal
            cleanupRunTombstoneReportDigest tombstone
              `shouldBe` authorityBackupDigestText (authorityBackupReceiptDigest (receiptFor reportBytes))
          other -> expectationFailure ("unexpected compacted index: " ++ show other)
      registerCleanupRun baseIndex (freshRun graphA)
        `shouldReturn` Left "cleanup run id is already registered and cannot be reused"

    it "repairs response loss between physical tombstone commit and namespace publication" $ do
      let tombstone = CleanupRunTombstone (cleanupRunId (freshRun graphA)) digestText
      state <- newIORef (Just (2, CleanupRunStoredTombstone tombstone))
      indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive (freshRun graphA)]))
      scanNonterminalCleanupRuns (endpointClient state indexState) `shouldReturn` Right []
      readCleanupRunIndex (memoryIndexRepository indexState)
        `shouldReturn` Right (CleanupRunIndexObserved 2 (CleanupRunIndex [CleanupRunIndexTombstone tombstone]))

    it "compacts eligible terminal runs through the authenticated endpoint only after retention" $ do
      let run0 = expectRight (recordPrimaryOutcome ownerA 1 CleanupPrimarySucceeded (freshRun graphA))
          run1 = expectRight (beginCleanupNode ownerA 1 nodeAId attemptA run0)
          terminal = expectRight (completeCleanupNode ownerA 1 nodeAId attemptA CleanupNodeSucceeded run1)
      state <- newIORef (Just (1, CleanupRunStoredActive terminal))
      indexState <- newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive (freshRun graphA)]))
      backupBytes <- newIORef Nothing
      let backup = memoryBackup backupBytes
          client = endpointClientWithBackup state indexState backup
      compactEligibleCleanupRuns client 99 0
        `shouldReturn` Left
          [ CleanupRunDriverClientFailed
              ( CleanupRunClientHttpStatus
                  500
                  "CleanupRunEndpointInvalidState \"cleanup run retention window has not elapsed\""
              )
          ]
      compacted <- compactEligibleCleanupRuns client 100 0
      case compacted of
        Left failures -> expectationFailure (show failures)
        Right [report] -> cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimarySucceeded
        Right reports -> expectationFailure ("unexpected compacted reports: " ++ show reports)
      replayed <- compactTerminalCleanupRun client "run-1" 100 0
      case replayed of
        Left failure -> expectationFailure (show failure)
        Right report -> cleanupReportPrimaryOutcome report `shouldBe` CleanupPrimarySucceeded
      scanNonterminalCleanupRuns client `shouldReturn` Right []

    it "compiles managed cleanup from the same capability-bound registry entries it executes" $ do
      let runId = expectRight (mkCleanupRunId "managed-run")
          compiled = expectRight (compileManagedCleanupPlan runId perRunManagedResources [])
      length (cleanupGraphNodes (managedCleanupGraph compiled)) `shouldBe` 3
      effects <- newIORef ([] :: [Text])
      let resource =
            ManagedResource
              { resourceName = "fixture"
              , resourceClass = PerRun
              , resourceEnsureCommand = Nothing
              , resourceEnsurePresent = Nothing
              , resourceDestroyCommand = "fixture destroy"
              , resourceDestroyCapability = managedDestroyCapability "fixture"
              , resourceDestroy = \_ -> modifyIORef' effects (++ ["destroyed"]) >> pure ExitSuccess
              }
          fixturePlan = expectRight (compileManagedCleanupPlan runId [resource] [])
      case cleanupGraphNodes (managedCleanupGraph fixturePlan) of
        [fixtureNode] ->
          runManagedCleanupNode "/tmp" fixturePlan fixtureNode `shouldReturn` CleanupNodeSucceeded
        other -> expectationFailure ("unexpected managed cleanup nodes: " ++ show other)
      readIORef effects `shouldReturn` ["destroyed"]
 where
  isTooLarge result = case result of
    Left CleanupRunEnvelopeTooLarge {} -> True
    _ -> False

expectRight :: (Show errorType) => Either errorType value -> value
expectRight = either (error . show) id

field :: (Show errorType) => (Text -> Either errorType value) -> Text -> value
field constructor = expectRight . constructor

generation :: Natural -> CredentialGeneration
generation = expectRight . mkCredentialGeneration

coordinate :: Text -> CapabilityCoordinate
coordinate logical =
  mkCoordinate
    (field mkServiceIdentity "test-harness")
    (field mkAuthorityScope "home/prodbox")
    (field mkCapabilityEndpoint "authority:8443")
    (field mkLogicalName logical)
    (generation 1)

destroyRef :: Text -> CapabilityRef 'ManagedDestroy
destroyRef = mkCapabilityRef . coordinate

nodeAId, nodeBId, unknownId :: CleanupNodeId
nodeAId = expectRight (mkCleanupNodeId "drain")
nodeBId = expectRight (mkCleanupNodeId "destroy")
unknownId = expectRight (mkCleanupNodeId "unknown")

nodeA, nodeB :: CleanupNodePlan
nodeA = nodePlan nodeAId (expectRight (mkCleanupOperationId "run-1/drain")) [] "cleanup/drain"
nodeB =
  nodePlan
    nodeBId
    (expectRight (mkCleanupOperationId "run-1/destroy"))
    [requiresAttempt nodeAId]
    "cleanup/destroy"

nodePlan :: CleanupNodeId -> CleanupOperationId -> [CleanupDependency] -> Text -> CleanupNodePlan
nodePlan nodeId operationId dependencies logical =
  mkCleanupNodePlan (destroyRef logical) nodeId operationId dependencies

requiresSuccess, requiresAttempt :: CleanupNodeId -> CleanupDependency
requiresSuccess nodeId = CleanupDependency nodeId CleanupRequiresSuccess
requiresAttempt nodeId = CleanupDependency nodeId CleanupRequiresAttempt

graphA, graphBoth, graphSuccess :: CleanupGraph
graphA = expectRight (mkCleanupGraph [nodeA])
graphBoth = expectRight (mkCleanupGraph [nodeA, nodeB])
graphSuccess =
  expectRight
    ( mkCleanupGraph
        [nodeA, nodePlan nodeBId (cleanupNodeOperationId nodeB) [requiresSuccess nodeAId] "cleanup/destroy"]
    )

ownerA, ownerB :: CleanupOwnerId
ownerA = expectRight (mkCleanupOwnerId "runner-a")
ownerB = expectRight (mkCleanupOwnerId "runner-b")

attemptA, attemptB :: CleanupAttemptId
attemptA = expectRight (mkCleanupAttemptId "attempt-a")
attemptB = expectRight (mkCleanupAttemptId "attempt-b")

digestText :: Text
digestText = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

freshRun :: CleanupGraph -> CleanupRun
freshRun graph =
  expectRight
    ( newCleanupRun
        (expectRight (mkCleanupRunId "run-1"))
        graph
        ownerA
        0
        100
    )

receiptFor :: ByteString.ByteString -> AuthorityBackupReceipt
receiptFor bytes =
  let ciphertext = expectRight (mkAuthorityBackupCiphertext bytes)
   in AuthorityBackupReceipt
        { authorityBackupReceiptClass = AuthorityAggregateEnvelope
        , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
        , authorityBackupReceiptObjectVersion = "version-1"
        }

memoryRepository
  :: IORef (Maybe (Int, CleanupRunStored))
  -> CleanupRunRepository IO Int
memoryRepository state =
  CleanupRunRepository
    { readCleanupRun = do
        stored <- readIORef state
        pure $ Right $ case stored of
          Nothing -> CleanupRunMissing
          Just (revision, CleanupRunStoredActive run) -> CleanupRunObserved revision run
          Just (revision, CleanupRunStoredTombstone tombstone) -> CleanupRunTombstoned revision tombstone
    , compareAndSwapCleanupRun = \expected run -> do
        stored <- readIORef state
        let observedRevision = fst <$> stored
        if observedRevision /= expected
          then pure (Right ())
          else do
            writeIORef state (Just (maybe 1 ((+ 1) . fst) stored, CleanupRunStoredActive run))
            pure (Right ())
    , compareAndSwapCleanupRunTombstone = \expected tombstone -> do
        stored <- readIORef state
        if (fst <$> stored) /= Just expected
          then pure (Left "tombstone conflict")
          else do
            writeIORef state (Just (expected + 1, CleanupRunStoredTombstone tombstone))
            pure (Right ())
    }

endpointClient
  :: IORef (Maybe (Int, CleanupRunStored))
  -> IORef (Maybe (Int, CleanupRunIndex))
  -> CleanupRunClient IO
endpointClient state indexState =
  endpointClientWithBackup state indexState inertBackup

endpointClientWithBackup
  :: IORef (Maybe (Int, CleanupRunStored))
  -> IORef (Maybe (Int, CleanupRunIndex))
  -> AuthorityAggregateBackupClient IO
  -> CleanupRunClient IO
endpointClientWithBackup state indexState backup =
  CleanupRunClient
    { executeCleanupRunCommand = \command -> do
        result <- callEndpoint command
        pure $ case result of
          CleanupRunEndpointSucceeded run -> Right (Just run)
          CleanupRunEndpointMissing -> Right Nothing
          other -> Left (CleanupRunClientHttpStatus 500 (Text.pack (show other)))
    , scanNonterminalCleanupRuns = do
        result <- callEndpoint CleanupRunScan
        pure $ case result of
          CleanupRunEndpointScanned runIds -> Right runIds
          other -> Left (CleanupRunClientHttpStatus 500 (Text.pack (show other)))
    , compactTerminalCleanupRun = \runId now retention -> do
        result <- callEndpoint (CleanupRunCompact runId now retention)
        pure $ case result of
          CleanupRunEndpointCompacted report -> Right report
          other -> Left (CleanupRunClientHttpStatus 500 (Text.pack (show other)))
    }
 where
  callEndpoint command =
    serveCleanupRunRequest
      CleanupRunRepositoryProvider
        { cleanupRunRepositoryFor = const (memoryRepository state)
        , cleanupRunIndexRepository = memoryIndexRepository indexState
        , cleanupRunAggregateBackup = backup
        }
      (encodeControlPlaneRequest command)

memoryIndexRepository
  :: IORef (Maybe (Int, CleanupRunIndex))
  -> CleanupRunIndexRepository IO Int
memoryIndexRepository state =
  CleanupRunIndexRepository
    { readCleanupRunIndex = do
        stored <- readIORef state
        pure (Right (maybe CleanupRunIndexMissing (uncurry CleanupRunIndexObserved) stored))
    , compareAndSwapCleanupRunIndex = \expected index -> do
        stored <- readIORef state
        if (fst <$> stored) /= expected
          then pure (Left "index conflict")
          else do
            writeIORef state (Just (maybe 1 ((+ 1) . fst) stored, index))
            pure (Right ())
    }

inertBackup :: AuthorityAggregateBackupClient IO
inertBackup =
  AuthorityAggregateBackupClient
    { copyAuthorityAggregateBackup = pure . Right . receiptFor
    , observeAuthorityAggregateBackup = const (pure (Right AuthorityAggregateBackupMissing))
    }

memoryBackup :: IORef (Maybe ByteString.ByteString) -> AuthorityAggregateBackupClient IO
memoryBackup state =
  AuthorityAggregateBackupClient
    { copyAuthorityAggregateBackup = \bytes -> do
        writeIORef state (Just bytes)
        pure (Right (receiptFor bytes))
    , observeAuthorityAggregateBackup = \_ -> do
        stored <- readIORef state
        pure $ case stored of
          Nothing -> Right AuthorityAggregateBackupMissing
          Just bytes ->
            Right
              ( AuthorityAggregateBackupCurrent
                  (expectRight (mkAuthorityBackupCiphertext bytes))
                  (receiptFor bytes)
              )
    }

isThreadKilled :: Either SomeException value -> Bool
isThreadKilled result = case result of
  Left exception -> show exception == show ThreadKilled
  Right _ -> False
