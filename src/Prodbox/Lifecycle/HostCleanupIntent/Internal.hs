{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Host-durable intent for the destructive boundary of one cleanup run.
--
-- The caller supplies a retained host root.  This module owns one active,
-- versioned file below that root and never replaces a different active intent,
-- including a completed one.  Every accepted write is fsynced, atomically
-- published, parent-fsynced, and positively read back before success is
-- returned.  A completed intent becomes replaceable only through explicit,
-- exact retirement.
module Prodbox.Lifecycle.HostCleanupIntent.Internal
  ( HostCleanupIntentStore
  , mkHostCleanupIntentStore
  , hostCleanupIntentRetainedRoot
  , hostCleanupIntentPath
  , hostCleanupIntentRetiredPath
  , hostCleanupIntentFormatVersion
  , maximumHostCleanupIntentBytes
  , HostCleanupScope
  , mkHostCleanupScope
  , hostCleanupFoundationId
  , hostCleanupObservationRunScope
  , hostCleanupObservationEvidenceScope
  , HostTerminalPermitId
  , mkHostTerminalPermitId
  , hostTerminalPermitIdText
  , HostCleanupTerminalIdentity
  , mkHostCleanupTerminalIdentity
  , hostCleanupTerminalOperationId
  , hostCleanupTerminalPermitId
  , HostCleanupReadyBinding
  , hostCleanupReadyRunId
  , hostCleanupReadyGraphDigest
  , hostCleanupReadyScope
  , hostCleanupReadyReportDigest
  , hostCleanupReadyPermitId
  , hostCleanupReadyUninstallOperationId
  , hostCleanupReadyCompletionOperationId
  , HostCleanupIntentPhase (..)
  , HostCleanupIntent
  , mkHostCleanupIntent
  , hostCleanupRunId
  , hostCleanupGraphDigest
  , hostCleanupRun
  , hostCleanupScope
  , hostCleanupTerminalIdentity
  , hostCleanupReadyBinding
  , hostCleanupIntentPhase
  , hostCleanupCompletionReceiptDigest
  , bindHostCleanupReady
  , hostCleanupReadyMatches
  , advanceHostCleanupIntent
  , encodeHostCleanupIntent
  , decodeHostCleanupIntent
  , ObservedHostCleanupIntent
  , observedHostCleanupIntent
  , restoreObservedHostCleanupReady
  , observeHostCleanupIntentForResume
  , withHostCleanupExecutionLease
  , observeHostCleanupIntent
  , prepareHostCleanupIntent
  , persistHostCleanupReady
  , transitionHostCleanupIntent
  , markHostCleanupAuthorityAccepted
  , markHostCleanupTerminalArmed
  , markHostLocalAbsenceRecorded
  , markHostCleanupAuthorityReconciled
  , markHostCleanupComplete
  , HostCleanupIntentRetirementDigest
  , hostCleanupIntentRetirementDigestText
  , HostCleanupIntentRetirement (..)
  , retireHostCleanupIntent
  , HostCleanupIntentRegression
  , fixedHostCleanupIntentRegression
  , hostCleanupIntentRegressionBoundCodec
  , hostCleanupIntentRegressionBoundPreparationRefused
  , hostCleanupIntentRegressionReadyReadBack
  , hostCleanupIntentRegressionPhaseReplay
  , hostCleanupIntentRegressionRetirementReplay
  , HostCleanupIntentError (..)
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception
  ( IOException
  , bracket
  , finally
  , mask
  , mask_
  , onException
  , throwIO
  , try
  )
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRun (cleanupRunGraph, cleanupRunGraphDigest, cleanupRunId)
  , CleanupRunCodecError
  , CleanupRunId
  , cleanupGraphDigest
  , cleanupRunIdText
  , decodeCleanupRun
  , encodeCleanupRun
  , mkCleanupDigest
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeEvidenceError
  , CascadeReportDigest
  , DurableReadyToUninstallBinding
  , LocalCompletionPermitId
  , ReadyToUninstallEvidence
  , captureDurableReadyToUninstallBinding
  , cascadeLocalCompletionOperationId
  , cascadeLocalUninstallOperationId
  , encodeDurableReadyToUninstallBinding
  , localCompletionPermitIdText
  , observeDurableReadyToUninstallBinding
  , readyBindingObservationGraphDigest
  , readyBindingObservationOperationReferences
  , readyBindingObservationPermitId
  , readyBindingObservationReportDigest
  , readyBindingObservationRunId
  , readyBindingObservationScope
  , readyToUninstallOperationReferences
  , readyToUninstallPermitId
  , readyToUninstallScope
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( decodeDurableReadyToUninstallBinding
  , restoreReadyToUninstallEvidence
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
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
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , renameFile
  )
import System.FilePath (isAbsolute, normalise, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files
  ( FileStatus
  , accessModes
  , createLink
  , fileMode
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , intersectFileModes
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , ownerModes
  , ownerReadMode
  , ownerWriteMode
  , removeLink
  , setFdMode
  , setFileMode
  , unionFileModes
  )
import System.Posix.IO
  ( LockRequest (Unlock, WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , setLock
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

newtype HostCleanupIntentStore = HostCleanupIntentStore
  { internalRetainedRoot :: FilePath
  }
  deriving stock (Eq, Show)

mkHostCleanupIntentStore :: FilePath -> Either HostCleanupIntentError HostCleanupIntentStore
mkHostCleanupIntentStore retainedRoot
  | not (isAbsolute retainedRoot) =
      Left (HostCleanupIntentStoreInvalid "retained root must be absolute")
  | normalise retainedRoot == "/" =
      Left (HostCleanupIntentStoreInvalid "retained root must not be the filesystem root")
  | otherwise = Right (HostCleanupIntentStore (normalise retainedRoot))

hostCleanupIntentRetainedRoot :: HostCleanupIntentStore -> FilePath
hostCleanupIntentRetainedRoot = internalRetainedRoot

hostCleanupIntentDirectory :: HostCleanupIntentStore -> FilePath
hostCleanupIntentDirectory store =
  hostCleanupIntentRetainedRoot store </> "host-cleanup-intent"

hostCleanupIntentPath :: HostCleanupIntentStore -> FilePath
hostCleanupIntentPath store = hostCleanupIntentDirectory store </> "active-v1.cbor"

hostCleanupIntentTemporaryPath :: HostCleanupIntentStore -> FilePath
hostCleanupIntentTemporaryPath store =
  hostCleanupIntentDirectory store </> ".active-v1.cbor.tmp"

hostCleanupIntentLockPath :: HostCleanupIntentStore -> FilePath
hostCleanupIntentLockPath store =
  hostCleanupIntentDirectory store </> ".host-cleanup-intent.lock"

hostCleanupIntentFormatVersion :: Word16
hostCleanupIntentFormatVersion = 2

maximumCleanupRunBytes :: Int
maximumCleanupRunBytes = 512 * 1024

-- | Fixed pre-allocation bound for the complete on-disk envelope.
maximumHostCleanupIntentBytes :: Int
maximumHostCleanupIntentBytes = maximumCleanupRunBytes + (128 * 1024)

data HostCleanupScope = HostCleanupScope
  { internalCleanupSurface :: !CleanupSurface
  , internalRegistryRevision :: !Text
  , internalDurableRunScope :: !Text
  , internalFoundationId :: !Text
  , internalAwsAccountId :: !(Maybe Text)
  , internalAwsRegion :: !(Maybe Text)
  , internalLifecycleOperation :: !LifecycleOperation
  }
  deriving stock (Eq, Show)

mkHostCleanupScope
  :: CleanupRunId
  -> ObservationEvidenceScope
  -> Either HostCleanupIntentError HostCleanupScope
mkHostCleanupScope expectedRunId evidence = do
  let surface = evidenceCleanupSurface evidence
      RegistryRevision revision = evidenceRegistryRevision evidence
      DurableObservationRunScope observation = evidenceDurableRunScope evidence
      LinuxRke2FoundationId foundation = evidenceLinuxRke2Foundation evidence
      operation = evidenceLifecycleOperation evidence
  if surface == Cascade
    then Right ()
    else Left (HostCleanupIntentScopeSurfaceMismatch surface)
  if operation == ReconcileDesiredAbsent
    then Right ()
    else Left (HostCleanupIntentScopeOperationMismatch operation)
  if observation == cleanupRunIdText expectedRunId
    then Right ()
    else Left HostCleanupIntentScopeRunIdMismatch
  revision' <- validateIdentity "registry revision" revision
  foundation' <- validateIdentity "Linux RKE2 foundation id" foundation
  observation' <- validateIdentity "durable observation run scope" observation
  (account, region) <- validateAwsScope (evidenceAwsScope evidence)
  Right
    HostCleanupScope
      { internalCleanupSurface = surface
      , internalRegistryRevision = revision'
      , internalDurableRunScope = observation'
      , internalFoundationId = foundation'
      , internalAwsAccountId = account
      , internalAwsRegion = region
      , internalLifecycleOperation = operation
      }

validateAwsScope
  :: Maybe AwsScope
  -> Either HostCleanupIntentError (Maybe Text, Maybe Text)
validateAwsScope Nothing = Right (Nothing, Nothing)
validateAwsScope (Just (AwsScope (AwsAccountId account) (AwsRegion region))) = do
  if Text.length account == 12 && Text.all (\character -> isAscii character && isDigit character) account
    then Right ()
    else
      Left
        ( HostCleanupIntentIdentityInvalid
            "AWS account id must contain exactly 12 ASCII digits"
        )
  region' <- validateIdentity "AWS region" region
  Right (Just account, Just region')

hostCleanupFoundationId :: HostCleanupScope -> LinuxRke2FoundationId
hostCleanupFoundationId = LinuxRke2FoundationId . internalFoundationId

hostCleanupObservationRunScope :: HostCleanupScope -> DurableObservationRunScope
hostCleanupObservationRunScope =
  DurableObservationRunScope . internalDurableRunScope

hostCleanupObservationEvidenceScope :: HostCleanupScope -> ObservationEvidenceScope
hostCleanupObservationEvidenceScope scope =
  mkObservationEvidenceScope
    (internalCleanupSurface scope)
    (RegistryRevision (internalRegistryRevision scope))
    (DurableObservationRunScope (internalDurableRunScope scope))
    (LinuxRke2FoundationId (internalFoundationId scope))
    ( case (internalAwsAccountId scope, internalAwsRegion scope) of
        (Just account, Just region) ->
          Just (AwsScope (AwsAccountId account) (AwsRegion region))
        _ -> Nothing
    )
    (internalLifecycleOperation scope)

newtype HostTerminalPermitId = HostTerminalPermitId Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkHostTerminalPermitId :: Text -> Either HostCleanupIntentError HostTerminalPermitId
mkHostTerminalPermitId =
  fmap HostTerminalPermitId . validateIdentity "terminal permit id"

hostTerminalPermitIdText :: HostTerminalPermitId -> Text
hostTerminalPermitIdText (HostTerminalPermitId value) = value

data HostCleanupTerminalIdentity = HostCleanupTerminalIdentity
  { internalTerminalOperationId :: !CleanupOperationId
  , internalTerminalPermitId :: !HostTerminalPermitId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkHostCleanupTerminalIdentity
  :: CleanupOperationId
  -> HostTerminalPermitId
  -> HostCleanupTerminalIdentity
mkHostCleanupTerminalIdentity = HostCleanupTerminalIdentity

hostCleanupTerminalOperationId :: HostCleanupTerminalIdentity -> CleanupOperationId
hostCleanupTerminalOperationId = internalTerminalOperationId

hostCleanupTerminalPermitId :: HostCleanupTerminalIdentity -> HostTerminalPermitId
hostCleanupTerminalPermitId = internalTerminalPermitId

-- | Canonical, secret-free readiness captured from an already-opaque
-- 'ReadyToUninstallEvidence'.  The constructor remains private; decoding the
-- nested bytes is not enough to use it until the full host run, graph, scope,
-- permit, and both local operation IDs have been validated.
data HostCleanupReadyBinding = HostCleanupReadyBinding
  { internalHostReadyDurableBinding :: !DurableReadyToUninstallBinding
  , internalHostReadyEvidence :: !ReadyToUninstallEvidence
  }
  deriving stock (Eq, Show)

hostCleanupReadyRunId :: HostCleanupReadyBinding -> CleanupRunId
hostCleanupReadyRunId =
  readyBindingObservationRunId
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyGraphDigest :: HostCleanupReadyBinding -> CleanupDigest
hostCleanupReadyGraphDigest =
  readyBindingObservationGraphDigest
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyScope :: HostCleanupReadyBinding -> ObservationEvidenceScope
hostCleanupReadyScope =
  readyBindingObservationScope
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyReportDigest :: HostCleanupReadyBinding -> CascadeReportDigest
hostCleanupReadyReportDigest =
  readyBindingObservationReportDigest
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyPermitId :: HostCleanupReadyBinding -> LocalCompletionPermitId
hostCleanupReadyPermitId =
  readyBindingObservationPermitId
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyUninstallOperationId
  :: HostCleanupReadyBinding -> CleanupOperationId
hostCleanupReadyUninstallOperationId =
  cascadeLocalUninstallOperationId
    . readyBindingObservationOperationReferences
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

hostCleanupReadyCompletionOperationId
  :: HostCleanupReadyBinding -> CleanupOperationId
hostCleanupReadyCompletionOperationId =
  cascadeLocalCompletionOperationId
    . readyBindingObservationOperationReferences
    . observeDurableReadyToUninstallBinding
    . internalHostReadyDurableBinding

data HostCleanupIntentPhase
  = HostCleanupPrepared
  | HostCleanupAuthorityAccepted
  | HostCleanupTerminalArmed
  | HostCleanupLocalAbsenceRecorded
  | HostCleanupAuthorityReconciled
  | HostCleanupComplete
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data HostCleanupIntent = HostCleanupIntent
  { internalCleanupRunId :: !CleanupRunId
  , internalCleanupGraphDigest :: !CleanupDigest
  , internalCleanupRun :: !CleanupRun
  , internalCleanupScope :: !HostCleanupScope
  , internalCleanupTerminalIdentity :: !HostCleanupTerminalIdentity
  , internalCleanupReadyBinding :: !(Maybe HostCleanupReadyBinding)
  , internalCleanupIntentPhase :: !HostCleanupIntentPhase
  , internalCleanupCompletionReceiptDigest :: !(Maybe CleanupDigest)
  }
  deriving stock (Eq, Show)

mkHostCleanupIntent
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupRun
  -> HostCleanupScope
  -> HostCleanupTerminalIdentity
  -> Either HostCleanupIntentError HostCleanupIntent
mkHostCleanupIntent runId graphDigest run scope terminalIdentity =
  validateHostCleanupIntent
    HostCleanupIntent
      { internalCleanupRunId = runId
      , internalCleanupGraphDigest = graphDigest
      , internalCleanupRun = run
      , internalCleanupScope = scope
      , internalCleanupTerminalIdentity = terminalIdentity
      , internalCleanupReadyBinding = Nothing
      , internalCleanupIntentPhase = HostCleanupPrepared
      , internalCleanupCompletionReceiptDigest = Nothing
      }

hostCleanupRunId :: HostCleanupIntent -> CleanupRunId
hostCleanupRunId = internalCleanupRunId

hostCleanupGraphDigest :: HostCleanupIntent -> CleanupDigest
hostCleanupGraphDigest = internalCleanupGraphDigest

hostCleanupRun :: HostCleanupIntent -> CleanupRun
hostCleanupRun = internalCleanupRun

hostCleanupScope :: HostCleanupIntent -> HostCleanupScope
hostCleanupScope = internalCleanupScope

hostCleanupTerminalIdentity :: HostCleanupIntent -> HostCleanupTerminalIdentity
hostCleanupTerminalIdentity = internalCleanupTerminalIdentity

hostCleanupReadyBinding :: HostCleanupIntent -> Maybe HostCleanupReadyBinding
hostCleanupReadyBinding = internalCleanupReadyBinding

hostCleanupIntentPhase :: HostCleanupIntent -> HostCleanupIntentPhase
hostCleanupIntentPhase = internalCleanupIntentPhase

hostCleanupCompletionReceiptDigest :: HostCleanupIntent -> Maybe CleanupDigest
hostCleanupCompletionReceiptDigest = internalCleanupCompletionReceiptDigest

bindHostCleanupReady
  :: HostCleanupIntent
  -> ReadyToUninstallEvidence
  -> Either HostCleanupIntentError HostCleanupIntent
bindHostCleanupReady intent ready
  | hostCleanupIntentPhase intent /= HostCleanupPrepared =
      Left
        ( HostCleanupIntentReadyBindingRequiresPrepared
            (hostCleanupIntentPhase intent)
        )
  | otherwise = do
      binding <-
        canonicalHostCleanupReadyBinding
          (hostCleanupRun intent)
          (hostCleanupScope intent)
          (hostCleanupTerminalIdentity intent)
          ready
      case hostCleanupReadyBinding intent of
        Nothing ->
          validateHostCleanupIntent
            intent {internalCleanupReadyBinding = Just binding}
        Just existing
          | existing == binding -> Right intent
          | otherwise -> Left HostCleanupIntentReadyBindingConflict

restoreHostCleanupReadyUnchecked
  :: HostCleanupIntent
  -> Either HostCleanupIntentError ReadyToUninstallEvidence
restoreHostCleanupReadyUnchecked intent = case hostCleanupReadyBinding intent of
  Nothing ->
    Left
      ( HostCleanupIntentReadyBindingRequired
          (hostCleanupIntentPhase intent)
      )
  Just binding -> do
    validated <- validateHostCleanupReadyBinding intent binding
    Right (internalHostReadyEvidence validated)

-- | Compare an already-opaque Ready proof with the exact durable binding.
-- This deliberately does not return the restored proof, so a caller-decoded
-- host envelope cannot become a Ready minting path.
hostCleanupReadyMatches
  :: HostCleanupIntent
  -> ReadyToUninstallEvidence
  -> Either HostCleanupIntentError Bool
hostCleanupReadyMatches intent supplied =
  (== supplied) <$> restoreHostCleanupReadyUnchecked intent

canonicalHostCleanupReadyBinding
  :: CleanupRun
  -> HostCleanupScope
  -> HostCleanupTerminalIdentity
  -> ReadyToUninstallEvidence
  -> Either HostCleanupIntentError HostCleanupReadyBinding
canonicalHostCleanupReadyBinding run scope terminal ready = do
  durable <-
    either
      (Left . HostCleanupIntentReadyBindingInvalid)
      Right
      (captureDurableReadyToUninstallBinding ready)
  binding <- hostCleanupReadyBindingFromDurable run scope terminal durable
  if internalHostReadyEvidence binding == ready
    then Right binding
    else Left HostCleanupIntentReadyBindingReadBackMismatch

hostCleanupReadyBindingFromDurable
  :: CleanupRun
  -> HostCleanupScope
  -> HostCleanupTerminalIdentity
  -> DurableReadyToUninstallBinding
  -> Either HostCleanupIntentError HostCleanupReadyBinding
hostCleanupReadyBindingFromDurable run scope terminal durable = do
  ready <-
    either
      (Left . HostCleanupIntentReadyBindingInvalid)
      Right
      ( restoreReadyToUninstallEvidence
          run
          (hostCleanupObservationEvidenceScope scope)
          durable
      )
  let observation = observeDurableReadyToUninstallBinding durable
      operations = readyBindingObservationOperationReferences observation
  if localCompletionPermitIdText (readyBindingObservationPermitId observation)
    == hostTerminalPermitIdText (hostCleanupTerminalPermitId terminal)
    then Right ()
    else Left HostCleanupIntentReadyPermitMismatch
  if cascadeLocalUninstallOperationId operations
    == hostCleanupTerminalOperationId terminal
    then Right ()
    else Left HostCleanupIntentReadyUninstallOperationMismatch
  rebound <-
    either
      (Left . HostCleanupIntentReadyBindingInvalid)
      Right
      (captureDurableReadyToUninstallBinding ready)
  if rebound == durable
    then
      Right
        HostCleanupReadyBinding
          { internalHostReadyDurableBinding = durable
          , internalHostReadyEvidence = ready
          }
    else Left HostCleanupIntentReadyBindingReadBackMismatch

validateHostCleanupReadyBinding
  :: HostCleanupIntent
  -> HostCleanupReadyBinding
  -> Either HostCleanupIntentError HostCleanupReadyBinding
validateHostCleanupReadyBinding intent binding = do
  validated <-
    hostCleanupReadyBindingFromDurable
      (hostCleanupRun intent)
      (hostCleanupScope intent)
      (hostCleanupTerminalIdentity intent)
      (internalHostReadyDurableBinding binding)
  if validated == binding
    then Right validated
    else Left HostCleanupIntentReadyBindingReadBackMismatch

validateHostCleanupIntent
  :: HostCleanupIntent
  -> Either HostCleanupIntentError HostCleanupIntent
validateHostCleanupIntent intent = do
  encodedRun <-
    either
      (Left . HostCleanupIntentCleanupRunInvalid)
      Right
      (encodeCleanupRun maximumCleanupRunBytes (hostCleanupRun intent))
  validatedRun <-
    either
      (Left . HostCleanupIntentCleanupRunInvalid)
      Right
      (decodeCleanupRun maximumCleanupRunBytes encodedRun)
  if validatedRun == hostCleanupRun intent
    then Right ()
    else Left (HostCleanupIntentDecodeInvalid "cleanup run validation changed its value")
  if cleanupRunId validatedRun == hostCleanupRunId intent
    then Right ()
    else Left HostCleanupIntentRunIdMismatch
  if cleanupRunGraphDigest validatedRun == hostCleanupGraphDigest intent
    && cleanupGraphDigest (cleanupRunGraph validatedRun) == hostCleanupGraphDigest intent
    then Right ()
    else Left HostCleanupIntentGraphDigestMismatch
  validatedScope <-
    mkHostCleanupScope
      (hostCleanupRunId intent)
      (hostCleanupObservationEvidenceScope (hostCleanupScope intent))
  if validatedScope == hostCleanupScope intent
    then Right ()
    else Left (HostCleanupIntentDecodeInvalid "cleanup scope validation changed its value")
  case hostCleanupReadyBinding intent of
    Nothing
      | hostCleanupIntentPhase intent >= HostCleanupAuthorityAccepted ->
          Left
            ( HostCleanupIntentReadyBindingRequired
                (hostCleanupIntentPhase intent)
            )
      | otherwise -> Right ()
    Just binding -> do
      _ <- validateHostCleanupReadyBinding intent binding
      Right ()
  validateReceiptForPhase
    (hostCleanupIntentPhase intent)
    (hostCleanupCompletionReceiptDigest intent)
  Right intent

validateReceiptForPhase
  :: HostCleanupIntentPhase
  -> Maybe CleanupDigest
  -> Either HostCleanupIntentError ()
validateReceiptForPhase phase receipt = case (phase, receipt) of
  (HostCleanupComplete, Nothing) -> Left HostCleanupIntentCompletionReceiptRequired
  (HostCleanupComplete, Just _) -> Right ()
  (_, Nothing) -> Right ()
  (_, Just _) -> Left HostCleanupIntentCompletionReceiptUnexpected

advanceHostCleanupIntent
  :: HostCleanupIntentPhase
  -> Maybe CleanupDigest
  -> HostCleanupIntent
  -> Either HostCleanupIntentError HostCleanupIntent
advanceHostCleanupIntent requestedPhase completionReceipt intent
  | requestedPhase == currentPhase = do
      validateReceiptForPhase requestedPhase completionReceipt
      if completionReceipt == hostCleanupCompletionReceiptDigest intent
        then Right intent
        else Left HostCleanupIntentCompletionReceiptMismatch
  | fromEnum requestedPhase == fromEnum currentPhase + 1 =
      validateHostCleanupIntent
        intent
          { internalCleanupIntentPhase = requestedPhase
          , internalCleanupCompletionReceiptDigest = completionReceipt
          }
  | otherwise =
      Left (HostCleanupIntentPhaseConflict currentPhase requestedPhase)
 where
  currentPhase = hostCleanupIntentPhase intent

data HostCleanupIntentEnvelope = HostCleanupIntentEnvelope
  { envelopeVersion :: !Word16
  , envelopeRunId :: !CleanupRunId
  , envelopeGraphDigest :: !CleanupDigest
  , envelopeCleanupRun :: !ByteString
  , envelopeCleanupSurface :: !Word16
  , envelopeRegistryRevision :: !Text
  , envelopeObservationRunScope :: !Text
  , envelopeFoundationId :: !Text
  , envelopeAwsAccountId :: !(Maybe Text)
  , envelopeAwsRegion :: !(Maybe Text)
  , envelopeLifecycleOperation :: !Word16
  , envelopeTerminalOperationId :: !CleanupOperationId
  , envelopeTerminalPermitId :: !Text
  , envelopeReadyBinding :: !(Maybe ByteString)
  , envelopePhase :: !HostCleanupIntentPhase
  , envelopeCompletionReceiptDigest :: !(Maybe CleanupDigest)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

encodeHostCleanupIntent
  :: HostCleanupIntent
  -> Either HostCleanupIntentError ByteString
encodeHostCleanupIntent candidate = do
  intent <- validateHostCleanupIntent candidate
  encodedRun <-
    either
      (Left . HostCleanupIntentCleanupRunInvalid)
      Right
      (encodeCleanupRun maximumCleanupRunBytes (hostCleanupRun intent))
  let scope = hostCleanupScope intent
      terminal = hostCleanupTerminalIdentity intent
      encoded =
        LazyByteString.toStrict . serialise $
          HostCleanupIntentEnvelope
            { envelopeVersion = hostCleanupIntentFormatVersion
            , envelopeRunId = hostCleanupRunId intent
            , envelopeGraphDigest = hostCleanupGraphDigest intent
            , envelopeCleanupRun = encodedRun
            , envelopeCleanupSurface = encodeCleanupSurface (internalCleanupSurface scope)
            , envelopeRegistryRevision = internalRegistryRevision scope
            , envelopeObservationRunScope = internalDurableRunScope scope
            , envelopeFoundationId = internalFoundationId scope
            , envelopeAwsAccountId = internalAwsAccountId scope
            , envelopeAwsRegion = internalAwsRegion scope
            , envelopeLifecycleOperation =
                encodeLifecycleOperation (internalLifecycleOperation scope)
            , envelopeTerminalOperationId = hostCleanupTerminalOperationId terminal
            , envelopeTerminalPermitId =
                hostTerminalPermitIdText (hostCleanupTerminalPermitId terminal)
            , envelopeReadyBinding =
                encodeDurableReadyToUninstallBinding
                  . internalHostReadyDurableBinding
                  <$> hostCleanupReadyBinding intent
            , envelopePhase = hostCleanupIntentPhase intent
            , envelopeCompletionReceiptDigest =
                hostCleanupCompletionReceiptDigest intent
            }
  if ByteString.length encoded > maximumHostCleanupIntentBytes
    then
      Left
        ( HostCleanupIntentEncodedTooLarge
            (ByteString.length encoded)
            maximumHostCleanupIntentBytes
        )
    else Right encoded

decodeHostCleanupIntent
  :: ByteString
  -> Either HostCleanupIntentError HostCleanupIntent
decodeHostCleanupIntent bytes
  | ByteString.length bytes > maximumHostCleanupIntentBytes =
      Left
        ( HostCleanupIntentEncodedTooLarge
            (ByteString.length bytes)
            maximumHostCleanupIntentBytes
        )
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left (HostCleanupIntentDecodeInvalid "invalid cleanup intent envelope")
      Right envelope
        | envelopeVersion envelope /= hostCleanupIntentFormatVersion ->
            Left (HostCleanupIntentUnsupportedVersion (envelopeVersion envelope))
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left HostCleanupIntentNonCanonical
        | otherwise -> decodeEnvelope envelope
 where
  decodeEnvelope envelope = do
    run <-
      either
        (Left . HostCleanupIntentCleanupRunInvalid)
        Right
        (decodeCleanupRun maximumCleanupRunBytes (envelopeCleanupRun envelope))
    surface <- decodeCleanupSurface (envelopeCleanupSurface envelope)
    operation <- decodeLifecycleOperation (envelopeLifecycleOperation envelope)
    awsScope <-
      decodeAwsScope
        (envelopeAwsAccountId envelope)
        (envelopeAwsRegion envelope)
    let evidence =
          mkObservationEvidenceScope
            surface
            (RegistryRevision (envelopeRegistryRevision envelope))
            (DurableObservationRunScope (envelopeObservationRunScope envelope))
            (LinuxRke2FoundationId (envelopeFoundationId envelope))
            awsScope
            operation
    scope <-
      mkHostCleanupScope
        (envelopeRunId envelope)
        evidence
    permit <- mkHostTerminalPermitId (envelopeTerminalPermitId envelope)
    let terminal =
          mkHostCleanupTerminalIdentity
            (envelopeTerminalOperationId envelope)
            permit
    readyBinding <-
      traverse
        (decodeHostCleanupReadyBinding run scope terminal)
        (envelopeReadyBinding envelope)
    validateHostCleanupIntent
      HostCleanupIntent
        { internalCleanupRunId = envelopeRunId envelope
        , internalCleanupGraphDigest = envelopeGraphDigest envelope
        , internalCleanupRun = run
        , internalCleanupScope = scope
        , internalCleanupTerminalIdentity = terminal
        , internalCleanupReadyBinding = readyBinding
        , internalCleanupIntentPhase = envelopePhase envelope
        , internalCleanupCompletionReceiptDigest =
            envelopeCompletionReceiptDigest envelope
        }

decodeHostCleanupReadyBinding
  :: CleanupRun
  -> HostCleanupScope
  -> HostCleanupTerminalIdentity
  -> ByteString
  -> Either HostCleanupIntentError HostCleanupReadyBinding
decodeHostCleanupReadyBinding run scope terminal bytes = do
  durable <-
    either
      (Left . HostCleanupIntentReadyBindingInvalid)
      Right
      (decodeDurableReadyToUninstallBinding bytes)
  hostCleanupReadyBindingFromDurable run scope terminal durable

encodeCleanupSurface :: CleanupSurface -> Word16
encodeCleanupSurface surface = case surface of
  LocalOnly -> 0
  Cascade -> 1
  ExplicitPerRun -> 2
  OperationalTeardown -> 3
  ExplicitLongLived -> 4
  TotalDecommission -> 5

decodeCleanupSurface :: Word16 -> Either HostCleanupIntentError CleanupSurface
decodeCleanupSurface tag = case tag of
  0 -> Right LocalOnly
  1 -> Right Cascade
  2 -> Right ExplicitPerRun
  3 -> Right OperationalTeardown
  4 -> Right ExplicitLongLived
  5 -> Right TotalDecommission
  _ -> Left (HostCleanupIntentDecodeInvalid "unknown cleanup surface tag")

encodeLifecycleOperation :: LifecycleOperation -> Word16
encodeLifecycleOperation operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

decodeLifecycleOperation
  :: Word16
  -> Either HostCleanupIntentError LifecycleOperation
decodeLifecycleOperation tag = case tag of
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  _ -> Left (HostCleanupIntentDecodeInvalid "unknown lifecycle operation tag")

decodeAwsScope
  :: Maybe Text
  -> Maybe Text
  -> Either HostCleanupIntentError (Maybe AwsScope)
decodeAwsScope account region = case (account, region) of
  (Nothing, Nothing) -> Right Nothing
  (Just accountId, Just regionId) ->
    Right (Just (AwsScope (AwsAccountId accountId) (AwsRegion regionId)))
  _ ->
    Left
      ( HostCleanupIntentDecodeInvalid
          "AWS account and region must either both be present or both be absent"
      )

data HostCleanupIntentError
  = HostCleanupIntentStoreInvalid !Text
  | HostCleanupIntentIdentityInvalid !Text
  | HostCleanupIntentRunIdMismatch
  | HostCleanupIntentGraphDigestMismatch
  | HostCleanupIntentScopeRunIdMismatch
  | HostCleanupIntentScopeSurfaceMismatch !CleanupSurface
  | HostCleanupIntentScopeOperationMismatch !LifecycleOperation
  | HostCleanupIntentCleanupRunInvalid !CleanupRunCodecError
  | HostCleanupIntentEncodedTooLarge !Int !Int
  | HostCleanupIntentDecodeInvalid !Text
  | HostCleanupIntentUnsupportedVersion !Word16
  | HostCleanupIntentNonCanonical
  | HostCleanupIntentCompletionReceiptRequired
  | HostCleanupIntentCompletionReceiptUnexpected
  | HostCleanupIntentCompletionReceiptMismatch
  | HostCleanupIntentReadyBindingInvalid !CascadeEvidenceError
  | HostCleanupIntentReadyBindingRequired !HostCleanupIntentPhase
  | HostCleanupIntentReadyBindingRequiresPrepared !HostCleanupIntentPhase
  | HostCleanupIntentReadyBindingConflict
  | HostCleanupIntentReadyPermitMismatch
  | HostCleanupIntentReadyUninstallOperationMismatch
  | HostCleanupIntentReadyBindingReadBackMismatch
  | HostCleanupIntentPhaseConflict !HostCleanupIntentPhase !HostCleanupIntentPhase
  | HostCleanupIntentPreparationRequiresPrepared !HostCleanupIntentPhase
  | HostCleanupIntentPreparationReadyBindingUnexpected
  | HostCleanupIntentExecutionLeaseIntentMismatch
  | HostCleanupIntentExecutionLeaseBindingConflict
  | HostCleanupIntentExecutionLeaseAlreadyHeld
  | HostCleanupIntentExecutionLeaseEncodedTooLarge !Int !Int
  | HostCleanupIntentMissing
  | HostCleanupIntentActiveConflict
  | HostCleanupIntentBindingConflict
  | HostCleanupIntentFileNotRegular
  | HostCleanupIntentFileModeInvalid
  | HostCleanupIntentAlreadyLocked
  | HostCleanupIntentReadBackMismatch
  | HostCleanupIntentRetirementRequiresComplete !HostCleanupIntentPhase
  | HostCleanupIntentRetirementReceiptMismatch
  | HostCleanupIntentRetirementArchiveConflict
  | HostCleanupIntentIoFailure !String
  deriving stock (Eq, Show)

-- | Closed regression result for the opaque Ready-dependent journal paths.
-- The public facade exposes only these booleans; no fixture proof, raw
-- binding bytes, phase capability, or callback can escape this module.
data HostCleanupIntentRegression = HostCleanupIntentRegression
  { hostCleanupIntentRegressionBoundCodec :: !Bool
  , hostCleanupIntentRegressionBoundPreparationRefused :: !Bool
  , hostCleanupIntentRegressionReadyReadBack :: !Bool
  , hostCleanupIntentRegressionPhaseReplay :: !Bool
  , hostCleanupIntentRegressionRetirementReplay :: !Bool
  }

fixedHostCleanupIntentRegression
  :: IO (Either Text HostCleanupIntentRegression)
fixedHostCleanupIntentRegression =
  case withFixedCascadeEvidenceFixtureInternal
    (\_ run ready _ _ -> fixedHostCleanupIntentRegressionFor run ready) of
    Left detail -> pure (Left detail)
    Right regression -> regression

fixedHostCleanupIntentRegressionFor
  :: CleanupRun
  -> ReadyToUninstallEvidence
  -> IO (Either Text HostCleanupIntentRegression)
fixedHostCleanupIntentRegressionFor run ready =
  withSystemTempDirectory "prodbox-host-cleanup-fixed-regression" $ \retainedRoot ->
    runExceptT $ do
      scope <-
        fromEitherText
          (mkHostCleanupScope (cleanupRunId run) (readyToUninstallScope ready))
      hostPermit <-
        fromEitherText
          ( mkHostTerminalPermitId
              (localCompletionPermitIdText (readyToUninstallPermitId ready))
          )
      let operations = readyToUninstallOperationReferences ready
          terminal =
            mkHostCleanupTerminalIdentity
              (cascadeLocalUninstallOperationId operations)
              hostPermit
      intent <-
        fromEitherText
          ( mkHostCleanupIntent
              (cleanupRunId run)
              (cleanupRunGraphDigest run)
              run
              scope
              terminal
          )
      receipt <-
        fromEitherText
          (mkCleanupDigest "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
      store <- fromEitherText (mkHostCleanupIntentStore retainedRoot)
      prepared <- ioEitherText (prepareHostCleanupIntent store intent)
      bound <- ioEitherText (persistHostCleanupReady store prepared ready)
      replayedBound <- ioEitherText (persistHostCleanupReady store prepared ready)
      observed <- ioEitherText (observeHostCleanupIntentForResume store)
      observedReady <- case observed of
        Nothing -> ExceptT (pure (Left "fixed Ready read-back disappeared"))
        Just exact -> fromEitherText (restoreObservedHostCleanupReady exact)
      completed <-
        advanceFixedHostCleanupPhases
          store
          bound
          receipt
          [ HostCleanupAuthorityAccepted
          , HostCleanupTerminalArmed
          , HostCleanupLocalAbsenceRecorded
          , HostCleanupAuthorityReconciled
          , HostCleanupComplete
          ]
      reopened <- ioEitherText (observeHostCleanupIntent store)
      boundPreparationRefused <-
        liftIO
          ( withSystemTempDirectory
              "prodbox-host-cleanup-bound-preparation-regression"
              ( \otherRoot -> do
                  let decodedBound = do
                        encoded <- encodeHostCleanupIntent bound
                        decodeHostCleanupIntent encoded
                  case (mkHostCleanupIntentStore otherRoot, decodedBound) of
                    (Right otherStore, Right callerDecoded) -> do
                      refused <- prepareHostCleanupIntent otherStore callerDecoded
                      missing <- observeHostCleanupIntent otherStore
                      pure
                        ( refused
                            == Left HostCleanupIntentPreparationReadyBindingUnexpected
                            && missing == Right Nothing
                        )
                    _ -> pure False
              )
          )
      retirement <- ioEitherText (retireHostCleanupIntent store completed receipt)
      replayedRetirement <- ioEitherText (retireHostCleanupIntent store completed receipt)
      afterRetirement <- ioEitherText (observeHostCleanupIntent store)
      let boundCodec = do
            encoded <- encodeHostCleanupIntent bound
            decodeHostCleanupIntent encoded
      pure
        HostCleanupIntentRegression
          { hostCleanupIntentRegressionBoundCodec = boundCodec == Right bound
          , hostCleanupIntentRegressionBoundPreparationRefused =
              boundPreparationRefused
          , hostCleanupIntentRegressionReadyReadBack =
              replayedBound == bound && observedReady == ready
          , hostCleanupIntentRegressionPhaseReplay =
              hostCleanupIntentPhase completed == HostCleanupComplete
                && reopened == Just completed
          , hostCleanupIntentRegressionRetirementReplay =
              replayedRetirement == retirement && afterRetirement == Nothing
          }

advanceFixedHostCleanupPhases
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> CleanupDigest
  -> [HostCleanupIntentPhase]
  -> ExceptT Text IO HostCleanupIntent
advanceFixedHostCleanupPhases _ current _ [] = pure current
advanceFixedHostCleanupPhases store current receipt (phase : remaining) = do
  advanced <-
    ioEitherText
      ( transitionHostCleanupIntent
          store
          current
          phase
          (if phase == HostCleanupComplete then Just receipt else Nothing)
      )
  advanceFixedHostCleanupPhases store advanced receipt remaining

fromEitherText :: (Show err) => Either err value -> ExceptT Text IO value
fromEitherText = ExceptT . pure . either (Left . Text.pack . show) Right

ioEitherText
  :: (Show err) => IO (Either err value) -> ExceptT Text IO value
ioEitherText action = ExceptT (either (Left . Text.pack . show) Right <$> action)

validateIdentity :: Text -> Text -> Either HostCleanupIntentError Text
validateIdentity label raw
  | Text.null raw = invalid "must not be empty"
  | Text.length raw > 160 = invalid "exceeds 160 characters"
  | Text.any (not . validCharacter) raw = invalid "contains an invalid character"
  | otherwise = Right raw
 where
  invalid detail =
    Left (HostCleanupIntentIdentityInvalid (label <> " " <> detail))
  validCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || (isAscii character && isDigit character)
      || character `elem` ("-._:/" :: String)

data StoredIntent
  = StoredIntentMissing
  | StoredIntentPresent !ByteString !HostCleanupIntent

-- | One canonical intent obtained through the locked, nofollow host-store
-- observer.  Its constructor is private so raw decoder output cannot enter
-- the terminal resume path.
newtype ObservedHostCleanupIntent = ObservedHostCleanupIntent HostCleanupIntent
  deriving stock (Eq, Show)

observedHostCleanupIntent :: ObservedHostCleanupIntent -> HostCleanupIntent
observedHostCleanupIntent (ObservedHostCleanupIntent intent) = intent

data HostCleanupExecutionLeaseEnvelope = HostCleanupExecutionLeaseEnvelope
  { executionLeaseVersion :: !Word16
  , executionLeaseRunId :: !CleanupRunId
  , executionLeaseGraphDigest :: !CleanupDigest
  , executionLeaseSurface :: !Word16
  , executionLeaseRegistryRevision :: !Text
  , executionLeaseRunScope :: !Text
  , executionLeaseFoundation :: !Text
  , executionLeaseAwsAccount :: !(Maybe Text)
  , executionLeaseAwsRegion :: !(Maybe Text)
  , executionLeaseLifecycleOperation :: !Word16
  , executionLeaseTerminalOperation :: !CleanupOperationId
  , executionLeaseTerminalPermit :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

hostCleanupExecutionLeaseVersion :: Word16
hostCleanupExecutionLeaseVersion = 1

maximumHostCleanupExecutionLeaseBytes :: Int
maximumHostCleanupExecutionLeaseBytes = 16 * 1024

hostCleanupExecutionLeaseBytes :: HostCleanupIntent -> ByteString
hostCleanupExecutionLeaseBytes intent =
  LazyByteString.toStrict . serialise $
    HostCleanupExecutionLeaseEnvelope
      { executionLeaseVersion = hostCleanupExecutionLeaseVersion
      , executionLeaseRunId = hostCleanupRunId intent
      , executionLeaseGraphDigest = hostCleanupGraphDigest intent
      , executionLeaseSurface = encodeCleanupSurface (internalCleanupSurface scope)
      , executionLeaseRegistryRevision = internalRegistryRevision scope
      , executionLeaseRunScope = internalDurableRunScope scope
      , executionLeaseFoundation = internalFoundationId scope
      , executionLeaseAwsAccount = internalAwsAccountId scope
      , executionLeaseAwsRegion = internalAwsRegion scope
      , executionLeaseLifecycleOperation =
          encodeLifecycleOperation (internalLifecycleOperation scope)
      , executionLeaseTerminalOperation =
          hostCleanupTerminalOperationId terminal
      , executionLeaseTerminalPermit =
          hostTerminalPermitIdText (hostCleanupTerminalPermitId terminal)
      }
 where
  scope = hostCleanupScope intent
  terminal = hostCleanupTerminalIdentity intent

hostCleanupExecutionLeasePath
  :: HostCleanupIntentStore -> HostCleanupIntent -> FilePath
hostCleanupExecutionLeasePath store intent =
  hostCleanupIntentDirectory store
    </> ( ".host-cleanup-execution-"
            ++ Text.unpack
              (TextEncoding.decodeUtf8 (hexSha256 (hostCleanupExecutionLeaseBytes intent)))
            ++ ".lease"
        )

hostCleanupExecutionLeaseTemporaryPath
  :: HostCleanupIntentStore -> HostCleanupIntent -> FilePath
hostCleanupExecutionLeaseTemporaryPath store intent =
  hostCleanupExecutionLeasePath store intent ++ ".tmp"

hostCleanupExecutionLockPath
  :: HostCleanupIntentStore -> HostCleanupIntent -> FilePath
hostCleanupExecutionLockPath store intent =
  hostCleanupExecutionLeasePath store intent ++ ".lock"

restoreObservedHostCleanupReady
  :: ObservedHostCleanupIntent
  -> Either HostCleanupIntentError ReadyToUninstallEvidence
restoreObservedHostCleanupReady =
  restoreHostCleanupReadyUnchecked . observedHostCleanupIntent

observeHostCleanupIntentForResume
  :: HostCleanupIntentStore
  -> IO (Either HostCleanupIntentError (Maybe ObservedHostCleanupIntent))
observeHostCleanupIntentForResume store =
  withHostCleanupIntentLock store $ \preparedStore -> do
    observed <- readStoredIntent (hostCleanupIntentPath preparedStore)
    case observed of
      Left err -> pure (Left err)
      Right StoredIntentMissing -> pure (Right Nothing)
      Right (StoredIntentPresent _ intent) -> do
        -- The file contents were fsynced before their atomic rename.  Repeat
        -- the parent fsync at every positive resume observation so a rename
        -- whose original fsync response was lost cannot authorize teardown
        -- until its directory entry is durably established.
        synced <- try (syncIntentDirectory preparedStore)
        pure $ case synced of
          Left (err :: IOException) ->
            Left (HostCleanupIntentIoFailure (show err))
          Right () -> Right (Just (ObservedHostCleanupIntent intent))

-- | Hold one run-bound host execution lease across the complete terminal
-- effect interval.  The durable lease file binds the exact run, graph, scope,
-- and terminal identity; its advisory lock is distinct from the short-lived
-- journal lock used by individual reads and writes.
withHostCleanupExecutionLease
  :: HostCleanupIntentStore
  -> ObservedHostCleanupIntent
  -> IO result
  -> IO (Either HostCleanupIntentError result)
withHostCleanupExecutionLease store observed action = do
  preparedRoot <- prepareStoreRoot store
  case preparedRoot of
    Left err -> pure (Left err)
    Right preparedStore -> do
      let intent = observedHostCleanupIntent observed
          leasePath = hostCleanupExecutionLeasePath preparedStore intent
          lockPath = hostCleanupExecutionLockPath preparedStore intent
          expectedBytes = hostCleanupExecutionLeaseBytes intent
      mask $ \restore -> do
        -- Reserve the canonical lock pathname before any cooperating code can
        -- open the durable lease file. POSIX record locks are process-scoped:
        -- closing another descriptor for the locked inode can otherwise drop
        -- the active lock. The lock therefore has its own inode, and aliases
        -- share this one process-local reservation key.
        reserved <- reserveProcessIntentLock lockPath
        if not reserved
          then pure (Left HostCleanupIntentExecutionLeaseAlreadyHeld)
          else do
            prepared <-
              restore (prepareHostCleanupExecutionLease preparedStore observed)
                `onException` releaseProcessIntentLock lockPath
            case prepared of
              Left err -> do
                releaseProcessIntentLock lockPath
                pure (Left err)
              Right _ -> do
                acquired <- acquireIntentLockAtReserved lockPath
                case acquired of
                  Left HostCleanupIntentAlreadyLocked ->
                    pure (Left HostCleanupIntentExecutionLeaseAlreadyHeld)
                  Left err -> pure (Left err)
                  Right held -> do
                    validation <-
                      try
                        (validateHeldExecutionLease held leasePath expectedBytes)
                    case validation of
                      Left (err :: IOException) -> do
                        releaseIntentLock held
                        pure (Left (HostCleanupIntentIoFailure (show err)))
                      Right validated -> case validated of
                        Left err -> do
                          releaseIntentLock held
                          pure (Left err)
                        Right () -> do
                          result <- restore action `finally` releaseIntentLock held
                          pure (Right result)

observeHostCleanupIntent
  :: HostCleanupIntentStore
  -> IO (Either HostCleanupIntentError (Maybe HostCleanupIntent))
observeHostCleanupIntent store = do
  observed <- observeHostCleanupIntentForResume store
  pure (fmap (fmap observedHostCleanupIntent) observed)

prepareHostCleanupIntent
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
prepareHostCleanupIntent store candidate
  | hostCleanupIntentPhase candidate /= HostCleanupPrepared =
      pure
        ( Left
            ( HostCleanupIntentPreparationRequiresPrepared
                (hostCleanupIntentPhase candidate)
            )
        )
  | hostCleanupReadyBinding candidate /= Nothing =
      pure (Left HostCleanupIntentPreparationReadyBindingUnexpected)
  | otherwise = case encodeHostCleanupIntent candidate of
      Left err -> pure (Left err)
      Right expectedBytes ->
        withHostCleanupIntentLock store $ \preparedStore -> do
          observed <- readStoredIntent (hostCleanupIntentPath preparedStore)
          case observed of
            Left err -> pure (Left err)
            Right StoredIntentMissing ->
              atomicPersistAndReadBack preparedStore expectedBytes candidate
            Right (StoredIntentPresent actualBytes actual)
              | actualBytes == expectedBytes && actual == candidate ->
                  -- An earlier rename may have applied while its parent fsync
                  -- response was lost.  Rewrite only the already-proven exact
                  -- bytes so replay closes that durability uncertainty.
                  atomicPersistAndReadBack preparedStore expectedBytes actual
              | otherwise -> pure (Left HostCleanupIntentActiveConflict)

-- | Capture one already-opaque Ready proof, durably publish its canonical
-- binding while the intent remains Prepared, and positively read the exact
-- bytes back.  Exact replay closes a lost persistence response; a different
-- proof can never replace the first durable binding.
persistHostCleanupReady
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> ReadyToUninstallEvidence
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
persistHostCleanupReady store expected ready =
  case bindHostCleanupReady expected ready of
    Left err -> pure (Left err)
    Right candidate ->
      case (encodeHostCleanupIntent expected, encodeHostCleanupIntent candidate) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right expectedBytes, Right candidateBytes) ->
          withHostCleanupIntentLock store $ \preparedStore -> do
            observed <- readStoredIntent (hostCleanupIntentPath preparedStore)
            case observed of
              Left err -> pure (Left err)
              Right StoredIntentMissing -> pure (Left HostCleanupIntentMissing)
              Right (StoredIntentPresent actualBytes actual)
                | actualBytes == candidateBytes && actual == candidate ->
                    atomicPersistAndReadBack
                      preparedStore
                      candidateBytes
                      candidate
                | actualBytes == expectedBytes && actual == expected ->
                    atomicPersistAndReadBack
                      preparedStore
                      candidateBytes
                      candidate
                | not (sameIntentBaseBinding expected actual) ->
                    pure (Left HostCleanupIntentBindingConflict)
                | otherwise ->
                    pure (Left HostCleanupIntentReadyBindingConflict)

transitionHostCleanupIntent
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> HostCleanupIntentPhase
  -> Maybe CleanupDigest
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
transitionHostCleanupIntent store expected requestedPhase completionReceipt =
  case advanceHostCleanupIntent requestedPhase completionReceipt expected of
    Left err -> pure (Left err)
    Right candidate -> case (encodeHostCleanupIntent expected, encodeHostCleanupIntent candidate) of
      (Left err, _) -> pure (Left err)
      (_, Left err) -> pure (Left err)
      (Right expectedBytes, Right candidateBytes) ->
        withHostCleanupIntentLock store $ \preparedStore -> do
          observed <- readStoredIntent (hostCleanupIntentPath preparedStore)
          case observed of
            Left err -> pure (Left err)
            Right StoredIntentMissing -> pure (Left HostCleanupIntentMissing)
            Right (StoredIntentPresent actualBytes actual)
              | actualBytes == candidateBytes && actual == candidate ->
                  atomicPersistAndReadBack preparedStore candidateBytes actual
              | actualBytes == expectedBytes && actual == expected ->
                  if candidate == expected
                    then pure (Right actual)
                    else atomicPersistAndReadBack preparedStore candidateBytes candidate
              | not (sameIntentBinding expected actual) ->
                  pure (Left HostCleanupIntentBindingConflict)
              | otherwise ->
                  pure
                    ( Left
                        ( HostCleanupIntentPhaseConflict
                            (hostCleanupIntentPhase actual)
                            requestedPhase
                        )
                    )

markHostCleanupAuthorityAccepted
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
markHostCleanupAuthorityAccepted store expected =
  transitionHostCleanupIntent
    store
    expected
    HostCleanupAuthorityAccepted
    Nothing

markHostCleanupTerminalArmed
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
markHostCleanupTerminalArmed store expected =
  transitionHostCleanupIntent store expected HostCleanupTerminalArmed Nothing

markHostLocalAbsenceRecorded
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
markHostLocalAbsenceRecorded store expected =
  transitionHostCleanupIntent
    store
    expected
    HostCleanupLocalAbsenceRecorded
    Nothing

markHostCleanupAuthorityReconciled
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
markHostCleanupAuthorityReconciled store expected =
  transitionHostCleanupIntent
    store
    expected
    HostCleanupAuthorityReconciled
    Nothing

markHostCleanupComplete
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> CleanupDigest
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
markHostCleanupComplete store expected completionReceipt =
  transitionHostCleanupIntent
    store
    expected
    HostCleanupComplete
    (Just completionReceipt)

sameIntentBinding :: HostCleanupIntent -> HostCleanupIntent -> Bool
sameIntentBinding left right =
  sameIntentBaseBinding left right
    && hostCleanupReadyBinding left == hostCleanupReadyBinding right

sameIntentBaseBinding :: HostCleanupIntent -> HostCleanupIntent -> Bool
sameIntentBaseBinding left right =
  hostCleanupRunId left == hostCleanupRunId right
    && hostCleanupGraphDigest left == hostCleanupGraphDigest right
    && hostCleanupRun left == hostCleanupRun right
    && hostCleanupScope left == hostCleanupScope right
    && hostCleanupTerminalIdentity left == hostCleanupTerminalIdentity right

newtype HostCleanupIntentRetirementDigest = HostCleanupIntentRetirementDigest
  { hostCleanupIntentRetirementDigestText :: Text
  }
  deriving stock (Eq, Ord, Show)

data HostCleanupIntentRetirement = HostCleanupIntentRetirement
  { retiredHostCleanupIntentDigest :: !HostCleanupIntentRetirementDigest
  , retiredHostCleanupCompletionReceiptDigest :: !CleanupDigest
  }
  deriving stock (Eq, Show)

intentRetirementDigest :: ByteString -> HostCleanupIntentRetirementDigest
intentRetirementDigest =
  HostCleanupIntentRetirementDigest . TextEncoding.decodeUtf8 . hexSha256

hostCleanupIntentRetiredPath
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> Either HostCleanupIntentError FilePath
hostCleanupIntentRetiredPath store intent = do
  encoded <- encodeHostCleanupIntent intent
  let digest = intentRetirementDigest encoded
  Right
    ( hostCleanupIntentDirectory store
        </> ( "retired-"
                ++ Text.unpack (hostCleanupIntentRetirementDigestText digest)
                ++ ".cbor"
            )
    )

retireHostCleanupIntent
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> CleanupDigest
  -> IO (Either HostCleanupIntentError HostCleanupIntentRetirement)
retireHostCleanupIntent store expected suppliedReceipt
  | hostCleanupIntentPhase expected /= HostCleanupComplete =
      pure
        ( Left
            ( HostCleanupIntentRetirementRequiresComplete
                (hostCleanupIntentPhase expected)
            )
        )
  | hostCleanupCompletionReceiptDigest expected /= Just suppliedReceipt =
      pure (Left HostCleanupIntentRetirementReceiptMismatch)
  | otherwise = case encodeHostCleanupIntent expected of
      Left err -> pure (Left err)
      Right expectedBytes ->
        withHostCleanupIntentLock store (retirePreparedStore expectedBytes)
 where
  retirePreparedStore expectedBytes preparedStore =
    case hostCleanupIntentRetiredPath preparedStore expected of
      Left err -> pure (Left err)
      Right archivePath -> do
        active <- readStoredIntent (hostCleanupIntentPath preparedStore)
        archived <- readStoredIntent archivePath
        case (active, archived) of
          (Left err, _) -> pure (Left err)
          (_, Left err) -> pure (Left err)
          (Right StoredIntentMissing, Right StoredIntentMissing) ->
            pure (Left HostCleanupIntentMissing)
          (Right StoredIntentMissing, Right archive) ->
            case exactStoredIntent expectedBytes expected archive of
              False -> pure (Left HostCleanupIntentRetirementArchiveConflict)
              True ->
                finishRetirementReadBack
                  preparedStore
                  archivePath
                  expectedBytes
                  expected
                  suppliedReceipt
          (Right activeIntent, Right archive) ->
            case exactStoredIntent expectedBytes expected activeIntent of
              False -> pure (Left HostCleanupIntentActiveConflict)
              True -> case archive of
                StoredIntentPresent archiveBytes archiveIntent
                  | archiveBytes /= expectedBytes || archiveIntent /= expected ->
                      pure (Left HostCleanupIntentRetirementArchiveConflict)
                _ -> do
                  moved <-
                    durableRetire
                      preparedStore
                      archivePath
                      (archive == StoredIntentMissing)
                  case moved of
                    Left err -> pure (Left err)
                    Right () -> do
                      finalArchive <- readStoredIntent archivePath
                      case finalArchive of
                        Left err -> pure (Left err)
                        Right archiveIntent ->
                          case exactStoredIntent expectedBytes expected archiveIntent of
                            False ->
                              pure (Left HostCleanupIntentRetirementArchiveConflict)
                            True ->
                              finishRetirementReadBack
                                preparedStore
                                archivePath
                                expectedBytes
                                expected
                                suppliedReceipt

exactStoredIntent :: ByteString -> HostCleanupIntent -> StoredIntent -> Bool
exactStoredIntent expectedBytes expected stored = case stored of
  StoredIntentMissing -> False
  StoredIntentPresent actualBytes actual ->
    actualBytes == expectedBytes && actual == expected

finishRetirementReadBack
  :: HostCleanupIntentStore
  -> FilePath
  -> ByteString
  -> HostCleanupIntent
  -> CleanupDigest
  -> IO (Either HostCleanupIntentError HostCleanupIntentRetirement)
finishRetirementReadBack store archivePath expectedBytes expected suppliedReceipt = do
  -- Repeat the parent fsync even on the response-loss replay arm.  If a prior
  -- unlink applied but its fsync reported failure, absence plus an archive is
  -- not yet enough to claim durable retirement.
  synced <- try (syncIntentDirectory store)
  case synced of
    Left (err :: IOException) ->
      pure (Left (HostCleanupIntentIoFailure (show err)))
    Right () -> do
      active <- readStoredIntent (hostCleanupIntentPath store)
      archive <- readStoredIntent archivePath
      pure $ case (active, archive) of
        (Right StoredIntentMissing, Right storedArchive)
          | exactStoredIntent expectedBytes expected storedArchive ->
              Right
                HostCleanupIntentRetirement
                  { retiredHostCleanupIntentDigest = intentRetirementDigest expectedBytes
                  , retiredHostCleanupCompletionReceiptDigest = suppliedReceipt
                  }
        (Left err, _) -> Left err
        (_, Left err) -> Left err
        (_, Right (StoredIntentPresent _ _)) ->
          Left HostCleanupIntentRetirementArchiveConflict
        (_, Right StoredIntentMissing) ->
          Left
            ( HostCleanupIntentIoFailure
                ("retirement archive missing after durable move: " ++ archivePath)
            )

durableRetire
  :: HostCleanupIntentStore
  -> FilePath
  -> Bool
  -> IO (Either HostCleanupIntentError ())
durableRetire store archivePath archiveMissing = do
  result <- try . mask_ $ do
    if archiveMissing
      then do
        -- Publish without replacement.  A crash after this directory fsync
        -- leaves both exact names; the retry arm below removes only the exact
        -- active name.
        createLink (hostCleanupIntentPath store) archivePath
        syncIntentDirectory store
      else pure ()
    removeLink (hostCleanupIntentPath store)
    syncIntentDirectory store
  pure $ case result :: Either IOException () of
    Left err -> Left (HostCleanupIntentIoFailure (show err))
    Right () -> Right ()

instance Eq StoredIntent where
  StoredIntentMissing == StoredIntentMissing = True
  StoredIntentPresent leftBytes leftIntent == StoredIntentPresent rightBytes rightIntent =
    leftBytes == rightBytes && leftIntent == rightIntent
  _ == _ = False

prepareStoreRoot
  :: HostCleanupIntentStore
  -> IO (Either HostCleanupIntentError HostCleanupIntentStore)
prepareStoreRoot store = do
  canonicalResult <- try (canonicalizePath (hostCleanupIntentRetainedRoot store))
  case canonicalResult of
    Left (err :: IOException) -> pure (Left (HostCleanupIntentIoFailure (show err)))
    Right canonicalRoot
      | normalise canonicalRoot == "/" ->
          pure
            ( Left
                ( HostCleanupIntentStoreInvalid
                    "retained root resolves to the filesystem root"
                )
            )
      | otherwise -> do
          let preparedStore = HostCleanupIntentStore (normalise canonicalRoot)
              intentDirectory = hostCleanupIntentDirectory preparedStore
          created <- try (createDirectoryIfMissing False intentDirectory)
          case created of
            Left (err :: IOException) ->
              pure (Left (HostCleanupIntentIoFailure (show err)))
            Right () -> secureIntentDirectory preparedStore

secureIntentDirectory
  :: HostCleanupIntentStore
  -> IO (Either HostCleanupIntentError HostCleanupIntentStore)
secureIntentDirectory store = do
  let path = hostCleanupIntentDirectory store
  statusResult <- try (getSymbolicLinkStatus path)
  case statusResult of
    Left (err :: IOException) -> pure (Left (HostCleanupIntentIoFailure (show err)))
    Right status
      | isSymbolicLink status || not (isDirectory status) ->
          pure
            ( Left
                ( HostCleanupIntentStoreInvalid
                    "host cleanup intent directory must be a real directory"
                )
            )
      | otherwise -> do
          canonicalResult <- try (canonicalizePath path)
          case canonicalResult of
            Left (err :: IOException) ->
              pure (Left (HostCleanupIntentIoFailure (show err)))
            Right canonicalDirectory
              | normalise canonicalDirectory /= normalise path ->
                  pure
                    ( Left
                        ( HostCleanupIntentStoreInvalid
                            "host cleanup intent directory escapes the retained root"
                        )
                    )
              | otherwise -> do
                  secured <- try (setFileMode canonicalDirectory ownerModes)
                  pure $ case secured of
                    Left (err :: IOException) ->
                      Left (HostCleanupIntentIoFailure (show err))
                    Right () -> Right store

data StoredExecutionLease
  = StoredExecutionLeaseMissing
  | StoredExecutionLeasePresent !ByteString

prepareHostCleanupExecutionLease
  :: HostCleanupIntentStore
  -> ObservedHostCleanupIntent
  -> IO (Either HostCleanupIntentError (FilePath, ByteString))
prepareHostCleanupExecutionLease store observed =
  withHostCleanupIntentLock store $ \preparedStore -> do
    active <- readStoredIntent (hostCleanupIntentPath preparedStore)
    case active of
      Left err -> pure (Left err)
      Right StoredIntentMissing ->
        pure (Left HostCleanupIntentExecutionLeaseIntentMismatch)
      Right (StoredIntentPresent _ current)
        | not (sameExecutionLeaseBinding expected current) ->
            pure (Left HostCleanupIntentExecutionLeaseIntentMismatch)
        | otherwise -> do
            let leasePath = hostCleanupExecutionLeasePath preparedStore expected
                expectedBytes = hostCleanupExecutionLeaseBytes expected
            stored <- readStoredExecutionLease leasePath
            case stored of
              Left err -> pure (Left err)
              Right StoredExecutionLeaseMissing -> do
                persisted <-
                  atomicPersistExecutionLease
                    preparedStore
                    expected
                    expectedBytes
                pure ((leasePath, expectedBytes) <$ persisted)
              Right (StoredExecutionLeasePresent actualBytes)
                | actualBytes == expectedBytes -> do
                    synced <- try (syncIntentDirectory preparedStore)
                    pure $ case synced of
                      Left (err :: IOException) ->
                        Left (HostCleanupIntentIoFailure (show err))
                      Right () -> Right (leasePath, expectedBytes)
                | otherwise ->
                    pure (Left HostCleanupIntentExecutionLeaseBindingConflict)
 where
  expected = observedHostCleanupIntent observed

sameExecutionLeaseBinding :: HostCleanupIntent -> HostCleanupIntent -> Bool
sameExecutionLeaseBinding left right =
  hostCleanupRunId left == hostCleanupRunId right
    && hostCleanupGraphDigest left == hostCleanupGraphDigest right
    && hostCleanupScope left == hostCleanupScope right
    && hostCleanupTerminalIdentity left == hostCleanupTerminalIdentity right

readStoredExecutionLease
  :: FilePath
  -> IO (Either HostCleanupIntentError StoredExecutionLease)
readStoredExecutionLease path = do
  result <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          safeCloseFd
          readOpenExecutionLease
      )
  pure $ case result of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right StoredExecutionLeaseMissing
      | otherwise -> Left (HostCleanupIntentIoFailure (show err))
    Right value -> value

readOpenExecutionLease
  :: Fd -> IO (Either HostCleanupIntentError StoredExecutionLease)
readOpenExecutionLease fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then pure (Left HostCleanupIntentFileNotRegular)
    else
      if fileMode status `intersectFileModes` accessModes /= ownerFileMode
        then pure (Left HostCleanupIntentFileModeInvalid)
        else do
          bytes <-
            readFdBounded fd (maximumHostCleanupExecutionLeaseBytes + 1)
          pure $ do
            if ByteString.length bytes > maximumHostCleanupExecutionLeaseBytes
              then
                Left
                  ( HostCleanupIntentExecutionLeaseEncodedTooLarge
                      (ByteString.length bytes)
                      maximumHostCleanupExecutionLeaseBytes
                  )
              else Right (StoredExecutionLeasePresent bytes)

atomicPersistExecutionLease
  :: HostCleanupIntentStore
  -> HostCleanupIntent
  -> ByteString
  -> IO (Either HostCleanupIntentError ())
atomicPersistExecutionLease store intent bytes = do
  result <- try . mask_ $ do
    bracket
      ( openFd
          (hostCleanupExecutionLeaseTemporaryPath store intent)
          WriteOnly
          defaultFileFlags
            { trunc = True
            , creat = Just ownerFileMode
            , nofollow = True
            , cloexec = True
            }
      )
      safeCloseFd
      ( \fd -> do
          setFdMode fd ownerFileMode
          status <- getFdStatus fd
          if not (isRegularFile status)
            then ioError (userError "cleanup execution lease temporary path is not regular")
            else do
              writeAll fd bytes
              fileSynchronise fd
      )
    renameFile
      (hostCleanupExecutionLeaseTemporaryPath store intent)
      (hostCleanupExecutionLeasePath store intent)
    syncIntentDirectory store
  case result of
    Left (err :: IOException) ->
      pure (Left (HostCleanupIntentIoFailure (show err)))
    Right () -> do
      readBack <- readStoredExecutionLease (hostCleanupExecutionLeasePath store intent)
      pure $ case readBack of
        Right (StoredExecutionLeasePresent actualBytes)
          | actualBytes == bytes -> Right ()
        Left err -> Left err
        _ -> Left HostCleanupIntentExecutionLeaseBindingConflict

validateHeldExecutionLease
  :: HeldIntentLock
  -> FilePath
  -> ByteString
  -> IO (Either HostCleanupIntentError ())
validateHeldExecutionLease held leasePath expectedBytes = do
  status <- getFdStatus (heldIntentLockFd held)
  if not (isRegularFile status)
    then pure (Left HostCleanupIntentFileNotRegular)
    else
      if fileMode status `intersectFileModes` accessModes /= ownerFileMode
        then pure (Left HostCleanupIntentFileModeInvalid)
        else do
          stored <- readStoredExecutionLease leasePath
          pure $ case stored of
            Right (StoredExecutionLeasePresent actualBytes)
              | actualBytes == expectedBytes -> Right ()
            Left err -> Left err
            _ -> Left HostCleanupIntentExecutionLeaseBindingConflict

data HeldIntentLock = HeldIntentLock
  { heldIntentLockPath :: !FilePath
  , heldIntentLockFd :: !Fd
  }

{-# NOINLINE processIntentLocks #-}
processIntentLocks :: MVar (Set FilePath)
processIntentLocks = unsafePerformIO (newMVar Set.empty)

ownerFileMode :: FileMode
ownerFileMode = ownerReadMode `unionFileModes` ownerWriteMode

withHostCleanupIntentLock
  :: HostCleanupIntentStore
  -> (HostCleanupIntentStore -> IO (Either HostCleanupIntentError result))
  -> IO (Either HostCleanupIntentError result)
withHostCleanupIntentLock store action = do
  prepared <- prepareStoreRoot store
  case prepared of
    Left err -> pure (Left err)
    Right preparedStore ->
      mask $ \restore -> do
        lockResult <- acquireIntentLock preparedStore
        case lockResult of
          Left err -> pure (Left err)
          Right held ->
            restore (action preparedStore)
              `finally` releaseIntentLock held

acquireIntentLock
  :: HostCleanupIntentStore
  -> IO (Either HostCleanupIntentError HeldIntentLock)
acquireIntentLock store =
  acquireIntentLockAt (hostCleanupIntentLockPath store)

acquireIntentLockAt
  :: FilePath
  -> IO (Either HostCleanupIntentError HeldIntentLock)
acquireIntentLockAt path = do
  locallyAcquired <- reserveProcessIntentLock path
  if not locallyAcquired
    then pure (Left HostCleanupIntentAlreadyLocked)
    else acquireIntentLockAtReserved path

reserveProcessIntentLock :: FilePath -> IO Bool
reserveProcessIntentLock path =
  modifyMVar processIntentLocks $ \held ->
    if Set.member path held
      then pure (held, False)
      else pure (Set.insert path held, True)

acquireIntentLockAtReserved
  :: FilePath
  -> IO (Either HostCleanupIntentError HeldIntentLock)
acquireIntentLockAtReserved path = do
  opened <-
    try
      ( ( openFd
            path
            ReadWrite
            defaultFileFlags
              { creat = Just ownerFileMode
              , nofollow = True
              , cloexec = True
              }
        )
          `onException` releaseProcessIntentLock path
      )
  case opened of
    Left (err :: IOException) ->
      pure (Left (HostCleanupIntentIoFailure (show err)))
    Right fd -> do
      secured <-
        try
          ( setFdMode fd ownerFileMode
              `onException` cleanupIntentLockAcquisition path fd
          )
      case secured of
        Left (err :: IOException) ->
          pure (Left (HostCleanupIntentIoFailure (show err)))
        Right () -> do
          locked <-
            try
              ( setLock fd (WriteLock, AbsoluteSeek, 0, 0)
                  `onException` cleanupIntentLockAcquisition path fd
              )
          case locked of
            Left (_ :: IOException) -> pure (Left HostCleanupIntentAlreadyLocked)
            Right () -> pure (Right (HeldIntentLock path fd))

releaseIntentLock :: HeldIntentLock -> IO ()
releaseIntentLock held =
  ( do
      _ <-
        try (setLock (heldIntentLockFd held) (Unlock, AbsoluteSeek, 0, 0))
          :: IO (Either IOException ())
      pure ()
  )
    `finally` ( safeCloseFd (heldIntentLockFd held)
                  `finally` releaseProcessIntentLock (heldIntentLockPath held)
              )

cleanupIntentLockAcquisition :: FilePath -> Fd -> IO ()
cleanupIntentLockAcquisition path fd =
  safeCloseFd fd `finally` releaseProcessIntentLock path

releaseProcessIntentLock :: FilePath -> IO ()
releaseProcessIntentLock path =
  modifyMVar_ processIntentLocks (pure . Set.delete path)

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = do
  _ <- try (closeFd fd) :: IO (Either IOException ())
  pure ()

readStoredIntent
  :: FilePath
  -> IO (Either HostCleanupIntentError StoredIntent)
readStoredIntent path = do
  result <-
    try
      ( bracket
          (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True})
          safeCloseFd
          readOpenIntent
      )
  pure $ case result :: Either IOException (Either HostCleanupIntentError StoredIntent) of
    Left err
      | isDoesNotExistError err -> Right StoredIntentMissing
      | otherwise -> Left (HostCleanupIntentIoFailure (show err))
    Right value -> value

readOpenIntent :: Fd -> IO (Either HostCleanupIntentError StoredIntent)
readOpenIntent fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then pure (Left HostCleanupIntentFileNotRegular)
    else
      if fileMode status `intersectFileModes` accessModes /= ownerFileMode
        then pure (Left HostCleanupIntentFileModeInvalid)
        else case boundedFileSize status of
          Left err -> pure (Left err)
          Right () -> do
            bytes <- readFdBounded fd (maximumHostCleanupIntentBytes + 1)
            pure $ do
              if ByteString.length bytes > maximumHostCleanupIntentBytes
                then
                  Left
                    ( HostCleanupIntentEncodedTooLarge
                        (ByteString.length bytes)
                        maximumHostCleanupIntentBytes
                    )
                else Right ()
              intent <- decodeHostCleanupIntent bytes
              Right (StoredIntentPresent bytes intent)

boundedFileSize :: FileStatus -> Either HostCleanupIntentError ()
boundedFileSize status
  | toInteger (fileSize status) < 0 =
      Left (HostCleanupIntentDecodeInvalid "cleanup intent reported a negative size")
  | toInteger (fileSize status) > toInteger maximumHostCleanupIntentBytes =
      Left
        ( HostCleanupIntentEncodedTooLarge
            (fromInteger (toInteger (fileSize status)))
            maximumHostCleanupIntentBytes
        )
  | otherwise = Right ()

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        readResult <-
          try (PosixByteString.fdRead fd (fromIntegral (min remaining (64 * 1024))))
        case readResult of
          Left (err :: IOException)
            | isEOFError err -> pure (ByteString.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (remaining - ByteString.length chunk) (chunk : chunks)

atomicPersistAndReadBack
  :: HostCleanupIntentStore
  -> ByteString
  -> HostCleanupIntent
  -> IO (Either HostCleanupIntentError HostCleanupIntent)
atomicPersistAndReadBack store expectedBytes expected = do
  written <- atomicPersist store expectedBytes
  case written of
    Left err -> pure (Left err)
    Right () -> do
      observed <- readStoredIntent (hostCleanupIntentPath store)
      pure $ case observed of
        Right (StoredIntentPresent actualBytes actual)
          | actualBytes == expectedBytes && actual == expected -> Right actual
        Left err -> Left err
        _ -> Left HostCleanupIntentReadBackMismatch

atomicPersist
  :: HostCleanupIntentStore
  -> ByteString
  -> IO (Either HostCleanupIntentError ())
atomicPersist store bytes = do
  result <- try . mask_ $ do
    bracket
      ( openFd
          (hostCleanupIntentTemporaryPath store)
          WriteOnly
          defaultFileFlags
            { trunc = True
            , creat = Just ownerFileMode
            , nofollow = True
            , cloexec = True
            }
      )
      safeCloseFd
      ( \fd -> do
          setFdMode fd ownerFileMode
          status <- getFdStatus fd
          if not (isRegularFile status)
            then ioError (userError "cleanup intent temporary path is not a regular file")
            else do
              writeAll fd bytes
              fileSynchronise fd
      )
    renameFile
      (hostCleanupIntentTemporaryPath store)
      (hostCleanupIntentPath store)
    syncIntentDirectory store
  pure $ case result :: Either IOException () of
    Left err -> Left (HostCleanupIntentIoFailure (show err))
    Right () -> Right ()

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then ioError (userError "cleanup intent write made no progress")
    else writeAll fd (ByteString.drop count bytes)

syncIntentDirectory :: HostCleanupIntentStore -> IO ()
syncIntentDirectory store =
  bracket
    ( openFd
        (hostCleanupIntentDirectory store)
        ReadOnly
        defaultFileFlags {directory = True, nofollow = True, cloexec = True}
    )
    safeCloseFd
    fileSynchronise
