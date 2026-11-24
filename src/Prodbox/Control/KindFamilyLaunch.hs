{-# LANGUAGE ImportQualifiedPost #-}

-- | Write-ahead publication and one-shot submission of the kind family.
-- A returned manager reply is not worker or retirement evidence.
module Prodbox.Control.KindFamilyLaunch
  ( KindFamilyLaunchError (..)
  , KindFamilyLaunchClosing (..)
  , KindFamilyLaunchOutcome (..)
  , prepareFreshKindFamilyRequest
  , launchFreshKindFamily
  , launchKindFamily
  , KindProbeRecoveryLaunchOutcome (..)
  , launchKindProbeRecovery
  , KindProbeVerifierLaunchOutcome (..)
  , launchKindProbeVerifier
  , KindProbeSuccessorLaunchOutcome (..)
  , KindProbeSuccessorCancellationOutcome (..)
  , launchKindProbeSuccessor
  , cancelKindProbeSuccessorBeforePublication
  ) where

import Control.Exception (IOException, try)
import Control.Monad.Trans.Class (lift)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as Bytes
import Data.Text.Encoding qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection qualified as Bootstrap
import Prodbox.Control.KindController qualified as Kind
import Prodbox.Control.KindControllerReceipt qualified as Receipt
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindLease qualified as Lease
import Prodbox.Control.KindFamilyRecovery qualified as Recovery
import Prodbox.Control.KindNetworkProbeRecord qualified as Probe
import Prodbox.Control.NetworkEnforcement qualified as Network
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Environment (getExecutablePath)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data KindFamilyLaunchError
  = KindFamilyLaunchConfigurationRefused
  | KindFamilyLaunchPreparationRefused !Kind.KindFamilyPreparationError
  | KindFamilyLaunchManagerRefused !Bus.BusError
  | KindFamilyLaunchManagerMismatch
  | KindFamilyLaunchRecordRefused !Receipt.FamilyLaunchWrite
  | KindFamilyLaunchPublicationRefused !Publication.HostControllerPublicationError
  | KindFamilyLaunchProgramRefused !Family.HostOperationError
  | KindFamilyLaunchInputMismatch
  | KindFamilyLaunchLeaseChanged
  | KindFamilyLaunchLegacySubmissionUnconfirmed
  | KindFamilyLaunchExecutableUnobservable
  | KindFamilyLaunchWindowInvalid
  | KindFamilyLaunchRequestInvalid !Request.KindControllerRequestError
  | KindFamilyLaunchProbeRecordRefused !Probe.ProbeRecordWrite
  | KindFamilyLaunchProbeStateUnconfirmed
  deriving (Eq, Show)

data KindFamilyLaunchClosing
  = KindFamilyLaunchPossiblySent
  | KindFamilyLaunchUnsentRetired
  | KindFamilyLaunchUnsentUnconfirmed !InputRetirement.InputRetirementError
  deriving (Eq, Show)

data KindFamilyLaunchOutcome
  = KindFamilyLaunchRefused !KindFamilyLaunchError
  | KindFamilyLaunchLease !(Lease.KindOperationOutcome
      (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing)))
  deriving (Eq, Show)

data KindProbeRecoveryLaunchOutcome
  = KindProbeRecoveryLaunchRefused !KindFamilyLaunchError
  | KindProbeRecoveryLaunchRetirement
      !(Recovery.KindFamilyRetirementOutcome (Lease.KindOperationOutcome
        (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing))))
  deriving (Show)

data KindProbeVerifierLaunchOutcome
  = KindProbeVerifierLaunchRefused !KindFamilyLaunchError
  | KindProbeVerifierLaunchRetirement
      !(Recovery.KindFamilyRetirementOutcome (Recovery.KindFamilyRetirementOutcome
        (Lease.KindOperationOutcome
          (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing)))))
  deriving (Show)

data KindProbeSuccessorLaunchOutcome
  = KindProbeSuccessorLaunchRefused !KindFamilyLaunchError
  | KindProbeSuccessorLaunchRetirement !(Recovery.KindFamilyRetirementOutcome (Recovery.KindFamilyRetirementOutcome
      (Recovery.KindFamilyRetirementOutcome (Recovery.KindProbeSuccessorChainOutcome
        (Lease.KindOperationOutcome (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing)))))))
  deriving (Show)

