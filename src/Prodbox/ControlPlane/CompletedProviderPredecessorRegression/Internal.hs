{-# LANGUAGE OverloadedStrings #-}

module Prodbox.ControlPlane.CompletedProviderPredecessorRegression.Internal
  ( fixedCompletedProviderPredecessorRegression
  ) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Monad (forM, unless)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityBackupClient
import Prodbox.ControlPlane.AuthorityBackupEndpoint
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( modelBCleanupProgramDescriptorRepository
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.CompletedProviderPredecessor
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry (mkClientSubmissionKey)
import Prodbox.Lifecycle.Authority.CompletedProviderPredecessor
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.CheckpointAuthority
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
import Prodbox.Lifecycle.TargetCommitIntent
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
import Prodbox.Lifecycle.Teardown.Model (evidenceCleanupSurface)
import Prodbox.Lifecycle.Teardown.Observation (terminalAuditEvidenceScopeDigest)
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForCascadeTerminalAudit)

-- The fixture supplies ordinary descriptor/run metadata. The real repository
-- owner commits and re-reads the descriptor; only the production observer can
-- produce the transient proof. Diagnostics return decided facts, never proof.
fixedCompletedProviderPredecessorRegression
  :: CleanupProgramDescriptor -> CleanupRun -> IO (Either Text [(Text, Bool)])
fixedCompletedProviderPredecessorRegression descriptor terminal = runExceptT $ do
  report <- checked (compactCleanupRun terminal)
  bytes <- checked (encodeCleanupRunReport limit report)
  descriptors <- descriptorFixture descriptor
  committed <-
    ExceptT
      ( fmap
          (first (Text.pack . show))
          ( independentlyReadBackCommittedCleanupProgramDescriptor
              descriptors
              (cleanupProgramDescriptorRunId descriptor)
          )
      )
  scope <- checked (committedCleanupProgramDescriptorObservationScope committed)
  scopeDigest <-
    checked (mkCleanupDigest (terminalAuditEvidenceScopeDigest (scopeForCascadeTerminalAudit scope)))
  let runId = cleanupProgramDescriptorRunId descriptor
      descriptorDigest = cleanupProgramDescriptorDigest descriptor
      graphDigest = cleanupProgramDescriptorGraphDigest descriptor
      coordinates = ProviderPredecessorCoordinates runId descriptorDigest graphDigest scopeDigest
      digest = cleanupDigestOfBytes bytes
      present = DescriptorBoundCleanupRunObserved (0 :: Int) descriptorDigest terminal
      tombstoneFor body =
        DescriptorBoundCleanupRunTombstoned
          1
          descriptorDigest
          (CleanupRunTombstone runId (cleanupDigestText (cleanupDigestOfBytes body)))
      tombstone = tombstoneFor bytes
  backup <- backupFixture bytes
  (runs, _) <- liftIO (runFixture present)
  proof <-
    ExceptT
      ( fmap
          (first (Text.pack . show))
          (observeCompletedProviderPredecessor descriptors runs backup coordinates)
      )
  archived <- liftIO $ do
    (stored, _) <- runFixture tombstone
    observeCompletedProviderPredecessor descriptors stored backup coordinates
  changedBytes <-
    checked
      ( encodeCleanupRunReport
          limit
          report {cleanupReportPrimaryOutcome = CleanupPrimaryFailed "fixture primary failure"}
      )
  changedBackup <- backupFixture changedBytes
  badNodesBytes <-
    checked
      ( encodeCleanupRunReport
          limit
          report {cleanupReportNodeStates = Map.deleteMin (cleanupReportNodeStates report)}
      )
  badNodesBackup <- backupFixture badNodesBytes
  blockedBytes <-
    checked
      ( encodeCleanupRunReport
          limit
          report
            { cleanupReportNodeStates = Map.map (const (CleanupNodeBlocked [])) (cleanupReportNodeStates report)
            }
      )
  blockedBackup <- backupFixture blockedBytes
  expectedDigest <- checked (mkAuthorityBackupDigest (cleanupDigestText digest))
  correctBody <- checked (mkAuthorityBackupCiphertext bytes)
  wrongBody <- checked (mkAuthorityBackupCiphertext "fixture body substitution")
  let withResponse response = backup {observeAuthorityAggregateBackup = const (pure response)}
      wrongReceipt = AuthorityBackupReceipt AuthorityCheckpointBlob expectedDigest "fixture-version"
      matchingReceipt = AuthorityBackupReceipt AuthorityAggregateEnvelope expectedDigest "fixture-version"
  archivedCases <- forM
    [ ("archived report is observed", tombstone, backup, Nothing)
    ,
      ( "missing archive refuses"
      , tombstone
      , withResponse (Right AuthorityAggregateBackupMissing)
      , Just CompletedProviderPredecessorBackupMissing
      )
    ,
      ( "corrupt archive refuses"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCorrupt "fixture corrupt"))
      , Just CompletedProviderPredecessorBackupCorrupt
      )
    ,
      ( "unobservable archive refuses"
      , tombstone
      , withResponse (Left (AuthorityAggregateBackupCiphertextInvalid "fixture unavailable"))
      , Just CompletedProviderPredecessorBackupUnavailable
      )
    ,
      ( "wrong receipt class refuses"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCurrent correctBody wrongReceipt))
      , Just CompletedProviderPredecessorBackupReceiptMismatch
      )
    ,
      ( "matching receipt cannot bless substituted bytes"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCurrent wrongBody matchingReceipt))
      , Just CompletedProviderPredecessorReportDigestMismatch
      )
    ,
      ( "incomplete archived node set refuses"
      , tombstoneFor badNodesBytes
      , badNodesBackup
      , Just CompletedProviderPredecessorNodeSetMismatch
      )
    ,
      ( "blocked archived nodes refuse"
      , tombstoneFor blockedBytes
      , blockedBackup
      , Just CompletedProviderPredecessorNodeNotSuccessful
      )
    ,
      ( "successful cleanup preserves independently failed primary"
      , tombstoneFor changedBytes
      , changedBackup
      , Nothing
      )
    ]
    $ \(name, snapshot, archive, expected) -> do
      (stored, _) <- liftIO (runFixture snapshot)
      answer <- liftIO (observeCompletedProviderPredecessor descriptors stored archive coordinates)
      pure
        ( name
        , case expected of Nothing -> isRight answer; Just cause -> either (== cause) (const False) answer
        )
  raceCases <- forM [False, True] $ \changeReport -> do
    (stored, state) <- liftIO (runFixture present)
    counter <- liftIO (newIORef (0 :: Int))
    let racing =
          stored
            { readDescriptorBoundCleanupRun = do
                n <- atomicModifyIORef' counter (\old -> (old + 1, old + 1))
                if n == 2
                  then writeIORef state (if changeReport then tombstoneFor changedBytes else tombstone)
                  else pure ()
                readDescriptorBoundCleanupRun stored
            }
    answer <-
      liftIO
        ( observeCompletedProviderPredecessor
            descriptors
            racing
            (if changeReport then changedBackup else backup)
            coordinates
        )
    pure
      ( if changeReport
          then "changed report between reads refuses"
          else "compaction between reads preserves completion"
      , if changeReport
          then either (== CompletedProviderPredecessorChanged) (const False) answer
          else isRight answer
      )
  closingCase <- do
    counter <- liftIO (newIORef (0 :: Int))
    let unavailableRuns =
          runs
            { readDescriptorBoundCleanupRun = do
                n <- atomicModifyIORef' counter (\old -> (old + 1, old + 1))
                if n == 2
                  then pure (Left "fixture closing read unavailable")
                  else readDescriptorBoundCleanupRun runs
            }
    answer <-
      liftIO (observeCompletedProviderPredecessor descriptors unavailableRuns backup coordinates)
    pure
      ( "closing run read cannot reuse first proof"
      , either (== CompletedProviderPredecessorRunUnavailable) (const False) answer
      )
  mismatches <- forM
    [ coordinates
        { providerPredecessorDescriptorDigest = cleanupDigestOfBytes "fixture foreign descriptor"
        }
    , coordinates {providerPredecessorGraphDigest = cleanupDigestOfBytes "fixture foreign graph"}
    , coordinates {providerPredecessorScopeDigest = cleanupDigestOfBytes "fixture foreign scope"}
    ]
    $ \foreignCoordinates -> do
      answer <- liftIO (observeCompletedProviderPredecessor descriptors runs backup foreignCoordinates)
      pure ("foreign descriptor graph or scope refuses", isLeft answer)
  aggregate <- checked (aggregateCases coordinates proof)
  endpointCases <- forM
    [ ("live terminal report", present, backup, True)
    , ("compacted terminal report", tombstone, backup, True)
    , ("missing compacted report", tombstone, withResponse (Right AuthorityAggregateBackupMissing), False)
    ,
      ( "corrupt compacted report"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCorrupt "fixture corrupt"))
      , False
      )
    ,
      ( "unobservable compacted report"
      , tombstone
      , withResponse (Left (AuthorityAggregateBackupCiphertextInvalid "fixture unavailable"))
      , False
      )
    ,
      ( "wrong compacted receipt class"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCurrent correctBody wrongReceipt))
      , False
      )
    ,
      ( "substituted compacted bytes"
      , tombstone
      , withResponse (Right (AuthorityAggregateBackupCurrent wrongBody matchingReceipt))
      , False
      )
    , ("incomplete compacted node set", tombstoneFor badNodesBytes, badNodesBackup, False)
    , ("nonterminal compacted nodes", tombstoneFor blockedBytes, blockedBackup, False)
    , ("failed primary with completed cleanup", tombstoneFor changedBytes, changedBackup, True)
    ]
    $ \(name, snapshot, archive, succeeds) -> do
      (stored, _) <- liftIO (runFixture snapshot)
      let provider =
            CleanupRunRepositoryProvider
              { cleanupRunRepositoryFor =
                  const
                    ( CleanupRunRepository
                        (pure (Left "must not read legacy state"))
                        (\_ _ -> pure (Left "must not mutate legacy state"))
                        (\_ _ -> pure (Left "must not mutate legacy tombstone"))
                    )
              , descriptorBoundCleanupRunRepositoryFor = const stored
              , cleanupRunIndexRepository =
                  CleanupRunIndexRepository
                    (pure (Left "must not read index"))
                    (\_ _ -> pure (Left "must not mutate index"))
              , cleanupRunAggregateBackup = archive
              , cleanupProgramDescriptorAuthorityClient = Just descriptors
              }
      answer <-
        liftIO
          ( serveCleanupRunRequest
              provider
              ( encodeControlPlaneRequest
                  ( CleanupRunDescriptorBound
                      (CleanupRunDescriptorObserveCompletion (cleanupRunIdText runId) (cleanupDigestText descriptorDigest))
                  )
              )
          )
      pure
        ( "read-only completion endpoint " <> name
        , case answer of
            CleanupRunEndpointDescriptorBound (CleanupRunDescriptorCompacted rawDigest body) ->
              succeeds
                && rawDigest == cleanupDigestText descriptorDigest
                && either
                  (const False)
                  ((== graphDigest) . cleanupReportGraphDigest)
                  (decodeCleanupRunReport limit body)
            _ -> not succeeds
        )
  pure
    ( [
        ( "current report is independently observed"
        , completedProviderPredecessorReportDigest proof == digest
        )
      ,
        ( "compacted report preserves exact digest"
        , either (const False) ((== digest) . completedProviderPredecessorReportDigest) archived
        )
      , ("descriptor remains a cascade", show (evidenceCleanupSurface scope) == "Cascade")
      ]
        ++ archivedCases
        ++ raceCases
        ++ [closingCase]
        ++ mismatches
        ++ aggregate
        ++ endpointCases
    )
 where
  limit = 1024 * 1024

