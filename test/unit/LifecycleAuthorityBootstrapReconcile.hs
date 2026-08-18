{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityBootstrapReconcile
  ( lifecycleAuthorityBootstrapReconcileSuite
  )
where

import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommand (..)
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (..)
  , stepBackupRepair
  )
import Prodbox.Lifecycle.Authority.BootstrapReconcile
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , BackupRepairPermit (..)
  , GenesisPlan (..)
  , GenesisProgress (..)
  , TargetAgentGenerationReceipt (..)
  , authorityEpochGenesis
  , stepGenesis
  )
import TestSupport

data Trace
  = TraceObserve
  | TraceSubmit !AuthorityAdmissionCommand
  | TraceCompileGenesis
  | TraceGenesisTarget
  | TraceGenesisCopy
  | TraceHealth
  | TraceMintRepair
  | TraceRepairTarget
  | TraceRepairCopy
  deriving (Eq, Show)

data Fixture = Fixture
  { fixtureBoundary :: !(AuthorityBackupReconcileBoundary IO)
  , fixtureState :: !(IORef AuthorityAdmissionState)
  , fixtureTrace :: !(IORef [Trace])
  , fixtureLoseControlResponses :: !(IORef Bool)
  }

lifecycleAuthorityBootstrapReconcileSuite :: SuiteBuilder ()
lifecycleAuthorityBootstrapReconcileSuite =
  describe "Sprint 4.50 Authority backup bootstrap reconciliation" $ do
    it "orders frozen genesis through target, backup read-back, disablement, and admission" $ do
      fixture <- newFixture GenesisFrozen [BackupHealthy]
      result <- reconcileAuthorityBackupAdmission (fixtureBoundary fixture)
      result `shouldBe` Right (AuthorityBackupAdmissionReady authorityEpochGenesis)
      readIORef (fixtureTrace fixture)
        `shouldReturn` [ TraceObserve
                       , TraceCompileGenesis
                       , TraceSubmit
                           ( ApplyAuthorityGenesis
                               (BeginGenesisEstablishment genesisPlan)
                           )
                       , TraceObserve
                       , TraceGenesisTarget
                       , TraceSubmit
                           (ApplyAuthorityGenesis (ObserveTargetAgentGeneration targetReceipt))
                       , TraceObserve
                       , TraceGenesisCopy
                       , TraceSubmit
                           (ApplyAuthorityGenesis (ObserveBackupReceipt backupReceipt))
                       , TraceObserve
                       , TraceHealth
                       ]

    it "resumes the exact retained genesis plan without reminting an existing target generation" $ do
      fixture <-
        newFixture
          ( EstablishingBackup
              GenesisProgress
                { genesisProgressPlan = genesisPlan
                , genesisProgressTargetAgentReceipt = Just targetReceipt
                , genesisProgressBackupReceipt = Nothing
                }
          )
          [BackupHealthy]
      reconcileAuthorityBackupAdmission (fixtureBoundary fixture)
        `shouldReturn` Right (AuthorityBackupAdmissionReady authorityEpochGenesis)
      trace <- readIORef (fixtureTrace fixture)
      trace `shouldNotContain` [TraceCompileGenesis]
      trace `shouldNotContain` [TraceGenesisTarget]
      trace `shouldContain` [TraceGenesisCopy]

    it "converges from applied control writes whose responses are lost" $ do
      fixture <- newFixture GenesisFrozen [BackupHealthy]
      writeIORef (fixtureLoseControlResponses fixture) True
      reconcileAuthorityBackupAdmission (fixtureBoundary fixture)
        `shouldReturn` Right (AuthorityBackupAdmissionReady authorityEpochGenesis)

    it "freezes and returns without repair effects for temporary or unobservable backup health" $ do
      mapM_
        ( \health -> do
            fixture <- newFixture openedState [health]
            reconcileAuthorityBackupAdmission (fixtureBoundary fixture)
              `shouldReturn` Right
                (AuthorityBackupAdmissionFrozen authorityEpochGenesis health)
            trace <- readIORef (fixtureTrace fixture)
            trace `shouldNotContain` [TraceMintRepair]
            trace `shouldNotContain` [TraceRepairTarget]
            trace `shouldNotContain` [TraceRepairCopy]
        )
        [BackupTemporarilyUnavailable, BackupUnobservable]

    it "uses the signed repair lane for positive loss and reopens under a greater epoch" $ do
      fixture <-
        newFixture
          openedState
          [BackupPositivelyAbsent, BackupPositivelyAbsent, BackupHealthy]
      result <- reconcileAuthorityBackupAdmission (fixtureBoundary fixture)
      case result of
        Right (AuthorityBackupAdmissionReady epoch) ->
          epoch `shouldNotBe` authorityEpochGenesis
        other -> expectationFailure ("expected repaired open admission, got " ++ show other)
      trace <- readIORef (fixtureTrace fixture)
      trace `shouldContain` [TraceMintRepair]
      trace `shouldContain` [TraceRepairTarget]
      trace `shouldContain` [TraceRepairCopy]

    it "reopens a transient freeze only after a later healthy observation" $ do
      frozen <- newFixture openedState [BackupTemporarilyUnavailable]
      reconcileAuthorityBackupAdmission (fixtureBoundary frozen)
        `shouldReturn` Right
          ( AuthorityBackupAdmissionFrozen
              authorityEpochGenesis
              BackupTemporarilyUnavailable
          )
      retained <- readIORef (fixtureState frozen)
      resumed <- newFixture retained [BackupHealthy, BackupHealthy]
      result <- reconcileAuthorityBackupAdmission (fixtureBoundary resumed)
      case result of
        Right (AuthorityBackupAdmissionReady epoch) ->
          epoch `shouldNotBe` authorityEpochGenesis
        other -> expectationFailure ("expected recovered open admission, got " ++ show other)

