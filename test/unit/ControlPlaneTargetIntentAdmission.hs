{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetIntentAdmission (controlPlaneTargetIntentAdmissionSuite) where

import Codec.Serialise (serialise)
import Control.Exception (AsyncException (UserInterrupt), throwIO, try)
import Control.Monad (forM_, void)
import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import EpochPromotionFixture
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  , compileBackupRepairPermit
  , compileGenesisAwsAdminIntent
  , compileNormalAwsAdminIntentForScope
  , compileRepairAwsAdminIntent
  )
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.ServiceSessionJournal
import Prodbox.ControlPlane.TargetIntentAdmission
import Prodbox.ControlPlane.TargetIntentAuthority
import Prodbox.ControlPlane.TargetIntentAuthorityEndpoint
import Prodbox.ControlPlane.TargetMaterialRegistry
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.ControlPlane.TargetSecretWorker
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.AdmissionGate (authoritySubmissionGateRefusalToken)
import Prodbox.Lifecycle.Authority.BackupRepair
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
import Prodbox.Lifecycle.CredentialProvisioner.FirstReconcileJournal
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTargetOutbox
import Prodbox.Lifecycle.Decommission.AuthorityExport
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (..))
import Prodbox.Lifecycle.Decommission.Manifest (mkManifestPublicKey)
import Prodbox.Lifecycle.Lease
import Prodbox.Lifecycle.TargetCommitIntent
import TestSupport

