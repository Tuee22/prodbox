{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module GatewayEmitterActor
  ( gatewayEmitterActorSuite
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryPutMVar
  )
import Data.ByteString.Char8 qualified as BS8
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Word (Word64)
import Prodbox.ControlPlane.Capacity
  ( RawServiceCapacityPlan (..)
  , ServiceCapacityPlan
  , mkServiceCapacityPlan
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , RemainingDuration (..)
  , RetryAfter (..)
  , WorkEstimate (..)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.Gateway.Continuity qualified as Continuity
import Prodbox.Gateway.Emitter.Actor
import Prodbox.Gateway.Emitter.Kernel
import Prodbox.Gateway.Emitter.Mailbox
import System.Timeout (timeout)
import TestSupport

gatewayEmitterActorSuite :: SuiteBuilder ()
gatewayEmitterActorSuite =
  describe "Sprint 2.32 live single-writer emitter actor" $ do
    it "executes one heartbeat through all five ordered durable phases" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      interpreter <- successfulInterpreter effects tickets Nothing
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        result <- submitEmitterRequest actor (ReqHeartbeat (HeartbeatPayload 7))
        record <- expectCommitted result
        stagedRecordKind record `shouldBe` KindHeartbeat (HeartbeatPayload 7)
        Continuity.continuityAnchorSequence (stagedRecordNextAnchor record) `shouldBe` 1
      readIORef effects
        `shouldReturn` ["stage", "fsync", "publish", "commit", "fsync"]

    it "uses fresh tickets for the failed sign attempt, rotation, and parked advance" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      stageCoordinates <- newIORef []
      base <- successfulInterpreter effects tickets Nothing
      let interpreter =
            base
              { emitterMintTicket = do
                  number <- atomicModifyIORef' tickets (\value -> (value + 1, value + 1))
                  let now = monotonicInstantFromMicros 0
                  pure
                    ( now
                    , deadlineAtOffset now (RemainingDuration (1000000 + fromIntegral number))
                    )
              , emitterStage = \admission deadline plan -> do
                  modifyIORef' stageCoordinates (++ [(admission, deadline)])
                  emitterStage base admission deadline plan
              }
      let exhausted =
            mkEmitterState
              (anchorAt 4 maxBound)
              (mkIncarnation 9)
              mailbox
              8
      withEmitterActor actorConfig exhausted interpreter $ \actor -> do
        result <- submitEmitterRequest actor (ReqOwnership OwnershipClaim)
        record <- expectCommitted result
        stagedRecordKind record `shouldBe` KindOwnership OwnershipClaim
        Continuity.continuityAnchorEpoch (stagedRecordNextAnchor record) `shouldBe` 5
        Continuity.continuityAnchorSequence (stagedRecordNextAnchor record) `shouldBe` 1
      readIORef tickets `shouldReturn` 3
      coordinates <- readIORef stageCoordinates
      map (transitionAdmissionValue . fst) coordinates `shouldBe` [0, 1, 2]
      map snd coordinates `shouldSatisfy` allDistinct

    it "refreshes an expired staged deadline after a transient fsync failure" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      observations <- newIORef [0, 4000]
      postStageDeadlines <- newIORef []
      failFirstFsync <- newIORef True
      base <- successfulInterpreter effects tickets Nothing
      let oldDeadline =
            deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 3000)
          recoveryDeadline =
            deadlineAtOffset (monotonicInstantFromMicros 4000) (RemainingDuration 10000)
      let interpreter =
            base
              { emitterMintTicket = do
                  number <- atomicModifyIORef' tickets (\value -> (value + 1, value + 1))
                  pure $
                    if number == 1
                      then (monotonicInstantFromMicros 0, oldDeadline)
                      else (monotonicInstantFromMicros 4000, recoveryDeadline)
              , emitterObserveNow =
                  monotonicInstantFromMicros . fromIntegral <$> popObservation observations
              , emitterFsyncProjection = \deadline _ -> do
                  modifyIORef' postStageDeadlines (++ [deadline])
                  modifyIORef' effects (++ ["fsync"])
                  shouldFail <- atomicModifyIORef' failFirstFsync (False,)
                  pure (if shouldFail then Left "injected fsync failure" else Right ())
              , emitterPublish = \deadline record -> do
                  modifyIORef' postStageDeadlines (++ [deadline])
                  emitterPublish base deadline record
              , emitterCommit = \deadline record -> do
                  modifyIORef' postStageDeadlines (++ [deadline])
                  emitterCommit base deadline record
              }
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        first <- submitEmitterRequest actor (ReqOwnership OwnershipClaim)
        first `shouldBe` Left (EmitterActorInterpreterFailed "injected fsync failure")
        recovered <- submitEmitterRequest actor ReqRecover
        _ <- expectCommitted recovered
        pure ()
      readIORef effects
        `shouldReturn` [ "stage"
                       , "fsync"
                       , "fsync"
                       , "publish"
                       , "commit"
                       , "fsync"
                       ]
      readIORef postStageDeadlines
        `shouldReturn` [ oldDeadline
                       , recoveryDeadline
                       , recoveryDeadline
                       , recoveryDeadline
                       , recoveryDeadline
                       ]

    it "restarts from the last safe stage projection and republishes exact bytes" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      projections <- newIORef []
      publishedRecords <- newIORef []
      failFirstCommit <- newIORef True
      base <- successfulInterpreter effects tickets Nothing
      let interpreter =
            base
              { emitterFsyncProjection = \deadline projection -> do
                  modifyIORef' projections (++ [projection])
                  emitterFsyncProjection base deadline projection
              , emitterPublish = \deadline record -> do
                  modifyIORef' publishedRecords (++ [record])
                  emitterPublish base deadline record
              , emitterCommit = \deadline record -> do
                  shouldFail <- atomicModifyIORef' failFirstCommit (False,)
                  if shouldFail
                    then do
                      modifyIORef' effects (++ ["commit"])
                      pure (Left "injected post-publish commit failure")
                    else emitterCommit base deadline record
              }
          stateWithPeer =
            mkEmitterStateForPeers
              (anchorAt 1 0)
              (mkIncarnation 1)
              mailbox
              8
              [peerA]
      (safeProjection, publishedRecord) <-
        withEmitterActor actorConfig stateWithPeer interpreter $ \actor -> do
          first <- submitEmitterRequest actor (ReqOwnership OwnershipClaim)
          first
            `shouldBe` Left
              (EmitterActorInterpreterFailed "injected post-publish commit failure")
          records <- readIORef publishedRecords
          record <- case records of
            [value] -> pure value
            values -> do
              expectationFailure
                ("expected one pre-failure publication, got " ++ show (length values))
              fail "unreachable"
          let point =
                mkAckPoint
                  (stagedRecordIncarnation record)
                  (stagedRecordNextAnchor record)
          acknowledgeEmitterPeerThrough actor peerA point
            `shouldReturn` Left (EmitterActorKernelRejected RejectBusy)
          persisted <- readIORef projections
          case persisted of
            [projection] -> pure (projection, record)
            values -> do
              expectationFailure
                ("unsafe acknowledgement changed projection count to " ++ show (length values))
              fail "unreachable"
      let recoveryDeadline = deadlineAfter 1000000
          restored =
            either
              (error . show)
              id
              (restoreDurableEmitterState mailbox recoveryDeadline safeProjection)
          safeInFlight = maybe (error "missing safe in-flight transition") id (emitterInFlight restored)
      inFlightPhase safeInFlight `shouldBe` PhaseFsyncingStage
      inFlightPublished safeInFlight `shouldBe` False
      inFlightStagedRecord safeInFlight `shouldBe` Just publishedRecord
      withEmitterActor actorConfig restored interpreter $ \actor -> do
        recovered <- submitEmitterRequest actor ReqRecover
        committed <- expectCommitted recovered
        committed `shouldBe` publishedRecord
      readIORef publishedRecords `shouldReturn` [publishedRecord, publishedRecord]
      persisted <- readIORef projections
      map durableProjectionStagedRecord persisted
        `shouldBe` [Just publishedRecord, Just publishedRecord, Nothing]
      readIORef effects
        `shouldReturn` [ "stage"
                       , "fsync"
                       , "publish"
                       , "commit"
                       , "fsync"
                       , "publish"
                       , "commit"
                       , "fsync"
                       ]

    it "rejects work whose capacity estimate cannot meet its deadline" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      base <- successfulInterpreter effects tickets Nothing
      let now = monotonicInstantFromMicros 0
          interpreter =
            base
              { emitterMintTicket =
                  pure (now, deadlineAtOffset now (RemainingDuration 2000))
              }
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        result <- submitEmitterRequest actor (ReqOwnership OwnershipClaim)
        result
          `shouldBe` Left
            ( EmitterActorDeadlineUnmeetable
                (WorkEstimate 2500)
                (RemainingDuration 2000)
            )
      readIORef effects `shouldReturn` []

    it "does not orphan or misattribute a normal request submitted while recovery is required" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      failFirstFsync <- newIORef True
      stagedKinds <- newIORef []
      base <- successfulInterpreter effects tickets Nothing
      let interpreter =
            base
              { emitterStage = \admission deadline plan -> do
                  modifyIORef' stagedKinds (++ [stagePlanKind plan])
                  emitterStage base admission deadline plan
              , emitterFsyncProjection = \deadline projection -> do
                  shouldFail <- atomicModifyIORef' failFirstFsync (False,)
                  if shouldFail
                    then pure (Left "injected fsync failure")
                    else emitterFsyncProjection base deadline projection
              }
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        first <- submitEmitterRequest actor (ReqOwnership OwnershipClaim)
        first `shouldBe` Left (EmitterActorInterpreterFailed "injected fsync failure")
        submitEmitterRequest actor (ReqOwnership OwnershipYield)
          `shouldReturn` Left (EmitterActorKernelRejected RejectBusy)
        _ <- submitEmitterRequest actor ReqRecover >>= expectCommitted
        next <- submitEmitterRequest actor (ReqHeartbeat (HeartbeatPayload 42)) >>= expectCommitted
        stagedRecordKind next `shouldBe` KindHeartbeat (HeartbeatPayload 42)
      readIORef stagedKinds
        `shouldReturn` [KindOwnership OwnershipClaim, KindHeartbeat (HeartbeatPayload 42)]

    it "refuses promptly when the bounded command queue is saturated" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      started <- newEmptyMVar
      release <- newEmptyMVar
      interpreter <- successfulInterpreter effects tickets (Just (started, release))
      let saturatedState =
            mkEmitterState
              (anchorAt 1 0)
              (mkIncarnation 1)
              (emitterActorMailbox saturatedActorConfig)
              8
      withEmitterActor saturatedActorConfig saturatedState interpreter $ \actor -> do
        first <- async (submitEmitterRequest actor (ReqOwnership OwnershipClaim))
        takeMVar started
        second <- submitEmitterRequest actor (ReqOwnership OwnershipYield)
        second `shouldBe` Left (EmitterActorOverloaded (RetryAfter 2500))
        putMVar release ()
        _ <- wait first >>= expectCommitted
        pure ()

    it "rejects a queued command when queue wait crosses its absolute deadline" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      observations <- newIORef [0, 7000]
      started <- newEmptyMVar
      release <- newEmptyMVar
      base <- successfulInterpreter effects tickets (Just (started, release))
      let initialDeadline =
            deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 1000000)
          queuedDeadline =
            deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 6000)
          interpreter =
            base
              { emitterMintTicket = do
                  number <- atomicModifyIORef' tickets (\value -> (value + 1, value + 1))
                  pure
                    ( monotonicInstantFromMicros 0
                    , if number == 1 then initialDeadline else queuedDeadline
                    )
              , emitterObserveNow =
                  monotonicInstantFromMicros . fromIntegral <$> popObservation observations
              }
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        first <- async (submitEmitterRequest actor (ReqOwnership OwnershipClaim))
        takeMVar started
        queued <- async (submitEmitterRequest actor (ReqOwnership OwnershipYield))
        threadDelay 20000
        putMVar release ()
        _ <- wait first >>= expectCommitted
        wait queued
          `shouldReturn` Left (EmitterActorKernelRejected RejectDeadlineExpired)
      readIORef effects
        `shouldReturn` ["stage", "fsync", "publish", "commit", "fsync"]

    it "coalesces the live queue in place and keeps the freshest heartbeat" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      stagedKinds <- newIORef []
      started <- newEmptyMVar
      release <- newEmptyMVar
      base <- successfulInterpreter effects tickets (Just (started, release))
      let interpreter =
            base
              { emitterStage = \admission deadline plan -> do
                  modifyIORef' stagedKinds (++ [stagePlanKind plan])
                  emitterStage base admission deadline plan
              }
      withEmitterActor actorConfig initialState interpreter $ \actor -> do
        first <- async (submitEmitterRequest actor (ReqOwnership OwnershipClaim))
        takeMVar started
        fresh <- async (submitEmitterRequest actor (ReqHeartbeat (HeartbeatPayload 9)))
        threadDelay 10000
        stale <- async (submitEmitterRequest actor (ReqHeartbeat (HeartbeatPayload 4)))
        threadDelay 10000
        putMVar release ()
        _ <- wait first >>= expectCommitted
        wait fresh `shouldReturn` Right EmitterNoTransition
        coalesced <- wait stale >>= expectCommitted
        stagedRecordKind coalesced `shouldBe` KindHeartbeat (HeartbeatPayload 9)
      readIORef stagedKinds
        `shouldReturn` [KindOwnership OwnershipClaim, KindHeartbeat (HeartbeatPayload 9)]

    it "persists peer acknowledgement before adoption and safely retries a failed fsync" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      persistCalls <- newIORef (0 :: Word)
      projections <- newIORef []
      base <- successfulInterpreter effects tickets Nothing
      let interpreter =
            base
              { emitterFsyncProjection = \deadline projection -> do
                  call <- atomicModifyIORef' persistCalls (\value -> (value + 1, value + 1))
                  modifyIORef' projections (++ [projection])
                  if call == 3
                    then pure (Left "injected ack fsync failure")
                    else emitterFsyncProjection base deadline projection
              }
          stateWithPeer =
            mkEmitterStateForPeers
              (anchorAt 1 0)
              (mkIncarnation 1)
              mailbox
              8
              [peerA]
      withEmitterActor actorConfig stateWithPeer interpreter $ \actor -> do
        committed <-
          submitEmitterRequest actor (ReqOwnership OwnershipClaim) >>= expectCommitted
        let point =
              mkAckPoint
                (stagedRecordIncarnation committed)
                (stagedRecordNextAnchor committed)
        firstAck <- acknowledgeEmitterPeerThrough actor peerA point
        firstAck
          `shouldBe` Left (EmitterActorInterpreterFailed "injected ack fsync failure")
        acknowledgeEmitterPeerThrough actor peerA point `shouldReturn` Right ()
        persisted <- readIORef projections
        lastProjection <- case reverse persisted of
          [] -> expectationFailure "expected a persisted acknowledgement projection" >> fail "unreachable"
          projection : _ -> pure projection
        let restored =
              either
                (error . show)
                id
                (restoreDurableEmitterState mailbox (deadlineAfter 1000000) lastProjection)
        Map.lookup peerA (emitterPeerAcknowledgements restored)
          `shouldBe` Just (Just point)
        case emitterUnacked restored of
          [retained] -> do
            unackedAssertionRecord retained `shouldBe` committed
            unackedAssertionWaitingPeers retained `shouldBe` Set.empty
          values -> expectationFailure ("expected one retained assertion, got " ++ show values)
      readIORef persistCalls `shouldReturn` 4

    it "threads the governing absolute deadline through checkpoint install and fsync" $ actorTest $ do
      effects <- newIORef []
      tickets <- newIORef 0
      checkpointDeadlines <- newIORef []
      persistedDeadlines <- newIORef []
      base <- successfulInterpreter effects tickets Nothing
      let interpreter =
            base
              { emitterFsyncProjection = \deadline projection -> do
                  modifyIORef' persistedDeadlines (++ [deadline])
                  emitterFsyncProjection base deadline projection
              , emitterInstallCheckpoint = \deadline candidate -> do
                  modifyIORef' checkpointDeadlines (++ [deadline])
                  emitterInstallCheckpoint base deadline candidate
              }
          checkpointingState =
            mkEmitterStateForPeers
              (anchorAt 1 0)
              (mkIncarnation 1)
              mailbox
              0
              [peerA]
          governingDeadline = deadlineAfter 1000000
      withEmitterActor actorConfig checkpointingState interpreter $ \actor -> do
        _ <- submitEmitterRequest actor (ReqOwnership OwnershipClaim) >>= expectCommitted
        pure ()
      readIORef checkpointDeadlines `shouldReturn` [governingDeadline]
      readIORef persistedDeadlines
        `shouldReturn` [governingDeadline, governingDeadline, governingDeadline]

