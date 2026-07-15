{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module RetainedSesTargetRecovery
  ( retainedSesTargetRecoverySuite
  )
where

import Data.ByteString (ByteString)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBLeaseGuard (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , TargetClusterSecretSink
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , mkTargetClusterSecretSink
  , targetSecretSinkIdentity
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencedCommitPermit
  , LeaseCommitDecision (..)
  , LeaseGrant
  , LeaseKey
  , LeasePolicy
  , OwnerNonce
  , RawLeasePolicy (..)
  , authorityDurationMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  , decideFencedCommit
  , leaseGrantFencingToken
  , mkFencingToken
  , mkLeaseGrant
  , mkLeaseKey
  , mkLeasePolicy
  , mkLeaseProjection
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , RegisteredTargetSet
  , TargetCommitDisposition (..)
  , TargetIntentCoordinate
  , TargetIntentProjection
  , TargetSinkCasAdapter (..)
  , TargetSinkCasRequest (..)
  , TargetSinkCasResult (..)
  , TargetSinkObservation (..)
  , TargetSinkReadbackRefusal (..)
  , TargetSinkVersion
  , TargetValueDigest
  , mkCredentialGeneration
  , mkRegisteredTargetSet
  , mkTargetIntentCoordinate
  , mkTargetSinkVersion
  , mkTargetValueDigest
  , targetCommitDisposition
  , targetIntentCoordinateLeaseObject
  , targetProjectionEntries
  , targetProjectionEntryIntent
  , targetProjectionEntryTargetIdentity
  )
import Prodbox.Lifecycle.TargetCommitInterpreter
  ( TargetCommitInterpreter (..)
  , TargetCommitInterpreterError (..)
  , TargetCommitRun (..)
  , TargetRecoveryInterpreter (..)
  , TargetRecoveryRun (..)
  , runPreparedTargetCommit
  , runSuccessorTargetRecoveryAfter
  )
import TestSupport

retainedSesTargetRecoverySuite :: SuiteBuilder ()
retainedSesTargetRecoverySuite =
  describe "Sprint 5.17 retained SES different-sink recovery" $ do
    it "resolves sink A's nonterminal intent before generation or sink B admission" $ do
      state <- newFakeState
      leavePreparedOwnerIntent state
      preparedIdentities state `shouldReturn` ["home"]
      readSink state "home" >>= (`shouldSatisfy` isObservedSink)
      readSink state "aws" `shouldReturn` TargetSinkMissing

      writeIORef (fakeEvents state) []
      successor <- recoverBeforeSuccessorAdmission state
      successor
        `shouldBe` Right
          TargetCommitRunCommitted
            { targetCommitRunTargetIdentity = "aws"
            , targetCommitRunGeneration = generationTwo
            , targetCommitRunSinkCasAttempted = True
            }
      preparedIdentities state `shouldReturn` []

      events <- readIORef (fakeEvents state)
      events
        `shouldSatisfy` ( \actual ->
                            containsInOrder
                              actual
                              [ SinkObserved "home"
                              , SinkObserved "home"
                              , RecoveryConfirmed ["home"]
                              , CredentialGenerated generationTwo
                              , SuccessorAdmitted "aws"
                              , SinkObserved "aws"
                              , SinkWritten "aws"
                              ]
                        )
      let beforeGeneration = takeWhile (/= CredentialGenerated generationTwo) events
      filter (== SinkObserved "home") beforeGeneration `shouldBe` replicate 2 (SinkObserved "home")
      beforeGeneration `shouldSatisfy` notElem (SuccessorAdmitted "aws")
      beforeGeneration `shouldSatisfy` notElem (SinkWritten "aws")
      filter (== SinkWritten "aws") events `shouldBe` [SinkWritten "aws"]

    it "fails closed when the predecessor sink is unobservable" $ do
      state <- newFakeState
      leavePreparedOwnerIntent state
      setSink state "home" (TargetSinkUnobservable "predecessor target unavailable")
      writeIORef (fakeEvents state) []

      successor <- recoverBeforeSuccessorAdmission state
      successor
        `shouldBe` Left
          ( TargetCommitRecoveryReadbackFailed
              "home"
              (TargetSinkReadbackUnobservable "predecessor target unavailable")
          )
      preparedIdentities state `shouldReturn` ["home"]
      readSink state "aws" `shouldReturn` TargetSinkMissing

      events <- readIORef (fakeEvents state)
      filter (== SinkObserved "home") events `shouldBe` replicate 2 (SinkObserved "home")
      events `shouldSatisfy` notElem (CredentialGenerated generationTwo)
      events `shouldSatisfy` notElem (SuccessorAdmitted "aws")
      events `shouldSatisfy` notElem (SinkObserved "aws")
      events `shouldSatisfy` notElem (SinkWritten "aws")
      events `shouldSatisfy` all isNotGlobalCas

data FakeEvent
  = GlobalObserved
  | GlobalCas !Natural
  | SinkObserved !Text
  | SinkWritten !Text
  | WaitedUntil !AuthorityTime
  | WaitedFor
  | RecoveryConfirmed ![Text]
  | CredentialGenerated !CredentialGeneration
  | SuccessorAdmitted !Text
  deriving (Eq, Show)

isNotGlobalCas :: FakeEvent -> Bool
isNotGlobalCas event = case event of
  GlobalCas _ -> False
  _ -> True

data FakeState = FakeState
  { fakeEvents :: !(IORef [FakeEvent])
  , fakeGlobal :: !(IORef (ModelBObservation TargetIntentProjection))
  , fakeGlobalVersion :: !(IORef Natural)
  , fakeSinks :: !(IORef (Map Text (TargetSinkObservation ByteString)))
  , fakeNow :: !(IORef AuthorityTime)
  }

newFakeState :: IO FakeState
newFakeState = do
  fakeEvents <- newIORef []
  fakeGlobal <- newIORef ModelBMissing
  fakeGlobalVersion <- newIORef 1
  fakeSinks <- newIORef (Map.fromList [("home", TargetSinkMissing), ("aws", TargetSinkMissing)])
  fakeNow <- newIORef recoveryBoundary
  pure FakeState {fakeEvents, fakeGlobal, fakeGlobalVersion, fakeSinks, fakeNow}

-- The first run reaches the real target CAS and read-back, then loses its
-- authority clock before global completion. This is the crash window that the
-- successor must close before admitting work for a different registered sink.
leavePreparedOwnerIntent :: FakeState -> IO ()
leavePreparedOwnerIntent state = do
  timeCalls <- newIORef (0 :: Int)
  let ownerTime = do
        call <- readIORef timeCalls
        writeIORef timeCalls (call + 1)
        pure $
          if call < 2
            then Right (at 1250)
            else Left "owner lost authority after sink write"
      interpreter = fakeInterpreter state ownerPermit ownerTime
  result <-
    runPreparedTargetCommit
      interpreter
      registeredTargets
      intentCoordinate
      homeSink
      generationOne
      digestA
      (at 1600)
      payloadA
  result
    `shouldBe` Left
      (TargetCommitAuthorityClockUnavailable "owner lost authority after sink write")

recoverBeforeSuccessorAdmission
  :: FakeState
  -> IO (Either TargetCommitInterpreterError TargetCommitRun)
recoverBeforeSuccessorAdmission state = do
  recovered <-
    runSuccessorTargetRecoveryAfter
      (fakeRecoveryInterpreter state)
      registeredTargets
      intentCoordinate
      leasePolicy
      recoveryBoundary
  case recovered of
    Left err -> pure (Left err)
    Right recoveryRun -> do
      outstanding <- preparedIdentities state
      if null outstanding
        then do
          record state (RecoveryConfirmed (resolvedIdentities recoveryRun))
          record state (CredentialGenerated generationTwo)
          record state (SuccessorAdmitted "aws")
          runPreparedTargetCommit
            (fakeInterpreter state successorPermit (Right <$> readIORef (fakeNow state)))
            registeredTargets
            intentCoordinate
            awsSink
            generationTwo
            digestB
            (at 3500)
            payloadB
        else error ("recovery returned before resolving global intents: " ++ show outstanding)

resolvedIdentities :: TargetRecoveryRun -> [Text]
resolvedIdentities recoveryRun = case recoveryRun of
  TargetRecoveryRunAlreadyResolved -> []
  TargetRecoveryRunResolved identities -> identities

fakeRecoveryInterpreter :: FakeState -> TargetRecoveryInterpreter IO ByteString
fakeRecoveryInterpreter state =
  TargetRecoveryInterpreter
    { targetRecoveryBaseInterpreter =
        fakeInterpreter state successorPermit (Right <$> readIORef (fakeNow state))
    , targetRecoveryWaitUntil = \deadline -> do
        record state (WaitedUntil deadline)
        writeIORef (fakeNow state) deadline
        pure (Right ())
    , targetRecoveryWaitFor = \duration -> do
        record state WaitedFor
        now <- readIORef (fakeNow state)
        writeIORef
          (fakeNow state)
          (at (authorityTimeMicros now + authorityDurationMicros duration))
        pure (Right ())
    }

fakeInterpreter
  :: FakeState
  -> FencedCommitPermit
  -> IO (Either Text AuthorityTime)
  -> TargetCommitInterpreter IO ByteString
fakeInterpreter state permit currentTime =
  TargetCommitInterpreter
    { targetCommitGlobalAdapter = fakeGlobalAdapter state
    , targetCommitSinkAdapter = fakeSinkAdapter state
    , targetCommitCurrentPermit = pure (Right permit)
    , targetCommitCurrentAuthorityTime = currentTime
    , targetCommitDigestPayload = payloadDigest
    }

fakeGlobalAdapter :: FakeState -> ModelBCasAdapter 'ClusterRetained IO TargetIntentProjection
fakeGlobalAdapter state =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        record state GlobalObserved
        readIORef (fakeGlobal state)
    , modelBCompareAndSwap = \request -> do
        current <- readIORef (fakeGlobal state)
        case admissibleGlobalRequest current request of
          Nothing -> pure (ModelBCasConflict current)
          Just (guard, projection) -> do
            record state (GlobalCas (modelBLeaseGuardFencingTokenValue guard))
            versionNumber <- readIORef (fakeGlobalVersion state)
            let version =
                  expectRight
                    (mkModelBObjectVersion ("target-intent-v" <> Text.pack (show versionNumber)))
            writeIORef (fakeGlobal state) (ModelBObserved version projection)
            writeIORef (fakeGlobalVersion state) (versionNumber + 1)
            pure (ModelBCasApplied version projection)
    }