controlPlaneTargetIntentAdmissionSuite :: SuiteBuilder ()
controlPlaneTargetIntentAdmissionSuite =
  describe "Sprint 6.5 retained Target signing admission" $ do
    forM_ (zip [0 :: Int ..] cutoverPrefixes) $ \(index, aggregate) ->
      it ("gates actual issuance at retained cutover prefix " ++ show index) $ do
        fixture <- newFixture aggregate
        result <- issueTargetCommittedIntent (boundary fixture) request
        if index == length cutoverPrefixes - 1
          then do
            issued <- mustRightIO result
            targetIntentAuthorityEpoch (signedTargetCommittedIntentSpec (issuedTargetSignedIntent issued))
              `shouldBe` Coordinate.AuthorityEpoch 2
          else do
            result `shouldSatisfy` isLeft
            readIORef (events fixture) `shouldReturn` [AdmissionRead]

    forM_
      [ ("clean", cleanOpen, TargetIntentAuthorityWriter)
      , ("legacy", legacyOpen, TargetIntentLegacyWriter)
      ]
      $ \(label, aggregate, writer) ->
        it ("preserves the admitted " ++ label ++ " writer before cutover") $ do
          targetIntentAdmissionFromAggregate aggregate
            `shouldBe` TargetIntentAdmissionReady writer (Coordinate.AuthorityEpoch 1)
          fixture <- newFixture aggregate
          issued <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
          acceptedTargetAuthorityEpoch (issuedTargetAcceptedAuthority issued)
            `shouldBe` Coordinate.AuthorityEpoch 1
          observed <- readIORef (events fixture)
          length (filter (== SignPayload) observed) `shouldBe` 1
          length (filter (== TrustInstall) observed) `shouldBe` 1

    forM_ closedAuthorities $ \(label, aggregate, reason) ->
      it ("refuses " ++ label ++ " before reading an outbox or signing") $ do
        fixture <- newFixture aggregate
        result <- issueTargetCommittedIntent (boundary fixture) request
        refusalOf result `shouldBe` Just (TargetIntentIssueAdmissionClosed reason)
        readIORef (events fixture) `shouldReturn` [AdmissionRead]

    forM_ [PublicKeyRead, SignPayload, TrustInstall] $ \stage -> do
      it ("does not release an intent if admission freezes during " ++ show stage) $ do
        fixture <- newFixture cleanOpen
        writeIORef
          (hook fixture)
          (\event -> if event == stage then writeIORef (aggregateCell fixture) frozen else pure ())
        result <- issueTargetCommittedIntent (boundary fixture) request
        refusalOf result
          `shouldBe` Just (TargetIntentIssueAdmissionClosed AuthorityMigrationWritersQuiesced)
        observed <- readIORef (events fixture)
        length (filter (== SignPayload) observed) `shouldBe` if stage == PublicKeyRead then 0 else 1
        length (filter (== TrustInstall) observed) `shouldBe` if stage == TrustInstall then 1 else 0

      it ("does not release an intent if the admitted epoch changes during " ++ show stage) $ do
        fixture <- newFixture cleanOpen
        writeIORef
          (hook fixture)
          (\event -> if event == stage then writeIORef (aggregateCell fixture) opened else pure ())
        result <- issueTargetCommittedIntent (boundary fixture) request
        refusalOf result `shouldBe` Just TargetIntentIssueAdmissionChanged

      it ("charges elapsed time during " ++ show stage ++ " to the original deadline") $ do
        fixture <- newFixture cleanOpen
        writeIORef
          (hook fixture)
          (\event -> if event == stage then writeIORef (clockCell fixture) (Right deadline) else pure ())
        result <- issueTargetCommittedIntent (boundary fixture) request
        refusalOf result `shouldBe` Just TargetIntentIssueDeadlineReached

      it ("preserves an unobservable admission after " ++ show stage) $ do
        fixture <- newFixture cleanOpen
        writeIORef
          (hook fixture)
          ( \event ->
              if event == stage
                then writeIORef (readFailure fixture) (Just "private-admission-sentinel")
                else pure ()
          )
        result <- issueTargetCommittedIntent (boundary fixture) request
        refusalOf result
          `shouldBe` Just (TargetIntentIssueAdmissionUnavailable "private-admission-sentinel")
        targetIntentIssueErrorResponse (fromJust (refusalOf result))
          `shouldBe` TargetIntentIssueUnavailable "authority-admission-unavailable"

    it "refuses an unreadable aggregate without substituting its authentication epoch" $ do
      fixture <- newFixture cleanOpen
      writeIORef (readFailure fixture) (Just "private-read-sentinel")
      result <- issueTargetCommittedIntent (boundary fixture) request
      refusalOf result `shouldBe` Just (TargetIntentIssueAdmissionUnavailable "private-read-sentinel")
      readIORef (events fixture) `shouldReturn` [AdmissionRead]

    it "refuses a zero epoch from a malformed boundary observation" $ do
      fixture <- newFixture cleanOpen
      let malformed =
            (boundary fixture)
              { readTargetIntentAuthorityAdmission =
                  const
                    (pure (Right (TargetIntentAdmissionReady TargetIntentAuthorityWriter (Coordinate.AuthorityEpoch 0))))
              }
      result <- issueTargetCommittedIntent malformed request
      refusalOf result `shouldBe` Just TargetIntentIssueAdmissionInvalid
      readIORef (events fixture) `shouldReturn` []

    it "does not let a compatibility admission sample become a replacement sample at the same epoch" $ do
      fixture <- newFixture cleanOpen
      admissionReadCount <- newIORef (0 :: Int)
      let changed =
            (boundary fixture)
              { readTargetIntentAuthorityAdmission = \_ -> do
                  modifyIORef' admissionReadCount (+ 1)
                  count <- readIORef admissionReadCount
                  pure
                    ( Right
                        ( TargetIntentAdmissionReady
                            (if count == 1 then TargetIntentLegacyWriter else TargetIntentAuthorityWriter)
                            (Coordinate.AuthorityEpoch 1)
                        )
                    )
              }
      result <- issueTargetCommittedIntent changed request
      refusalOf result `shouldBe` Just TargetIntentIssueAdmissionChanged
      observed <- readIORef (events fixture)
      filter (== SignPayload) observed `shouldBe` []

    it "returns the same exact signed intent on an admitted retry and refuses a later frozen retry" $ do
      fixture <- newFixture cleanOpen
      first <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
      second <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
      encodeSignedTargetCommittedIntent (issuedTargetSignedIntent first)
        `shouldBe` encodeSignedTargetCommittedIntent (issuedTargetSignedIntent second)
      writeIORef (events fixture) []
      writeIORef (aggregateCell fixture) frozen
      result <- issueTargetCommittedIntent (boundary fixture) request
      refusalOf result
        `shouldBe` Just (TargetIntentIssueAdmissionClosed AuthorityMigrationWritersQuiesced)
      readIORef (events fixture) `shouldReturn` [AdmissionRead]

    it "propagates cancellation during signing without installing trust or returning a signature" $ do
      fixture <- newFixture cleanOpen
      writeIORef
        (hook fixture)
        (\event -> if event == SignPayload then throwIO UserInterrupt else pure ())
      result <-
        try (issueTargetCommittedIntent (boundary fixture) request)
          :: IO (Either AsyncException (Either TargetIntentIssueError IssuedTargetIntent))
      case result of
        Left interrupted -> interrupted `shouldBe` UserInterrupt
        Right _ -> fail "signer cancellation was swallowed"
      observed <- readIORef (events fixture)
      filter (== TrustInstall) observed `shouldBe` []

    it "verifies a positive attested execution permit through the admitted wrapper" $ do
      fixture <- newFixture cleanOpen
      issued <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
      let (rollout, attestation, session) = executionInputs issued
      permit <-
        mustRightIO
          =<< issueAdmittedTargetWorkerExecutionPermit (boundary fixture) issued rollout attestation session
      verified <-
        mustRightIO
          ( verifyTargetWorkerExecutionPermit
              (issuedTargetAcceptedAuthority issued)
              now
              (targetWorkerAttestedIntent attestation)
              permit
          )
      targetWorkerExecutionPermitMatchesObservation rollout attestation session verified `shouldBe` True

    it "refuses an execution permit when admission froze after initial issuance" $ do
      fixture <- newFixture cleanOpen
      issued <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
      writeIORef (events fixture) []
      writeIORef (aggregateCell fixture) frozen
      let (rollout, attestation, session) = executionInputs issued
      result <-
        issueAdmittedTargetWorkerExecutionPermit (boundary fixture) issued rollout attestation session
      permitRefusal result
        `shouldBe` Just (TargetIntentIssueAdmissionClosed AuthorityMigrationWritersQuiesced)
      readIORef (events fixture) `shouldReturn` [AdmissionRead]

    forM_ [PermitAdmissionFreeze, PermitDeadlineReached] $ \fault ->
      it ("does not release the second signature across " ++ show fault) $ do
        fixture <- newFixture cleanOpen
        issued <- mustRightIO =<< issueTargetCommittedIntent (boundary fixture) request
        writeIORef (events fixture) []
        writeIORef (hook fixture) $ \event ->
          if event /= SignPayload
            then pure ()
            else case fault of
              PermitAdmissionFreeze -> writeIORef (aggregateCell fixture) frozen
              PermitDeadlineReached -> writeIORef (clockCell fixture) (Right deadline)
        let (rollout, attestation, session) = executionInputs issued
        result <-
          issueAdmittedTargetWorkerExecutionPermit (boundary fixture) issued rollout attestation session
        let expected = case fault of
              PermitAdmissionFreeze -> Left (TargetIntentIssueAdmissionClosed AuthorityMigrationWritersQuiesced)
              PermitDeadlineReached -> Left TargetIntentIssueDeadlineReached
        void result `shouldBe` expected
        observed <- readIORef (events fixture)
        length (filter (== SignPayload) observed) `shouldBe` 1

    forM_ recoveryCases $ \(label, aggregate, outbox) -> do
      it ("admits the exact retained " ++ label ++ " backup-store delivery") $ do
        fixture <- newFixture aggregate
        outboxCell <- newIORef (Right outbox)
        journalCell <- newIORef (Right genesisJournal)
        let scoped = recoveryBoundary fixture outboxCell journalCell
            scopedRequest = requestForOutbox outbox
        issued <- mustRightIO =<< issueTargetCommittedIntent scoped scopedRequest
        acceptedTargetId (issuedTargetAcceptedAuthority issued)
          `shouldBe` TargetAwsCredential AwsAuthorityBackupStore
        acceptedTargetAuthorityEpoch (issuedTargetAcceptedAuthority issued)
          `shouldBe` Coordinate.AuthorityEpoch 1
        let (rollout, attestation, session) = executionInputs issued
        permit <-
          mustRightIO =<< issueAdmittedTargetWorkerExecutionPermit scoped issued rollout attestation session
        verified <-
          mustRightIO
            ( verifyTargetWorkerExecutionPermit
                (issuedTargetAcceptedAuthority issued)
                now
                (targetWorkerAttestedIntent attestation)
                permit
            )
        targetWorkerExecutionPermitMatchesObservation rollout attestation session verified `shouldBe` True
        activeAuthorityEpoch aggregate `shouldSatisfy` isLeft

      forM_
        [TargetAcmeEab, TargetAwsCredential AwsLifecycleProvider, TargetAwsCredential AwsTlsRetentionStore]
        $ \otherTarget ->
          it ("does not extend " ++ label ++ " recovery admission to " ++ show otherTarget) $ do
            fixture <- newFixture aggregate
            outboxCell <- newIORef (Right outbox)
            journalCell <- newIORef (Right genesisJournal)
            let scopedRequest = (requestForOutbox outbox) {targetIntentIssueTarget = otherTarget}
            result <- issueTargetCommittedIntent (recoveryBoundary fixture outboxCell journalCell) scopedRequest
            result `shouldSatisfy` isLeft
            readIORef (events fixture) `shouldReturn` [AdmissionRead]

      it ("requires canonical permit purpose for " ++ label ++ " recovery") $ do
        fixture <- newFixture aggregate
        let legacy =
              mustRight
                ( decodePreparedCredentialTargetOutbox
                    (encodePreparedCredentialTargetObservation (preparedCredentialTargetOutboxObservation outbox))
                )
        outboxCell <- newIORef (Right legacy)
        journalCell <- newIORef (Right genesisJournal)
        result <-
          issueTargetCommittedIntent
            (recoveryBoundary fixture outboxCell journalCell)
            (requestForOutbox outbox)
        result `shouldSatisfy` isLeft
        observed <- readIORef (events fixture)
        filter (== SignPayload) observed `shouldBe` []

      it ("refuses an ordinary backup-store permit during " ++ label ++ " recovery") $ do
        fixture <- newFixture aggregate
        outboxCell <- newIORef (Right normalBackupOutbox)
        journalCell <- newIORef (Right genesisJournal)
        result <-
          issueTargetCommittedIntent
            (recoveryBoundary fixture outboxCell journalCell)
            (requestForOutbox normalBackupOutbox)
        result `shouldSatisfy` isLeft
        observed <- readIORef (events fixture)
        filter (== SignPayload) observed `shouldBe` []

      it ("rechecks the " ++ label ++ " permit before execution authorization") $ do
        fixture <- newFixture aggregate
        outboxCell <- newIORef (Right outbox)
        journalCell <- newIORef (Right genesisJournal)
        let scoped = recoveryBoundary fixture outboxCell journalCell
        issued <- mustRightIO =<< issueTargetCommittedIntent scoped (requestForOutbox outbox)
        writeIORef outboxCell (Right normalBackupOutbox)
        let (rollout, attestation, session) = executionInputs issued
        result <- issueAdmittedTargetWorkerExecutionPermit scoped issued rollout attestation session
        result `shouldSatisfy` isLeft
        observed <- readIORef (events fixture)
        length (filter (== SignPayload) observed) `shouldBe` 1

      forM_ [RequestOperationDrift, RequestGenerationDrift, RequestReceiptDrift, RequestAgentDrift] $ \drift ->
        it ("refuses " ++ label ++ " recovery request " ++ show drift) $ do
          fixture <- newFixture aggregate
          outboxCell <- newIORef (Right outbox)
          journalCell <- newIORef (Right genesisJournal)
          result <-
            issueTargetCommittedIntent
              (recoveryBoundary fixture outboxCell journalCell)
              (driftRequest drift (requestForOutbox outbox))
          result `shouldSatisfy` isLeft
          observed <- readIORef (events fixture)
          filter (== SignPayload) observed `shouldBe` []

      forM_ [RecoveryOutboxUnobservable, RecoveryOutboxForeign] $ \fault ->
        it ("rechecks " ++ label ++ " purpose across signing: " ++ show fault) $ do
          fixture <- newFixture aggregate
          outboxCell <- newIORef (Right outbox)
          journalCell <- newIORef (Right genesisJournal)
          writeIORef (hook fixture) (changeRecoveryEvidence outboxCell fault)
          result <-
            issueTargetCommittedIntent
              (recoveryBoundary fixture outboxCell journalCell)
              (requestForOutbox outbox)
          result `shouldSatisfy` isLeft
          observed <- readIORef (events fixture)
          length (filter (== SignPayload) observed) `shouldBe` 1
          filter (== TrustInstall) observed `shouldBe` []

    it "refuses a foreign genesis plan and a changed first-reconcile journal" $ do
      forM_
        [ (foreignGenesisOutbox, genesisJournal)
        , (genesisOutbox, changedGenesisJournal)
        , (genesisOutbox, advancedGenesisJournal)
        ]
        $ \(outbox, journal) -> do
          fixture <- newFixture genesisEstablishing
          outboxCell <- newIORef (Right outbox)
          journalCell <- newIORef (Right journal)
          result <-
            issueTargetCommittedIntent
              (recoveryBoundary fixture outboxCell journalCell)
              (requestForOutbox outbox)
          result `shouldSatisfy` isLeft
          observed <- readIORef (events fixture)
          filter (== SignPayload) observed `shouldBe` []

    it "refuses backup repair without its exact retained permit" $ do
      forM_ [temporaryRepair, repairFrozenWith foreignRepairPermit] $ \aggregate -> do
        fixture <- newFixture aggregate
        outboxCell <- newIORef (Right repairOutbox)
        journalCell <- newIORef (Right genesisJournal)
        result <-
          issueTargetCommittedIntent
            (recoveryBoundary fixture outboxCell journalCell)
            (requestForOutbox repairOutbox)
        result `shouldSatisfy` isLeft
        observed <- readIORef (events fixture)
        filter (== SignPayload) observed `shouldBe` []

    it "does not admit a backup recovery permit through a prepared/frozen cutover or decommission" $ do
      let prepared = cutoverPrefixes !! 1
          frozenRepair =
            applyEpochAggregateCommand
              frozen
              (ApplyAuthorityBackupRepair (AssessBackupHealth BackupPositivelyAbsent))
          preparedRepair =
            applyEpochAggregateCommand
              prepared
              (ApplyAuthorityBackupRepair (AssessBackupHealth BackupPositivelyAbsent))
          blocked =
            [ frozen
            , prepared
            , preparedRepair
            , frozenRepair
            , snd (freezeAuthorityForDecommission genesisEstablishing)
            ]
      forM_ blocked $ \aggregate -> do
        fixture <- newFixture aggregate
        outboxCell <- newIORef (Right genesisOutbox)
        journalCell <- newIORef (Right genesisJournal)
        result <-
          issueTargetCommittedIntent
            (recoveryBoundary fixture outboxCell journalCell)
            (requestForOutbox genesisOutbox)
        result `shouldSatisfy` isLeft
        readIORef (events fixture) `shouldReturn` [AdmissionRead]

    it "preserves every established refusal wire tag after moving the shared declaration" $ do
      let reasons =
            [ AuthorityGenesisFrozen
            , AuthorityGenesisEstablishing
            , AuthorityBackupRepairFrozen
            , AuthorityDecommissionAdmissionFrozen
            , AuthorityDecommissionPermanentlyStopped
            , AuthorityLegacyWriterActive
            , AuthorityMigrationWritersQuiesced
            , AuthorityProviderAdmissionCascadeFrozen
            , AuthorityProviderAdmissionCredentialRevoked
            , AuthorityProviderAdmissionCredentialMutationPending
            ]
      forM_ (zip [0 .. 9] reasons) $ \(tag, reason) -> do
        serialise reason `shouldBe` LazyByteString.pack [129, tag]
        let response = targetIntentIssueErrorResponse (TargetIntentIssueAdmissionClosed reason)
        response
          `shouldBe` TargetIntentIssueRefused
            ("authority-mutation-admission-closed/" <> authoritySubmissionGateRefusalToken reason)
        targetIntentIssueResponseStatus response `shouldBe` ReplyConflict

