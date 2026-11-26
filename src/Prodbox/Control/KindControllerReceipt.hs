{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A non-authorizing, scope-bound record of one returned kind worker.
module Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptWrite (..)
  , FamilyPrimary (..)
  , FamilyWorkerClosing (..)
  , FamilyParentClosing (..)
  , FamilyInputClosing (..)
  , FamilyPostDisposition (..)
  , FamilyPostClosing (..)
  , FamilyResult (..)
  , FamilyResultWrite (..)
  , FamilyResultObservation (..)
  , recordFamilyResult
  , recordFamilyResultUntil
  , observeFamilyResult
  , observeFamilyResultStatus
  , FamilyLaunchWrite (..)
  , FamilyLaunchObservation (..)
  , recordFamilyLaunch
  , observeFamilyLaunch
  , recordFamilyPublicationAttempt
  , observeFamilyPublicationAttempt
  , recordFamilyPrePublicationCancellation
  , observeFamilyPrePublicationCancellation
  , matchesRetainedFamilyRequest
  , ControllerReceiptObservation (..)
  , recordControllerReceipt
  , observeControllerReceipt
  , controllerReceiptNode
  , ControllerSubmissionWrite (..)
  , ControllerSubmissionObservation (..)
  , recordControllerSubmissionIntent
  , observeControllerSubmissionIntent
  , RetainedControllerSubmission (..)
  , observeRetainedControllerSubmission
  , observeControllerSubmissionStatus
  , withControllerSubmissionIntent
  , ControllerJobWrite (..)
  , ControllerJobObservation (..)
  , recordControllerJob
  , observeControllerJob
  , RetainedControllerJob (..)
  , observeRetainedControllerJob
  , Identity.HostManagerDomain
  , Identity.hostManagerDomain
  , Identity.hostManagerBootId
  , Identity.hostManagerBusId
  , Identity.hostManagerUniqueName
  , Identity.hostManagerUserId
  , Identity.hostManagerProcessId
  , Identity.hostManagerStartTicks
  , Identity.HostBusUniqueName
  , Identity.hostBusUniqueName
  , Identity.HostExecutionWindow
  , Identity.hostExecutionWindow
  , ControllerDomainWrite (..)
  , ControllerDomainObservation (..)
  , recordControllerDomain
  , observeControllerDomain
  , RetainedControllerDomain (..)
  , observeRetainedControllerDomain
  , ControllerProviderWrite (..)
  , RetainedControllerProvider (..)
  , recordControllerProvider
  , observeRetainedControllerProvider
  , Provider.RecordedProviderBinding
  , Provider.decodeProviderBinding
  , ControllerProviderMaterialWrite (..)
  , RetainedControllerProviderMaterial (..)
  , recordControllerProviderMaterial
  , observeControllerProviderMaterial
  , ControllerSenderWrite (..)
  , RetainedControllerSender (..)
  , recordControllerSender
  , observeRetainedControllerSender
  , ControllerFreshProvider (..)
  , compareControllerProviderBinding
  , ControllerSenderPresence (..)
  , ControllerFreshSender (..)
  , ControllerUnitRead (..)
  , ControllerManagerRead (..)
  , observeControllerManagerRead
  , withControllerRecoverySettlement
  , controllerUnitName
  , observeControllerFreshSender
  , observeControllerFreshProvider
  , withCurrentControllerProvider
  , controllerProviderDigest
  ) where

import Control.Exception (IOException, bracket, mask, try)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (stripPrefix)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32, Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeEnvironment
  , scopeIdentifier
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindIntent
  ( KindIntentObservation (..)
  , observeKindFamilyIntent
  , observeKindIntent
  )
import Prodbox.Control.KindKubeconfigYaml (KindKubeconfigDecodeError, decodeBoundedYamlValue)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (KindOperationCallbackReturned)
  , withRecoveredKindOperation
  , withRecoveredKindOperationUntil
  )
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd, UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data ControllerSubmissionWrite
  = ControllerSubmissionRecorded
  | ControllerSubmissionAlreadyExists
  | ControllerSubmissionRefused
  | ControllerSubmissionIncomplete
  deriving (Eq, Show)

data ControllerSubmissionObservation
  = ControllerSubmissionMissing
  | ControllerSubmissionMatches
  | ControllerSubmissionConflict
  | ControllerSubmissionUnobservable
  deriving (Eq, Show)

data RetainedControllerSubmission
  = RetainedControllerSubmissionMissing
  | RetainedControllerSubmissionObserved !String
  | RetainedControllerSubmissionConflict
  | RetainedControllerSubmissionUnobservable
  deriving (Eq, Show)

data ControllerJobWrite
  = ControllerJobRecorded
  | ControllerJobAlreadyExists
  | ControllerJobRefused
  | ControllerJobIncomplete
  deriving (Eq, Show)

data ControllerJobObservation
  = ControllerJobMissing
  | ControllerJobMatches
  | ControllerJobConflict
  | ControllerJobUnobservable
  deriving (Eq, Show)

data RetainedControllerJob
  = RetainedControllerJobMissing
  | RetainedControllerJobObserved !String
  | RetainedControllerJobConflict
  | RetainedControllerJobUnobservable
  deriving (Eq, Show)

data ControllerDomainWrite
  = ControllerDomainRecorded
  | ControllerDomainAlreadyExists
  | ControllerDomainRefused
  | ControllerDomainIncomplete
  deriving (Eq, Show)

data ControllerDomainObservation
  = ControllerDomainMissing
  | ControllerDomainMatches
  | ControllerDomainConflict
  | ControllerDomainUnobservable
  deriving (Eq, Show)

data RetainedControllerDomain
  = RetainedControllerDomainMissing
  | RetainedControllerDomainObserved !Identity.HostManagerDomain !Identity.HostExecutionWindow
  | RetainedControllerDomainConflict
  | RetainedControllerDomainUnobservable
  deriving (Eq, Show)

data ControllerProviderWrite
  = ControllerProviderRecorded
  | ControllerProviderAlreadyExists
  | ControllerProviderRefused
  | ControllerProviderIncomplete
  deriving (Eq, Show)

data RetainedControllerProvider
  = RetainedControllerProviderMissing
  | RetainedControllerProviderObserved !String
  | RetainedControllerProviderConflict
  | RetainedControllerProviderUnobservable
  deriving (Eq, Show)

data ControllerProviderMaterialWrite
  = ControllerProviderMaterialRecorded
  | ControllerProviderMaterialAlreadyExists
  | ControllerProviderMaterialRefused
  | ControllerProviderMaterialIncomplete
  deriving (Eq, Show)

data RetainedControllerProviderMaterial
  = RetainedControllerProviderMaterialMissing
  | RetainedControllerProviderMaterialObserved !Provider.RecordedProviderBinding
  | RetainedControllerProviderMaterialConflict
  | RetainedControllerProviderMaterialUnobservable
  deriving (Eq)

instance Show RetainedControllerProviderMaterial where
  show value = case value of
    RetainedControllerProviderMaterialMissing -> "RetainedControllerProviderMaterialMissing"
    RetainedControllerProviderMaterialObserved _ -> "RetainedControllerProviderMaterialObserved"
    RetainedControllerProviderMaterialConflict -> "RetainedControllerProviderMaterialConflict"
    RetainedControllerProviderMaterialUnobservable -> "RetainedControllerProviderMaterialUnobservable"

data ControllerFreshProvider
  = ControllerFreshProviderMatches
  | ControllerFreshProviderDifferent
  | ControllerFreshProviderDifferentDomain
  | ControllerFreshProviderRecordUnavailable
  | ControllerFreshProviderUnobservable
  deriving (Eq, Show)

-- This comparison is data only. Qualification, lease and retirement remain
-- independent, and callers must not treat a match as permission for an effect.
compareControllerProviderBinding
  :: Identity.HostManagerDomain
  -> Provider.RecordedProviderBinding
  -> Identity.HostManagerDomain
  -> Provider.RecordedProviderBinding
  -> Bool
compareControllerProviderBinding recordedDomain recordedBinding currentDomain currentBinding =
  recordedDomain == currentDomain && recordedBinding == currentBinding

data ControllerSenderWrite
  = ControllerSenderRecorded
  | ControllerSenderAlreadyExists
  | ControllerSenderRefused
  | ControllerSenderIncomplete
  deriving (Eq, Show)

data RetainedControllerSender
  = RetainedControllerSenderMissing
  | RetainedControllerSenderObserved !Identity.HostBusUniqueName
  | RetainedControllerSenderConflict
  | RetainedControllerSenderUnobservable
  deriving (Eq, Show)

data ControllerSenderPresence
  = ControllerSenderPresent
  | ControllerSenderAbsent
  | ControllerSenderPresenceUnobservable
  deriving (Eq, Show)

data ControllerFreshSender
  = ControllerFreshSenderPresent
  | ControllerFreshSenderAbsent
  | ControllerFreshSenderDifferentDomain
  | ControllerFreshSenderRecordUnavailable
  | ControllerFreshSenderUnobservable
  deriving (Eq, Show)

data ControllerUnitRead = ControllerUnitPresent | ControllerUnitAbsent | ControllerUnitUnobservable
  deriving (Eq, Show)

data ControllerManagerRead
  = ControllerManagerSenderPresent
  | ControllerManagerUnitPresent
  | ControllerManagerUnitAbsent
  | ControllerManagerDifferentDomain
  | ControllerManagerRecordUnavailable
  | ControllerManagerReadUnobservable
  deriving (Eq, Show)

