{-# LANGUAGE ImportQualifiedPost #-}

-- | The closed operation-wide request and its complete read-only field.
-- Submission is neither physical placement nor Authority admission. The
-- controller entrypoint and kernel/transport owners must establish those.
module Prodbox.Subprocess.HostOperationFamily
  ( HostOperationIntent
  , HostOperationRole (..)
  , HostOperationProcessRole (..)
  , hostOperationProcessRole
  , HostOperationError (..)
  , HostControllerProgram
  , HostOperationHelperBounds
  , hostOperationHelperBounds
  , withCurrentHostControllerProgram
  , withPinnedHostControllerProgram
  , verifyHostControllerProgram
  , HostControllerInputFingerprint
  , parseHostControllerInputFingerprint
  , hostControllerInputFingerprintText
  , hostControllerProgramInputFingerprint
  , hostControllerProgramExecutablePath
  , HostControllerInputBytes
  , readHostControllerProgramInputs
  , hostControllerConfigurationBytes
  , hostControllerRequestBytes
  , newHostOperationIntent
  , hostOperationUnitName
  , hostOperationRuntimeDirectory
  , hostOperationDescription
  , hostOperationPlan
  , hostOperationKind
  , hostOperationKey
  , hostOperationWindow
  , hostOperationHelperStartMicros
  , hostOperationHelperStopMicros
  , HostOperationDeclaration
  , HostOperationChildDeclaration (..)
  , hostOperationTimerInvocation
  , hostOperationChildDeclarations
  , verifyHostOperationDeclaration
  , verifyHostOperationCoreDeclaration
  , observeHostOperationIdleChild
  , observeHostOperationIdleChildBefore
  , submitHostOperationFamily
  , submitPublishedHostOperationFamily
  , submitPublishedHostOperationFamilyWithStdin
  , HostSubmissionCausalClosure
  , observeHostSubmissionCausalClosure
  , withHostSubmissionCausalClosure
  , hostSubmissionCausalMatches
  , HostOperationInventory
  , HostOperationPresence (..)
  , HostOperationField
  , hostOperationField
  , hostOperationFieldUnitName
  , hostControllerSubmissionField
  , hostOperationFieldRuntimeDirectory
  , observeHostOperationField
  , observeHostOperationFamily
  , hostOperationPresence
  , hostOperationAbsent
  ) where

import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE, withExceptT)
import Data.List (nub)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputs
  ( HostControllerInputBytes
  , HostControllerInputError
  , HostControllerInputFingerprint
  , hostControllerConfigurationBytes
  , hostControllerInputFingerprintText
  , hostControllerRequestBytes
  , parseHostControllerInputFingerprint
  )
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostControllerStdin qualified as Stdin
import Prodbox.Subprocess.OneShotAttempt qualified as Attempt
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider

data HostOperationRole
  = OperationController
  | OperationSlice
  | OperationTimer
  | OperationExpiry
  | OperationCommand
  | OperationTransport
  deriving (Bounded, Enum, Eq, Show)

data HostOperationProcessRole = OperationCommandProcess | OperationTransportProcess
  deriving (Eq, Show)

hostOperationProcessRole :: HostOperationProcessRole -> HostOperationRole
hostOperationProcessRole role = case role of
  OperationCommandProcess -> OperationCommand
  OperationTransportProcess -> OperationTransport

data HostOperationError
  = HostOperationExpired
  | HostOperationInvalidWindow
  | HostOperationProgramMismatch
  | HostOperationProgramUnavailable
  | HostOperationInputsRefused !HostControllerInputError
  | HostOperationAlreadyAttempted
  | HostOperationFieldNotAbsent !HostOperationInventory
  | HostOperationDeclarationRefused !HostOperationRole
  | HostOperationManagerRefused !BusError
  | HostOperationProviderRefused !Provider.ProviderError
  | HostOperationPublicationRefused !Publication.HostControllerPublicationError
  | HostOperationStdinRefused !Stdin.HostControllerStdinError
  | HostSubmissionUnqualified
  | HostSubmissionProviderMismatch
  | HostSubmissionSenderPresent
  deriving (Eq, Show)

data HostOperationHelperBounds = HostOperationHelperBounds !Word64 !Word64

hostOperationHelperBounds :: Word64 -> Word64 -> Maybe HostOperationHelperBounds
hostOperationHelperBounds start stop
  | start > 0 && start < maxBound && stop > 0 && stop < maxBound =
      Just (HostOperationHelperBounds start stop)
  | otherwise = Nothing

data HostOperationIntent
  = HostOperationIntent
      !Identity.HostControllerKind
      !Host.HostExecutionTransportPlan
      !HostOperationHelperBounds
      !Identity.HostExecutionKey
      !Identity.HostExecutionWindow
      !Attempt.OneShotAttempt

-- No caller-selected executable, mode, argument tail or environment callback.
-- The scoped owner holds exact executable/input descriptors. Payload schema,
-- original request/Authority admission and the closed dispatcher remain separate.
data HostControllerProgram
  = HostControllerProgram !Identity.HostControllerKind !Inputs.HostControllerInputs