data PermitFault = PermitAdmissionFreeze | PermitDeadlineReached
  deriving (Eq, Show)

data RecoveryFault = RecoveryOutboxUnobservable | RecoveryOutboxForeign
  deriving (Eq, Show)

data RequestDrift
  = RequestOperationDrift
  | RequestGenerationDrift
  | RequestReceiptDrift
  | RequestAgentDrift
  deriving (Eq, Show)

data Event
  = AdmissionRead
  | PreparedRead
  | ClockRead
  | PublicKeyRead
  | SignPayload
  | TrustInstall
  | GenesisEvidenceRead
  | RepairEvidenceRead
  deriving (Eq, Show)

data Fixture = Fixture
  { aggregateCell :: IORef AuthorityAdmissionAggregate
  , clockCell :: IORef (Either Text AuthorityTime)
  , readFailure :: IORef (Maybe Text)
  , events :: IORef [Event]
  , hook :: IORef (Event -> IO ())
  }

newFixture :: AuthorityAdmissionAggregate -> IO Fixture
newFixture aggregate =
  Fixture
    <$> newIORef aggregate
    <*> newIORef (Right now)
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef (const (pure ()))

record :: Fixture -> Event -> IO ()
record fixture event = do
  modifyIORef' (events fixture) (++ [event])
  handler <- readIORef (hook fixture)
  handler event

