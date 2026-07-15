{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module SmtpKeyRepairInterpreter
  ( smtpKeyRepairInterpreterSuite
  )
where

import Control.Exception
  ( SomeException
  , displayException
  , throwIO
  , try
  )
import Data.ByteString (ByteString)
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
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
  , ModelBLeaseGuard
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencedCommitPermit
  , LeaseAcquireDecision (..)
  , LeaseAcquireRequest
  , LeaseCommitDecision (..)
  , LeaseGrant
  , LeaseKey
  , LeaseProjection
  , addAuthorityDuration
  , authorityTimeFromMicros
  , beginLeaseAcquire
  , decideFencedCommit
  , decideLeaseAcquire
  , defaultSesLeasePolicy
  , leaseObjectCoordinate
  , leasePolicySmtpCommitBudget
  , leaseProjectionActiveGrant
  , mkLeaseKey
  , mkOwnerNonce
  , modelBLeaseGuardFromPermit
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpAccessKeyId
  , SmtpCommittedProjection
  , SmtpKeyCleanupResult (..)
  , SmtpKeyInventoryObservation (..)
  , committedSmtpCredentialGeneration
  , committedSmtpCredentialKeyId
  , committedSmtpCredentialMaterial
  , mkCommittedSmtpCredential
  , mkSmtpAccessKeyId
  , mkSmtpKeyInventoryBound
  , smtpKeyCreateActionGeneration
  )
import Prodbox.Lifecycle.SmtpKeyRepairInterpreter
  ( SmtpKeyCommitFailure (..)
  , SmtpKeyRepairExecutionError (..)
  , SmtpKeyRepairInterpreter (..)
  , SmtpKeyRepairOutcome (..)
  , SmtpKeyRepairRequest (..)
  , runSmtpKeyRepairWith
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  )
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