hostControllerProgramExecutablePath :: HostControllerProgram -> FilePath
hostControllerProgramExecutablePath (HostControllerProgram _ inputs) = Inputs.hostControllerExecutablePath inputs

withCurrentHostControllerProgram
  :: Identity.HostControllerKind
  -> Word64
  -> FilePath
  -> FilePath
  -> (HostControllerProgram -> IO value)
  -> IO (Either HostOperationError value)
withCurrentHostControllerProgram kind ending configuration request action =
  either (Left . HostOperationInputsRefused) Right
    <$> Inputs.withHostControllerInputs ending configuration request (action . HostControllerProgram kind)

withPinnedHostControllerProgram
  :: Identity.HostControllerKind
  -> Word64
  -> HostControllerInputFingerprint
  -> FilePath
  -> FilePath
  -> (HostControllerProgram -> IO value)
  -> IO (Either HostOperationError value)
withPinnedHostControllerProgram kind ending expected configuration request action =
  either (Left . HostOperationInputsRefused) Right
    <$> Inputs.withPinnedHostControllerInputs
      ending
      expected
      configuration
      request
      (action . HostControllerProgram kind)

hostControllerProgramInputFingerprint :: HostControllerProgram -> HostControllerInputFingerprint
hostControllerProgramInputFingerprint (HostControllerProgram _ inputs) = Inputs.hostControllerInputFingerprint inputs

readHostControllerProgramInputs
  :: HostControllerProgram -> IO (Either HostOperationError HostControllerInputBytes)
readHostControllerProgramInputs (HostControllerProgram _ inputs) =
  either (Left . HostOperationInputsRefused) Right <$> Inputs.readHostControllerInputs inputs

verifyHostControllerProgram
  :: HostOperationIntent -> HostControllerProgram -> IO (Either HostOperationError ())
verifyHostControllerProgram intent (HostControllerProgram kind inputs)
  | kind /= hostOperationKind intent = pure (Left HostOperationProgramMismatch)
  | Inputs.hostControllerInputWorkEnd inputs
      /= Identity.hostExecutionWorkEnd (hostOperationWindow intent) =
      pure (Left HostOperationInvalidWindow)
  | otherwise =
      either (Left . HostOperationInputsRefused) Right <$> Inputs.verifyHostControllerInputs inputs

newHostOperationIntent
  :: Identity.HostControllerKind
  -> Host.HostExecutionTransportPlan
  -> HostOperationHelperBounds
  -> Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> IO (Either HostOperationError HostOperationIntent)
newHostOperationIntent kind plan helper@(HostOperationHelperBounds start stop) key window = do
  now <- getMonotonicTimeNSec
  if now >= Identity.hostExecutionWorkEnd window
    then pure (Left HostOperationExpired)
    else
      if toInteger (Identity.hostExecutionOuterEnd window) - toInteger now
        > toInteger (Host.hostExecutionMaximumChildMicros plan) * 1000
        || (toInteger start + toInteger stop) * 1000
          > toInteger (Identity.hostExecutionStopEnd window) - toInteger (Identity.hostExecutionHardEnd window)
        then pure (Left HostOperationInvalidWindow)
        else Right . HostOperationIntent kind plan helper key window <$> Attempt.newOneShotAttempt

hostOperationUnitName :: HostOperationIntent -> HostOperationRole -> String
hostOperationUnitName = fieldUnitName . intentField

-- A read-only name selector. It carries no plan, work window or create attempt.
data HostOperationField = HostOperationField !Identity.HostControllerKind !Identity.HostExecutionKey

hostOperationField :: Identity.HostControllerKind -> Identity.HostExecutionKey -> HostOperationField
hostOperationField = HostOperationField

intentField :: HostOperationIntent -> HostOperationField
intentField intent = hostOperationField (hostOperationKind intent) (hostOperationKey intent)

hostControllerSubmissionField :: Inputs.HostControllerSubmissionRecord -> HostOperationField
hostControllerSubmissionField record =
  hostOperationField
    (Inputs.hostControllerSubmissionKind record)
    (Inputs.hostControllerSubmissionKey record)

hostOperationFieldUnitName :: HostOperationField -> HostOperationRole -> String
hostOperationFieldUnitName = fieldUnitName

fieldUnitName :: HostOperationField -> HostOperationRole -> String
fieldUnitName (HostOperationField kind key) role = case role of
  OperationController -> prefix <> "controller-" <> text <> ".service"
  OperationSlice -> Identity.hostControllerKindSliceName kind
  OperationTimer -> prefix <> text <> "-expiry.timer"
  OperationExpiry -> prefix <> text <> "-expiry.service"
  OperationCommand -> commandPrefix <> text <> ".scope"
  OperationTransport -> transportPrefix <> text <> ".scope"
 where
  text = Identity.hostExecutionKeyText key
  prefix = Identity.hostControllerKindPrefix kind
  (commandPrefix, transportPrefix) = case kind of
    Identity.RpcBirthController -> ("prodbox-owned-", "prodbox-transport-")
    Identity.OrdinaryCascadeController -> ("prodbox-cascade-owned-", "prodbox-cascade-transport-")