controllerUnitName :: String
controllerUnitName = "prodbox-kind-controller.service"

-- Bounded, non-secret summary. Resource-specific journals remain the source
-- for detailed create/start and cleanup observations; this is not retirement.
data FamilyPrimary
  = FamilyPreparationRefused
  | FamilyParentRefused
  | FamilyWorkerNotObserved
  | FamilyWorkerUnconfirmed
  | FamilyWorkerConfirmed
  deriving (Eq, Read, Show)

data FamilyWorkerClosing
  = FamilyWorkerNotStarted
  | FamilyWorkerUnobserved
  | FamilyWorkerComplete
  | FamilyWorkerIoUnconfirmed
  | FamilyWorkerDescriptorRefused
  deriving (Eq, Read, Show)

data FamilyParentClosing
  = FamilyParentNotStarted
  | FamilyParentComplete
  | FamilyParentUnconfirmed
  | FamilyParentKernelUnconfirmed
  | FamilyParentProviderUnconfirmed
  | FamilyParentProgramUnconfirmed
  deriving (Eq, Read, Show)

data FamilyInputClosing
  = FamilyInputComplete
  | FamilyInputUnconfirmed
  | FamilyInputExpired
  | FamilyInputChanged
  | FamilyInputIoUnconfirmed
  deriving (Eq, Read, Show)

data FamilyPostDisposition
  = FamilyPostNotAttempted
  | FamilyPostPreconditionFailed
  | FamilyPostInstallFailed
  | FamilyPostImageAttemptFailed
  | FamilyPostImageObservationFailed
  | FamilyPostImageResultUnconfirmed
  | FamilyPostImageReadbackUnconfirmed
  | FamilyPostImageTransportUnconfirmed
  | FamilyPostImageClosingUnconfirmed
  | FamilyPostNetworkFailed
  | FamilyPostVolumeFailed
  | FamilyPostNodeIntentFailed
  | FamilyPostReceiptFailed
  | FamilyPostReceiptComplete
  | FamilyPostProbeFailed
  | FamilyPostProbeComplete
  | FamilyPostProbeSnapshotRefused
  | FamilyPostProbeIntentRefused
  | FamilyPostProbeBindingRefused
  deriving (Eq, Read, Show)

data FamilyPostClosing = FamilyPostNotStarted | FamilyPostLeaseComplete | FamilyPostLeaseUnconfirmed
  deriving (Eq, Read, Show)

data FamilyResult
  = FamilyResult
      !FamilyPrimary
      !FamilyWorkerClosing
      !FamilyParentClosing
      !FamilyInputClosing
      !FamilyPostDisposition
      !FamilyPostClosing
  deriving (Eq, Show)

data FamilyResultWrite
  = FamilyResultRecorded
  | FamilyResultAlreadyExists
  | FamilyResultRefused
  | FamilyResultIncomplete
  deriving (Eq, Show)

data FamilyResultObservation
  = FamilyResultMissing
  | FamilyResultObserved !String !FamilyResult
  | FamilyResultConflict
  | FamilyResultUnobservable
  deriving (Eq, Show)

data FamilyLaunchWrite
  = FamilyLaunchRecorded
  | FamilyLaunchAlreadyExists
  | FamilyLaunchRefused
  | FamilyLaunchIncomplete
  deriving (Eq, Show)

data FamilyLaunchObservation
  = FamilyLaunchMissing
  | FamilyLaunchObserved !Request.KindControllerRequest
  | FamilyLaunchConflict
  | FamilyLaunchUnobservable
  deriving (Eq, Show)

data ControllerReceiptWrite
  = ControllerReceiptRecorded
  | ControllerReceiptAlreadyExists
  | ControllerReceiptRefused
  | ControllerReceiptIncomplete
  deriving (Eq, Show)

data ControllerReceiptObservation
  = ControllerReceiptMissing
  | ControllerReceiptObserved !String
  | ControllerReceiptInvalid
  | ControllerReceiptConflict
  | ControllerReceiptUnobservable
  deriving (Eq, Show)

controllerReceiptNode :: KindOperationOutcome ControllerReceiptObservation -> Maybe String
controllerReceiptNode outcome = case outcome of
  KindOperationCallbackReturned (ControllerReceiptObserved identifier)
    | validImageId ("sha256:" ++ identifier) -> Just identifier
  _ -> Nothing

submissionName :: FilePath
submissionName = "kind-controller-submission-intent.json"

submissionValue :: BootstrapProjection -> String -> String -> Files.FileStatus -> Aeson.Value
submissionValue bootstrap operation requestDigest root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-submission-intent" :: String)
    , "deployment_id" Aeson..= scopeIdentifier (bootstrapScope bootstrap)
    , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
    , "operation_id" Aeson..= operation
    , "unit" Aeson..= controllerUnitName
    , "request_sha256" Aeson..= requestDigest
    , "root_device" Aeson..= toInteger (Files.deviceID root)
    , "root_inode" Aeson..= toInteger (Files.fileID root)
    ]

-- Durable local write-ahead identity. It is not proof of submission, manager
-- identity, job completion or worker retirement. Existing records never admit
-- a second submission, even when they match.
recordControllerSubmissionIntent
  :: BootstrapProjection -> String -> String -> IO Bool -> IO ControllerSubmissionWrite
recordControllerSubmissionIntent bootstrap operation requestDigest stable
  | not (validInput bootstrap operation) || not (validImageId ("sha256:" ++ requestDigest)) =
      pure ControllerSubmissionRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          protocol <- observeKindFamilyIntent bootstrap
          family <- observeFamilyLaunch bootstrap operation operationStable
          rootStatus <- Files.getFdStatus root
          if not admitted || protocol /= KindIntentConflict || family /= FamilyLaunchMissing
            then pure ControllerSubmissionRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) submissionName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerSubmissionAlreadyExists
                Left (_ :: IOException) -> pure ControllerSubmissionRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      ( LazyByteString.toStrict
                          (Aeson.encode (submissionValue bootstrap operation requestDigest rootStatus))
                      )
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerSubmissionIncomplete
                    Right () -> do
                      observed <-
                        restore (observeControllerSubmissionIntent bootstrap operation requestDigest operationStable)
                      pure
                        ( if observed == ControllerSubmissionMatches
                            then ControllerSubmissionRecorded
                            else ControllerSubmissionIncomplete
                        )
        pure
          ( either
              (const ControllerSubmissionRefused)
              id
              (attempted :: Either IOException ControllerSubmissionWrite)
          )
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerSubmissionRefused -> outcome
        _ | changed -> ControllerSubmissionIncomplete
        _ -> ControllerSubmissionRefused

-- A single admitted action may follow only a newly recorded intent and a
-- current operation recheck. The caller holds the matching lease and must
-- preserve any unconfirmed external outcome for recovery.
withControllerSubmissionIntent
  :: BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> IO a
  -> IO (Either ControllerSubmissionWrite a)
withControllerSubmissionIntent bootstrap operation requestDigest stable action = do
  recorded <- recordControllerSubmissionIntent bootstrap operation requestDigest stable
  case recorded of
    ControllerSubmissionRecorded -> do
      before <- stable
      current <- observeKindIntent bootstrap
      after <- stable
      if before && current == KindIntentMatches operation && after
        then Right <$> action
        else pure (Left ControllerSubmissionIncomplete)
    other -> pure (Left other)

observeControllerSubmissionIntent
  :: BootstrapProjection -> String -> String -> IO Bool -> IO ControllerSubmissionObservation
observeControllerSubmissionIntent bootstrap operation requestDigest stable
  | not (validImageId ("sha256:" ++ requestDigest)) = pure ControllerSubmissionUnobservable
  | otherwise = do
      retained <- observeRetainedControllerSubmission bootstrap operation stable
      pure $ case retained of
        RetainedControllerSubmissionMissing -> ControllerSubmissionMissing
        RetainedControllerSubmissionObserved digest
          | digest == requestDigest -> ControllerSubmissionMatches
          | otherwise -> ControllerSubmissionConflict
        RetainedControllerSubmissionConflict -> ControllerSubmissionConflict
        RetainedControllerSubmissionUnobservable -> ControllerSubmissionUnobservable

-- Read the retained digest itself instead of reconstructing it using the
-- currently installed binary. This is local evidence, not authenticated
-- history or proof that a manager received or settled the request.
observeRetainedControllerSubmission
  :: BootstrapProjection -> String -> IO Bool -> IO RetainedControllerSubmission
