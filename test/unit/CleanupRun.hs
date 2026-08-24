{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module CleanupRun
  ( cleanupRunSuite
  )
where

import Codec.Serialise (Serialise, serialise)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
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
  , CleanupRunDescriptorCommand (..)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (..)
  , CleanupRunRepositoryProvider (..)
  , cleanupRunDescriptorResponseMaximumBytes
  , cleanupRunEndpointBody
  , decodeCleanupRunDescriptorResponse
  , decodeCleanupRunScanResponse
  , encodeCleanupRunDescriptorResponse
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
import Prodbox.ControlPlane.EksClientAuthClient
  ( eksClientAuthExecutionSubmissionKey
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError (..)
  , CleanupRunDriverResult (..)
  , CleanupTerminalDependencyResult (..)
  , claimAndResumeDurableCleanup
  , cleanupDependencyReceiptAttemptId
  , cleanupDependencyReceiptKind
  , cleanupDependencyReceiptNodeId
  , cleanupDependencyReceiptOperationId
  , cleanupDependencyReceiptOutcome
  , cleanupNodeExecutionDependencyReceipts
  , cleanupNodeExecutionRunId
  , cleanupNodeExecutionTerminalDependencyReceipts
  , cleanupTerminalDependencyReceiptNodeId
  , cleanupTerminalDependencyReceiptOperationId
  , cleanupTerminalDependencyReceiptResult
  , compactEligibleCleanupRuns
  , recoverNonterminalCleanupRuns
  , runWithDurableCleanup
  , runWithDurableCleanupOutcome
  , runWithDurableCleanupWithAttempt
  , runWithDurableCleanupWithContext
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  )
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

    it
      "runs RequiresTerminal after attempted and dependency-blocked predecessors without inventing attempts"
      $ do
        attemptedState <- newIORef Nothing
        attemptedIndex <- newIORef Nothing
        attemptedReceipt <- newIORef Nothing
        attempted <-
          runWithDurableCleanupWithContext
            16384
            (endpointClient attemptedState attemptedIndex)
            (freshRun graphTerminalAttempted)
            ownerA
            1000000
            (pure ())
            ( \context plan ->
                if cleanupNodeId plan == nodeAId
                  then pure (CleanupNodeFailed "drain")
                  else do
                    writeIORef
                      attemptedReceipt
                      ( Just
                          [ ( cleanupTerminalDependencyReceiptNodeId receipt
                            , cleanupTerminalDependencyReceiptOperationId receipt
                            , cleanupTerminalDependencyReceiptResult receipt
                            )
                          | receipt <- cleanupNodeExecutionTerminalDependencyReceipts context
                          ]
                      )
                    pure CleanupNodeSucceeded
            )
        case attempted of
          Left err -> expectationFailure (show err)
          Right _ -> pure ()
        observedAttemptedReceipt <- readIORef attemptedReceipt
        let matchesAttemptedReceipt observed = case observed of
              Just
                [ ( observedNode
                    , observedOperation
                    , CleanupTerminalDependencyCompleted observedAttempt (CleanupNodeFailed "drain")
                    )
                  ] ->
                  observedNode == nodeAId
                    && observedOperation == cleanupNodeOperationId nodeA
                    && validAttemptIdentity (cleanupAttemptIdText observedAttempt)
              _ -> False
        observedAttemptedReceipt `shouldSatisfy` matchesAttemptedReceipt

        blockedState <- newIORef Nothing
        blockedIndex <- newIORef Nothing
        blockedReceipt <- newIORef Nothing
        blocked <-
          runWithDurableCleanupWithContext
            16384
            (endpointClient blockedState blockedIndex)
            (freshRun graphTerminalBlocked)
            ownerA
            1000000
            (pure ())
            ( \context plan ->
                if cleanupNodeId plan == nodeAId
                  then pure (CleanupNodeFailed "drain")
                  else do
                    writeIORef
                      blockedReceipt
                      ( Just
                          [ ( cleanupTerminalDependencyReceiptNodeId receipt
                            , cleanupTerminalDependencyReceiptOperationId receipt
                            , cleanupTerminalDependencyReceiptResult receipt
                            )
                          | receipt <- cleanupNodeExecutionTerminalDependencyReceipts context
                          ]
                      )
                    pure CleanupNodeSucceeded
            )
        case blocked of
          Left err -> expectationFailure (show err)
          Right _ -> pure ()
        readIORef blockedReceipt
          `shouldReturn` Just
            [
              ( cleanupNodeId nodeB
              , cleanupNodeOperationId nodeB
              , CleanupTerminalDependencyBlocked [nodeAId]
              )
            ]

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

    it "keeps terminal-free runs and unchanged reports byte-stable at v1" $ do
      let legacyRun = freshRun graphBoth
          legacyBytes = fixtureCleanupRunBytes 1 legacyRun
      encodeCleanupRun 16384 legacyRun `shouldBe` Right legacyBytes
      decodeCleanupRun 16384 legacyBytes `shouldBe` Right legacyRun

      let blocked0 =
            expectRight
              ( recordPrimaryOutcome
                  ownerA
                  1
                  CleanupPrimarySucceeded
                  (freshRun graphSuccess)
              )
          blocked1 =
            expectRight
              (beginCleanupNode ownerA 1 nodeAId attemptA blocked0)
          blocked =
            expectRight
              ( completeCleanupNode
                  ownerA
                  1
                  nodeAId
                  attemptA
                  (CleanupNodeFailed "drain")
                  blocked1
              )
          report = expectRight (compactCleanupRun blocked)
          reportBytes = fixtureCleanupRunReportBytes 1 report
      encodeCleanupRun 16384 blocked `shouldBe` Right (fixtureCleanupRunBytes 1 blocked)
      decodeCleanupRun 16384 (fixtureCleanupRunBytes 1 blocked) `shouldBe` Right blocked
      encodeCleanupRunReport 16384 report `shouldBe` Right reportBytes
      decodeCleanupRunReport 16384 reportBytes `shouldBe` Right report

    it "uses v2 only for the appended RequiresTerminal graph feature" $ do
      let terminalRun = freshRun graphTerminalAttempted
          v1Bytes = fixtureCleanupRunBytes 1 terminalRun
          v2Bytes = fixtureCleanupRunBytes 2 terminalRun
      encodeCleanupRun 16384 terminalRun `shouldBe` Right v2Bytes
      decodeCleanupRun 16384 v2Bytes `shouldBe` Right terminalRun
      decodeCleanupRun 16384 v1Bytes `shouldBe` Left CleanupRunEnvelopeInvalid

    it "accepts byte-stable legacy stored/index tags but refuses v2 state in v1 wrappers" $ do
      let run = freshRun graphBoth
          otherRun = freshRunNamed "other-run" graphBoth
          tombstone = CleanupRunTombstone (cleanupRunId otherRun) digestText
          storedCodec = cleanupRunStoredCodec 16384
          indexCodec = cleanupRunIndexCodec 16384
      encodeModelBValue storedCodec (CleanupRunStoredActive run)
        `shouldBe` Right (fixtureLegacyStoredBytes (FixtureStoredActive run))
      encodeModelBValue storedCodec (CleanupRunStoredTombstone tombstone)
        `shouldBe` Right
          (fixtureLegacyStoredBytes (FixtureStoredTombstone tombstone))
      decodeModelBValue storedCodec (fixtureLegacyStoredBytes (FixtureStoredActive run))
        `shouldBe` Right (CleanupRunStoredActive run)
      decodeModelBValue storedCodec (fixtureLegacyStoredBytes (FixtureStoredTombstone tombstone))
        `shouldBe` Right (CleanupRunStoredTombstone tombstone)
      decodeModelBValue
        indexCodec
        (fixtureLegacyIndexBytes [FixtureIndexActive run, FixtureIndexTombstone tombstone])
        `shouldBe` Right
          ( CleanupRunIndex
              [ CleanupRunIndexActive run
              , CleanupRunIndexTombstone tombstone
              ]
          )
      encodeModelBValue
        indexCodec
        ( CleanupRunIndex
            [ CleanupRunIndexActive run
            , CleanupRunIndexTombstone tombstone
            ]
        )
        `shouldBe` Right
          (fixtureLegacyIndexBytes [FixtureIndexActive run, FixtureIndexTombstone tombstone])
      decodeModelBValue
        storedCodec
        ( fixtureCurrentStoredBytes
            1
            (CleanupRunStoredDescriptorBoundActive descriptorDigest run)
        )
        `shouldBe` Left "stored cleanup run v1 contains v2 state"
      encodeModelBValue
        storedCodec
        (CleanupRunStoredDescriptorBoundActive descriptorDigest run)
        `shouldBe` Right
          ( fixtureCurrentStoredBytes
              2
              (CleanupRunStoredDescriptorBoundActive descriptorDigest run)
          )
      decodeModelBValue
        indexCodec
        ( fixtureCurrentIndexBytes
            1
            ( CleanupRunIndex
                [CleanupRunIndexDescriptorBoundActive descriptorDigest run]
            )
        )
        `shouldBe` Left "cleanup run index v1 contains v2 state"
      encodeModelBValue
        indexCodec
        ( CleanupRunIndex
            [CleanupRunIndexDescriptorBoundActive descriptorDigest run]
        )
        `shouldBe` Right
          ( fixtureCurrentIndexBytes
              2
              ( CleanupRunIndex
                  [CleanupRunIndexDescriptorBoundActive descriptorDigest run]
              )
          )

    it "publishes descriptor discovery before primary creation and repairs post-index interruption" $ do
      primaryState <- newIORef Nothing
      indexState <- newIORef Nothing
      effects <- newIORef (["descriptor-readback"] :: [Text])
      let initialRun = freshRun graphA
          basePrimary = memoryDescriptorBoundRepository primaryState
          tracedPrimary =
            basePrimary
              { readDescriptorBoundCleanupRun = do
                  modifyIORef' effects (++ ["primary-read"])
                  readDescriptorBoundCleanupRun basePrimary
              , compareAndSwapDescriptorBoundCleanupRun = \revision digest run -> do
                  modifyIORef' effects (++ ["primary-write"])
                  _ <-
                    compareAndSwapDescriptorBoundCleanupRun
                      basePrimary
                      revision
                      digest
                      run
                  pure (Left "primary response lost")
              }
          baseIndex = memoryIndexRepository indexState
          tracedIndex =
            baseIndex
              { readCleanupRunIndex = do
                  modifyIORef' effects (++ ["index-read"])
                  readCleanupRunIndex baseIndex
              , compareAndSwapCleanupRunIndex = \revision index -> do
                  modifyIORef' effects (++ ["index-write"])
                  _ <- compareAndSwapCleanupRunIndex baseIndex revision index
                  pure (Left "index response lost")
              }

      -- A crash before index publication is intentionally undiscoverable; a
      -- create retry still knows the caller's stable run id.
      readCleanupRunIndex baseIndex `shouldReturn` Right CleanupRunIndexMissing
      readDescriptorBoundCleanupRun basePrimary
        `shouldReturn` Right DescriptorBoundCleanupRunMissing

      registerDescriptorBoundCleanupRun tracedIndex descriptorDigest initialRun
        `shouldReturn` Right
          ( CleanupRunIndex
              [ CleanupRunIndexDescriptorBoundActive
                  descriptorDigest
                  initialRun
              ]
          )
      -- A crash here is scan-recoverable because the exact initial run and
      -- descriptor digest are already independently read back in the index.
      readDescriptorBoundCleanupRun basePrimary
        `shouldReturn` Right DescriptorBoundCleanupRunMissing
      indexed <- readCleanupRunIndex baseIndex
      repaired <- case indexed of
        Right
          ( CleanupRunIndexObserved
              _
              (CleanupRunIndex [CleanupRunIndexDescriptorBoundActive digest run])
            ) -> createDescriptorBoundCleanupRunDurably tracedPrimary digest run
        other ->
          expectationFailure ("unexpected descriptor index: " ++ show other)
            >> pure (Left CleanupRunStoreMissing)
      repaired `shouldBe` Right initialRun
      readIORef effects
        `shouldReturn` [ "descriptor-readback"
                       , "index-read"
                       , "index-write"
                       , "index-read"
                       , "primary-read"
                       , "primary-write"
                       , "primary-read"
                       ]

      registerDescriptorBoundCleanupRun baseIndex descriptorDigest initialRun
        `shouldReturn` Right
          ( CleanupRunIndex
              [ CleanupRunIndexDescriptorBoundActive
                  descriptorDigest
                  initialRun
              ]
          )
      createDescriptorBoundCleanupRunDurably basePrimary descriptorDigest initialRun
        `shouldReturn` Right initialRun

      endpointSource <- readFile "src/Prodbox/ControlPlane/CleanupRunEndpoint.hs"
      endpointSource
        `shouldSatisfy` descriptorActivationPublishesIndexBeforePrimary

    it "refuses cross-protocol, descriptor-digest, and immutable-plan conflicts" $ do
      let initialRun = freshRun graphA
          otherRun = freshRunNamed "other-run" graphA
      primaryState <-
        newIORef
          ( Just
              ( 1
              , CleanupRunStoredDescriptorBoundActive
                  descriptorDigest
                  initialRun
              )
          )
      let primary = memoryDescriptorBoundRepository primaryState
      createDescriptorBoundCleanupRunDurably primary alternateDescriptorDigest initialRun
        `shouldReturn` Left CleanupRunStoreReadBackMismatch
      applyDescriptorBoundCleanupRunTransition
        primary
        alternateDescriptorDigest
        initialRun
        Right
        `shouldReturn` Left CleanupRunStoreReadBackMismatch
      applyDescriptorBoundCleanupRunTransition
        primary
        descriptorDigest
        otherRun
        Right
        `shouldReturn` Left CleanupRunStoreReadBackMismatch

      legacyPrimaryState <-
        newIORef (Just (1, CleanupRunStoredActive initialRun))
      createDescriptorBoundCleanupRunDurably
        (memoryDescriptorBoundRepository legacyPrimaryState)
        descriptorDigest
        initialRun
        `shouldReturn` Left
          ( CleanupRunStoreUnavailable
              "cleanup run primary uses the legacy protocol"
          )
      legacyIndexState <-
        newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive initialRun]))
      registerDescriptorBoundCleanupRun
        (memoryIndexRepository legacyIndexState)
        descriptorDigest
        initialRun
        `shouldReturn` Left
          "cleanup run id is already registered under a different protocol or descriptor"

      let tombstone = CleanupRunTombstone (cleanupRunId initialRun) digestText
      descriptorIndexState <-
        newIORef
          ( Just
              ( 1
              , CleanupRunIndex
                  [ CleanupRunIndexDescriptorBoundActive
                      descriptorDigest
                      initialRun
                  ]
              )
          )
      published <-
        publishDescriptorBoundCleanupRunTombstone
          (memoryIndexRepository descriptorIndexState)
          descriptorDigest
          tombstone
      published
        `shouldBe` Right
          ( CleanupRunIndex
              [ CleanupRunIndexDescriptorBoundTombstone
                  descriptorDigest
                  tombstone
              ]
          )

    it "keeps descriptor readback bounded and rejects legacy scan state explicitly" $ do
      let initialRun = freshRun graphA
          invalidProgramResponse =
            CleanupRunDescriptorProgramPresent
              "run-1"
              digestText
              "caller-forged-descriptor"
      encodeCleanupRunDescriptorResponse invalidProgramResponse
        `shouldSatisfy` isLeftResult
      decodeCleanupRunDescriptorResponse
        (fixtureDescriptorResponseBytes 3 invalidProgramResponse)
        `shouldBe` Left
          "descriptor-bound cleanup response version is unsupported"
      decodeCleanupRunDescriptorResponse
        (fixtureDescriptorResponseBytes 1 invalidProgramResponse)
        `shouldBe` Left
          "descriptor-bound cleanup response v1 contains v2 state"
      decodeCleanupRunDescriptorResponse
        (ByteString.replicate (cleanupRunDescriptorResponseMaximumBytes + 1) 0)
        `shouldBe` Left
          "descriptor-bound cleanup response exceeds its encoded bound"
      mapM_
        ( \refusal -> do
            let response = CleanupRunDescriptorRefused refusal
                bytes = expectRight (encodeCleanupRunDescriptorResponse response)
            decodeCleanupRunDescriptorResponse bytes `shouldBe` Right response
        )
        [ CleanupRunDescriptorMissing
        , CleanupRunDescriptorCorrupt "corrupt"
        , CleanupRunDescriptorUnobservable "unobservable"
        ]

      legacyIndexState <-
        newIORef (Just (1, CleanupRunIndex [CleanupRunIndexActive initialRun]))
      let legacyProvider =
            CleanupRunRepositoryProvider
              { cleanupRunRepositoryFor = const unavailableLegacyRepository
              , descriptorBoundCleanupRunRepositoryFor =
                  const unavailableDescriptorRepository
              , cleanupRunIndexRepository = memoryIndexRepository legacyIndexState
              , cleanupRunAggregateBackup = inertBackup
              , cleanupProgramDescriptorAuthorityClient = Nothing
              }
      serveCleanupRunRequest
        legacyProvider
        ( encodeControlPlaneRequest
            (CleanupRunDescriptorBound CleanupRunDescriptorScan)
        )
        `shouldReturn` CleanupRunEndpointDescriptorBound
          (CleanupRunDescriptorRefused CleanupRunDescriptorLegacyState)

      runnerSource <- readFile "src/Prodbox/Lifecycle/CleanupRunRunner.hs"
      runnerSource
        `shouldContain` "interpret running witness compiled context plan"
      runnerSource
        `shouldContain` "try (runAction running executionContext plan)"
      executionSource <-
        readFile "src/Prodbox/Lifecycle/Teardown/Execution.hs"
      executionSource
        `shouldContain` "cleanupNodeExecutionRunId durableContext == compiledDesiredAbsenceRunId compiled"
      executionSource
        `shouldContain` "cleanupNodeExecutionGraphDigest durableContext == cleanupGraphDigest graph"
      executionSource
        `shouldContain` "cleanupNodeExecutionNodeId durableContext == cleanupNodeId suppliedPlan"

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
              , descriptorBoundCleanupRunRepositoryFor =
                  const unavailableDescriptorRepository
              , cleanupRunIndexRepository = memoryIndexRepository indexState
              , cleanupRunAggregateBackup = inertBackup
              , cleanupProgramDescriptorAuthorityClient = Nothing
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

    it "passes each node its exact fence-bound durable attempt identity" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      attempts <- newIORef ([] :: [(Text, Text)])
      result <-
        runWithDurableCleanupWithAttempt
          16384
          (endpointClient state indexState)
          (freshRun graphBoth)
          ownerA
          1000000
          (pure ())
          ( \attempt plan -> do
              modifyIORef'
                attempts
                ( ++
                    [
                      ( cleanupNodeIdText (cleanupNodeId plan)
                      , cleanupAttemptIdText attempt
                      )
                    ]
                )
              pure CleanupNodeSucceeded
          )
      case result of
        Left err -> expectationFailure (show err)
        Right _ -> pure ()
      observedAttempts <- readIORef attempts
      map fst observedAttempts `shouldBe` ["drain", "destroy"]
      let areDistinctAttemptIdentities identities = case identities of
            [drainAttempt, destroyAttempt] ->
              all
                ( \identity ->
                    "cleanup-attempt/" `Text.isPrefixOf` identity
                      && Text.length identity == 80
                )
                identities
                && drainAttempt /= destroyAttempt
            _ -> False
      map snd observedAttempts `shouldSatisfy` areDistinctAttemptIdentities

    it "admits success-gated effects only from authoritative dependency receipts" $ do
      state <- newIORef Nothing
      indexState <- newIORef Nothing
      observed <- newIORef []
      result <-
        runWithDurableCleanupWithContext
          16384
          (endpointClient state indexState)
          (freshRun graphBoth)
          ownerA
          1000000
          (pure ())
          ( \context plan -> do
              let receipts = cleanupNodeExecutionDependencyReceipts context
              modifyIORef'
                observed
                ( ++
                    [
                      ( cleanupNodeIdText (cleanupNodeId plan)
                      , cleanupRunIdText (cleanupNodeExecutionRunId context)
                      , [ ( cleanupNodeIdText (cleanupDependencyReceiptNodeId receipt)
                          , cleanupOperationIdText
                              (cleanupDependencyReceiptOperationId receipt)
                          , cleanupAttemptIdText
                              (cleanupDependencyReceiptAttemptId receipt)
                          , cleanupDependencyReceiptKind receipt
                          , cleanupDependencyReceiptOutcome receipt
                          )
                        | receipt <- receipts
                        ]
                      )
                    ]
                )
              pure CleanupNodeSucceeded
          )
      case result of
        Left err -> expectationFailure (show err)
        Right _ -> pure ()
      observedContexts <- readIORef observed
      let matchesObservedContexts contexts = case contexts of
            [ ("drain", "run-1", [])
              , ( "destroy"
                  , "run-1"
                  , [ ( "drain"
                        , drainOperation
                        , drainAttempt
                        , CleanupRequiresAttempt
                        , CleanupNodeSucceeded
                        )
                      ]
                  )
              ] ->
                drainOperation == cleanupOperationIdText (cleanupNodeOperationId nodeA)
                  && validAttemptIdentity drainAttempt
            _ -> False
      observedContexts `shouldSatisfy` matchesObservedContexts

    it "separates attempt identity across cleanup runs at the same fence" $ do
      first <- runAttempts "run-1"
      second <- runAttempts "run-2"
      first `shouldSatisfy` all validAttemptIdentity
      second `shouldSatisfy` all validAttemptIdentity
      first `shouldSatisfy` \attempts -> all (`notElem` second) attempts
      firstKeys <- runExecutionKeys "run-key-1"
      secondKeys <- runExecutionKeys "run-key-2"
      firstKeys `shouldSatisfy` all validEksAuthExecutionKey
      secondKeys `shouldSatisfy` all validEksAuthExecutionKey
      firstKeys `shouldSatisfy` \keys -> all (`notElem` secondKeys) keys

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