boundary :: Fixture -> TargetIntentIssuerBoundary IO
boundary fixture =
  TargetIntentIssuerBoundary
    { readTargetIntentAuthorityAdmission =
        const (readTargetIntentIssuanceAdmission (fixtureRepository fixture))
    , readTargetIntentAuthorityTime = record fixture ClockRead >> readIORef (clockCell fixture)
    , readAuthorizedPreparedTargetIntent = \_ -> record fixture PreparedRead >> pure (Right preparedIntent)
    , targetIntentAuthoritySigner =
        AuthorityManifestSigner
          { readAuthorityManifestPublicKey = do
              record fixture PublicKeyRead
              pure (Right (1, mustRight (mkManifestPublicKey (ByteArray.convert publicKey))))
          , signAuthorityManifestPayload = \payload -> do
              record fixture SignPayload
              pure (Right (1, ByteArray.convert (Ed25519.sign privateKey publicKey payload)))
          }
    , targetIntentAuthorityIssuerIdentity = "lifecycle-authority"
    , installIssuedTargetAuthority = \_ accepted -> record fixture TrustInstall >> pure (Right accepted)
    }
fixtureRepository :: Fixture -> AuthorityAdmissionRepository IO Word
fixtureRepository fixture =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        record fixture AdmissionRead
        failed <- readIORef (readFailure fixture)
        case failed of
          Just detail -> pure (Left detail)
          Nothing -> Right . AuthorityAdmissionSnapshot (1 :: Word) <$> readIORef (aggregateCell fixture)
    , compareAndSwapAuthorityAdmission = \_ _ -> fail "issuance observation must not write admission"
    }