hostOperationRuntimeDirectory :: HostOperationIntent -> String
hostOperationRuntimeDirectory = hostOperationFieldRuntimeDirectory . intentField

hostOperationFieldRuntimeDirectory :: HostOperationField -> String
hostOperationFieldRuntimeDirectory (HostOperationField kind key) =
  Identity.hostControllerKindPrefix kind <> Identity.hostExecutionKeyText key

hostOperationKind :: HostOperationIntent -> Identity.HostControllerKind
hostOperationKind (HostOperationIntent kind _ _ _ _ _) = kind

hostOperationPlan :: HostOperationIntent -> Host.HostExecutionTransportPlan
hostOperationPlan (HostOperationIntent _ plan _ _ _ _) = plan

hostOperationKey :: HostOperationIntent -> Identity.HostExecutionKey
hostOperationKey (HostOperationIntent _ _ _ key _ _) = key

hostOperationWindow :: HostOperationIntent -> Identity.HostExecutionWindow
hostOperationWindow (HostOperationIntent _ _ _ _ window _) = window

hostOperationHelperStartMicros, hostOperationHelperStopMicros :: HostOperationIntent -> Word64
hostOperationHelperStartMicros (HostOperationIntent _ _ (HostOperationHelperBounds start _) _ _ _) = start
hostOperationHelperStopMicros (HostOperationIntent _ _ (HostOperationHelperBounds _ stop) _ _ _) = stop

hostOperationDescription :: HostOperationIntent -> String
hostOperationDescription (HostOperationIntent kind plan (HostOperationHelperBounds start stop) key window _) =
  descriptionPrefix
    <> Identity.hostExecutionKeyText key
    <> " "
    <> unwords (map (show . ($ window)) clocks)
    <> " resources "
    <> unwords (map (show . ($ plan)) resources)
    <> " transport "
    <> unwords (map (show . ($ Host.hostExecutionTransportLimits plan)) transport)
    <> " heap "
    <> show
      ( Runtime.positiveBytesValue
          (Runtime.runtimeMemoryHeapCapBytes (Host.hostExecutionRuntimeMemory plan))
      )
    <> " child-window "
    <> show (Host.hostExecutionMaximumChildMicros plan)
    <> " helper-window "
    <> show start
    <> " "
    <> show stop
 where
  descriptionPrefix = case kind of
    Identity.RpcBirthController -> "prodbox rpc birth operation "
    Identity.OrdinaryCascadeController -> "prodbox ordinary cascade operation "
  clocks =
    [ Identity.hostExecutionOuterEnd
    , Identity.hostExecutionWorkEnd
    , Identity.hostExecutionHardEnd
    , Identity.hostExecutionStopEnd
    , Identity.hostExecutionFinishEnd
    ]
  resources =
    [ Host.hostExecutionParentMemoryBytes
    , Host.hostExecutionChildMemoryBytes
    , Host.hostExecutionHelperMemoryBytes
    , Host.hostExecutionSliceMemoryBytes
    , Host.hostExecutionParentCpuUsecPerSec
    , Host.hostExecutionChildCpuUsecPerSec
    , Host.hostExecutionHelperCpuUsecPerSec
    , Host.hostExecutionSliceCpuUsecPerSec
    , Host.hostExecutionParentTasks
    , Host.hostExecutionChildTasks
    , Host.hostExecutionHelperTasks
    , Host.hostExecutionSliceTasks
    ]
  transport = [Host.hostTransportMemoryBytes, Host.hostTransportCpuUsecPerSec, Host.hostTransportTasks]

data HostOperationPresence
  = HostOperationAbsent
  | HostOperationPresent !InvocationObservation
  | HostOperationUnobservable !BusError
  deriving (Eq, Show)

data HostOperationInventory
  = HostOperationInventory
      !HostOperationPresence
      !HostOperationPresence
      !HostOperationPresence
      !HostOperationPresence
      !HostOperationPresence
      !HostOperationPresence
  deriving (Eq, Show)

observeHostOperationFamily
  :: BusConnection -> HostOperationIntent -> BusAction HostOperationInventory
observeHostOperationFamily connection intent =
  observeHostOperationField connection (intentField intent)

observeHostOperationField
  :: BusConnection -> HostOperationField -> BusAction HostOperationInventory
observeHostOperationField connection field =
  HostOperationInventory
    <$> observe OperationController
    <*> observe OperationSlice
    <*> observe OperationTimer
    <*> observe OperationExpiry
    <*> observe OperationCommand
    <*> observe OperationTransport
 where
  observe role = do
    let expected = fieldUnitName field role
    found <-
      lift
        ( runExceptT
            (callManager connection GetUnit (\message -> appendString message expected) (`readString` 'o'))
        )
    case found of
      Left (BusMethodRefused 2) -> pure HostOperationAbsent
      Left cause -> pure (HostOperationUnobservable cause)
      Right path -> do
        identity <- lift $ runExceptT $ do
          actual <- property path "Id" readVariantString
          unless (actual == expected) (throwE BusMalformedReply)
          property path "InvocationID" readVariantInvocationObservation
        pure (either HostOperationUnobservable HostOperationPresent identity)
  property path name = callManager connection (ReadUnitProperty path) $ \message -> do
    appendString message "org.freedesktop.systemd1.Unit"
    appendString message name