observeRetainedControllerSubmission bootstrap operation stable
  | not (validInput bootstrap operation) = pure RetainedControllerSubmissionUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure RetainedControllerSubmissionUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) submissionName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure
                    (if still then RetainedControllerSubmissionMissing else RetainedControllerSubmissionUnobservable)
                Left (_ :: IOException) -> pure RetainedControllerSubmissionUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure RetainedControllerSubmissionUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) submissionName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      pure $
                        if not (still && sameVersion before after && sameVersion after named)
                          then RetainedControllerSubmissionUnobservable
                          else case (Aeson.eitherDecodeStrict' bytes, checked) of
                            (Right value, Right checkedValue) | value == checkedValue ->
                              case parseEither (Aeson.withObject "controller submission" (.: "request_sha256")) value of
                                Right digest
                                  | validImageId ("sha256:" ++ digest) && value == submissionValue bootstrap operation digest rootStatus ->
                                      RetainedControllerSubmissionObserved digest
                                _ -> RetainedControllerSubmissionConflict
                            _ -> RetainedControllerSubmissionConflict
        pure
          ( either
              (const RetainedControllerSubmissionUnobservable)
              id
              (attempted :: Either IOException RetainedControllerSubmission)
          )
      pure $ case result of Just (Right observed) -> observed; _ -> RetainedControllerSubmissionUnobservable

-- Status does not authorize a retry, deletion, or inference that an older
-- implementation never submitted a worker.
observeControllerSubmissionStatus :: BootstrapProjection -> IO String
observeControllerSubmissionStatus bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      result <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        submission <- observeRetainedControllerSubmission bootstrap operation stable
        (domain, provider, material, sender, job) <- case submission of
          RetainedControllerSubmissionObserved digest -> do
            domain <- observeRetainedControllerDomain bootstrap operation digest stable
            provider <- observeRetainedControllerProvider bootstrap operation digest stable
            material <- observeControllerProviderMaterial bootstrap operation digest stable
            sender <- observeRetainedControllerSender bootstrap operation digest stable
            job <- observeRetainedControllerJob bootstrap operation digest stable
            pure (Just domain, Just provider, Just material, Just sender, Just job)
          _ -> pure (Nothing, Nothing, Nothing, Nothing, Nothing)
        pure (submission, domain, provider, material, sender, job)
      pure $
        "Kind controller submission " ++ operation ++ ": " ++ case result of
          KindOperationCallbackReturned (submission, domain, provider, material, sender, job) ->
            show submission
              ++ "; manager domain record "
              ++ show domain
              ++ "; provider binding record "
              ++ show provider
              ++ "; provider material "
              ++ show material
              ++ "; sender record "
              ++ show sender
              ++ "; returned job record "
              ++ show job
              ++ "; local records only; manager state and worker settlement not observed.\n"
          _ -> "operation lease or records unconfirmed; manager state and worker settlement not observed.\n"
    _ ->
      pure
        "Kind controller submission: operation identity unavailable; manager state and worker settlement not observed.\n"

-- Read-only provider acquisition for a bounded local observation. The
-- callback receives recorded identity data and a live verification action;
-- neither is permission to submit, delete, or infer worker retirement.
withCurrentControllerProvider
  :: ( Identity.HostManagerDomain
       -> Provider.RecordedProviderBinding
       -> Identity.HostBusUniqueName
       -> (Identity.HostBusUniqueName -> IO ControllerSenderPresence)
       -> IO ControllerUnitRead
       -> IO Bool
       -> IO a
     )
  -> IO (Either String a)
withCurrentControllerProvider action = do
  owner <- getEffectiveUserID
  now <- getMonotonicTimeNSec
  outcome <- Bus.withSystemdBus (now + 5000000000) ("/run/user/" ++ show owner ++ "/bus") $ \connection -> lift $ do
    sender <- runExceptT (Bus.observeBusSender connection)
    case sender of
      Left failure -> pure (Left (show failure))
      Right name -> do
        result <- Provider.withQualifiedProvider connection $ \provider ->
          action
            (Provider.qualifiedProviderDomain provider)
            (Provider.qualifiedProviderBinding provider)
            name
            ( \target -> do
                observed <- runExceptT (Bus.observeBusNamePresence connection target)
                pure $ case observed of
                  Right Bus.BusNamePresent -> ControllerSenderPresent
                  Right Bus.BusNameAbsent -> ControllerSenderAbsent
                  _ -> ControllerSenderPresenceUnobservable
            )
            (readControllerUnit connection)
            ((== Right ()) <$> Provider.verifyQualifiedProvider provider)
        pure (either (Left . show) Right result)
  pure (either (Left . show) id outcome)

-- The manager's exact unit lookup is only a point observation. The Id
-- property is checked for a present result; errors are never absence.
readControllerUnit :: Bus.BusConnection -> IO ControllerUnitRead
readControllerUnit connection = do
  result <-
    runExceptT
      ( Bus.callManager
          connection
          Bus.GetUnit
          (\message -> Bus.appendString message controllerUnitName)
          (`Bus.readString` 'o')
      )
  case result of
    Left (Bus.BusMethodRefused 2) -> pure ControllerUnitAbsent
    Left _ -> pure ControllerUnitUnobservable
    Right path -> do
      identity <-
        runExceptT $
          Bus.callManager
            connection
            (Bus.ReadUnitProperty path)
            ( \message -> Bus.appendString message "org.freedesktop.systemd1.Unit" >> Bus.appendString message "Id"
            )
            Bus.readVariantString
      pure
        (if identity == Right controllerUnitName then ControllerUnitPresent else ControllerUnitUnobservable)

controllerProviderDigest :: Provider.RecordedProviderBinding -> String
controllerProviderDigest = ByteString8.unpack . hexSha256 . Provider.encodeProviderBinding

-- A fresh read-only provider observation under the recovered operation lease.
-- A different boot or UID refuses before opening a manager socket. The result
-- establishes neither job processing nor physical worker settlement.
observeControllerFreshProvider :: BootstrapProjection -> IO ControllerFreshProvider
observeControllerFreshProvider bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      outcome <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        submission <- observeRetainedControllerSubmission bootstrap operation stable
        case submission of
          RetainedControllerSubmissionObserved digest -> do
            domain <- observeRetainedControllerDomain bootstrap operation digest stable
            material <- observeControllerProviderMaterial bootstrap operation digest stable
            case (domain, material) of
              ( RetainedControllerDomainObserved recordedDomain _
                , RetainedControllerProviderMaterialObserved recordedBinding
                ) -> do
                  owner <- getEffectiveUserID
                  boot <- currentBootId
                  if boot == Nothing
                    then pure ControllerFreshProviderUnobservable
                    else
                      if boot /= Just (Identity.hostManagerBootId recordedDomain)
                        || fromIntegral owner /= Identity.hostManagerUserId recordedDomain
                        then pure ControllerFreshProviderDifferentDomain
                        else do
                          result <- withCurrentControllerProvider $ \freshDomain freshBinding _ _ _ verify -> do
                            before <- verify
                            currentDomain <- observeRetainedControllerDomain bootstrap operation digest stable
                            currentMaterial <- observeControllerProviderMaterial bootstrap operation digest stable
                            still <- stable
                            after <- verify
                            finalStable <- stable
                            pure $
                              if not before
                                || not after
                                || not still
                                || not finalStable
                                || currentDomain /= domain
                                || currentMaterial /= material
                                then ControllerFreshProviderUnobservable
                                else
                                  if compareControllerProviderBinding recordedDomain recordedBinding freshDomain freshBinding
                                    then ControllerFreshProviderMatches
                                    else ControllerFreshProviderDifferent
                          pure (either (const ControllerFreshProviderUnobservable) id result)
              _ -> pure ControllerFreshProviderRecordUnavailable
          _ -> pure ControllerFreshProviderRecordUnavailable
      pure $ case outcome of
        KindOperationCallbackReturned result -> result
        _ -> ControllerFreshProviderUnobservable
    _ -> pure ControllerFreshProviderRecordUnavailable

-- Observe the original sender on the same freshly qualified manager domain.
-- Name absence is only a point observation and is not a drained-job or
-- physical-retirement proof.
observeControllerFreshSender :: BootstrapProjection -> IO ControllerFreshSender
observeControllerFreshSender bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      outcome <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        submission <- observeRetainedControllerSubmission bootstrap operation stable
        case submission of
          RetainedControllerSubmissionObserved digest -> do
            domain <- observeRetainedControllerDomain bootstrap operation digest stable
            material <- observeControllerProviderMaterial bootstrap operation digest stable
            sender <- observeRetainedControllerSender bootstrap operation digest stable
            case (domain, material, sender) of
              ( RetainedControllerDomainObserved recordedDomain _
                , RetainedControllerProviderMaterialObserved recordedBinding
                , RetainedControllerSenderObserved recordedSender
                ) -> do
                  owner <- getEffectiveUserID
                  boot <- currentBootId
                  if boot == Nothing
                    then pure ControllerFreshSenderUnobservable
                    else
                      if boot /= Just (Identity.hostManagerBootId recordedDomain)
                        || fromIntegral owner /= Identity.hostManagerUserId recordedDomain
                        then pure ControllerFreshSenderDifferentDomain
                        else do
                          result <- withCurrentControllerProvider $ \freshDomain freshBinding _ observePresence _ verify -> do
                            before <- verify
                            first <- observePresence recordedSender
                            currentDomain <- observeRetainedControllerDomain bootstrap operation digest stable
                            currentMaterial <- observeControllerProviderMaterial bootstrap operation digest stable
                            currentSender <- observeRetainedControllerSender bootstrap operation digest stable
                            second <- observePresence recordedSender
                            after <- verify
                            finalStable <- stable
                            pure $
                              if not before
                                || not after
                                || not finalStable
                                || currentDomain /= domain
                                || currentMaterial /= material
                                || currentSender /= sender
                                || not (compareControllerProviderBinding recordedDomain recordedBinding freshDomain freshBinding)
                                || first /= second
                                then ControllerFreshSenderUnobservable
                                else case first of
                                  ControllerSenderPresent -> ControllerFreshSenderPresent
                                  ControllerSenderAbsent -> ControllerFreshSenderAbsent
                                  ControllerSenderPresenceUnobservable -> ControllerFreshSenderUnobservable
                          pure (either (const ControllerFreshSenderUnobservable) id result)
              _ -> pure ControllerFreshSenderRecordUnavailable
          _ -> pure ControllerFreshSenderRecordUnavailable
      pure $ case outcome of
        KindOperationCallbackReturned result -> result
        _ -> ControllerFreshSenderUnobservable
    _ -> pure ControllerFreshSenderRecordUnavailable

-- Read the exact controller unit after checking the retained sender, under
-- the same fresh provider. This reports an observable manager read, not a
-- durable proof that a job or worker has finished.
observeControllerManagerRead :: BootstrapProjection -> IO ControllerManagerRead
observeControllerManagerRead bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      outcome <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        submission <- observeRetainedControllerSubmission bootstrap operation stable
        case submission of
          RetainedControllerSubmissionObserved digest -> do
            domain <- observeRetainedControllerDomain bootstrap operation digest stable
            material <- observeControllerProviderMaterial bootstrap operation digest stable
            sender <- observeRetainedControllerSender bootstrap operation digest stable
            case (domain, material, sender) of
              ( RetainedControllerDomainObserved recordedDomain _
                , RetainedControllerProviderMaterialObserved recordedBinding
                , RetainedControllerSenderObserved recordedSender
                ) -> do
                  owner <- getEffectiveUserID
                  boot <- currentBootId
                  if boot == Nothing
                    then pure ControllerManagerReadUnobservable
                    else
                      if boot /= Just (Identity.hostManagerBootId recordedDomain)
                        || fromIntegral owner /= Identity.hostManagerUserId recordedDomain
                        then pure ControllerManagerDifferentDomain
                        else do
                          result <- withCurrentControllerProvider $ \freshDomain freshBinding _ observePresence readUnit verify -> do
                            before <- verify
                            first <- observePresence recordedSender
                            unit <- if first == ControllerSenderAbsent then readUnit else pure ControllerUnitUnobservable
                            currentDomain <- observeRetainedControllerDomain bootstrap operation digest stable
                            currentMaterial <- observeControllerProviderMaterial bootstrap operation digest stable
                            currentSender <- observeRetainedControllerSender bootstrap operation digest stable
                            second <- observePresence recordedSender
                            after <- verify
                            finalStable <- stable
                            pure $
                              if not before
                                || not after
                                || not finalStable
                                || currentDomain /= domain
                                || currentMaterial /= material
                                || currentSender /= sender
                                || not (compareControllerProviderBinding recordedDomain recordedBinding freshDomain freshBinding)
                                || first /= second
                                then ControllerManagerReadUnobservable
                                else case (first, unit) of
                                  (ControllerSenderPresent, _) -> ControllerManagerSenderPresent
                                  (ControllerSenderAbsent, ControllerUnitPresent) -> ControllerManagerUnitPresent
                                  (ControllerSenderAbsent, ControllerUnitAbsent) -> ControllerManagerUnitAbsent
                                  _ -> ControllerManagerReadUnobservable
                          pure (either (const ControllerManagerReadUnobservable) id result)
              _ -> pure ControllerManagerRecordUnavailable
          _ -> pure ControllerManagerRecordUnavailable
      pure $ case outcome of
        KindOperationCallbackReturned result -> result
        _ -> ControllerManagerReadUnobservable
    _ -> pure ControllerManagerRecordUnavailable

-- | Recovery effects require a held proof of both manager processing and
-- physical worker retirement. The static kind controller has no such proof
-- yet. In particular, neither a missing record nor an absent unit permits an
-- effect. Keep the recovery action intact, but do not enter it until the
-- controller is migrated to a settlement owner that can hold that proof.
withControllerRecoverySettlement :: IO value -> IO (Either String value)
withControllerRecoverySettlement _ =
  pure (Left "kind controller processing and physical retirement are unconfirmed")

currentBootId :: IO (Maybe String)
currentBootId = do
  observed <- timeout 2000000 $
    try $
      bracket (Posix.openFd "/proc/sys/kernel/random/boot_id" Posix.ReadOnly readFlags) Posix.closeFd $ \file ->
        PosixBytes.fdRead file 65
  pure $ case observed of
    Just (Right bytes) -> case ByteString8.unpack bytes of
      value | length value == 37 && last value == '\n' -> Just (init value)
      value | length value == 36 -> Just value
      _ -> Nothing
    Just (Left (_ :: IOException)) -> Nothing
    Nothing -> Nothing

controllerDomainName :: FilePath
controllerDomainName = "kind-controller-manager-domain.json"

domainValue
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> Files.FileStatus
  -> Aeson.Value
domainValue bootstrap operation requestDigest domain window root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-manager-domain" :: String)
    , "intent" Aeson..= submissionValue bootstrap operation requestDigest root
    , "boot_id" Aeson..= Identity.hostManagerBootId domain
    , "bus_id" Aeson..= Identity.hostManagerBusId domain
    , "manager_name" Aeson..= Identity.hostManagerUniqueName domain
    , "manager_uid" Aeson..= Identity.hostManagerUserId domain
    , "manager_pid" Aeson..= Identity.hostManagerProcessId domain
    , "manager_start_ticks" Aeson..= Identity.hostManagerStartTicks domain
    , "outer_ns" Aeson..= Identity.hostExecutionOuterEnd window
    , "work_ns" Aeson..= Identity.hostExecutionWorkEnd window
    , "hard_ns" Aeson..= Identity.hostExecutionHardEnd window
    , "stop_ns" Aeson..= Identity.hostExecutionStopEnd window
    , "finish_ns" Aeson..= Identity.hostExecutionFinishEnd window
    ]

