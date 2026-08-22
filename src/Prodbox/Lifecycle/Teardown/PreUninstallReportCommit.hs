{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the production writer half of Stage C.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- gives the Authority two acts on the writing side: it commits the complete
-- pre-uninstall cleanup report, and it signs the one-shot local-completion
-- permit.  "Prodbox.Lifecycle.Teardown.PreUninstallReadiness" states both as one
-- injected boundary and deliberately owns no client; this module is the join
-- between that boundary, the Authority's retained namespace
-- ("Prodbox.ControlPlane.CascadeReportRepository"), and the independent Backup
-- Adapter the reader then asks
-- ("Prodbox.ControlPlane.CleanupReportBackupClient").
--
-- Five properties carry the design.
--
--   * __The bytes and the identity are checked against each other before
--     anything is written.__  A commit is asked for one 'CascadeReportDigest',
--     and this module holds the report bytes that digest is supposed to name.
--     If they do not hash to it the commit refuses, so the Authority never
--     records an identity the replicated bytes do not have and the independent
--     read-back is never set up to confirm a name nothing produces.
--
--   * __The Authority write comes first and the replication second.__  The
--     order is what makes an interrupted commit recoverable: an identity the
--     Authority holds with no copy beside it is a run that can retry the copy,
--     while a copy with no Authority record is an object nothing refers to.
--
--   * __A failed replication is a lost response, not a refusal.__  The copy is
--     a write whose outcome this module cannot decide — a transport failure may
--     have landed, and the adapter's own read-back mismatch may be a race with
--     a concurrent identical copy.  Stage C reads the report back after /every/
--     commit outcome precisely so the observation arbitrates, and reporting a
--     definite refusal here would decide it from the weaker fact.
--
--   * __The permit that is returned is the durable one.__  After the write the
--     slot is read back and the grant is rebuilt from what the Authority holds,
--     so a grant that was never recorded cannot reach
--     'Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal.bindLocalCompletionPermit'
--     just because a write reported success.
--
--   * __The permit is one-shot by construction.__  Its slot admits one write and
--     has no replace arm, and its id is derived from the run and the report
--     identity, so a second permit for a different report is a conflict rather
--     than a second key.  Two permits under one run would be two licences to
--     destroy the same host.
--
-- What this module does not own: the /content/ of the report, which belongs to
-- "Prodbox.Lifecycle.Teardown.Report"; the read-back, which is
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportBackup"; and the composition of
-- both into a running cascade, which is the non-public candidate entrypoint
-- Sprint @4.86@ still owns.
module Prodbox.Lifecycle.Teardown.PreUninstallReportCommit
  ( cascadeReportCommitBoundary
  , cascadeLocalCompletionPermitId

    -- * Regression over the package-private fixture
  , PreUninstallReportCommitRegression
  , fixedPreUninstallReportCommitRegression
  , reportCommitRegressionAppliedWhenBothLand
  , reportCommitRegressionForeignBytesRefused
  , reportCommitRegressionConflictRefused
  , reportCommitRegressionReplicationFailureIsResponseLost
  , reportCommitRegressionReplicationFollowsTheAuthority
  , reportCommitRegressionPermitIsBoundToTheReport
  , reportCommitRegressionPermitReplayIsTheDurableGrant
  , reportCommitRegressionSecondReportRefusesThePermit
  )
where

import Data.ByteString (ByteString)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityCleanupReportBlob)
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.CascadeReportRepository
  ( CascadeReportAuthorityClient
  , CascadeReportSlotResult (..)
  , commitCascadeReportAttempt
  , grantLocalCompletionPermitAttempt
  , modelBCascadeReportRepository
  , observeGrantedLocalCompletionPermit
  , renderCascadeReportRepositoryError
  , renderCascadeReportSlotResult
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient (..)
  , CleanupReportBackupClientError (CleanupReportBackupCiphertextInvalid)
  , renderCleanupReportBackupClientError
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun (CleanupRunId, cleanupRunIdText)
import Prodbox.Lifecycle.CleanupRun qualified as CleanupRun
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeLocalOperationReferences
  , CascadeReportDigest
  , LocalCompletionPermitGrant (..)
  , cascadeLocalOperationReferences
  , cascadeReportDigestText
  , mkCascadeReportDigest
  , mkLocalCompletionPermitId
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Execution (TeardownMutationResult (..))
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model (CleanupSurface (Cascade))
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( CascadeReportCommitBoundary (..)
  )

-- | The production Stage-C commit boundary.
--
-- It is an 'Either' because the compiled run's local operation references are
-- what a permit binds to, and a program that does not name them cannot license
-- a local uninstall at all — that is a refusal to construct the boundary, not a
-- refusal it should discover at commit time.
cascadeReportCommitBoundary
  :: CascadeReportAuthorityClient IO
  -> CleanupReportBackupClient IO
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> ByteString
  -- ^ The rendered pre-uninstall report bytes this run committed.
  -> Either Text (CascadeReportCommitBoundary IO)
cascadeReportCommitBoundary authority backup compiled reportBytes = do
  operations <-
    either (Left . Text.pack . show) Right (cascadeLocalOperationReferences compiled)
  Right
    CascadeReportCommitBoundary
      { commitPreUninstallReport = commit
      , grantLocalCompletionPermit = grant operations
      }
 where
  runId = compiledDesiredAbsenceRunId compiled

  commit askedDigest = case reportBytesIdentity reportBytes of
    Left detail ->
      pure
        ( TeardownMutationRefused
            ("the pre-uninstall report bytes are not committable: " <> detail)
        )
    Right actualDigest
      | actualDigest /= askedDigest ->
          pure
            ( TeardownMutationRefused
                ( "the pre-uninstall report identity `"
                    <> cascadeReportDigestText askedDigest
                    <> "` does not name the report bytes, which hash to `"
                    <> cascadeReportDigestText actualDigest
                    <> "`"
                )
            )
      | otherwise -> do
          recorded <- commitCascadeReportAttempt authority runId askedDigest
          case recorded of
            CascadeReportSlotWritten -> replicateReport
            CascadeReportSlotExactReplay -> replicateReport
            CascadeReportSlotConflict ->
              pure
                ( TeardownMutationRefused
                    ( "the Lifecycle Authority already committed a different "
                        <> "pre-uninstall report for this run"
                    )
                )
            CascadeReportSlotResponseLost _ ->
              pure (TeardownMutationResponseLost (renderCascadeReportSlotResult recorded))
            CascadeReportSlotUnavailable _ ->
              pure (TeardownMutationRefused (renderCascadeReportSlotResult recorded))

  replicateReport = do
    copied <- copyCleanupReportBackup backup reportBytes
    pure $ case copied of
      Right _ -> TeardownMutationApplied
      Left err ->
        TeardownMutationResponseLost
          ( "the pre-uninstall report was committed and its independent copy "
              <> "did not confirm: "
              <> renderCleanupReportBackupClientError err
          )

  grant operations digest = case cascadeLocalCompletionPermitId runId digest of
    Left detail -> pure (Left detail)
    Right permitIdText -> do
      granted <-
        grantLocalCompletionPermitAttempt authority runId permitIdText digest operations
      case granted of
        CascadeReportSlotConflict ->
          pure
            ( Left
                ( "the Lifecycle Authority already granted a different "
                    <> "local-completion permit for this run"
                )
            )
        CascadeReportSlotResponseLost _ ->
          pure (Left (renderCascadeReportSlotResult granted))
        CascadeReportSlotUnavailable _ ->
          pure (Left (renderCascadeReportSlotResult granted))
        CascadeReportSlotWritten -> durableGrant digest
        CascadeReportSlotExactReplay -> durableGrant digest

  durableGrant digest = do
    observed <- observeGrantedLocalCompletionPermit authority runId
    pure $ case observed of
      Left err -> Left (renderCascadeReportRepositoryError err)
      Right (permitIdText, durableDigest, durableOperations)
        | durableDigest /= digest ->
            Left
              ( "the durable local-completion permit names report `"
                  <> cascadeReportDigestText durableDigest
                  <> "`, not `"
                  <> cascadeReportDigestText digest
                  <> "`"
              )
        | otherwise -> case mkLocalCompletionPermitId permitIdText of
            Left detail -> Left detail
            Right permitId ->
              Right
                LocalCompletionPermitGrant
                  { localCompletionGrantPermitId = permitId
                  , localCompletionGrantRunId = runId
                  , localCompletionGrantScope =
                      compiledDesiredAbsenceObservationScope compiled
                  , localCompletionGrantGraphDigest =
                      CleanupRun.cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
                  , localCompletionGrantReportDigest = durableDigest
                  , localCompletionGrantOperationReferences = durableOperations
                  }

-- | The permit id one run may hold for one report identity.
--
-- Derived rather than supplied, and bound to the report digest, so a permit
-- can be recomputed by a rerun that lost its response and a permit for a
-- different report is visibly a different value in the same one-write slot.
cascadeLocalCompletionPermitId :: CleanupRunId -> CascadeReportDigest -> Either Text Text
cascadeLocalCompletionPermitId runId digest =
  Right
    ( "cascade-local-completion/"
        <> TextEncoding.decodeUtf8
          ( hexSha256
              ( TextEncoding.encodeUtf8
                  ( Text.concat
                      ( map
                          frame
                          [ "cascade-local-completion-permit/v1"
                          , cleanupRunIdText runId
                          , cascadeReportDigestText digest
                          ]
                      )
                  )
              )
          )
    )
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

-- | The identity a rendered report has, computed the same way the independent
-- adapter computes the name it stores the bytes under.
reportBytesIdentity :: ByteString -> Either Text CascadeReportDigest
reportBytesIdentity bytes = do
  ciphertext <- mkAuthorityBackupCiphertext bytes
  mkCascadeReportDigest (authorityBackupDigestText (authorityBackupCiphertextDigest ciphertext))

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without an Authority, a compiled
-- cascade program, a report digest, or a permit grant leaving this package.
data PreUninstallReportCommitRegression = PreUninstallReportCommitRegression
  { reportCommitRegressionAppliedWhenBothLand :: !Bool
  , reportCommitRegressionForeignBytesRefused :: !Bool
  , reportCommitRegressionConflictRefused :: !Bool
  , reportCommitRegressionReplicationFailureIsResponseLost :: !Bool
  , reportCommitRegressionReplicationFollowsTheAuthority :: !Bool
  , reportCommitRegressionPermitIsBoundToTheReport :: !Bool
  , reportCommitRegressionPermitReplayIsTheDurableGrant :: !Bool
  , reportCommitRegressionSecondReportRefusesThePermit :: !Bool
  }

-- | Run the commit boundary against an in-memory Authority slot store and an
-- in-memory independent copy target.
--
-- Every fault the boundary classifies is produced by actually running it
-- against the fault, rather than by asserting the classification: an arm the
-- protocol stops producing disappears from the result instead of surviving as
-- an authored constant.
fixedPreUninstallReportCommitRegression
  :: IO (Either Text PreUninstallReportCommitRegression)
fixedPreUninstallReportCommitRegression =
  case fixedCommitScenario of
    Left err -> pure (Left err)
    Right scenario -> runFixedCommitRegression scenario

data FixedCommitScenario = FixedCommitScenario
  { fixedCommitCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedCommitBytes :: !ByteString
  , fixedCommitDigest :: !CascadeReportDigest
  , fixedCommitOtherBytes :: !ByteString
  , fixedCommitOtherDigest :: !CascadeReportDigest
  , fixedCommitOperations :: !CascadeLocalOperationReferences
  }

fixedCommitScenario :: Either Text FixedCommitScenario
fixedCommitScenario = do
  compiled <-
    withCascadePreUninstallInputsInternal
      "cleanup-run/report-commit-fixed-regression"
      (\program _run _absence _credentials _audit _custody -> program)
  let bytes = "fixed-pre-uninstall-report-bytes"
      otherBytes = "a-different-pre-uninstall-report"
  digest <- reportBytesIdentity bytes
  otherDigest <- reportBytesIdentity otherBytes
  operations <-
    either (Left . Text.pack . show) Right (cascadeLocalOperationReferences compiled)
  Right
    FixedCommitScenario
      { fixedCommitCompiled = compiled
      , fixedCommitBytes = bytes
      , fixedCommitDigest = digest
      , fixedCommitOtherBytes = otherBytes
      , fixedCommitOtherDigest = otherDigest
      , fixedCommitOperations = operations
      }

runFixedCommitRegression
  :: FixedCommitScenario -> IO (Either Text PreUninstallReportCommitRegression)
runFixedCommitRegression scenario = do
  let bytes = fixedCommitBytes scenario
      digest = fixedCommitDigest scenario

  -- The happy path: both halves land.
  (applied, appliedOrder) <- withFresh scenario bytes acceptingCopy $ \boundary _ order -> do
    result <- commitPreUninstallReport boundary digest
    journal <- readIORef order
    pure (result, journal)

  -- The identity does not name the bytes this module holds.
  foreign' <- withFresh scenario bytes acceptingCopy $ \boundary _ _ ->
    commitPreUninstallReport boundary (fixedCommitOtherDigest scenario)

  -- A second, different report identity under one run.
  conflict <- withFresh scenario bytes acceptingCopy $ \boundary store _ -> do
    _ <- commitPreUninstallReport boundary digest
    other <- boundaryFor scenario (fixedCommitOtherBytes scenario) acceptingCopy store
    case other of
      Left err -> pure (TeardownMutationRefused err)
      Right otherBoundary ->
        commitPreUninstallReport otherBoundary (fixedCommitOtherDigest scenario)

  -- The independent copy refuses.
  replicationFailed <- withFresh scenario bytes refusingCopy $ \boundary _ _ ->
    commitPreUninstallReport boundary digest

  -- The permit, twice, and then for a different report.
  permits <- withFresh scenario bytes acceptingCopy $ \boundary store _ -> do
    _ <- commitPreUninstallReport boundary digest
    first' <- grantLocalCompletionPermit boundary digest
    second' <- grantLocalCompletionPermit boundary digest
    other <- boundaryFor scenario (fixedCommitOtherBytes scenario) acceptingCopy store
    third <- case other of
      Left err -> pure (Left err)
      Right otherBoundary ->
        grantLocalCompletionPermit otherBoundary (fixedCommitOtherDigest scenario)
    pure (first', second', third)

  let (firstPermit, replayedPermit, foreignPermit) = permits
  pure
    ( Right
        PreUninstallReportCommitRegression
          { reportCommitRegressionAppliedWhenBothLand =
              applied == TeardownMutationApplied
          , -- The Authority write precedes the independent copy, so an
            -- interrupted commit leaves an identity that can be re-copied
            -- rather than a copy nothing refers to.
            reportCommitRegressionReplicationFollowsTheAuthority =
              appliedOrder == ["authority", "copy"]
          , reportCommitRegressionForeignBytesRefused = refused foreign'
          , reportCommitRegressionConflictRefused = refused conflict
          , reportCommitRegressionReplicationFailureIsResponseLost =
              responseLost replicationFailed
          , reportCommitRegressionPermitIsBoundToTheReport =
              case firstPermit of
                Left _ -> False
                Right grant -> localCompletionGrantReportDigest grant == digest
          , -- A rerun that lost its response is handed the permit the Authority
            -- durably holds, not a fresh one.
            reportCommitRegressionPermitReplayIsTheDurableGrant =
              case (firstPermit, replayedPermit) of
                (Right one, Right two) -> one == two
                _ -> False
          , reportCommitRegressionSecondReportRefusesThePermit =
              either (const True) (const False) foreignPermit
          }
    )
 where
  refused = \case
    TeardownMutationRefused _ -> True
    _ -> False
  responseLost = \case
    TeardownMutationResponseLost _ -> True
    _ -> False

-- | One scenario run against a fresh in-memory Authority slot store.
withFresh
  :: FixedCommitScenario
  -> ByteString
  -> (IORef [Text] -> ByteString -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt))
  -> (CascadeReportCommitBoundary IO -> IORef [(Text, ByteString)] -> IORef [Text] -> IO a)
  -> IO a
