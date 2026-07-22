{-# LANGUAGE OverloadedStrings #-}

module GatewayEmitterLease
  ( gatewayEmitterLeaseSuite
  )
where

import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, secondsToDiffTime)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.Gateway.Emitter.KubernetesLease
  ( boundLeaseResponseBody
  , collectLeaseResponseBody
  , leaseApiPath
  , leaseMutationFromResponse
  , leaseObservationFromResponse
  , maximumLeaseResponseBytes
  , projectedTokenSupplierAt
  , runLeaseRequestWithinDeadline
  , validateProjectedToken
  )
import Prodbox.Gateway.Emitter.Lease
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

gatewayEmitterLeaseSuite :: SuiteBuilder ()
gatewayEmitterLeaseSuite =
  describe "Sprint 2.32 emitter Lease fence" $ do
    describe "pure acquisition decision" $ do
      it "creates an absent Lease" $
        decideLease wallNow binding LeaseMissing `shouldBe` LeaseCreate
      it "renews only the exact same binding" $
        decideLease wallNow binding (LeaseObserved (recordFor holder wallNow))
          `shouldSatisfy` isRenew
      it "refuses a different live holder" $
        decideLease wallNow binding (LeaseObserved (recordFor "other" wallNow))
          `shouldSatisfy` isRefusal
      it "takes over a different expired holder" $
        decideLease wallNow binding (LeaseObserved (recordFor "other" (addUTCTime (-31) wallNow)))
          `shouldSatisfy` isTakeover
      it "fails closed on an unobservable Lease" $
        decideLease wallNow binding (LeaseUnobservable "forbidden")
          `shouldBe` LeaseRefuseUnobservable "forbidden"

    describe "binding and wire coordinate" $ do
      it "normalizes a Lease name once to its canonical DNS-label spelling" $
        fmap leaseNameText (mkLeaseName "  Prodbox-Emitter-Node-A  ")
          `shouldBe` Right "prodbox-emitter-node-a"
      it "changes the holder digest across incarnations and journal digests" $ do
        leaseBindingHolderIdentity binding
          `shouldNotBe` leaseBindingHolderIdentity (mkBinding 2 7)
        leaseBindingHolderIdentity binding
          `shouldNotBe` leaseBindingHolderIdentity (mkBinding 1 8)
      it "renders the exact namespaced coordination API path" $
        leaseApiPath "gateway" leaseName
          `shouldBe` "/apis/coordination.k8s.io/v1/namespaces/gateway/leases/prodbox-emitter-node-a"

    describe "bounded native Kubernetes transport" $ do
      it "rereads and validates the projected ServiceAccount token for rotation" $
        withSystemTempDirectory "prodbox-emitter-token" $ \temporaryRoot -> do
          let path = temporaryRoot </> "token"
              supply = projectedTokenSupplierAt path
          BS.writeFile path "token-generation-a\n"
          supply `shouldReturn` Right "token-generation-a"
          BS.writeFile path "token-generation-b"
          supply `shouldReturn` Right "token-generation-b"
          BS.writeFile path "token with whitespace"
          result <- supply
          result `shouldSatisfy` isLeft
      it "bounds token and HTTP response bytes before decoding" $ do
        validateProjectedToken (BS.replicate (16 * 1024 + 1) 0x61)
          `shouldSatisfy` isLeft
        boundLeaseResponseBody (BL.replicate (fromIntegral maximumLeaseResponseBytes) 0x61)
          `shouldSatisfy` isRight
        boundLeaseResponseBody (BL.replicate (fromIntegral maximumLeaseResponseBytes + 1) 0x61)
          `shouldSatisfy` isLeft
      it "collects fragmented Lease JSON through EOF at the exact body bound" $ do
        chunks <-
          newIORef
            [ BL.replicate (fromIntegral maximumLeaseResponseBytes - 1) 0x61
            , "b"
            , BL.empty
            ]
        requests <- newIORef ([] :: [Int])
        result <-
          collectLeaseResponseBody
            fixedMonotonicNow
            responseDeadline
            (chunkReader chunks requests)
        fmap BL.length result
          `shouldBe` Right (fromIntegral maximumLeaseResponseBytes)
        readIORef requests
          `shouldReturn` [maximumLeaseResponseBytes + 1, 2, 1]
      it "rejects a fragmented max-plus-one body without partial success" $ do
        chunks <-
          newIORef
            [ BL.replicate (fromIntegral maximumLeaseResponseBytes) 0x61
            , "b"
            ]
        requests <- newIORef ([] :: [Int])
        result <-
          collectLeaseResponseBody
            fixedMonotonicNow
            responseDeadline
            (chunkReader chunks requests)
        result `shouldBe` Left "Kubernetes Lease response exceeds the 64 KiB bound"
        readIORef requests
          `shouldReturn` [maximumLeaseResponseBytes + 1, 1]
      it "accepts an empty response only after observing EOF" $ do
        chunks <- newIORef [BL.empty]
        requests <- newIORef ([] :: [Int])
        collectLeaseResponseBody
          fixedMonotonicNow
          responseDeadline
          (chunkReader chunks requests)
          `shouldReturn` Right BL.empty
        readIORef requests
          `shouldReturn` [maximumLeaseResponseBytes + 1]
      it "rejects an EOF result completed at the absolute response deadline" $ do
        observations <- newIORef [0, 1000000]
        result <-
          collectLeaseResponseBody
            (nextMonotonicObservation observations)
            responseDeadline
            (const (pure BL.empty))
        result
          `shouldBe` Left "Kubernetes Lease response deadline expired before EOF"
      it "bounds a blocked fragmented body by the one absolute response deadline" $ do
        secondReadStarted <- newEmptyMVar
        neverComplete <- newEmptyMVar :: IO (MVar BL.ByteString)
        readCountRef <- newIORef (0 :: Natural)
        let blockedReader _ = do
              readCount <- readIORef readCountRef
              modifyIORef' readCountRef (+ 1)
              case readCount of
                0 -> pure "{"
                _ -> do
                  putMVar secondReadStarted ()
                  takeMVar neverComplete
        result <-
          collectLeaseResponseBody
            fixedMonotonicNow
            shortResponseDeadline
            blockedReader
        takeMVar secondReadStarted
        result
          `shouldBe` Left "Kubernetes Lease response deadline expired before EOF"
        readIORef readCountRef `shouldReturn` 2
      it "does not swallow unrelated asynchronous cancellation" $ do
        let cancelledReader _ = throwIO ThreadKilled
        result <-
          try
            ( collectLeaseResponseBody
                fixedMonotonicNow
                responseDeadline
                cancelledReader
            )
            :: IO (Either AsyncException (Either Text BL.ByteString))
        result `shouldBe` Left ThreadKilled
      it "re-observes the absolute deadline before HTTP dispatch" $ do
        dispatched <- newIORef False
        let expiredNow = pure (monotonicInstantFromMicros 200)
            expiredDeadline =
              deadlineAtOffset
                (monotonicInstantFromMicros 0)
                (RemainingDuration 100)
        result <-
          runLeaseRequestWithinDeadline expiredNow expiredDeadline $ \_ -> do
            writeIORef dispatched True
            pure ()
        result
          `shouldBe` Left "Kubernetes Lease deadline expired before request completion"
        readIORef dispatched `shouldReturn` False
      it "rejects a request result completed at the original absolute deadline" $ do
        observations <- newIORef [0, 100]
        let originalDeadline =
              deadlineAtOffset
                (monotonicInstantFromMicros 0)
                (RemainingDuration 100)
        result <-
          runLeaseRequestWithinDeadline
            (nextMonotonicObservation observations)
            originalDeadline
            (const (pure ()))
        result
          `shouldBe` Left "Kubernetes Lease deadline expired before request completion"
      it "derives a fresh remaining budget and bounds the entire HTTP scope" $ do
        dispatchStarted <- newEmptyMVar
        neverComplete <- newEmptyMVar :: IO (MVar ())
        let freshNow = pure (monotonicInstantFromMicros 90000)
            originalDeadline =
              deadlineAtOffset
                (monotonicInstantFromMicros 0)
                (RemainingDuration 100000)
        result <-
          runLeaseRequestWithinDeadline freshNow originalDeadline $ \remainingMicros -> do
            putMVar dispatchStarted remainingMicros
            takeMVar neverComplete
        observedBudget <- takeMVar dispatchStarted
        observedBudget `shouldBe` 10000
        result
          `shouldBe` Left "Kubernetes Lease deadline expired before request completion"
      it "classifies 404/409 and validates exact status JSON coordinates" $ do
        leaseObservationFromResponse leaseName 404 "not-json" `shouldBe` LeaseMissing
        leaseObservationFromResponse leaseName 200 (leaseWireJson (recordFor holder wallNow))
          `shouldBe` LeaseObserved (recordFor holder wallNow)
        let otherName = either (error . show) id (mkLeaseName "prodbox-emitter-node-b")
            wrongRecord = (recordFor holder wallNow) {leaseRecordName = otherName}
        leaseObservationFromResponse leaseName 200 (leaseWireJson wrongRecord)
          `shouldSatisfy` isUnobservable
        leaseObservationFromResponse
          leaseName
          200
          (leaseWireJsonWithName "Prodbox-Emitter-Node-A" (recordFor holder wallNow))
          `shouldSatisfy` isUnobservable
        leaseObservationFromResponse leaseName 200 "not-json"
          `shouldSatisfy` isUnobservable
        leaseMutationFromResponse (recordFor holder wallNow) 409 "not-json"
          `shouldBe` LeaseMutationConflict
        leaseMutationFromResponse
          (recordFor holder wallNow)
          200
          (leaseWireJson (recordFor holder wallNow))
          `shouldBe` LeaseMutationApplied (recordFor holder wallNow)
        leaseMutationFromResponse (recordFor holder wallNow) 200 (leaseWireJson wrongRecord)
          `shouldSatisfy` isMutationUnobservable

    describe "CAS/read-back interpreter" $ do
      it "returns a witness only after an exact create read-back" $ do
        (runtime, recordRef, mutationCount) <- fakeRuntime Nothing
        result <- acquireEmitterLease runtime callerDeadline leaseName duration binding
        witness <- expectRight result
        readIORef mutationCount `shouldReturn` 1
        stored <- readIORef recordRef
        fmap leaseRecordHolderIdentity stored `shouldBe` Just holder
        leaseWitnessResourceVersion witness `shouldBe` "rv-1"
        leaseWitnessCurrent (monotonicInstantFromMicros 29999999) leaseName duration binding witness
          `shouldBe` True
        leaseWitnessCurrent (monotonicInstantFromMicros 30000000) leaseName duration binding witness
          `shouldBe` False
      it "uses the caller deadline only for acquisition I/O, not as the authority expiry" $ do
        (runtime, _, _) <- fakeRuntime Nothing
        let shortAcquisitionDeadline =
              deadlineAtOffset
                (monotonicInstantFromMicros 0)
                (RemainingDuration (5 * 1000000))
        result <- acquireEmitterLease runtime shortAcquisitionDeadline leaseName duration binding
        witness <- expectRight result
        leaseWitnessCurrent (monotonicInstantFromMicros 29999999) leaseName duration binding witness
          `shouldBe` True
        leaseWitnessCurrent (monotonicInstantFromMicros 30000000) leaseName duration binding witness
          `shouldBe` False
      it "does not extend the witness by time spent acquiring and reading back" $ do
        (fixedRuntime, _, _) <- fakeRuntime Nothing
        wallReads <- newIORef (0 :: Natural)
        let progressingWall = do
              readCount <- readIORef wallReads
              modifyIORef' wallReads (+ 1)
              pure $
                if readCount == 0
                  then wallNow
                  else addUTCTime 10 wallNow
            runtime = fixedRuntime {leaseRuntimeWallNow = progressingWall}
        result <- acquireEmitterLease runtime callerDeadline leaseName duration binding
        witness <- expectRight result
        leaseWitnessCurrent (monotonicInstantFromMicros 19999999) leaseName duration binding witness
          `shouldBe` True
        leaseWitnessCurrent (monotonicInstantFromMicros 20000000) leaseName duration binding witness
          `shouldBe` False
      it "anchors wall-clock expiry at the earlier monotonic clock sample" $ do
        (fixedRuntime, _, _) <- fakeRuntime Nothing
        monotonicReads <- newIORef (0 :: Natural)
        let progressingMonotonic = do
              readCount <- readIORef monotonicReads
              modifyIORef' monotonicReads (+ 1)
              pure . monotonicInstantFromMicros $
                if readCount >= 6 then 5 * 1000000 else 0
            runtime = fixedRuntime {leaseRuntimeMonotonicNow = progressingMonotonic}
        result <- acquireEmitterLease runtime callerDeadline leaseName duration binding
        witness <- expectRight result
        leaseWitnessCurrent (monotonicInstantFromMicros 29999999) leaseName duration binding witness
          `shouldBe` True
        leaseWitnessCurrent (monotonicInstantFromMicros 30000000) leaseName duration binding witness
          `shouldBe` False
      it "binds a witness to the exact canonical Lease name and duration" $ do
        (runtime, _, _) <- fakeRuntime Nothing
        result <- acquireEmitterLease runtime callerDeadline leaseName duration binding
        witness <- expectRight result
        let otherName = either (error . show) id (mkLeaseName "prodbox-emitter-node-b")
            otherDuration = either (error . show) id (mkLeaseDuration 31)
            now = monotonicInstantFromMicros 0
        leaseWitnessCurrent now otherName duration binding witness `shouldBe` False
        leaseWitnessCurrent now leaseName otherDuration binding witness `shouldBe` False
        renewEmitterLease runtime callerDeadline otherName duration witness
          `shouldReturn` Left LeaseWitnessCoordinateMismatch
        renewEmitterLease runtime callerDeadline leaseName otherDuration witness
          `shouldReturn` Left LeaseWitnessCoordinateMismatch
      it "refuses a witness when the caller deadline expires during read-back" $ do
        (fixedRuntime, _, _) <- fakeRuntime Nothing
        monotonicReads <- newIORef (0 :: Natural)
        let progressingMonotonic = do
              readCount <- readIORef monotonicReads
              modifyIORef' monotonicReads (+ 1)
              pure . monotonicInstantFromMicros $
                if readCount >= 6 then 5 * 1000000 else 0
            runtime = fixedRuntime {leaseRuntimeMonotonicNow = progressingMonotonic}
            shortDeadline =
              deadlineAtOffset
                (monotonicInstantFromMicros 0)
                (RemainingDuration (4 * 1000000))
        acquireEmitterLease runtime shortDeadline leaseName duration binding
          `shouldReturn` Left LeaseDeadlineExpired
      it "renews the same holder through resource-version replacement" $ do
        let current = (recordFor holder wallNow) {leaseRecordResourceVersion = "rv-4"}
        (runtime, recordRef, _) <- fakeRuntime (Just current)
        result <- acquireEmitterLease runtime callerDeadline leaseName duration binding
        witness <- expectRight result
        leaseWitnessResourceVersion witness `shouldBe` "rv-5"
        stored <- readIORef recordRef
        fmap leaseRecordTransitions stored `shouldBe` Just 0
      it "performs no observation or mutation after the caller deadline" $ do
        (runtime, _, mutationCount) <- fakeRuntime Nothing
        result <-
          acquireEmitterLease
            runtime
            (deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 0))
            leaseName
            duration
            binding
        result `shouldBe` Left LeaseDeadlineExpired
        readIORef mutationCount `shouldReturn` 0
      it "rejects a mutation conflict without manufacturing a witness" $ do
        let client =
              EmitterLeaseClient
                { leaseClientObserve = \_ _ -> pure LeaseMissing
                , leaseClientCreate = \_ _ -> pure LeaseMutationConflict
                , leaseClientReplace = \_ _ -> pure LeaseMutationConflict
                }
            runtime = clocks client
        acquireEmitterLease runtime callerDeadline leaseName duration binding
          `shouldReturn` Left LeaseMutationConflictFailure
      it "rejects a mismatching authoritative read-back" $ do
        observations <- newIORef (0 :: Natural)
        let client =
              EmitterLeaseClient
                { leaseClientObserve = \_ _ -> do
                    count <- readIORef observations
                    modifyIORef' observations (+ 1)
                    pure $
                      if count == 0
                        then LeaseMissing
                        else LeaseObserved (recordFor "wrong-holder" wallNow)
                , leaseClientCreate = \_ desired ->
                    pure (LeaseMutationApplied desired {leaseRecordResourceVersion = "rv-1"})
                , leaseClientReplace = \_ _ -> pure LeaseMutationConflict
                }
        acquireEmitterLease (clocks client) callerDeadline leaseName duration binding
          `shouldReturn` Left LeaseReadBackMismatch
      it "rejects an observation returned for a different Lease coordinate" $ do
        let otherName = either (error . show) id (mkLeaseName "prodbox-emitter-node-b")
            client =
              EmitterLeaseClient
                { leaseClientObserve = \_ _ ->
                    pure (LeaseObserved ((recordFor holder wallNow) {leaseRecordName = otherName}))
                , leaseClientCreate = \_ _ -> pure LeaseMutationConflict
                , leaseClientReplace = \_ _ -> pure LeaseMutationConflict
                }
        acquireEmitterLease (clocks client) callerDeadline leaseName duration binding
          `shouldReturn` Left LeaseObservationCoordinateMismatch