admissibleGlobalRequest
  :: ModelBObservation TargetIntentProjection
  -> ModelBCasRequest 'ClusterRetained TargetIntentProjection
  -> Maybe (ModelBLeaseGuard, TargetIntentProjection)
admissibleGlobalRequest current request = case (current, request) of
  (ModelBMissing, ModelBInitializeGuarded _ guard projection)
    | knownGuard guard -> Just (guard, projection)
  (ModelBObserved currentVersion _, ModelBReplaceGuarded _ expectedVersion guard projection)
    | currentVersion == expectedVersion && knownGuard guard -> Just (guard, projection)
  _ -> Nothing
 where
  knownGuard guard = guard == expectedOwnerGuard || guard == expectedSuccessorGuard

fakeSinkAdapter :: FakeState -> TargetSinkCasAdapter IO ByteString
fakeSinkAdapter state =
  TargetSinkCasAdapter
    { targetSinkObserve = \sink -> do
        let identity = targetSecretSinkIdentity sink
        record state (SinkObserved identity)
        readSink state identity
    , targetSinkCompareAndSwap = \request -> do
        let (sink, expectedVersion, sinkRecord) = case request of
              TargetSinkInitialize target value -> (target, Nothing, value)
              TargetSinkReplace target expected value -> (target, Just expected, value)
            identity = targetSecretSinkIdentity sink
        current <- readSink state identity
        if sinkCasMatches expectedVersion current
          then do
            let version = sinkVersion identity expectedVersion
                observation = TargetSinkObserved version sinkRecord
            record state (SinkWritten identity)
            setSink state identity observation
            pure (TargetSinkCasApplied version sinkRecord)
          else pure (TargetSinkCasConflict current)
    }

