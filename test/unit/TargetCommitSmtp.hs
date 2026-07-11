{-# LANGUAGE OverloadedStrings #-}

module TargetCommitSmtp
  ( targetCommitSmtpSuite
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
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
import Prodbox.Gateway.Daemon
  ( decodeTargetSecretCasRequest
  , decodeTargetSecretReadRequest
  )
import Prodbox.Gateway.TargetSecret qualified as TargetSecret
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBLeaseGuard (..)
  , ModelBObservation (..)
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
import Prodbox.Lifecycle.SmtpKeyRepair
import Prodbox.Lifecycle.TargetCommitIntent
import Prodbox.Lifecycle.TargetCommitInterpreter
import TestSupport

targetCommitSmtpSuite :: SuiteBuilder ()
targetCommitSmtpSuite = do
  describe "Sprint 4.47 bounded global target-commit protocol" $ do
    it "rejects unregistered, duplicate, and over-bound target registrations" $ do
      mkRegisteredTargetSet 1 [sinkA, sinkB]
        `shouldBe` Left (TargetRegistrationOverBound 2 1)
      mkRegisteredTargetSet 2 [sinkA, sinkA]
        `shouldBe` Left (TargetRegistrationDuplicateIdentity "home")
      mkRegisteredTargetSet
        2
        [sinkA, sink "home-alias" "https://gateway.home.example.test"]
        `shouldBe` Left (TargetRegistrationDuplicateSinkCoordinate "home" "home-alias")
      mkRegisteredTargetSet 65 []
        `shouldBe` Left (TargetRegistrationCapacityExceedsHardMaximum 65 64)
      decidePrepareTargetCommit
        registered
        intentCoordinate
        (at 1200)
        (at 1600)
        ownerPermit
        unregisteredSink
        generationOne
        digestA
        ModelBMissing
        `shouldBe` TargetCommitPrepareRefused
          (TargetCommitUnregisteredTarget "unregistered")

    it "runs prepare -> revalidate -> one sink CAS -> readback -> global completion" $ do
      let (projection, intent) = firstPrepared sinkA
          globalObservation = observedGlobal "intent-v1" projection
          writePermit =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intent
                  globalObservation
              )
      record <- case decideTargetSinkWrite payloadDigest writePermit secretPayload TargetSinkMissing of
        TargetSinkWriteCompareAndSwap (TargetSinkInitialize actualSink record) -> do
          actualSink `shouldBe` sinkA
          pure record
        other -> unexpected ("expected one sink initialize CAS, got " ++ show other)
      let sinkReadback = TargetSinkObserved sinkVersion record
          readback = expectRight (confirmTargetSinkReadback payloadDigest writePermit sinkReadback)
      completed <- case decideCompleteTargetCommit
        registered
        intentCoordinate
        (at 1300)
        ownerPermit
        readback
        globalObservation of
        TargetCommitCompleteCompareAndSwap (ModelBReplaceGuarded _ _ guard next) -> do
          assertOwnerGuard guard
          pure next
        other -> unexpected ("expected global completion CAS, got " ++ show other)
      currentIntent completed "home" `shouldSatisfy` hasDisposition TargetCommitCommitted
      compacted <- case compactTargetIntent
        registered
        intentCoordinate
        ownerPermit
        "home"
        (observedGlobal "intent-v2" completed) of
        TargetIntentCompactCompareAndSwap (ModelBReplaceGuarded _ _ guard next) -> do
          assertOwnerGuard guard
          pure next
        other -> unexpected ("expected terminal compaction CAS, got " ++ show other)
      currentIntent compacted "home" `shouldBe` Nothing
      currentCommitted compacted "home"
        `shouldBe` Just (generationOne, digestA)

    it "refuses unobservable, unbounded, changing, and failed readback state" $ do
      let (projection, intent) = firstPrepared sinkA
          globalObservation = observedGlobal "intent-v1" projection
          writePermit =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intent
                  globalObservation
              )
      decideTargetSinkWrite payloadDigest writePermit secretPayload (TargetSinkUnobservable "denied")
        `shouldBe` TargetSinkWriteRefused (TargetSinkReadbackUnobservable "denied")
      decideTargetSinkWrite payloadDigest writePermit secretPayload (TargetSinkUnbounded 2 1)
        `shouldBe` TargetSinkWriteRefused (TargetSinkReadbackUnbounded 2 1)
      decideTargetSinkWrite payloadDigest writePermit secretPayload (TargetSinkChanging "cas conflict")
        `shouldBe` TargetSinkWriteRefused (TargetSinkReadbackChanging "cas conflict")
      confirmTargetSinkReadback payloadDigest writePermit TargetSinkMissing
        `shouldBe` Left TargetSinkReadbackMissing
      prepareTargetWrite
        registered
        (at 1250)
        ownerPermit
        sinkA
        intent
        (ModelBUnobservable "authority timeout")
        `shouldBe` Left (TargetCommitGlobalUnobservable "authority timeout")

    it "resolves every same-generation cross-sink intent after target grace" $ do
      let (projectionA, intentA) = firstPrepared sinkA
          (projectionBoth, intentB) = appendPrepared sinkB projectionA
          writePermitA =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intentA
                  (observedGlobal "intent-v2" projectionBoth)
              )
          recordA = case decideTargetSinkWrite payloadDigest writePermitA secretPayload TargetSinkMissing of
            TargetSinkWriteCompareAndSwap (TargetSinkInitialize _ record) -> record
            other -> error ("expected sink action: " ++ show other)
          exactA = TargetSinkObserved sinkVersion recordA
          witnessA =
            expectRight
              ( proveStableTargetReadback
                  payloadDigest
                  registered
                  policy
                  ownerGrant
                  intentA
                  [targetSample 2750 exactA, targetSample 2850 exactA]
              )
          witnessB =
            expectRight
              ( proveStableTargetReadback
                  payloadDigest
                  registered
                  policy
                  ownerGrant
                  intentB
                  [targetSample 2750 TargetSinkMissing, targetSample 2850 TargetSinkMissing]
              )
      recovered <- case decideResolveOutstandingTargets
        registered
        intentCoordinate
        successorPermit
        [witnessA, witnessB]
        (observedGlobal "intent-v3" projectionBoth) of
        TargetRecoveryCompareAndSwap (ModelBReplaceGuarded _ _ guard next) -> do
          assertSuccessorGuard guard
          pure next
        other -> unexpected ("expected cross-sink recovery CAS, got " ++ show other)
      currentIntent recovered "home" `shouldSatisfy` hasDisposition TargetCommitCommitted
      currentIntent recovered "aws" `shouldSatisfy` hasDisposition TargetCommitAborted

    it "requires stable post-grace evidence and authoritatively retires a target entry" $ do
      let (projection, intent) = firstPrepared sinkB
      proveStableTargetReadback
        payloadDigest
        registered
        policy
        ownerGrant
        intent
        [targetSample 2749 TargetSinkRetired, targetSample 2849 TargetSinkRetired]
        `shouldBe` Left (TargetSinkObservationBeforeGrace (at 2749) (at 2750))
      proveStableTargetReadback
        payloadDigest
        registered
        policy
        ownerGrant
        intent
        [targetSample 2750 TargetSinkMissing, targetSample 2850 TargetSinkRetired]
        `shouldBe` Left TargetSinkStableStateChanged
      let retiredWitness =
            expectRight
              ( proveStableTargetReadback
                  payloadDigest
                  registered
                  policy
                  ownerGrant
                  intent
                  [targetSample 2750 TargetSinkRetired, targetSample 2850 TargetSinkRetired]
              )
      case decideResolveOutstandingTargets
        registered
        intentCoordinate
        successorPermit
        [retiredWitness]
        (observedGlobal "intent-v2" projection) of
        TargetRecoveryCompareAndSwap (ModelBReplaceGuarded _ _ guard next) -> do
          assertSuccessorGuard guard
          map targetProjectionEntryTargetIdentity (targetProjectionEntries next)
            `shouldBe` []
        other -> expectationFailure ("expected retired-target recovery, got " ++ show other)

    it "round-trips the bounded projection through validated canonical CBOR" $ do
      let (projection, _) = firstPrepared sinkA
          encoded = encodeTargetIntentProjection projection
      decodeTargetIntentProjection registered encoded `shouldBe` Right projection
      decodeTargetIntentProjection registeredAOnly encoded
        `shouldSatisfy` isRegistrationCodecRefusal
      decodeTargetIntentProjection
        registered
        (BS.replicate (targetIntentProjectionMaximumEncodedBytes + 1) 0)
        `shouldBe` Left
          ( TargetIntentProjectionCodecTooLarge
              (targetIntentProjectionMaximumEncodedBytes + 1)
              targetIntentProjectionMaximumEncodedBytes
          )

    it "interprets the full protocol with exactly one sink CAS and fresh global guards" $ do
      events <- newIORef []
      global <- newIORef ModelBMissing
      sinkState <- newIORef TargetSinkMissing
      globalVersion <- newIORef (1 :: Natural)
      let interpreter = fakeTargetCommitInterpreter events global sinkState globalVersion
      result <-
        runPreparedTargetCommit
          interpreter
          registered
          intentCoordinate
          sinkA
          generationOne
          digestA
          (at 1600)
          secretFields
      result
        `shouldBe` Right
          TargetCommitRunCommitted
            { targetCommitRunTargetIdentity = "home"
            , targetCommitRunGeneration = generationOne
            , targetCommitRunSinkCasAttempted = True
            }
      recorded <- readIORef events
      length (filter (== "sink-cas") recorded) `shouldBe` 1
      length (filter (== "global-cas") recorded) `shouldBe` 3
      writeIORef events []
      second <-
        runPreparedTargetCommit
          interpreter
          registered
          intentCoordinate
          sinkA
          generationOne
          digestA
          (at 1600)
          secretFields
      second `shouldBe` Right (TargetCommitRunAlreadyCommitted "home" generationOne)
      secondEvents <- readIORef events
      filter (== "sink-cas") secondEvents `shouldBe` []
      filter (== "sink-observe") secondEvents `shouldBe` []
      filter (== "global-cas") secondEvents `shouldBe` []

    it "fails closed when authority time is unobservable before mutation" $ do
      events <- newIORef []
      global <- newIORef ModelBMissing
      sinkState <- newIORef TargetSinkMissing
      globalVersion <- newIORef (1 :: Natural)
      let base = fakeTargetCommitInterpreter events global sinkState globalVersion
          interpreter =
            base
              { targetCommitCurrentAuthorityTime = pure (Left "authority clock timeout")
              }
      result <-
        runPreparedTargetCommit
          interpreter
          registered
          intentCoordinate
          sinkA
          generationOne
          digestA
          (at 1600)
          secretFields
      result
        `shouldBe` Left
          (TargetCommitAuthorityClockUnavailable "authority clock timeout")
      recorded <- readIORef events
      filter (== "global-cas") recorded `shouldBe` []
      filter (== "sink-cas") recorded `shouldBe` []

    it "effectfully resolves every cross-sink intent from stable post-grace readback" $ do
      let (projectionA, intentA) = firstPrepared sinkA
          (projectionBoth, _) = appendPrepared sinkB projectionA
          writePermitA =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intentA
                  (observedGlobal "intent-v2" projectionBoth)
              )
          recordA = case decideTargetSinkWrite payloadDigest writePermitA secretPayload TargetSinkMissing of
            TargetSinkWriteCompareAndSwap (TargetSinkInitialize _ record) -> record
            other -> error ("expected target record fixture, got " ++ show other)
      events <- newIORef []
      global <- newIORef (observedGlobal "recovery-v1" projectionBoth)
      now <- newIORef (at 2000)
      globalVersion <- newIORef (2 :: Natural)
      let recovery =
            fakeTargetRecoveryInterpreter
              events
              global
              now
              globalVersion
              recordA
      result <-
        runSuccessorTargetRecovery
          recovery
          registered
          intentCoordinate
          policy
          ownerGrant
      result `shouldBe` Right (TargetRecoveryRunResolved ["aws", "home"])
      recorded <- readIORef events
      length (filter (== "sink-observe") recorded) `shouldBe` 4
      length (filter (== "sink-cas") recorded) `shouldBe` 0
      length (filter (== "global-cas") recorded) `shouldBe` 3

    it "anchors target recovery at a voluntary-release boundary" $ do
      let (projection, intent) = firstPrepared sinkA
          writePermit =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intent
                  (observedGlobal "intent-v1" projection)
              )
          record = case decideTargetSinkWrite payloadDigest writePermit secretPayload TargetSinkMissing of
            TargetSinkWriteCompareAndSwap (TargetSinkInitialize _ value) -> value
            other -> error ("expected target record fixture, got " ++ show other)
      events <- newIORef []
      global <- newIORef (observedGlobal "release-v1" projection)
      now <- newIORef (at 1200)
      globalVersion <- newIORef (2 :: Natural)
      let recovery =
            fakeTargetRecoveryInterpreter
              events
              global
              now
              globalVersion
              record
      result <-
        runSuccessorTargetRecoveryAfter
          recovery
          registered
          intentCoordinate
          policy
          (at 1650)
      result `shouldBe` Right (TargetRecoveryRunResolved ["home"])
      readIORef now `shouldReturn` at 1750
      recorded <- readIORef events
      length (filter (== "sink-observe") recorded) `shouldBe` 2
      length (filter (== "wait-until") recorded) `shouldBe` 1

    it "treats a missing global target-intent ledger as already resolved" $ do
      let (projection, intent) = firstPrepared sinkA
          writePermit =
            expectRight
              ( prepareTargetWrite
                  registered
                  (at 1250)
                  ownerPermit
                  sinkA
                  intent
                  (observedGlobal "intent-v1" projection)
              )
          record = case decideTargetSinkWrite payloadDigest writePermit secretPayload TargetSinkMissing of
            TargetSinkWriteCompareAndSwap (TargetSinkInitialize _ value) -> value
            other -> error ("expected target record fixture, got " ++ show other)
      events <- newIORef []
      global <- newIORef ModelBMissing
      now <- newIORef (at 1200)
      globalVersion <- newIORef (1 :: Natural)
      let recovery =
            fakeTargetRecoveryInterpreter
              events
              global
              now
              globalVersion
              record
      result <-
        runSuccessorTargetRecoveryAfter
          recovery
          registered
          intentCoordinate
          policy
          (at 1650)
      result `shouldBe` Right TargetRecoveryRunAlreadyResolved
      recorded <- readIORef events
      filter (`elem` ["global-cas", "sink-observe", "sink-cas", "wait-until", "wait-for"]) recorded
        `shouldBe` []

    it "pins the allowlisted target route and redacted Vault record round-trip" $ do
      let wireRecord =
            TargetSecret.TargetSecretRecord
              { TargetSecret.targetSecretRecordOwnerNonce = "owner-a"
              , TargetSecret.targetSecretRecordFencingToken = 1
              , TargetSecret.targetSecretRecordGeneration = 1
              , TargetSecret.targetSecretRecordDigest = targetValueDigestText digestA
              , TargetSecret.targetSecretRecordFields = secretFields
              }
          coordinate =
            TargetSecret.TargetSecretCoordinate
              { TargetSecret.targetSecretCoordinateIdentity = "home"
              , TargetSecret.targetSecretCoordinateVaultMount = "secret"
              , TargetSecret.targetSecretCoordinateKvPath = "keycloak/smtp"
              }
          readRequest = TargetSecret.TargetSecretReadRequest coordinate True
          casRequest = TargetSecret.TargetSecretCasRequest coordinate 0 wireRecord True
      ( TargetSecret.targetSecretRecordToVaultFields wireRecord
          >>= TargetSecret.targetSecretRecordFromVaultFields
        )
        `shouldBe` Right wireRecord
      show wireRecord `shouldNotContain` "smtp-secret"
      eitherDecode (encode readRequest) `shouldBe` Right readRequest
      eitherDecode (encode casRequest) `shouldBe` Right casRequest
      decodeTargetSecretReadRequest (rawPost TargetSecret.targetSecretReadPath (encode readRequest))
        `shouldBe` Right readRequest
      decodeTargetSecretCasRequest (rawPost TargetSecret.targetSecretCasPath (encode casRequest))
        `shouldBe` Right casRequest
      TargetSecret.validateTargetSecretReadRequest
        readRequest
          { TargetSecret.targetSecretReadCoordinate =
              coordinate {TargetSecret.targetSecretCoordinateKvPath = "other/path"}
          }
        `shouldBe` Left (TargetSecret.TargetSecretCoordinateNotAllowed "secret" "other/path")
      TargetSecret.validateTargetSecretIdentity
        "home"
        coordinate {TargetSecret.targetSecretCoordinateIdentity = "aws"}
        `shouldBe` Left (TargetSecret.TargetSecretIdentityMismatch "home" "aws")

  describe "Sprint 4.47 SMTP committed-key repair" $ do
    it "reuses the sole recoverable committed key without creation" $ do
      planSmtpKeyRepair
        keyBound
        (SmtpKeyInventoryObserved [committedKey])
        (Just recoverableCommitted)
        `shouldBe` SmtpReuseCommitted recoverableCommitted

    it "deletes only uncommitted keys, stably reobserves, then reuses" $ do
      let plan =
            planSmtpKeyRepair
              keyBound
              (SmtpKeyInventoryObserved [committedKey, orphanKey])
              (Just recoverableCommitted)
      continuation <- case plan of
        SmtpDeleteKeys [keyId] next -> do
          keyId `shouldBe` orphanKey
          confirmSmtpKeyCleanup plan [SmtpKeyDeleted orphanKey]
            `shouldBe` Right (SmtpAwaitStableInventory next)
          pure next
        other -> unexpected ("expected orphan cleanup, got " ++ show other)
      let witness =
            expectRight
              ( proveStableSmtpInventory
                  policy
                  (at 1000)
                  keyBound
                  [committedKey]
                  [smtpSample 1000 [committedKey], smtpSample 1100 [committedKey]]
              )
      confirmSmtpReuseAfterCleanup continuation witness
        `shouldBe` Right recoverableCommitted

    it "deletes unrecoverable and uncommitted keys before one fenced creation" $ do
      let plan =
            planSmtpKeyRepair
              keyBound
              (SmtpKeyInventoryObserved [committedKey, orphanKey])
              (Just unrecoverableCommitted)
      continuation <- case plan of
        SmtpDeleteKeys keyIds next -> do
          keyIds `shouldBe` [committedKey, orphanKey]
          confirmSmtpKeyCleanup
            plan
            [SmtpKeyDeleted committedKey, SmtpKeyDeleted orphanKey]
            `shouldBe` Right (SmtpAwaitStableInventory next)
          pure next
        other -> unexpected ("expected full key cleanup, got " ++ show other)
      let emptyWitness =
            expectRight
              ( proveStableSmtpInventory
                  policy
                  (at 1000)
                  keyBound
                  []
                  [smtpSample 1000 [], smtpSample 1100 []]
              )
          createAction =
            expectRight
              ( authorizeSmtpKeyCreation
                  ownerPermit
                  generationTwo
                  continuation
                  emptyWitness
              )
          candidate =
            acceptCreatedSmtpCredential
              payloadDigest
              createAction
              replacementKey
              secretPayload
      smtpCommitCandidateKeyId candidate `shouldBe` replacementKey
      smtpCommitCandidateGeneration candidate `shouldBe` generationTwo
      smtpCommitCandidateDigest candidate `shouldBe` digestA
      smtpCommitCandidateMaterial candidate `shouldBe` secretPayload

    it "propagates cleanup failure and never lowers unsafe inventories to create" $ do
      let plan =
            planSmtpKeyRepair
              keyBound
              (SmtpKeyInventoryObserved [orphanKey])
              (Nothing :: Maybe (CommittedSmtpCredential ByteString))
      confirmSmtpKeyCleanup plan [SmtpKeyDeleteFailed orphanKey "access denied"]
        `shouldBe` Left (SmtpCleanupFailed orphanKey "access denied")
      planSmtpKeyRepair keyBound (SmtpKeyInventoryUnobservable "timeout") Nothing
        `shouldBe` (SmtpKeyRepairRefused (SmtpInventoryUnobservable "timeout") :: SmtpKeyRepairPlan ByteString)
      planSmtpKeyRepair
        keyBound
        (SmtpKeyInventoryObserved [committedKey, orphanKey, replacementKey])
        Nothing
        `shouldBe` (SmtpKeyRepairRefused (SmtpInventoryOverBound 3 2) :: SmtpKeyRepairPlan ByteString)
      proveStableSmtpInventory
        policy
        (at 1000)
        keyBound
        []
        [smtpSample 1000 [], smtpSample 1100 [orphanKey]]
        `shouldBe` Left SmtpStableInventoryChanged

    it "does not authorize creation from a stable nonempty witness" $ do
      let nonempty =
            expectRight
              ( proveStableSmtpInventory
                  policy
                  (at 1000)
                  keyBound
                  [orphanKey]
                  [smtpSample 1000 [orphanKey], smtpSample 1100 [orphanKey]]
              )
      authorizeSmtpKeyCreation
        ownerPermit
        generationTwo
        SmtpCreateAfterStableAbsence
        nonempty
        `shouldBe` Left (SmtpCreationRequiresStableEmptyInventory [orphanKey])

    it "round-trips the recoverable SMTP projection through canonical bounded CBOR" $ do
      let encoded = expectRight (encodeSmtpCommittedProjection recoverableCommitted)
      decodeSmtpCommittedProjection encoded `shouldBe` Right recoverableCommitted
      encodeSmtpCommittedProjection
        (mkCommittedSmtpCredential committedKey generationOne digestA (Just (BS.replicate 20000 1)))
        `shouldBe` Left (SmtpCommittedProjectionCodecMaterialTooLarge 20000 16384)

