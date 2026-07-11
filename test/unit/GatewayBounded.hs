{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module GatewayBounded
  ( gatewayBoundedSuite
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word64, Word8)
import Numeric.Natural (Natural)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Gateway.Bounds qualified as Bounds
import Prodbox.Gateway.Peer qualified as Peer
import Prodbox.Gateway.Settings qualified as Settings
import Prodbox.Gateway.State qualified as State
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import System.IO (hClose, hFlush)
import System.IO.Temp (withSystemTempFile)
import Test.Tasty.QuickCheck (NonNegative (..), Small (..))
import TestSupport

gatewayBoundedSuite :: SuiteBuilder ()
gatewayBoundedSuite =
  describe "Sprint 2.31 bounded gateway core" $ do
    propertyTest
      "arbitrarily long heartbeat histories preserve every finite cardinality"
      boundedHeartbeatHistoryProperty
    propertyTest
      "arbitrarily repeated duplicate delivery is idempotent and bounded"
      duplicateDeliveryProperty
    propertyTest
      "multi-emitter partition delivery converges with monotonic cursors"
      multiEmitterConvergenceProperty
    propertyTest
      "arbitrary Orders churn retains only one promotion slot"
      ordersChurnProperty
    propertyTest
      "epoch invalidation advances fixed-width coordinates without wrapping"
      epochRotationProperty

    it "rejects zero for every authored gateway bound" $ do
      let memoryPlan = runtimeMemoryPlan 1
      mapM_
        ( \(field, makeZero) ->
            Bounds.validateGatewayBounds memoryPlan (makeZero rawGatewayBounds)
              `shouldBe` Left (Bounds.GatewayBoundMustBePositive field)
        )
        zeroBoundCases

    it "requires capacity-one child scheduling and nested retained/scratch fit" $ do
      Bounds.validateGatewayBounds
        (runtimeMemoryPlan 2)
        rawGatewayBounds
        `shouldBe` Left (Bounds.GatewayChildPermitMustBeOne 2)
      Bounds.validateGatewayBounds
        (runtimeMemoryPlan 1)
        rawGatewayBounds
          { Bounds.rawMaxOrdersBytes = 11000000
          }
        `shouldSatisfy` isRetainedBudgetFailure
      Bounds.validateGatewayBounds
        (runtimeMemoryPlan 1)
        rawGatewayBounds
          { Bounds.rawMaxFrameBytes = 4000000
          , Bounds.rawMaxInFlightFrames = 6
          }
        `shouldSatisfy` isScratchBudgetFailure

    it "rejects per-peer concurrency above process concurrency" $ do
      Bounds.validateGatewayBounds
        (runtimeMemoryPlan 1)
        rawGatewayBounds
          { Bounds.rawMaxInFlightFrames = 2
          , Bounds.rawMaxInFlightFramesPerPeer = 3
          }
        `shouldBe` Left (Bounds.GatewayPerPeerInFlightExceedsProcess 3 2)

    it "exposes finite derived budgets and the Phase-1 child deadline" $ do
      let bounds = gatewayBounds
      Bounds.gatewayMaxMembers bounds `shouldBe` 3
      Bounds.gatewayReplayPerEmitter bounds `shouldBe` 4
      Bounds.gatewayDiagnosticHashCapacity `shouldBe` 64
      Bounds.gatewayRetainedBytesRequired bounds `shouldSatisfy` (> 0)
      Bounds.gatewayScratchBytesRequired bounds `shouldSatisfy` (> 0)
      Bounds.gatewayChildDeadlineMicros bounds `shouldBe` 30000000

    it "rejects raw Orders bytes before inspecting version or members" $ do
      State.validateOrders
        gatewayBounds
        State.RawOrders
          { State.rawOrdersDocument = BS.replicate 1025 0
          , State.rawOrdersVersion = -1
          , State.rawOrdersMembers = []
          }
        `shouldBe` Left (State.OrdersDocumentTooLarge 1025 1024)

    it "rejects oversized Orders through the production file loader before Dhall decode" $
      withSystemTempFile "gateway-orders-oversized.dhall" $ \path handle -> do
        BS.hPut handle (BS.replicate 1025 65)
        hFlush handle
        hClose handle
        result <- Settings.loadOrdersBounded gatewayBounds [] path
        case result of
          Left err -> err `shouldContain` "exceeds raw byte bound: 1025 > 1024"
          Right _ -> expectationFailure "oversized production Orders unexpectedly decoded"

    it "enforces every member bound through the production Orders loader" $
      withSystemTempFile "gateway-orders-bounds.dhall" $ \path handle -> do
        BS.hPut handle productionOrdersSource
        hFlush handle
        hClose handle
        Bounds.validateGatewayBounds
          (runtimeMemoryPlan 1)
          rawGatewayBounds {Bounds.rawMaxEncodedMemberBytes = 1}
          `shouldSatisfy` isMemberEncodingBoundFailure
        let keys = [("node-a", "key-a"), ("node-b", "key-b")]
            cases =
              [
                ( rawGatewayBounds {Bounds.rawMaxMembers = 1}
                , ["OrdersMemberCountExceeded", "2 1"]
                )
              ,
                ( rawGatewayBounds {Bounds.rawMaxNodeIdBytes = 5}
                , ["OrdersNodeIdTooLarge", "6 5"]
                )
              ,
                ( rawGatewayBounds {Bounds.rawMaxEndpointBytes = 8}
                , ["OrdersMemberFieldTooLarge", "EndpointField"]
                )
              ,
                ( rawGatewayBounds {Bounds.rawMaxTrustKeyBytes = 4}
                , ["OrdersMemberFieldTooLarge", "TrustKeyField"]
                )
              ]
        mapM_
          ( \(rawBounds, expectedFragments) ->
              expectProductionOrdersFailure
                path
                (gatewayBoundsFrom rawBounds)
                keys
                expectedFragments
          )
          cases

    it "requires non-empty production event keys to match Orders membership exactly" $
      withSystemTempFile "gateway-orders-keys.dhall" $ \path handle -> do
        BS.hPut handle productionOrdersSource
        hFlush handle
        hClose handle
        let cases =
              [
                ( [("node-a", "key-a")]
                , ["event_keys must match Orders membership exactly", "node-b"]
                )
              ,
                ( [("node-a", "key-a"), ("node-b", "key-b"), ("node-c", "key-c")]
                , ["event_keys must match Orders membership exactly", "node-c"]
                )
              ,
                ( [("node-a", "key-a"), ("node-a", "key-b")]
                , ["event_keys names must be unique"]
                )
              ]
        mapM_
          ( \(keys, expectedFragments) ->
              expectProductionOrdersFailure path gatewayBounds keys expectedFragments
          )
          cases

    it "keeps health and readiness branches structurally independent of operational state" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      let probeSurface =
            sourceBetween
              "handleReadRequest sock env now rawRequest ="
              "    \"/metrics\" -> do"
              daemonSource
      probeSurface `shouldContain` "\"/healthz\""
      probeSurface `shouldContain` "\"/readyz\""
      probeSurface `shouldNotContain` "envState"
      probeSurface `shouldNotContain` "stateBoundedGateway"
      probeSurface `shouldNotContain` "sortOn"
      probeSurface `shouldNotContain` "encode"

    it "keeps first admission and recovery distinct on the production continuity path" $ do
      repoRoot <- getCurrentDirectory
      daemonSource <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs")
      vaultSource <-
        readFile (repoRoot </> "src" </> "Prodbox" </> "Vault" </> "Reconcile.hs")
      let bootstrapSurface =
            sourceBetween
              "bootstrapContinuity env = do"
              "data ContinuityAdmission"
              daemonSource
          admissionTokens = words bootstrapSurface
          expectedAdmissionTokens =
            [ "ContinuityFirstAdmission"
            , "->"
            , "Continuity.initializeContinuityAtFirstAdmission"
            , "authority"
            , "admission"
            , "ContinuityPreviouslyAdmitted"
            , "->"
            , "Continuity.recoverContinuityAtStartup"
            , "authority"
            ]
          continuityPolicySurface =
            sourceBetween
              "    , \"path \\\"secret/data/prodbox/gateway/continuity-admission/*\\\" {\""
              "    , \"}\""
              vaultSource
      admissionTokens
        `shouldSatisfy` (expectedAdmissionTokens `isInfixOf`)
      daemonSource
        `shouldContain` "Left (HttpStatus 404 _) -> Right ContinuityFirstAdmission"
      daemonSource `shouldContain` "otherwise -> Left \"continuity admission marker is malformed\""
      continuityPolicySurface
        `shouldContain` "path \\\"secret/data/prodbox/gateway/continuity-admission/*\\\""
      continuityPolicySurface
        `shouldContain` "capabilities = [\\\"create\\\", \\\"read\\\", \\\"update\\\"]"

    it "rejects signed non-positive Orders versions before fixed-width conversion" $ do
      State.ordersVersionFromInt (-1)
        `shouldBe` Left (State.OrdersVersionMustBePositive (-1))
      State.ordersVersionFromInt 0
        `shouldBe` Left (State.OrdersVersionMustBePositive 0)
      State.validateOrders gatewayBounds (rawOrders (-1) [rawMember "node-a" 0])
        `shouldBe` Left (State.OrdersVersionMustBePositive (-1))

    it "derives a canonical Orders anchor after admission and redacts trust material" $ do
      let memberA = rawMember "node-a" 0
          memberB = rawMember "node-b" 1
          ordersAB = admittedOrders (rawOrders 7 [memberA, memberB])
          ordersBA = admittedOrders (rawOrders 7 [memberB, memberA])
          changed =
            admittedOrders
              ( rawOrders
                  7
                  [ memberA
                      { State.rawMemberEndpoint = "https://changed.internal:8444"
                      }
                  , memberB
                  ]
              )
          secretOrders =
            admittedOrders
              ( rawOrders
                  8
                  [ memberA
                      { State.rawMemberTrustKey = "TOP-SECRET-TRUST-MATERIAL"
                      }
                  ]
              )
      State.validatedOrdersAnchor ordersAB
        `shouldBe` State.validatedOrdersAnchor ordersBA
      State.validatedOrdersAnchor changed
        `shouldNotBe` State.validatedOrdersAnchor ordersAB
      BS.length
        (State.ordersAnchorHashBytes (State.validatedOrdersAnchor ordersAB))
        `shouldBe` 32
      show secretOrders `shouldNotContain` "TOP-SECRET-TRUST-MATERIAL"
      show (gatewayState secretOrders)
        `shouldNotContain` "TOP-SECRET-TRUST-MATERIAL"

    it "counts UTF-8 member fields in bytes and rejects duplicate identities/ranks" $ do
      let unicodeBounds =
            gatewayBoundsFrom
              rawGatewayBounds
                { Bounds.rawMaxNodeIdBytes = 3
                }
          unicodeOrders =
            rawOrders
              1
              [rawMember "éé" 0]
      State.validateOrders unicodeBounds unicodeOrders
        `shouldBe` Left (State.OrdersNodeIdTooLarge 4 3)
      State.validateOrders
        gatewayBounds
        (rawOrders 1 [rawMember "node-a" 0, rawMember "node-a" 1])
        `shouldBe` Left State.OrdersDuplicateMember
      State.validateOrders
        gatewayBounds
        (rawOrders 1 [rawMember "node-a" 0, rawMember "node-b" 0])
        `shouldBe` Left State.OrdersDuplicateRank

    it "constructs member maps only from admitted bounded Orders" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          seeds = cursorSeeds orders
          nodeA = memberId orders "node-a"
      State.validatedOrdersMemberCount orders `shouldBe` 2
      State.initializeGatewayState gatewayBounds orders seeds
        `shouldSatisfy` isRight
      State.initializeGatewayState gatewayBounds orders (Map.delete nodeA seeds)
        `shouldSatisfy` isCursorSeedMembershipFailure

    it "retains one semantic value, bounded replay, and exactly 64 diagnostic hashes" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          initialState = gatewayState orders
          initialCursor = cursorAt nodeA (cursorSeeds orders)
          (finalState, finalCursor) =
            foldl'
              (applyHeartbeat orders nodeA)
              (initialState, initialCursor)
              [1 .. 100]
      State.gatewayStateEmitterCount finalState `shouldBe` 2
      State.gatewayStateReplayCount nodeA finalState
        `shouldBe` Bounds.gatewayReplayPerEmitter gatewayBounds
      length (State.gatewayStateDiagnosticHashes finalState) `shouldBe` 64
      State.gatewayStateLatestHeartbeat nodeA finalState `shouldSatisfy` isJust
      State.emitterSequenceValue (State.emitterCursorSequence finalCursor)
        `shouldBe` 100
      State.emitterSequenceValue
        ( State.emitterCursorSequence
            (State.emitterCheckpointCursor (emitterCheckpoint nodeA finalState))
        )
        `shouldBe` 96

    it "applies bounded deltas idempotently and ignores assertion order inside a frame" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          nodeB = memberId orders "node-b"
          seeds = cursorSeeds orders
          initialState = gatewayState orders
          cursorA0 = cursorAt nodeA seeds
          cursorB0 = cursorAt nodeB seeds
          assertionA1 = nextAssertion orders nodeA cursorA0 11 (State.HeartbeatAssertion 1)
          assertionA2 =
            nextAssertion
              orders
              nodeA
              (State.assertionResultCursor assertionA1)
              12
              (State.OwnershipAssertion State.OwnershipClaim)
          assertionB1 = nextAssertion orders nodeB cursorB0 21 (State.HeartbeatAssertion 1)
          base = cursorVector orders seeds
          canonicalFrame = deltaFrame orders base [assertionA1, assertionA2, assertionB1]
          reorderedFrame = deltaFrame orders base [assertionB1, assertionA2, assertionA1]
          canonicalState = appliedDelta canonicalFrame initialState
          reorderedState = appliedDelta reorderedFrame initialState
      State.gatewayStateCursorVector reorderedState
        `shouldBe` State.gatewayStateCursorVector canonicalState
      State.gatewayStateLatestHeartbeat nodeA reorderedState
        `shouldBe` State.gatewayStateLatestHeartbeat nodeA canonicalState
      State.gatewayStateLatestOwnership nodeA reorderedState
        `shouldBe` State.gatewayStateLatestOwnership nodeA canonicalState
      appliedDelta canonicalFrame canonicalState `shouldBe` canonicalState

    it "rejects a cross-frame gap atomically, then converges after predecessor and retry" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          seeds = cursorSeeds orders
          initialState = gatewayState orders
          cursorA0 = cursorAt nodeA seeds
          assertionA1 = nextAssertion orders nodeA cursorA0 31 (State.HeartbeatAssertion 1)
          assertionA2 =
            nextAssertion
              orders
              nodeA
              (State.assertionResultCursor assertionA1)
              32
              (State.HeartbeatAssertion 2)
          base0 = cursorVector orders seeds
          baseAfterA1 =
            cursorVector
              orders
              (Map.insert nodeA (State.assertionResultCursor assertionA1) seeds)
          frameA1 = deltaFrame orders base0 [assertionA1]
          frameA2 = deltaFrame orders baseAfterA1 [assertionA2]
          (rejectedState, gapError) = rejectedDelta frameA2 initialState
          recovered = appliedDelta frameA2 (appliedDelta frameA1 rejectedState)
          canonical = appliedDelta (deltaFrame orders base0 [assertionA1, assertionA2]) initialState
      State.gatewayStateCursorVector rejectedState
        `shouldBe` State.gatewayStateCursorVector initialState
      gapError `shouldBe` State.AssertionSequenceGap nodeA 1 2
      State.gatewayStateCursorVector recovered
        `shouldBe` State.gatewayStateCursorVector canonical

    it "selects only retained deltas and requests repair when a cursor fell behind replay" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          initialState = gatewayState orders
          initialCursor = cursorAt nodeA (cursorSeeds orders)
          (source, _) =
            foldl'
              (applyHeartbeat orders nodeA)
              (initialState, initialCursor)
              [1 .. 12]
      State.selectDelta (State.gatewayStateCursorVector initialState) source
        `shouldSatisfy` isReplayUnavailable
      let currentVector = State.gatewayStateCursorVector source
      case State.selectDelta currentVector source of
        Left err -> expectationFailure (show err)
        Right frame -> State.deltaFrameAssertionCount frame `shouldBe` 0

    it "bounds assertion count and encoded bytes in every delta frame" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          seeds = cursorSeeds orders
          cursor0 = cursorAt nodeA seeds
          assertions = assertionChain orders nodeA cursor0 9 100
      State.mkDeltaFrame
        gatewayBounds
        orders
        (cursorVector orders seeds)
        assertions
        `shouldBe` Left (State.DeltaAssertionCountExceeded 9 8)
      let smallFrameBounds =
            gatewayBoundsFrom
              rawGatewayBounds
                { Bounds.rawMaxFrameBytes = 1000
                }
          oversizedAssertions =
            assertionChainWithBytes orders nodeA 400 cursor0 3 100
      State.mkDeltaFrame
        smallFrameBounds
        orders
        (cursorVector orders seeds)
        oversizedAssertions
        `shouldBe` Left (State.DeltaFrameBytesExceeded 1200 1000)

    it "rejects oversized Content-Length during header preflight before body accumulation" $ do
      let request =
            "POST /v1/peer/delta HTTP/1.1\r\nHost: node-a:8444\r\nContent-Length: 4097\r\n\r\n"
      Peer.preflightPeerHttpRequest gatewayBounds request
        `shouldBe` Left (Peer.PeerHttpContentLengthTooLarge 4097 4096)

    it "rotates at the Word64 sequence boundary without wrapping and rejects delayed old epochs" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          nodeB = memberId orders "node-b"
          nearCursor = State.restoredEmitterCursor 7 (maxBound - 1) (eventHash 40)
          seeds =
            Map.fromList
              [ (nodeA, nearCursor)
              , (nodeB, State.initialEmitterCursor 1 (eventHash 2))
              ]
          initialState = gatewayStateWithSeeds orders seeds
      let lastAssertion = nextAssertion orders nodeA nearCursor 41 (State.HeartbeatAssertion 1)
          exhaustedCursor = State.assertionResultCursor lastAssertion
          exhaustedState = appliedAssertion lastAssertion initialState
      State.emitterSequenceValue (State.emitterCursorSequence exhaustedCursor)
        `shouldBe` maxBound
      State.mkNextAssertion
        gatewayBounds
        orders
        nodeA
        exhaustedCursor
        (eventHash 42)
        200
        (State.HeartbeatAssertion 2)
        `shouldBe` Left (State.EmitterRotationRequired nodeA exhaustedCursor)
      let rotation = epochRotation orders nodeA exhaustedCursor 42
          rotatedState = appliedAssertion rotation exhaustedState
          rotatedCursor = State.assertionResultCursor rotation
          oldPrevious = State.restoredEmitterCursor 7 (maxBound - 2) (eventHash 39)
          delayedOld = nextAssertion orders nodeA oldPrevious 40 (State.HeartbeatAssertion 1)
      State.emitterEpochValue (State.emitterCursorEpoch rotatedCursor) `shouldBe` 8
      State.emitterSequenceValue (State.emitterCursorSequence rotatedCursor) `shouldBe` 0
      case State.applyGatewayAssertion delayedOld rotatedState of
        State.AssertionRejected _ err ->
          err `shouldBe` State.AssertionDelayedOldEpoch nodeA 7 8
        outcome -> expectationFailure ("expected delayed-old-epoch rejection, got " ++ show outcome)
      let terminal = State.restoredEmitterCursor maxBound maxBound (eventHash 50)
      State.mkEpochRotationAssertion
        gatewayBounds
        orders
        nodeA
        terminal
        (eventHash 51)
        200
        `shouldBe` Left (State.EmitterEpochExhausted nodeA)

    it "retains only active Orders plus the highest staged promotion and evicts old evidence" $ do
      let orders1 = validatedOrders 1 ["node-a", "node-b"]
          orders2 = validatedOrders 2 ["node-a", "node-b"]
          orders3 = validatedOrders 3 ["node-a", "node-b"]
          orders5 = validatedOrders 5 ["node-a", "node-b"]
          nodeA = memberId orders1 "node-a"
          initialState = gatewayState orders1
          ownership =
            nextAssertion
              orders1
              nodeA
              (cursorAt nodeA (cursorSeeds orders1))
              61
              (State.OwnershipAssertion State.OwnershipClaim)
          withOwnership = appliedAssertion ownership initialState
          staged =
            stageOrders
              orders3
              (stageOrders orders5 (stageOrders orders2 withOwnership))
      fmap ordersVersion (State.gatewayStateStagedOrders staged) `shouldBe` Just 5
      State.gatewayStateLatestOwnership nodeA staged `shouldSatisfy` isJust
      let promoted =
            case State.activateOrdersPromotion (cursorSeeds orders5) staged of
              Left err -> error (show err)
              Right value -> value
          promotedNodeA = memberId orders5 "node-a"
      ordersVersion (State.gatewayStateActiveOrders promoted) `shouldBe` 5
      State.gatewayStateStagedOrders promoted `shouldBe` Nothing
      State.gatewayStateLatestOwnership promotedNodeA promoted `shouldBe` Nothing
      State.gatewayStateReplayCount promotedNodeA promoted `shouldBe` 0

    it "keeps rejection counts exact while trimming samples to their configured capacity" $ do
      let orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          initialState = gatewayState orders
          cursor0 = cursorAt nodeA (cursorSeeds orders)
          assertion1 = nextAssertion orders nodeA cursor0 71 (State.HeartbeatAssertion 1)
          assertion2 =
            nextAssertion
              orders
              nodeA
              (State.assertionResultCursor assertion1)
              72
              (State.HeartbeatAssertion 2)
          rejected =
            foldl'
              (\state _ -> rejectedAssertionState assertion2 state)
              initialState
              [1 .. 10 :: Int]
          summary = State.gatewayStateRejectionSummary rejected
      State.rejectionCount State.RejectSequenceGap summary `shouldBe` 10
      length (State.rejectionSamples summary)
        `shouldBe` Bounds.gatewayMaxRejectionSamples gatewayBounds

    it "repairs a cursor beyond replay from a signed checkpoint, then converges by delta suffix" $ do
      let bounds =
            gatewayBoundsFrom
              rawGatewayBounds
                { Bounds.rawMaxAssertionsPerFrame = 3
                }
          orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          key = eventKey bounds 7
          (source, history) =
            signedHistory
              bounds
              orders
              nodeA
              key
              [ State.HeartbeatAssertion 10
              , State.OwnershipAssertion State.OwnershipClaim
              , State.HeartbeatAssertion 30
              , State.OwnershipAssertion State.OwnershipYield
              , State.HeartbeatAssertion 50
              , State.HeartbeatAssertion 60
              ]
          signedAssertions = map fst history
          heartbeatAtCheckpoint = signedAt 0 signedAssertions
          ownershipAtCheckpoint = signedAt 1 signedAssertions
          signed3 = signedAt 2 signedAssertions
          signed4 = signedAt 3 signedAssertions
          signed5 = signedAt 4 signedAssertions
          signed6 = signedAt 5 signedAssertions
          checkpoint = emitterCheckpoint nodeA source
          target0 = gatewayStateFor bounds orders
          repair =
            signedRepair
              bounds
              orders
              (State.gatewayStateCursorVector target0)
              checkpoint
              (Just heartbeatAtCheckpoint)
              (Just ownershipAtCheckpoint)
              key
              [signed3, signed4, signed5, signed6]
          encoded = Peer.encodeSignedRepairFrame repair
          decoded = decodedRepair bounds encoded
          request = Peer.PeerPushRepair decoded
          repaired = appliedSignedRepair bounds nodeA key decoded target0
      Peer.signedRepairAssertionCount decoded `shouldBe` 3
      length
        ( Peer.boundedSignedAssertionsToList
            (Peer.peerRequestReplayAssertions request)
        )
        `shouldBe` 1
      Peer.peerRequestSemanticSnapshot request `shouldSatisfy` isJust
      Peer.peerRequestOrdersVersion request `shouldBe` Just 1
      Peer.peerRequestOrdersVersion Peer.PeerPullCursor `shouldBe` Nothing
      length
        ( Peer.boundedSignedAssertionsToList
            (Peer.peerRequestSnapshotEvidence request)
        )
        `shouldBe` 2
      let renderedRequest =
            case Peer.renderPeerRepairRequest bounds "node-b.internal:8444" decoded of
              Left err -> error (show err)
              Right value -> value
      Peer.parsePeerHttpRequest bounds renderedRequest `shouldBe` Right request
      State.emitterSequenceValue
        ( State.emitterCursorSequence
            (cursorFromState nodeA repaired)
        )
        `shouldBe` 3
      let remaining =
            case Peer.selectSignedDelta
              bounds
              orders
              (State.gatewayStateCursorVector repaired)
              [signed3, signed4, signed5, signed6] of
              Left err -> error (show err)
              Right value -> value
          converged = appliedSignedDelta bounds nodeA key remaining repaired
      State.gatewayStateCursorVector converged
        `shouldBe` State.gatewayStateCursorVector source
      State.gatewayStateLatestHeartbeat nodeA converged
        `shouldBe` State.gatewayStateLatestHeartbeat nodeA source
      State.gatewayStateLatestOwnership nodeA converged
        `shouldBe` State.gatewayStateLatestOwnership nodeA source

    it "repairs semantic slots at an equal retained cursor atomically and idempotently" $ do
      let bounds = gatewayBounds
          orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          key = eventKey bounds 7
          (source, history) =
            signedHistory
              bounds
              orders
              nodeA
              key
              [ State.HeartbeatAssertion 10
              , State.OwnershipAssertion State.OwnershipClaim
              , State.HeartbeatAssertion 30
              , State.OwnershipAssertion State.OwnershipYield
              , State.HeartbeatAssertion 50
              , State.HeartbeatAssertion 60
              ]
          signedAssertions = map fst history
          checkpoint = emitterCheckpoint nodeA source
          repair =
            signedRepair
              bounds
              orders
              (State.gatewayStateCursorVector (gatewayStateFor bounds orders))
              checkpoint
              (Just (signedAt 0 signedAssertions))
              (Just (signedAt 1 signedAssertions))
              key
              (drop 2 signedAssertions)
          targetAtContinuity =
            case State.restoreEmitterFromContinuity
              nodeA
              (cursorFromState nodeA source)
              (gatewayStateFor bounds orders) of
              Left err -> error (show err)
              Right value -> value
      State.gatewayStateLatestHeartbeat nodeA targetAtContinuity `shouldBe` Nothing
      let repaired = appliedSignedRepair bounds nodeA key repair targetAtContinuity
      State.gatewayStateCursorVector repaired
        `shouldBe` State.gatewayStateCursorVector source
      State.gatewayStateLatestHeartbeat nodeA repaired
        `shouldBe` State.gatewayStateLatestHeartbeat nodeA source
      State.gatewayStateLatestOwnership nodeA repaired
        `shouldBe` State.gatewayStateLatestOwnership nodeA source
      case Peer.applySignedRepair bounds (eventKeyLookup nodeA key) repair repaired of
        Right (State.RepairDuplicate unchanged) -> unchanged `shouldBe` repaired
        outcome -> expectationFailure ("expected duplicate repair, got " ++ show outcome)

    it "rejects a forged repair without exposing a partial semantic transition" $ do
      let bounds = gatewayBounds
          orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          key = eventKey bounds 7
          wrongKey = eventKey bounds 8
          (source, history) =
            signedHistory
              bounds
              orders
              nodeA
              key
              [ State.HeartbeatAssertion 10
              , State.OwnershipAssertion State.OwnershipClaim
              , State.HeartbeatAssertion 30
              , State.OwnershipAssertion State.OwnershipYield
              , State.HeartbeatAssertion 50
              ]
          signedAssertions = map fst history
          target = gatewayStateFor bounds orders
          repair =
            signedRepair
              bounds
              orders
              (State.gatewayStateCursorVector target)
              (emitterCheckpoint nodeA source)
              (Just (signedAt 0 signedAssertions))
              Nothing
              key
              (drop 1 signedAssertions)
      case Peer.handlePeerRequest
        bounds
        (eventKeyLookup nodeA wrongKey)
        (Peer.PeerPushRepair repair)
        target of
        Left err -> expectationFailure (show err)
        Right (unchanged, response) -> do
          State.gatewayStateCursorVector unchanged
            `shouldBe` State.gatewayStateCursorVector target
          State.gatewayStateLatestHeartbeat nodeA unchanged `shouldBe` Nothing
          Peer.peerResponseAccepted response `shouldBe` False

    it "checks live replay heartbeat skew but exempts authenticated old checkpoint evidence" $ do
      let bounds =
            gatewayBoundsFrom
              rawGatewayBounds
                { Bounds.rawReplayPerEmitter = 1
                }
          orders = validatedOrders 1 ["node-a", "node-b"]
          nodeA = memberId orders "node-a"
          key = eventKey bounds 7
          (source, history) =
            signedHistory
              bounds
              orders
              nodeA
              key
              [ State.HeartbeatAssertion 1
              , State.OwnershipAssertion State.OwnershipClaim
              ]
          signedAssertions = map fst history
          signedHeartbeat = signedAt 0 signedAssertions
          signedOwnership = signedAt 1 signedAssertions
          target = gatewayStateFor bounds orders
          repair =
            signedRepair
              bounds
              orders
              (State.gatewayStateCursorVector target)
              (emitterCheckpoint nodeA source)
              (Just signedHeartbeat)
              Nothing
              key
              [signedOwnership]
          delta =
            case Peer.mkSignedDeltaFrame
              bounds
              orders
              (State.gatewayStateCursorVector target)
              [signedHeartbeat] of
              Left err -> error (show err)
              Right value -> value
      Peer.validatePeerRequestHeartbeatSkew 100 1 (Peer.PeerPushRepair repair)
        `shouldBe` Right ()
      Peer.validatePeerRequestHeartbeatSkew 11 10 (Peer.PeerPushDelta delta)
        `shouldBe` Right ()
      Peer.validatePeerRequestHeartbeatSkew 11 9 (Peer.PeerPushDelta delta)
        `shouldSatisfy` isHeartbeatSkewFailure

boundedHeartbeatHistoryProperty :: NonNegative (Small Int) -> Bool
boundedHeartbeatHistoryProperty (NonNegative (Small generatedCount)) =
  let count = generatedCount `mod` 2001
      orders = validatedOrders 1 ["node-a", "node-b"]
      nodeA = memberId orders "node-a"
      initial = gatewayState orders
      cursor0 = cursorFromState nodeA initial
      (finalState, finalCursor) =
        foldl'
          (applyHeartbeat orders nodeA)
          (initial, cursor0)
          [1 .. count]
   in State.gatewayStateEmitterCount finalState == 2
        && State.gatewayStateReplayCount nodeA finalState
          <= Bounds.gatewayReplayPerEmitter gatewayBounds
        && length (State.gatewayStateDiagnosticHashes finalState)
          <= Bounds.gatewayDiagnosticHashCapacity
        && State.emitterSequenceValue
          (State.emitterCursorSequence finalCursor)
          == fromIntegral count

duplicateDeliveryProperty :: NonNegative (Small Int) -> Bool
duplicateDeliveryProperty (NonNegative (Small generatedCount)) =
  let count = generatedCount `mod` 1001
      orders = validatedOrders 1 ["node-a", "node-b"]
      nodeA = memberId orders "node-a"
      initial = gatewayState orders
      assertion =
        nextAssertion
          orders
          nodeA
          (cursorFromState nodeA initial)
          71
          (State.HeartbeatAssertion 1)
      expected = if count == 0 then initial else appliedAssertion assertion initial
      observed =
        foldl'
          (\state _ -> appliedAssertion assertion state)
          initial
          [1 .. count]
   in State.gatewayStateCursorVector observed
        == State.gatewayStateCursorVector expected
        && State.gatewayStateReplayCount nodeA observed <= 1

multiEmitterConvergenceProperty
  :: NonNegative (Small Int)
  -> NonNegative (Small Int)
  -> Bool
multiEmitterConvergenceProperty
  (NonNegative (Small generatedA))
  (NonNegative (Small generatedB)) =
    let countA = generatedA `mod` 4 + 1
        countB = generatedB `mod` 4 + 1
        orders = validatedOrders 1 ["node-a", "node-b"]
        nodeA = memberId orders "node-a"
        nodeB = memberId orders "node-b"
        initial = gatewayState orders
        base = State.gatewayStateCursorVector initial
        assertionsA = assertionChain orders nodeA (cursorFromState nodeA initial) countA 100
        assertionsB = assertionChain orders nodeB (cursorFromState nodeB initial) countB 180
        frameA = deltaFrame orders base assertionsA
        frameB = deltaFrame orders base assertionsB
        canonical = appliedDelta (deltaFrame orders base (assertionsA ++ assertionsB)) initial
        leftDeliveries = [frameA, frameB, frameA, frameB]
        rightDeliveries = [frameB, frameA, frameB, frameA]
        leftStates = scanl (flip appliedDelta) initial leftDeliveries
        rightStates = scanl (flip appliedDelta) initial rightDeliveries
        leftFinal = last leftStates
        rightFinal = last rightStates
        sameProjection observed =
          State.gatewayStateCursorVector observed
            == State.gatewayStateCursorVector canonical
            && all
              ( \emitter ->
                  State.gatewayStateLatestHeartbeat emitter observed
                    == State.gatewayStateLatestHeartbeat emitter canonical
                    && State.gatewayStateLatestOwnership emitter observed
                      == State.gatewayStateLatestOwnership emitter canonical
              )
              [nodeA, nodeB]
     in sameProjection leftFinal
          && sameProjection rightFinal
          && cursorsNeverRegress [nodeA, nodeB] leftStates
          && cursorsNeverRegress [nodeA, nodeB] rightStates

ordersChurnProperty :: NonNegative (Small Int) -> Bool
ordersChurnProperty (NonNegative (Small generatedCount)) =
  let count = generatedCount `mod` 101
      active = validatedOrders 1 ["node-a", "node-b"]
      initial = gatewayState active
      candidates =
        [ validatedOrders version ["node-a", "node-b"]
        | version <- [2 .. count + 1]
        ]
      finalState = foldl' (flip stageOrders) initial candidates
      stagedVersion = ordersVersion <$> State.gatewayStateStagedOrders finalState
      expectedStaged = if count == 0 then Nothing else Just (fromIntegral (count + 1))
   in ordersVersion (State.gatewayStateActiveOrders finalState) == 1
        && stagedVersion == expectedStaged
        && State.gatewayStateEmitterCount finalState == 2

epochRotationProperty :: NonNegative (Small Int) -> Bool
epochRotationProperty (NonNegative (Small generatedEpoch)) =
  let epoch = fromIntegral (generatedEpoch `mod` 100001 + 1)
      orders = validatedOrders 1 ["node-a", "node-b"]
      nodeA = memberId orders "node-a"
      exhausted = State.restoredEmitterCursor epoch maxBound (eventHash 91)
      rotation = epochRotation orders nodeA exhausted 92
      result = State.assertionResultCursor rotation
   in State.emitterEpochValue (State.emitterCursorEpoch result) == epoch + 1
        && State.emitterSequenceValue (State.emitterCursorSequence result) == 0
        && State.assertionKind rotation == State.EpochRotationAssertion

sourceBetween :: String -> String -> String -> String
sourceBetween startMarker endMarker source =
  case dropWhile (not . isPrefixOf startMarker) (tails source) of
    [] -> ""
    fromStart : _ ->
      let (prefixes, _) =
            break (isPrefixOf endMarker) (tails fromStart)
       in take (length prefixes) fromStart

cursorsNeverRegress :: [State.NodeId] -> [State.GatewayState] -> Bool
cursorsNeverRegress emitters states =
  all
    ( \(before, after) ->
        all
          ( \emitter ->
              emitterPosition (cursorFromState emitter before)
                <= emitterPosition (cursorFromState emitter after)
          )
          emitters
    )
    (zip states (drop 1 states))

emitterPosition :: State.EmitterCursor -> (Word64, Word64)
emitterPosition cursor =
  ( State.emitterEpochValue (State.emitterCursorEpoch cursor)
  , State.emitterSequenceValue (State.emitterCursorSequence cursor)
  )

expectProductionOrdersFailure
  :: FilePath
  -> Bounds.GatewayBounds
  -> [(String, String)]
  -> [String]
  -> IO ()
expectProductionOrdersFailure path bounds keys expectedFragments = do
  result <- Settings.loadOrdersBounded bounds keys path
  case result of
    Left err -> mapM_ (err `shouldContain`) expectedFragments
    Right _ -> expectationFailure "invalid production Orders unexpectedly admitted"

productionOrdersSource :: BS.ByteString
productionOrdersSource =
  BS8.pack $
    unlines
      [ "{ version_utc = 1"
      , ", nodes ="
      , "  [ { node_id = \"node-a\""
      , "    , stable_dns_name = \"node-a.internal\""
      , "    , rest_host = \"node-a.internal\""
      , "    , rest_port = 8443"
      , "    , socket_host = \"node-a.internal\""
      , "    , socket_port = 8444"
      , "    }"
      , "  , { node_id = \"node-b\""
      , "    , stable_dns_name = \"node-b.internal\""
      , "    , rest_host = \"node-b.internal\""
      , "    , rest_port = 8443"
      , "    , socket_host = \"node-b.internal\""
      , "    , socket_port = 8444"
      , "    }"
      , "  ]"
      , ", gateway_rule ="
      , "    { ranked_nodes = [ \"node-a\", \"node-b\" ]"
      , "    , heartbeat_timeout_seconds = 5"
      , "    }"
      , "}"
      ]

signedHistory
  :: Bounds.GatewayBounds
  -> State.ValidatedOrders
  -> State.NodeId
  -> Peer.EventKey
  -> [State.AssertionKind]
  -> (State.GatewayState, [(Peer.SignedAssertion, State.GatewayAssertion)])
signedHistory bounds orders emitter key kinds =
  let initial = gatewayStateFor bounds orders
      cursor0 = cursorFromState emitter initial
      (finalState, _, reversed) = foldl' step (initial, cursor0, []) kinds
   in (finalState, reverse reversed)
 where
  step (state, cursor, assertions) kind =
    case Peer.signAndConvertAssertion bounds orders emitter cursor kind key of
      Left err -> error (show err)
      Right (signed, semantic) ->
        ( appliedAssertion semantic state
        , State.assertionResultCursor semantic
        , (signed, semantic) : assertions
        )

gatewayStateFor
  :: Bounds.GatewayBounds
  -> State.ValidatedOrders
  -> State.GatewayState
gatewayStateFor bounds orders =
  case State.initializeGatewayState bounds orders (cursorSeeds orders) of
    Left err -> error (show err)
    Right value -> value

eventKey :: Bounds.GatewayBounds -> Word8 -> Peer.EventKey
eventKey bounds byte =
  case Peer.mkEventKey bounds (BS.replicate 32 byte) of
    Left err -> error (show err)
    Right value -> value

eventKeyLookup
  :: State.NodeId
  -> Peer.EventKey
  -> Peer.EventKeyLookup
eventKeyLookup expected key candidate
  | candidate == expected = Just key
  | otherwise = Nothing

emitterCheckpoint
  :: State.NodeId
  -> State.GatewayState
  -> State.EmitterCheckpoint
emitterCheckpoint emitter state =
  case State.gatewayStateEmitterCheckpoint emitter state of
    Nothing -> error "missing emitter checkpoint"
    Just value -> value

cursorFromState
  :: State.NodeId
  -> State.GatewayState
  -> State.EmitterCursor
cursorFromState emitter state =
  case State.cursorVectorLookup emitter (State.gatewayStateCursorVector state) of
    Nothing -> error "missing emitter cursor"
    Just value -> value

signedRepair
  :: Bounds.GatewayBounds
  -> State.ValidatedOrders
  -> State.CursorVector
  -> State.EmitterCheckpoint
  -> Maybe Peer.SignedAssertion
  -> Maybe Peer.SignedAssertion
  -> Peer.EventKey
  -> [Peer.SignedAssertion]
  -> Peer.SignedRepairFrame
signedRepair bounds orders peerCursor checkpoint heartbeat ownership key replay =
  case Peer.selectSignedRepairFromCheckpoint
    bounds
    orders
    peerCursor
    checkpoint
    heartbeat
    ownership
    key
    replay of
    Left err -> error (show err)
    Right value -> value

decodedRepair
  :: Bounds.GatewayBounds
  -> BS.ByteString
  -> Peer.SignedRepairFrame
decodedRepair bounds encoded =
  case Peer.decodeSignedRepairFrame bounds encoded of
    Left err -> error (show err)
    Right value -> value

appliedSignedRepair
  :: Bounds.GatewayBounds
  -> State.NodeId
  -> Peer.EventKey
  -> Peer.SignedRepairFrame
  -> State.GatewayState
  -> State.GatewayState
appliedSignedRepair bounds emitter key repair state =
  case Peer.applySignedRepair bounds (eventKeyLookup emitter key) repair state of
    Left err -> error (show err)
    Right (State.RepairApplied advanced) -> advanced
    Right (State.RepairDuplicate unchanged) -> unchanged
    Right (State.RepairRejected _ err) -> error (show err)

appliedSignedDelta
  :: Bounds.GatewayBounds
  -> State.NodeId
  -> Peer.EventKey
  -> Peer.SignedDeltaFrame
  -> State.GatewayState
  -> State.GatewayState
appliedSignedDelta bounds emitter key frame state =
  case Peer.applySignedDelta bounds (eventKeyLookup emitter key) frame state of
    Left err -> error (show err)
    Right (State.DeltaApplied advanced) -> advanced
    Right (State.DeltaRejected _ err) -> error (show err)

isHeartbeatSkewFailure :: Either Peer.PeerError () -> Bool
isHeartbeatSkewFailure result =
  case result of
    Left Peer.PeerHeartbeatSkewExceeded {} -> True
    _ -> False

signedAt :: Int -> [Peer.SignedAssertion] -> Peer.SignedAssertion
signedAt index assertions =
  case drop index assertions of
    value : _ -> value
    [] -> error ("missing signed assertion at index " ++ show index)

zeroBoundCases
  :: [(Bounds.GatewayBoundField, Bounds.RawGatewayBounds -> Bounds.RawGatewayBounds)]
zeroBoundCases =
  [ (Bounds.MaxOrdersBytes, \raw -> raw {Bounds.rawMaxOrdersBytes = 0})
  , (Bounds.MaxMembers, \raw -> raw {Bounds.rawMaxMembers = 0})
  , (Bounds.MaxNodeIdBytes, \raw -> raw {Bounds.rawMaxNodeIdBytes = 0})
  , (Bounds.MaxEndpointBytes, \raw -> raw {Bounds.rawMaxEndpointBytes = 0})
  , (Bounds.MaxTrustKeyBytes, \raw -> raw {Bounds.rawMaxTrustKeyBytes = 0})
  , (Bounds.MaxEncodedMemberBytes, \raw -> raw {Bounds.rawMaxEncodedMemberBytes = 0})
  , (Bounds.MaxAssertionPayloadBytes, \raw -> raw {Bounds.rawMaxAssertionPayloadBytes = 0})
  , (Bounds.MaxFrameBytes, \raw -> raw {Bounds.rawMaxFrameBytes = 0})
  , (Bounds.MaxAssertionsPerFrame, \raw -> raw {Bounds.rawMaxAssertionsPerFrame = 0})
  , (Bounds.ReplayPerEmitter, \raw -> raw {Bounds.rawReplayPerEmitter = 0})
  , (Bounds.MaxInFlightFrames, \raw -> raw {Bounds.rawMaxInFlightFrames = 0})
  , (Bounds.MaxInFlightFramesPerPeer, \raw -> raw {Bounds.rawMaxInFlightFramesPerPeer = 0})
  , (Bounds.MaxRejectionSamples, \raw -> raw {Bounds.rawMaxRejectionSamples = 0})
  ]

rawGatewayBounds :: Bounds.RawGatewayBounds
rawGatewayBounds =
  Bounds.RawGatewayBounds
    { Bounds.rawMaxOrdersBytes = 1024
    , Bounds.rawMaxMembers = 3
    , Bounds.rawMaxNodeIdBytes = 64
    , Bounds.rawMaxEndpointBytes = 256
    , Bounds.rawMaxTrustKeyBytes = 64
    , Bounds.rawMaxEncodedMemberBytes = 384
    , Bounds.rawMaxAssertionPayloadBytes = 256
    , Bounds.rawMaxFrameBytes = 4096
    , Bounds.rawMaxAssertionsPerFrame = 8
    , Bounds.rawReplayPerEmitter = 4
    , Bounds.rawMaxInFlightFrames = 2
    , Bounds.rawMaxInFlightFramesPerPeer = 1
    , Bounds.rawMaxRejectionSamples = 4
    }

gatewayBounds :: Bounds.GatewayBounds
gatewayBounds = gatewayBoundsFrom rawGatewayBounds

gatewayBoundsFrom :: Bounds.RawGatewayBounds -> Bounds.GatewayBounds
gatewayBoundsFrom raw =
  case Bounds.validateGatewayBounds (runtimeMemoryPlan 1) raw of
    Left err -> error (show err)
    Right value -> value

runtimeMemoryPlan :: Natural -> RuntimeMemory.RuntimeMemoryPlan
runtimeMemoryPlan permitCount =
  let positive term value =
        case RuntimeMemory.mkPositiveBytes term value of
          Left err -> error (show err)
          Right bytes -> bytes
      peaks =
        if permitCount == 1
          then [1000000]
          else replicate (fromIntegral permitCount) 1000000
      inputs =
        RuntimeMemory.RuntimeMemoryInputs
          { RuntimeMemory.runtimeBoundedApplicationState =
              positive RuntimeMemory.BoundedApplicationState 10000000
          , RuntimeMemory.runtimeBoundedPendingPersistenceState =
              positive RuntimeMemory.BoundedPendingPersistenceState 10000000
          , RuntimeMemory.runtimeInHeapTransportDecodeScratch =
              positive RuntimeMemory.InHeapTransportDecodeScratch 20000000
          , RuntimeMemory.runtimeOtherHeapReserve =
              positive RuntimeMemory.OtherHeapReserve 1000000
          , RuntimeMemory.runtimeHeapCap = positive RuntimeMemory.HeapCap 45000000
          , RuntimeMemory.runtimeNativeNonHeapReserve =
              positive RuntimeMemory.NativeNonHeapReserve 1000000
          , RuntimeMemory.runtimeRawChildSchedule =
              RuntimeMemory.BoundedChildSchedule
                { RuntimeMemory.rawChildPermitCount = permitCount
                , RuntimeMemory.rawChildDeadlineMicros = Just 30000000
                , RuntimeMemory.rawChildPeakBytes = peaks
                }
          , RuntimeMemory.runtimeKernelCgroupReserve =
              positive RuntimeMemory.KernelCgroupReserve 1000000
          , RuntimeMemory.runtimeSafetyMargin =
              positive RuntimeMemory.SafetyMargin 1000000
          , RuntimeMemory.runtimeContainerMemoryLimit =
              positive RuntimeMemory.ContainerMemoryLimit 60000000
          }
   in case RuntimeMemory.validateRuntimeMemoryPlan inputs of
        Left err -> error (show err)
        Right value -> value

rawOrders :: Int -> [State.RawGatewayMember] -> State.RawOrders
rawOrders version members =
  State.RawOrders
    { State.rawOrdersDocument = "bounded-orders"
    , State.rawOrdersVersion = version
    , State.rawOrdersMembers = members
    }

rawMember :: Text -> Word64 -> State.RawGatewayMember
rawMember nodeId rank =
  State.RawGatewayMember
    { State.rawMemberNodeId = nodeId
    , State.rawMemberEndpoint = "https://gateway.internal:8444"
    , State.rawMemberTrustKey = BS.replicate 32 7
    , State.rawMemberRank = rank
    }

validatedOrders :: Int -> [Text] -> State.ValidatedOrders
validatedOrders version memberNames =
  let members = zipWith rawMember memberNames [0 ..]
   in admittedOrders (rawOrders version members)

admittedOrders :: State.RawOrders -> State.ValidatedOrders
admittedOrders raw =
  case State.validateOrders gatewayBounds raw of
    Left err -> error (show err)
    Right value -> value

memberId :: State.ValidatedOrders -> Text -> State.NodeId
memberId orders expected =
  case filter ((== expected) . State.nodeIdText) (State.validatedOrdersMemberIds orders) of
    [nodeId] -> nodeId
    values -> error ("expected one admitted member, got " ++ show values)

eventHash :: Word8 -> State.EventHash
eventHash byte =
  case State.mkEventHash (BS.replicate 32 byte) of
    Left err -> error (show err)
    Right value -> value

cursorSeeds :: State.ValidatedOrders -> Map State.NodeId State.EmitterCursor
cursorSeeds orders =
  Map.fromList
    [ (nodeId, State.initialEmitterCursor 1 (eventHash (fromIntegral index + 1)))
    | (index, nodeId) <- zip [0 :: Int ..] (State.validatedOrdersMemberIds orders)
    ]

cursorAt
  :: State.NodeId
  -> Map State.NodeId State.EmitterCursor
  -> State.EmitterCursor
cursorAt nodeId seeds =
  case Map.lookup nodeId seeds of
    Nothing -> error "missing cursor seed"
    Just cursor -> cursor

cursorVector
  :: State.ValidatedOrders
  -> Map State.NodeId State.EmitterCursor
  -> State.CursorVector
cursorVector orders cursors =
  case State.mkCursorVector orders cursors of
    Left err -> error (show err)
    Right value -> value

gatewayState :: State.ValidatedOrders -> State.GatewayState
gatewayState orders = gatewayStateWithSeeds orders (cursorSeeds orders)

gatewayStateWithSeeds
  :: State.ValidatedOrders
  -> Map State.NodeId State.EmitterCursor
  -> State.GatewayState
gatewayStateWithSeeds orders seeds =
  case State.initializeGatewayState gatewayBounds orders seeds of
    Left err -> error (show err)
    Right value -> value

nextAssertion
  :: State.ValidatedOrders
  -> State.NodeId
  -> State.EmitterCursor
  -> Word8
  -> State.AssertionKind
  -> State.GatewayAssertion
nextAssertion orders nodeId cursor hashByte kind =
  nextAssertionWithBytes orders nodeId cursor hashByte kind 200

nextAssertionWithBytes
  :: State.ValidatedOrders
  -> State.NodeId
  -> State.EmitterCursor
  -> Word8
  -> State.AssertionKind
  -> Natural
  -> State.GatewayAssertion
nextAssertionWithBytes orders nodeId cursor hashByte kind encodedBytes =
  case State.mkNextAssertion
    gatewayBounds
    orders
    nodeId
    cursor
    (eventHash hashByte)
    encodedBytes
    kind of
    Left err -> error (show err)
    Right value -> value

epochRotation
  :: State.ValidatedOrders
  -> State.NodeId
  -> State.EmitterCursor
  -> Word8
  -> State.GatewayAssertion
epochRotation orders nodeId cursor hashByte =
  case State.mkEpochRotationAssertion
    gatewayBounds
    orders
    nodeId
    cursor
    (eventHash hashByte)
    200 of
    Left err -> error (show err)
    Right value -> value

appliedAssertion :: State.GatewayAssertion -> State.GatewayState -> State.GatewayState
appliedAssertion assertion state =
  case State.applyGatewayAssertion assertion state of
    State.AssertionApplied advanced -> advanced
    State.AssertionDuplicate unchanged -> unchanged
    State.AssertionRejected _ err -> error (show err)

rejectedAssertionState
  :: State.GatewayAssertion
  -> State.GatewayState
  -> State.GatewayState
rejectedAssertionState assertion state =
  case State.applyGatewayAssertion assertion state of
    State.AssertionRejected rejected _ -> rejected
    outcome -> error ("expected assertion rejection, got " ++ show outcome)

applyHeartbeat
  :: State.ValidatedOrders
  -> State.NodeId
  -> (State.GatewayState, State.EmitterCursor)
  -> Int
  -> (State.GatewayState, State.EmitterCursor)
applyHeartbeat orders nodeId (state, cursor) index =
  let assertion =
        nextAssertion
          orders
          nodeId
          cursor
          (fromIntegral (index `mod` 251 + 1))
          (State.HeartbeatAssertion (fromIntegral index))
      advanced = appliedAssertion assertion state
   in (advanced, State.assertionResultCursor assertion)

assertionChain
  :: State.ValidatedOrders
  -> State.NodeId
  -> State.EmitterCursor
  -> Int
  -> Word8
  -> [State.GatewayAssertion]
assertionChain orders nodeId = assertionChainWithBytes orders nodeId 200

assertionChainWithBytes
  :: State.ValidatedOrders
  -> State.NodeId
  -> Natural
  -> State.EmitterCursor
  -> Int
  -> Word8
  -> [State.GatewayAssertion]
assertionChainWithBytes orders nodeId encodedBytes initialCursor count firstHash =
  reverse (fst (foldl' step ([], initialCursor) [0 .. count - 1]))
 where
  step (assertions, cursor) offset =
    let assertion =
          nextAssertionWithBytes
            orders
            nodeId
            cursor
            (firstHash + fromIntegral offset)
            (State.HeartbeatAssertion (fromIntegral offset))
            encodedBytes
     in (assertion : assertions, State.assertionResultCursor assertion)

deltaFrame
  :: State.ValidatedOrders
  -> State.CursorVector
  -> [State.GatewayAssertion]
  -> State.DeltaFrame
deltaFrame orders base assertions =
  case State.mkDeltaFrame gatewayBounds orders base assertions of
    Left err -> error (show err)
    Right value -> value

appliedDelta :: State.DeltaFrame -> State.GatewayState -> State.GatewayState
appliedDelta frame state =
  case State.applyDelta frame state of
    State.DeltaApplied advanced -> advanced
    State.DeltaRejected _ err -> error (show err)

rejectedDelta
  :: State.DeltaFrame
  -> State.GatewayState
  -> (State.GatewayState, State.GatewayStateError)
rejectedDelta frame state =
  case State.applyDelta frame state of
    State.DeltaRejected rejected err -> (rejected, err)
    State.DeltaApplied _ -> error "expected delta rejection"

stageOrders :: State.ValidatedOrders -> State.GatewayState -> State.GatewayState
stageOrders orders state =
  case State.stageOrdersPromotion orders state of
    Left err -> error (show err)
    Right value -> value

ordersVersion :: State.ValidatedOrders -> Word64
ordersVersion =
  State.ordersVersionValue
    . State.ordersAnchorVersion
    . State.validatedOrdersAnchor

isRight :: Either left right -> Bool
isRight result =
  case result of
    Left _ -> False
    Right _ -> True

isRetainedBudgetFailure :: Either Bounds.GatewayBoundsError Bounds.GatewayBounds -> Bool
isRetainedBudgetFailure result =
  case result of
    Left Bounds.GatewayRetainedBudgetExceeded {} -> True
    _ -> False

isScratchBudgetFailure :: Either Bounds.GatewayBoundsError Bounds.GatewayBounds -> Bool
isScratchBudgetFailure result =
  case result of
    Left Bounds.GatewayScratchBudgetExceeded {} -> True
    _ -> False

isMemberEncodingBoundFailure :: Either Bounds.GatewayBoundsError Bounds.GatewayBounds -> Bool
isMemberEncodingBoundFailure result =
  case result of
    Left Bounds.GatewayMemberEncodingBoundTooSmall {} -> True
    _ -> False

isCursorSeedMembershipFailure :: Either State.GatewayStateError State.GatewayState -> Bool
isCursorSeedMembershipFailure result =
  case result of
    Left State.CursorSeedMembershipMismatch {} -> True
    _ -> False

isReplayUnavailable :: Either State.GatewayStateError State.DeltaFrame -> Bool
isReplayUnavailable result =
  case result of
    Left State.DeltaReplayUnavailable {} -> True
    _ -> False