recoveryBoundary
  :: Fixture
  -> IORef (Either Text PreparedCredentialTargetOutbox)
  -> IORef (Either Text FirstReconcileJournal)
  -> TargetIntentIssuerBoundary IO
recoveryBoundary fixture outboxCell journalCell =
  (boundary fixture)
    { readTargetIntentAuthorityAdmission =
        readTargetIntentIssuanceAdmissionForRequest (TargetIntentAdmissionInterpreter interpret)
    , readAuthorizedPreparedTargetIntent = prepare
    }
 where
  interpret :: TargetIntentAdmissionProgram result -> IO (Either Text result)
  interpret program = case program of
    ReadTargetWriterAdmission -> do
      observed <- readAuthorityAdmission (fixtureRepository fixture)
      pure (authorityAdmissionSnapshotState <$> observed)
    ReadGenesisTargetIssuanceEvidence _ -> do
      record fixture GenesisEvidenceRead
      outbox <- readIORef outboxCell
      journal <- readIORef journalCell
      pure ((,) <$> outbox <*> journal)
    ReadRepairTargetIssuanceEvidence _ -> record fixture RepairEvidenceRead >> readIORef outboxCell
  prepare scopedRequest = do
    record fixture PreparedRead
    observed <- readIORef outboxCell
    pure $ do
      outbox <- observed
      if targetIntentRequestMatchesPreparedOutbox scopedRequest outbox
        then preparedFromOutbox outbox
        else Left "fixture outbox request mismatch"