rawPolicy :: RawLeasePolicy
rawPolicy =
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

policy :: LeasePolicy
policy = expectRight (mkLeasePolicy rawPolicy)

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "https://gateway.example.test"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
    )

leaseKey :: LeaseKey
leaseKey = expectRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

intentCoordinate :: TargetIntentCoordinate
intentCoordinate = expectRight (mkTargetIntentCoordinate authority leaseKey)

sinkA :: TargetClusterSecretSink
sinkA = sink "home" "https://gateway.home.example.test"

sinkB :: TargetClusterSecretSink
sinkB = sink "aws" "https://gateway.aws.example.test"

unregisteredSink :: TargetClusterSecretSink
unregisteredSink = sink "unregistered" "https://gateway.other.example.test"

sink :: Text -> Text -> TargetClusterSecretSink
sink identity endpoint =
  expectRight (mkTargetClusterSecretSink identity endpoint "secret" "keycloak/smtp")

registered :: RegisteredTargetSet
registered = expectRight (mkRegisteredTargetSet 2 [sinkA, sinkB])

registeredAOnly :: RegisteredTargetSet
registeredAOnly = expectRight (mkRegisteredTargetSet 1 [sinkA])

ownerA :: OwnerNonce
ownerA = expectRight (mkOwnerNonce "owner-a")