actorConfig :: EmitterActorConfig
actorConfig =
  maybe (error "actor config") id (mkEmitterActorConfig actorCapacityPlan)

saturatedActorConfig :: EmitterActorConfig
saturatedActorConfig =
  maybe (error "saturated actor config") id (mkEmitterActorConfig saturatedActorCapacityPlan)

actorCapacityPlan :: ServiceCapacityPlan
actorCapacityPlan =
  either (error . show) id $
    mkServiceCapacityPlan
      RawServiceCapacityPlan
        { rawArrivalPerSecond = 1
        , rawServiceTimeMicros = 2500
        , rawWorkerCount = 1
        , rawQueueCapacity = 2
        , rawRejectionThreshold = 2
        , rawHeadroomPpm = 100000
        }

saturatedActorCapacityPlan :: ServiceCapacityPlan
saturatedActorCapacityPlan =
  either (error . show) id $
    mkServiceCapacityPlan
      RawServiceCapacityPlan
        { rawArrivalPerSecond = 1
        , rawServiceTimeMicros = 2500
        , rawWorkerCount = 1
        , rawQueueCapacity = 1
        , rawRejectionThreshold = 1
        , rawHeadroomPpm = 100000
        }

mailbox :: Mailbox
mailbox = emitterActorMailbox actorConfig

