{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Write-ahead identity for a disposable network probe. These records do not
-- authorize an effect or establish that a Kubernetes resource exists or is gone.
module Prodbox.Control.KindNetworkProbeRecord
  ( ProbeRecord (..)
  , ProbeVerifierDiagnostic (..)
  , ProbeRecordWrite (..)
  , ProbeRecordObservation (..)
  , ProbeCreatedObservation (..)
  , ProbeRemovalAttemptObservation (..)
  , ProbeRemovalFailureObservation (..)
  , ProbeAttemptReadbackObservation (..)
  , ProbeVerifierLaunchObservation (..)
  , ProbeSuccessorObservation (..)
  , ProbeSuccessorChainObservation (..)
  , ProbeRecoveryLaunchObservation (..)
  , ProbePublicationObservation (..)
  , recordProbeRecord
  , observeProbeRecord
  , observeProbeCreated
  , observeProbeRemovalAttempt
  , observeProbeRemovalFailure
  , observeProbeAttemptReadback
  , observeProbeVerifierLaunch
  , observeProbeVerifierPublicationAttempt
  , observeProbeSuccessorLaunch
  , observeProbeSuccessorPublication
  , observeProbeSuccessorChain
  , observeProbeSuccessorChainState
  , observeProbeRecoveryLaunch
  , observeProbePublicationAttempt
  ) where

import Control.Exception (IOException, bracket, mask, try)
import Control.Monad (unless)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.BootstrapProjection (BootstrapProjection, bootstrapRootGeneration, bootstrapScope)
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeEnvironment
  , scopeIdentifier
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindFamilyIntent, observeKindIntent)
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data ProbeVerifierDiagnostic = VerifierPreparationRefused | VerifierParentRefused | VerifierParentUnconfirmed | VerifierHandoffRefused | VerifierOriginalRetirementRefused | VerifierPriorRetirementRefused | VerifierSuccessorRetirementRefused | VerifierLeaseUnconfirmed | VerifierOriginalLeaseUnconfirmed | VerifierCleanupLeaseUnconfirmed | VerifierFirstLeaseUnconfirmed | VerifierChainLeaseUnconfirmed | VerifierOperationLeaseUnconfirmed | VerifierReadbackInvalid | VerifierFamilyRefused | VerifierSnapshotUnobservable | VerifierJournalRefused | VerifierIdentityChanged | VerifierAbsenceUnconfirmed | VerifierRecordRefused | VerifierRecordAlreadyExists | VerifierRecordIncomplete | VerifierRecordUnexpected | VerifierChangedAfterRecord | VerifierReadbackRecorded | VerifierClosingUnconfirmed
  deriving (Eq, Show)

data ProbeRecord = ProbeIntent | ProbeCreated !String | ProbeRecoveryLaunch !Request.ProbeRecoveryRequest | ProbePublicationAttempt !Request.ProbeRecoveryRequest | ProbeRemovalAttempt !String !String | ProbeRemovalFailure !String !String !Int | ProbeVerifierLaunch !Request.ProbeAttemptVerifierRequest | ProbeVerifierPublicationAttempt !Request.ProbeAttemptVerifierRequest | ProbeVerifierDiagnosticRecord !Request.ProbeAttemptVerifierRequest !ProbeVerifierDiagnostic | ProbeSuccessorLaunch !Request.ProbeSuccessorRequest | ProbeSuccessorPublication !Request.ProbeSuccessorRequest | ProbeSuccessorCancellation !Request.ProbeSuccessorRequest | ProbeSuccessorDiagnosticRecord !Request.ProbeSuccessorRequest !ProbeVerifierDiagnostic | ProbeSuccessorReadback !Request.ProbeSuccessorRequest | ProbeAttemptReadback !String !String !String | ProbeRemoved !String
  deriving (Eq, Show)

data ProbeRecordWrite = ProbeRecorded | ProbeAlreadyExists | ProbeRefused | ProbeIncomplete
  deriving (Eq, Show)

data ProbeRecordObservation = ProbeMissing | ProbeMatches | ProbeConflict | ProbeUnobservable
  deriving (Eq, Show)

data ProbeSuccessorObservation = ProbeSuccessorMissing | ProbeSuccessorObserved !Request.ProbeSuccessorRequest | ProbeSuccessorConflict | ProbeSuccessorUnobservable
  deriving (Eq, Show)

data ProbeSuccessorChainObservation = ProbeSuccessorChainComplete ![Request.ProbeSuccessorRequest] | ProbeSuccessorChainStaged ![Request.ProbeSuccessorRequest] !Request.ProbeSuccessorRequest | ProbeSuccessorChainConflict | ProbeSuccessorChainUnobservable
  deriving (Eq, Show)

data ProbeCreatedObservation
  = ProbeCreatedMissing
  | ProbeCreatedObserved !String
  | ProbeCreatedConflict
  | ProbeCreatedUnobservable
  deriving (Eq, Show)

data ProbeRemovalAttemptObservation
  = ProbeRemovalAttemptMissing
  | ProbeRemovalAttemptObserved !String !String
  | ProbeRemovalAttemptConflict
  | ProbeRemovalAttemptUnobservable
  deriving (Eq, Show)