nodeAId, nodeBId, nodeCId, unknownId :: CleanupNodeId
nodeAId = expectRight (mkCleanupNodeId "drain")
nodeBId = expectRight (mkCleanupNodeId "destroy")
nodeCId = expectRight (mkCleanupNodeId "summarize")
unknownId = expectRight (mkCleanupNodeId "unknown")

nodeA, nodeB, nodeCFromAttempt, nodeCFromBlocked :: CleanupNodePlan
nodeA = nodePlan nodeAId (expectRight (mkCleanupOperationId "run-1/drain")) [] "cleanup/drain"
nodeB =
  nodePlan
    nodeBId
    (expectRight (mkCleanupOperationId "run-1/destroy"))
    [requiresAttempt nodeAId]
    "cleanup/destroy"
nodeCFromAttempt =
  nodePlan
    nodeCId
    (expectRight (mkCleanupOperationId "run-1/summarize-attempt"))
    [requiresTerminal nodeAId]
    "cleanup/summarize-attempt"
nodeCFromBlocked =
  nodePlan
    nodeCId
    (expectRight (mkCleanupOperationId "run-1/summarize-blocked"))
    [requiresTerminal nodeBId]
    "cleanup/summarize-blocked"

nodePlan :: CleanupNodeId -> CleanupOperationId -> [CleanupDependency] -> Text -> CleanupNodePlan
nodePlan nodeId operationId dependencies logical =
  mkCleanupNodePlan (destroyRef logical) nodeId operationId dependencies