ownerB :: OwnerNonce
ownerB = expectRight (mkOwnerNonce "owner-b")

ownerGrant :: LeaseGrant
ownerGrant = grant 1 ownerA 1000

successorGrant :: LeaseGrant
successorGrant = grant 2 ownerB 3000

grant :: Natural -> OwnerNonce -> Natural -> LeaseGrant
grant fenceValue owner issuedAt =
  expectRight
    ( mkLeaseGrant
        policy
        leaseKey
        owner
        (expectRight (mkFencingToken fenceValue))
        (at issuedAt)
        (at (issuedAt + 1000))
        (at (issuedAt + 750))
    )

ownerPermit :: FencedCommitPermit
ownerPermit = permitFor ownerGrant 1200 "lease-v1"

successorPermit :: FencedCommitPermit
successorPermit = permitFor successorGrant 3100 "lease-v2"

expectedOwnerGuard :: ModelBLeaseGuard
expectedOwnerGuard =
  ModelBLeaseGuard
    { modelBLeaseGuardCoordinate = targetIntentCoordinateLeaseObject intentCoordinate
    , modelBLeaseGuardExpectedVersion = expectRight (mkModelBObjectVersion "lease-v1")
    , modelBLeaseGuardOwnerNonceText = "owner-a"
    , modelBLeaseGuardFencingTokenValue = 1
    }