data ProbeRemovalFailureObservation
  = ProbeRemovalFailureMissing
  | ProbeRemovalFailureObserved !String !String !Int
  | ProbeRemovalFailureConflict
  | ProbeRemovalFailureUnobservable
  deriving (Eq, Show)

data ProbeAttemptReadbackObservation
  = ProbeAttemptReadbackMissing
  | ProbeAttemptReadbackObserved !String !String !String
  | ProbeAttemptReadbackConflict
  | ProbeAttemptReadbackUnobservable
  deriving (Eq, Show)

data ProbeVerifierLaunchObservation
  = ProbeVerifierLaunchMissing
  | ProbeVerifierLaunchObserved !Request.ProbeAttemptVerifierRequest
  | ProbeVerifierLaunchConflict
  | ProbeVerifierLaunchUnobservable
  deriving (Eq, Show)

data ProbeRecoveryLaunchObservation
  = ProbeRecoveryLaunchMissing
  | ProbeRecoveryLaunchObserved !Request.ProbeRecoveryRequest
  | ProbeRecoveryLaunchConflict
  | ProbeRecoveryLaunchUnobservable
  deriving (Eq, Show)

data ProbePublicationObservation
  = ProbePublicationMissing
  | ProbePublicationObserved !Request.ProbeRecoveryRequest
  | ProbePublicationConflict
  | ProbePublicationUnobservable
  deriving (Eq, Show)

data ProbeRead
  = RecordMissing
  | RecordValue !Aeson.Value !Files.FileStatus
  | RecordConflict
  | RecordUnobservable

validNamespace :: String -> Bool
validNamespace value =
  not (null value)
    && length value <= 63
    && all (\c -> isAsciiLower c || (isDigit c && c <= '9') || c == '-') value
    && take 1 value /= "-"
    && take 1 (reverse value) /= "-"

validUid :: String -> Bool
validUid value =
  length value == 36
    && and
      [ if index `elem` [8, 13, 18, 23] then c == '-' else isDigit c && c <= '9' || c >= 'a' && c <= 'f'
      | (index, c) <- zip [0 :: Int ..] value
      ]

validInput :: BootstrapProjection -> String -> String -> ProbeRecord -> Bool
validInput bootstrap operation namespace record =
  scopeEnvironment (bootstrapScope bootstrap) == Test
    && validRootGeneration operation
    && validNamespace namespace
    && case record of
      ProbeIntent -> True
      ProbeCreated uid -> validUid uid
      ProbeRecoveryLaunch request ->
        namespace == "prodbox-netcheck-" ++ take 12 operation
          && Request.decodeProbeRecoveryRequest bootstrap operation (Request.encodeProbeRecoveryRequest request) == Right request
      ProbePublicationAttempt request -> validInput bootstrap operation namespace (ProbeRecoveryLaunch request)
      ProbeRemovalAttempt uid recovery -> validUid uid && validRootGeneration recovery && recovery /= operation
      ProbeRemovalFailure uid recovery code -> validInput bootstrap operation namespace (ProbeRemovalAttempt uid recovery) && code > 0 && code <= 255
      ProbeVerifierLaunch request ->
        namespace == "prodbox-netcheck-" ++ take 12 operation
          && Request.decodeProbeAttemptVerifierRequest bootstrap operation (Request.encodeProbeAttemptVerifierRequest request) == Right request
      ProbeVerifierPublicationAttempt request -> validInput bootstrap operation namespace (ProbeVerifierLaunch request)
      ProbeVerifierDiagnosticRecord request _ -> validInput bootstrap operation namespace (ProbeVerifierLaunch request)
      ProbeSuccessorLaunch request -> namespace == "prodbox-netcheck-" ++ take 12 operation
        && Request.decodeProbeSuccessorRequest bootstrap operation (Request.encodeProbeSuccessorRequest request) == Right request
      ProbeSuccessorPublication request -> validInput bootstrap operation namespace (ProbeSuccessorLaunch request)
      ProbeSuccessorCancellation request -> validInput bootstrap operation namespace (ProbeSuccessorLaunch request)
      ProbeSuccessorDiagnosticRecord request _ -> validInput bootstrap operation namespace (ProbeSuccessorLaunch request)
      ProbeSuccessorReadback request -> validInput bootstrap operation namespace (ProbeSuccessorLaunch request)
      ProbeAttemptReadback uid recovery verifier ->
        namespace == "prodbox-netcheck-" ++ take 12 operation
          && validInput bootstrap operation namespace (ProbeRemovalAttempt uid recovery)
          && validRootGeneration verifier && verifier /= operation && verifier /= recovery
      ProbeRemoved uid -> validUid uid