data KindProbeSuccessorCancellationOutcome
  = KindProbeSuccessorCancellationRefused
  | KindProbeSuccessorCancellationRetirement !(Recovery.KindFamilyRetirementOutcome (Recovery.KindFamilyRetirementOutcome
      (Recovery.KindFamilyRetirementOutcome (Recovery.KindProbeSuccessorChainOutcome (Lease.KindOperationOutcome Probe.ProbeRecordWrite)))))
  deriving (Show)

-- These are candidate coordinates only. The publisher later hashes the
-- held executable again and independently rechecks the same manager domain.
prepareFreshKindFamilyRequest
  :: Bootstrap.BootstrapProjection -> String
  -> IO (Either KindFamilyLaunchError (Request.KindControllerRequest, Word64))
prepareFreshKindFamilyRequest bootstrap operation = do
  now <- getMonotonicTimeNSec
  let second = 1000000000 :: Word64
      duration = 590 * second
  if now > maxBound - duration then pure (Left KindFamilyLaunchWindowInvalid) else do
    let outer = now + duration
        work = now + 500 * second
        hard = now + 510 * second
        stop = now + 540 * second
        finish = now + 560 * second
    case Identity.hostExecutionWindow outer work hard stop finish of
      Nothing -> pure (Left KindFamilyLaunchWindowInvalid)
      Just window -> do
        digest <- currentExecutableDigest
        uid <- getEffectiveUserID
        manager <- Bus.withSystemdBus outer ("/run/user/" ++ show uid ++ "/bus") Bus.observeManagerDomain
        pure $ case (digest, manager) of
          (Nothing, _) -> Left KindFamilyLaunchExecutableUnobservable
          (_, Left failure) -> Left (KindFamilyLaunchManagerRefused failure)
          (Just value, Right domain) -> case Request.mkKindControllerRequest bootstrap operation value domain window of
            Left failure -> Left (KindFamilyLaunchRequestInvalid failure)
            Right request -> Right (request, outer)

-- Only a candidate digest is returned; bounded incremental reads avoid
-- retaining the executable in memory. The launch owner authenticates it.
currentExecutableDigest :: IO (Maybe String)
currentExecutableDigest = do
  result <- timeout 10000000 (try hash :: IO (Either IOException (Maybe String)))
  pure $ case result of Just (Right value) -> value; _ -> Nothing
 where
  hash = getExecutablePath >>= \path -> withBinaryFile path ReadMode (loop 0 SHA256.init)
  loop count state handle = do
    chunk <- Bytes.hGetSome handle 65536
    let total = count + Bytes.length chunk
    if total > 256 * 1024 * 1024 then pure Nothing else
      if Bytes.null chunk
        then pure (if count == 0 then Nothing else Just ("sha256:" ++ concatMap hex (Bytes.unpack (SHA256.finalize state))))
        else let next = SHA256.update state chunk in next `seq` loop total next handle
  hex byte = [digits !! fromIntegral (byte `div` 16), digits !! fromIntegral (byte `mod` 16)]
  digits = "0123456789abcdef"

launchFreshKindFamily :: Bootstrap.BootstrapProjection -> String -> IO KindFamilyLaunchOutcome
launchFreshKindFamily bootstrap operation = do
  prepared <- prepareFreshKindFamilyRequest bootstrap operation
  case prepared of
    Left failure -> pure (KindFamilyLaunchRefused failure)
    Right (request, cleanupEnd) -> launchKindFamily cleanupEnd bootstrap request

-- Configuration is generated from the validated bootstrap projection; other
-- fields in the selected file cannot enter the published controller inputs.
-- The original lease is held across the local record, publisher and send.
-- A fresh cleanup budget never extends the original work deadline.
launchKindFamily
  :: Word64 -> Bootstrap.BootstrapProjection -> Request.KindControllerRequest
  -> IO KindFamilyLaunchOutcome
