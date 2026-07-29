{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneAuthorityBackupEndpoint (controlPlaneAuthorityBackupEndpointSuite) where

import Data.IORef
import Prodbox.ControlPlane.AuthorityBackupEndpoint
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (ControlPlaneRequestInvalid, ControlPlaneRequestTooLarge)
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.BackupRepair
  ( BackupHealth (BackupHealthy, BackupPositivelyAbsent)
  , BackupRepairCommand (AssessBackupHealth, BeginBackupRepair)
  , BackupRepairDecision (BackupRepairFroze, BackupRepairNotNeeded, BackupRepairRefused)
  , BackupRepairRefusal (BackupRepairBeforeGenesis)
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (BackupEstablished)
  , BackupRepairPermit (BackupRepairPermit)
  , admitsNormalOperations
  , authorityEpochGenesis
  , initialGenesisState
  )
import TestSupport

controlPlaneAuthorityBackupEndpointSuite :: SuiteBuilder ()
controlPlaneAuthorityBackupEndpointSuite =
  describe "Sprint 4.50 Authority Backup role endpoint" $ do
    it "treats a healthy backup while established as a no-op" $ do
      (repository, stateRef) <- freshRepository established1
      result <- serveBackupCopy repository (AssessBackupHealth BackupHealthy)
      resultDecision result `shouldBe` Just BackupRepairNotNeeded
      authorityBackupHttpStatus result `shouldBe` 200
      authorityBackupSummary result `shouldBe` "backup-not-needed"
      (admitsNormalOperations <$> readIORef stateRef) `shouldReturn` True
    it "freezes admission and commits the new state on a non-healthy reading" $ do
      (repository, stateRef) <- freshRepository established1
      result <- serveBackupCopy repository (AssessBackupHealth BackupPositivelyAbsent)
      authorityBackupHttpStatus result `shouldBe` 200
      authorityBackupSummary result `shouldBe` "backup-froze"
      case resultDecision result of
        Just (BackupRepairFroze _) -> pure ()
        other -> expectationFailure ("expected a freeze decision, got " <> show other)
      (admitsNormalOperations <$> readIORef stateRef) `shouldReturn` False
    it "refuses a repair command before genesis without committing" $ do
      (repository, stateRef) <- freshRepository initialGenesisState
      result <- serveBackupCopy repository (BeginBackupRepair samplePermit)
      resultDecision result `shouldBe` Just (BackupRepairRefused BackupRepairBeforeGenesis)
      authorityBackupHttpStatus result `shouldBe` 409
      authorityBackupSummary result `shouldBe` "backup-refused:before-genesis"
      readIORef stateRef `shouldReturn` initialGenesisState
    it "reports a failed durable commit as a retryable write failure" $ do
      stateRef <- newIORef established1
      let repository = inMemoryRepository stateRef True
      result <- serveBackupCopy repository (AssessBackupHealth BackupPositivelyAbsent)
      authorityBackupHttpStatus result `shouldBe` 503
      authorityBackupSummary result `shouldBe` "backup-write-failed"
    it "observes the current admission state without mutating it" $ do
      (repository, _) <- freshRepository established1
      observed <- serveBackupObserve repository
      observed `shouldBe` established1
    it "round-trips a backup command through the shared request codec" $ do
      let command = AssessBackupHealth BackupPositivelyAbsent
      decodeControlPlaneRequest 4096 (encodeControlPlaneRequest command)
        `shouldBe` Right command
    it "serveBackupCopyRequest decodes a well-formed body and applies it" $ do
      (repository, stateRef) <- freshRepository established1
      let body = encodeControlPlaneRequest (AssessBackupHealth BackupPositivelyAbsent)
      result <- serveBackupCopyRequest 4096 repository body
      authorityBackupHttpStatus result `shouldBe` 200
      authorityBackupSummary result `shouldBe` "backup-froze"
      (admitsNormalOperations <$> readIORef stateRef) `shouldReturn` False
    it "serveBackupCopyRequest refuses a malformed body before reading state" $ do
      (repository, stateRef) <- freshRepository established1
      result <- serveBackupCopyRequest 4096 repository "not-a-cbor-envelope"
      result `shouldBe` AuthorityBackupBadRequest ControlPlaneRequestInvalid
      authorityBackupHttpStatus result `shouldBe` 400
      authorityBackupSummary result `shouldBe` "backup-bad-request:invalid"
      readIORef stateRef `shouldReturn` established1
    it "serveBackupCopyRequest refuses an oversized body before reading state" $ do
      (repository, stateRef) <- freshRepository established1
      let body = encodeControlPlaneRequest (AssessBackupHealth BackupPositivelyAbsent)
      result <- serveBackupCopyRequest 2 repository body
      result `shouldBe` AuthorityBackupBadRequest ControlPlaneRequestTooLarge
      authorityBackupHttpStatus result `shouldBe` 400
      authorityBackupSummary result `shouldBe` "backup-bad-request:too-large"
      readIORef stateRef `shouldReturn` established1
 where
  established1 = BackupEstablished authorityEpochGenesis
  samplePermit = BackupRepairPermit "repair-digest" "authority-backup-store/home/repair"
  freshRepository initial = do
    stateRef <- newIORef initial
    pure (inMemoryRepository stateRef False, stateRef)

resultDecision :: AuthorityBackupEndpointResult -> Maybe BackupRepairDecision
resultDecision result = case result of
  AuthorityBackupDecided decision -> Just decision
  AuthorityBackupWriteFailed _ -> Nothing
  AuthorityBackupBadRequest _ -> Nothing

inMemoryRepository :: IORef AuthorityAdmissionState -> Bool -> AuthorityBackupRepository IO
inMemoryRepository stateRef failWrites =
  AuthorityBackupRepository
    { readAdmissionState = readIORef stateRef
    , commitAdmissionState = \state ->
        if failWrites
          then pure (Left "retained-store commit failed")
          else do
            writeIORef stateRef state
            pure (Right ())
    }