requiresSuccess, requiresAttempt, requiresTerminal :: CleanupNodeId -> CleanupDependency
requiresSuccess nodeId = CleanupDependency nodeId CleanupRequiresSuccess
requiresAttempt nodeId = CleanupDependency nodeId CleanupRequiresAttempt
requiresTerminal nodeId = CleanupDependency nodeId CleanupRequiresTerminal

graphA, graphBoth, graphSuccess, graphTerminalAttempted, graphTerminalBlocked :: CleanupGraph
graphA = expectRight (mkCleanupGraph [nodeA])
graphBoth = expectRight (mkCleanupGraph [nodeA, nodeB])
graphSuccess =
  expectRight
    ( mkCleanupGraph
        [nodeA, nodePlan nodeBId (cleanupNodeOperationId nodeB) [requiresSuccess nodeAId] "cleanup/destroy"]
    )
graphTerminalAttempted = expectRight (mkCleanupGraph [nodeA, nodeCFromAttempt])
graphTerminalBlocked =
  expectRight
    ( mkCleanupGraph
        [ nodeA
        , nodePlan
            nodeBId
            (cleanupNodeOperationId nodeB)
            [requiresSuccess nodeAId]
            "cleanup/destroy"
        , nodeCFromBlocked
        ]
    )

ownerA, ownerB :: CleanupOwnerId
ownerA = expectRight (mkCleanupOwnerId "runner-a")
ownerB = expectRight (mkCleanupOwnerId "runner-b")