launchKindFamily cleanupEnd bootstrap request = case Bootstrap.renderBootstrapProjection bootstrap of
  Nothing -> pure (KindFamilyLaunchRefused KindFamilyLaunchConfigurationRefused)
  Just source -> do
    valid <- (== Right (Just bootstrap)) <$> Bootstrap.decodeOptionalBootstrapSource "kind-family-settings.dhall" source
    if not valid then pure (KindFamilyLaunchRefused KindFamilyLaunchConfigurationRefused) else do
      prepared <- Kind.prepareKindFamilyController bootstrap request
      case prepared of
        Left failure -> pure (KindFamilyLaunchRefused (KindFamilyLaunchPreparationRefused failure))
        Right plan -> KindFamilyLaunchLease <$> Lease.withRecoveredKindOperation bootstrap operation (underLease (Text.encodeUtf8 source) plan)
 where
  operation = Request.kindRequestOperation request
  window = Request.kindRequestWindow request
  underLease configuration plan stable = do
    uid <- getEffectiveUserID
    let socket = "/run/user/" ++ show uid ++ "/bus"
    connected <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) socket $ \connection -> do
      domain <- Bus.observeManagerDomain connection
      if domain /= Request.kindRequestManagerDomain request
        then pure (Left KindFamilyLaunchManagerMismatch)
        else lift $ do
          legacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
          recorded <- if legacy == Receipt.RetainedControllerSubmissionMissing
            then Receipt.recordFamilyLaunch bootstrap request stable
            else pure Receipt.FamilyLaunchRefused
          resumable <- case recorded of
            Receipt.FamilyLaunchRecorded -> pure True
            Receipt.FamilyLaunchAlreadyExists -> do
              matching <- Receipt.matchesRetainedFamilyRequest bootstrap request stable
              marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
              cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
              final <- stable
              pure (matching && marker == Receipt.FamilyLaunchMissing && cancelled == Receipt.FamilyLaunchMissing && final)
            _ -> pure False
          if legacy /= Receipt.RetainedControllerSubmissionMissing
            then pure (Left KindFamilyLaunchLegacySubmissionUnconfirmed)
            else if not resumable
            then pure (Left (KindFamilyLaunchRecordRefused recorded))
            else do
              marker <- Receipt.recordFamilyPublicationAttempt bootstrap request stable
              if marker /= Receipt.FamilyLaunchRecorded then pure (Left (KindFamilyLaunchRecordRefused marker))
                else case Request.kindControllerOperationKey operation of
                  Nothing -> pure (Left KindFamilyLaunchInputMismatch)
                  Just key -> do
                    let admission = do
                          matching <- Receipt.matchesRetainedFamilyRequest bootstrap request stable
                          current <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                          cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
                          final <- stable
                          pure (matching && current == Receipt.FamilyLaunchObserved request && cancelled == Receipt.FamilyLaunchMissing && final)
                    publishBoundKindFamily Identity.KindController cleanupEnd configuration (Request.encodeKindControllerRequest request)
                      request key plan admission connection
    pure (either (Left . KindFamilyLaunchManagerRefused) id connected)

-- The held publication owner records whether a send may have occurred. Only
-- the never-sent branch can retire inputs here; possible-send recovery belongs
-- to the independently observed family retirement path.
publishBoundKindFamily
  :: Identity.HostControllerKind -> Word64 -> Bytes.ByteString -> Bytes.ByteString -> Request.KindControllerRequest
  -> Identity.HostExecutionKey -> Kind.KindFamilyPreparation -> IO Bool -> Bus.BusConnection
  -> IO (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing))
publishBoundKindFamily kind cleanupEnd configuration requestBytes request key plan stable connection =
  publishBoundKindFamilyWithMarker kind cleanupEnd configuration requestBytes request key plan stable (pure (Right ())) connection

-- The successor's marker is written only after the durable publication owner
-- exists, so an attempted send always has a recoverable publication birth.
publishBoundKindFamilyWithMarker
  :: Identity.HostControllerKind -> Word64 -> Bytes.ByteString -> Bytes.ByteString -> Request.KindControllerRequest
  -> Identity.HostExecutionKey -> Kind.KindFamilyPreparation -> IO Bool -> IO (Either KindFamilyLaunchError ()) -> Bus.BusConnection
  -> IO (Either KindFamilyLaunchError (Either KindFamilyLaunchError (), KindFamilyLaunchClosing))
