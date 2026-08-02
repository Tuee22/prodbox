{-# LANGUAGE OverloadedStrings #-}

module SesWorkflow (sesWorkflowSuite) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Prodbox.Ses.Workflow.Coordinator
import Prodbox.Ses.Workflow.Interpreter
import Prodbox.Ses.Workflow.LegacyCheckpointGc
import Prodbox.Ses.Workflow.Model
import Prodbox.Ses.Workflow.Repository
import TestSupport

sesWorkflowSuite :: SuiteBuilder ()
sesWorkflowSuite =
  describe "Sprint 8.11 revisioned SES workflow" $ do
    it "each ownership state has at most one IAM writer" $ do
      activeSesWriters initial `shouldBe` Set.singleton "pulumi"
      activeSesWriters frozen `shouldBe` Set.empty
      activeSesWriters provisioner `shouldBe` Set.singleton "credential-provisioner"
    it "provider work is closed over non-credential inventory" $
      decideSesWorkflow initial ObserveProvider
        `shouldBe` EmitSesEffect (ProviderWork (ReconcileNonCredentialSesInventory contract))
    it "provider and semantic commits are revision bound" $ do
      decideSesWorkflow initial (CommitProviderRevision 6)
        `shouldBe` RefuseSesWorkflow (RevisionMismatch 7 6)
      decideSesWorkflow providerCommitted (CommitSemanticReady 7)
        `shouldBe` RecordSesEvent (SemanticRevisionCommitted 7)
    it "activation refuses until the legacy checkpoint is released" $
      decideSesWorkflow frozen (ActivateProvisioner 2 "prodbox-ses-smtp")
        `shouldBe` RefuseSesWorkflow LegacyCheckpointNotReleased
    it "activation refuses until migration custody and every target are read back" $ do
      decideSesWorkflow released (ActivateProvisioner 2 "prodbox-ses-smtp")
        `shouldBe` RefuseSesWorkflow MigrationCustodyNotPrepared
      decideSesWorkflow migrationCustody (ActivateProvisioner 2 "prodbox-ses-smtp")
        `shouldBe` RefuseSesWorkflow (MigrationTargetsNotConverged (Set.fromList ["home", "aws"]))
    it "old-writer restart cannot reactivate Pulumi" $
      decideSesWorkflow provisioner (BeginCredentialMigration 3 evidence)
        `shouldBe` RefuseSesWorkflow MigrationEvidenceConflict
    it "target delivery is generation and target bound" $ do
      decideSesWorkflow smtpCommitted (CommitTargetDelivery "unknown" targetReceipt)
        `shouldBe` RefuseSesWorkflow (UnknownSesTarget "unknown")
      decideSesWorkflow smtpCommitted (CommitTargetDelivery "aws" (TargetReceipt 8 "wrong"))
        `shouldBe` RefuseSesWorkflow TargetGenerationMismatch
    it "target deliveries are independent and resumable" $
      decideSesWorkflow smtpCommitted (CommitTargetDelivery "aws" targetReceipt)
        `shouldBe` EmitSesEffect (CustodyWork (DeliverSesSmtpGeneration "aws" 7 custodyReceipt))
    it "a newer generation cannot overtake an unresolved target" $
      decideSesWorkflow partiallyDelivered (CommitSmtpGeneration 8 (CustodyReceipt 8 "next"))
        `shouldBe` RefuseSesWorkflow (UnresolvedTargetDeliveries (Set.singleton "aws"))
    it "legacy secret GC requires the exact immutable version set" $ do
      decideSesWorkflow fullyDelivered (CommitLegacySecretGc (Set.singleton "primary:v1"))
        `shouldBe` RefuseSesWorkflow (LegacySecretGcIncomplete (Set.singleton "backup:v1"))
      decideSesWorkflow fullyDelivered (CommitLegacySecretGc legacyVersions)
        `shouldBe` EmitSesEffect (OperatorMaterialWork (GarbageCollectLegacySecretVersions legacyVersions))
    it "completion requires provider semantics, custody, all targets, and GC" $
      decideSesWorkflow converged CompleteSesWorkflow
        `shouldBe` RecordSesEvent SesWorkflowCompleted
    it "explicit destruction uses only the admin teardown family" $
      decideSesWorkflow converged RequestDestroyAwsSes
        `shouldBe` EmitSesEffect (AdminTeardownWork RunDestroyAwsSesDag)
    it "persists each committed event through exact-revision CAS" $ do
      cell <- newIORef (1 :: Int, initial)
      result <- applySesWorkflowEvent (memoryRepository cell) (ProviderRevisionCommitted 7)
      fmap workflowProviderCommitted result `shouldBe` Right (Just 7)
      readIORef cell `shouldReturn` (2, evolveSesWorkflow initial (ProviderRevisionCommitted 7))
    it "leaves state unchanged when repository CAS loses its fence" $ do
      cell <- newIORef (1 :: Int, initial)
      let repository = (memoryRepository cell) {compareAndSwapSesWorkflow = \_ _ -> pure (Left "conflict")}
      applySesWorkflowEvent repository (ProviderRevisionCommitted 7)
        `shouldReturn` Left "conflict"
      readIORef cell `shouldReturn` (1, initial)
    it "dispatches each effect only to its role-indexed interpreter" $ do
      calls <- newIORef ([] :: [String])
      let interpreters = recordingInterpreters calls
      runSesWorkflowEffect interpreters (ProviderWork (ObserveNonCredentialSesInventory contract))
        `shouldReturn` Right (SesWorkflowEventResult (ProviderRevisionCommitted 7))
      runSesWorkflowEffect interpreters (AdminTeardownWork RunDestroyAwsSesDag)
        `shouldReturn` Right (SesWorkflowDestroyResult "destroyed")
      readIORef calls `shouldReturn` ["provider", "admin"]
    it "recovers an applied-but-response-lost effect by authoritative re-observation" $ do
      applied <- newIORef False
      let provider =
            ProviderWorkflowInterpreter
              { observeProviderWorkflowEffect = \_ -> do
                  done <- readIORef applied
                  pure (Right (if done then Just (ProviderRevisionCommitted 7) else Nothing))
              , applyProviderWorkflowEffect = \_ -> do
                  writeIORef applied True
                  pure (Left "response lost")
              }
          interpreters = (recordingInterpreters (error "unused")) {sesProviderWorkflowInterpreter = provider}
      runSesWorkflowEffect interpreters (ProviderWork (ReconcileNonCredentialSesInventory contract))
        `shouldReturn` Right (SesWorkflowEventResult (ProviderRevisionCommitted 7))
    it "GC refuses rollback-window, dangling-reference, and unobservable-copy cases" $ do
      decideLegacyCheckpointGc gcInput {legacyGcRollbackWindowClosed = False}
        `shouldBe` Left LegacyRollbackWindowOpen
      decideLegacyCheckpointGc gcInput {legacyGcLiveReferences = Set.singleton primaryCopy}
        `shouldBe` Left (LegacyCheckpointStillReferenced (Set.singleton primaryCopy))
      decideLegacyCheckpointGc
        gcInput
          { legacyGcObservations =
              Map.insert backupCopy (LegacyBlobUnobservable "backup unavailable") presentCopies
          }
        `shouldBe` Left (LegacyCheckpointCopyUnobservable backupCopy "backup unavailable")
    it "GC deletes the exact primary/backup set then commits only full absence" $ do
      decideLegacyCheckpointGc gcInput
        `shouldBe` Right (DeleteLegacyCheckpointCopies legacyCopies)
      decideLegacyCheckpointGc gcInput {legacyGcObservations = absentCopies}
        `shouldBe` Right (CommitLegacyCheckpointGcReceipt legacyCopies)
      decideLegacyCheckpointGc
        gcInput {legacyGcObservations = Map.insert primaryCopy LegacyBlobAbsent presentCopies}
        `shouldBe` Left (LegacyCheckpointPartialDeletion (Set.singleton backupCopy))
    it "coordinates effect read-back before the fenced event commit" $ do
      cell <- newIORef (1 :: Int, initial)
      calls <- newIORef ([] :: [String])
      result <-
        runSesWorkflowCommand (memoryRepository cell) (recordingInterpreters calls) ObserveProvider
      result
        `shouldBe` Right
          ( SesWorkflowEffectCommitted
              (ProviderWork (ReconcileNonCredentialSesInventory contract))
              (ProviderRevisionCommitted 7)
          )
      (_revision, committed) <- readIORef cell
      workflowProviderCommitted committed `shouldBe` Just 7
 where
  contract = SesContract "contract-v7" 7 (Set.fromList ["home", "aws"])
  legacyVersions = Set.fromList ["primary:v1", "backup:v1"]
  evidence = LegacyEvidence "checkpoint" "principal" "policy" (Set.singleton "AKIAOLD") legacyVersions
  migrationReceipt = CustodyReceipt 6 "legacy-custody"
  migrationTargetReceipt = TargetReceipt 6 "legacy-target"
  custodyReceipt = CustodyReceipt 7 "custody"
  targetReceipt = TargetReceipt 7 "target"
  initial = initialSesWorkflow contract 1
  frozen = evolveSesWorkflow initial (CredentialMigrationStarted 2 evidence)
  released = evolveSesWorkflow frozen LegacyCredentialCheckpointReleased
  migrationCustody = evolveSesWorkflow released (SmtpGenerationCommitted 6 migrationReceipt)
  migrationTargets =
    evolveSesWorkflow
      (evolveSesWorkflow migrationCustody (TargetDeliveryCommitted "home" migrationTargetReceipt))
      (TargetDeliveryCommitted "aws" migrationTargetReceipt)
  provisioner = evolveSesWorkflow migrationTargets (ProvisionerActivated 2 "prodbox-ses-smtp")
  providerCommitted = evolveSesWorkflow provisioner (ProviderRevisionCommitted 7)
  smtpCommitted = evolveSesWorkflow provisioner (SmtpGenerationCommitted 7 custodyReceipt)
  partiallyDelivered = evolveSesWorkflow smtpCommitted (TargetDeliveryCommitted "home" targetReceipt)
  fullyDelivered = evolveSesWorkflow partiallyDelivered (TargetDeliveryCommitted "aws" targetReceipt)
  converged =
    evolveSesWorkflow
      ( evolveSesWorkflow
          (evolveSesWorkflow fullyDelivered (ProviderRevisionCommitted 7))
          (SemanticRevisionCommitted 7)
      )
      (LegacySecretGcCommitted legacyVersions)

  primaryCopy = LegacyPrimaryVersion "primary:v1"
  backupCopy = LegacyBackupVersion "backup:v1"
  legacyCopies = Set.fromList [primaryCopy, backupCopy]
  presentCopies = Map.fromSet (const LegacyBlobPresent) legacyCopies
  absentCopies = Map.fromSet (const LegacyBlobAbsent) legacyCopies
  gcInput = LegacyCheckpointGcInput True True legacyCopies Set.empty presentCopies

memoryRepository :: IORef (Int, SesWorkflowState) -> SesWorkflowRepository IO Int
memoryRepository cell =
  SesWorkflowRepository
    { readSesWorkflowSnapshot = do
        (revision, state) <- readIORef cell
        pure (Right (SesWorkflowSnapshot revision state))
    , compareAndSwapSesWorkflow = \expected next ->
        atomicModifyIORef' cell $ \current@(revision, _state) ->
          if revision == expected
            then ((revision + 1, next), Right ())
            else (current, Left "conflict")
    }

recordingInterpreters :: IORef [String] -> SesWorkflowInterpreters IO
recordingInterpreters calls =
  SesWorkflowInterpreters
    { sesProviderWorkflowInterpreter =
        ProviderWorkflowInterpreter
          { observeProviderWorkflowEffect = \_ -> do
              modifyIORef' calls (++ ["provider"])
              pure (Right (Just (ProviderRevisionCommitted 7)))
          , applyProviderWorkflowEffect = \_ -> pure (Right ())
          }
    , sesOperatorMaterialWorkflowInterpreter =
        OperatorMaterialWorkflowInterpreter
          { observeOperatorMaterialWorkflowEffect = \_ -> do
              modifyIORef' calls (++ ["material"])
              pure (Right (Just LegacyCredentialCheckpointReleased))
          , applyOperatorMaterialWorkflowEffect = \_ -> pure (Right ())
          }
    , sesCustodyWorkflowInterpreter =
        CustodyWorkflowInterpreter
          { observeCustodyWorkflowEffect = \_ -> do
              modifyIORef' calls (++ ["custody"])
              pure (Right (Just (TargetDeliveryCommitted "aws" (TargetReceipt 7 "target"))))
          , applyCustodyWorkflowEffect = \_ -> pure (Right ())
          }
    , sesAdminTeardownWorkflowInterpreter =
        AdminTeardownWorkflowInterpreter
          { observeAdminTeardownWorkflowEffect = \_ -> do
              modifyIORef' calls (++ ["admin"])
              pure (Right (Just "destroyed"))
          , applyAdminTeardownWorkflowEffect = \_ -> pure (Right ())
          }
    }