-- A retained manager observation binds the original clock and manager domain;
-- the record is not a provider qualification or a live manager observation.
recordControllerDomain
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> IO Bool
  -> IO ControllerDomainWrite
recordControllerDomain bootstrap operation requestDigest domain window stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure ControllerDomainRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          intent <- observeControllerSubmissionIntent bootstrap operation requestDigest operationStable
          rootStatus <- Files.getFdStatus root
          if not admitted || intent /= ControllerSubmissionMatches
            then pure ControllerDomainRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) controllerDomainName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerDomainAlreadyExists
                Left (_ :: IOException) -> pure ControllerDomainRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      ( LazyByteString.toStrict
                          (Aeson.encode (domainValue bootstrap operation requestDigest domain window rootStatus))
                      )
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerDomainIncomplete
                    Right () -> do
                      observed <-
                        restore (observeControllerDomain bootstrap operation requestDigest domain window operationStable)
                      pure
                        (if observed == ControllerDomainMatches then ControllerDomainRecorded else ControllerDomainIncomplete)
        pure
          (either (const ControllerDomainRefused) id (attempted :: Either IOException ControllerDomainWrite))
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerDomainRefused -> outcome
        _ | changed -> ControllerDomainIncomplete
        _ -> ControllerDomainRefused

observeControllerDomain
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> IO Bool
  -> IO ControllerDomainObservation
observeControllerDomain bootstrap operation requestDigest domain window stable = do
  observed <- observeRetainedControllerDomain bootstrap operation requestDigest stable
  pure $ case observed of
    RetainedControllerDomainMissing -> ControllerDomainMissing
    RetainedControllerDomainObserved actualDomain actualWindow
      | actualDomain == domain && actualWindow == window -> ControllerDomainMatches
      | otherwise -> ControllerDomainConflict
    RetainedControllerDomainConflict -> ControllerDomainConflict
    RetainedControllerDomainUnobservable -> ControllerDomainUnobservable

observeRetainedControllerDomain
  :: BootstrapProjection -> String -> String -> IO Bool -> IO RetainedControllerDomain
observeRetainedControllerDomain bootstrap operation requestDigest stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure RetainedControllerDomainUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          intent <- observeControllerSubmissionIntent bootstrap operation requestDigest stable
          rootStatus <- Files.getFdStatus root
          if not admitted || intent /= ControllerSubmissionMatches
            then pure RetainedControllerDomainUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) controllerDomainName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then RetainedControllerDomainMissing else RetainedControllerDomainUnobservable)
                Left (_ :: IOException) -> pure RetainedControllerDomainUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure RetainedControllerDomainUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) controllerDomainName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      currentIntent <- observeControllerSubmissionIntent bootstrap operation requestDigest stable
                      pure $
                        if not
                          ( still
                              && currentIntent == ControllerSubmissionMatches
                              && sameVersion before after
                              && sameVersion after named
                          )
                          then RetainedControllerDomainUnobservable
                          else case (Aeson.eitherDecodeStrict' bytes, checked) of
                            (Right value, Right checkedValue) | value == checkedValue ->
                              case parseEither parseDomain value of
                                Right (Just (domain, window))
                                  | value == domainValue bootstrap operation requestDigest domain window rootStatus ->
                                      RetainedControllerDomainObserved domain window
                                _ -> RetainedControllerDomainConflict
                            _ -> RetainedControllerDomainConflict
        pure
          ( either
              (const RetainedControllerDomainUnobservable)
              id
              (attempted :: Either IOException RetainedControllerDomain)
          )
      pure $ case result of Just (Right observed) -> observed; _ -> RetainedControllerDomainUnobservable
 where
  parseDomain = Aeson.withObject "controller manager domain" $ \object -> do
    boot <- object .: "boot_id"
    bus <- object .: "bus_id"
    name <- object .: "manager_name"
    uid <- object .: "manager_uid"
    pid <- object .: "manager_pid"
    ticks <- object .: "manager_start_ticks"
    outer <- object .: "outer_ns"
    work <- object .: "work_ns"
    hard <- object .: "hard_ns"
    stop <- object .: "stop_ns"
    finish <- object .: "finish_ns"
    pure
      ( (,)
          <$> Identity.hostManagerDomain boot bus name uid pid ticks
          <*> Identity.hostExecutionWindow outer work hard stop finish
      )

controllerProviderName :: FilePath
controllerProviderName = "kind-controller-provider-binding.json"

providerValue
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> String
  -> Files.FileStatus
  -> Aeson.Value
providerValue bootstrap operation requestDigest domain window providerDigest root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-provider-binding" :: String)
    , "manager_domain" Aeson..= domainValue bootstrap operation requestDigest domain window root
    , "provider_sha256" Aeson..= providerDigest
    ]