attemptA, attemptB :: CleanupAttemptId
attemptA = expectRight (mkCleanupAttemptId "attempt-a")
attemptB = expectRight (mkCleanupAttemptId "attempt-b")

digestText :: Text
digestText = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

descriptorDigest, alternateDescriptorDigest :: CleanupDigest
descriptorDigest = expectRight (mkCleanupDigest digestText)
alternateDescriptorDigest =
  expectRight
    (mkCleanupDigest "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")

data FixtureCleanupRunEnvelope
  = FixtureCleanupRunEnvelope !Word16 !CleanupRun
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureCleanupRunReportEnvelope
  = FixtureCleanupRunReportEnvelope !Word16 !CleanupRunReport
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureStored
  = FixtureStoredActive !CleanupRun
  | FixtureStoredTombstone !CleanupRunTombstone
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureLegacyStoredEnvelope
  = FixtureLegacyStoredEnvelope !Word16 !FixtureStored
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureCurrentStoredEnvelope
  = FixtureCurrentStoredEnvelope !Word16 !CleanupRunStored
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureIndexEntry
  = FixtureIndexActive !CleanupRun
  | FixtureIndexTombstone !CleanupRunTombstone
  deriving stock (Generic)
  deriving anyclass (Serialise)

newtype FixtureIndex = FixtureIndex [FixtureIndexEntry]
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureLegacyIndexEnvelope
  = FixtureLegacyIndexEnvelope !Word16 !FixtureIndex
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureCurrentIndexEnvelope
  = FixtureCurrentIndexEnvelope !Word16 !CleanupRunIndex
  deriving stock (Generic)
  deriving anyclass (Serialise)