publishBoundKindFamilyWithMarker kind cleanupEnd configuration requestBytes request key plan stable mark connection = do
  published <- Publication.withPublishedHostControllerOwner kind ending key configuration requestBytes
    (\owner -> do
      let (configPath, requestPath) = Publication.hostPublicationPaths owner
      marked <- mark
      held <- case marked of
        Left failure -> pure (Right (Left failure))
        Right () -> Family.withCurrentHostControllerProgram kind ending configPath requestPath $ \program -> do
          actualDigest <- Family.hashHostControllerProgramExecutable program
          inputs <- Family.readHostControllerProgramInputs program
          unchanged <- stable
          case (actualDigest, inputs) of
            (Left failure, _) -> pure (Left (KindFamilyLaunchProgramRefused failure))
            (_, Left failure) -> pure (Left (KindFamilyLaunchProgramRefused failure))
            (Right digest, Right bytes)
              | digest /= Request.kindRequestExecutableDigest request
                || Family.hostControllerConfigurationBytes bytes /= configuration
                || Family.hostControllerRequestBytes bytes /= requestBytes -> pure (Left KindFamilyLaunchInputMismatch)
              | not unchanged -> pure (Left KindFamilyLaunchLeaseChanged)
              | otherwise -> do
                  submitted <- Publication.withHostPublicationSubmission owner $ \permit ->
                    Family.submitPublishedHostOperationFamilyBoundToDomain permit (Request.kindRequestManagerDomain request)
                      stable connection (Kind.kindFamilyIntent plan) program
                  pure $ case submitted of
                    Left failure -> Left (KindFamilyLaunchPublicationRefused failure)
                    Right (Left failure) -> Left (KindFamilyLaunchProgramRefused failure)
                    Right (Right ()) -> Right ()
      pure (either (Left . KindFamilyLaunchProgramRefused) id held))
    (\disposition -> case disposition of
      Publication.PublicationPossiblySent -> pure KindFamilyLaunchPossiblySent
      Publication.PublicationNeverSent owner -> do
        retired <- InputRetirement.retireNeverSentHostControllerInputs cleanupEnd owner
        pure $ either KindFamilyLaunchUnsentUnconfirmed (const KindFamilyLaunchUnsentRetired) retired)
  pure (either (Left . KindFamilyLaunchPublicationRefused) Right published)
 where
  ending = Identity.hostExecutionWorkEnd (Request.kindRequestWindow request)

-- The original family must be physically retired while this request is
-- published and sent. The operation lease is released when submission returns
-- so the cleanup controller can acquire it. The outcome preserves the
-- possible-send disposition and does not claim cleanup-family retirement.
launchKindProbeRecovery
  :: Word64 -> Bootstrap.BootstrapProjection -> Request.ProbeRecoveryRequest
  -> IO KindProbeRecoveryLaunchOutcome