expectedSuccessorGuard :: ModelBLeaseGuard
expectedSuccessorGuard =
  ModelBLeaseGuard
    { modelBLeaseGuardCoordinate = targetIntentCoordinateLeaseObject intentCoordinate
    , modelBLeaseGuardExpectedVersion = expectRight (mkModelBObjectVersion "lease-v2")
    , modelBLeaseGuardOwnerNonceText = "owner-b"
    , modelBLeaseGuardFencingTokenValue = 2
    }

assertOwnerGuard :: ModelBLeaseGuard -> Expectation
assertOwnerGuard guard = guard `shouldBe` expectedOwnerGuard

assertSuccessorGuard :: ModelBLeaseGuard -> Expectation
assertSuccessorGuard guard = guard `shouldBe` expectedSuccessorGuard

permitFor :: LeaseGrant -> Natural -> Text -> FencedCommitPermit
permitFor leaseGrant now version =
  let leaseProjection =
        expectRight (mkLeaseProjection (leaseGrantFencingToken leaseGrant) (Just leaseGrant))
   in case decideFencedCommit (at now) leaseGrant (observedGlobal version leaseProjection) of
        LeaseCommitAuthorized permit -> permit
        other -> error ("expected fenced permit, got " ++ show other)

generationOne :: CredentialGeneration
generationOne = expectRight (mkCredentialGeneration 1)