wallNow :: UTCTime
wallNow = UTCTime (fromGregorian 2026 7 20) (secondsToDiffTime (12 * 60 * 60))

leaseName :: LeaseName
leaseName = either (error . show) id (mkLeaseName "prodbox-emitter-node-a")

duration :: LeaseDuration
duration = either (error . show) id (mkLeaseDuration 30)

binding :: LeaseBinding
binding = mkBinding 1 7

mkBinding :: Word -> Word -> LeaseBinding
mkBinding incarnation journalByte =
  either (error . show) id $
    mkLeaseBinding
      "node-a"
      (fromIntegral incarnation)
      (BS.replicate 32 (fromIntegral journalByte))
      (BS.replicate 32 9)

holder :: Text
holder = leaseBindingHolderIdentity binding

recordFor :: Text -> UTCTime -> LeaseRecord
recordFor recordHolder renewedAt =
  LeaseRecord
    { leaseRecordName = leaseName
    , leaseRecordResourceVersion = "rv-1"
    , leaseRecordHolderIdentity = recordHolder
    , leaseRecordDuration = duration
    , leaseRecordAcquireTime = addUTCTime (-60) wallNow
    , leaseRecordRenewTime = renewedAt
    , leaseRecordTransitions = 0
    }

callerDeadline :: Deadline
callerDeadline =
  deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration (120 * 1000000))

