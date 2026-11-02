{-# LANGUAGE ScopedTypeVariables #-}

-- | Pinned same-descriptor input loading and the observed operation parent.
-- Decoding/preparation is bounded by the original work end. The callback's
-- physical interpreter owns work/cleanup; file leases alone grant no effects.
module Prodbox.ControlPlane.RpcAdmissionBirthControllerInputs
  ( RpcBirthControllerArguments
  , RpcBirthControllerInputs
  , RpcBirthControllerLoadError (..)
  , parseRpcBirthControllerArguments
  , withRpcBirthControllerInputs
  , verifyRpcBirthControllerInputs
  , rpcBirthControllerInputPreparation
  , rpcBirthControllerSourcePath
  , withRpcBirthControllerProcesses
  , RpcBirthControllerLaunch
  , withRpcBirthControllerLaunchFiles
  , withPublishedRpcBirthControllerLaunch
  , RpcBirthControllerPublicationResult (..)
  , RpcBirthControllerPublicationDisposition (..)
  , RpcBirthControllerNeverSentRetirementReceipt
  , withPublishedRpcBirthControllerLaunchRetiringUnsent
  , rpcBirthControllerLaunchArguments
  , rpcBirthControllerLaunchUnitNames
  , submitRpcBirthControllerLaunch
  , RpcBirthControllerFieldObservation
  , RpcBirthControllerFieldState (..)
  , HostOperationRole (..)
  , observeRpcBirthControllerField
  , observeRpcBirthControllerSubmission
  , RpcBirthControllerSubmissionProcessed
  , observeRpcBirthControllerSubmissionProcessed
  , RpcBirthControllerRetirement
  , withRpcBirthControllerRetirement
  , verifyRpcBirthControllerRetirement
  , RpcBirthControllerInputRetirementReceipt
  , retireRpcBirthControllerInputs
  , recoverNeverSentRpcBirthControllerInputs
  , rpcBirthControllerFieldState
  , rpcBirthControllerFieldRoleState
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, putMVar, tryTakeMVar)
import Control.Exception (IOException, finally, mask, try, uninterruptibleMask_)
import Control.Monad (unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (IOErrorType, ioe_errno, ioe_type)
import Prodbox.ControlPlane.RpcAdmissionBirthClock qualified as Clock
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
  ( rpcBirthCoordinationDeadline
  , rpcBirthCoordinationScope
  )
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.ControlPlane.RpcAdmissionBirthRequest
import Prodbox.Repo (SiblingConfigSurface (ProductionTier0), siblingConfigPathForExecutable)
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily (HostOperationRole (..))
import Prodbox.Subprocess.HostOperationFamily qualified as Operation
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

type RpcBirthControllerArguments = Arguments.HostControllerArguments

newtype RpcBirthControllerFieldObservation
  = RpcBirthControllerFieldObservation Operation.HostOperationInventory
  deriving (Eq, Show)

data RpcBirthControllerFieldState
  = ControllerFieldAbsent
  | ControllerFieldPresent
  | ControllerFieldUnobservable
  deriving (Eq, Show)

-- This fresh budget grants reads only. Even complete manager absence supplies
-- no kernel/retirement receipt or closure of an uncertain admission.
observeRpcBirthControllerField
  :: Word64
  -> RpcBirthControllerRequest
  -> IO (Either RpcBirthControllerLoadError RpcBirthControllerFieldObservation)
observeRpcBirthControllerField readEnd request = do
  uid <- getEffectiveUserID
  result <-
    Bus.withSystemdBus
      readEnd
      ("/run/user/" <> show uid <> "/bus")
      ( \connection ->
          Operation.observeHostOperationField
            connection
            (Operation.hostOperationField Identity.RpcBirthController (rpcBirthControllerRequestKey request))
      )
  pure (first ControllerLoadBusRefused (RpcBirthControllerFieldObservation <$> result))

-- Historical provenance is data, even when all original work clocks elapsed.
-- This neither reopens the sender nor proves that its queued request drained.
observeRpcBirthControllerSubmission
  :: Word64
  -> FilePath
  -> RpcBirthControllerRequest
  -> IO (Either RpcBirthControllerLoadError Inputs.HostControllerSubmissionRecord)
observeRpcBirthControllerSubmission readEnd path request = runExceptT $ do
  record <-
    ExceptT $
      first (ControllerLoadInputsRefused . Operation.HostOperationInputsRefused)
        <$> Inputs.readHostControllerSubmission readEnd path (rpcBirthControllerRequestKey request)
  unless
    ( Inputs.hostControllerSubmissionKind record == Identity.RpcBirthController
        && Inputs.hostControllerSubmissionWindow record == rpcBirthControllerRequestWindow request
        && Inputs.hostControllerSubmissionDomain record == rpcBirthControllerRequestDomain request
    )
    (throwE ControllerLoadPublicationMismatch)
  pure record

-- Only the original submission's native method-processing frontier. Physical
-- kernel/alarm absence and immutable-file retirement remain independent owners.
newtype RpcBirthControllerSubmissionProcessed
  = RpcBirthControllerSubmissionProcessed Operation.HostSubmissionCausalClosure

observeRpcBirthControllerSubmissionProcessed
  :: Word64
  -> FilePath
  -> RpcBirthControllerRequest
  -> IO (Either RpcBirthControllerLoadError RpcBirthControllerSubmissionProcessed)
observeRpcBirthControllerSubmissionProcessed readEnd path request = runExceptT $ do
  record <- ExceptT (observeRpcBirthControllerSubmission readEnd path request)
  uid <- lift getEffectiveUserID
  observed <-
    ExceptT $
      first ControllerLoadBusRefused
        <$> Bus.withSystemdBus
          readEnd
          ("/run/user/" <> show uid <> "/bus")
          (\connection -> lift (Operation.observeHostSubmissionCausalClosure connection record))
  either
    (throwE . ControllerLoadInputsRefused)
    (pure . RpcBirthControllerSubmissionProcessed)
    observed

-- The callback borrows a fresh, exact-request physical observation owner. It
-- cannot renew work or delete launch inputs without their separate file owner.
newtype RpcBirthControllerRetirement = RpcBirthControllerRetirement Retirement.HostOperationRetirement

withRpcBirthControllerRetirement
  :: Word64
  -> FilePath
  -> RpcBirthControllerRequest
  -> (RpcBirthControllerRetirement -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withRpcBirthControllerRetirement readEnd path request action =
  withMatchedControllerRetirement readEnd path request (\_ -> action . RpcBirthControllerRetirement)

withMatchedControllerRetirement
  :: Word64
  -> FilePath
  -> RpcBirthControllerRequest
  -> (Inputs.HostControllerSubmissionRecord -> Retirement.HostOperationRetirement -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withMatchedControllerRetirement readEnd path request action = runExceptT $ do
  record <- ExceptT (observeRpcBirthControllerSubmission readEnd path request)
  uid <- lift getEffectiveUserID
  observed <-
    ExceptT $
      first ControllerLoadBusRefused
        <$> Bus.withSystemdBus
          readEnd
          ("/run/user/" <> show uid <> "/bus")
          ( \connection ->
              lift
                (Retirement.withHostOperationRetirement connection record (action record))
          )
  either (throwE . ControllerLoadRetirementRefused) pure observed

verifyRpcBirthControllerRetirement
  :: RpcBirthControllerRetirement -> IO (Either RpcBirthControllerLoadError ())
verifyRpcBirthControllerRetirement (RpcBirthControllerRetirement owner) =
  first ControllerLoadRetirementRefused <$> Retirement.verifyHostOperationRetirement owner

-- A distinct fresh cleanup budget permits only the fixed publisher's exact
-- submitted payloads. Original work clocks stay expired; the public one-shot
-- submission/preparation/terminal fences remain for runtime-epoch retirement.
newtype RpcBirthControllerInputRetirementReceipt
  = RpcBirthControllerInputRetirementReceipt InputRetirement.HostInputRetirementReceipt

retireRpcBirthControllerInputs
  :: Word64
  -> FilePath
  -> RpcBirthControllerRequest
  -> IO (Either RpcBirthControllerLoadError RpcBirthControllerInputRetirementReceipt)
retireRpcBirthControllerInputs cleanupEnd path request = do
  observed <-
    withMatchedControllerRetirement cleanupEnd path request $ \record owner ->
      InputRetirement.retireHostControllerInputs cleanupEnd owner record
  pure $
    observed
      >>= fmap RpcBirthControllerInputRetirementReceipt
        . first ControllerLoadInputRetirementRefused

recoverNeverSentRpcBirthControllerInputs
  :: Word64
  -> RpcBirthControllerRequest
  -> IO (Either RpcBirthControllerLoadError RpcBirthControllerNeverSentRetirementReceipt)
recoverNeverSentRpcBirthControllerInputs cleanupEnd request = do
  recovered <-
    Publication.withRecoveredHostPublicationNeverSent
      Identity.RpcBirthController
      cleanupEnd
      (rpcBirthControllerRequestKey request)
      recover
  pure (either (Left . ControllerLoadPublicationRefused) id recovered)
 where
  recover owner
    | Publication.hostPublicationNeverSentOriginalWorkEnd owner
        /= Identity.hostExecutionWorkEnd (rpcBirthControllerRequestWindow request) =
        pure (Left ControllerLoadPublicationMismatch)
    | otherwise =
        (fmap RpcBirthControllerNeverSentRetirementReceipt . first ControllerLoadInputRetirementRefused)
          <$> InputRetirement.retireNeverSentHostControllerInputs cleanupEnd owner

rpcBirthControllerFieldState :: RpcBirthControllerFieldObservation -> RpcBirthControllerFieldState
rpcBirthControllerFieldState observation
  | ControllerFieldUnobservable `elem` states = ControllerFieldUnobservable
  | ControllerFieldPresent `elem` states = ControllerFieldPresent
  | otherwise = ControllerFieldAbsent
 where
  states = map (rpcBirthControllerFieldRoleState observation) [minBound .. maxBound]

rpcBirthControllerFieldRoleState
  :: RpcBirthControllerFieldObservation -> HostOperationRole -> RpcBirthControllerFieldState
rpcBirthControllerFieldRoleState (RpcBirthControllerFieldObservation inventory) role =
  case Operation.hostOperationPresence inventory role of
    Operation.HostOperationAbsent -> ControllerFieldAbsent
    Operation.HostOperationPresent _ -> ControllerFieldPresent
    Operation.HostOperationUnobservable _ -> ControllerFieldUnobservable

data RpcBirthControllerInputs
  = RpcBirthControllerInputs !Operation.HostControllerProgram !RpcBirthControllerPreparation

data RpcBirthControllerLoadError
  = ControllerLoadArgumentsRefused !Arguments.HostControllerArgumentsError
  | ControllerLoadInputsRefused !Operation.HostOperationError
  | ControllerLoadRequestRefused !RpcBirthControllerRequestError
  | ControllerLoadSettingsRefused !RpcBirthSettingsPayloadError
  | ControllerLoadClockRefused !Clock.RpcBirthHostClockError
  | ControllerLoadBusRefused !Bus.BusError
  | ControllerLoadParentRefused !Kernel.KernelScopeError
  | ControllerLoadRetirementRefused !Retirement.RetirementError
  | ControllerLoadInputRetirementRefused !InputRetirement.InputRetirementError
  | ControllerLoadStreamsRefused !Subprocess.OwnedSubprocessError
  | ControllerLoadIoRefused !IOErrorType !(Maybe Int)
  | ControllerLoadExpired
  | ControllerLoadBudgetInvalid
  | ControllerLoadPublicationMismatch
  | ControllerLoadLaunchBusy
  | ControllerLoadPublicationRefused !Publication.HostControllerPublicationError
  deriving (Eq, Show)

parseRpcBirthControllerArguments
  :: [String] -> Either RpcBirthControllerLoadError RpcBirthControllerArguments
parseRpcBirthControllerArguments =
  first ControllerLoadArgumentsRefused
    . Arguments.parseHostControllerArguments

rpcBirthControllerInputPreparation :: RpcBirthControllerInputs -> RpcBirthControllerPreparation
rpcBirthControllerInputPreparation (RpcBirthControllerInputs _ preparation) = preparation

rpcBirthControllerSourcePath :: RpcBirthControllerInputs -> FilePath
rpcBirthControllerSourcePath (RpcBirthControllerInputs program _) =
  siblingConfigPathForExecutable
    ProductionTier0
    (Operation.hostControllerProgramExecutablePath program)

withRpcBirthControllerInputs
  :: RpcBirthControllerArguments
  -> (RpcBirthControllerInputs -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withRpcBirthControllerInputs arguments action = do
  result <-
    Operation.withPinnedHostControllerProgram
      Identity.RpcBirthController
      ending
      (Arguments.controllerInputFingerprint arguments)
      (Arguments.controllerConfigurationPath arguments)
      (Arguments.controllerRequestPath arguments)
      use
  pure (either (Left . ControllerLoadInputsRefused) id result)
 where
  window = Arguments.controllerOriginalWindow arguments
  ending = Identity.hostExecutionWorkEnd window
  use program = do
    prepared <- withinWork ending (loadInputs arguments program Nothing)
    case prepared of
      Left cause -> pure (Left cause)
      Right inputs -> Right <$> action inputs

loadInputs
  :: Arguments.HostControllerArguments
  -> Operation.HostControllerProgram
  -> Maybe RpcBirthControllerPreparation
  -> IO (Either RpcBirthControllerLoadError RpcBirthControllerInputs)
loadInputs arguments program expected = runExceptT $ do
  bytes <-
    ExceptT (first ControllerLoadInputsRefused <$> Operation.readHostControllerProgramInputs program)
  case expected of
    Nothing -> pure ()
    Just preparation -> do
      config <-
        either
          (throwE . ControllerLoadSettingsRefused)
          pure
          (encodeRpcBirthControllerSettings (rpcBirthControllerPreparedSettings preparation))
      command <-
        either
          (throwE . ControllerLoadRequestRefused)
          pure
          (encodeRpcBirthControllerRequest (rpcBirthControllerPreparedRequest preparation))
      unless
        ( rpcBirthSettingsBytes config == Operation.hostControllerConfigurationBytes bytes
            && rpcBirthControllerRequestBytes command == Operation.hostControllerRequestBytes bytes
        )
        (throwE ControllerLoadPublicationMismatch)
  request <-
    either
      (throwE . ControllerLoadRequestRefused)
      pure
      ( decodeRpcBirthControllerRequest
          (Arguments.controllerOperationKey arguments)
          (Arguments.controllerOriginalWindow arguments)
          (Operation.hostControllerRequestBytes bytes)
      )
  settings <-
    ExceptT
      ( first ControllerLoadSettingsRefused
          <$> decodeRpcBirthControllerSettings
            (rpcBirthCoordinationScope (rpcBirthControllerRequestCoordination request))
            (rpcBirthControllerRequestRoot request)
            (Operation.hostControllerConfigurationBytes bytes)
      )
  preparation <-
    ExceptT (first ControllerLoadRequestRefused <$> prepareRpcBirthControllerRequest request settings)
  let inputs = RpcBirthControllerInputs program preparation
  ExceptT (verifyRpcBirthControllerInputs inputs)
  pure inputs

withinWork
  :: Word64
  -> IO (Either RpcBirthControllerLoadError value)
  -> IO (Either RpcBirthControllerLoadError value)
withinWork ending action = do
  now <- getMonotonicTimeNSec
  if now >= ending || (ending - now) `div` 1000 == 0
    then pure (Left ControllerLoadExpired)
    else do
      let micros = (ending - now) `div` 1000
      if toInteger micros > toInteger (maxBound :: Int)
        then pure (Left ControllerLoadBudgetInvalid)
        else do
          attempted <- try (timeout (fromIntegral micros) action)
          closing <- getMonotonicTimeNSec
          pure $ case attempted of
            Left (err :: IOException) -> Left (ControllerLoadIoRefused (ioe_type err) (fromIntegral <$> ioe_errno err))
            Right result
              | closing >= ending -> Left ControllerLoadExpired
              | otherwise -> maybe (Left ControllerLoadExpired) id result

verifyRpcBirthControllerInputs
  :: RpcBirthControllerInputs -> IO (Either RpcBirthControllerLoadError ())
verifyRpcBirthControllerInputs (RpcBirthControllerInputs program preparation) = runExceptT $ do
  ExceptT (first ControllerLoadInputsRefused <$> Operation.verifyHostControllerProgram intent program)
  void
    ( ExceptT
        ( first ControllerLoadClockRefused
            <$> Clock.observeRpcBirthHostWindow
              (Identity.hostExecutionWorkEnd window, Identity.hostExecutionOuterEnd window)
              (rpcBirthCoordinationDeadline (rpcBirthControllerRequestCoordination request))
        )
    )
  ExceptT (first ControllerLoadRequestRefused <$> verifyRpcBirthControllerRequestDomain request)
 where
  intent = rpcBirthControllerPreparedIntent preparation
  request = rpcBirthControllerPreparedRequest preparation
  window = rpcBirthControllerRequestWindow request

-- This is the existing physical lease, not a new interpretation of manager
-- metadata. It verifies the actual self PIDFD, invocation, cgroups and limits.
withRpcBirthControllerProcesses
  :: RpcBirthControllerInputs
  -> (Subprocess.OperationSubprocesses -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withRpcBirthControllerProcesses inputs@(RpcBirthControllerInputs program preparation) action = do
  checked <- verifyRpcBirthControllerInputs inputs
  case checked of
    Left cause -> pure (Left cause)
    Right () -> do
      uid <- getEffectiveUserID
      opened <-
        Bus.withSystemdBus
          (Identity.hostExecutionOuterEnd window)
          ("/run/user/" ++ show uid ++ "/bus")
          ( \connection -> do
              verifyConnectionDomain connection (rpcBirthControllerPreparedRequest preparation)
              lift (Kernel.withObservedOperationParent connection intent program use)
          )
      pure $ case opened of
        Left cause -> Left (ControllerLoadBusRefused cause)
        Right (Left cause) -> Left (ControllerLoadParentRefused cause)
        Right (Right result) -> result
 where
  intent = rpcBirthControllerPreparedIntent preparation
  window = rpcBirthControllerRequestWindow (rpcBirthControllerPreparedRequest preparation)
  use parent = do
    checked <- verifyRpcBirthControllerInputs inputs
    case checked of
      Left cause -> pure (Right (Left cause))
      Right () -> case Subprocess.operationSubprocesses
        parent
        (rpcBirthControllerCommandLimits preparation)
        (rpcBirthControllerTransportLimits preparation) of
        Left cause -> pure (Right (Left (ControllerLoadStreamsRefused cause)))
        Right processes -> Right . Right <$> action processes

data RpcBirthControllerLaunch
  = RpcBirthControllerLaunch
      !Arguments.HostControllerArguments
      !RpcBirthControllerInputs
      !(Maybe Publication.HostPublicationOwner)
      !(MVar LaunchStage)

data LaunchStage = LaunchReady | LaunchSpent | LaunchClosed

-- Fixed-root exclusive publication preserves files on every callback exit.
-- No completion/submission reply is interpreted as a retirement capability.
withPublishedRpcBirthControllerLaunch
  :: RpcBirthControllerPreparation
  -> (RpcBirthControllerLaunch -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withPublishedRpcBirthControllerLaunch preparation action = do
  result <- publishControllerLaunchWithClosing preparation action (const (pure ()))
  pure (result >>= fst)

data RpcBirthControllerPublicationResult value = RpcBirthControllerPublicationResult
  { rpcBirthPublicationOutcome :: !(Either RpcBirthControllerLoadError value)
  , rpcBirthPublicationDisposition :: !RpcBirthControllerPublicationDisposition
  }

newtype RpcBirthControllerNeverSentRetirementReceipt
  = RpcBirthControllerNeverSentRetirementReceipt InputRetirement.HostNeverSentInputRetirementReceipt

data RpcBirthControllerPublicationDisposition
  = ControllerUnsubmittedInputsRetired !RpcBirthControllerNeverSentRetirementReceipt
  | ControllerUnsubmittedInputsUnresolved !RpcBirthControllerLoadError
  | ControllerSubmittedInputsRetained

withPublishedRpcBirthControllerLaunchRetiringUnsent
  :: Word64
  -> RpcBirthControllerPreparation
  -> (RpcBirthControllerLaunch -> IO value)
  -> IO (Either RpcBirthControllerLoadError (RpcBirthControllerPublicationResult value))
withPublishedRpcBirthControllerLaunchRetiringUnsent cleanupEnd preparation action = do
  result <- publishControllerLaunchWithClosing preparation action close
  pure (fmap (uncurry RpcBirthControllerPublicationResult) result)
 where
  close disposition = case disposition of
    Publication.PublicationPossiblySent -> pure ControllerSubmittedInputsRetained
    Publication.PublicationNeverSent owner -> do
      retired <- InputRetirement.retireNeverSentHostControllerInputs cleanupEnd owner
      pure $ case retired of
        Left cause -> ControllerUnsubmittedInputsUnresolved (ControllerLoadInputRetirementRefused cause)
        Right receipt -> ControllerUnsubmittedInputsRetired (RpcBirthControllerNeverSentRetirementReceipt receipt)

publishControllerLaunchWithClosing
  :: RpcBirthControllerPreparation
  -> (RpcBirthControllerLaunch -> IO value)
  -> (Publication.HostPublicationDisposition -> IO closing)
  -> IO (Either RpcBirthControllerLoadError (Either RpcBirthControllerLoadError value, closing))
publishControllerLaunchWithClosing preparation action closing = runExceptT $ do
  configuration <-
    either
      (throwE . ControllerLoadSettingsRefused)
      pure
      (encodeRpcBirthControllerSettings (rpcBirthControllerPreparedSettings preparation))
  request <-
    either
      (throwE . ControllerLoadRequestRefused)
      pure
      (encodeRpcBirthControllerRequest original)
  ExceptT
    ( first ControllerLoadPublicationRefused
        <$> Publication.withPublishedHostControllerOwner
          Identity.RpcBirthController
          (Identity.hostExecutionWorkEnd (rpcBirthControllerRequestWindow original))
          (rpcBirthControllerRequestKey original)
          (rpcBirthSettingsBytes configuration)
          (rpcBirthControllerRequestBytes request)
          ( \owner ->
              let (config, command) = Publication.hostPublicationPaths owner
               in withRpcBirthControllerLaunchFilesOwned (Just owner) preparation config command action
          )
          closing
    )
 where
  original = rpcBirthControllerPreparedRequest preparation

-- The caller owns these immutable files through independent family absence.
-- Scope release closes descriptors; it never deletes uncertain launch inputs.
withRpcBirthControllerLaunchFiles
  :: RpcBirthControllerPreparation
  -> FilePath
  -> FilePath
  -> (RpcBirthControllerLaunch -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withRpcBirthControllerLaunchFiles = withRpcBirthControllerLaunchFilesOwned Nothing

withRpcBirthControllerLaunchFilesOwned
  :: Maybe Publication.HostPublicationOwner
  -> RpcBirthControllerPreparation
  -> FilePath
  -> FilePath
  -> (RpcBirthControllerLaunch -> IO value)
  -> IO (Either RpcBirthControllerLoadError value)
withRpcBirthControllerLaunchFilesOwned publication expected configuration request action = do
  result <-
    Operation.withCurrentHostControllerProgram
      Identity.RpcBirthController
      ending
      configuration
      request
      use
  pure (either (Left . ControllerLoadInputsRefused) id result)
 where
  original = rpcBirthControllerPreparedRequest expected
  window = rpcBirthControllerRequestWindow original
  ending = Identity.hostExecutionWorkEnd window
  use program = do
    let arguments =
          Arguments.HostControllerArguments
            configuration
            request
            (Operation.hostControllerProgramInputFingerprint program)
            (rpcBirthControllerRequestKey original)
            window
    loaded <- withinWork ending (loadInputs arguments program (Just expected))
    case loaded of
      Left cause -> pure (Left cause)
      Right inputs -> do
        gate <- newMVar LaunchReady
        (Right <$> action (RpcBirthControllerLaunch arguments inputs publication gate))
          `finally` uninterruptibleMask_ (modifyMVar_ gate (const (pure LaunchClosed)))

rpcBirthControllerLaunchArguments
  :: RpcBirthControllerLaunch -> IO (Either RpcBirthControllerLoadError [String])
rpcBirthControllerLaunchArguments (RpcBirthControllerLaunch arguments inputs _ _) = do
  checked <- verifyRpcBirthControllerInputs inputs
  pure (Arguments.renderHostControllerArguments arguments <$ checked)

rpcBirthControllerLaunchUnitNames :: RpcBirthControllerLaunch -> [String]
rpcBirthControllerLaunchUnitNames (RpcBirthControllerLaunch _ (RpcBirthControllerInputs _ preparation) _ _) =
  map
    (Operation.hostOperationUnitName (rpcBirthControllerPreparedIntent preparation))
    [minBound .. maxBound]

-- Submission is not a running descriptor, Authority admission or absence proof.
submitRpcBirthControllerLaunch
  :: RpcBirthControllerLaunch -> IO (Either RpcBirthControllerLoadError ())
submitRpcBirthControllerLaunch (RpcBirthControllerLaunch _ inputs publication gate) = mask $ \restore -> do
  acquired <- tryTakeMVar gate
  case acquired of
    Nothing -> pure (Left ControllerLoadLaunchBusy)
    Just LaunchClosed ->
      putMVar gate LaunchClosed
        >> pure
          ( Left
              (ControllerLoadInputsRefused (Operation.HostOperationInputsRefused Inputs.ControllerInputsClosed))
          )
    Just LaunchSpent ->
      putMVar gate LaunchSpent
        >> pure (Left (ControllerLoadInputsRefused Operation.HostOperationAlreadyAttempted))
    Just LaunchReady ->
      restore (submitWithPublication publication inputs) `finally` putMVar gate LaunchSpent

submitWithPublication
  :: Maybe Publication.HostPublicationOwner
  -> RpcBirthControllerInputs
  -> IO (Either RpcBirthControllerLoadError ())
submitWithPublication publication inputs = case publication of
  Nothing -> submitUsingPublication Nothing inputs
  Just owner -> do
    submitted <-
      Publication.withHostPublicationSubmission
        owner
        (\permit -> submitUsingPublication (Just permit) inputs)
    pure (either (Left . ControllerLoadPublicationRefused) id submitted)

submitUsingPublication
  :: Maybe Publication.HostPublicationSubmission
  -> RpcBirthControllerInputs
  -> IO (Either RpcBirthControllerLoadError ())
submitUsingPublication publication inputs@(RpcBirthControllerInputs program preparation) = do
  checked <- verifyRpcBirthControllerInputs inputs
  case checked of
    Left cause -> pure (Left cause)
    Right () -> do
      uid <- getEffectiveUserID
      result <-
        Bus.withSystemdBus
          (Identity.hostExecutionOuterEnd window)
          ("/run/user/" ++ show uid ++ "/bus")
          ( \connection -> do
              verifyConnectionDomain connection (rpcBirthControllerPreparedRequest preparation)
              lift $ case publication of
                Nothing -> Operation.submitHostOperationFamily connection intent program
                Just permit -> Operation.submitPublishedHostOperationFamily permit connection intent program
          )
      pure $ case result of
        Left cause -> Left (ControllerLoadBusRefused cause)
        Right submitted -> first ControllerLoadInputsRefused submitted
 where
  intent = rpcBirthControllerPreparedIntent preparation
  window = rpcBirthControllerRequestWindow (rpcBirthControllerPreparedRequest preparation)

verifyConnectionDomain :: Bus.BusConnection -> RpcBirthControllerRequest -> Bus.BusAction ()
verifyConnectionDomain connection request = do
  current <-
    Bus.observeManagerDomain
      ( Bus.systemdBusWithin
          (Identity.hostExecutionWorkEnd (rpcBirthControllerRequestWindow request))
          connection
      )
  unless (current == rpcBirthControllerRequestDomain request) (throwE Bus.BusManagerIdentityRefused)