recordName :: String -> ProbeRecord -> FilePath
recordName namespace record = "kind-network-probe-" ++ namespace ++ suffix
 where
  suffix = case record of
    ProbeIntent -> "-intent.json"
    ProbeCreated _ -> "-created.json"
    ProbeRecoveryLaunch _ -> "-recovery-launch.json"
    ProbePublicationAttempt _ -> "-publication-attempt.json"
    ProbeRemovalAttempt _ _ -> "-removal-attempt.json"
    ProbeRemovalFailure {} -> "-removal-failure.json"
    ProbeVerifierLaunch _ -> "-verifier-launch.json"
    ProbeVerifierPublicationAttempt _ -> "-verifier-publication-attempt.json"
    ProbeVerifierDiagnosticRecord request _ -> "-verifier-result-" ++ Request.probeRecoveryId (Request.probeVerifierRecoveryRequest request) ++ ".json"
    ProbeSuccessorLaunch request -> "-successor-of-" ++ Request.probeSuccessorPredecessorId request ++ ".json"
    ProbeSuccessorPublication request -> "-successor-published-" ++ Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request)) ++ ".json"
    ProbeSuccessorCancellation request -> "-successor-cancelled-" ++ Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request)) ++ ".json"
    ProbeSuccessorDiagnosticRecord request _ -> "-successor-result-" ++ Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request)) ++ ".json"
    ProbeSuccessorReadback request -> "-successor-readback-" ++ Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request)) ++ ".json"
    ProbeAttemptReadback {} -> "-attempt-readback.json"
    ProbeRemoved _ -> "-removed.json"

recordValue :: BootstrapProjection -> String -> String -> ProbeRecord -> Files.FileStatus -> Aeson.Value
recordValue bootstrap operation namespace record root =
  Aeson.object $
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-network-probe" :: String)
    , "deployment_id" Aeson..= scopeIdentifier (bootstrapScope bootstrap)
    , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
    , "operation_id" Aeson..= operation
    , "namespace" Aeson..= namespace
    , "stage" Aeson..= stage
    , "namespace_uid" Aeson..= uid
    , "root_device" Aeson..= toInteger (Files.deviceID root)
    , "root_inode" Aeson..= toInteger (Files.fileID root)
    ] ++ case record of
      ProbeRemovalAttempt _ recovery -> ["recovery_id" Aeson..= recovery]
      ProbeRemovalFailure _ recovery code -> ["recovery_id" Aeson..= recovery, "exit_code" Aeson..= code]
      ProbeAttemptReadback _ recovery verifier -> ["recovery_id" Aeson..= recovery, "verifier_id" Aeson..= verifier]
      ProbeVerifierLaunch request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeAttemptVerifierRequest request), "publication_protocol" Aeson..= (1 :: Int)]
      ProbeVerifierPublicationAttempt request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeAttemptVerifierRequest request)]
      ProbeVerifierDiagnosticRecord request result -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeAttemptVerifierRequest request), "result" Aeson..= show result]
      ProbeSuccessorLaunch request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeSuccessorRequest request)]
      ProbeSuccessorPublication request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeSuccessorRequest request)]
      ProbeSuccessorCancellation request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeSuccessorRequest request)]
      ProbeSuccessorDiagnosticRecord request result -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeSuccessorRequest request), "result" Aeson..= show result]
      ProbeSuccessorReadback request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeSuccessorRequest request)]
      ProbeRecoveryLaunch request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeRecoveryRequest request), "publication_protocol" Aeson..= (1 :: Int)]
      ProbePublicationAttempt request -> ["request" Aeson..= TextEncoding.decodeUtf8 (Request.encodeProbeRecoveryRequest request)]
      _ -> []
 where
  (stage, uid) = case record of
    ProbeIntent -> ("intent" :: String, Nothing)
    ProbeCreated identity -> ("created", Just identity)
    ProbeRecoveryLaunch request -> ("recovery-launch", Just (Request.probeRecoveryNamespaceUid request))
    ProbePublicationAttempt request -> ("publication-attempt", Just (Request.probeRecoveryNamespaceUid request))
    ProbeRemovalAttempt identity _ -> ("removal-attempt", Just identity)
    ProbeRemovalFailure identity _ _ -> ("removal-failure", Just identity)
    ProbeVerifierLaunch request -> ("verifier-launch", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest request)))
    ProbeVerifierPublicationAttempt request -> ("verifier-publication-attempt", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest request)))
    ProbeVerifierDiagnosticRecord request _ -> ("verifier-result", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest request)))
    ProbeSuccessorLaunch request -> ("successor-launch", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))))
    ProbeSuccessorPublication request -> ("successor-publication", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))))
    ProbeSuccessorCancellation request -> ("successor-cancellation", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))))
    ProbeSuccessorDiagnosticRecord request _ -> ("successor-result", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))))
    ProbeSuccessorReadback request -> ("successor-readback", Just (Request.probeRecoveryNamespaceUid (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))))
    ProbeAttemptReadback identity _ _ -> ("attempt-readback", Just identity)
    ProbeRemoved identity -> ("removed", Just identity)

ready :: BootstrapProjection -> IO Bool -> IO Bool -> IO Bool
ready bootstrap stable sameRoot = do
  a <- stable
  b <- sameRoot
  generation <- observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
  c <- sameRoot
  d <- stable
  pure (a && b && generation == Right ScopeGenerationMatches && c && d)

readFlags, createFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

safeFile :: UserID -> Files.FileStatus -> Bool
safeFile owner status =
  Files.isRegularFile status && Files.fileOwner status == owner
    && Files.fileMode status .&. 0o077 == 0 && Files.linkCount status == 1
    && Files.fileSize status >= 0 && Files.fileSize status <= 4096

sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion a b =
  Files.deviceID a == Files.deviceID b && Files.fileID a == Files.fileID b
    && Files.fileOwner a == Files.fileOwner b && Files.fileMode a == Files.fileMode b
    && Files.linkCount a == Files.linkCount b && Files.fileSize a == Files.fileSize b
    && Files.modificationTimeHiRes a == Files.modificationTimeHiRes b
    && Files.statusChangeTimeHiRes a == Files.statusChangeTimeHiRes b

verifierPrerequisites :: BootstrapProjection -> String -> String -> Request.ProbeAttemptVerifierRequest -> IO Bool -> IO Bool
verifierPrerequisites bootstrap operation namespace request stable = do
  let verifier = Request.probeVerifierRecoveryRequest request
      uid = Request.probeRecoveryNamespaceUid verifier
      priorId = Request.probeVerifierPriorId request
  launch <- observeProbeRecoveryLaunch bootstrap operation namespace stable
  publication <- observeProbePublicationAttempt bootstrap operation namespace stable
  attempted <- observeProbeRemovalAttempt bootstrap operation namespace stable
  failure <- observeProbeRemovalFailure bootstrap operation namespace stable
  readback <- observeProbeAttemptReadback bootstrap operation namespace stable
  removed <- observeProbeRecord bootstrap operation namespace (ProbeRemoved uid) stable
  pure $ case launch of
    ProbeRecoveryLaunchObserved prior -> Request.probeRecoveryId prior == priorId
      && Request.probeRecoveryNamespaceUid prior == uid && publication == ProbePublicationObserved prior
      && (attempted == ProbeRemovalAttemptObserved uid priorId || (Request.probeVerifierIsIsolated request && attempted == ProbeRemovalAttemptMissing)) && failure == ProbeRemovalFailureMissing
      && readback == ProbeAttemptReadbackMissing && removed == ProbeMissing
    _ -> False