launchKindProbeRecovery cleanupEnd bootstrap recovery = case Bootstrap.renderBootstrapProjection bootstrap of
  Nothing -> pure (KindProbeRecoveryLaunchRefused KindFamilyLaunchConfigurationRefused)
  Just source -> do
    valid <- (== Right (Just bootstrap)) <$> Bootstrap.decodeOptionalBootstrapSource "kind-probe-recovery-settings.dhall" source
    if not valid then pure (KindProbeRecoveryLaunchRefused KindFamilyLaunchConfigurationRefused) else do
      prepared <- Kind.prepareKindProbeRecoveryController bootstrap recovery
      case prepared of
        Left failure -> pure (KindProbeRecoveryLaunchRefused (KindFamilyLaunchPreparationRefused failure))
        Right plan -> KindProbeRecoveryLaunchRetirement <$>
          Recovery.withKindFamilyRetirement cleanupEnd bootstrap operation (\owner ->
            Lease.withRecoveredKindOperation bootstrap operation (underLease owner (Text.encodeUtf8 source) plan))
 where
  request = Request.probeRecoveryControllerRequest recovery
  operation = Request.kindRequestOperation request
  window = Request.kindRequestWindow request
  namespace = "prodbox-netcheck-" ++ take 12 operation
  uid = Request.probeRecoveryNamespaceUid recovery
  underLease owner configuration plan stable = do
    let originalStable = (== Right ()) <$> Recovery.verifyKindFamilyRetirement owner stable
    before <- originalStable
    journal <- if before then Network.observeProbeJournal bootstrap operation namespace originalStable
      else pure Network.ProbeJournalConflict
    if journal /= Network.ProbeJournalRemovalMissing uid then pure (Left KindFamilyLaunchProbeStateUnconfirmed) else do
      recorded <- Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeRecoveryLaunch recovery) originalStable
      resumable <- case recorded of
        Probe.ProbeRecorded -> pure True
        Probe.ProbeAlreadyExists -> do
          retained <- Probe.observeProbeRecoveryLaunch bootstrap operation namespace originalStable
          marker <- Probe.observeProbePublicationAttempt bootstrap operation namespace originalStable
          current <- Network.observeProbeJournal bootstrap operation namespace originalStable
          unchanged <- originalStable
          pure (retained == Probe.ProbeRecoveryLaunchObserved recovery
            && marker == Probe.ProbePublicationMissing && current == Network.ProbeJournalRemovalMissing uid && unchanged)
        _ -> pure False
      if not resumable then pure (Left (KindFamilyLaunchProbeRecordRefused recorded)) else do
        let admission = do
              retired <- originalStable
              retained <- Probe.observeProbeRecoveryLaunch bootstrap operation namespace originalStable
              publication <- Probe.observeProbeRecord bootstrap operation namespace (Probe.ProbePublicationAttempt recovery) originalStable
              current <- Network.observeProbeJournal bootstrap operation namespace originalStable
              after <- originalStable
              pure (retired && retained == Probe.ProbeRecoveryLaunchObserved recovery
                && publication == Probe.ProbeMatches && current == Network.ProbeJournalRemovalMissing uid && after)
        case Request.kindProbeRecoveryKey operation (Request.probeRecoveryId recovery) of
          Nothing -> pure (Left KindFamilyLaunchInputMismatch)
          Just key -> do
            operator <- getEffectiveUserID
            let socket = "/run/user/" ++ show operator ++ "/bus"
            connected <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) socket $ \connection -> do
              domain <- Bus.observeManagerDomain connection
              if domain /= Request.kindRequestManagerDomain request then pure (Left KindFamilyLaunchManagerMismatch)
                else lift $ do
                  marker <- Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbePublicationAttempt recovery) originalStable
                  if marker /= Probe.ProbeRecorded then pure (Left (KindFamilyLaunchProbeRecordRefused marker))
                    else publishBoundKindFamily Identity.KindController cleanupEnd configuration (Request.encodeProbeRecoveryRequest recovery)
                      request key plan admission connection
            pure (either (Left . KindFamilyLaunchManagerRefused) id connected)

-- Both predecessor families remain retired through publication and submission.
-- The verifier must independently reacquire those owners after handoff.
launchKindProbeVerifier
  :: Word64 -> Bootstrap.BootstrapProjection -> Request.ProbeAttemptVerifierRequest
  -> IO KindProbeVerifierLaunchOutcome