withFresh scenario bytes copy consume = do
  store <- newIORef []
  order <- newIORef []
  built <- boundaryForWithOrder scenario bytes copy store order
  case built of
    Left err -> fail (Text.unpack err)
    Right boundary -> consume boundary store order

boundaryFor
  :: FixedCommitScenario
  -> ByteString
  -> (IORef [Text] -> ByteString -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt))
  -> IORef [(Text, ByteString)]
  -> IO (Either Text (CascadeReportCommitBoundary IO))
boundaryFor scenario bytes copy store = do
  order <- newIORef []
  boundaryForWithOrder scenario bytes copy store order

boundaryForWithOrder
  :: FixedCommitScenario
  -> ByteString
  -> (IORef [Text] -> ByteString -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt))
  -> IORef [(Text, ByteString)]
  -> IORef [Text]
  -> IO (Either Text (CascadeReportCommitBoundary IO))
boundaryForWithOrder scenario bytes copy store order =
  pure
    ( cascadeReportCommitBoundary
        (memoryAuthority order store)
        (memoryBackup order copy)
        (fixedCommitCompiled scenario)
        bytes
    )

memoryAuthority
  :: IORef [Text] -> IORef [(Text, ByteString)] -> CascadeReportAuthorityClient IO
memoryAuthority order store =
  modelBCascadeReportRepository fixedAuthority (memorySlotAdapter order store)