-- The digest is non-authorizing historical data. A future recovery must
-- freshly qualify the provider and compare its encoded binding.
recordControllerProvider
  :: BootstrapProjection -> String -> String -> String -> IO Bool -> IO ControllerProviderWrite
recordControllerProvider bootstrap operation requestDigest providerDigest stable
  | not
      ( validInput bootstrap operation
          && validImageId ("sha256:" ++ requestDigest)
          && validImageId ("sha256:" ++ providerDigest)
      ) =
      pure ControllerProviderRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest operationStable
          rootStatus <- Files.getFdStatus root
          case domain of
            RetainedControllerDomainObserved manager window | admitted -> mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) controllerProviderName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerProviderAlreadyExists
                Left (_ :: IOException) -> pure ControllerProviderRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      ( LazyByteString.toStrict
                          ( Aeson.encode
                              (providerValue bootstrap operation requestDigest manager window providerDigest rootStatus)
                          )
                      )
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerProviderIncomplete
                    Right () -> do
                      observed <-
                        restore (observeRetainedControllerProvider bootstrap operation requestDigest operationStable)
                      pure
                        ( if observed == RetainedControllerProviderObserved providerDigest
                            then ControllerProviderRecorded
                            else ControllerProviderIncomplete
                        )
            _ -> pure ControllerProviderRefused
        pure
          ( either
              (const ControllerProviderRefused)
              id
              (attempted :: Either IOException ControllerProviderWrite)
          )
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerProviderRefused -> outcome
        _ | changed -> ControllerProviderIncomplete
        _ -> ControllerProviderRefused

observeRetainedControllerProvider
  :: BootstrapProjection -> String -> String -> IO Bool -> IO RetainedControllerProvider
observeRetainedControllerProvider bootstrap operation requestDigest stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure RetainedControllerProviderUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
          rootStatus <- Files.getFdStatus root
          case domain of
            RetainedControllerDomainObserved manager window | admitted -> do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) controllerProviderName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then RetainedControllerProviderMissing else RetainedControllerProviderUnobservable)
                Left (_ :: IOException) -> pure RetainedControllerProviderUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure RetainedControllerProviderUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) controllerProviderName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      finalDomain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
                      pure $
                        if not (still && finalDomain == domain && sameVersion before after && sameVersion after named)
                          then RetainedControllerProviderUnobservable
                          else case (Aeson.eitherDecodeStrict' bytes, checked) of
                            (Right value, Right checkedValue) | value == checkedValue ->
                              case parseEither (Aeson.withObject "controller provider" (.: "provider_sha256")) value of
                                Right digest
                                  | validImageId ("sha256:" ++ digest)
                                      && value == providerValue bootstrap operation requestDigest manager window digest rootStatus ->
                                      RetainedControllerProviderObserved digest
                                _ -> RetainedControllerProviderConflict
                            _ -> RetainedControllerProviderConflict
            _ -> pure RetainedControllerProviderUnobservable
        pure
          ( either
              (const RetainedControllerProviderUnobservable)
              id
              (attempted :: Either IOException RetainedControllerProvider)
          )
      pure $ case result of Just (Right observed) -> observed; _ -> RetainedControllerProviderUnobservable

providerMaterialName :: FilePath
providerMaterialName = "kind-controller-provider-material.json"

providerMaterialValue
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> Provider.RecordedProviderBinding
  -> Files.FileStatus
  -> Aeson.Value
providerMaterialValue bootstrap operation requestDigest domain window binding root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-provider-material" :: String)
    , "provider" Aeson..= providerValue bootstrap operation requestDigest domain window digest root
    , "binding_base64" Aeson..= TextEncoding.decodeUtf8 (Base64.encode encoded)
    ]
 where
  encoded = Provider.encodeProviderBinding binding
  digest = ByteString8.unpack (hexSha256 encoded)

-- The decoded binding is retained data, not a live provider qualification.
recordControllerProviderMaterial
  :: BootstrapProjection
  -> String
  -> String
  -> Provider.RecordedProviderBinding
  -> IO Bool
  -> IO ControllerProviderMaterialWrite
recordControllerProviderMaterial bootstrap operation requestDigest binding stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure ControllerProviderMaterialRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
          digest = ByteString8.unpack (hexSha256 (Provider.encodeProviderBinding binding))
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest operationStable
          provider <- observeRetainedControllerProvider bootstrap operation requestDigest operationStable
          rootStatus <- Files.getFdStatus root
          case domain of
            RetainedControllerDomainObserved manager window | admitted && provider == RetainedControllerProviderObserved digest -> mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) providerMaterialName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerProviderMaterialAlreadyExists
                Left (_ :: IOException) -> pure ControllerProviderMaterialRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      ( LazyByteString.toStrict
                          ( Aeson.encode
                              (providerMaterialValue bootstrap operation requestDigest manager window binding rootStatus)
                          )
                      )
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerProviderMaterialIncomplete
                    Right () -> do
                      observed <-
                        restore (observeControllerProviderMaterial bootstrap operation requestDigest operationStable)
                      pure
                        ( if observed == RetainedControllerProviderMaterialObserved binding
                            then ControllerProviderMaterialRecorded
                            else ControllerProviderMaterialIncomplete
                        )
            _ -> pure ControllerProviderMaterialRefused
        pure
          ( either
              (const ControllerProviderMaterialRefused)
              id
              (attempted :: Either IOException ControllerProviderMaterialWrite)
          )
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerProviderMaterialRefused -> outcome
        _ | changed -> ControllerProviderMaterialIncomplete
        _ -> ControllerProviderMaterialRefused

observeControllerProviderMaterial
  :: BootstrapProjection -> String -> String -> IO Bool -> IO RetainedControllerProviderMaterial
observeControllerProviderMaterial bootstrap operation requestDigest stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure RetainedControllerProviderMaterialUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
          provider <- observeRetainedControllerProvider bootstrap operation requestDigest stable
          rootStatus <- Files.getFdStatus root
          case (domain, provider) of
            (RetainedControllerDomainObserved manager window, RetainedControllerProviderObserved digest) | admitted -> do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) providerMaterialName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure
                    ( if still
                        then RetainedControllerProviderMaterialMissing
                        else RetainedControllerProviderMaterialUnobservable
                    )
                Left (_ :: IOException) -> pure RetainedControllerProviderMaterialUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure RetainedControllerProviderMaterialUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) providerMaterialName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      finalDomain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
                      finalProvider <- observeRetainedControllerProvider bootstrap operation requestDigest stable
                      pure $
                        if not
                          ( still
                              && finalDomain == domain
                              && finalProvider == provider
                              && sameVersion before after
                              && sameVersion after named
                          )
                          then RetainedControllerProviderMaterialUnobservable
                          else case (Aeson.eitherDecodeStrict' bytes, checked) of
                            (Right value, Right checkedValue) | value == checkedValue ->
                              case parseEither (Aeson.withObject "controller provider material" (.: "binding_base64")) value of
                                Right encodedText -> case Base64.decode (TextEncoding.encodeUtf8 encodedText) of
                                  Right encoded
                                    | Base64.encode encoded == TextEncoding.encodeUtf8 encodedText
                                        && ByteString8.unpack (hexSha256 encoded) == digest ->
                                        case Provider.decodeProviderBinding encoded of
                                          Right binding
                                            | value == providerMaterialValue bootstrap operation requestDigest manager window binding rootStatus ->
                                                RetainedControllerProviderMaterialObserved binding
                                          _ -> RetainedControllerProviderMaterialConflict
                                  _ -> RetainedControllerProviderMaterialConflict
                                _ -> RetainedControllerProviderMaterialConflict
                            _ -> RetainedControllerProviderMaterialConflict
            _ -> pure RetainedControllerProviderMaterialUnobservable
        pure
          ( either
              (const RetainedControllerProviderMaterialUnobservable)
              id
              (attempted :: Either IOException RetainedControllerProviderMaterial)
          )
      pure $ case result of
        Just (Right observed) -> observed
        _ -> RetainedControllerProviderMaterialUnobservable

controllerSenderName :: FilePath
controllerSenderName = "kind-controller-sender.json"

senderValue
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostManagerDomain
  -> Identity.HostExecutionWindow
  -> Provider.RecordedProviderBinding
  -> Identity.HostBusUniqueName
  -> Files.FileStatus
  -> Aeson.Value
senderValue bootstrap operation requestDigest domain window binding sender root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-sender" :: String)
    , "provider_material"
        Aeson..= providerMaterialValue bootstrap operation requestDigest domain window binding root
    , "sender" Aeson..= Identity.hostBusUniqueNameText sender
    ]

-- The retained sender is non-authorizing data. Later recovery must establish
-- that the original sender is gone under the same freshly qualified provider.
recordControllerSender
  :: BootstrapProjection
  -> String
  -> String
  -> Identity.HostBusUniqueName
  -> IO Bool
  -> IO ControllerSenderWrite