data FixtureDescriptorResponseEnvelope
  = FixtureDescriptorResponseEnvelope !Word16 !CleanupRunDescriptorResponse
  deriving stock (Generic)
  deriving anyclass (Serialise)

fixtureCleanupRunBytes :: Word16 -> CleanupRun -> ByteString.ByteString
fixtureCleanupRunBytes version =
  LazyByteString.toStrict
    . serialise
    . FixtureCleanupRunEnvelope version

fixtureCleanupRunReportBytes
  :: Word16 -> CleanupRunReport -> ByteString.ByteString
fixtureCleanupRunReportBytes version =
  LazyByteString.toStrict
    . serialise
    . FixtureCleanupRunReportEnvelope version

fixtureLegacyStoredBytes :: FixtureStored -> ByteString.ByteString
fixtureLegacyStoredBytes =
  LazyByteString.toStrict
    . serialise
    . FixtureLegacyStoredEnvelope 1

fixtureCurrentStoredBytes
  :: Word16 -> CleanupRunStored -> ByteString.ByteString
fixtureCurrentStoredBytes version =
  LazyByteString.toStrict
    . serialise
    . FixtureCurrentStoredEnvelope version

fixtureLegacyIndexBytes :: [FixtureIndexEntry] -> ByteString.ByteString
fixtureLegacyIndexBytes =
  LazyByteString.toStrict
    . serialise
    . FixtureLegacyIndexEnvelope 1
    . FixtureIndex