hostOperationPresence :: HostOperationInventory -> HostOperationRole -> HostOperationPresence
hostOperationPresence (HostOperationInventory controller slice timer expiry command transport) role = case role of
  OperationController -> controller
  OperationSlice -> slice
  OperationTimer -> timer
  OperationExpiry -> expiry
  OperationCommand -> command
  OperationTransport -> transport

hostOperationAbsent :: HostOperationInventory -> Bool
hostOperationAbsent
  ( HostOperationInventory
      HostOperationAbsent
      HostOperationAbsent
      HostOperationAbsent
      HostOperationAbsent
      HostOperationAbsent
      HostOperationAbsent
    ) = True
hostOperationAbsent _ = False

data HostOperationChildDeclaration = OperationChildAbsent | OperationChildNotFound
  deriving (Eq, Show)

-- Declaration identity only. Kernel ownership and runtime admission are separate.
data HostOperationDeclaration
  = HostOperationDeclaration !InvocationId !HostOperationChildDeclaration !HostOperationChildDeclaration

hostOperationTimerInvocation :: HostOperationDeclaration -> InvocationId
hostOperationTimerInvocation (HostOperationDeclaration timer _ _) = timer

hostOperationChildDeclarations
  :: HostOperationDeclaration -> (HostOperationChildDeclaration, HostOperationChildDeclaration)
hostOperationChildDeclarations (HostOperationDeclaration _ command transport) = (command, transport)

verifyHostOperationDeclaration
  :: BusConnection
  -> HostOperationIntent
  -> HostControllerProgram
  -> InvocationPath
  -> IO (Either HostOperationError HostOperationDeclaration)
verifyHostOperationDeclaration original intent program controller = runExceptT $ do
  timer <- ExceptT (verifyHostOperationCoreDeclaration original intent program controller)
  command <- ExceptT (observeHostOperationIdleChild original intent OperationCommandProcess)
  transport <- ExceptT (observeHostOperationIdleChild original intent OperationTransportProcess)
  pure (HostOperationDeclaration timer command transport)

-- The immutable alarm/controller declaration is independent of live child roles.
-- Its invocation identifier is metadata, not a placement or effect capability.
verifyHostOperationCoreDeclaration
  :: BusConnection
  -> HostOperationIntent
  -> HostControllerProgram
  -> InvocationPath
  -> IO (Either HostOperationError InvocationId)