launchKindProbeVerifier cleanupEnd bootstrap verifier = case Bootstrap.renderBootstrapProjection bootstrap of
  Nothing -> pure (KindProbeVerifierLaunchRefused KindFamilyLaunchConfigurationRefused)
  Just source -> do
    valid <- (== Right (Just bootstrap)) <$> Bootstrap.decodeOptionalBootstrapSource "kind-probe-verifier-settings.dhall" source
    if not valid then pure (KindProbeVerifierLaunchRefused KindFamilyLaunchConfigurationRefused) else do
      prepared <- Kind.prepareKindProbeVerifierController bootstrap verifier
      case prepared of
        Left failure -> pure (KindProbeVerifierLaunchRefused (KindFamilyLaunchPreparationRefused failure))
        Right plan -> KindProbeVerifierLaunchRetirement <$>
          Recovery.withKindFamilyRetirement cleanupEnd bootstrap operation (\originalOwner ->
            Recovery.withKindProbeFamilyRetirement cleanupEnd bootstrap operation (\priorOwner ->
              Lease.withRecoveredKindOperation bootstrap operation (underLease originalOwner priorOwner (Text.encodeUtf8 source) plan)))
 where
  recovery = Request.probeVerifierRecoveryRequest verifier
  request = Request.probeRecoveryControllerRequest recovery
  operation = Request.kindRequestOperation request
  window = Request.kindRequestWindow request
  namespace = "prodbox-netcheck-" ++ take 12 operation
  uid = Request.probeRecoveryNamespaceUid recovery
  prior = Request.probeVerifierPriorId verifier
  verifierId = Request.probeRecoveryId recovery
  underLease originalOwner priorOwner configuration plan stable = do
    let ownersStable = do
          original <- Recovery.verifyKindFamilyRetirement originalOwner stable
          previous <- Recovery.verifyKindProbeFamilyRetirement priorOwner stable
          pure (original == Right () && previous == Right ())
    before <- ownersStable
    journal <- if before then Network.observeProbeJournal bootstrap operation namespace ownersStable
      else pure Network.ProbeJournalConflict
    recorded <- case journal of
      Network.ProbeJournalRemovalMissing currentUid
        | Request.probeVerifierIsIsolated verifier && currentUid == uid ->
            Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeVerifierLaunch verifier) ownersStable
      Network.ProbeJournalRemovalAttempted currentUid currentPrior
        | currentUid == uid && currentPrior == prior ->
            Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeVerifierLaunch verifier) ownersStable
      Network.ProbeJournalVerifierPending currentUid currentPrior currentVerifier False
        | currentUid == uid && currentPrior == prior && currentVerifier == verifierId -> do
            retained <- Probe.observeProbeVerifierLaunch bootstrap operation namespace ownersStable
            marker <- Probe.observeProbeVerifierPublicationAttempt bootstrap operation namespace ownersStable
            unchanged <- ownersStable
            pure $ if retained == Probe.ProbeVerifierLaunchObserved verifier && marker == Probe.ProbeVerifierLaunchMissing && unchanged
              then Probe.ProbeRecorded else Probe.ProbeRefused
      _ -> pure Probe.ProbeRefused
    if recorded /= Probe.ProbeRecorded then pure (Left (KindFamilyLaunchProbeRecordRefused recorded)) else do
        let admission = do
              retired <- ownersStable
              retained <- Probe.observeProbeVerifierLaunch bootstrap operation namespace ownersStable
              publication <- Probe.observeProbeRecord bootstrap operation namespace (Probe.ProbeVerifierPublicationAttempt verifier) ownersStable
              current <- Network.observeProbeJournal bootstrap operation namespace ownersStable
              after <- ownersStable
              pure (retired && retained == Probe.ProbeVerifierLaunchObserved verifier
                && publication == Probe.ProbeMatches
                && current == Network.ProbeJournalVerifierPending uid prior verifierId True && after)
        case Request.kindProbeRecoveryKey operation verifierId of
          Nothing -> pure (Left KindFamilyLaunchInputMismatch)
          Just key -> do
            operator <- getEffectiveUserID
            let socket = "/run/user/" ++ show operator ++ "/bus"
            connected <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) socket $ \connection -> do
              domain <- Bus.observeManagerDomain connection
              if domain /= Request.kindRequestManagerDomain request then pure (Left KindFamilyLaunchManagerMismatch)
                else lift $ do
                  marker <- Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeVerifierPublicationAttempt verifier) ownersStable
                  if marker /= Probe.ProbeRecorded then pure (Left (KindFamilyLaunchProbeRecordRefused marker))
                    else publishBoundKindFamily (if Request.probeVerifierIsIsolated verifier then Identity.KindProbeVerifierController else Identity.KindController) cleanupEnd configuration (Request.encodeProbeAttemptVerifierRequest verifier)
                      request key plan admission connection
            pure (either (Left . KindFamilyLaunchManagerRefused) id connected)

-- A successor is a separate read-only observer. All recorded predecessors are
-- independently retired throughout publication; a partial send stays recorded.
launchKindProbeSuccessor
  :: Word64 -> Bootstrap.BootstrapProjection -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest] -> Request.ProbeSuccessorRequest
  -> IO KindProbeSuccessorLaunchOutcome