fixtureCurrentIndexBytes
  :: Word16 -> CleanupRunIndex -> ByteString.ByteString
fixtureCurrentIndexBytes version =
  LazyByteString.toStrict
    . serialise
    . FixtureCurrentIndexEnvelope version

fixtureDescriptorResponseBytes
  :: Word16 -> CleanupRunDescriptorResponse -> ByteString.ByteString
fixtureDescriptorResponseBytes version =
  LazyByteString.toStrict
    . serialise
    . FixtureDescriptorResponseEnvelope version

descriptorActivationPublishesIndexBeforePrimary :: String -> Bool
descriptorActivationPublishesIndexBeforePrimary source =
  let (_, body) =
        Text.breakOn
          "createAfterDescriptorReadBack provider runId expectedDescriptorDigest"
          (Text.pack source)
      (_, fromIndex) = Text.breakOn "registerDescriptorBoundCleanupRun" body
      (_, fromPrimary) = Text.breakOn "createDescriptorBoundCleanupRunDurably" body
   in not (Text.null body)
        && not (Text.null fromIndex)
        && not (Text.null fromPrimary)
        && Text.length fromIndex > Text.length fromPrimary

isLeftResult :: Either error value -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False

freshRun :: CleanupGraph -> CleanupRun
freshRun = freshRunNamed "run-1"