checked :: (Show cause) => Either cause value -> ExceptT Text IO value
checked = ExceptT . pure . first (Text.pack . show)

descriptorFixture
  :: CleanupProgramDescriptor -> ExceptT Text IO (CleanupProgramDescriptorAuthorityClient IO)
descriptorFixture descriptor = do
  authority <-
    checked
      ( mkLongLivedCheckpointAuthority
          "fixture-cluster"
          "fixture-bucket"
          "fixture-namespace"
          "fixture-vault"
      )
  state <- liftIO (newIORef ModelBMissing)
  version <- checked (mkModelBObjectVersion "fixture-v1")
  let apply request = case request of
        ModelBInitialize _ bytes -> do
          old <- readIORef state
          case old of
            ModelBMissing -> writeIORef state (ModelBObserved version bytes) >> pure (ModelBCasApplied version bytes)
            _ -> pure (ModelBCasConflict old)
        _ -> pure (ModelBCasUnobservable "fixture unexpected mutation")
      adapter = ModelBCasAdapter (\_ -> readIORef state) apply
      client = modelBCleanupProgramDescriptorRepository authority adapter
  committed <- liftIO (commitCleanupProgramDescriptorAttempt client descriptor)
  unless
    (committed == CleanupProgramDescriptorCommitCreated)
    (throwE "fixture descriptor commit refused")
  _ <-
    ExceptT
      ( fmap
          (first (Text.pack . show))
          ( independentlyReadBackCommittedCleanupProgramDescriptor
              client
              (cleanupProgramDescriptorRunId descriptor)
          )
      )
  pure client