fixedMonotonicNow :: IO MonotonicInstant
fixedMonotonicNow = pure (monotonicInstantFromMicros 0)

responseDeadline :: Deadline
responseDeadline =
  deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 1000000)

shortResponseDeadline :: Deadline
shortResponseDeadline =
  deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 100000)

nextMonotonicObservation :: IORef [Natural] -> IO MonotonicInstant
nextMonotonicObservation observationsRef = do
  observations <- readIORef observationsRef
  case observations of
    [] -> fail "monotonic observation fixture exhausted"
    observation : remaining -> do
      writeIORef observationsRef remaining
      pure (monotonicInstantFromMicros observation)

chunkReader
  :: IORef [BL.ByteString]
  -> IORef [Int]
  -> Int
  -> IO BL.ByteString
chunkReader chunksRef requestsRef requested = do
  modifyIORef' requestsRef (++ [requested])
  chunks <- readIORef chunksRef
  case chunks of
    [] -> pure BL.empty
    chunk : remaining -> do
      writeIORef chunksRef remaining
      pure chunk

clocks :: EmitterLeaseClient -> EmitterLeaseRuntime
clocks client =
  EmitterLeaseRuntime
    { leaseRuntimeClient = client
    , leaseRuntimeWallNow = pure wallNow
    , leaseRuntimeMonotonicNow = pure (monotonicInstantFromMicros 0)
    }