verifyHostOperationCoreDeclaration original intent program controller = runExceptT $ do
  ExceptT (verifyHostControllerProgram intent program)
  let controllerPath = invocationPathText controller
      (executable, arguments) = controllerCommand intent program
  declared OperationController controllerPath "active"
  invocation <- property controllerPath "Unit" "InvocationID" readVariantInvocationId
  check OperationController (invocation == invocationPathId controller)
  property controllerPath "Service" "ExecStart" (readVariantExactCommand executable arguments)
  noHooks controllerPath
  dependencies
    OperationController
    controllerPath
    "Requires"
    [name OperationTimer, name OperationSlice]
    managerPrerequisites
  wants <- property controllerPath "Unit" "Wants" (readVariantStrings 16)
  check OperationController (null wants)
  timerPath <- unit OperationTimer
  declared OperationTimer timerPath "active"
  timerInvocation <- property timerPath "Unit" "InvocationID" readVariantInvocationId
  timerAlias <-
    manager $
      callManager
        connection
        (GetUnitByInvocationID timerInvocation)
        (const (pure ()))
        (readInvocationPath timerInvocation)
  let timer = invocationPathText timerAlias
      expiry = Identity.hostExecutionHardEnd window `div` 1000
  declared OperationTimer timer "active"
  target <- property timer "Timer" "Unit" readVariantString
  check OperationTimer (target == name OperationExpiry)
  property timer "Timer" "TimersMonotonic" (readVariantOriginalBootTimer expiry)
  property timer "Timer" "TimersCalendar" readVariantNoCalendarTimers
  mapM_
    ( \(label, expected) -> do
        actual <- property timer "Timer" label readVariantWord64
        check OperationTimer (actual == expected)
    )
    [ ("NextElapseUSecMonotonic", expiry)
    , ("AccuracyUSec", 1)
    , ("RandomizedDelayUSec", 0)
    , ("LastTriggerUSecMonotonic", 0)
    ]
  mapM_
    ( \label -> do
        actual <- property timer "Timer" label readVariantBoolean
        check OperationTimer (not actual)
    )
    ["WakeSystem", "Persistent", "RemainAfterElapse", "OnClockChange", "OnTimezoneChange"]
  dependencies OperationTimer timer "Requires" [name OperationSlice] []
  helper <- unit OperationExpiry
  declared OperationExpiry helper "inactive"
  helperInvocation <- property helper "Unit" "InvocationID" readVariantInvocationObservation
  helperKind <- property helper "Service" "Type" readVariantString
  helperSlice <- property helper "Service" "Slice" readVariantString
  helperRestart <- property helper "Service" "Restart" readVariantString
  helperPid <- property helper "Service" "MainPID" readVariantWord32
  check
    OperationExpiry
    ( helperInvocation == InvocationAbsent
        && helperKind == "oneshot"
        && helperSlice == name OperationSlice
        && helperRestart == "no"
        && helperPid == 0
    )
  property helper "Service" "ExecStart" readVariantDormantNoOp
  noHooks helper
  let victims = [name OperationController]
  dependencies OperationExpiry helper "Conflicts" victims ["shutdown.target"]
  dependencies OperationExpiry helper "Before" victims ["shutdown.target"]
  mapM_
    ( \(label, expected) -> do
        actual <- property helper "Service" label readVariantWord64
        check OperationExpiry (actual == expected)
    )
    [ ("MemoryMax", Host.hostExecutionHelperMemoryBytes plan)
    , ("MemorySwapMax", 0)
    , ("TasksMax", Host.hostExecutionHelperTasks plan)
    , ("CPUQuotaPerSecUSec", Host.hostExecutionHelperCpuUsecPerSec plan)
    , ("TimeoutStartUSec", hostOperationHelperStartMicros intent)
    , ("TimeoutStopUSec", hostOperationHelperStopMicros intent)
    ]
  slice <- unit OperationSlice
  declared OperationSlice slice "active"
  closingTimer <- property timer "Unit" "InvocationID" readVariantInvocationId
  check OperationTimer (closingTimer == timerInvocation)
  pure timerInvocation
 where
  plan = hostOperationPlan intent
  window = hostOperationWindow intent
  connection = systemdBusWithin (Identity.hostExecutionWorkEnd window) original
  name = hostOperationUnitName intent
  manager action = ExceptT $ either (Left . HostOperationManagerRefused) Right <$> runExceptT action
  check role condition = unless condition (throwE (HostOperationDeclarationRefused role))
  unit role =
    manager $
      callManager connection GetUnit (\message -> appendString message (name role)) (`readString` 'o')
  property path interface label decode =
    manager $
      callManager
        connection
        (ReadUnitProperty path)
        ( \message -> appendString message ("org.freedesktop.systemd1." <> interface) >> appendString message label
        )
        decode
  declared role path expectedState = do
    identifier <- property path "Unit" "Id" readVariantString
    description <- property path "Unit" "Description" readVariantString
    transient <- property path "Unit" "Transient" readVariantBoolean
    state <- property path "Unit" "ActiveState" readVariantString
    load <- property path "Unit" "LoadState" readVariantString
    job <- property path "Unit" "Job" readVariantJob
    check
      role
      ( identifier == name role
          && description == hostOperationDescription intent <> " " <> show role
          && transient
          && state == expectedState
          && load == "loaded"
          && job == UnitJobAbsent
      )
  dependencies role path label required allowed = do
    actual <- property path "Unit" label (readVariantStrings 16)
    check
      role
      ( length actual == length (nub actual)
          && all (`elem` actual) required
          && all (`elem` (required <> allowed)) actual
      )
  managerPrerequisites = ["basic.target", "sysinit.target", "-.slice"]
  noHooks path =
    mapM_
      (\label -> property path "Service" label readVariantNoExecStop)
      ["ExecCondition", "ExecStartPre", "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost"]

observeHostOperationIdleChild
  :: BusConnection
  -> HostOperationIntent
  -> HostOperationProcessRole
  -> IO (Either HostOperationError HostOperationChildDeclaration)
observeHostOperationIdleChild original intent =
  observeHostOperationIdleChildBefore
    (Identity.hostExecutionWorkEnd (hostOperationWindow intent))
    original
    intent

observeHostOperationIdleChildBefore
  :: Word64
  -> BusConnection
  -> HostOperationIntent
  -> HostOperationProcessRole
  -> IO (Either HostOperationError HostOperationChildDeclaration)
observeHostOperationIdleChildBefore requested original intent process = runExceptT $ do
  found <-
    lift $
      runExceptT
        (callManager connection GetUnit (\message -> appendString message name) (`readString` 'o'))
  case found of
    Left (BusMethodRefused 2) -> pure OperationChildAbsent
    Left cause -> throwE (HostOperationManagerRefused cause)
    Right path -> do
      identifier <- property path "Unit" "Id" readVariantString
      load <- property path "Unit" "LoadState" readVariantString
      state <- property path "Unit" "ActiveState" readVariantString
      invocation <- property path "Unit" "InvocationID" readVariantInvocationObservation
      job <- property path "Unit" "Job" readVariantJob
      group <- property path "Scope" "ControlGroup" readVariantString
      unless
        ( identifier == name
            && load == "not-found"
            && state == "inactive"
            && invocation == InvocationAbsent
            && job == UnitJobAbsent
            && null group
        )
        (throwE (HostOperationDeclarationRefused role))
      pure OperationChildNotFound
 where
  connection =
    systemdBusWithin
      (min requested (Identity.hostExecutionFinishEnd (hostOperationWindow intent)))
      original
  role = hostOperationProcessRole process
  name = hostOperationUnitName intent role
  property path interface label decode =
    ExceptT $
      either (Left . HostOperationManagerRefused) Right
        <$> runExceptT
          ( callManager
              connection
              (ReadUnitProperty path)
              ( \message -> appendString message ("org.freedesktop.systemd1." <> interface) >> appendString message label
              )
              decode
          )

