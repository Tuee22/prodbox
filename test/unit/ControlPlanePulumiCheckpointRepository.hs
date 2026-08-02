{-# LANGUAGE OverloadedStrings #-}

module ControlPlanePulumiCheckpointRepository
  ( controlPlanePulumiCheckpointRepositorySuite
  )
where

import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityCheckpointBackupObservation (..)
  )
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityCheckpointBlob)
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerTestHarness)
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRepository (..)
  , PulumiCheckpointRetirementResult (..)
  )
import Prodbox.ControlPlane.PulumiCheckpointProductionStore
  ( confirmCheckpointBackupReplication
  )
import Prodbox.ControlPlane.PulumiCheckpointRepository
  ( PulumiCheckpointBlobStore (..)
  , aggregatePulumiCheckpointRepository
  )
import Prodbox.ControlPlane.RequestAuthentication (VerifiedCallerSlot)
import Prodbox.ControlPlane.Runtime
  ( AuthorityStartupMode (..)
  , authorityStartupModeFromRegistration
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (..)
  , AuthorityRegisteredSubmissionDecision (..)
  , authorityAggregatePulumiCheckpoints
  , authorityCheckpointOperationStatus
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  , stepRegisteredAuthoritySubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( RegisteredClientGeneration
  , RegisteredClientTable
  , RegisteredSubmissionDecision (..)
  , clientPrincipalForCaller
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (..)
  , GenesisPlan (..)
  , TargetAgentGenerationReceipt (..)
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  , mkVerifiedPulumiCheckpointRef
  , observeAuthorityPulumiCheckpoint
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId (..)
  , RequestDigest (..)
  , SubmissionStatus (StatusInFlight, StatusSettled)
  , TerminalOutcome (OperationCompletedOutcome)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBObservation (..)
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointPayloadKind (PulumiFileBackendCheckpoint)
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointDigest
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointMaximumBytes
  , registeredPulumiCheckpointByName
  )
import TestSupport

controlPlanePulumiCheckpointRepositorySuite :: SuiteBuilder ()
controlPlanePulumiCheckpointRepositorySuite =
  describe "Sprint 4.50 aggregate Pulumi checkpoint repository" $ do
    it "selects clean-install or migration startup only from retained registration observation" $ do
      authorityStartupModeFromRegistration (ModelBMissing :: ModelBObservation ())
        `shouldBe` Right AuthorityCleanInstallStartup
      version <- mustRightIO (mkModelBObjectVersion "registration-version-1")
      authorityStartupModeFromRegistration (ModelBObserved version ())
        `shouldBe` Right AuthorityMigrationStartup
      authorityStartupModeFromRegistration (ModelBCorrupt "invalid registration" :: ModelBObservation ())
        `shouldBe` Left "projection-import registration is corrupt: invalid registration"
      authorityStartupModeFromRegistration (ModelBEndpointUnready "sealed" :: ModelBObservation ())
        `shouldBe` Left "projection-import registration endpoint is not ready: sealed"
      authorityStartupModeFromRegistration (ModelBUnobservable "timeout" :: ModelBObservation ())
        `shouldBe` Left "projection-import registration is unobservable: timeout"

    it "replicates before promotion and makes exact publication replay idempotent" $ do
      fixture <- newPublicationFixture CasSucceeds BlobSucceeds
      let repository = fixtureRepository fixture
      published <-
        publishRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      published
        `shouldBe` PulumiCheckpointPublished
          (canonicalPulumiCheckpointDigest (fixtureCheckpoint fixture))
      observed <-
        observeRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          (fixtureRegistration fixture)
      observed `shouldBe` PulumiCheckpointCurrent (fixtureCheckpoint fixture)
      replayed <-
        publishRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      replayed
        `shouldBe` PulumiCheckpointAlreadyCurrent
          (canonicalPulumiCheckpointDigest (fixtureCheckpoint fixture))
      readIORef (fixtureReplicationCount fixture) `shouldReturn` 1
      readIORef (fixtureCasCount fixture) `shouldReturn` 2
      aggregate <- readIORef (fixtureAuthorityState fixture)
      authorityCheckpointOperationStatus
        checkpointCaller
        checkpointGeneration
        (fixtureOperation fixture)
        aggregate
        `shouldBe` Right (StatusSettled OperationCompletedOutcome)

    it "confirms an applied aggregate update after the CAS response is lost" $ do
      fixture <- newPublicationFixture CasAppliesThenLosesResponse BlobSucceeds
      published <-
        publishRegisteredPulumiCheckpoint
          (fixtureRepository fixture)
          checkpointCallerSlot
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      published
        `shouldBe` PulumiCheckpointPublished
          (canonicalPulumiCheckpointDigest (fixtureCheckpoint fixture))
      readIORef (fixtureCasCount fixture) `shouldReturn` 2

    it "refuses a forged or mismatched admitted operation before blob replication" $ do
      fixture <- newPublicationFixture CasSucceeds BlobSucceeds
      let admitted = fixtureOperation fixture
          forged = admitted {operationIdDigest = RequestDigest "forged-request"}
          forgedTicket =
            PulumiCheckpointMutationTicket
              { pulumiCheckpointTicketOperation = forged
              , pulumiCheckpointTicketExpectedDigest = Nothing
              }
      result <-
        publishRegisteredPulumiCheckpoint
          (fixtureRepository fixture)
          checkpointCallerSlot
          forgedTicket
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      result `shouldSatisfy` isPublicationRefusal
      crossCallerResult <-
        publishRegisteredPulumiCheckpoint
          (fixtureRepository fixture)
          (verifiedCallerSlotFixture CallerTestHarness 1)
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      crossCallerResult `shouldSatisfy` isPublicationRefusal
      readIORef (fixtureReplicationCount fixture) `shouldReturn` 0
      readIORef (fixtureCasCount fixture) `shouldReturn` 0

    it "does not advance the aggregate when either immutable copy is unavailable" $ do
      fixture <- newPublicationFixture CasSucceeds BlobFails
      result <-
        publishRegisteredPulumiCheckpoint
          (fixtureRepository fixture)
          checkpointCallerSlot
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      result
        `shouldBe` PulumiCheckpointPublicationUnavailable
          "independent checkpoint backup unavailable"
      after <- readIORef (fixtureAuthorityState fixture)
      observeAuthorityPulumiCheckpoint
        (fixtureRegistration fixture)
        (authorityAggregatePulumiCheckpoints after)
        `shouldBe` Nothing
      authorityCheckpointOperationStatus
        checkpointCaller
        checkpointGeneration
        (fixtureOperation fixture)
        after
        `shouldBe` Right StatusInFlight
      readIORef (fixtureCasCount fixture) `shouldReturn` 1

    it "converges a lost backup-copy response by exact read-back" $ do
      ciphertext <- mustRightIO (mkAuthorityBackupCiphertext "sealed-checkpoint")
      let receipt =
            AuthorityBackupReceipt
              { authorityBackupReceiptClass = AuthorityCheckpointBlob
              , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
              , authorityBackupReceiptObjectVersion = "backup-version-1"
              }
          lostCopy = Left ("copy response lost" :: Text.Text)
          observed =
            Right (AuthorityCheckpointBackupCurrent ciphertext receipt)
      confirmCheckpointBackupReplication
        "sealed-checkpoint"
        lostCopy
        observed
        `shouldBe` Right receipt

    it "refuses backup read-back byte or receipt drift" $ do
      ciphertext <- mustRightIO (mkAuthorityBackupCiphertext "sealed-checkpoint")
      otherCiphertext <- mustRightIO (mkAuthorityBackupCiphertext "different-checkpoint")
      let receipt =
            AuthorityBackupReceipt
              { authorityBackupReceiptClass = AuthorityCheckpointBlob
              , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
              , authorityBackupReceiptObjectVersion = "backup-version-1"
              }
          changedReceipt =
            receipt {authorityBackupReceiptObjectVersion = "backup-version-2"}
          observed =
            Right (AuthorityCheckpointBackupCurrent ciphertext receipt)
          observedOther =
            Right (AuthorityCheckpointBackupCurrent otherCiphertext receipt)
      confirmCheckpointBackupReplication
        "sealed-checkpoint"
        (Right changedReceipt :: Either Text.Text AuthorityBackupReceipt)
        observed
        `shouldBe` Left "checkpoint backup receipt changed during read-back"
      confirmCheckpointBackupReplication
        "sealed-checkpoint"
        (Right receipt :: Either Text.Text AuthorityBackupReceipt)
        observedOther
        `shouldBe` Left "primary and backup checkpoint ciphertext differ"

    it "retires only through a separately admitted predecessor-fenced operation" $ do
      fixture <- newPublicationFixture CasSucceeds BlobSucceeds
      let repository = fixtureRepository fixture
      _ <-
        publishRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          (fixtureTicket fixture)
          (fixtureRegistration fixture)
          (fixtureCheckpoint fixture)
      publishedAggregate <- readIORef (fixtureAuthorityState fixture)
      (retireOperation, admitted) <-
        admitOperation
          publishedAggregate
          2
      writeIORef (fixtureAuthorityState fixture) admitted
      retired <-
        retireRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          PulumiCheckpointMutationTicket
            { pulumiCheckpointTicketOperation = retireOperation
            , pulumiCheckpointTicketExpectedDigest =
                Just (canonicalPulumiCheckpointDigest (fixtureCheckpoint fixture))
            }
          (fixtureRegistration fixture)
      retired `shouldBe` PulumiCheckpointRetiredAndReadBack
      observed <-
        observeRegisteredPulumiCheckpoint
          repository
          checkpointCallerSlot
          (fixtureRegistration fixture)
      observed `shouldBe` PulumiCheckpointMissing
      retiredAggregate <- readIORef (fixtureAuthorityState fixture)
      authorityCheckpointOperationStatus
        checkpointCaller
        checkpointGeneration
        retireOperation
        retiredAggregate
        `shouldBe` Right (StatusSettled OperationCompletedOutcome)

data CasMode
  = CasSucceeds
  | CasAppliesThenLosesResponse

data BlobMode
  = BlobSucceeds
  | BlobFails

data PublicationFixture = PublicationFixture
  { fixtureRepository :: !(PulumiCheckpointRepository IO)
  , fixtureAuthorityState :: !(IORef AuthorityAdmissionAggregate)
  , fixtureCasCount :: !(IORef Int)
  , fixtureReplicationCount :: !(IORef Int)
  , fixtureRegistration :: !RegisteredPulumiCheckpoint
  , fixtureCheckpoint :: !CanonicalPulumiCheckpoint
  , fixtureOperation :: !OperationId
  , fixtureTicket :: !PulumiCheckpointMutationTicket
  }

newPublicationFixture :: CasMode -> BlobMode -> IO PublicationFixture
newPublicationFixture casMode blobMode = do
  registration <- mustRightIO (registeredPulumiCheckpointByName "aws-test")
  checkpoint <- checkpointFixture
  (operation, admitted) <- admitOperation openedAuthority 1
  authorityState <- newIORef admitted
  revision <- newIORef (0 :: Word)
  casCount <- newIORef 0
  replicationCount <- newIORef 0
  storedBlob <- newIORef Nothing
  let authorityRepository =
        memoryAuthorityRepository casMode authorityState revision casCount
      blobStore =
        memoryBlobStore blobMode replicationCount storedBlob
      repository =
        aggregatePulumiCheckpointRepository authorityRepository blobStore
  pure
    PublicationFixture
      { fixtureRepository = repository
      , fixtureAuthorityState = authorityState
      , fixtureCasCount = casCount
      , fixtureReplicationCount = replicationCount
      , fixtureRegistration = registration
      , fixtureCheckpoint = checkpoint
      , fixtureOperation = operation
      , fixtureTicket =
          PulumiCheckpointMutationTicket
            { pulumiCheckpointTicketOperation = operation
            , pulumiCheckpointTicketExpectedDigest = Nothing
            }
      }

memoryAuthorityRepository
  :: CasMode
  -> IORef AuthorityAdmissionAggregate
  -> IORef Word
  -> IORef Int
  -> AuthorityAdmissionRepository IO Word
memoryAuthorityRepository mode stateRef revisionRef casCount =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        revision <- readIORef revisionRef
        state <- readIORef stateRef
        pure
          ( Right
              AuthorityAdmissionSnapshot
                { authorityAdmissionRevision = revision
                , authorityAdmissionSnapshotState = state
                }
          )
    , compareAndSwapAuthorityAdmission = \expected next -> do
        modifyIORef' casCount (+ 1)
        current <- readIORef revisionRef
        if current /= expected
          then pure (Left "fixture CAS conflict")
          else do
            writeIORef stateRef next
            writeIORef revisionRef (current + 1)
            pure $ case mode of
              CasSucceeds -> Right ()
              CasAppliesThenLosesResponse ->
                Left "fixture lost the successful CAS response"
    }