sinkCasMatches
  :: Maybe TargetSinkVersion
  -> TargetSinkObservation payload
  -> Bool
sinkCasMatches expectedVersion current = case (expectedVersion, current) of
  (Nothing, TargetSinkMissing) -> True
  (Just expected, TargetSinkObserved actual _) -> expected == actual
  _ -> False

sinkVersion :: Text -> Maybe TargetSinkVersion -> TargetSinkVersion
sinkVersion identity expectedVersion =
  expectRight
    ( mkTargetSinkVersion
        (identity <> case expectedVersion of Nothing -> "-v1"; Just _ -> "-v2")
    )

readSink :: FakeState -> Text -> IO (TargetSinkObservation ByteString)
readSink state identity = do
  sinks <- readIORef (fakeSinks state)
  pure (Map.findWithDefault TargetSinkMissing identity sinks)

setSink :: FakeState -> Text -> TargetSinkObservation ByteString -> IO ()
setSink state identity observation =
  modifyIORef' (fakeSinks state) (Map.insert identity observation)

preparedIdentities :: FakeState -> IO [Text]
preparedIdentities state = do
  global <- readIORef (fakeGlobal state)
  pure $ case global of
    ModelBObserved _ projection ->
      [ targetProjectionEntryTargetIdentity entry
      | entry <- targetProjectionEntries projection
      , Just intent <- [targetProjectionEntryIntent entry]
      , targetCommitDisposition intent == TargetCommitPrepared
      ]
    _ -> []