generationTwo :: CredentialGeneration
generationTwo = expectRight (mkCredentialGeneration 2)

digestA :: TargetValueDigest
digestA = expectRight (mkTargetValueDigest (Text.replicate 64 "a"))

secretPayload :: ByteString
secretPayload = "smtp-secret"

payloadDigest :: ByteString -> TargetValueDigest
payloadDigest _ = digestA

sinkVersion :: TargetSinkVersion
sinkVersion = expectRight (mkTargetSinkVersion "sink-v1")

firstPrepared :: TargetClusterSecretSink -> (TargetIntentProjection, TargetCommitIntent)
firstPrepared target =
  case decidePrepareTargetCommit
    registered
    intentCoordinate
    (at 1200)
    (at 1600)
    ownerPermit
    target
    generationOne
    digestA
    ModelBMissing of
    TargetCommitPrepareCompareAndSwap (ModelBInitializeGuarded _ guard projection) intent
      | guard == expectedOwnerGuard -> (projection, intent)
    other -> error ("expected first prepare, got " ++ show other)

appendPrepared
  :: TargetClusterSecretSink
  -> TargetIntentProjection
  -> (TargetIntentProjection, TargetCommitIntent)
appendPrepared target projection =
  case decidePrepareTargetCommit
    registered
    intentCoordinate
    (at 1201)
    (at 1600)
    ownerPermit
    target
    generationOne
    digestA
    (observedGlobal "intent-v1" projection) of
    TargetCommitPrepareCompareAndSwap (ModelBReplaceGuarded _ _ guard next) intent
      | guard == expectedOwnerGuard -> (next, intent)
    other -> error ("expected appended prepare, got " ++ show other)