fakeRuntime
  :: Maybe LeaseRecord
  -> IO (EmitterLeaseRuntime, IORef (Maybe LeaseRecord), IORef Natural)
fakeRuntime initial = do
  recordRef <- newIORef initial
  mutationCount <- newIORef 0
  let apply _deadline desired = do
        modifyIORef' mutationCount (+ 1)
        previous <- readIORef recordRef
        let previousVersion :: Natural
            previousVersion = maybe 0 parseVersion previous
            applied = desired {leaseRecordResourceVersion = "rv-" <> fromString (previousVersion + 1)}
        writeIORef recordRef (Just applied)
        pure (LeaseMutationApplied applied)
      client =
        EmitterLeaseClient
          { leaseClientObserve = \_ _ -> maybe LeaseMissing LeaseObserved <$> readIORef recordRef
          , leaseClientCreate = apply
          , leaseClientReplace = apply
          }
  pure (clocks client, recordRef, mutationCount)
 where
  parseVersion :: LeaseRecord -> Natural
  parseVersion record = case leaseRecordResourceVersion record of
    "rv-4" -> 4
    _ -> 0
  fromString :: Natural -> Text
  fromString value = case value of
    1 -> "1"
    5 -> "5"
    _ -> error "unexpected fake resource version"

isRenew :: LeaseDecision -> Bool
isRenew LeaseRenew {} = True
isRenew _ = False