initialState :: EmitterState
initialState = mkEmitterState (anchorAt 1 0) (mkIncarnation 1) mailbox 8

peerA :: EmitterPeer
peerA = maybe (error "peer-a") id (mkEmitterPeer "peer-a")

deadlineAfter :: Word64 -> Deadline
deadlineAfter budget =
  deadlineAtOffset
    (monotonicInstantFromMicros 0)
    (RemainingDuration (fromIntegral budget))

boundedPayload :: BS8.ByteString -> BoundedSignedPayload
boundedPayload bytes =
  either (error . show) id (mkBoundedSignedPayload 4096 bytes)

anchorAt :: Word64 -> Word64 -> Continuity.ContinuityAnchor
anchorAt epoch sequenceNumber =
  let bounds = either (error . show) id (Continuity.mkContinuityBounds 256 256 4096)
      scope =
        either (error . show) id $
          Continuity.mkContinuityScope bounds "emitter-a" "orders-anchor"
      digest =
        either (error . show) id $
          Continuity.mkContinuityDigest (BS8.replicate 32 '\0')
   in Continuity.authorityRecordCommittedAnchor
        ( Continuity.mkInitialAuthorityRecord
            scope
            (fromIntegral epoch)
            (fromIntegral sequenceNumber)
            digest
        )