observedGlobal :: Text -> value -> ModelBObservation value
observedGlobal version value =
  ModelBObserved (expectRight (mkModelBObjectVersion version)) value

at :: Natural -> AuthorityTime
at = authorityTimeFromMicros

targetSample
  :: Natural
  -> TargetSinkObservation payload
  -> TimedTargetSinkObservation payload
targetSample observedAt observation =
  TimedTargetSinkObservation (at observedAt) observation

smtpSample :: Natural -> [SmtpAccessKeyId] -> TimedSmtpKeyInventoryObservation
smtpSample observedAt keyIds =
  TimedSmtpKeyInventoryObservation
    (at observedAt)
    (SmtpKeyInventoryObserved keyIds)

currentIntent
  :: TargetIntentProjection -> Text -> Maybe TargetCommitIntent
currentIntent projection identity = do
  entry <- findEntry projection identity
  targetProjectionEntryIntent entry

currentCommitted
  :: TargetIntentProjection
  -> Text
  -> Maybe (CredentialGeneration, TargetValueDigest)
currentCommitted projection identity = do
  entry <- findEntry projection identity
  committed <- targetProjectionEntryCommitted entry
  pure (committedTargetGeneration committed, committedTargetDigest committed)

findEntry :: TargetIntentProjection -> Text -> Maybe TargetProjectionEntry
findEntry projection identity =
  case filter ((== identity) . targetProjectionEntryTargetIdentity) (targetProjectionEntries projection) of
    [entry] -> Just entry
    _ -> Nothing