memoryBlobStore
  :: BlobMode
  -> IORef Int
  -> IORef (Maybe (VerifiedPulumiCheckpointRef, CanonicalPulumiCheckpoint))
  -> PulumiCheckpointBlobStore IO
memoryBlobStore mode replicationCount stored =
  PulumiCheckpointBlobStore
    { replicatePulumiCheckpointBlob = \_ checkpoint -> do
        modifyIORef' replicationCount (+ 1)
        case mode of
          BlobFails -> pure (Left "independent checkpoint backup unavailable")
          BlobSucceeds -> do
            reference <- checkpointReference checkpoint
            writeIORef stored (Just (reference, checkpoint))
            pure (Right reference)
    , observePulumiCheckpointBlob = \_ expected -> do
        current <- readIORef stored
        pure $ case current of
          Just (reference, checkpoint)
            | reference == expected -> PulumiCheckpointCurrent checkpoint
          Nothing -> PulumiCheckpointMissing
          Just _ -> PulumiCheckpointCorrupt "fixture reference mismatch"
    }

admitOperation
  :: AuthorityAdmissionAggregate
  -> Word
  -> IO (OperationId, AuthorityAdmissionAggregate)
admitOperation aggregate rawSequence = do
  let digest = RequestDigest ("checkpoint-operation-" <> Text.pack (show rawSequence))
      submissionKey =
        mustRight
          (mkClientSubmissionKey ("checkpoint-operation-" <> Text.pack (show rawSequence)))
  (submission, admitted) <-
    mustRightIO
      ( stepRegisteredAuthoritySubmission
          aggregate
          checkpointCaller
          checkpointGeneration
          submissionKey
          digest
      )
  operation <- case submission of
    AuthorityRegisteredSubmissionDecided
      (RegisteredSubmissionAccepted acceptedOperation) ->
        pure acceptedOperation
    other -> fail ("unexpected checkpoint operation admission: " <> show other)
  pure (operation, admitted)