isTakeover :: LeaseDecision -> Bool
isTakeover LeaseTakeOver {} = True
isTakeover _ = False

isRefusal :: LeaseDecision -> Bool
isRefusal LeaseRefuseLiveHolder {} = True
isRefusal _ = False

leaseWireJson :: LeaseRecord -> BL.ByteString
leaseWireJson record = leaseWireJsonWithName (leaseNameText (leaseRecordName record)) record

leaseWireJsonWithName :: Text -> LeaseRecord -> BL.ByteString
leaseWireJsonWithName rawName record =
  encode $
    object
      [ "metadata"
          .= object
            [ "name" .= rawName
            , "resourceVersion" .= leaseRecordResourceVersion record
            ]
      , "spec"
          .= object
            [ "holderIdentity" .= leaseRecordHolderIdentity record
            , "leaseDurationSeconds" .= leaseDurationSeconds (leaseRecordDuration record)
            , "acquireTime" .= leaseRecordAcquireTime record
            , "renewTime" .= leaseRecordRenewTime record
            , "leaseTransitions" .= leaseRecordTransitions record
            ]
      ]

isUnobservable :: LeaseObservation -> Bool
isUnobservable LeaseUnobservable {} = True
isUnobservable _ = False

isMutationUnobservable :: LeaseMutationResult -> Bool
isMutationUnobservable LeaseMutationUnobservable {} = True
isMutationUnobservable _ = False

isRight :: Either left right -> Bool
isRight result = case result of
  Left _ -> False
  Right _ -> True

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right value -> pure value