smtpKeyRepairInterpreterSuite :: SuiteBuilder ()
smtpKeyRepairInterpreterSuite =
  describe "Sprint 4.47 SMTP IAM-key effect interpreter" $ do
    it
      "cleans unrecoverable/orphan keys, derives N+1, creates once, guarded-CAS commits, and reobserves"
      $ do
        stateRef <-
          newFakeState
            (observedProjection "smtp-v0" unrecoverableCommitted)
            [committedKey, orphanKey]
            FakeCasApply
        result <- runSmtpKeyRepairWith (fakeInterpreter stateRef) repairRequest
        case result of
          Right (SmtpKeyRepairCreated committed) -> do
            committedSmtpCredentialKeyId committed `shouldBe` replacementKey
            credentialGenerationValue (committedSmtpCredentialGeneration committed)
              `shouldBe` 8
            committedSmtpCredentialMaterial committed `shouldBe` Just replacementSecret
          other -> expectationFailure ("expected created SMTP credential, got " ++ show other)
        finalState <- readIORef stateRef
        fakeInventory finalState `shouldBe` [replacementKey]
        fakePermitRequests finalState `shouldBe` 1
        fakeCreateRequests finalState `shouldBe` 1
        fakeProjectionObservations finalState `shouldBe` 2
        fakeInventoryObservations finalState `shouldBe` 3
        fakeNow finalState
          `shouldSatisfy` ( <=
                              addAuthorityDuration
                                initialTime
                                (leasePolicySmtpCommitBudget defaultSesLeasePolicy)
                          )
        fakeEvents finalState `shouldContain` [FakeDelete committedKey]
        fakeEvents finalState `shouldContain` [FakeDelete orphanKey]
        fakeEvents finalState `shouldContain` [FakeGuardedReplace expectedLeaseGuard]

    it "deletes the newly-created uncommitted key when guarded CAS conflicts" $ do
      stateRef <- newFakeState ModelBMissing [] FakeCasConflict
      result <- runSmtpKeyRepairWith (fakeInterpreter stateRef) repairRequest
      result
        `shouldBe` Left
          (SmtpKeyRepairCommitFailed SmtpKeyCommitConflict)
      finalState <- readIORef stateRef
      fakeInventory finalState `shouldBe` []
      fakeCreateRequests finalState `shouldBe` 1
      fakeEvents finalState
        `shouldContain` [ FakeCreate replacementKey 1
                        , FakeGuardedInitialize expectedLeaseGuard
                        , FakeDelete replacementKey
                        ]

    it "propagates compensation failure after a commit conflict" $ do
      stateRef <-
        newFakeStateWith
          ModelBMissing
          []
          FakeCasConflict
          (Map.singleton replacementKey "compensation denied")
          Nothing
      result <- runSmtpKeyRepairWith (fakeInterpreter stateRef) repairRequest
      case result of
        Left
          ( SmtpKeyRepairCommitFailedAndCleanupRefused
              SmtpKeyCommitConflict
              (SmtpKeyDeleteFailed keyId detail)
              _
            ) -> do
            keyId `shouldBe` replacementKey
            detail `shouldBe` "compensation denied"
        other -> expectationFailure ("expected compensation refusal, got " ++ show other)
      finalState <- readIORef stateRef
      fakeInventory finalState `shouldBe` [replacementKey]

    it "attempts every planned cleanup and propagates every failure before waiting or creating" $ do
      let failures =
            Map.fromList
              [ (committedKey, "committed delete denied")
              , (orphanKey, "orphan delete denied")
              ]
      stateRef <-
        newFakeStateWith
          ModelBMissing
          [committedKey, orphanKey]
          FakeCasApply
          failures
          Nothing
      result <- runSmtpKeyRepairWith (fakeInterpreter stateRef) repairRequest
      case result of
        Left (SmtpKeyRepairCleanupRefused cleanupResults _) ->
          cleanupResults
            `shouldBe` [ SmtpKeyDeleteFailed committedKey "committed delete denied"
                       , SmtpKeyDeleteFailed orphanKey "orphan delete denied"
                       ]
        other -> expectationFailure ("expected cleanup refusal, got " ++ show other)
      finalState <- readIORef stateRef
      fakeDeleteRequests finalState `shouldBe` 2
      fakePermitRequests finalState `shouldBe` 0
      fakeCreateRequests finalState `shouldBe` 0
      fakeWaitRequests finalState `shouldBe` 0

    it "brackets a created key and deletes it when commit is interrupted" $ do
      stateRef <- newFakeState ModelBMissing [] FakeCasInterrupt
      interrupted <-
        try (runSmtpKeyRepairWith (fakeInterpreter stateRef) repairRequest)
          :: IO
               ( Either
                   SomeException
                   (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
               )
      case interrupted of
        Left err -> displayException err `shouldContain` "smtp commit interrupted"
        Right result -> expectationFailure ("expected interruption, got " ++ show result)
      finalState <- readIORef stateRef
      fakeInventory finalState `shouldBe` []
      fakeEvents finalState
        `shouldContain` [ FakeCreate replacementKey 1
                        , FakeGuardedInitialize expectedLeaseGuard
                        , FakeDelete replacementKey
                        ]

    it "fails closed on unobservable projection or IAM inventory without mutation" $ do
      projectionState <-
        newFakeState (ModelBUnobservable "checkpoint timeout") [] FakeCasApply
      projectionResult <-
        runSmtpKeyRepairWith (fakeInterpreter projectionState) repairRequest
      projectionResult
        `shouldBe` Left (SmtpKeyRepairProjectionUnobservable "checkpoint timeout")
      projectionFinal <- readIORef projectionState
      fakeInventoryObservations projectionFinal `shouldBe` 0
      fakeDeleteRequests projectionFinal `shouldBe` 0
      fakeCreateRequests projectionFinal `shouldBe` 0

      inventoryState <-
        newFakeStateWith
          ModelBMissing
          []
          FakeCasApply
          Map.empty
          (Just (SmtpKeyInventoryUnobservable "iam timeout"))
      inventoryResult <-
        runSmtpKeyRepairWith (fakeInterpreter inventoryState) repairRequest
      case inventoryResult of
        Left (SmtpKeyRepairPlanRefused _) -> pure ()
        other -> expectationFailure ("expected inventory refusal, got " ++ show other)
      inventoryFinal <- readIORef inventoryState
      fakeDeleteRequests inventoryFinal `shouldBe` 0
      fakePermitRequests inventoryFinal `shouldBe` 0
      fakeCreateRequests inventoryFinal `shouldBe` 0

    it "leaves SMTP access-key ownership to the Haskell repair interpreter" $ do
      repoRoot <- getCurrentDirectory
      program <- readFile (repoRoot </> "pulumi" </> "aws-ses" </> "Main.yaml")
      program `shouldContain` "  smtpUser:"
      program `shouldNotContain` "  smtpUserAccessKey:"
      program `shouldNotContain` "type: aws:iam:AccessKey"
      program `shouldNotContain` "smtp_iam_access_key_id:"
      program `shouldNotContain` "smtp_iam_secret_access_key:"

data FakeCasMode
  = FakeCasApply
  | FakeCasConflict
  | FakeCasInterrupt
  deriving (Eq, Show)

data FakeEvent
  = FakeObserveProjection
  | FakeObserveInventory ![SmtpAccessKeyId]
  | FakeWait !AuthorityTime
  | FakeDelete !SmtpAccessKeyId
  | FakeFreshPermit
  | FakeCreate !SmtpAccessKeyId !Natural
  | FakeGuardedInitialize !ModelBLeaseGuard
  | FakeGuardedReplace !ModelBLeaseGuard
  deriving (Eq, Show)

data FakeState = FakeState
  { fakeProjection :: !(ModelBObservation SmtpCommittedProjection)
  , fakeInventory :: ![SmtpAccessKeyId]
  , fakeInventoryOverride :: !(Maybe SmtpKeyInventoryObservation)
  , fakeDeleteFailures :: !(Map SmtpAccessKeyId Text)
  , fakeCasMode :: !FakeCasMode
  , fakeNow :: !AuthorityTime
  , fakeEvents :: ![FakeEvent]
  , fakeProjectionObservations :: !Int
  , fakeInventoryObservations :: !Int
  , fakeDeleteRequests :: !Int
  , fakeWaitRequests :: !Int
  , fakePermitRequests :: !Int
  , fakeCreateRequests :: !Int
  }

newFakeState
  :: ModelBObservation SmtpCommittedProjection
  -> [SmtpAccessKeyId]
  -> FakeCasMode
  -> IO (IORef FakeState)
newFakeState projection inventory casMode =
  newFakeStateWith projection inventory casMode Map.empty Nothing

newFakeStateWith
  :: ModelBObservation SmtpCommittedProjection
  -> [SmtpAccessKeyId]
  -> FakeCasMode
  -> Map SmtpAccessKeyId Text
  -> Maybe SmtpKeyInventoryObservation
  -> IO (IORef FakeState)
newFakeStateWith projection inventory casMode deleteFailures inventoryOverride =
  newIORef
    FakeState
      { fakeProjection = projection
      , fakeInventory = inventory
      , fakeInventoryOverride = inventoryOverride
      , fakeDeleteFailures = deleteFailures
      , fakeCasMode = casMode
      , fakeNow = initialTime
      , fakeEvents = []
      , fakeProjectionObservations = 0
      , fakeInventoryObservations = 0
      , fakeDeleteRequests = 0
      , fakeWaitRequests = 0
      , fakePermitRequests = 0
      , fakeCreateRequests = 0
      }

fakeInterpreter :: IORef FakeState -> SmtpKeyRepairInterpreter IO
fakeInterpreter stateRef =
  SmtpKeyRepairInterpreter
    { smtpKeyRepairModelB = fakeModelB stateRef
    , smtpKeyRepairAuthorityNow = Right . fakeNow <$> readIORef stateRef
    , smtpKeyRepairWaitUntil = \deadline -> do
        modifyIORef' stateRef $ \state ->
          state
            { fakeNow = max deadline (fakeNow state)
            , fakeEvents = fakeEvents state ++ [FakeWait deadline]
            , fakeWaitRequests = fakeWaitRequests state + 1
            }
        pure (Right ())
    , smtpKeyRepairObserveInventory = do
        state <- readIORef stateRef
        let observation = case fakeInventoryOverride state of
              Just override -> override
              Nothing -> SmtpKeyInventoryObserved (fakeInventory state)
        modifyIORef' stateRef $ \current ->
          current
            { fakeEvents =
                fakeEvents current
                  ++ [FakeObserveInventory (fakeInventory current)]
            , fakeInventoryObservations = fakeInventoryObservations current + 1
            }
        pure observation
    , smtpKeyRepairDeleteKey = \keyId -> do
        state <- readIORef stateRef
        let maybeFailure = Map.lookup keyId (fakeDeleteFailures state)
            result = case maybeFailure of
              Just detail -> SmtpKeyDeleteFailed keyId detail
              Nothing -> SmtpKeyDeleted keyId
        modifyIORef' stateRef $ \current ->
          current
            { fakeInventory = case maybeFailure of
                Just _ -> fakeInventory current
                Nothing -> filter (/= keyId) (fakeInventory current)
            , fakeEvents = fakeEvents current ++ [FakeDelete keyId]
            , fakeDeleteRequests = fakeDeleteRequests current + 1
            }
        pure result
    , smtpKeyRepairFreshFencedPermit = do
        modifyIORef' stateRef $ \state ->
          state
            { fakeEvents = fakeEvents state ++ [FakeFreshPermit]
            , fakePermitRequests = fakePermitRequests state + 1
            }
        pure (Right fencedPermit)
    , smtpKeyRepairCreateKey = \action -> do
        let generation =
              credentialGenerationValue (smtpKeyCreateActionGeneration action)
        modifyIORef' stateRef $ \state ->
          state
            { fakeInventory = [replacementKey]
            , fakeEvents = fakeEvents state ++ [FakeCreate replacementKey generation]
            , fakeCreateRequests = fakeCreateRequests state + 1
            }
        pure (Right (replacementKey, replacementSecret))
    , smtpKeyRepairDigestMaterial = const digest
    }

fakeModelB
  :: IORef FakeState
  -> ModelBCasAdapter 'ClusterRetained IO SmtpCommittedProjection
fakeModelB stateRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> do
        state <- readIORef stateRef
        modifyIORef' stateRef $ \current ->
          current
            { fakeEvents = fakeEvents current ++ [FakeObserveProjection]
            , fakeProjectionObservations = fakeProjectionObservations current + 1
            }
        pure (fakeProjection state)
    , modelBCompareAndSwap = \request -> do
        (event, committed) <- case request of
          ModelBInitializeGuarded coordinate guard value -> do
            coordinate `shouldBe` smtpProjectionCoordinate
            pure (FakeGuardedInitialize guard, value)
          ModelBReplaceGuarded coordinate expectedVersion guard value -> do
            coordinate `shouldBe` smtpProjectionCoordinate
            expectedVersion `shouldBe` modelBVersion "smtp-v0"
            pure (FakeGuardedReplace guard, value)
          _ -> error "SMTP interpreter emitted unguarded CAS"
        modifyIORef' stateRef $ \state ->
          state {fakeEvents = fakeEvents state ++ [event]}
        state <- readIORef stateRef
        case fakeCasMode state of
          FakeCasApply -> do
            let version = modelBVersion "smtp-v1"
            modifyIORef' stateRef $ \current ->
              current
                { fakeProjection = ModelBObserved version committed
                }
            pure (ModelBCasApplied version committed)
          FakeCasConflict ->
            pure (ModelBCasConflict (fakeProjection state))
          FakeCasInterrupt ->
            throwIO (userError "smtp commit interrupted")
    }