runFixture
  :: DescriptorBoundCleanupRunSnapshot Int
  -> IO (DescriptorBoundCleanupRunRepository IO Int, IORef (DescriptorBoundCleanupRunSnapshot Int))
runFixture initial = do
  state <- newIORef initial
  pure
    ( DescriptorBoundCleanupRunRepository
        (Right <$> readIORef state)
        (\_ _ _ -> pure (Left "fixture read-only run"))
        (\_ _ _ -> pure (Left "fixture read-only tombstone"))
    , state
    )

backupFixture :: BS.ByteString -> ExceptT Text IO (AuthorityAggregateBackupClient IO)
backupFixture bytes = do
  digest <- checked (mkAuthorityBackupDigest (cleanupDigestText (cleanupDigestOfBytes bytes)))
  ciphertext <- checked (mkAuthorityBackupCiphertext bytes)
  pure
    ( AuthorityAggregateBackupClient
        (\_ -> pure (Left (AuthorityAggregateBackupCiphertextInvalid "fixture copy disabled")))
        ( \_ ->
            pure
              ( Right
                  ( AuthorityAggregateBackupCurrent
                      ciphertext
                      (AuthorityBackupReceipt AuthorityAggregateEnvelope digest "fixture-version")
                  )
              )
        )
    )

aggregateCases
  :: ProviderPredecessorCoordinates -> ObservedCompletedProviderPredecessor -> Either Text [(Text, Bool)]