preparedFromOutbox :: PreparedCredentialTargetOutbox -> Either Text AuthorizedPreparedTargetIntent
preparedFromOutbox outbox = do
  owner <-
    either (Left . Text.pack . show) Right (mkOwnerNonce (preparedCredentialTargetOwnerNonce prepared))
  fence <-
    either (Left . Text.pack . show) Right (mkFencingToken (preparedCredentialTargetFence prepared))
  mkAuthorizedPreparedTargetIntent
    owner
    fence
    (preparedCredentialTargetSelectedAgent prepared)
    (preparedCredentialTargetId prepared)
    (preparedCredentialTargetGeneration prepared)
    (preparedCredentialTargetReceiptDigest prepared)
    (preparedCredentialTargetDeadline prepared)
 where
  prepared = preparedCredentialTargetOutboxObservation outbox

changeRecoveryEvidence
  :: IORef (Either Text PreparedCredentialTargetOutbox) -> RecoveryFault -> Event -> IO ()
changeRecoveryEvidence cell fault event
  | event /= SignPayload = pure ()
  | otherwise = case fault of
      RecoveryOutboxUnobservable -> writeIORef cell (Left "private-recovery-sentinel")
      RecoveryOutboxForeign -> writeIORef cell (Right foreignGenesisOutbox)

driftRequest :: RequestDrift -> TargetIntentIssueRequest -> TargetIntentIssueRequest
driftRequest drift original = case drift of
  RequestOperationDrift -> original {targetIntentIssueOperationId = "foreign-operation"}
  RequestGenerationDrift -> original {targetIntentIssueExpectedGeneration = mustRight (mkCredentialGeneration 99)}
  RequestReceiptDrift -> original {targetIntentIssueExpectedReceiptDigest = sha256TargetValueDigest "foreign-receipt"}
  RequestAgentDrift ->
    original
      { targetIntentIssueExpectedAgentIdentity =
          mustRight (mkTargetAgentRolloutIdentity "foreign" ("sha256:" <> Text.replicate 64 "a"))
      }

requestForOutbox :: PreparedCredentialTargetOutbox -> TargetIntentIssueRequest
requestForOutbox outbox =
  TargetIntentIssueRequest
    (preparedCredentialTargetId prepared)
    (preparedCredentialTargetSelectedAgent prepared)
    (preparedCredentialTargetGeneration prepared)
    (preparedCredentialTargetReceiptDigest prepared)
    ( operatorMaterialOperationIdText
        (awsAdminPermitIntentOperationId (fromJust (preparedCredentialTargetOutboxCanonicalIntent outbox)))
    )
    0
    "recovery-idempotency"
 where
  prepared = preparedCredentialTargetOutboxObservation outbox

recoveryCases :: [(String, AuthorityAdmissionAggregate, PreparedCredentialTargetOutbox)]
recoveryCases =
  [ ("genesis", genesisEstablishing, genesisOutbox)
  , ("repair", repairFrozenWith repairPermit, repairOutbox)
  ]

genesisPlan :: GenesisPlan
genesisPlan = GenesisPlan "target-recovery-genesis" "authority-backup-store/home"

genesisEstablishing :: AuthorityAdmissionAggregate
genesisEstablishing =
  applyEpochAggregateCommand
    (mustRight (initialCleanInstallAuthority 4 8))
    (ApplyAuthorityGenesis (BeginGenesisEstablishment genesisPlan))

genesisJournal, changedGenesisJournal, advancedGenesisJournal :: FirstReconcileJournal
genesisJournal = initialFirstReconcileJournal (defaultFirstReconcileProvisioningPlan deadline)
changedGenesisJournal =
  initialFirstReconcileJournal (defaultFirstReconcileProvisioningPlan (authorityTimeFromMicros 2000))
advancedGenesisJournal = mustRight (appendFirstReconcileReceipt receipt genesisJournal)
 where
  member =
    fromJust
      ( mustRight
          ( nextFirstReconcileMember
              (firstReconcileJournalPlan genesisJournal)
              (firstReconcileJournalCursor genesisJournal)
          )
      )
  receipt = mustRight (mkFirstReconcileReceipt member "version-1" "backup-member-read-back")

intentParameters :: GenesisAwsAdminIntentParameters
intentParameters =
  GenesisAwsAdminIntentParameters
    ( mustRight
        ( mkAuthorityBackupIamParameters
            (fixtureAwsRegion FixtureUsWest2)
            "prodbox-retained"
            ["authority-backup-store/home"]
        )
    )
    ("sha256:" <> Text.replicate 64 "a")
    "home"
    "http://lifecycle-authority.lifecycle-authority.svc:8600"
    agent
    deadline

genesisOutbox
  , foreignGenesisOutbox
  , repairOutbox
  , normalBackupOutbox
    :: PreparedCredentialTargetOutbox