recordControllerSender bootstrap operation requestDigest sender stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure ControllerSenderRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest operationStable
          material <- observeControllerProviderMaterial bootstrap operation requestDigest operationStable
          rootStatus <- Files.getFdStatus root
          case (domain, material) of
            ( RetainedControllerDomainObserved manager window
              , RetainedControllerProviderMaterialObserved binding
              ) | admitted -> mask $ \restore -> do
                opened <- try (Posix.openFdAt (Just root) controllerSenderName Posix.WriteOnly createFlags)
                case opened of
                  Left failure | isAlreadyExistsError failure -> pure ControllerSenderAlreadyExists
                  Left (_ :: IOException) -> pure ControllerSenderRefused
                  Right file -> do
                    writeIORef touched True
                    written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                      writeAll
                        held
                        ( LazyByteString.toStrict
                            ( Aeson.encode
                                (senderValue bootstrap operation requestDigest manager window binding sender rootStatus)
                            )
                        )
                      fileSynchronise held
                      fileSynchronise root
                    case written of
                      Left (_ :: IOException) -> pure ControllerSenderIncomplete
                      Right () -> do
                        observed <-
                          restore (observeRetainedControllerSender bootstrap operation requestDigest operationStable)
                        pure
                          ( if observed == RetainedControllerSenderObserved sender
                              then ControllerSenderRecorded
                              else ControllerSenderIncomplete
                          )
            _ -> pure ControllerSenderRefused
        pure
          (either (const ControllerSenderRefused) id (attempted :: Either IOException ControllerSenderWrite))
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerSenderRefused -> outcome
        _ | changed -> ControllerSenderIncomplete
        _ -> ControllerSenderRefused

observeRetainedControllerSender
  :: BootstrapProjection -> String -> String -> IO Bool -> IO RetainedControllerSender
observeRetainedControllerSender bootstrap operation requestDigest stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure RetainedControllerSenderUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          domain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
          material <- observeControllerProviderMaterial bootstrap operation requestDigest stable
          rootStatus <- Files.getFdStatus root
          case (domain, material) of
            ( RetainedControllerDomainObserved manager window
              , RetainedControllerProviderMaterialObserved binding
              ) | admitted -> do
                owner <- getEffectiveUserID
                opened <- try (Posix.openFdAt (Just root) controllerSenderName Posix.ReadOnly readFlags)
                case opened of
                  Left failure | isDoesNotExistError failure -> do
                    still <- ready bootstrap stable sameRoot
                    pure (if still then RetainedControllerSenderMissing else RetainedControllerSenderUnobservable)
                  Left (_ :: IOException) -> pure RetainedControllerSenderUnobservable
                  Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                    before <- Files.getFdStatus held
                    if not (safeFile owner before)
                      then pure RetainedControllerSenderUnobservable
                      else do
                        bytes <- readBounded held
                        checked <- decodeBoundedYamlValue bytes
                        after <- Files.getFdStatus held
                        named <-
                          bracket
                            (Posix.openFdAt (Just root) controllerSenderName Posix.ReadOnly readFlags)
                            Posix.closeFd
                            Files.getFdStatus
                        still <- ready bootstrap stable sameRoot
                        finalDomain <- observeRetainedControllerDomain bootstrap operation requestDigest stable
                        finalMaterial <- observeControllerProviderMaterial bootstrap operation requestDigest stable
                        pure $
                          if not
                            ( still
                                && finalDomain == domain
                                && finalMaterial == material
                                && sameVersion before after
                                && sameVersion after named
                            )
                            then RetainedControllerSenderUnobservable
                            else case (Aeson.eitherDecodeStrict' bytes, checked) of
                              (Right value, Right checkedValue) | value == checkedValue ->
                                case parseEither (Aeson.withObject "controller sender" (.: "sender")) value of
                                  Right name
                                    | Just sender <- Identity.hostBusUniqueName name
                                    , value == senderValue bootstrap operation requestDigest manager window binding sender rootStatus ->
                                        RetainedControllerSenderObserved sender
                                  _ -> RetainedControllerSenderConflict
                              _ -> RetainedControllerSenderConflict
            _ -> pure RetainedControllerSenderUnobservable
        pure
          ( either
              (const RetainedControllerSenderUnobservable)
              id
              (attempted :: Either IOException RetainedControllerSender)
          )
      pure $ case result of Just (Right observed) -> observed; _ -> RetainedControllerSenderUnobservable

controllerJobName :: FilePath
controllerJobName = "kind-controller-submission-job.json"

validControllerJob :: String -> Bool
validControllerJob path = case stripPrefix "/org/freedesktop/systemd1/job/" path of
  Just digits -> case readMaybe digits :: Maybe Word32 of
    Just value -> value > 0 && show value == digits
    Nothing -> False
  Nothing -> False

jobValue :: BootstrapProjection -> String -> String -> String -> Files.FileStatus -> Aeson.Value
jobValue bootstrap operation requestDigest job root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-submission-job" :: String)
    , "intent" Aeson..= submissionValue bootstrap operation requestDigest root
    , "job_path" Aeson..= job
    ]

-- This records a returned manager job path only. It is not authenticated job
-- identity, manager acceptance proof, job completion, or worker retirement.
recordControllerJob
  :: BootstrapProjection -> String -> String -> String -> IO Bool -> IO ControllerJobWrite
recordControllerJob bootstrap operation requestDigest job stable
  | not
      ( validInput bootstrap operation
          && validImageId ("sha256:" ++ requestDigest)
          && validControllerJob job
      ) =
      pure ControllerJobRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          intent <- observeControllerSubmissionIntent bootstrap operation requestDigest operationStable
          rootStatus <- Files.getFdStatus root
          if not admitted || intent /= ControllerSubmissionMatches
            then pure ControllerJobRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) controllerJobName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerJobAlreadyExists
                Left (_ :: IOException) -> pure ControllerJobRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      (LazyByteString.toStrict (Aeson.encode (jobValue bootstrap operation requestDigest job rootStatus)))
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerJobIncomplete
                    Right () -> do
                      observed <- restore (observeControllerJob bootstrap operation requestDigest job operationStable)
                      pure (if observed == ControllerJobMatches then ControllerJobRecorded else ControllerJobIncomplete)
        pure (either (const ControllerJobRefused) id (attempted :: Either IOException ControllerJobWrite))
      changed <- readIORef touched
      pure $ case result of
        Just (Right outcome) | outcome /= ControllerJobRefused -> outcome
        _ | changed -> ControllerJobIncomplete
        _ -> ControllerJobRefused

observeControllerJob
  :: BootstrapProjection -> String -> String -> String -> IO Bool -> IO ControllerJobObservation
observeControllerJob bootstrap operation requestDigest job stable
  | not (validControllerJob job) = pure ControllerJobUnobservable
  | otherwise = do
      observed <- observeRetainedControllerJob bootstrap operation requestDigest stable
      pure $ case observed of
        RetainedControllerJobMissing -> ControllerJobMissing
        RetainedControllerJobObserved actual | actual == job -> ControllerJobMatches
        RetainedControllerJobObserved _ -> ControllerJobConflict
        RetainedControllerJobConflict -> ControllerJobConflict
        RetainedControllerJobUnobservable -> ControllerJobUnobservable

observeRetainedControllerJob
  :: BootstrapProjection -> String -> String -> IO Bool -> IO RetainedControllerJob
observeRetainedControllerJob bootstrap operation requestDigest stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ requestDigest)) =
      pure RetainedControllerJobUnobservable
  | otherwise = do
      result <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          intent <- observeControllerSubmissionIntent bootstrap operation requestDigest stable
          rootStatus <- Files.getFdStatus root
          if not admitted || intent /= ControllerSubmissionMatches
            then pure RetainedControllerJobUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) controllerJobName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then RetainedControllerJobMissing else RetainedControllerJobUnobservable)
                Left (_ :: IOException) -> pure RetainedControllerJobUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure RetainedControllerJobUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) controllerJobName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      currentIntent <- observeControllerSubmissionIntent bootstrap operation requestDigest stable
                      pure $
                        if not
                          ( still
                              && currentIntent == ControllerSubmissionMatches
                              && sameVersion before after
                              && sameVersion after named
                          )
                          then RetainedControllerJobUnobservable
                          else case (Aeson.eitherDecodeStrict' bytes, checked) of
                            (Right value, Right checkedValue) | value == checkedValue ->
                              case parseEither (Aeson.withObject "controller job" (.: "job_path")) value of
                                Right path
                                  | validControllerJob path && value == jobValue bootstrap operation requestDigest path rootStatus ->
                                      RetainedControllerJobObserved path
                                _ -> RetainedControllerJobConflict
                            _ -> RetainedControllerJobConflict
        pure
          ( either
              (const RetainedControllerJobUnobservable)
              id
              (attempted :: Either IOException RetainedControllerJob)
          )
      pure $ case result of Just (Right observed) -> observed; _ -> RetainedControllerJobUnobservable

receiptName :: FilePath
receiptName = "kind-controller-worker-result.json"

readFlags, createFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

validInput :: BootstrapProjection -> String -> Bool
validInput bootstrap operation =
  scopeEnvironment (bootstrapScope bootstrap) == Test && validRootGeneration operation

ready :: BootstrapProjection -> IO Bool -> IO Bool -> IO Bool
ready bootstrap stable sameRoot = do
  first <- stable
  rootFirst <- sameRoot
  generation <-
    observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
  rootLast <- sameRoot
  lastStable <- stable
  pure (first && rootFirst && generation == Right ScopeGenerationMatches && rootLast && lastStable)

receiptValue :: BootstrapProjection -> String -> String -> Files.FileStatus -> Aeson.Value
receiptValue bootstrap operation identifier root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-controller-worker-completed" :: String)
    , "deployment_id" Aeson..= scopeIdentifier (bootstrapScope bootstrap)
    , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
    , "operation_id" Aeson..= operation
    , "node_id" Aeson..= identifier
    , "root_device" Aeson..= toInteger (Files.deviceID root)
    , "root_inode" Aeson..= toInteger (Files.fileID root)
    ]

