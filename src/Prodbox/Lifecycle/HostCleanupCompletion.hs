{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 4.86: the local-completion half of the recover-to-clean cascade's
-- terminal node.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 8](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- says that after exact host absence @prepareLocalCompletion@ binds the signed
-- permit and the observed uninstall evidence to the stable local-completion
-- operation reference, that the host interpreter idempotently appends it to the
-- preserved non-secret cleanup journal, and that /a separate observation of the
-- same reference/ mints the completion receipt.  Both names existed only in the
-- doctrine: nothing in the repository appended such an entry and nothing read
-- one back, so the terminal node's second half had no producer at all.
--
-- Five properties carry the design.
--
--   * __The append is keyed by the reference, not by the bytes.__  An entry is
--     published by an exclusive link under the digest of its reference, so a
--     rerun after a lost append response finds the entry already present and
--     succeeds without writing a second one.  That is what makes the append
--     idempotent in the sense node 8 needs: a rerun performs the /observation/
--     rather than reinstalling a control plane merely to rewrite history.
--
--   * __The host cannot rewrite history.__  An entry that is already present
--     and does not match the prepared bytes is a conflict, not an overwrite.
--     The signed scope is carried into the entry unchanged, and there is no
--     argument through which a wider one could enter.
--
--   * __The writer does not decide.__  Appending and observing are separate
--     operations over separate descriptors, and the observation reads the
--     journal rather than the append's answer.  An append that reported success
--     over a journal that holds nothing observable produces no receipt.
--
--   * __Missing and unobservable are different answers.__  A journal with no
--     entry for this reference says the completion was never appended; a
--     journal that could not be read says nothing at all.  Collapsing them
--     would let an unreadable directory read as a clean \"not yet\".
--
--   * __Every field of the read-back comes from the decoded entry.__  Run,
--     graph digest, scope, operation reference, permit, and report digest are
--     decoded from the durable bytes and never taken from the running context.
--     Taking them from the context would make the runner's binding comparisons
--     compare a value with itself, which is the exact defect an independent
--     read-back exists to exclude.
--
-- What this module does not own: the /permit/, whose one-shot semantics are
-- enforced where the Lifecycle Authority signs it; the exact host observation
-- that produces the absence proof, which belongs to
-- "Prodbox.Lifecycle.HostCleanupLocalAbsence"; and the durable phase record,
-- which belongs to "Prodbox.Lifecycle.HostCleanupIntent".  This module is a
-- member of the cascade-evidence ownership set because minting completion from
-- an observed receipt requires the private constructor, exactly as the absence
-- read-back does.
module Prodbox.Lifecycle.HostCleanupCompletion
  ( -- * The preserved journal
    HostCleanupCompletionJournal
  , hostCleanupCompletionJournalDirectoryName
  , mkHostCleanupCompletionJournal
  , bootstrapLocatedHostCleanupCompletionJournal
  , authorityBoundHostCleanupCompletionJournal
  , hostCleanupCompletionJournalRoot
  , hostCleanupCompletionEntryPath

    -- * Preparing the entry
  , LocalCompletionReference
  , localCompletionReferenceRunId
  , localCompletionReferenceGraphDigest
  , localCompletionReferenceScope
  , localCompletionReferenceOperationId
  , localCompletionReferenceDigest
  , PreparedLocalCompletion
  , preparedLocalCompletionReference
  , preparedLocalCompletionBytes
  , preparedLocalCompletionDigest
  , prepareLocalCompletion

    -- * Appending it
  , LocalCompletionAppend (..)
  , renderLocalCompletionAppend
  , appendLocalCompletion
  , localCompletionAppendOutcome

    -- * Observing it back
  , ObservedLocalCompletion (..)
  , LocalCompletionObservation (..)
  , observeLocalCompletion
  , localCompletionReadBack

    -- * Production effect arms
  , productionHostCleanupCompletionCommit
  , productionHostCleanupCompletionReadBack

    -- * Regression over the package-private fixture
  , LocalCompletionRegression
  , fixedLocalCompletionRegression
  , localCompletionRegressionAppendedBecomesReceipt
  , localCompletionRegressionAppendIsIdempotent
  , localCompletionRegressionConflictRefusesRewrite
  , localCompletionRegressionMissingIsNotUnobservable
  , localCompletionRegressionUnobservableRefused
  , localCompletionRegressionReadBackCarriesDecodedIdentity
  , localCompletionRegressionForeignProofsRefused
  , localCompletionRegressionAppendResponseNotEvidence
  , localCompletionRegressionEntryPathIsReferenceKeyed
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (IOException, bracket, mask_, throwIO, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Config.LocalRetainedRoot
  ( AuthorityBoundRetainedRoot
  , BootstrapRetainedRootLocator
  , authorityBoundRetainedRootControlDirectory
  , bootstrapRetainedRootControlDirectory
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRun (cleanupRunGraphDigest, cleanupRunId)
  , CleanupRunId
  , cleanupDigestOfBytes
  , cleanupDigestText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntent
  , mkHostCleanupIntent
  , mkHostCleanupScope
  , mkHostCleanupTerminalIdentity
  , mkHostTerminalPermitId
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupCompletionReadBack (..)
  , HostCleanupEffectOutcome (..)
  , HostCleanupRunnerContext
  , hostCleanupRunnerCompletionOperationId
  , hostCleanupRunnerGraphDigest
  , hostCleanupRunnerObservationScope
  , hostCleanupRunnerReadyPermitId
  , hostCleanupRunnerReadyReportDigest
  , hostCleanupRunnerRunId
  , validateHostCleanupReady
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeCompletionReceiptObservation (..)
  , LocalUninstallEvidence
  , ReadyToUninstallEvidence
  , cascadeLocalUninstallOperationId
  , cascadeReportDigestText
  , localCompletionPermitIdText
  , localUninstallAbsenceEvidence
  , mkCascadeCompleteEvidence
  , mkCascadeReportDigest
  , mkLocalCompletionPermitId
  , readyToUninstallOperationReferences
  , readyToUninstallPermitId
  , readyToUninstallScope
  , withCascadeEvidenceFixtureForRunInternal
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( DurableReceiptKind (CascadeCompletionReceipt)
  , DurableReceiptObservation (..)
  , DurableReceiptObservationResult (DurableReceiptObserved)
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (Cascade)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (AbsenceEvidence))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (isAbsolute, normalise, takeFileName, (<.>), (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createLink
  , getFdStatus
  , isRegularFile
  , ownerReadMode
  , ownerWriteMode
  , removeLink
  , setFdMode
  , unionFileModes
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

-- ---------------------------------------------------------------------------
-- The preserved journal
-- ---------------------------------------------------------------------------

-- | The preserved non-secret cleanup journal.
--
-- It holds the prodbox-owned control directory rather than the journal path,
-- because the journal and its staging area are siblings that must both be
-- derived from one place — the same reason the retained-artifact store is
-- located that way.
newtype HostCleanupCompletionJournal = HostCleanupCompletionJournal FilePath
  deriving (Eq, Ord, Show)

-- | The single segment naming the journal inside the prodbox-owned control
-- directory, beside the host-cleanup record and the retained-artifact store.
hostCleanupCompletionJournalDirectoryName :: FilePath
hostCleanupCompletionJournalDirectoryName = "host-cleanup-completion"

-- | Locate the journal under an explicit control directory.
--
-- This is the test-scoped seam.  Production callers use one of the two derived
-- locators below, so the entry a run appends is the entry a rerun observes.
mkHostCleanupCompletionJournal
  :: FilePath -> Either Text HostCleanupCompletionJournal
mkHostCleanupCompletionJournal control
  | not (isAbsolute control) =
      Left "cleanup completion journal control directory must be absolute"
  | normalise control == "/" =
      Left "cleanup completion journal control directory must not be the filesystem root"
  | otherwise = Right (HostCleanupCompletionJournal (normalise control))

-- | Locate the journal from the non-authorizing bootstrap locator.
--
-- This is the direction a rerun needs: the completion entry is observed while
-- the Lifecycle Authority may still be absent.
bootstrapLocatedHostCleanupCompletionJournal
  :: BootstrapRetainedRootLocator -> Either Text HostCleanupCompletionJournal
bootstrapLocatedHostCleanupCompletionJournal =
  mkHostCleanupCompletionJournal . bootstrapRetainedRootControlDirectory

-- | Locate the same journal from an Authority-bound root.
--
-- There is deliberately no durability index here, for the reason the
-- host-cleanup record already carries none: this journal is /written/ at the
-- moment the Authority may be gone, so an Authority-bound mutation index would
-- forbid the one append that matters most.
authorityBoundHostCleanupCompletionJournal
  :: AuthorityBoundRetainedRoot -> Either Text HostCleanupCompletionJournal
authorityBoundHostCleanupCompletionJournal =
  mkHostCleanupCompletionJournal . authorityBoundRetainedRootControlDirectory

hostCleanupCompletionJournalRoot :: HostCleanupCompletionJournal -> FilePath
hostCleanupCompletionJournalRoot (HostCleanupCompletionJournal control) =
  control </> hostCleanupCompletionJournalDirectoryName

-- | Where one reference's entry lives.
--
-- The file is named by the digest of the reference rather than by any of its
-- text components, so the name is fixed-length lowercase hexadecimal and
-- \"the same reference\" is exactly \"the same file\".
hostCleanupCompletionEntryPath
  :: HostCleanupCompletionJournal -> LocalCompletionReference -> FilePath
hostCleanupCompletionEntryPath journal reference =
  hostCleanupCompletionJournalRoot journal
    </> Text.unpack (cleanupDigestText (localCompletionReferenceDigest reference))
      <.> "cbor"

hostCleanupCompletionStagingPath
  :: HostCleanupCompletionJournal -> LocalCompletionReference -> FilePath
hostCleanupCompletionStagingPath journal reference =
  hostCleanupCompletionJournalRoot journal
    </> ( "."
            <> Text.unpack (cleanupDigestText (localCompletionReferenceDigest reference))
            <> ".staging"
        )

-- ---------------------------------------------------------------------------
-- The reference and the prepared entry
-- ---------------------------------------------------------------------------

-- | The stable local-completion operation reference.
--
-- It is the run, its graph, its observation scope, and the compiled
-- local-completion operation — everything that decides /which/ completion this
-- is, and nothing that decides whether it happened.
data LocalCompletionReference = LocalCompletionReference
  { localCompletionReferenceRunId :: !CleanupRunId
  , localCompletionReferenceGraphDigest :: !CleanupDigest
  , localCompletionReferenceScope :: !ObservationEvidenceScope
  , localCompletionReferenceOperationId :: !CleanupOperationId
  }
  deriving (Eq, Show)

-- | The digest that names the reference's journal entry.
--
-- Every component is length-framed before it is joined, so two different
-- references cannot collapse onto one digest by moving a delimiter between
-- adjacent fields.
localCompletionReferenceDigest :: LocalCompletionReference -> CleanupDigest
localCompletionReferenceDigest reference =
  cleanupDigestOfBytes
    ( TextEncoding.encodeUtf8
        ( Text.concat
            ( map
                frame
                [ cleanupRunIdText (localCompletionReferenceRunId reference)
                , cleanupDigestText (localCompletionReferenceGraphDigest reference)
                , cleanupOperationIdText (localCompletionReferenceOperationId reference)
                , scopeText (localCompletionReferenceScope reference)
                ]
            )
        )
    )

frame :: Text -> Text
frame value = Text.pack (show (Text.length value)) <> ":" <> value

scopeText :: ObservationEvidenceScope -> Text
scopeText scope =
  Text.concat
    ( map
        frame
        [ Text.pack (show (fromEnum (evidenceCleanupSurface scope)))
        , registryRevisionText (evidenceRegistryRevision scope)
        , durableRunScopeText (evidenceDurableRunScope scope)
        , foundationIdText (evidenceLinuxRke2Foundation scope)
        , maybe "" (accountIdText . awsScopeAccountId) (evidenceAwsScope scope)
        , maybe "" (regionText . awsScopeRegion) (evidenceAwsScope scope)
        , Text.pack (show (encodeLifecycleOperation (evidenceLifecycleOperation scope)))
        ]
    )

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationIdText :: LinuxRke2FoundationId -> Text
foundationIdText (LinuxRke2FoundationId value) = value

accountIdText :: AwsAccountId -> Text
accountIdText (AwsAccountId value) = value

regionText :: AwsRegion -> Text
regionText (AwsRegion value) = value

absenceEvidenceText :: AbsenceEvidence -> Text
absenceEvidenceText (AbsenceEvidence evidence) = evidence

-- | One completion entry, prepared but not yet durable.
--
-- The canonical bytes are computed once, at preparation, so the bytes that are
-- appended, the bytes a conflict is compared against, and the digest the runner
-- records are one encoding rather than three that could drift.
data PreparedLocalCompletion = PreparedLocalCompletion
  { internalPreparedReference :: !LocalCompletionReference
  , internalPreparedBytes :: !ByteString
  }
  deriving (Eq, Show)

preparedLocalCompletionReference
  :: PreparedLocalCompletion -> LocalCompletionReference
preparedLocalCompletionReference = internalPreparedReference

preparedLocalCompletionBytes :: PreparedLocalCompletion -> ByteString
preparedLocalCompletionBytes = internalPreparedBytes

preparedLocalCompletionDigest :: PreparedLocalCompletion -> CleanupDigest
preparedLocalCompletionDigest = cleanupDigestOfBytes . internalPreparedBytes

-- | Bind the signed permit and the observed uninstall evidence to the stable
-- local-completion operation reference.
--
-- Every binding comes from the running context and the absence proof.  The
-- host supplies nothing of its own, which is what \"the host cannot widen the
-- signed scope\" means concretely: there is no argument through which a wider
-- scope, another permit, or another report identity could enter.
prepareLocalCompletion
  :: HostCleanupRunnerContext
  -> LocalUninstallEvidence 'Cascade
  -> PreparedLocalCompletion
prepareLocalCompletion context local =
  PreparedLocalCompletion
    { internalPreparedReference = reference
    , internalPreparedBytes = encodeLocalCompletionEntry reference permit report absence
    }
 where
  reference =
    LocalCompletionReference
      { localCompletionReferenceRunId = hostCleanupRunnerRunId context
      , localCompletionReferenceGraphDigest = hostCleanupRunnerGraphDigest context
      , localCompletionReferenceScope = hostCleanupRunnerObservationScope context
      , localCompletionReferenceOperationId =
          hostCleanupRunnerCompletionOperationId context
      }
  permit = localCompletionPermitIdText (hostCleanupRunnerReadyPermitId context)
  report = cascadeReportDigestText (hostCleanupRunnerReadyReportDigest context)
  absence = absenceEvidenceText (localUninstallAbsenceEvidence local)

-- ---------------------------------------------------------------------------
-- The on-disk entry
-- ---------------------------------------------------------------------------

localCompletionEntryVersion :: Word16
localCompletionEntryVersion = 1

-- | Fixed ceiling for one entry.  The entry is a handful of identities and
-- digests, so anything larger is a decode refusal rather than a read.
maximumLocalCompletionEntryBytes :: Int
maximumLocalCompletionEntryBytes = 16 * 1024

data LocalCompletionEntryEnvelope = LocalCompletionEntryEnvelope
  { envelopeVersion :: !Word16
  , envelopeRunId :: !Text
  , envelopeGraphDigest :: !Text
  , envelopeCleanupSurface :: !Int
  , envelopeRegistryRevision :: !Text
  , envelopeObservationRunScope :: !Text
  , envelopeFoundationId :: !Text
  , envelopeAwsAccountId :: !(Maybe Text)
  , envelopeAwsRegion :: !(Maybe Text)
  , envelopeLifecycleOperation :: !Word16
  , envelopeCompletionOperationId :: !Text
  , envelopePermitId :: !Text
  , envelopeReportDigest :: !Text
  , envelopeUninstallAbsence :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeLocalCompletionEntry
  :: LocalCompletionReference -> Text -> Text -> Text -> ByteString
encodeLocalCompletionEntry reference permit report absence =
  LazyByteString.toStrict
    ( serialise
        LocalCompletionEntryEnvelope
          { envelopeVersion = localCompletionEntryVersion
          , envelopeRunId = cleanupRunIdText (localCompletionReferenceRunId reference)
          , envelopeGraphDigest =
              cleanupDigestText (localCompletionReferenceGraphDigest reference)
          , envelopeCleanupSurface = fromEnum (evidenceCleanupSurface scope)
          , envelopeRegistryRevision = registryRevisionText (evidenceRegistryRevision scope)
          , envelopeObservationRunScope = durableRunScopeText (evidenceDurableRunScope scope)
          , envelopeFoundationId = foundationIdText (evidenceLinuxRke2Foundation scope)
          , envelopeAwsAccountId = accountIdText . awsScopeAccountId <$> evidenceAwsScope scope
          , envelopeAwsRegion = regionText . awsScopeRegion <$> evidenceAwsScope scope
          , envelopeLifecycleOperation =
              encodeLifecycleOperation (evidenceLifecycleOperation scope)
          , envelopeCompletionOperationId =
              cleanupOperationIdText (localCompletionReferenceOperationId reference)
          , envelopePermitId = permit
          , envelopeReportDigest = report
          , envelopeUninstallAbsence = absence
          }
    )
 where
  scope = localCompletionReferenceScope reference

-- | One journal entry, decoded from durable bytes alone.
data ObservedLocalCompletion = ObservedLocalCompletion
  { observedLocalCompletionReference :: !LocalCompletionReference
  , observedLocalCompletionPermitId :: !Text
  , observedLocalCompletionReportDigest :: !Text
  , observedLocalCompletionAbsence :: !Text
  , observedLocalCompletionDigest :: !CleanupDigest
  }
  deriving (Eq, Show)

decodeLocalCompletionEntry :: ByteString -> Either Text ObservedLocalCompletion
decodeLocalCompletionEntry bytes
  | ByteString.length bytes > maximumLocalCompletionEntryBytes =
      Left "cleanup completion entry exceeds its fixed ceiling"
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left "cleanup completion entry is not a valid envelope"
      Right envelope
        | envelopeVersion envelope /= localCompletionEntryVersion ->
            Left "cleanup completion entry has an unsupported version"
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left "cleanup completion entry is not canonically encoded"
        | otherwise -> decodeEnvelope envelope
 where
  decodeEnvelope envelope = do
    runId <- mkCleanupRunId (envelopeRunId envelope)
    graphDigest <- mkCleanupDigest (envelopeGraphDigest envelope)
    surface <- decodeCleanupSurface (envelopeCleanupSurface envelope)
    operation <- decodeLifecycleOperation (envelopeLifecycleOperation envelope)
    awsScope <-
      decodeAwsScope (envelopeAwsAccountId envelope) (envelopeAwsRegion envelope)
    operationId <- mkCleanupOperationId (envelopeCompletionOperationId envelope)
    let scope =
          mkObservationEvidenceScope
            surface
            (RegistryRevision (envelopeRegistryRevision envelope))
            (DurableObservationRunScope (envelopeObservationRunScope envelope))
            (LinuxRke2FoundationId (envelopeFoundationId envelope))
            awsScope
            operation
    Right
      ObservedLocalCompletion
        { observedLocalCompletionReference =
            LocalCompletionReference
              { localCompletionReferenceRunId = runId
              , localCompletionReferenceGraphDigest = graphDigest
              , localCompletionReferenceScope = scope
              , localCompletionReferenceOperationId = operationId
              }
        , observedLocalCompletionPermitId = envelopePermitId envelope
        , observedLocalCompletionReportDigest = envelopeReportDigest envelope
        , observedLocalCompletionAbsence = envelopeUninstallAbsence envelope
        , observedLocalCompletionDigest = cleanupDigestOfBytes bytes
        }

decodeCleanupSurface :: Int -> Either Text CleanupSurface
decodeCleanupSurface raw
  | raw < fromEnum (minBound :: CleanupSurface)
      || raw > fromEnum (maxBound :: CleanupSurface) =
      Left "cleanup completion entry names a cleanup surface outside the closed enum"
  | otherwise = Right (toEnum raw)

encodeLifecycleOperation :: LifecycleOperation -> Word16
encodeLifecycleOperation = \case
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

decodeLifecycleOperation :: Word16 -> Either Text LifecycleOperation
decodeLifecycleOperation = \case
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  _ -> Left "cleanup completion entry names an unknown lifecycle operation"

decodeAwsScope :: Maybe Text -> Maybe Text -> Either Text (Maybe AwsScope)
decodeAwsScope account region = case (account, region) of
  (Nothing, Nothing) -> Right Nothing
  (Just accountId, Just regionId) ->
    Right (Just (AwsScope (AwsAccountId accountId) (AwsRegion regionId)))
  _ -> Left "cleanup completion entry carries a partial AWS scope"

-- ---------------------------------------------------------------------------
-- Appending
-- ---------------------------------------------------------------------------

-- | What one append attempt established about the journal.
data LocalCompletionAppend
  = -- | The entry was published by this attempt.
    LocalCompletionAppended
  | -- | An entry for this reference was already present and matches the
    -- prepared bytes.  A replay after a lost append response lands here.
    LocalCompletionAlreadyPresent
  | -- | An entry for this reference is present and differs.  The host does not
    -- rewrite a completion it already recorded.
    LocalCompletionConflicted !Text
  | -- | The append could not be performed.  Whether anything landed is decided
    -- by the observation, never by this answer.
    LocalCompletionAppendFailed !Text
  deriving (Eq, Show)

renderLocalCompletionAppend :: LocalCompletionAppend -> Text
renderLocalCompletionAppend = \case
  LocalCompletionAppended -> "local completion entry appended"
  LocalCompletionAlreadyPresent ->
    "local completion entry was already present and matches"
  LocalCompletionConflicted detail ->
    "local completion entry conflicts with the durable one: " <> detail
  LocalCompletionAppendFailed detail ->
    "local completion append failed: " <> detail

-- | Idempotently append the prepared entry.
--
-- The bytes are written to a staging sibling, fsynced, and published by an
-- exclusive link.  A link that reports @EEXIST@ is not an error: the durable
-- entry is read and compared, so a rerun whose first append response was lost
-- observes its own entry rather than writing a second one.
appendLocalCompletion
  :: HostCleanupCompletionJournal
  -> PreparedLocalCompletion
  -> IO LocalCompletionAppend
appendLocalCompletion journal prepared = do
  attempt <- try publish
  case attempt :: Either IOException LocalCompletionAppend of
    Left err -> pure (LocalCompletionAppendFailed (Text.pack (show err)))
    Right outcome -> pure outcome
 where
  reference = internalPreparedReference prepared
  bytes = internalPreparedBytes prepared
  entryPath = hostCleanupCompletionEntryPath journal reference
  stagingPath = hostCleanupCompletionStagingPath journal reference

  publish = do
    createDirectoryIfMissing True (hostCleanupCompletionJournalRoot journal)
    linked <- mask_ $ do
      writeStaged
      link <- try (createLink stagingPath entryPath)
      discardStaged
      pure link
    case linked :: Either IOException () of
      Right () -> do
        syncJournalDirectory journal
        pure LocalCompletionAppended
      Left err
        | isAlreadyExistsError err -> compareDurable
        | otherwise -> pure (LocalCompletionAppendFailed (Text.pack (show err)))

  writeStaged =
    bracket
      ( openFd
          stagingPath
          WriteOnly
          defaultFileFlags
            { trunc = True
            , creat = Just entryFileMode
            , nofollow = True
            , cloexec = True
            }
      )
      safeCloseFd
      ( \fd -> do
          setFdMode fd entryFileMode
          status <- getFdStatus fd
          if not (isRegularFile status)
            then failWith "cleanup completion staging path is not a regular file"
            else do
              writeAll fd bytes
              fileSynchronise fd
      )

  discardStaged = do
    removed <- try (removeLink stagingPath)
    case removed :: Either IOException () of
      Left _ -> pure ()
      Right () -> pure ()

  compareDurable = do
    durable <- readEntryBytes entryPath
    pure $ case durable of
      Left detail -> LocalCompletionAppendFailed detail
      Right Nothing ->
        LocalCompletionAppendFailed
          "durable local completion entry disappeared between link and read"
      Right (Just durableBytes)
        | durableBytes == bytes -> LocalCompletionAlreadyPresent
        | otherwise ->
            LocalCompletionConflicted
              ( "durable entry digest is "
                  <> cleanupDigestText (cleanupDigestOfBytes durableBytes)
                  <> " and the prepared entry digest is "
                  <> cleanupDigestText (cleanupDigestOfBytes bytes)
              )

-- | Project the append onto the runner's mutation answer.
--
-- A conflict and an append failure are both refusals rather than losses: this
-- boundary either published the entry or read the durable one, so it never has
-- to say that it does not know what happened.  What the entry proves is still
-- decided by the separate observation.
localCompletionAppendOutcome :: LocalCompletionAppend -> HostCleanupEffectOutcome
localCompletionAppendOutcome = \case
  LocalCompletionAppended -> HostCleanupEffectApplied
  LocalCompletionAlreadyPresent -> HostCleanupEffectApplied
  LocalCompletionConflicted detail -> HostCleanupEffectRefused detail
  LocalCompletionAppendFailed detail -> HostCleanupEffectRefused detail

-- ---------------------------------------------------------------------------
-- Observing
-- ---------------------------------------------------------------------------

-- | What a separate observation of one reference found.
data LocalCompletionObservation
  = LocalCompletionObserved !ObservedLocalCompletion
  | -- | The journal is readable and holds no entry for this reference.
    LocalCompletionMissing
  | -- | The journal said nothing.  Deliberately not @Missing@: an unreadable
    -- directory has not established that no completion was appended.
    LocalCompletionUnobservable !Text
  deriving (Eq, Show)

-- | Observe one reference.
--
-- The observation reads the journal and decodes what it holds.  It takes no
-- append result as an input, so an append that reported success over a journal
-- holding nothing observable produces no receipt.
observeLocalCompletion
  :: HostCleanupCompletionJournal
  -> LocalCompletionReference
  -> IO LocalCompletionObservation
observeLocalCompletion journal reference = do
  durable <- readEntryBytes (hostCleanupCompletionEntryPath journal reference)
  pure $ case durable of
    Left detail -> LocalCompletionUnobservable detail
    Right Nothing -> LocalCompletionMissing
    Right (Just bytes) -> case decodeLocalCompletionEntry bytes of
      Left detail -> LocalCompletionUnobservable detail
      Right observed -> LocalCompletionObserved observed

-- | Join one observation with the readiness and absence proofs to mint the
-- completion read-back.
--
-- Every identity in the result is the decoded entry's.  The readiness and the
-- absence evidence are inputs to the private completion constructor and are
-- never consulted for a field of the read-back, so the runner's later
-- comparison of the read-back against its own context compares two independent
-- sources.
localCompletionReadBack
  :: ReadyToUninstallEvidence
  -> LocalUninstallEvidence 'Cascade
  -> LocalCompletionObservation
  -> Either Text HostCleanupCompletionReadBack
localCompletionReadBack ready local observation = case observation of
  LocalCompletionMissing ->
    Left "the preserved cleanup journal holds no local completion entry"
  LocalCompletionUnobservable detail ->
    Left ("the preserved cleanup journal is unobservable: " <> detail)
  LocalCompletionObserved observed -> do
    permitId <- mkLocalCompletionPermitId (observedLocalCompletionPermitId observed)
    reportDigest <- mkCascadeReportDigest (observedLocalCompletionReportDigest observed)
    let reference = observedLocalCompletionReference observed
        durable =
          DurableReceiptObservation
            { durableReceiptObservationKind = CascadeCompletionReceipt
            , durableReceiptObservationScope = localCompletionReferenceScope reference
            , durableReceiptObservationGraphDigest =
                localCompletionReferenceGraphDigest reference
            , durableReceiptObservationResult = DurableReceiptObserved
            }
        receipt =
          CascadeCompletionReceiptObservation
            { cascadeCompletionReceiptPermitId = permitId
            , cascadeCompletionReceiptReportDigest = reportDigest
            , cascadeCompletionReceipt = durable
            }
    evidence <-
      either
        (Left . Text.pack . show)
        Right
        (mkCascadeCompleteEvidence ready local receipt)
    Right
      HostCleanupCompletionReadBack
        { hostCompletionReadBackRunId = localCompletionReferenceRunId reference
        , hostCompletionReadBackGraphDigest =
            localCompletionReferenceGraphDigest reference
        , hostCompletionReadBackScope = localCompletionReferenceScope reference
        , hostCompletionReadBackOperationId =
            localCompletionReferenceOperationId reference
        , hostCompletionReadBackReceiptDigest = observedLocalCompletionDigest observed
        , hostCompletionReadBackObservation = receipt
        , hostCompletionReadBackEvidence = evidence
        }

-- ---------------------------------------------------------------------------
-- Production effect arms
-- ---------------------------------------------------------------------------

-- | The production commit arm: prepare the entry and idempotently append it.
productionHostCleanupCompletionCommit
  :: HostCleanupCompletionJournal
  -> HostCleanupRunnerContext
  -> LocalUninstallEvidence 'Cascade
  -> IO HostCleanupEffectOutcome
productionHostCleanupCompletionCommit journal context local =
  localCompletionAppendOutcome
    <$> appendLocalCompletion journal (prepareLocalCompletion context local)

-- | The production read-back arm: observe the same reference separately.
--
-- The reference is derived from the running context rather than carried over
-- from an append, so the observation addresses the reference the run is
-- completing even in an attempt where no append ran at all.
productionHostCleanupCompletionReadBack
  :: HostCleanupCompletionJournal
  -> ReadyToUninstallEvidence
  -> LocalUninstallEvidence 'Cascade
  -> HostCleanupRunnerContext
  -> IO (Either Text HostCleanupCompletionReadBack)
productionHostCleanupCompletionReadBack journal ready local context = do
  observation <-
    observeLocalCompletion
      journal
      (preparedLocalCompletionReference (prepareLocalCompletion context local))
  pure (localCompletionReadBack ready local observation)

-- ---------------------------------------------------------------------------
-- Filesystem helpers
-- ---------------------------------------------------------------------------

entryFileMode :: FileMode
entryFileMode = ownerReadMode `unionFileModes` ownerWriteMode

-- | Read one entry.  @Right Nothing@ is a readable journal with no entry for
-- this reference; @Left@ is a journal that answered nothing.
readEntryBytes :: FilePath -> IO (Either Text (Maybe ByteString))
readEntryBytes path = do
  attempt <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          safeCloseFd
          readOpenEntry
      )
  pure $ case attempt :: Either IOException ByteString of
    Left err
      | isDoesNotExistError err -> Right Nothing
      | otherwise -> Left (Text.pack (show err))
    Right bytes -> Right (Just bytes)

readOpenEntry :: Fd -> IO ByteString
readOpenEntry fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then failWith "cleanup completion entry path is not a regular file"
    else readFdBounded fd (maximumLocalCompletionEntryBytes + 1)

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        attempt <-
          try (PosixByteString.fdRead fd (fromIntegral (min remaining (16 * 1024))))
        case attempt of
          Left (err :: IOException)
            | isEOFError err -> pure (ByteString.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then failWith "cleanup completion write made no progress"
    else writeAll fd (ByteString.drop count bytes)

syncJournalDirectory :: HostCleanupCompletionJournal -> IO ()
syncJournalDirectory journal =
  bracket
    ( openFd
        (hostCleanupCompletionJournalRoot journal)
        ReadOnly
        defaultFileFlags {nofollow = True, cloexec = True}
    )
    safeCloseFd
    fileSynchronise

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = do
  closed <- try (closeFd fd)
  case closed :: Either IOException () of
    Left _ -> pure ()
    Right () -> pure ()

failWith :: String -> IO value
failWith = ioError . userError

-- ---------------------------------------------------------------------------
-- Regression over the package-private fixture
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without any authority-bearing value
-- leaving this package.
data LocalCompletionRegression = LocalCompletionRegression
  { localCompletionRegressionAppendedBecomesReceipt :: !Bool
  , localCompletionRegressionAppendIsIdempotent :: !Bool
  , localCompletionRegressionConflictRefusesRewrite :: !Bool
  , localCompletionRegressionMissingIsNotUnobservable :: !Bool
  , localCompletionRegressionUnobservableRefused :: !Bool
  , localCompletionRegressionReadBackCarriesDecodedIdentity :: !Bool
  , localCompletionRegressionForeignProofsRefused :: !Bool
  , localCompletionRegressionAppendResponseNotEvidence :: !Bool
  , localCompletionRegressionEntryPathIsReferenceKeyed :: !Bool
  }

fixedLocalCompletionRegression :: IO (Either Text LocalCompletionRegression)
fixedLocalCompletionRegression =
  case fixedLocalCompletionScenario of
    Left err -> pure (Left err)
    Right scenario -> Right <$> runFixedLocalCompletionRegression scenario

data FixedLocalCompletionScenario = FixedLocalCompletionScenario
  { fixedCompletionContext :: !HostCleanupRunnerContext
  , fixedCompletionReady :: !ReadyToUninstallEvidence
  , fixedCompletionLocal :: !(LocalUninstallEvidence 'Cascade)
  , fixedCompletionOtherContext :: !HostCleanupRunnerContext
  , fixedCompletionOtherLocal :: !(LocalUninstallEvidence 'Cascade)
  }

fixedLocalCompletionScenario :: Either Text FixedLocalCompletionScenario
fixedLocalCompletionScenario = do
  (run, ready, local) <-
    withFixedCascadeEvidenceFixtureInternal
      (\_compiled run ready local _complete -> (run, ready, local))
  (otherRun, otherReady, otherLocal) <-
    withCascadeEvidenceFixtureForRunInternal
      "cleanup-run/local-completion-fixed-other"
      (\_compiled run' ready' local' _complete -> (run', ready', local'))
  context <- fixedCompletionContextFor run ready
  otherContext <- fixedCompletionContextFor otherRun otherReady
  pure
    FixedLocalCompletionScenario
      { fixedCompletionContext = context
      , fixedCompletionReady = ready
      , fixedCompletionLocal = local
      , fixedCompletionOtherContext = otherContext
      , fixedCompletionOtherLocal = otherLocal
      }

-- | Build the running context the terminal node would hold, from the fixture's
-- own run and readiness.  Only public host-cleanup constructors are used, so
-- this creates no authority the runner does not already require.
fixedCompletionContextFor
  :: CleanupRun -> ReadyToUninstallEvidence -> Either Text HostCleanupRunnerContext
fixedCompletionContextFor run ready = do
  scope <-
    mapFixedLeft (mkHostCleanupScope (cleanupRunId run) (readyToUninstallScope ready))
  permit <-
    mapFixedLeft
      ( mkHostTerminalPermitId
          (localCompletionPermitIdText (readyToUninstallPermitId ready))
      )
  intent <- fixedCompletionIntent run scope permit
  mapFixedLeft (validateHostCleanupReady intent ready)
 where
  fixedCompletionIntent run' scope permit =
    mapFixedLeft
      ( mkHostCleanupIntent
          (cleanupRunId run')
          (cleanupRunGraphDigest run')
          run'
          scope
          ( mkHostCleanupTerminalIdentity
              ( cascadeLocalUninstallOperationId
                  (readyToUninstallOperationReferences ready)
              )
              permit
          )
      )
      :: Either Text HostCleanupIntent

mapFixedLeft :: (Show err) => Either err value -> Either Text value
mapFixedLeft = either (Left . Text.pack . show) Right

runFixedLocalCompletionRegression
  :: FixedLocalCompletionScenario -> IO LocalCompletionRegression
runFixedLocalCompletionRegression scenario =
  withSystemTempDirectory "prodbox-local-completion-fixed" $ \root -> do
    appended <- inJournal root "appended" $ \journal -> do
      first <- appendLocalCompletion journal prepared
      observation <- observeLocalCompletion journal reference
      pure (first, localCompletionReadBack ready local observation)
    idempotent <- inJournal root "idempotent" $ \journal -> do
      _ <- appendLocalCompletion journal prepared
      second <- appendLocalCompletion journal prepared
      observation <- observeLocalCompletion journal reference
      pure (second, localCompletionReadBack ready local observation)
    conflicted <- inJournal root "conflict" $ \journal -> do
      placeEntryBytes journal reference conflictingBytes
      appendLocalCompletion journal prepared
    missing <- inJournal root "missing" $ \journal -> do
      observation <- observeLocalCompletion journal reference
      pure (observation, localCompletionReadBack ready local observation)
    unobservable <- inJournal root "unobservable" $ \journal -> do
      placeEntryBytes journal reference "not a cleanup completion entry"
      observation <- observeLocalCompletion journal reference
      pure (observation, localCompletionReadBack ready local observation)
    foreign' <- inJournal root "foreign" $ \journal -> do
      _ <- appendLocalCompletion journal otherPrepared
      observation <- observeLocalCompletion journal otherReference
      pure (localCompletionReadBack ready local observation)
    responseNotEvidence <- inJournal root "response" $ \journal -> do
      applied <- appendLocalCompletion journal prepared
      removeEntry journal reference
      observation <- observeLocalCompletion journal reference
      pure (applied, localCompletionReadBack ready local observation)
    let (_, appendedReadBack) = appended
        (secondAppend, idempotentReadBack) = idempotent
        (missingObservation, missingReadBack) = missing
        (unobservableObservation, unobservableReadBack) = unobservable
        (appliedResponse, lostReadBack) = responseNotEvidence
    pure
      LocalCompletionRegression
        { localCompletionRegressionAppendedBecomesReceipt =
            fst appended == LocalCompletionAppended && isRight appendedReadBack
        , localCompletionRegressionAppendIsIdempotent =
            secondAppend == LocalCompletionAlreadyPresent && isRight idempotentReadBack
        , localCompletionRegressionConflictRefusesRewrite =
            isConflict conflicted
        , localCompletionRegressionMissingIsNotUnobservable =
            missingObservation == LocalCompletionMissing && isLeft missingReadBack
        , localCompletionRegressionUnobservableRefused =
            isUnobservable unobservableObservation && isLeft unobservableReadBack
        , localCompletionRegressionReadBackCarriesDecodedIdentity =
            carriesDecodedIdentity appendedReadBack
        , localCompletionRegressionForeignProofsRefused = isLeft foreign'
        , -- The append reported that it applied and the entry is then gone, so
          -- the run has only the writer's word for it.  The observation is what
          -- refuses.
          localCompletionRegressionAppendResponseNotEvidence =
            appliedResponse == LocalCompletionAppended && isLeft lostReadBack
        , localCompletionRegressionEntryPathIsReferenceKeyed =
            referenceKeyedPaths
        }
 where
  context = fixedCompletionContext scenario
  ready = fixedCompletionReady scenario
  local = fixedCompletionLocal scenario
  prepared = prepareLocalCompletion context local
  reference = preparedLocalCompletionReference prepared
  otherPrepared =
    prepareLocalCompletion
      (fixedCompletionOtherContext scenario)
      (fixedCompletionOtherLocal scenario)
  otherReference = preparedLocalCompletionReference otherPrepared
  conflictingBytes =
    encodeLocalCompletionEntry
      reference
      "adifferentpermitidentity"
      (cascadeReportDigestText (hostCleanupRunnerReadyReportDigest context))
      (absenceEvidenceText (localUninstallAbsenceEvidence local))

  carriesDecodedIdentity = \case
    Left _ -> False
    Right readBack ->
      hostCompletionReadBackRunId readBack == localCompletionReferenceRunId reference
        && hostCompletionReadBackGraphDigest readBack
          == localCompletionReferenceGraphDigest reference
        && hostCompletionReadBackScope readBack
          == localCompletionReferenceScope reference
        && hostCompletionReadBackOperationId readBack
          == localCompletionReferenceOperationId reference
        && hostCompletionReadBackReceiptDigest readBack
          == preparedLocalCompletionDigest prepared

  referenceKeyedPaths = case mkHostCleanupCompletionJournal "/retained/control" of
    Left _ -> False
    Right journal ->
      hostCleanupCompletionEntryPath journal reference
        /= hostCleanupCompletionEntryPath journal otherReference
        && takeFileName (hostCleanupCompletionEntryPath journal reference)
          == Text.unpack (cleanupDigestText (localCompletionReferenceDigest reference))
            <> ".cbor"

inJournal
  :: FilePath -> FilePath -> (HostCleanupCompletionJournal -> IO result) -> IO result
inJournal root leaf use = do
  let control = root </> leaf
  createDirectoryIfMissing True control
  case mkHostCleanupCompletionJournal control of
    Left err -> failWith (Text.unpack err)
    Right journal -> use journal

placeEntryBytes
  :: HostCleanupCompletionJournal
  -> LocalCompletionReference
  -> ByteString
  -> IO ()
placeEntryBytes journal reference bytes = do
  createDirectoryIfMissing True (hostCleanupCompletionJournalRoot journal)
  bracket
    ( openFd
        (hostCleanupCompletionEntryPath journal reference)
        WriteOnly
        defaultFileFlags
          { trunc = True
          , creat = Just entryFileMode
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    (\fd -> writeAll fd bytes)

removeEntry :: HostCleanupCompletionJournal -> LocalCompletionReference -> IO ()
removeEntry journal reference =
  removeLink (hostCleanupCompletionEntryPath journal reference)

isConflict :: LocalCompletionAppend -> Bool
isConflict = \case
  LocalCompletionConflicted _ -> True
  _ -> False

isUnobservable :: LocalCompletionObservation -> Bool
isUnobservable = \case
  LocalCompletionUnobservable _ -> True
  _ -> False

isRight :: Either left right -> Bool
isRight = either (const False) (const True)

isLeft :: Either left right -> Bool
isLeft = either (const True) (const False)