genesisOutbox = genesisOutboxFor genesisPlan
foreignGenesisOutbox = genesisOutboxFor (GenesisPlan "foreign-genesis-plan" "authority-backup-store/home")
repairOutbox = mustRight (mkPreparedCredentialTargetOutbox canonical)
 where
  draft = mustRight (compileRepairAwsAdminIntent intentParameters repairPermit)
  owner = "aws-admin-" <> operatorMaterialOperationIdText (awsAdminPermitIntentOperationId draft)
  canonical = mustRight (bindAwsAdminPermitIntentPreparedTarget Nothing Nothing deadline owner 2 agent draft)
normalBackupOutbox = mustRight (mkPreparedCredentialTargetOutbox canonical)
 where
  draft =
    mustRight
      ( compileNormalAwsAdminIntentForScope
          intentParameters
          "ordinary-backup"
          AuthorityBackupStoreCredential
          RotateOperatorMaterial
          1
          (genesisIntentIamParameters intentParameters)
      )
  owner = "aws-admin-" <> operatorMaterialOperationIdText (awsAdminPermitIntentOperationId draft)
  canonical = mustRight (bindAwsAdminPermitIntentPreparedTarget Nothing Nothing deadline owner 1 agent draft)

genesisOutboxFor :: GenesisPlan -> PreparedCredentialTargetOutbox
genesisOutboxFor plan = mustRight (mkPreparedCredentialTargetOutbox canonical)
 where
  firstPlan = firstReconcileJournalPlan genesisJournal
  member =
    fromJust
      (mustRight (nextFirstReconcileMember firstPlan (firstReconcileJournalCursor genesisJournal)))
  binding =
    mkFirstReconcilePermitBinding
      (firstReconcilePlanDigest firstPlan)
      0
      (firstReconcilePlanMemberDigest member)
      Nothing
  draft = mustRight (compileGenesisAwsAdminIntent intentParameters plan)
  owner = "aws-admin-" <> operatorMaterialOperationIdText (awsAdminPermitIntentOperationId draft)
  canonical =
    mustRight
      ( bindAwsAdminPermitIntentPreparedTarget
          (Just (plan, member))
          (Just binding)
          deadline
          owner
          1
          agent
          draft
      )

repairPermit, foreignRepairPermit :: BackupRepairPermit
repairPermit =
  compileBackupRepairPermit
    "authority-backup-store/home"
    authorityEpochGenesis
    productionGeneration
    productionBackup
foreignRepairPermit =
  compileBackupRepairPermit
    "authority-backup-store/foreign"
    authorityEpochGenesis
    productionGeneration
    productionBackup

productionGeneration :: TargetAgentGenerationReceipt
productionGeneration = TargetAgentGenerationReceipt "aws-admin-target-v1:1:1:commitment:request-digest"

productionBackup :: BackupReceipt
productionBackup = BackupReceipt (Text.replicate 64 "b")

temporaryRepair :: AuthorityAdmissionAggregate
temporaryRepair =
  applyEpochAggregateCommand
    established
    (ApplyAuthorityBackupRepair (AssessBackupHealth BackupPositivelyAbsent))
 where
  established =
    foldl
      applyEpochAggregateCommand
      genesisEstablishing
      [ ApplyAuthorityGenesis (ObserveTargetAgentGeneration productionGeneration)
      , ApplyAuthorityGenesis (ObserveBackupReceipt productionBackup)
      ]

repairFrozenWith :: BackupRepairPermit -> AuthorityAdmissionAggregate
repairFrozenWith permit =
  applyEpochAggregateCommand temporaryRepair (ApplyAuthorityBackupRepair (BeginBackupRepair permit))

refusalOf :: Either TargetIntentIssueError IssuedTargetIntent -> Maybe TargetIntentIssueError
refusalOf = either Just (const Nothing)

permitRefusal
  :: Either TargetIntentIssueError SignedTargetWorkerExecutionPermit -> Maybe TargetIntentIssueError
permitRefusal = either Just (const Nothing)

request :: TargetIntentIssueRequest
request =
  TargetIntentIssueRequest
    TargetAcmeEab
    agent
    generation
    digest
    "frozen-operation"
    0
    "frozen-idempotency"

preparedIntent :: AuthorizedPreparedTargetIntent
preparedIntent =
  mustRight
    ( mkAuthorizedPreparedTargetIntent
        (mustRight (mkOwnerNonce "frozen-owner"))
        (mustRight (mkFencingToken 1))
        agent
        TargetAcmeEab
        generation
        digest
        deadline
    )

agent :: TargetAgentIdentity
agent = mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "a"))

generation :: CredentialGeneration
generation = mustRight (mkCredentialGeneration 1)

digest :: TargetValueDigest
digest = sha256TargetValueDigest "public-receipt-coordinate"

now, deadline :: AuthorityTime
now = authorityTimeFromMicros 100
deadline = authorityTimeFromMicros 1000

privateKey :: Ed25519.SecretKey
privateKey = case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
  CryptoPassed key -> key
  CryptoFailed _ -> error "fixture key invalid"