repairRequest :: SmtpKeyRepairRequest
repairRequest =
  SmtpKeyRepairRequest
    { smtpKeyRepairProjectionCoordinate = smtpProjectionCoordinate
    , smtpKeyRepairLeaseCoordinate = leaseCoordinate
    , smtpKeyRepairInventoryBound = expectRight (mkSmtpKeyInventoryBound 2)
    , smtpKeyRepairLeasePolicy = defaultSesLeasePolicy
    }

authority :: LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "http://127.0.0.1:30120"
        "prodbox-state"
        "retained"
        "transit/prodbox"
    )

leaseKey :: LeaseKey
leaseKey = expectRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

leaseCoordinate :: ModelBObjectCoordinate 'ClusterRetained
leaseCoordinate = expectRight (leaseObjectCoordinate authority leaseKey)

smtpProjectionCoordinate :: ModelBObjectCoordinate 'ClusterRetained
smtpProjectionCoordinate =
  expectRight
    ( mkClusterRetainedCoordinate
        authority
        "smtp-commit/123456789012/ca-central-1/aws-ses"
    )

fencedPermit :: FencedCommitPermit
fencedPermit =
  case decideFencedCommit permitTime leaseGrant leaseObservation of
    LeaseCommitAuthorized permit -> permit
    other -> error ("expected fresh fenced permit, got " ++ show other)