-- The caller must hold the recovered operation lease throughout this call.
recordProbeRecord :: BootstrapProjection -> String -> String -> ProbeRecord -> IO Bool -> IO ProbeRecordWrite
recordProbeRecord bootstrap operation namespace record stable
  | not (validInput bootstrap operation namespace record) = pure ProbeRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      outcome <- timeout 60000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          -- The lease and root are checked around this complete local snapshot.
          -- Repeating the external admission proof inside every nested read
          -- can exhaust the writer deadline before any effect is recorded.
          let snapshotStable = pure True
          prerequisite <- case record of
            ProbeRecoveryLaunch request -> do
              family <- observeKindFamilyIntent bootstrap
              intent <- observeProbeRecord bootstrap operation namespace ProbeIntent snapshotStable
              created <- observeProbeCreated bootstrap operation namespace snapshotStable
              attempted <- observeProbeRemovalAttempt bootstrap operation namespace snapshotStable
              failure <- observeProbeRemovalFailure bootstrap operation namespace snapshotStable
              readback <- observeProbeAttemptReadback bootstrap operation namespace snapshotStable
              removed <- observeProbeRecord bootstrap operation namespace (ProbeRemoved (Request.probeRecoveryNamespaceUid request)) snapshotStable
              pure (family == KindIntentMatches operation && intent == ProbeMatches && created == ProbeCreatedObserved (Request.probeRecoveryNamespaceUid request)
                && attempted == ProbeRemovalAttemptMissing && failure == ProbeRemovalFailureMissing && readback == ProbeAttemptReadbackMissing && removed == ProbeMissing)
            ProbePublicationAttempt request -> do
              launch <- observeProbeRecoveryLaunch bootstrap operation namespace snapshotStable
              attempted <- observeProbeRemovalAttempt bootstrap operation namespace snapshotStable
              failure <- observeProbeRemovalFailure bootstrap operation namespace snapshotStable
              readback <- observeProbeAttemptReadback bootstrap operation namespace snapshotStable
              removed <- observeProbeRecord bootstrap operation namespace (ProbeRemoved (Request.probeRecoveryNamespaceUid request)) snapshotStable
              pure (launch == ProbeRecoveryLaunchObserved request && attempted == ProbeRemovalAttemptMissing && failure == ProbeRemovalFailureMissing && readback == ProbeAttemptReadbackMissing && removed == ProbeMissing)
            ProbeRemovalFailure uid recovery _ -> do
              attempted <- observeProbeRemovalAttempt bootstrap operation namespace snapshotStable
              pure (attempted == ProbeRemovalAttemptObserved uid recovery)
            ProbeAttemptReadback uid recovery verifierId -> do
              attempted <- observeProbeRemovalAttempt bootstrap operation namespace snapshotStable
              failure <- observeProbeRemovalFailure bootstrap operation namespace snapshotStable
              removed <- observeProbeRecord bootstrap operation namespace (ProbeRemoved uid) snapshotStable
              verifier <- observeProbeVerifierLaunch bootstrap operation namespace snapshotStable
              case verifier of
                ProbeVerifierLaunchObserved request -> do
                  marker <- observeProbeRecord bootstrap operation namespace (ProbeVerifierPublicationAttempt request) snapshotStable
                  prior <- verifierPrerequisites bootstrap operation namespace request snapshotStable
                  let coordinates = Request.probeVerifierRecoveryRequest request
                  pure ((attempted == ProbeRemovalAttemptObserved uid recovery || (Request.probeVerifierIsIsolated request && attempted == ProbeRemovalAttemptMissing)) && failure == ProbeRemovalFailureMissing
                    && removed == ProbeMissing && marker == ProbeMatches && prior && Request.probeVerifierPriorId request == recovery
                    && Request.probeRecoveryId coordinates == verifierId && Request.probeRecoveryNamespaceUid coordinates == uid)
                _ -> pure False
            ProbeVerifierLaunch request -> verifierPrerequisites bootstrap operation namespace request snapshotStable
            ProbeVerifierPublicationAttempt request -> do
              launch <- observeProbeVerifierLaunch bootstrap operation namespace snapshotStable
              prior <- verifierPrerequisites bootstrap operation namespace request snapshotStable
              pure (launch == ProbeVerifierLaunchObserved request && prior)
            ProbeVerifierDiagnosticRecord request _ -> do
              launch <- observeProbeVerifierLaunch bootstrap operation namespace snapshotStable
              marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace snapshotStable
              pure (launch == ProbeVerifierLaunchObserved request && marker == ProbeVerifierLaunchObserved request)
            ProbeSuccessorLaunch request -> do
              before <- snapshotStable
              initial <- observeProbeVerifierLaunch bootstrap operation namespace (pure True)
              initialMarker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace (pure True)
              result <- case initial of
                ProbeVerifierLaunchObserved first | initialMarker == ProbeVerifierLaunchObserved first -> do
                  chain <- observeProbeSuccessorChain bootstrap operation namespace first (pure True)
                  prior <- verifierPrerequisites bootstrap operation namespace (Request.probeSuccessorVerifier request) (pure True)
                  case chain of
                    Right entries -> do
                      readbacks <- mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) (pure True)) entries
                      pure (prior && all (== ProbeMissing) readbacks && Request.validProbeSuccessorChain first (entries ++ [request]))
                    Left _ -> pure False
                _ -> pure False
              after <- snapshotStable
              pure (before && result && after)
            ProbeSuccessorPublication request -> do
              launch <- observeProbeSuccessorLaunch bootstrap operation namespace (Request.probeSuccessorPredecessorId request) snapshotStable
              cancelled <- observeProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation request) snapshotStable
              pure (launch == ProbeSuccessorObserved request && cancelled == ProbeMissing)
            ProbeSuccessorCancellation request -> do
              let identity = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))
              launch <- observeProbeSuccessorLaunch bootstrap operation namespace (Request.probeSuccessorPredecessorId request) snapshotStable
              marker <- observeProbeSuccessorPublication bootstrap operation namespace identity snapshotStable
              readback <- observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback request) snapshotStable
              pure (launch == ProbeSuccessorObserved request && marker == ProbeSuccessorMissing && readback == ProbeMissing)
            ProbeSuccessorDiagnosticRecord request _ -> do
              let identity = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))
              launch <- observeProbeSuccessorLaunch bootstrap operation namespace (Request.probeSuccessorPredecessorId request) snapshotStable
              marker <- observeProbeSuccessorPublication bootstrap operation namespace identity snapshotStable
              pure (launch == ProbeSuccessorObserved request && marker == ProbeSuccessorObserved request)
            ProbeSuccessorReadback request -> do
              initial <- observeProbeVerifierLaunch bootstrap operation namespace snapshotStable
              marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace snapshotStable
              let identity = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))
              publication <- observeProbeSuccessorPublication bootstrap operation namespace identity snapshotStable
              cancelled <- observeProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation request) snapshotStable
              prior <- verifierPrerequisites bootstrap operation namespace (Request.probeSuccessorVerifier request) snapshotStable
              case initial of
                ProbeVerifierLaunchObserved first | marker == ProbeVerifierLaunchObserved first -> do
                  chain <- observeProbeSuccessorChain bootstrap operation namespace first snapshotStable
                  case chain of
                    Right entries -> case reverse entries of
                      latest : previous -> do
                        readbacks <- mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) snapshotStable) previous
                        pure (prior && latest == request && publication == ProbeSuccessorObserved request && cancelled == ProbeMissing && all (== ProbeMissing) readbacks)
                      [] -> pure False
                    _ -> pure False
                _ -> pure False
            _ -> pure True
          stillAdmitted <- ready bootstrap operationStable sameRoot
          rootStatus <- Files.getFdStatus root
          if not (admitted && prerequisite && stillAdmitted) then pure ProbeRefused else mask $ \restore -> do
            opened <- try (Posix.openFdAt (Just root) (recordName namespace record) Posix.WriteOnly createFlags)
            case opened of
              Left failure | isAlreadyExistsError failure -> pure ProbeAlreadyExists
              Left (_ :: IOException) -> pure ProbeRefused
              Right file -> do
                writeIORef touched True
                written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                  writeAll held (LazyByteString.toStrict (Aeson.encode (recordValue bootstrap operation namespace record rootStatus)))
                  fileSynchronise held
                  fileSynchronise root
                case written of
                  Left (_ :: IOException) -> pure ProbeIncomplete
                  Right () -> do
                    before <- restore operationStable
                    observed <- if before then restore (observeProbeRecord bootstrap operation namespace record (pure True)) else pure ProbeUnobservable
                    after <- restore operationStable
                    pure (if before && observed == ProbeMatches && after then ProbeRecorded else ProbeIncomplete)
        pure (either (const ProbeRefused) id (attempted :: Either IOException ProbeRecordWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right result) | result /= ProbeRefused -> result
        _ | changed -> ProbeIncomplete
        _ -> ProbeRefused

observeProbeRecord :: BootstrapProjection -> String -> String -> ProbeRecord -> IO Bool -> IO ProbeRecordObservation
observeProbeRecord bootstrap operation namespace record stable = do
  result <- readProbeRecord bootstrap operation namespace record stable
  pure $ case result of
    RecordMissing -> ProbeMissing
    RecordValue value root
      | value == recordValue bootstrap operation namespace record root -> ProbeMatches
      | otherwise -> ProbeConflict
    RecordConflict -> ProbeConflict
    RecordUnobservable -> ProbeUnobservable

-- Extract the UID only after verifying the complete scope-bound record. A
-- recorded UID is an identity for recovery, not evidence of worker settlement.
observeProbeCreated :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeCreatedObservation
observeProbeCreated bootstrap operation namespace stable = do
  result <- readProbeRecord bootstrap operation namespace (ProbeCreated placeholder) stable
  pure $ case result of
    RecordMissing -> ProbeCreatedMissing
    RecordConflict -> ProbeCreatedConflict
    RecordUnobservable -> ProbeCreatedUnobservable
    RecordValue value root ->
      case parseEither (Aeson.withObject "probe record" (.: "namespace_uid")) value of
        Right uid
          | validUid uid && value == recordValue bootstrap operation namespace (ProbeCreated uid) root -> ProbeCreatedObserved uid
        _ -> ProbeCreatedConflict
 where
  placeholder = "00000000-0000-0000-0000-000000000000"

-- This binds a cleanup attempt to its separate worker identity. It does not
-- establish that the worker was submitted, processed or physically retired.
observeProbeRemovalAttempt :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeRemovalAttemptObservation
observeProbeRemovalAttempt bootstrap operation namespace stable = do
  let placeholderUid = "00000000-0000-0000-0000-000000000000"
      placeholderRecovery = if operation == replicate 32 '0' then replicate 32 '1' else replicate 32 '0'
  result <- readProbeRecord bootstrap operation namespace (ProbeRemovalAttempt placeholderUid placeholderRecovery) stable
  pure $ case result of
    RecordMissing -> ProbeRemovalAttemptMissing
    RecordConflict -> ProbeRemovalAttemptConflict
    RecordUnobservable -> ProbeRemovalAttemptUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe removal attempt" $ \object ->
      (,) <$> object .: "namespace_uid" <*> object .: "recovery_id") value of
        Right (uid, recovery)
          | validInput bootstrap operation namespace (ProbeRemovalAttempt uid recovery)
          , value == recordValue bootstrap operation namespace (ProbeRemovalAttempt uid recovery) root ->
              ProbeRemovalAttemptObserved uid recovery
        _ -> ProbeRemovalAttemptConflict