submitHostOperationFamily
  :: BusConnection -> HostOperationIntent -> HostControllerProgram -> IO (Either HostOperationError ())
submitHostOperationFamily = submitHostOperationFamilyWithPublication Nothing Nothing

submitPublishedHostOperationFamily
  :: Publication.HostPublicationSubmission
  -> BusConnection
  -> HostOperationIntent
  -> HostControllerProgram
  -> IO (Either HostOperationError ())
submitPublishedHostOperationFamily permit = submitHostOperationFamilyWithPublication (Just permit) Nothing

-- Descriptor delivery remains inside the published ordinary-family owner.
-- A manager reply alone grants neither running placement nor admission.
submitPublishedHostOperationFamilyWithStdin
  :: Publication.HostPublicationSubmission
  -> Stdin.HostControllerStdin
  -> BusConnection
  -> HostOperationIntent
  -> HostControllerProgram
  -> IO (Either HostOperationError ())
submitPublishedHostOperationFamilyWithStdin permit input =
  submitHostOperationFamilyWithPublication (Just permit) (Just input)

submitHostOperationFamilyWithPublication
  :: Maybe Publication.HostPublicationSubmission
  -> Maybe Stdin.HostControllerStdin
  -> BusConnection
  -> HostOperationIntent
  -> HostControllerProgram
  -> IO (Either HostOperationError ())
submitHostOperationFamilyWithPublication publication input original intent@(HostOperationIntent _ _ _ _ window attempted) program = do
  admitted <- Attempt.claimOneShotAttempt attempted
  now <- getMonotonicTimeNSec
  if not admitted
    then pure (Left HostOperationAlreadyAttempted)
    else runExceptT $ do
      let HostControllerProgram _ originalInputs = program
      case publication of
        Just permit ->
          unless
            (Publication.hostPublicationSubmissionKind permit == hostOperationKind intent)
            (throwE (HostOperationPublicationRefused Publication.ControllerPublicationSubmissionMismatch))
        Nothing ->
          when
            ( any
                Publication.hostControllerPublicationPathReserved
                [ Inputs.hostControllerConfigurationPath originalInputs
                , Inputs.hostControllerRequestPath originalInputs
                ]
            )
            (throwE (HostOperationPublicationRefused Publication.ControllerPublicationSubmissionMismatch))
      when (now >= Identity.hostExecutionWorkEnd window) (throwE HostOperationExpired)
      case input of
        Nothing -> pure ()
        Just held -> do
          unless
            (hostOperationKind intent == Identity.OrdinaryCascadeController)
            (throwE (HostOperationStdinRefused Stdin.ControllerStdinBindingMismatch))
          ExceptT
            ( fmap
                (either (Left . HostOperationStdinRefused) Right)
                (Stdin.verifyHostControllerStdin (hostOperationKey intent) window held)
            )
      unless
        (Identity.hostExecutionOuterEnd window <= systemdBusDeadline original)
        (throwE HostOperationInvalidWindow)
      ExceptT (verifyHostControllerProgram intent program)
      inventory <- withExceptT HostOperationManagerRefused (observeHostOperationFamily connection intent)
      unless (hostOperationAbsent inventory) (throwE (HostOperationFieldNotAbsent inventory))
      ExceptT (verifyHostControllerProgram intent program)
      domain <- withExceptT HostOperationManagerRefused (observeManagerDomain connection)
      sender <- withExceptT HostOperationManagerRefused (observeBusSender connection)
      qualified <- lift $ Provider.withQualifiedProvider connection $ \provider -> runExceptT $ do
        unless (Provider.qualifiedProviderDomain provider == domain) (throwE HostSubmissionProviderMismatch)
        let HostControllerProgram _ inputs = program
        _ <-
          ExceptT $
            either (Left . HostOperationInputsRefused) Right
              <$> Inputs.registerHostControllerSubmission
                (hostOperationKind intent)
                inputs
                (hostOperationKey intent)
                window
                domain
                sender
                provider
        ExceptT
          ( fmap
              (either (Left . HostOperationProviderRefused) Right)
              (Provider.verifyQualifiedProvider provider)
          )
        closingDomain <- withExceptT HostOperationManagerRefused (observeManagerDomain connection)
        unless (closingDomain == domain) (throwE (HostOperationManagerRefused BusManagerIdentityRefused))
        ExceptT (verifyHostControllerProgram intent program)
        sending <- lift getMonotonicTimeNSec
        when (sending >= Identity.hostExecutionWorkEnd window) (throwE HostOperationExpired)
        case publication of
          Nothing -> pure ()
          Just permit ->
            ExceptT $
              fmap (either (Left . HostOperationPublicationRefused) Right) $
                Publication.markHostPublicationPossibleSend
                  permit
                  (hostOperationKind intent)
                  (hostOperationKey intent)
                  (Identity.hostExecutionWorkEnd window)
                  (Inputs.hostControllerConfigurationPath inputs)
                  (Inputs.hostControllerRequestPath inputs)
        _ <-
          withExceptT HostOperationManagerRefused $
            callManager
              connection
              StartTransientUnit
              (buildFamily sending intent program input)
              (`readString` 'o')
        case input of
          Nothing -> pure ()
          Just held ->
            ExceptT
              (fmap (either (Left . HostOperationStdinRefused) Right) (Stdin.deliverHostControllerStdin held))
        pure ()
      either (throwE . HostOperationProviderRefused) (either throwE pure) qualified
 where
  connection = systemdBusWithin (Identity.hostExecutionWorkEnd window) original