safeFile :: UserID -> Files.FileStatus -> Bool
safeFile owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.fileMode status .&. 0o077 == 0
    && Files.linkCount status == 1
    && Files.fileSize status >= 0
    && Files.fileSize status <= 4096

sameVersion :: Files.FileStatus -> Files.FileStatus -> Bool
sameVersion first second =
  Files.deviceID first == Files.deviceID second
    && Files.fileID first == Files.fileID second
    && Files.fileOwner first == Files.fileOwner second
    && Files.fileMode first == Files.fileMode second
    && Files.linkCount first == Files.linkCount second
    && Files.fileSize first == Files.fileSize second
    && Files.modificationTimeHiRes first == Files.modificationTimeHiRes second
    && Files.statusChangeTimeHiRes first == Files.statusChangeTimeHiRes second

familyResultName :: FilePath
familyResultName = "kind-family-dispatch-result.json"

familyLaunchName :: FilePath
familyLaunchName = "kind-family-launch-request.json"

familyPublicationName :: FilePath
familyPublicationName = "kind-family-publication-attempt.json"

familyCancellationName :: FilePath
familyCancellationName = "kind-family-pre-publication-cancel.json"

familyLaunchValue
  :: FilePath
  -> BootstrapProjection
  -> String
  -> Request.KindControllerRequest
  -> Files.FileStatus
  -> Aeson.Value
familyLaunchValue name bootstrap operation request root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind"
        Aeson..= ( if name == familyLaunchName
                     then "kind-family-launch-request"
                     else
                       if name == familyPublicationName
                         then "kind-family-publication-attempt"
                         else "kind-family-pre-publication-cancel" :: String
                 )
    , "publication_protocol" Aeson..= (1 :: Int)
    , "deployment_id" Aeson..= scopeIdentifier (bootstrapScope bootstrap)
    , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
    , "operation_id" Aeson..= operation
    , "root_device" Aeson..= toInteger (Files.deviceID root)
    , "root_inode" Aeson..= toInteger (Files.fileID root)
    , "request_base64"
        Aeson..= TextEncoding.decodeUtf8 (Base64.encode (Request.encodeKindControllerRequest request))
    ]

-- This write-ahead record is a recovery locator, not evidence of submission.
recordFamilyLaunch
  :: BootstrapProjection -> Request.KindControllerRequest -> IO Bool -> IO FamilyLaunchWrite
recordFamilyLaunch = recordFamilyLaunchAt familyLaunchName

recordFamilyPublicationAttempt
  :: BootstrapProjection -> Request.KindControllerRequest -> IO Bool -> IO FamilyLaunchWrite
recordFamilyPublicationAttempt = recordFamilyLaunchAt familyPublicationName

recordFamilyPrePublicationCancellation
  :: BootstrapProjection -> Request.KindControllerRequest -> IO Bool -> IO FamilyLaunchWrite
recordFamilyPrePublicationCancellation = recordFamilyLaunchAt familyCancellationName

recordFamilyLaunchAt
  :: FilePath -> BootstrapProjection -> Request.KindControllerRequest -> IO Bool -> IO FamilyLaunchWrite
recordFamilyLaunchAt name bootstrap request stable
  | not (validInput bootstrap operation)
      || Request.decodeRetainedKindControllerRequest bootstrap operation bytes /= Right request =
      pure FamilyLaunchRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          protocol <- observeKindFamilyIntent bootstrap
          legacy <- observeRetainedControllerSubmission bootstrap operation operationStable
          previous <-
            if name == familyLaunchName
              then pure True
              else do
                matching <- matchesRetainedFamilyRequest bootstrap request operationStable
                opposite <-
                  if name == familyPublicationName
                    then observeFamilyPrePublicationCancellation bootstrap operation operationStable
                    else observeFamilyPublicationAttempt bootstrap operation operationStable
                pure (matching && opposite == FamilyLaunchMissing)
          rootStatus <- Files.getFdStatus root
          let encoded =
                LazyByteString.toStrict
                  (Aeson.encode (familyLaunchValue name bootstrap operation request rootStatus))
          if not admitted
            || not previous
            || protocol /= KindIntentMatches operation
            || legacy /= RetainedControllerSubmissionMissing
            || ByteString.length encoded > 4096
            then pure FamilyLaunchRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) name Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure FamilyLaunchAlreadyExists
                Left (_ :: IOException) -> pure FamilyLaunchRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll held encoded
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure FamilyLaunchIncomplete
                    Right () -> do
                      observed <- restore (observeFamilyLaunchAt name bootstrap operation operationStable)
                      pure
                        (if observed == FamilyLaunchObserved request then FamilyLaunchRecorded else FamilyLaunchIncomplete)
        pure (either (const FamilyLaunchRefused) id (attempted :: Either IOException FamilyLaunchWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right value) | value /= FamilyLaunchRefused -> value
        _ | changed -> FamilyLaunchIncomplete
        _ -> FamilyLaunchRefused
 where
  operation = Request.kindRequestOperation request
  bytes = Request.encodeKindControllerRequest request

-- Call under the operation lease. Neither a matching request nor this check
-- proves that a controller was submitted or that its family has retired.
matchesRetainedFamilyRequest
  :: BootstrapProjection -> Request.KindControllerRequest -> IO Bool -> IO Bool
matchesRetainedFamilyRequest bootstrap request stable = do
  before <- stable
  protocol <- observeKindFamilyIntent bootstrap
  retained <- observeFamilyLaunch bootstrap (Request.kindRequestOperation request) stable
  after <- stable
  pure
    ( before
        && after
        && protocol == KindIntentMatches (Request.kindRequestOperation request)
        && retained == FamilyLaunchObserved request
    )

observeFamilyLaunch :: BootstrapProjection -> String -> IO Bool -> IO FamilyLaunchObservation
observeFamilyLaunch = observeFamilyLaunchAt familyLaunchName

observeFamilyPublicationAttempt
  :: BootstrapProjection -> String -> IO Bool -> IO FamilyLaunchObservation
observeFamilyPublicationAttempt = observeFamilyLaunchAt familyPublicationName

observeFamilyPrePublicationCancellation
  :: BootstrapProjection -> String -> IO Bool -> IO FamilyLaunchObservation
observeFamilyPrePublicationCancellation = observeFamilyLaunchAt familyCancellationName

observeFamilyLaunchAt
  :: FilePath -> BootstrapProjection -> String -> IO Bool -> IO FamilyLaunchObservation
observeFamilyLaunchAt name bootstrap operation stable
  | not (validInput bootstrap operation) = pure FamilyLaunchUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure FamilyLaunchUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then FamilyLaunchMissing else FamilyLaunchUnobservable)
                Left (_ :: IOException) -> pure FamilyLaunchUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure FamilyLaunchUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket (Posix.openFdAt (Just root) name Posix.ReadOnly readFlags) Posix.closeFd Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      pure $
                        if not (still && sameVersion before after && sameVersion after named)
                          then FamilyLaunchUnobservable
                          else decodeFamilyLaunch name bootstrap operation rootStatus bytes checked
        pure
          (either (const FamilyLaunchUnobservable) id (attempted :: Either IOException FamilyLaunchObservation))
      pure $ case outcome of Just (Right value) -> value; _ -> FamilyLaunchUnobservable

decodeFamilyLaunch
  :: FilePath
  -> BootstrapProjection
  -> String
  -> Files.FileStatus
  -> ByteString.ByteString
  -> Either KindKubeconfigDecodeError Aeson.Value
  -> FamilyLaunchObservation
decodeFamilyLaunch name bootstrap operation root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right checkedValue) | value == checkedValue -> case parseEither (Aeson.withObject "kind family launch" (.: "request_base64")) value of
    Right encoded -> case Base64.decode (TextEncoding.encodeUtf8 encoded) of
      Right requestBytes -> case Request.decodeRetainedKindControllerRequest bootstrap operation requestBytes of
        Right request | value == familyLaunchValue name bootstrap operation request root -> FamilyLaunchObserved request
        _ -> FamilyLaunchConflict
      _ -> FamilyLaunchConflict
    _ -> FamilyLaunchConflict
  _ -> FamilyLaunchConflict

familyResultValue
  :: BootstrapProjection -> String -> String -> FamilyResult -> Files.FileStatus -> Aeson.Value
familyResultValue bootstrap operation digest (FamilyResult primary worker parent input post postClosing) root =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("kind-family-dispatch-result" :: String)
    , "deployment_id" Aeson..= scopeIdentifier (bootstrapScope bootstrap)
    , "root_generation" Aeson..= bootstrapRootGeneration bootstrap
    , "operation_id" Aeson..= operation
    , "request_sha256" Aeson..= digest
    , "root_device" Aeson..= toInteger (Files.deviceID root)
    , "root_inode" Aeson..= toInteger (Files.fileID root)
    , "primary" Aeson..= show primary
    , "worker_closing" Aeson..= show worker
    , "parent_closing" Aeson..= show parent
    , "input_closing" Aeson..= show input
    , "post" Aeson..= show post
    , "post_closing" Aeson..= show postClosing
    ]