checkpointReference
  :: CanonicalPulumiCheckpoint
  -> IO VerifiedPulumiCheckpointRef
checkpointReference checkpoint =
  mustRightIO
    ( mkVerifiedPulumiCheckpointRef
        (canonicalPulumiCheckpointDigest checkpoint)
        (Text.replicate 64 "a")
        "primary-etag-1"
        (Text.replicate 64 "a")
        "backup-version-1"
    )

checkpointFixture :: IO CanonicalPulumiCheckpoint
checkpointFixture =
  mustRightIO
    ( decodeCanonicalPulumiCheckpoint
        (Set.singleton PulumiFileBackendCheckpoint)
        pulumiCheckpointMaximumBytes
        (TextEncoding.encodeUtf8 "{\"version\":3,\"checkpoint\":{\"sequence\":1}}")
    )

isPublicationRefusal :: PulumiCheckpointPublicationResult -> Bool
isPublicationRefusal result = case result of
  PulumiCheckpointPublicationRefused _ -> True
  _ -> False

openedAuthority :: AuthorityAdmissionAggregate
openedAuthority =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
    ( mustRight
        ( initialCleanInstallAuthorityWithRegisteredClients
            8
            16
            checkpointClientTable
        )
    )
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "checkpoint-genesis" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis
        (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

checkpointCaller :: CallerPrincipal
checkpointCaller = CallerOperatorCli

checkpointGeneration :: RegisteredClientGeneration
checkpointGeneration = mustRight (mkRegisteredClientGeneration 1)

checkpointCallerSlot :: VerifiedCallerSlot
checkpointCallerSlot = verifiedCallerSlotFixture checkpointCaller 1

checkpointClientTable :: RegisteredClientTable
checkpointClientTable =
  mustRight (mkRegisteredClientTable 1 [spec])
 where
  slot = mustRight (mkRegisteredClientSlot 1)
  spec =
    mustRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller checkpointCaller)
          slot
          checkpointGeneration
          16
      )

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