-- The old sender can never submit another frame on this bus instance. Under
-- the exact recorded native contract, a later pinned manager read establishes
-- completed method processing. Jobs, kernel/alarm state and files are separate.
newtype HostSubmissionCausalClosure = HostSubmissionCausalClosure Inputs.HostControllerSubmissionRecord

hostSubmissionCausalMatches
  :: HostSubmissionCausalClosure -> Inputs.HostControllerSubmissionRecord -> Bool
hostSubmissionCausalMatches (HostSubmissionCausalClosure original) = (== original)

observeHostSubmissionCausalClosure
  :: BusConnection
  -> Inputs.HostControllerSubmissionRecord
  -> IO (Either HostOperationError HostSubmissionCausalClosure)
observeHostSubmissionCausalClosure connection record =
  withHostSubmissionCausalClosure connection record (\_ proof -> pure proof)

-- The physical retirement owner borrows the same held provider; it cannot
-- recreate historical qualification from decoded provenance or a later Ping.
withHostSubmissionCausalClosure
  :: BusConnection
  -> Inputs.HostControllerSubmissionRecord
  -> (Provider.QualifiedProvider -> HostSubmissionCausalClosure -> IO value)
  -> IO (Either HostOperationError value)
withHostSubmissionCausalClosure connection record action = case Inputs.hostControllerSubmissionProvider record of
  Nothing -> pure (Left HostSubmissionUnqualified)
  Just binding -> do
    observed <- Provider.withQualifiedProvider connection $ \provider -> do
      checked <- runExceptT (qualify provider binding)
      case checked of
        Left cause -> pure (Left cause)
        Right proof -> Right <$> action provider proof
    pure (either (Left . HostOperationProviderRefused) id observed)
 where
  qualify provider binding = do
    unless
      ( binding == Provider.qualifiedProviderBinding provider
          && Inputs.hostControllerSubmissionDomain record == Provider.qualifiedProviderDomain provider
      )
      (throwE HostSubmissionProviderMismatch)
    let sender = Inputs.hostControllerSubmissionSender record
        readPresence = withExceptT HostOperationManagerRefused (observeBusNamePresence connection sender)
    presence <- readPresence
    unless (presence == BusNameAbsent) (throwE HostSubmissionSenderPresent)
    frontier <-
      withExceptT HostOperationManagerRefused $
        observeHostOperationField
          connection
          (hostControllerSubmissionField record)
    mapM_ (requireObservable frontier) [minBound .. maxBound]
    ExceptT
      ( fmap
          (either (Left . HostOperationProviderRefused) Right)
          (Provider.verifyQualifiedProvider provider)
      )
    closing <- readPresence
    unless (closing == BusNameAbsent) (throwE HostSubmissionSenderPresent)
    pure (HostSubmissionCausalClosure record)
  requireObservable inventory role = case hostOperationPresence inventory role of
    HostOperationUnobservable cause -> throwE (HostOperationManagerRefused cause)
    HostOperationAbsent -> pure ()
    HostOperationPresent _ -> pure ()

buildFamily
  :: Word64
  -> HostOperationIntent
  -> HostControllerProgram
  -> Maybe Stdin.HostControllerStdin
  -> BusMessage
  -> BusAction ()