observeProbeRemovalFailure :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeRemovalFailureObservation
observeProbeRemovalFailure bootstrap operation namespace stable = do
  let placeholderUid = "00000000-0000-0000-0000-000000000000"
      placeholderRecovery = if operation == replicate 32 '0' then replicate 32 '1' else replicate 32 '0'
  result <- readProbeRecord bootstrap operation namespace (ProbeRemovalFailure placeholderUid placeholderRecovery 1) stable
  pure $ case result of
    RecordMissing -> ProbeRemovalFailureMissing
    RecordConflict -> ProbeRemovalFailureConflict
    RecordUnobservable -> ProbeRemovalFailureUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe removal failure" $ \object ->
      (,,) <$> object .: "namespace_uid" <*> object .: "recovery_id" <*> object .: "exit_code") value of
        Right (uid, recovery, code)
          | validInput bootstrap operation namespace (ProbeRemovalFailure uid recovery code)
          , value == recordValue bootstrap operation namespace (ProbeRemovalFailure uid recovery code) root ->
              ProbeRemovalFailureObserved uid recovery code
        _ -> ProbeRemovalFailureConflict

observeProbeAttemptReadback :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeAttemptReadbackObservation
observeProbeAttemptReadback bootstrap operation namespace stable = do
  result <- readProbeNamed bootstrap operation namespace ("kind-network-probe-" ++ namespace ++ "-attempt-readback.json") stable
  pure $ case result of
    RecordMissing -> ProbeAttemptReadbackMissing
    RecordConflict -> ProbeAttemptReadbackConflict
    RecordUnobservable -> ProbeAttemptReadbackUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe attempt readback" $ \object ->
      (,,) <$> object .: "namespace_uid" <*> object .: "recovery_id" <*> object .: "verifier_id") value of
        Right (uid, prior, observer)
          | validInput bootstrap operation namespace (ProbeAttemptReadback uid prior observer)
          , value == recordValue bootstrap operation namespace (ProbeAttemptReadback uid prior observer) root ->
              ProbeAttemptReadbackObserved uid prior observer
        _ -> ProbeAttemptReadbackConflict