successfulInterpreter
  :: IORef [Text]
  -> IORef Word
  -> Maybe (MVar (), MVar ())
  -> IO EmitterInterpreter
successfulInterpreter effects tickets maybeStageGate = do
  signedCounter <- newIORef (0 :: Word)
  pure
    EmitterInterpreter
      { emitterMintTicket = do
          _ <- atomicModifyIORef' tickets (\value -> (value + 1, value + 1))
          let now = monotonicInstantFromMicros 0
          pure (now, deadlineAtOffset now (RemainingDuration 1000000))
      , emitterObserveNow = pure (monotonicInstantFromMicros 0)
      , emitterStage = \_admission _deadline plan -> do
          modifyIORef' effects (++ ["stage"])
          case maybeStageGate of
            Nothing -> pure ()
            Just (started, release) -> do
              _ <- tryPutMVar started ()
              readMVar release
          if stagePlanTransition plan == Continuity.SemanticAdvance
            && Continuity.continuityAnchorSequence (stagePlanPreviousAnchor plan) == maxBound
            then pure (Right StageNeedsRotation)
            else do
              serial <- atomicModifyIORef' signedCounter (\value -> (value + 1, value + 1))
              pure
                ( Right
                    (StageStaged (boundedPayload (BS8.pack ("signed-" ++ show serial))))
                )
      , emitterFsyncProjection = \_ _ -> record "fsync"
      , emitterPublish = \_ _ -> record "publish"
      , emitterCommit = \_ _ -> record "commit"
      , emitterInstallCheckpoint = \_ _ ->
          pure (Right (CheckpointInstalled (boundedPayload "signed-checkpoint")))
      , emitterRestoreRetained = \_ _ -> pure (Right ())
      }
 where
  record label = modifyIORef' effects (++ [label]) >> pure (Right ())

expectCommitted
  :: Either EmitterActorError EmitterCompletion
  -> IO StagedRecord
expectCommitted result = case result of
  Right (EmitterCommitted record) -> pure record
  other -> do
    expectationFailure ("expected committed emitter transition, got " ++ show other)
    fail "unreachable"

actorTest :: Expectation -> Expectation
actorTest action = do
  completed <- timeout 2000000 action
  case completed of
    Nothing -> expectationFailure "actor test exceeded its 2-second bound"
    Just () -> pure ()

popObservation :: IORef [Word64] -> IO Word64
popObservation ref =
  atomicModifyIORef' ref popObservationValue

popObservationValue :: [Word64] -> ([Word64], Word64)
popObservationValue values = case values of
  [] -> ([], 0)
  value : remaining -> (remaining, value)

allDistinct :: (Eq value) => [value] -> Bool
allDistinct values = length (nub values) == length values