isObservedSink :: TargetSinkObservation payload -> Bool
isObservedSink observation = case observation of
  TargetSinkObserved _ _ -> True
  _ -> False

containsInOrder :: (Eq value) => [value] -> [value] -> Bool
containsInOrder actual expected = go actual expected
 where
  go _ [] = True
  go [] _ = False
  go (value : rest) wanted@(next : remaining)
    | value == next = go rest remaining
    | otherwise = go rest wanted

record :: FakeState -> FakeEvent -> IO ()
record state event = modifyIORef' (fakeEvents state) (++ [event])

leasePolicy :: LeasePolicy
leasePolicy = expectRight (mkLeasePolicy rawLeasePolicy)

rawLeasePolicy :: RawLeasePolicy
rawLeasePolicy =
  RawLeasePolicy
    { rawLeaseAcquireTimeoutMicros = 100
    , rawLeaseGrantTtlMicros = 1000
    , rawLeaseReconcileBudgetMicros = 200
    , rawLeaseReadinessBudgetMicros = 300
    , rawLeaseSmtpCommitBudgetMicros = 100
    , rawLeaseCancellationGraceMicros = 100
    , rawLeaseClockSkewMicros = 50
    , rawLeaseSafetyMarginMicros = 100
    , rawLeaseProviderInFlightGraceMicros = 200
    , rawLeaseProviderVisibilityGraceMicros = 100
    , rawLeaseTargetWriteGraceMicros = 300
    , rawLeaseStableObservationCount = 2
    }

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "https://gateway.control.example.test"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
    )

leaseKey :: LeaseKey
leaseKey = expectRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

intentCoordinate :: TargetIntentCoordinate
intentCoordinate = expectRight (mkTargetIntentCoordinate authority leaseKey)

homeSink :: TargetClusterSecretSink
homeSink = targetSink "home" "https://gateway.home.example.test"