-- This exclusive write-ahead locator is not proof of submission or retirement.
observeProbeRecoveryLaunch :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeRecoveryLaunchObservation
observeProbeRecoveryLaunch bootstrap operation namespace stable = do
  result <- if namespace == "prodbox-netcheck-" ++ take 12 operation
    then readProbeNamed bootstrap operation namespace ("kind-network-probe-" ++ namespace ++ "-recovery-launch.json") stable
    else pure RecordUnobservable
  pure $ case result of
    RecordMissing -> ProbeRecoveryLaunchMissing
    RecordConflict -> ProbeRecoveryLaunchConflict
    RecordUnobservable -> ProbeRecoveryLaunchUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe recovery launch" (.: "request")) value of
      Right encoded -> case Request.decodeProbeRecoveryRequest bootstrap operation (TextEncoding.encodeUtf8 encoded) of
        Right request | value == recordValue bootstrap operation namespace (ProbeRecoveryLaunch request) root -> ProbeRecoveryLaunchObserved request
        _ -> ProbeRecoveryLaunchConflict
      _ -> ProbeRecoveryLaunchConflict

observeProbePublicationAttempt :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbePublicationObservation
observeProbePublicationAttempt bootstrap operation namespace stable = do
  result <- if namespace == "prodbox-netcheck-" ++ take 12 operation
    then readProbeNamed bootstrap operation namespace ("kind-network-probe-" ++ namespace ++ "-publication-attempt.json") stable
    else pure RecordUnobservable
  pure $ case result of
    RecordMissing -> ProbePublicationMissing
    RecordConflict -> ProbePublicationConflict
    RecordUnobservable -> ProbePublicationUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe publication attempt" (.: "request")) value of
      Right encoded -> case Request.decodeProbeRecoveryRequest bootstrap operation (TextEncoding.encodeUtf8 encoded) of
        Right request | value == recordValue bootstrap operation namespace (ProbePublicationAttempt request) root -> ProbePublicationObserved request
        _ -> ProbePublicationConflict
      _ -> ProbePublicationConflict

observeProbeVerifierLaunch :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeVerifierLaunchObservation
observeProbeVerifierLaunch = observeProbeVerifierRecord False

observeProbeVerifierPublicationAttempt :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeVerifierLaunchObservation
observeProbeVerifierPublicationAttempt = observeProbeVerifierRecord True

observeProbeVerifierRecord :: Bool -> BootstrapProjection -> String -> String -> IO Bool -> IO ProbeVerifierLaunchObservation
observeProbeVerifierRecord isPublication bootstrap operation namespace stable = do
  result <- readProbeNamed bootstrap operation namespace ("kind-network-probe-" ++ namespace ++ if isPublication then "-verifier-publication-attempt.json" else "-verifier-launch.json") stable
  pure $ case result of
    RecordMissing -> ProbeVerifierLaunchMissing
    RecordConflict -> ProbeVerifierLaunchConflict
    RecordUnobservable -> ProbeVerifierLaunchUnobservable
    RecordValue value root -> case parseEither (Aeson.withObject "probe verifier launch" (.: "request")) value of
      Right encoded -> case Request.decodeProbeAttemptVerifierRequest bootstrap operation (TextEncoding.encodeUtf8 encoded) of
        Right request | value == recordValue bootstrap operation namespace (if isPublication then ProbeVerifierPublicationAttempt request else ProbeVerifierLaunch request) root -> ProbeVerifierLaunchObserved request
        _ -> ProbeVerifierLaunchConflict
      _ -> ProbeVerifierLaunchConflict

observeProbeSuccessorLaunch :: BootstrapProjection -> String -> String -> String -> IO Bool -> IO ProbeSuccessorObservation
observeProbeSuccessorLaunch bootstrap operation namespace predecessor =
  observeProbeSuccessorRecord False bootstrap operation namespace predecessor

observeProbeSuccessorPublication :: BootstrapProjection -> String -> String -> String -> IO Bool -> IO ProbeSuccessorObservation
observeProbeSuccessorPublication bootstrap operation namespace identity =
  observeProbeSuccessorRecord True bootstrap operation namespace identity

observeProbeSuccessorRecord :: Bool -> BootstrapProjection -> String -> String -> String -> IO Bool -> IO ProbeSuccessorObservation
observeProbeSuccessorRecord publication bootstrap operation namespace identity stable
  | not (validRootGeneration identity) || namespace /= "prodbox-netcheck-" ++ take 12 operation = pure ProbeSuccessorUnobservable
  | otherwise = do
      let suffix = if publication then "-successor-published-" else "-successor-of-"
      result <- readProbeNamed bootstrap operation namespace ("kind-network-probe-" ++ namespace ++ suffix ++ identity ++ ".json") stable
      pure $ case result of
        RecordMissing -> ProbeSuccessorMissing
        RecordConflict -> ProbeSuccessorConflict
        RecordUnobservable -> ProbeSuccessorUnobservable
        RecordValue value root -> case parseEither (Aeson.withObject "probe successor" (.: "request")) value of
          Right encoded -> case Request.decodeProbeSuccessorRequest bootstrap operation (TextEncoding.encodeUtf8 encoded) of
            Right request
              | (if publication then Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request)) else Request.probeSuccessorPredecessorId request) == identity
              , value == recordValue bootstrap operation namespace (if publication then ProbeSuccessorPublication request else ProbeSuccessorLaunch request) root -> ProbeSuccessorObserved request
            _ -> ProbeSuccessorConflict
          _ -> ProbeSuccessorConflict