publicKey :: Ed25519.PublicKey
publicKey = Ed25519.toPublic privateKey

executionInputs
  :: IssuedTargetIntent -> (TargetAgentRolloutEvidence, TargetWorkerAttestation, ServiceSessionBinding)
executionInputs issued = (rollout, attestation, session)
 where
  target = acceptedTargetId (issuedTargetAcceptedAuthority issued)
  schema = mustRight (targetWorkerSchemaForTarget target)
  image = mustRight (mkTargetWorkerImageDigest ("sha256:" <> Text.replicate 64 "a"))
  intent =
    mustRight
      ( prepareTargetWorkerIntent
          (issuedTargetAcceptedAuthority issued)
          now
          agent
          target
          schema
          image
          (encodeSignedTargetCommittedIntent (issuedTargetSignedIntent issued))
      )
  rollout =
    mustRight
      ( mkTargetAgentRolloutEvidence
          agent
          "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
          1
          1
          ("sha256:" <> Text.replicate 64 "a")
      )
  observation =
    RawTargetWorkerPodObservation
      { observedTargetWorkerJobName = targetWorkerIntentJobName intent
      , observedTargetWorkerJobUid = "job-uid-123"
      , observedTargetWorkerPodName = "target-secret-worker-pod"
      , observedTargetWorkerPodUid = "aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
      , observedTargetWorkerImageDigest = targetWorkerImageDigestText image
      , observedTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
      , observedTargetWorkerServiceAccountUid = "aaaaaaaa-bbbb-cccc-dddd-111111111111"
      , observedTargetWorkerTarget = targetSecretIdToken target
      , observedTargetWorkerAgentIdentity = targetAgentIdentityText agent
      , observedTargetWorkerSchema = targetWorkerSchemaToken schema
      , observedTargetWorkerRequestDigest = targetValueDigestText (targetWorkerIntentRequestDigest intent)
      , observedTargetWorkerDeadlineMicros = 1000
      , observedTargetWorkerPhase = "Running"
      , observedTargetWorkerReady = True
      , observedTargetWorkerRestartCount = 0
      , observedTargetWorkerDeletionTimestamp = Nothing
      }
  attestation = mustRight (attestTargetWorkerPod now intent observation)
  session =
    mustRight
      ( mkServiceSessionBinding
          targetSecretWorkerVaultRole
          (targetWorkerSessionOperationId intent)
          (targetWorkerSessionAttemptId rollout attestation)
          1
      )

cutoverPrefixes :: [AuthorityAdmissionAggregate]
cutoverPrefixes = scanl apply importedFrozenEpochAggregate (epochPromotionCommands 1 2)
 where
  apply aggregate command = applyEpochAggregateCommand aggregate (ApplyAuthorityMigration command)

frozen, opened, cleanOpen, legacyOpen :: AuthorityAdmissionAggregate
frozen =
  foldl
    (\aggregate command -> applyEpochAggregateCommand aggregate (ApplyAuthorityMigration command))
    importedFrozenEpochAggregate
    (committedEpochCommands 1 2)
opened = last cutoverPrefixes
cleanOpen = establish (mustRight (initialCleanInstallAuthority 4 8))
legacyOpen = establish (mustRight (initialMigratingAuthority 4 8))

establish :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
establish aggregate =
  foldl
    applyEpochAggregateCommand
    aggregate
    [ ApplyAuthorityGenesis
        (BeginGenesisEstablishment (GenesisPlan "target-issuance-proof" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]

closedAuthorities :: [(String, AuthorityAdmissionAggregate, AuthoritySubmissionGateRefusal)]
closedAuthorities =
  [ ("genesis freeze", mustRight (initialCleanInstallAuthority 4 8), AuthorityGenesisFrozen)
  ,
    ( "genesis establishment"
    , applyEpochAggregateCommand
        (mustRight (initialCleanInstallAuthority 4 8))
        ( ApplyAuthorityGenesis
            (BeginGenesisEstablishment (GenesisPlan "target-issuance-proof" "backup-prefix"))
        )
    , AuthorityGenesisEstablishing
    )
  ,
    ( "backup repair"
    , applyEpochAggregateCommand
        cleanOpen
        (ApplyAuthorityBackupRepair (AssessBackupHealth BackupTemporarilyUnavailable))
    , AuthorityBackupRepairFrozen
    )
  , ("decommission freeze", decommissionFrozen, AuthorityDecommissionAdmissionFrozen)
  , ("permanent stop", stopped, AuthorityDecommissionPermanentlyStopped)
  ]
 where
  decommissionFrozen = snd (freezeAuthorityForDecommission cleanOpen)
  stopped =
    snd
      ( permanentlyStopAuthorityForDecommission
          (FrameDigest (ByteString.replicate 32 1))
          (FrameDigest (ByteString.replicate 32 2))
          decommissionFrozen
      )

mustRight :: (Show failure) => Either failure value -> value
mustRight = either (error . show) id

mustRightIO :: (Show failure) => Either failure value -> IO value
mustRightIO = either (fail . show) pure