awsSink :: TargetClusterSecretSink
awsSink = targetSink "aws" "https://gateway.aws.example.test"

targetSink :: Text -> Text -> TargetClusterSecretSink
targetSink identity endpoint =
  expectRight (mkTargetClusterSecretSink identity endpoint "secret" "keycloak/smtp")

registeredTargets :: RegisteredTargetSet
registeredTargets = expectRight (mkRegisteredTargetSet 2 [homeSink, awsSink])

ownerGrant :: LeaseGrant
ownerGrant = grant 1 (expectRight (mkOwnerNonce "owner-a")) 1000

successorGrant :: LeaseGrant
successorGrant = grant 2 (expectRight (mkOwnerNonce "owner-b")) 3000

grant :: Natural -> OwnerNonce -> Natural -> LeaseGrant
grant fenceValue owner issuedAt =
  expectRight
    ( mkLeaseGrant
        leasePolicy
        leaseKey
        owner
        (expectRight (mkFencingToken fenceValue))
        (at issuedAt)
        (at (issuedAt + 1000))
        (at (issuedAt + 750))
    )

ownerPermit :: FencedCommitPermit
ownerPermit = permitFor ownerGrant 1250 "lease-owner-v1"

successorPermit :: FencedCommitPermit
successorPermit = permitFor successorGrant 3100 "lease-successor-v1"

permitFor :: LeaseGrant -> Natural -> Text -> FencedCommitPermit
permitFor leaseGrant now version =
  case decideFencedCommit
    (at now)
    leaseGrant
    ( ModelBObserved
        (expectRight (mkModelBObjectVersion version))
        (expectRight (mkLeaseProjection (leaseGrantFencingToken leaseGrant) (Just leaseGrant)))
    ) of
    LeaseCommitAuthorized permit -> permit
    other -> error ("expected fenced commit permit, got " ++ show other)

expectedOwnerGuard :: ModelBLeaseGuard
expectedOwnerGuard =
  ModelBLeaseGuard
    { modelBLeaseGuardCoordinate =
        targetIntentCoordinateLeaseObject intentCoordinate
    , modelBLeaseGuardExpectedVersion = expectRight (mkModelBObjectVersion "lease-owner-v1")
    , modelBLeaseGuardOwnerNonceText = "owner-a"
    , modelBLeaseGuardFencingTokenValue = 1
    }

expectedSuccessorGuard :: ModelBLeaseGuard
expectedSuccessorGuard =
  ModelBLeaseGuard
    { modelBLeaseGuardCoordinate =
        targetIntentCoordinateLeaseObject intentCoordinate
    , modelBLeaseGuardExpectedVersion = expectRight (mkModelBObjectVersion "lease-successor-v1")
    , modelBLeaseGuardOwnerNonceText = "owner-b"
    , modelBLeaseGuardFencingTokenValue = 2
    }

generationOne :: CredentialGeneration
generationOne = expectRight (mkCredentialGeneration 1)

generationTwo :: CredentialGeneration
generationTwo = expectRight (mkCredentialGeneration 2)

digestA :: TargetValueDigest
digestA = expectRight (mkTargetValueDigest (Text.replicate 64 "a"))

digestB :: TargetValueDigest
digestB = expectRight (mkTargetValueDigest (Text.replicate 64 "b"))

payloadA :: ByteString
payloadA = "smtp-payload-a"

payloadB :: ByteString
payloadB = "smtp-payload-b"

payloadDigest :: ByteString -> TargetValueDigest
payloadDigest payload
  | payload == payloadA = digestA
  | payload == payloadB = digestB
  | otherwise = error "unexpected fake SMTP payload"

recoveryBoundary :: AuthorityTime
recoveryBoundary = at 3000

at :: Natural -> AuthorityTime
at = authorityTimeFromMicros

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result = case result of
  Left err -> error ("unexpected Left: " ++ show err)
  Right value -> value