launchKindProbeSuccessor cleanupEnd bootstrap first predecessors successor = case Bootstrap.renderBootstrapProjection bootstrap of
  Nothing -> pure (KindProbeSuccessorLaunchRefused KindFamilyLaunchConfigurationRefused)
  Just source -> do
    valid <- (== Right (Just bootstrap)) <$> Bootstrap.decodeOptionalBootstrapSource "kind-probe-successor-settings.dhall" source
    if not valid || not (Request.validProbeSuccessorChain first (predecessors ++ [successor]))
      then pure (KindProbeSuccessorLaunchRefused KindFamilyLaunchConfigurationRefused)
      else do
        prepared <- Kind.prepareKindProbeSuccessorController bootstrap successor
        case prepared of
          Left failure -> pure (KindProbeSuccessorLaunchRefused (KindFamilyLaunchPreparationRefused failure))
          Right plan -> KindProbeSuccessorLaunchRetirement <$>
            Recovery.withKindFamilyRetirement cleanupEnd bootstrap operation (\originalOwner ->
              Recovery.withKindProbeFamilyRetirement cleanupEnd bootstrap operation (\priorOwner ->
                Recovery.withKindProbeVerifierRetirement cleanupEnd bootstrap operation (\firstOwner -> do
                  let admission = do
                        original <- Recovery.verifyKindFamilyRetirement originalOwner (pure True)
                        priorRetired <- Recovery.verifyKindProbeFamilyRetirement priorOwner (pure True)
                        initial <- Recovery.verifyKindProbeVerifierRetirement firstOwner (pure True)
                        pure (original == Right () && priorRetired == Right () && initial == Right ())
                  state <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
                    let admitted = (&&) <$> stable <*> admission
                    root <- Probe.observeProbeVerifierLaunch bootstrap operation namespace admitted
                    marker <- Probe.observeProbeVerifierPublicationAttempt bootstrap operation namespace admitted
                    launch <- Probe.observeProbeSuccessorLaunch bootstrap operation namespace predecessor admitted
                    publication <- Probe.observeProbeSuccessorPublication bootstrap operation namespace successorId admitted
                    chain <- Probe.observeProbeSuccessorChain bootstrap operation namespace first admitted
                    closing <- admitted
                    pure (root, marker, launch, publication, chain, closing)
                  let action owners = Lease.withRecoveredKindOperation bootstrap operation (underLease admission owners (Text.encodeUtf8 source) plan)
                  case state of
                    Lease.KindOperationCallbackReturned (Probe.ProbeVerifierLaunchObserved root, Probe.ProbeVerifierLaunchObserved rootMarker,
                        Probe.ProbeSuccessorMissing, Probe.ProbeSuccessorMissing, Right current, True)
                      | root == first && rootMarker == first && current == predecessors ->
                          Recovery.withKindProbeSuccessorRetirementTransition cleanupEnd bootstrap operation first predecessors successor admission action
                    Lease.KindOperationCallbackReturned (Probe.ProbeVerifierLaunchObserved root, Probe.ProbeVerifierLaunchObserved rootMarker,
                        Probe.ProbeSuccessorObserved retained, Probe.ProbeSuccessorMissing, Left Probe.ProbeSuccessorMissing, True)
                      | root == first && rootMarker == first && retained == successor ->
                          Recovery.withKindProbeSuccessorRetirementStaged cleanupEnd bootstrap operation first predecessors successor admission action
                    _ -> pure Recovery.KindProbeSuccessorChainUnconfirmed)))
 where
  verifier = Request.probeSuccessorVerifier successor
  coordinates = Request.probeVerifierRecoveryRequest verifier
  request = Request.probeRecoveryControllerRequest coordinates
  operation = Request.kindRequestOperation request
  window = Request.kindRequestWindow request
  namespace = "prodbox-netcheck-" ++ take 12 operation
  predecessor = Request.probeSuccessorPredecessorId successor
  successorId = Request.probeRecoveryId coordinates
  uid = Request.probeRecoveryNamespaceUid coordinates
  prior = Request.probeVerifierPriorId verifier
  firstId = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest first)
  underLease predecessorsStable owners configuration plan stable = do
    let base = (&&) <$> stable <*> predecessorsStable
    existing <- Probe.observeProbeSuccessorLaunch bootstrap operation namespace predecessor base
    marker <- Probe.observeProbeSuccessorPublication bootstrap operation namespace successorId base
    recorded <- case (existing, marker) of
      (Probe.ProbeSuccessorMissing, Probe.ProbeSuccessorMissing) ->
        Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeSuccessorLaunch successor) base
      (Probe.ProbeSuccessorObserved retained, Probe.ProbeSuccessorMissing) | retained == successor -> pure Probe.ProbeRecorded
      _ -> pure Probe.ProbeRefused
    if recorded /= Probe.ProbeRecorded then pure (Left (KindFamilyLaunchProbeRecordRefused recorded)) else do
      let admission = do
            held <- Recovery.verifyKindProbeSuccessorRetirementPrefix bootstrap operation first predecessors successor owners base
            current <- Network.observeProbeJournal bootstrap operation namespace (pure True)
            readbacks <- mapM (\entry -> Probe.observeProbeRecord bootstrap operation namespace (Probe.ProbeSuccessorReadback entry) (pure True)) (predecessors ++ [successor])
            after <- base
            pure (held && current == Network.ProbeJournalVerifierPending uid prior firstId True
              && all (== Probe.ProbeMissing) readbacks && after)
      case Request.kindProbeRecoveryKey operation successorId of
        Nothing -> pure (Left KindFamilyLaunchInputMismatch)
        Just key -> do
          operator <- getEffectiveUserID
          let socket = "/run/user/" ++ show operator ++ "/bus"
          connected <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) socket $ \connection -> do
            domain <- Bus.observeManagerDomain connection
            if domain /= Request.kindRequestManagerDomain request then pure (Left KindFamilyLaunchManagerMismatch)
              else lift $ do
                let mark = do
                      published <- Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeSuccessorPublication successor) base
                      pure (if published == Probe.ProbeRecorded then Right () else Left (KindFamilyLaunchProbeRecordRefused published))
                publishBoundKindFamilyWithMarker Identity.KindProbeSuccessorController cleanupEnd configuration (Request.encodeProbeSuccessorRequest successor)
                  request key plan admission mark connection
          pure (either (Left . KindFamilyLaunchManagerRefused) id connected)