-- The caller independently binds the first verifier and its publication. A
-- missing next locator terminates a chain; an unpublished or unreadable
-- existing locator is an incomplete chain, never permission to append.
observeProbeSuccessorChain :: BootstrapProjection -> String -> String -> Request.ProbeAttemptVerifierRequest -> IO Bool -> IO (Either ProbeSuccessorObservation [Request.ProbeSuccessorRequest])
observeProbeSuccessorChain bootstrap operation namespace first stable = do
  observed <- observeProbeSuccessorChainState bootstrap operation namespace first stable
  pure $ case observed of
    ProbeSuccessorChainComplete entries -> Right entries
    ProbeSuccessorChainStaged _ _ -> Left ProbeSuccessorMissing
    ProbeSuccessorChainConflict -> Left ProbeSuccessorConflict
    ProbeSuccessorChainUnobservable -> Left ProbeSuccessorUnobservable

observeProbeSuccessorChainState :: BootstrapProjection -> String -> String -> Request.ProbeAttemptVerifierRequest -> IO Bool -> IO ProbeSuccessorChainObservation
observeProbeSuccessorChainState bootstrap operation namespace first stable = go [] (Request.probeRecoveryId (Request.probeVerifierRecoveryRequest first))
 where
  go entries predecessor = do
    next <- observeProbeSuccessorLaunch bootstrap operation namespace predecessor stable
    case next of
      ProbeSuccessorMissing -> pure (ProbeSuccessorChainComplete entries)
      ProbeSuccessorObserved request
        | length entries < 32 && Request.validProbeSuccessorChain first (entries ++ [request]) -> do
            let identity = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier request))
            marker <- observeProbeSuccessorPublication bootstrap operation namespace identity stable
            cancelled <- observeProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation request) stable
            case (marker, cancelled) of
              (ProbeSuccessorObserved marked, ProbeMissing) | marked == request -> go (entries ++ [request]) identity
              (ProbeSuccessorMissing, ProbeMatches) -> go (entries ++ [request]) identity
              (ProbeSuccessorMissing, ProbeMissing) -> pure (ProbeSuccessorChainStaged entries request)
              (ProbeSuccessorUnobservable, _) -> pure ProbeSuccessorChainUnobservable
              (_, ProbeUnobservable) -> pure ProbeSuccessorChainUnobservable
              _ -> pure ProbeSuccessorChainConflict
        | otherwise -> pure ProbeSuccessorChainConflict
      ProbeSuccessorConflict -> pure ProbeSuccessorChainConflict
      ProbeSuccessorUnobservable -> pure ProbeSuccessorChainUnobservable

readProbeRecord :: BootstrapProjection -> String -> String -> ProbeRecord -> IO Bool -> IO ProbeRead
readProbeRecord bootstrap operation namespace record stable
  | not (validInput bootstrap operation namespace record) = pure RecordUnobservable
  | otherwise = readProbeNamed bootstrap operation namespace (recordName namespace record) stable

readProbeNamed :: BootstrapProjection -> String -> String -> FilePath -> IO Bool -> IO ProbeRead
readProbeNamed bootstrap operation namespace name stable
  | not (validInput bootstrap operation namespace ProbeIntent) = pure RecordUnobservable
  | otherwise = do
      outcome <- timeout 30000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted then pure RecordUnobservable else do
            owner <- getEffectiveUserID
            opened <- try (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags)
            case opened of
              Left failure | isDoesNotExistError failure -> do
                still <- ready bootstrap stable sameRoot
                pure (if still then RecordMissing else RecordUnobservable)
              Left (_ :: IOException) -> pure RecordUnobservable
              Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                before <- Files.getFdStatus held
                if not (safeFile owner before) then pure RecordUnobservable else do
                  bytes <- readBounded held
                  checked <- decodeBoundedYamlValue bytes
                  after <- Files.getFdStatus held
                  named <- bracket (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags) Posix.closeFd Files.getFdStatus
                  still <- ready bootstrap stable sameRoot
                  pure $ if not (still && sameVersion before after && sameVersion after named)
                    then RecordUnobservable
                    else case (Aeson.eitherDecodeStrict' bytes, checked) of
                      (Right value, Right other) | value == other -> RecordValue value rootStatus
                      _ -> RecordConflict
        pure (either (const RecordUnobservable) id (attempted :: Either IOException ProbeRead))
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> RecordUnobservable

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll file bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite file bytes
      unless (count > 0) (ioError (userError "short probe record write"))
      writeAll file (ByteString.drop (fromIntegral count) bytes)

readBounded :: Fd -> IO ByteString.ByteString
readBounded file = go [] 0
 where
  go chunks count
    | count > 4096 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        result <- try (PosixBytes.fdRead file (fromIntegral (4097 - count)))
        case result of
          Left (failure :: IOException) | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          Left failure -> ioError failure
          Right chunk | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
          Right chunk -> go (chunk : chunks) (count + ByteString.length chunk)