freshRunNamed :: Text -> CleanupGraph -> CleanupRun
freshRunNamed runName graph =
  expectRight
    ( newCleanupRun
        (expectRight (mkCleanupRunId runName))
        graph
        ownerA
        0
        100
    )

validAttemptIdentity :: Text -> Bool
validAttemptIdentity identity =
  "cleanup-attempt/" `Text.isPrefixOf` identity
    && Text.length identity == 80

validEksAuthExecutionKey :: Text -> Bool
validEksAuthExecutionKey identity =
  "eks-auth-execution-" `Text.isPrefixOf` identity
    && Text.length identity == 83

runAttempts :: Text -> IO [Text]
runAttempts runName = do
  state <- newIORef Nothing
  indexState <- newIORef Nothing
  attempts <- newIORef []
  result <-
    runWithDurableCleanupWithAttempt
      16384
      (endpointClient state indexState)
      (freshRunNamed runName graphBoth)
      ownerA
      1000000
      (pure ())
      ( \attempt _ -> do
          modifyIORef' attempts (++ [cleanupAttemptIdText attempt])
          pure CleanupNodeSucceeded
      )
  case result of
    Left err -> expectationFailure (show err) >> pure []
    Right _ -> readIORef attempts

runExecutionKeys :: Text -> IO [Text]
runExecutionKeys runName = do
  state <- newIORef Nothing
  indexState <- newIORef Nothing
  keys <- newIORef []
  result <-
    runWithDurableCleanupWithContext
      16384
      (endpointClient state indexState)
      (freshRunNamed runName graphBoth)
      ownerA
      1000000
      (pure ())
      ( \context _ -> do
          modifyIORef' keys (++ [eksClientAuthExecutionSubmissionKey context])
          pure CleanupNodeSucceeded
      )
  case result of
    Left err -> expectationFailure (show err) >> pure []
    Right _ -> readIORef keys

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
        pure $ case stored of
          Nothing -> Right CleanupRunMissing
          Just (revision, CleanupRunStoredActive run) ->
            Right (CleanupRunObserved revision run)
          Just (revision, CleanupRunStoredTombstone tombstone) ->
            Right (CleanupRunTombstoned revision tombstone)
          Just (_, CleanupRunStoredDescriptorBoundActive {}) ->
            Left "cleanup run uses the descriptor-bound protocol"
          Just (_, CleanupRunStoredDescriptorBoundTombstone {}) ->
            Left "cleanup run uses the descriptor-bound protocol"
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