buildFamily now intent@(HostOperationIntent _ plan (HostOperationHelperBounds helperStart helperStop) _ window _) program input message = do
  appendString message (name OperationController)
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    common OperationController
    string "Type" "exec"
    string "Slice" (name OperationSlice)
    strings "Requires" [name OperationTimer]
    strings "After" [name OperationTimer]
    strings "RuntimeDirectory" [hostOperationRuntimeDirectory intent]
    property "UMask" "u" (appendWord32 message 0o077)
    property "RuntimeDirectoryMode" "u" (appendWord32 message 0o700)
    string "RuntimeDirectoryPreserve" "no"
    string "Restart" "no"
    string "KillMode" "control-group"
    property "KillSignal" "i" (appendInt32 message 9)
    property "FinalKillSignal" "i" (appendInt32 message 9)
    property "SendSIGKILL" "b" (appendBoolean message True)
    number "MemoryMax" (Host.hostExecutionParentMemoryBytes plan)
    number "MemorySwapMax" 0
    number "TasksMax" (Host.hostExecutionParentTasks plan)
    number "CPUQuotaPerSecUSec" (Host.hostExecutionParentCpuUsecPerSec plan)
    number "RuntimeMaxUSec" (remaining (Identity.hostExecutionOuterEnd window))
    number "RuntimeRandomizedExtraUSec" 0
    number "TimeoutStartUSec" (remaining (Identity.hostExecutionWorkEnd window))
    number "TimeoutStopUSec" stopMicros
    string "StandardInput" "null"
    case input of
      Nothing -> pure ()
      Just held -> Stdin.appendHostControllerStdin held message
    string "StandardOutput" "null"
    string "StandardError" "null"
    exec executable arguments
  withContainer message 'a' "(sa(sv))" $ do
    auxiliary OperationSlice $ do
      number "MemoryMax" (Host.hostExecutionSliceMemoryBytes plan)
      number "MemorySwapMax" 0
      number "TasksMax" (Host.hostExecutionSliceTasks plan)
      number "CPUQuotaPerSecUSec" (Host.hostExecutionSliceCpuUsecPerSec plan)
      property "StopWhenUnneeded" "b" (appendBoolean message True)
    auxiliary OperationTimer $ do
      strings "Requires" [name OperationSlice]
      strings "After" [name OperationSlice]
      property "TimersMonotonic" "a(st)" $ withContainer message 'a' "(st)" $ withContainer message 'r' "st" $ do
        appendString message "OnBootSec"
        appendWord64 message (Identity.hostExecutionHardEnd window `div` 1000)
      number "AccuracyUSec" 1
      number "RandomizedDelayUSec" 0
      property "RemainAfterElapse" "b" (appendBoolean message False)
    auxiliary OperationExpiry $ do
      string "Type" "oneshot"
      string "Slice" (name OperationSlice)
      strings "Conflicts" victims
      strings "Before" victims
      number "MemoryMax" (Host.hostExecutionHelperMemoryBytes plan)
      number "MemorySwapMax" 0
      number "TasksMax" (Host.hostExecutionHelperTasks plan)
      number "CPUQuotaPerSecUSec" (Host.hostExecutionHelperCpuUsecPerSec plan)
      number "TimeoutStartUSec" helperStart
      number "TimeoutStopUSec" helperStop
      property "KillSignal" "i" (appendInt32 message 9)
      exec "/bin/true" ["/bin/true"]
 where
  name = hostOperationUnitName intent
  victims = [name OperationController]
  remaining ending = fromInteger (max 1 ((toInteger ending - toInteger now + 999) `div` 1000))
  stopMicros = (Identity.hostExecutionStopEnd window - Identity.hostExecutionHardEnd window) `div` 1000
  (executable, arguments) = controllerCommand intent program
  common role = do
    string "Description" (hostOperationDescription intent <> " " <> show role)
    string "CollectMode" "inactive-or-failed"
  auxiliary role body = withContainer message 'r' "sa(sv)" $ do
    appendString message (name role)
    withContainer message 'a' "(sv)" (common role >> body)
  property label signature body =
    withContainer
      message
      'r'
      "sv"
      (appendString message label >> withContainer message 'v' signature body)
  string label value = property label "s" (appendString message value)
  number label value = property label "t" (appendWord64 message value)
  strings label values = property label "as" (withContainer message 'a' "s" (mapM_ (appendString message) values))
  exec path args = property "ExecStart" "a(sasb)" $ withContainer message 'a' "(sasb)" $ withContainer message 'r' "sasb" $ do
    appendString message path
    withContainer message 'a' "s" (mapM_ (appendString message) args)
    appendBoolean message False

controllerCommand :: HostOperationIntent -> HostControllerProgram -> (FilePath, [String])
controllerCommand intent (HostControllerProgram _ inputs) = (executable, arguments)
 where
  executable = Inputs.hostControllerExecutablePath inputs
  configuration = Inputs.hostControllerConfigurationPath inputs
  request = Inputs.hostControllerRequestPath inputs
  plan = hostOperationPlan intent
  key = hostOperationKey intent
  window = hostOperationWindow intent
  arguments =
    [executable, Identity.hostControllerKindEntrypoint (hostOperationKind intent)]
      <> Arguments.renderHostControllerArguments
        ( Arguments.HostControllerArguments
            configuration
            request
            (Inputs.hostControllerInputFingerprint inputs)
            key
            window
        )
      <> Runtime.runtimeMemoryRtsArguments (Host.hostExecutionRuntimeMemory plan)
      <> ["+RTS", "-N1", "-RTS"]