hasDisposition :: TargetCommitDisposition -> Maybe TargetCommitIntent -> Bool
hasDisposition disposition maybeIntent =
  case maybeIntent of
    Just intent -> targetCommitDisposition intent == disposition
    Nothing -> False

isRegistrationCodecRefusal
  :: Either TargetIntentProjectionCodecError TargetIntentProjection -> Bool
isRegistrationCodecRefusal result = case result of
  Left (TargetIntentProjectionCodecRegistrationMismatch _ _) -> True
  _ -> False

keyBound :: SmtpKeyInventoryBound
keyBound = expectRight (mkSmtpKeyInventoryBound 2)

committedKey :: SmtpAccessKeyId
committedKey = expectRight (mkSmtpAccessKeyId "AKIACOMMITTED0001")

orphanKey :: SmtpAccessKeyId
orphanKey = expectRight (mkSmtpAccessKeyId "AKIAORPHAN0000001")

replacementKey :: SmtpAccessKeyId
replacementKey = expectRight (mkSmtpAccessKeyId "AKIAREPLACEMENT01")

recoverableCommitted :: CommittedSmtpCredential ByteString
recoverableCommitted =
  mkCommittedSmtpCredential committedKey generationOne digestA (Just secretPayload)

unrecoverableCommitted :: CommittedSmtpCredential ByteString
unrecoverableCommitted =
  mkCommittedSmtpCredential committedKey generationOne digestA Nothing

secretFields :: Map Text Text
secretFields =
  Map.fromList
    [ ("host", "email-smtp.ca-central-1.amazonaws.com")
    , ("password", "smtp-secret")
    , ("username", "AKIACOMMITTED0001")
    ]

fakeTargetCommitInterpreter
  :: IORef [String]
  -> IORef (ModelBObservation TargetIntentProjection)
  -> IORef (TargetSinkObservation (Map Text Text))
  -> IORef Natural
  -> TargetCommitInterpreter IO (Map Text Text)