-- The marker and cancellation are exclusive under the recovered operation
-- lease. A cancelled locator remains in the chain as a no-send predecessor.
cancelKindProbeSuccessorBeforePublication
  :: Word64 -> Bootstrap.BootstrapProjection -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest] -> Request.ProbeSuccessorRequest
  -> IO KindProbeSuccessorCancellationOutcome
cancelKindProbeSuccessorBeforePublication ending bootstrap first predecessors successor
  | not (Request.validProbeSuccessorChain first (predecessors ++ [successor])) = pure KindProbeSuccessorCancellationRefused
  | otherwise = KindProbeSuccessorCancellationRetirement <$>
      Recovery.withKindFamilyRetirement ending bootstrap operation (\originalOwner ->
        Recovery.withKindProbeFamilyRetirement ending bootstrap operation (\priorOwner ->
          Recovery.withKindProbeVerifierRetirement ending bootstrap operation (\firstOwner -> do
            let admission = do
                  original <- Recovery.verifyKindFamilyRetirement originalOwner (pure True)
                  priorRetired <- Recovery.verifyKindProbeFamilyRetirement priorOwner (pure True)
                  initial <- Recovery.verifyKindProbeVerifierRetirement firstOwner (pure True)
                  pure (original == Right () && priorRetired == Right () && initial == Right ())
            Recovery.withKindProbeSuccessorRetirementStaged ending bootstrap operation first predecessors successor admission $ \_ ->
              Lease.withRecoveredKindOperation bootstrap operation $ \stable ->
                Probe.recordProbeRecord bootstrap operation namespace (Probe.ProbeSuccessorCancellation successor) ((&&) <$> stable <*> admission))))
 where
  operation = Request.kindRequestOperation (Request.probeRecoveryControllerRequest (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor)))
  namespace = "prodbox-netcheck-" ++ take 12 operation