memoryBackup
  :: IORef [Text]
  -> (IORef [Text] -> ByteString -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt))
  -> CleanupReportBackupClient IO
memoryBackup order copy =
  CleanupReportBackupClient
    { copyCleanupReportBackup = copy order
    , observeCleanupReportBackup = \_ ->
        pure
          ( Left
              ( CleanupReportBackupCiphertextInvalid
                  "the fixed commit fixture does not read the independent copy back"
              )
          )
    }

acceptingCopy
  :: IORef [Text]
  -> ByteString
  -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt)
acceptingCopy order bytes = do
  modifyIORef' order (++ ["copy"])
  pure $ do
    ciphertext <- first' (mkAuthorityBackupCiphertext bytes)
    Right
      AuthorityBackupReceipt
        { authorityBackupReceiptClass = AuthorityCleanupReportBlob
        , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
        , authorityBackupReceiptObjectVersion = "fixed-commit-version"
        }
 where
  first' = either (Left . CleanupReportBackupCiphertextInvalid) Right

refusingCopy
  :: IORef [Text]
  -> ByteString
  -> IO (Either CleanupReportBackupClientError AuthorityBackupReceipt)
refusingCopy order _ = do
  modifyIORef' order (++ ["copy"])
  pure
    ( Left
        ( CleanupReportBackupCiphertextInvalid
            "the independent copy target answered nothing"
        )
    )