newFixture :: AuthorityAdmissionState -> [BackupHealth] -> IO Fixture
newFixture initialState healthObservations = do
  stateRef <- newIORef initialState
  traceRef <- newIORef []
  healthRef <- newIORef healthObservations
  loseResponsesRef <- newIORef False
  let record event = modifyIORef' traceRef (++ [event])
      observe = record TraceObserve >> Right <$> readIORef stateRef
      submit command = do
        record (TraceSubmit command)
        modifyIORef' stateRef (`applyCommand` command)
        lose <- readIORef loseResponsesRef
        pure (if lose then Left "control response lost" else Right ())
      observeHealth _ = do
        record TraceHealth
        observations <- readIORef healthRef
        case observations of
          [] -> pure (Left "health fixture exhausted")
          health : remaining -> do
            writeIORef healthRef remaining
            pure (Right health)
      boundary =
        AuthorityBackupReconcileBoundary
          { observeAuthorityAdmissionState = observe
          , submitAuthorityAdmissionControl = submit
          , compileGenesisPlan = record TraceCompileGenesis >> pure (Right genesisPlan)
          , establishGenesisTargetGeneration =
              \_ -> record TraceGenesisTarget >> pure (Right targetReceipt)
          , copyGenesisAuthorityBackup =
              \_ -> record TraceGenesisCopy >> pure (Right backupReceipt)
          , observeAuthorityBackupHealth = observeHealth
          , mintAuthorityBackupRepairPermit =
              \_ _ _ -> record TraceMintRepair >> pure (Right repairPermit)
          , establishRepairTargetGeneration =
              \_ -> record TraceRepairTarget >> pure (Right repairTargetReceipt)
          , copyRepairedAuthorityBackup =
              \_ -> record TraceRepairCopy >> pure (Right repairBackupReceipt)
          }
  pure
    Fixture
      { fixtureBoundary = boundary
      , fixtureState = stateRef
      , fixtureTrace = traceRef
      , fixtureLoseControlResponses = loseResponsesRef
      }

applyCommand :: AuthorityAdmissionState -> AuthorityAdmissionCommand -> AuthorityAdmissionState
applyCommand state command = case command of
  ApplyAuthorityGenesis genesis -> snd (stepGenesis state genesis)
  ApplyAuthorityBackupRepair repair -> snd (stepBackupRepair state repair)
  BeginAuthorityMigration -> state
  ApplyAuthorityMigration _ -> state
  ApplyAuthorityMigrationImport _ -> state
  ApplyAuthorityForwardMigration _ -> state
  -- Sprint 4.85: the provider-admission commands change the aggregate's
  -- provider epoch, not this fixture's admission state.
  BindProviderAdmissionGeneration _ -> state
  FreezeProviderAdmissionForCascadeAudit _ -> state

openedState :: AuthorityAdmissionState
openedState =
  foldl
    applyGenesis
    GenesisFrozen
    [ BeginGenesisEstablishment genesisPlan
    , ObserveTargetAgentGeneration targetReceipt
    , ObserveBackupReceipt backupReceipt
    ]
 where
  applyGenesis state command = snd (stepGenesis state command)

genesisPlan :: GenesisPlan
genesisPlan = GenesisPlan "genesis-plan-digest" "authority-backup/home"

targetReceipt :: TargetAgentGenerationReceipt
targetReceipt = TargetAgentGenerationReceipt "target-generation-1"

backupReceipt :: BackupReceipt
backupReceipt = BackupReceipt "backup-version-1"

repairPermit :: BackupRepairPermit
repairPermit =
  BackupRepairPermit
    "repair-plan-digest"
    "authority-backup/home"
    authorityEpochGenesis
    targetReceipt
    backupReceipt

repairTargetReceipt :: TargetAgentGenerationReceipt
repairTargetReceipt = TargetAgentGenerationReceipt "target-generation-2"

repairBackupReceipt :: BackupReceipt
repairBackupReceipt = BackupReceipt "backup-version-2"