expectedLeaseGuard :: ModelBLeaseGuard
expectedLeaseGuard = modelBLeaseGuardFromPermit leaseCoordinate fencedPermit

leaseGrant :: LeaseGrant
leaseGrant = case leaseProjectionActiveGrant leaseProjection of
  Just grant -> grant
  Nothing -> error "default lease acquisition did not create an active grant"

leaseProjection :: LeaseProjection
leaseProjection =
  case decideLeaseAcquire
    defaultSesLeasePolicy
    initialTime
    leaseAcquireRequest
    Nothing
    (ModelBMissing :: ModelBObservation LeaseProjection) of
    LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) -> projection
    other -> error ("expected initial lease projection, got " ++ show other)

leaseAcquireRequest :: LeaseAcquireRequest
leaseAcquireRequest =
  expectRight
    ( beginLeaseAcquire
        defaultSesLeasePolicy
        authority
        leaseKey
        (expectRight (mkOwnerNonce "smtp-owner"))
        initialTime
    )

leaseObservation :: ModelBObservation LeaseProjection
leaseObservation = ModelBObserved (modelBVersion "lease-v1") leaseProjection

initialTime :: AuthorityTime
initialTime = authorityTimeFromMicros 0

permitTime :: AuthorityTime
permitTime =
  addAuthorityDuration
    initialTime
    (leasePolicySmtpCommitBudget defaultSesLeasePolicy)