memoryDescriptorBoundRepository
  :: IORef (Maybe (Int, CleanupRunStored))
  -> DescriptorBoundCleanupRunRepository IO Int
memoryDescriptorBoundRepository state =
  DescriptorBoundCleanupRunRepository
    { readDescriptorBoundCleanupRun = do
        stored <- readIORef state
        pure $ case stored of
          Nothing -> Right DescriptorBoundCleanupRunMissing
          Just (revision, CleanupRunStoredActive _) ->
            Right (DescriptorBoundCleanupRunLegacyState revision)
          Just (revision, CleanupRunStoredTombstone _) ->
            Right (DescriptorBoundCleanupRunLegacyState revision)
          Just
            ( revision
              , CleanupRunStoredDescriptorBoundActive digest run
              ) ->
              Right
                ( DescriptorBoundCleanupRunObserved
                    revision
                    digest
                    run
                )
          Just
            ( revision
              , CleanupRunStoredDescriptorBoundTombstone digest tombstone
              ) ->
              Right
                ( DescriptorBoundCleanupRunTombstoned
                    revision
                    digest
                    tombstone
                )
    , compareAndSwapDescriptorBoundCleanupRun = \expected digest run -> do
        stored <- readIORef state
        if (fst <$> stored) /= expected
          then pure (Left "descriptor primary conflict")
          else do
            writeIORef
              state
              ( Just
                  ( maybe 1 ((+ 1) . fst) stored
                  , CleanupRunStoredDescriptorBoundActive digest run
                  )
              )
            pure (Right ())
    , compareAndSwapDescriptorBoundCleanupRunTombstone =
        \expected digest tombstone -> do
          stored <- readIORef state
          if (fst <$> stored) /= Just expected
            then pure (Left "descriptor primary tombstone conflict")
            else do
              writeIORef
                state
                ( Just
                    ( expected + 1
                    , CleanupRunStoredDescriptorBoundTombstone digest tombstone
                    )
                )
              pure (Right ())
    }

unavailableLegacyRepository :: CleanupRunRepository IO Int
unavailableLegacyRepository =
  CleanupRunRepository
    { readCleanupRun = pure (Left "legacy repository must not be read")
    , compareAndSwapCleanupRun = \_ _ -> pure (Left "legacy repository must not be written")
    , compareAndSwapCleanupRunTombstone =
        \_ _ -> pure (Left "legacy repository must not be written")
    }

unavailableDescriptorRepository
  :: DescriptorBoundCleanupRunRepository IO Int
unavailableDescriptorRepository =
  DescriptorBoundCleanupRunRepository
    { readDescriptorBoundCleanupRun = pure (Left "not configured")
    , compareAndSwapDescriptorBoundCleanupRun =
        \_ _ _ -> pure (Left "not configured")
    , compareAndSwapDescriptorBoundCleanupRunTombstone =
        \_ _ _ -> pure (Left "not configured")
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
        , descriptorBoundCleanupRunRepositoryFor =
            const unavailableDescriptorRepository
        , cleanupRunIndexRepository = memoryIndexRepository indexState
        , cleanupRunAggregateBackup = backup
        , cleanupProgramDescriptorAuthorityClient = Nothing
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
