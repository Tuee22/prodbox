{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: Stage C composed, from a converged run to readiness.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 7](../../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- is one sentence with five surfaces under it, and by the time this module was
-- written every one of them existed and none of them met:
-- "Prodbox.Lifecycle.Teardown.PreUninstallReport" renders the bytes,
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportCommit" writes them and signs
-- the permit, "Prodbox.ControlPlane.CleanupReportBackupClient" replicates them
-- into the independent failure domain,
-- "Prodbox.Lifecycle.Teardown.PreUninstallReportBackup" reads them back from
-- it, and "Prodbox.Lifecycle.Teardown.PreUninstallReadiness" sequences a commit
-- and a read-back into 'ReadyToUninstallEvidence'.  Each was exercised only by
-- its own regression.  This module is the chain: the one surface that turns
-- three convergence proofs and two clients into readiness.
--
-- Four properties carry the design.
--
--   * __The report identity is rendered, never supplied.__  No caller names a
--     'CascadeReportDigest'.  The bytes are rendered from the compiled program
--     and its three convergence evidences, the identity is their digest, and
--     that one value is what the Authority is asked to commit and what the
--     independent adapter is asked to confirm.  A run therefore cannot commit a
--     report identity its own proofs do not produce, which is the failure the
--     two halves could not exclude while each took the digest as an argument.
--
--   * __Nothing is written before the report is admitted.__  The three
--     evidences must bind to the compiled program for
--     'renderPreUninstallReport' to produce anything at all, and that refusal
--     returns before the commit boundary is constructed — measured as the
--     Authority not being called at all when the proofs describe another run.
--     A report is a durable statement that /this/ run converged, so a run that
--     cannot make the statement must not reach the surface that records it.
--
--   * __The same three evidences render the report and compose the
--     readiness.__  They are passed once and used twice, so the report a permit
--     is signed over and the readiness that permit belongs to are statements
--     about the same run by construction rather than by the caller's
--     discipline.
--
--   * __The deciding surface is not the Authority.__  The Authority client
--     records the identity and signs the permit; the independent adapter holds
--     the bytes and answers the read-back that decides durability.  The adapter
--     appears in both halves because copying into that domain and reading it
--     back are the two things that domain does — the separation node 7 requires
--     is between the surface that /claims/ the write and the surface that
--     /confirms/ it, and here they remain distinct failure domains.
--
-- __A rerun re-renders one identity.__  The report bytes are canonical, so a
-- cascade resumed after a lost response renders exactly the bytes it rendered
-- before, finds the Authority already holding that identity, and takes the
-- exact-replay arm rather than committing a second identity for the same facts.
--
-- What this module does not own: whether the run converged, which is the three
-- evidences'; the content of the report, the one-shot semantics of the permit,
-- and the classification of either half's faults, which belong to the surfaces
-- named above; and the uninstall that consumes this readiness, which is
-- "Prodbox.Lifecycle.HostCleanupRunner".  Composing this chain with the host
-- runner and the restore boundary into a running cascade remains the non-public
-- candidate entrypoint Sprint @4.86@ owns; nothing here activates a public
-- writer.
module Prodbox.Lifecycle.Teardown.PreUninstallStageC
  ( -- * Running Stage C against the production clients
    CascadeStageCRefusal (..)
  , renderCascadeStageCRefusal
  , CascadeStageC (..)
  , cascadeStageCReadiness
  , runCascadeStageC

    -- * Regression over the package-private fixture
  , PreUninstallStageCRegression
  , fixedPreUninstallStageCRegression
  , stageCRegressionReadyFromConvergedRun
  , stageCRegressionReadinessCarriesTheRenderedIdentity
  , stageCRegressionForeignEvidenceRefused
  , stageCRegressionForeignEvidenceWritesNothing
  , stageCRegressionMissingCopyIsNotReady
  , stageCRegressionUnobservableDomainIsNotReady
  , stageCRegressionReadBackIsAnsweredByTheIndependentDomain
  , stageCRegressionRerunCommitsOneIdentity
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
import Prodbox.ControlPlane.AuthorityBackupEndpoint
  ( AuthorityBackupBlobClass (AuthorityCleanupReportBlob)
  , AuthorityBackupReceipt (..)
  , authorityBackupCiphertextDigest
  , authorityBackupDigestText
  , mkAuthorityBackupCiphertext
  )
import Prodbox.ControlPlane.CascadeReportRepository
  ( CascadeReportAuthorityClient
  , modelBCascadeReportRepository
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient (..)
  , CleanupReportBackupClientError (CleanupReportBackupCiphertextInvalid)
  , CleanupReportBackupObservation (..)
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
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeAbsenceEvidence
  , CascadeCapabilityCustodyEvidence
  , CascadeCredentialDispositionEvidence
  , CascadeEvidenceError
  , CascadeTerminalAuditEvidence
  , ReadyToUninstallEvidence
  , readyToUninstallReportDigest
  , withCascadePreUninstallInputsInternal
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  )
import Prodbox.Lifecycle.Teardown.Model (CleanupSurface (Cascade))
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( PreUninstallReadinessOutcome (..)
  , PreUninstallReadinessRun (..)
  , establishPreUninstallReadiness
  , preUninstallReadinessEvidence
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReport
  ( PreUninstallReport
  , preUninstallReportBytes
  , preUninstallReportDigest
  , renderPreUninstallReport
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReportBackup
  ( cascadeReportReadBackBoundary
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReportCommit
  ( cascadeReportCommitBoundary
  )

-- ---------------------------------------------------------------------------
-- Running Stage C against the production clients
-- ---------------------------------------------------------------------------

-- | Why Stage C could not be run at all.
--
-- These are refusals to /start/ the protocol, and they are a different kind of
-- answer from 'PreUninstallReadinessRun': no commit was attempted, no
-- observation was taken, and the Authority was never called.
data CascadeStageCRefusal
  = -- | The three convergence evidences do not bind to the compiled program,
    -- so there is no statement this run is entitled to commit.
    CascadeStageCReportUnrenderable !CascadeEvidenceError
  | -- | The compiled program does not carry the local operation references the
    -- permit must be granted over.
    CascadeStageCBoundaryUnavailable !Text
  deriving (Eq, Show)

renderCascadeStageCRefusal :: CascadeStageCRefusal -> String
renderCascadeStageCRefusal = \case
  CascadeStageCReportUnrenderable err ->
    "Stage C did not start: the pre-uninstall report cannot be rendered for this "
      ++ "run: "
      ++ show err
  CascadeStageCBoundaryUnavailable detail ->
    "Stage C did not start: the Authority commit boundary is unavailable: "
      ++ Text.unpack detail

-- | One complete Stage-C run and the report it was about.
--
-- The report is retained beside the run because an incomplete cascade reports
-- the identity it attempted to make durable, and that identity is a fact about
-- the run whether or not the readiness composed.
data CascadeStageC = CascadeStageC
  { cascadeStageCReport :: !PreUninstallReport
  , cascadeStageCRun :: !PreUninstallReadinessRun
  }

cascadeStageCReadiness :: CascadeStageC -> Maybe ReadyToUninstallEvidence
cascadeStageCReadiness = preUninstallReadinessEvidence . cascadeStageCRun

-- | Render the pre-uninstall report for a converged cascade run, commit it at
-- the Lifecycle Authority, replicate and independently read it back through the
-- Backup Adapter, obtain the one-shot completion permit, and compose readiness.
--
-- The digest is not a parameter: it is derived from the bytes this call
-- renders, so the identity the Authority commits, the identity the independent
-- domain stores the bytes under, and the identity the read-back confirms are
-- one value with one source.
runCascadeStageC
  :: CascadeReportAuthorityClient IO
  -> CleanupReportBackupClient IO
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> CascadeCapabilityCustodyEvidence
  -> IO (Either CascadeStageCRefusal CascadeStageC)
runCascadeStageC authority backup compiled absence credentials audit custody =
  case renderPreUninstallReport compiled absence credentials audit of
    Left err -> pure (Left (CascadeStageCReportUnrenderable err))
    Right report ->
      case cascadeReportCommitBoundary
        authority
        backup
        compiled
        (preUninstallReportBytes report) of
        Left detail -> pure (Left (CascadeStageCBoundaryUnavailable detail))
        Right commit -> do
          let digest = preUninstallReportDigest report
              readBack = cascadeReportReadBackBoundary backup compiled digest
          run <-
            establishPreUninstallReadiness
              commit
              readBack
              compiled
              absence
              credentials
              audit
              custody
              digest
          pure
            ( Right
                CascadeStageC
                  { cascadeStageCReport = report
                  , cascadeStageCRun = run
                  }
            )

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without a compiled cascade program, an
-- evidence value, a report identity, or a readiness proof leaving this package.
data PreUninstallStageCRegression = PreUninstallStageCRegression
  { stageCRegressionReadyFromConvergedRun :: !Bool
  , stageCRegressionReadinessCarriesTheRenderedIdentity :: !Bool
  , stageCRegressionForeignEvidenceRefused :: !Bool
  , stageCRegressionForeignEvidenceWritesNothing :: !Bool
  , stageCRegressionMissingCopyIsNotReady :: !Bool
  , stageCRegressionUnobservableDomainIsNotReady :: !Bool
  , stageCRegressionReadBackIsAnsweredByTheIndependentDomain :: !Bool
  , stageCRegressionRerunCommitsOneIdentity :: !Bool
  }

-- | Run the whole chain against an in-memory Authority slot store and an
-- in-memory independent domain.
--
-- Every property is produced by running the composition rather than by
-- asserting its parts: the happy path really reaches readiness, the foreign-run
-- refusal is measured by an Authority that was never called, and the two
-- unready arms are produced by a domain that lost the bytes and by one that
-- could not be reached.
fixedPreUninstallStageCRegression :: IO (Either Text PreUninstallStageCRegression)
fixedPreUninstallStageCRegression =
  case fixedStageCComposition of
    Left err -> pure (Left err)
    Right scenario -> Right <$> runFixedStageCComposition scenario

data FixedStageCComposition = FixedStageCComposition
  { fixedStageCCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedStageCAbsence :: !CascadeAbsenceEvidence
  , fixedStageCCredentials :: !CascadeCredentialDispositionEvidence
  , fixedStageCAudit :: !CascadeTerminalAuditEvidence
  , fixedStageCCustody :: !CascadeCapabilityCustodyEvidence
  , fixedStageCForeignAbsence :: !CascadeAbsenceEvidence
  , fixedStageCForeignCredentials :: !CascadeCredentialDispositionEvidence
  , fixedStageCForeignAudit :: !CascadeTerminalAuditEvidence
  , fixedStageCForeignCustody :: !CascadeCapabilityCustodyEvidence
  }

fixedStageCComposition :: Either Text FixedStageCComposition
fixedStageCComposition = do
  own <-
    withCascadePreUninstallInputsInternal
      "cleanup-run/stage-c-composition-fixed-regression"
      ( \compiled _run absence credentials audit custody ->
          (compiled, absence, credentials, audit, custody)
      )
  foreign' <-
    withCascadePreUninstallInputsInternal
      "cleanup-run/stage-c-composition-fixed-other"
      ( \_compiled _run absence credentials audit custody ->
          (absence, credentials, audit, custody)
      )
  let (compiled, absence, credentials, audit, custody) = own
      (otherAbsence, otherCredentials, otherAudit, otherCustody) = foreign'
  Right
    FixedStageCComposition
      { fixedStageCCompiled = compiled
      , fixedStageCAbsence = absence
      , fixedStageCCredentials = credentials
      , fixedStageCAudit = audit
      , fixedStageCCustody = custody
      , fixedStageCForeignAbsence = otherAbsence
      , fixedStageCForeignCredentials = otherCredentials
      , fixedStageCForeignAudit = otherAudit
      , fixedStageCForeignCustody = otherCustody
      }

runFixedStageCComposition
  :: FixedStageCComposition -> IO PreUninstallStageCRegression
runFixedStageCComposition scenario = do
  -- The happy path: the report renders, both halves land, and the independent
  -- domain confirms the identity it was given.
  (ready, readyJournal) <- withFixedDomain scenario HoldsWhatItWasGiven $ \run journal -> do
    outcome <- run scenario
    entries <- readIORef journal
    pure (outcome, entries)

  -- A report described by another run's proofs never reaches a client.
  (refused, refusedJournal) <- withFixedDomain scenario HoldsWhatItWasGiven $ \_ journal -> do
    outcome <- runForeign scenario
    entries <- readIORef journal
    pure (outcome, entries)

  -- The commit reported success and the independent domain holds nothing.
  lostCopy <- withFixedDomain scenario ForgetsTheCopy $ \run _ -> run scenario

  -- The independent domain could not be reached at all.
  unreachable <- withFixedDomain scenario AnswersNothing $ \run _ -> run scenario

  -- A rerun of a converged run re-renders one identity and finds it already
  -- committed, rather than committing a second identity for the same facts.
  (first', second') <- withFixedDomain scenario HoldsWhatItWasGiven $ \run _ -> do
    one <- run scenario
    two <- run scenario
    pure (one, two)

  pure
    PreUninstallStageCRegression
      { stageCRegressionReadyFromConvergedRun = isReady ready
      , stageCRegressionReadinessCarriesTheRenderedIdentity =
          case ready of
            Right stageC ->
              case cascadeStageCReadiness stageC of
                Nothing -> False
                Just evidence ->
                  readyToUninstallReportDigest evidence
                    == preUninstallReportDigest (cascadeStageCReport stageC)
            Left _ -> False
      , -- The whole chain ran, so the journal proves the order the composition
        -- performs: the Authority records the identity, the independent domain
        -- takes the copy, that domain answers the read-back that decides
        -- durability, and only then does the Authority sign the permit.
        stageCRegressionReadBackIsAnsweredByTheIndependentDomain =
          readyJournal == ["authority", "copy", "observe", "authority"]
      , stageCRegressionForeignEvidenceRefused =
          case refused of
            Left (CascadeStageCReportUnrenderable _) -> True
            _ -> False
      , stageCRegressionForeignEvidenceWritesNothing = null refusedJournal
      , stageCRegressionMissingCopyIsNotReady = isNotReady lostCopy
      , stageCRegressionUnobservableDomainIsNotReady = isNotReady unreachable
      , stageCRegressionRerunCommitsOneIdentity =
          isReady first'
            && isReady second'
            && sameIdentity first' second'
      }
 where
  isReady = \case
    Right stageC -> case preUninstallReadinessOutcome (cascadeStageCRun stageC) of
      PreUninstallReady _ -> True
      PreUninstallNotReady _ -> False
    Left _ -> False

  isNotReady = \case
    Right stageC -> case preUninstallReadinessOutcome (cascadeStageCRun stageC) of
      PreUninstallReady _ -> False
      PreUninstallNotReady _ -> True
    Left _ -> False

  sameIdentity one two = case (one, two) of
    (Right a, Right b) ->
      preUninstallReportDigest (cascadeStageCReport a)
        == preUninstallReportDigest (cascadeStageCReport b)
    _ -> False

-- | What the fixture's independent domain does with the bytes it is handed.
data FixedIndependentDomain
  = -- | It stores them and answers the read-back with its own receipt.
    HoldsWhatItWasGiven
  | -- | It accepts the copy and holds nothing, which is a commit that never
    -- reached the independent domain.
    ForgetsTheCopy
  | -- | It answers neither the copy nor the read-back.
    AnswersNothing

-- | One Stage-C composition over a fresh Authority slot store and a fresh
-- independent domain, with a journal recording which surface was called.
withFixedDomain
  :: FixedStageCComposition
  -> FixedIndependentDomain
  -> ( (FixedStageCComposition -> IO (Either CascadeStageCRefusal CascadeStageC))
       -> IORef [Text]
       -> IO a
     )
  -> IO a
withFixedDomain _ domain consume = do
  journal <- newIORef []
  slots <- newIORef []
  held <- newIORef []
  let authority = modelBCascadeReportRepository fixedAuthority (memorySlots journal slots)
      backup = memoryDomain journal domain held
      run scenario =
        runCascadeStageC
          authority
          backup
          (fixedStageCCompiled scenario)
          (fixedStageCAbsence scenario)
          (fixedStageCCredentials scenario)
          (fixedStageCAudit scenario)
          (fixedStageCCustody scenario)
  consume run journal

runForeign
  :: FixedStageCComposition -> IO (Either CascadeStageCRefusal CascadeStageC)
runForeign scenario =
  runCascadeStageC
    (modelBCascadeReportRepository fixedAuthority neverCalledSlots)
    neverCalledDomain
    (fixedStageCCompiled scenario)
    (fixedStageCForeignAbsence scenario)
    (fixedStageCForeignCredentials scenario)
    (fixedStageCForeignAudit scenario)
    (fixedStageCForeignCustody scenario)

-- | Clients that fail the test if the composition reaches them.
--
-- The foreign-evidence case is about /not/ writing, so the measurement is that
-- these are never called rather than that they refused.
neverCalledSlots :: ModelBCasAdapter 'ClusterRetained IO ByteString
neverCalledSlots =
  ModelBCasAdapter
    { modelBObserve = \_ -> pure (ModelBUnobservable "the Authority must not be reached")
    , modelBCompareAndSwap = \_ ->
        pure (ModelBCasRefusedCorrupt "the Authority must not be reached")
    }

neverCalledDomain :: CleanupReportBackupClient IO
neverCalledDomain =
  CleanupReportBackupClient
    { copyCleanupReportBackup = \_ ->
        pure
          ( Left
              ( CleanupReportBackupCiphertextInvalid
                  "the independent domain must not be reached"
              )
          )
    , observeCleanupReportBackup = \_ ->
        pure
          ( Left
              ( CleanupReportBackupCiphertextInvalid
                  "the independent domain must not be reached"
              )
          )
    }

memoryDomain
  :: IORef [Text]
  -> FixedIndependentDomain
  -> IORef [(Text, ByteString)]
  -> CleanupReportBackupClient IO
memoryDomain journal domain held =
  CleanupReportBackupClient
    { copyCleanupReportBackup = \bytes -> do
        modifyIORef' journal (++ ["copy"])
        case domain of
          AnswersNothing ->
            pure
              ( Left
                  ( CleanupReportBackupCiphertextInvalid
                      "the independent domain answered nothing"
                  )
              )
          ForgetsTheCopy -> pure (receiptFor bytes)
          HoldsWhatItWasGiven -> case receiptFor bytes of
            Left err -> pure (Left err)
            Right receipt -> do
              modifyIORef'
                held
                (++ [(authorityBackupDigestText (authorityBackupReceiptDigest receipt), bytes)])
              pure (Right receipt)
    , observeCleanupReportBackup = \digest -> do
        modifyIORef' journal (++ ["observe"])
        case domain of
          AnswersNothing ->
            pure
              ( Left
                  ( CleanupReportBackupCiphertextInvalid
                      "the independent domain answered nothing"
                  )
              )
          _ -> do
            stored <- readIORef held
            pure $ case lookup digest stored of
              Nothing -> Right CleanupReportBackupMissing
              Just bytes -> do
                ciphertext <-
                  either
                    (Left . CleanupReportBackupCiphertextInvalid)
                    Right
                    (mkAuthorityBackupCiphertext bytes)
                Right
                  ( CleanupReportBackupCurrent
                      ciphertext
                      AuthorityBackupReceipt
                        { authorityBackupReceiptClass = AuthorityCleanupReportBlob
                        , authorityBackupReceiptDigest =
                            authorityBackupCiphertextDigest ciphertext
                        , authorityBackupReceiptObjectVersion = "fixed-stage-c-version"
                        }
                  )
    }
 where
  receiptFor bytes = do
    ciphertext <-
      either
        (Left . CleanupReportBackupCiphertextInvalid)
        Right
        (mkAuthorityBackupCiphertext bytes)
    Right
      AuthorityBackupReceipt
        { authorityBackupReceiptClass = AuthorityCleanupReportBlob
        , authorityBackupReceiptDigest = authorityBackupCiphertextDigest ciphertext
        , authorityBackupReceiptObjectVersion = "fixed-stage-c-version"
        }

memorySlots
  :: IORef [Text]
  -> IORef [(Text, ByteString)]
  -> ModelBCasAdapter 'ClusterRetained IO ByteString
memorySlots journal store =
  ModelBCasAdapter
    { modelBObserve = \coordinate -> do
        stored <- readIORef store
        pure
          ( maybe
              ModelBMissing
              (ModelBObserved fixedSlotVersion)
              (lookup (modelBObjectLogicalName coordinate) stored)
          )
    , modelBCompareAndSwap = \case
        ModelBInitialize coordinate value -> do
          modifyIORef' journal (++ ["authority"])
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
                "the fixed Stage-C store issues only initialize"
            )
    }
 where
  initializeSlot name value stored = case lookup name stored of
    Just existing -> (stored, Just existing)
    Nothing -> (stored ++ [(name, value)], Nothing)

fixedSlotVersion :: ModelBObjectVersion
fixedSlotVersion =
  either (const fallback) id (mkModelBObjectVersion "fixed-stage-c-slot")
 where
  fallback = either (const fixedSlotVersion) id (mkModelBObjectVersion "v")

-- | The fixture's Authority coordinate root.
--
-- Compiled here because the slot names Stage C exercises are derived from the
-- run id rather than from the authority, so a fixed root keeps two runs' slots
-- distinguishable without inventing cluster identity.
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