-- The exclusive write and independent read-back are bounded by the recovered
-- operation lease. It records only a summary, never a retirement observation.
recordFamilyResult
  :: BootstrapProjection -> String -> String -> FamilyResult -> IO Bool -> IO FamilyResultWrite
recordFamilyResult bootstrap operation digest result stable
  | not (validInput bootstrap operation && validImageId ("sha256:" ++ digest)) =
      pure FamilyResultRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure FamilyResultRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) familyResultName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure FamilyResultAlreadyExists
                Left (_ :: IOException) -> pure FamilyResultRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      ( LazyByteString.toStrict
                          (Aeson.encode (familyResultValue bootstrap operation digest result rootStatus))
                      )
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure FamilyResultIncomplete
                    Right () -> do
                      observed <- restore (observeFamilyResult bootstrap operation operationStable)
                      pure
                        ( if observed == FamilyResultObserved digest result
                            then FamilyResultRecorded
                            else FamilyResultIncomplete
                        )
        pure (either (const FamilyResultRefused) id (attempted :: Either IOException FamilyResultWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right value) | value /= FamilyResultRefused -> value
        _ | changed -> FamilyResultIncomplete
        _ -> FamilyResultRefused

-- A retirement observer can briefly hold the same lease. Retry only before
-- entering the result writer, within the dispatcher deadline.
recordFamilyResultUntil
  :: Word64
  -> BootstrapProjection
  -> String
  -> String
  -> FamilyResult
  -> IO (KindOperationOutcome FamilyResultWrite)
recordFamilyResultUntil ending bootstrap operation digest summary =
  withRecoveredKindOperationUntil
    ending
    bootstrap
    operation
    (recordFamilyResult bootstrap operation digest summary)

observeFamilyResult :: BootstrapProjection -> String -> IO Bool -> IO FamilyResultObservation
observeFamilyResult bootstrap operation stable
  | not (validInput bootstrap operation) = pure FamilyResultUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure FamilyResultUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) familyResultName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then FamilyResultMissing else FamilyResultUnobservable)
                Left (_ :: IOException) -> pure FamilyResultUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure FamilyResultUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) familyResultName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      pure $
                        if not (still && sameVersion before after && sameVersion after named)
                          then FamilyResultUnobservable
                          else decodeFamilyResult bootstrap operation rootStatus bytes checked
        pure
          (either (const FamilyResultUnobservable) id (attempted :: Either IOException FamilyResultObservation))
      pure $ case outcome of Just (Right value) -> value; _ -> FamilyResultUnobservable

decodeFamilyResult
  :: BootstrapProjection
  -> String
  -> Files.FileStatus
  -> ByteString.ByteString
  -> Either KindKubeconfigDecodeError Aeson.Value
  -> FamilyResultObservation
decodeFamilyResult bootstrap operation root bytes checked = case (Aeson.eitherDecodeStrict' bytes, checked) of
  (Right value, Right checkedValue) | value == checkedValue -> case parseEither fields value of
    Right (digest, primaryText, workerText, parentText, inputText, postText, postClosingText)
      | validImageId ("sha256:" ++ digest)
      , Just primary <- readMaybe primaryText
      , Just worker <- readMaybe workerText
      , Just parent <- readMaybe parentText
      , Just input <- readMaybe inputText
      , Just post <- readMaybe postText
      , Just postClosing <- readMaybe postClosingText
      , let result = FamilyResult primary worker parent input post postClosing
      , value == familyResultValue bootstrap operation digest result root ->
          FamilyResultObserved digest result
    _ -> FamilyResultConflict
  _ -> FamilyResultConflict
 where
  fields = Aeson.withObject "kind family result" $ \o ->
    (,,,,,,)
      <$> o .: "request_sha256"
      <*> o .: "primary"
      <*> o .: "worker_closing"
      <*> o .: "parent_closing"
      <*> o .: "input_closing"
      <*> o .: "post"
      <*> o .: "post_closing"

observeFamilyResultStatus :: BootstrapProjection -> IO String
observeFamilyResultStatus bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      observed <- withRecoveredKindOperation bootstrap operation (observeFamilyResult bootstrap operation)
      pure $
        "Kind family result " ++ operation ++ ": " ++ case observed of
          KindOperationCallbackReturned value -> show value ++ "; local summary only, retirement not observed.\n"
          _ -> "operation lease or result unconfirmed; retirement not observed.\n"
    _ -> pure "Kind family result: operation identity unavailable; retirement not observed.\n"

-- The caller supplies the recovered operation lease and its stability check.
-- This receipt records worker evidence only, never resource readiness.
recordControllerReceipt
  :: BootstrapProjection -> String -> String -> IO Bool -> IO ControllerReceiptWrite
recordControllerReceipt bootstrap operation identifier stable
  | not (validInput bootstrap operation) || not (validImageId ("sha256:" ++ identifier)) =
      pure ControllerReceiptRefused
  | otherwise = do
      touched <- newIORef False
      let operationStable = do
            before <- stable
            current <- observeKindIntent bootstrap
            after <- stable
            pure (before && current == KindIntentMatches operation && after)
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap operationStable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure ControllerReceiptRefused
            else mask $ \restore -> do
              opened <- try (Posix.openFdAt (Just root) receiptName Posix.WriteOnly createFlags)
              case opened of
                Left failure | isAlreadyExistsError failure -> pure ControllerReceiptAlreadyExists
                Left (_ :: IOException) -> pure ControllerReceiptRefused
                Right file -> do
                  writeIORef touched True
                  written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                    writeAll
                      held
                      (LazyByteString.toStrict (Aeson.encode (receiptValue bootstrap operation identifier rootStatus)))
                    fileSynchronise held
                    fileSynchronise root
                  case written of
                    Left (_ :: IOException) -> pure ControllerReceiptIncomplete
                    Right () -> do
                      observed <- restore (observeControllerReceipt bootstrap operation operationStable)
                      pure $
                        if observed == ControllerReceiptObserved identifier
                          then ControllerReceiptRecorded
                          else ControllerReceiptIncomplete
        pure
          (either (const ControllerReceiptRefused) id (attempted :: Either IOException ControllerReceiptWrite))
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right result) | result /= ControllerReceiptRefused -> result
        _ | changed -> ControllerReceiptIncomplete
        _ -> ControllerReceiptRefused

observeControllerReceipt
  :: BootstrapProjection -> String -> IO Bool -> IO ControllerReceiptObservation
observeControllerReceipt bootstrap operation stable
  | not (validInput bootstrap operation) = pure ControllerReceiptUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        attempted <- try $ do
          admitted <- ready bootstrap stable sameRoot
          rootStatus <- Files.getFdStatus root
          if not admitted
            then pure ControllerReceiptUnobservable
            else do
              owner <- getEffectiveUserID
              opened <- try (Posix.openFdAt (Just root) receiptName Posix.ReadOnly readFlags)
              case opened of
                Left failure | isDoesNotExistError failure -> do
                  still <- ready bootstrap stable sameRoot
                  pure (if still then ControllerReceiptMissing else ControllerReceiptUnobservable)
                Left (_ :: IOException) -> pure ControllerReceiptUnobservable
                Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                  before <- Files.getFdStatus held
                  if not (safeFile owner before)
                    then pure ControllerReceiptUnobservable
                    else do
                      bytes <- readBounded held
                      checked <- decodeBoundedYamlValue bytes
                      after <- Files.getFdStatus held
                      named <-
                        bracket
                          (Posix.openFdAt (Just root) receiptName Posix.ReadOnly readFlags)
                          Posix.closeFd
                          Files.getFdStatus
                      still <- ready bootstrap stable sameRoot
                      pure $
                        if not (still && sameVersion before after && sameVersion after named)
                          then ControllerReceiptUnobservable
                          else decodeReceipt bootstrap operation rootStatus bytes checked
        pure
          ( either
              (const ControllerReceiptUnobservable)
              id
              (attempted :: Either IOException ControllerReceiptObservation)
          )
      pure $ case outcome of
        Just (Right observed) -> observed
        _ -> ControllerReceiptUnobservable

decodeReceipt
  :: BootstrapProjection
  -> String
  -> Files.FileStatus
  -> ByteString.ByteString
  -> Either KindKubeconfigDecodeError Aeson.Value
  -> ControllerReceiptObservation
decodeReceipt bootstrap operation root bytes checked =
  case (Aeson.eitherDecodeStrict' bytes, checked) of
    (Right value, Right checkedValue) | value == checkedValue ->
      case parseEither (Aeson.withObject "controller receipt" (.: "node_id")) value of
        Right identifier
          | validImageId ("sha256:" ++ identifier) ->
              if value == receiptValue bootstrap operation identifier root
                then ControllerReceiptObserved identifier
                else ControllerReceiptConflict
        _ -> ControllerReceiptInvalid
    _ -> ControllerReceiptInvalid

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll file bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite file bytes
      unless (count > 0) (ioError (userError "short controller receipt write"))
      writeAll file (ByteString.drop (fromIntegral count) bytes)

readBounded :: Fd -> IO ByteString.ByteString
readBounded file = go [] 0
 where
  go chunks count
    | count > 4096 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        result <- try (PosixBytes.fdRead file (fromIntegral (4097 - count)))
        case result of
          Left (failure :: IOException)
            | isEOFError failure -> pure (ByteString.concat (reverse chunks))
            | otherwise -> ioError failure
          Right chunk
            | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (chunk : chunks) (count + ByteString.length chunk)