aggregateCases coordinates proof = do
  initial <- firstShow (initialCleanInstallAuthority 1 1)
  node <- firstShow (mkCleanupNodeId "predecessor/audit")
  operation <- firstShow (mkCleanupOperationId "predecessor/audit")
  attempt <- firstShow (mkCleanupAttemptId "predecessor/audit")
  key <- firstShow (mkClientSubmissionKey "predecessor/audit")
  let ProviderPredecessorCoordinates run descriptor graph scope = coordinates
  binding <-
    firstShow
      ( mkCascadeAuditFreezeBinding
          run
          descriptor
          graph
          (cleanupDigestText scope)
          node
          operation
          attempt
          [key]
      )
  audit <-
    firstShow
      ( mkCascadeTerminalAuditReceipt
          (cleanupDigestText scope)
          (cleanupDigestText (cleanupDigestOfBytes "fixture query"))
          (cleanupDigestText (cleanupDigestOfBytes "fixture retained"))
          CascadeTerminalAuditReceiptClean
      )
  receipt <-
    firstShow
      ( mkProviderCredentialRevocationReceipt
          (cleanupDigestOfBytes "fixture iam")
          (cleanupDigestOfBytes "fixture target")
      )
  op <- firstShow (mkOperatorMaterialOperationId "predecessor/new-install")
  generation <- firstShow (mkCredentialGeneration 1)
  digest <-
    firstShow (mkTargetValueDigest (cleanupDigestText (cleanupDigestOfBytes "fixture request")))
  reservation <-
    firstShow (mkProviderCredentialMutationReservation InstallOperatorMaterial op generation digest)
  let step aggregate command = snd (stepAuthorityAdmission aggregate command)
      open =
        foldl
          step
          initial
          [ ApplyAuthorityGenesis (BeginGenesisEstablishment (GenesisPlan "fixture-plan" "fixture-backup"))
          , ApplyAuthorityGenesis (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "fixture-target"))
          , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "fixture-backup"))
          ]
      frozen = step open (FreezeProviderAdmissionAtGeneration 7 binding)
      recorded = step frozen (RecordCascadeTerminalAuditReceipt binding audit)
      revoked = step recorded (RevokeCascadeProviderCredential binding receipt)
  (pending, archive) <-
    firstShow (reserveAuthorityProviderCredentialMutationAfterPredecessor revoked reservation proof)
  bytes <- encodeProviderCredentialLineageArchive archive
  pure
    [
      ( "ordinary reserve cannot bypass completed predecessor evidence"
      , reserveAuthorityProviderCredentialMutation revoked reservation
          == Left AuthorityCredentialMutationPredecessorCompletionRequired
      )
    ,
      ( "observed predecessor binds all four coordinates"
      , authorityAggregateProviderPredecessorCoordinates revoked == Just coordinates
      )
    ,
      ( "frozen recovery metadata remains closed"
      , authorityAggregateProviderCredentialRecoveryView frozen == ProviderCredentialRecoveryClosed
      )
    ,
      ( "recorded recovery metadata preserves the generation for final revoke"
      , authorityAggregateProviderCredentialRecoveryView recorded == ProviderCredentialRecoveryRecorded 7
      )
    ,
      ( "revoked recovery metadata preserves server-owned successor proof"
      , authorityAggregateProviderCredentialRecoveryView revoked == ProviderCredentialRecoveryRevoked
      )
    ,
      ( "observed predecessor admits exact successor"
      , authorityAggregatePendingCredentialArchive pending == Just archive
      )
    ,
      ( "observed predecessor reservation replay is exact"
      , reserveAuthorityProviderCredentialMutationAfterPredecessor pending reservation proof
          == Right (pending, archive)
      )
    ,
      ( "predecessor proof cannot install before revocation"
      , isLeft (reserveAuthorityProviderCredentialMutationAfterPredecessor recorded reservation proof)
      )
    ,
      ( "predecessor proof cannot bypass genesis"
      , isLeft (reserveAuthorityProviderCredentialMutationAfterPredecessor initial reservation proof)
      )
    ,
      ( "new archive remains bounded and canonical"
      , BS.length bytes <= 65536 && decodeProviderCredentialLineageArchive bytes == Right archive
      )
    , ("new pending aggregate round-trips", deserialiseOrFail (serialise pending) == Right pending)
    ,
      ( "successor archive retains the independently observed report digest"
      , providerCredentialLineageArchiveCompletedReportDigest archive
          == Just (completedProviderPredecessorReportDigest proof)
      )
    ]
 where
  firstShow :: (Show cause) => Either cause value -> Either Text value
  firstShow = first (Text.pack . show)