fakeTargetCommitInterpreter events global sinkState globalVersion =
  TargetCommitInterpreter
    { targetCommitGlobalAdapter =
        ModelBCasAdapter
          { modelBObserve = \_ -> do
              record "global-observe"
              readIORef global
          , modelBCompareAndSwap = \request -> do
              record "global-cas"
              versionNumber <- readIORef globalVersion
              let version = expectRight (mkModelBObjectVersion (Text.pack ("global-v" ++ show versionNumber)))
                  next = case request of
                    ModelBInitializeGuarded _ guard projection
                      | guard == expectedOwnerGuard -> Right projection
                    ModelBReplaceGuarded _ _ guard projection
                      | guard == expectedOwnerGuard -> Right projection
                    _ -> Left "missing or stale target-intent lease guard"
              case next of
                Left detail -> pure (ModelBCasUnobservable detail)
                Right projection -> do
                  writeIORef global (ModelBObserved version projection)
                  writeIORef globalVersion (versionNumber + 1)
                  pure (ModelBCasApplied version projection)
          }
    , targetCommitSinkAdapter =
        TargetSinkCasAdapter
          { targetSinkObserve = \_ -> do
              record "sink-observe"
              readIORef sinkState
          , targetSinkCompareAndSwap = \request -> do
              record "sink-cas"
              let (version, sinkRecord) = case request of
                    TargetSinkInitialize _ value -> (sinkVersion, value)
                    TargetSinkReplace _ expected value -> (expected, value)
                  observation = TargetSinkObserved version sinkRecord
              writeIORef sinkState observation
              pure (TargetSinkCasApplied version sinkRecord)
          }
    , targetCommitCurrentPermit = do
        record "permit"
        pure (Right ownerPermit)
    , targetCommitCurrentAuthorityTime = do
        record "time"
        pure (Right (at 1250))
    , targetCommitDigestPayload = const digestA
    }
 where
  record event = modifyIORef' events (++ [event])

fakeTargetRecoveryInterpreter
  :: IORef [String]
  -> IORef (ModelBObservation TargetIntentProjection)
  -> IORef AuthorityTime
  -> IORef Natural
  -> TargetSinkRecord ByteString
  -> TargetRecoveryInterpreter IO ByteString
fakeTargetRecoveryInterpreter events global now globalVersion homeRecord =
  TargetRecoveryInterpreter
    { targetRecoveryBaseInterpreter =
        TargetCommitInterpreter
          { targetCommitGlobalAdapter =
              ModelBCasAdapter
                { modelBObserve = \_ -> do
                    record "global-observe"
                    readIORef global
                , modelBCompareAndSwap = \request -> do
                    record "global-cas"
                    versionNumber <- readIORef globalVersion
                    let version =
                          expectRight
                            ( mkModelBObjectVersion
                                (Text.pack ("recovery-v" ++ show versionNumber))
                            )
                        next = case request of
                          ModelBReplaceGuarded _ _ guard projection
                            | guard == expectedSuccessorGuard -> Right projection
                          _ -> Left "missing or stale successor lease guard"
                    case next of
                      Left detail -> pure (ModelBCasUnobservable detail)
                      Right projection -> do
                        writeIORef global (ModelBObserved version projection)
                        writeIORef globalVersion (versionNumber + 1)
                        pure (ModelBCasApplied version projection)
                }
          , targetCommitSinkAdapter =
              TargetSinkCasAdapter
                { targetSinkObserve = \target -> do
                    record "sink-observe"
                    pure $ case targetSecretSinkIdentity target of
                      "home" -> TargetSinkObserved sinkVersion homeRecord
                      _ -> TargetSinkMissing
                , targetSinkCompareAndSwap = \_ -> do
                    record "sink-cas"
                    pure (TargetSinkCasRefused "recovery must not write a sink")
                }
          , targetCommitCurrentPermit = do
              record "permit"
              pure (Right successorPermit)
          , targetCommitCurrentAuthorityTime = do
              record "time"
              Right <$> readIORef now
          , targetCommitDigestPayload = payloadDigest
          }
    , targetRecoveryWaitUntil = \deadline -> do
        record "wait-until"
        writeIORef now deadline
        pure (Right ())
    , targetRecoveryWaitFor = \duration -> do
        record "wait-for"
        current <- readIORef now
        writeIORef
          now
          ( at
              ( authorityTimeMicros current
                  + authorityDurationMicros duration
              )
          )
        pure (Right ())
    }
 where
  record event = modifyIORef' events (++ [event])

rawPost :: String -> BL.ByteString -> ByteString
rawPost path body =
  BS.concat
    [ BS8.pack
        ( "POST "
            ++ path
            ++ " HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: "
            ++ show (BL.length body)
            ++ "\r\n\r\n"
        )
    , BL.toStrict body
    ]

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result = case result of
  Left err -> error ("unexpected Left: " ++ show err)
  Right value -> value

unexpected :: String -> IO value
unexpected detail = do
  expectationFailure detail
  error detail