memorySlotAdapter
  :: IORef [Text]
  -> IORef [(Text, ByteString)]
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
memorySlotAdapter order store =
  ModelBCasAdapter
    { modelBObserve = \coordinate -> do
        held <- readIORef store
        pure
          ( maybe
              ModelBMissing
              (ModelBObserved fixedSlotVersion)
              (lookup (modelBObjectLogicalName coordinate) held)
          )
    , modelBCompareAndSwap = \case
        ModelBInitialize coordinate value -> do
          modifyIORef' order (++ ["authority"])
          let name = modelBObjectLogicalName coordinate
          existing <- atomicModifyIORef' store (initializeSlot name value)
          pure
            ( maybe
                (ModelBCasApplied fixedSlotVersion value)
                (ModelBCasConflict . ModelBObserved fixedSlotVersion)
                existing
            )
        _ ->
          pure
            ( ModelBCasRefusedCorrupt
                "the fixed cascade-report store issues only initialize"
            )
    }
 where
  initializeSlot name value held = case lookup name held of
    Just existing -> (held, Just existing)
    Nothing -> (held ++ [(name, value)], Nothing)

fixedSlotVersion :: ModelBObjectVersion
fixedSlotVersion =
  either (const fallback) id (mkModelBObjectVersion "fixed-slot-version")
 where
  fallback = either (const fixedSlotVersion) id (mkModelBObjectVersion "v")

-- | The fixture's Authority coordinate root.
--
-- It is a compiled constant here because the slot names this fixture exercises
-- are derived from the run id, not from the authority, so a fixed root keeps
-- the two runs' slots distinguishable without inventing cluster identity.
fixedAuthority :: LongLivedCheckpointAuthority
fixedAuthority =
  either
    (error . show)
    id
    ( mkLongLivedCheckpointAuthority
        "home-rke2"
        "prodbox-retained"
        "authority"
        "prodbox/authority"
    )