generationSeven :: CredentialGeneration
generationSeven = expectRight (mkCredentialGeneration 7)

digest :: TargetValueDigest
digest = expectRight (mkTargetValueDigest (Text.replicate 64 "a"))

unrecoverableCommitted :: SmtpCommittedProjection
unrecoverableCommitted =
  mkCommittedSmtpCredential
    committedKey
    generationSeven
    digest
    Nothing

committedKey :: SmtpAccessKeyId
committedKey = expectRight (mkSmtpAccessKeyId "AKIACOMMITTED0001")

orphanKey :: SmtpAccessKeyId
orphanKey = expectRight (mkSmtpAccessKeyId "AKIAORPHAN0000001")

replacementKey :: SmtpAccessKeyId
replacementKey = expectRight (mkSmtpAccessKeyId "AKIAREPLACEMENT01")

replacementSecret :: ByteString
replacementSecret = "recoverable-smtp-secret"

observedProjection
  :: Text
  -> SmtpCommittedProjection
  -> ModelBObservation SmtpCommittedProjection
observedProjection version = ModelBObserved (modelBVersion version)

modelBVersion :: Text -> ModelBObjectVersion
modelBVersion = expectRight . mkModelBObjectVersion

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result = case result of
  Left err -> error ("unexpected Left: " ++ show err)
  Right value -> value
