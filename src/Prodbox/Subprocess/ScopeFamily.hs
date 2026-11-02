{-# LANGUAGE ImportQualifiedPost #-}

-- | The fixed scope/timer/no-op expiry request and its exact read-only field.
-- Request acknowledgement and inventory are not host admission or a process
-- completion receipt. The subprocess owner must compose those obligations.
module Prodbox.Subprocess.ScopeFamily
  ( ScopeFamilyIntent
  , ScopeFamilyRole (..)
  , ScopeFamilyError (..)
  , ExpiryHelperLimits
  , expiryHelperLimits
  , newScopeFamilyIntent
  , hostScopeFamilyIntent
  , scopeFamilyUnitName
  , scopeFamilyHardExpiry
  , startScopeFamily
  , startHostScopeFamily
  , verifyHostScopeFamilyBeforeEffect
  , ScopeFamilyInventory
  , ScopeFamilyPresence (..)
  , observeScopeFamily
  , scopeFamilyPresence
  , scopeFamilyAbsent
  , retireScopeFamilyAlarms
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, readMVar)
import Control.Exception (finally, mask)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as Bytes
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import Data.Word (Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Subprocess.KernelScope
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.Types (Fd (..))

data ScopeFamilyRole = FamilyScope | FamilyTimer | FamilyExpiry
  deriving (Bounded, Enum, Eq, Show)

data ScopeFamilyError
  = ScopeFamilyInvalidLimits
  | ScopeFamilyExpired
  | ScopeFamilyAlreadyAttempted
  | ScopeFamilyChildRefused !KernelScopeError
  | ScopeFamilyManagerRefused !BusError
  | ScopeFamilyScopeMismatch
  | ScopeFamilyGroupNotTerminal
  | ScopeFamilyReferenceReleaseRefused !BusError
  | ScopeFamilyPrimaryAndReleaseRefused !ScopeFamilyError !BusError
  deriving (Eq, Show)

data ExpiryHelperLimits = ExpiryHelperLimits !Word64 !Word64 !Word64 !Word64 !Word64
  deriving (Eq, Show)

-- Explicit wire limits. These do not establish a family CPU/memory/host permit.
expiryHelperLimits :: Word64 -> Word64 -> Word64 -> Word64 -> Word64 -> Maybe ExpiryHelperLimits
expiryHelperLimits memory tasks cpu start stop
  | all (\value -> value > 0 && value < maxBound) [memory, tasks, cpu, start, stop] =
      Just (ExpiryHelperLimits memory tasks cpu start stop)
  | otherwise = Nothing

data ScopeFamilyIntent = ScopeFamilyIntent !String !Word64 !Word64 !(MVar Bool)

newScopeFamilyIntent :: Word64 -> Word64 -> IO (Either ScopeFamilyError ScopeFamilyIntent)
newScopeFamilyIntent hardExpiry terminalDeadline = do
  now <- getMonotonicTimeNSec
  if now >= hardExpiry || hardExpiry >= terminalDeadline
    then pure (Left ScopeFamilyExpired)
    else do
      nonce <- getRandomBytes 16
      attempted <- newMVar False
      finished <- getMonotonicTimeNSec
      pure $
        if finished >= hardExpiry
          then Left ScopeFamilyExpired
          else
            Right
              ( ScopeFamilyIntent
                  ("prodbox-owned-" <> concatMap hexByte (Bytes.unpack nonce))
                  hardExpiry
                  terminalDeadline
                  attempted
              )

-- Retain the caller's field and original alarm through an uncertain request.
-- Reconstructing this location cannot extend either absolute deadline.
hostScopeFamilyIntent
  :: Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> IO (Either ScopeFamilyError ScopeFamilyIntent)
hostScopeFamilyIntent key window = do
  now <- getMonotonicTimeNSec
  if now >= Identity.hostExecutionWorkEnd window
    then pure (Left ScopeFamilyExpired)
    else do
      attempted <- newMVar False
      pure
        ( Right
            ( ScopeFamilyIntent
                ("prodbox-owned-" <> Identity.hostExecutionKeyText key)
                (Identity.hostExecutionHardEnd window)
                (Identity.hostExecutionStopEnd window)
                attempted
            )
        )

hexByte :: Word8 -> String
hexByte byte = [digit (byte `div` 16), digit (byte `mod` 16)]
 where
  digit index = "0123456789abcdef" !! fromIntegral index

scopeFamilyUnitName :: ScopeFamilyIntent -> ScopeFamilyRole -> String
scopeFamilyUnitName (ScopeFamilyIntent stem _ _ _) role = case role of
  FamilyScope -> stem <> ".scope"
  FamilyTimer -> stem <> "-expiry.timer"
  FamilyExpiry -> stem <> "-expiry.service"

scopeFamilyHardExpiry :: ScopeFamilyIntent -> Word64
scopeFamilyHardExpiry (ScopeFamilyIntent _ expiry _ _) = expiry

-- Only one create attempt is allowed for this intent. A lost reply is observed
-- through the same field; it must never create a fresh family behind recovery.
startScopeFamily
  :: BusConnection
  -> Word64
  -> ScopeFamilyIntent
  -> Fd
  -> ScopeKernelLimits
  -> ExpiryHelperLimits
  -> IO (Either ScopeFamilyError ())
startScopeFamily = startPlacedScopeFamily Nothing

startHostScopeFamily
  :: HostPlacementUse
  -> BusConnection
  -> Word64
  -> ScopeFamilyIntent
  -> Fd
  -> ScopeKernelLimits
  -> ExpiryHelperLimits
  -> IO (Either ScopeFamilyError ())
startHostScopeFamily token connection requestedCreationEnd intent@(ScopeFamilyIntent _ hardExpiry terminalEnd _) child limits helper@(ExpiryHelperLimits memory tasks cpu _ _) = do
  let window = hostPlacementWindow token
      plan = hostPlacementPlan token
      expected = "prodbox-owned-" <> Identity.hostExecutionKeyText (hostPlacementKey token) <> ".scope"
  if scopeFamilyUnitName intent FamilyScope /= expected
    || hardExpiry /= Identity.hostExecutionHardEnd window
    || terminalEnd /= Identity.hostExecutionStopEnd window
    || memory /= Host.hostExecutionHelperMemoryBytes plan
    || tasks /= Host.hostExecutionHelperTasks plan
    || cpu /= Host.hostExecutionHelperCpuUsecPerSec plan
    then pure (Left ScopeFamilyInvalidLimits)
    else do
      placement <- verifyHostPlacementBeforeAdmission token child limits
      case placement of
        Left cause -> pure (Left (ScopeFamilyChildRefused cause))
        Right () ->
          startPlacedScopeFamily
            (Just (hostPlacementSliceName token))
            connection
            (min requestedCreationEnd (Identity.hostExecutionWorkEnd window))
            intent
            child
            limits
            helper

startPlacedScopeFamily
  :: Maybe String
  -> BusConnection
  -> Word64
  -> ScopeFamilyIntent
  -> Fd
  -> ScopeKernelLimits
  -> ExpiryHelperLimits
  -> IO (Either ScopeFamilyError ())
startPlacedScopeFamily slice connection requestedCreationEnd intent@(ScopeFamilyIntent _ hardExpiry terminalEnd attempted) child limits helper@(ExpiryHelperLimits _ _ _ start stop) = do
  now <- getMonotonicTimeNSec
  let creationEnd = min requestedCreationEnd (systemdBusDeadline connection)
      ending = min terminalEnd (systemdBusDeadline connection)
      helperEnd = toInteger hardExpiry + (toInteger start + toInteger stop) * 1000
  if now >= creationEnd || creationEnd >= hardExpiry || hardExpiry >= ending
    then pure (Left ScopeFamilyExpired)
    else
      if helperEnd >= toInteger ending
        then pure (Left ScopeFamilyInvalidLimits)
        else do
          result <- withVerifiedChildDescriptor creationEnd child $ \owned -> do
            first <- modifyMVar attempted (\prior -> pure (True, not prior))
            if first
              then do
                accepted <-
                  runExceptT
                    ( callManager
                        (systemdBusWithin creationEnd connection)
                        StartTransientUnit
                        (buildFamily slice intent owned limits helper)
                        (`readString` 'o')
                    )
                pure (either (Left . ScopeFamilyManagerRefused) (const (Right ())) accepted)
              else pure (Left ScopeFamilyAlreadyAttempted)
          pure (either (Left . ScopeFamilyChildRefused) id result)

buildFamily
  :: Maybe String
  -> ScopeFamilyIntent
  -> Fd
  -> ScopeKernelLimits
  -> ExpiryHelperLimits
  -> BusMessage
  -> BusAction ()
buildFamily slice intent (Fd descriptor) limits (ExpiryHelperLimits memory tasks cpu start stop) message = do
  appendString message (scopeFamilyUnitName intent FamilyScope)
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    property
      message
      "Description"
      "s"
      (appendString message "prodbox owned child with original absolute expiry")
    property message "PIDFDs" "ah" (withContainer message 'a' "h" (appendDescriptor message descriptor))
    stringsProperty message "Requires" [timer]
    stringsProperty message "After" [timer]
    property message "KillSignal" "i" (appendInt32 message 9)
    property message "CollectMode" "s" (appendString message "inactive-or-failed")
    appendSlice
    appendScopeKernelLimits message limits
  withContainer message 'a' "(sa(sv))" $ do
    auxiliary timer $ do
      property message "TimersMonotonic" "a(st)" $
        withContainer message 'a' "(st)" $
          withContainer message 'r' "st" $ do
            appendString message "OnBootSec"
            appendWord64 message (scopeFamilyHardExpiry intent `div` 1000)
      uintProperty message "AccuracyUSec" 1
      uintProperty message "RandomizedDelayUSec" 0
      property message "RemainAfterElapse" "b" (appendBoolean message False)
      property message "CollectMode" "s" (appendString message "inactive-or-failed")
    auxiliary expiry $ do
      property message "Type" "s" (appendString message "oneshot")
      appendSlice
      stringsProperty message "Conflicts" [scopeFamilyUnitName intent FamilyScope]
      stringsProperty message "Before" [scopeFamilyUnitName intent FamilyScope]
      property message "ExecStart" "a(sasb)" $
        withContainer message 'a' "(sasb)" $
          withContainer message 'r' "sasb" $ do
            appendString message "/bin/true"
            strings message ["/bin/true"]
            appendBoolean message False
      uintProperty message "MemoryMax" memory
      uintProperty message "MemorySwapMax" 0
      uintProperty message "TasksMax" tasks
      uintProperty message "CPUQuotaPerSecUSec" cpu
      uintProperty message "TimeoutStartUSec" start
      uintProperty message "TimeoutStopUSec" stop
      property message "KillSignal" "i" (appendInt32 message 9)
      property message "CollectMode" "s" (appendString message "inactive-or-failed")
 where
  timer = scopeFamilyUnitName intent FamilyTimer
  expiry = scopeFamilyUnitName intent FamilyExpiry
  appendSlice = mapM_ (\name -> property message "Slice" "s" (appendString message name)) slice
  auxiliary name action = withContainer message 'r' "sa(sv)" $ do
    appendString message name
    withContainer message 'a' "(sv)" action

property :: BusMessage -> String -> String -> BusAction () -> BusAction ()
property message name signature action = withContainer message 'r' "sv" $ do
  appendString message name
  withContainer message 'v' signature action

uintProperty :: BusMessage -> String -> Word64 -> BusAction ()
uintProperty message name value = property message name "t" (appendWord64 message value)

stringsProperty :: BusMessage -> String -> [String] -> BusAction ()
stringsProperty message name values = property message name "as" (strings message values)

strings :: BusMessage -> [String] -> BusAction ()
strings message values = withContainer message 'a' "s" (mapM_ (appendString message) values)

-- The loaded but dormant helper already carries its closed command, placement
-- and finite activation/stop limits. It may not hide an additional hook chain.
verifyHostScopeFamilyBeforeEffect
  :: HostPlacementUse
  -> BusConnection
  -> ScopeFamilyIntent
  -> ExpiryHelperLimits
  -> IO (Either ScopeFamilyError ())
verifyHostScopeFamilyBeforeEffect token original intent (ExpiryHelperLimits memory tasks cpu start stop) =
  runExceptT $ withFamilyReference connection expiry $ \observed -> do
    familyDeadline ending
    path <- maybe (throwE ScopeFamilyScopeMismatch) pure observed
    let helperProperty interface name decode =
          manager $
            callManager
              connection
              (ReadUnitProperty path)
              ( \message -> appendString message ("org.freedesktop.systemd1." <> interface) >> appendString message name
              )
              decode
    name <- helperProperty "Unit" "Id" readVariantString
    invocation <- helperProperty "Unit" "InvocationID" readVariantInvocationObservation
    state <- helperProperty "Unit" "ActiveState" readVariantString
    job <- helperProperty "Unit" "Job" readVariantJob
    kind <- helperProperty "Service" "Type" readVariantString
    slice <- helperProperty "Service" "Slice" readVariantString
    remain <- helperProperty "Service" "RemainAfterExit" readVariantBoolean
    mode <- helperProperty "Service" "KillMode" readVariantString
    signal <- helperProperty "Service" "KillSignal" readVariantInt32
    finalSignal <- helperProperty "Service" "FinalKillSignal" readVariantInt32
    sendKill <- helperProperty "Service" "SendSIGKILL" readVariantBoolean
    pid <- helperProperty "Service" "MainPID" readVariantWord32
    values <-
      traverse
        (\field -> helperProperty "Service" field readVariantWord64)
        [ "MemoryMax"
        , "MemorySwapMax"
        , "TasksMax"
        , "CPUQuotaPerSecUSec"
        , "TimeoutStartUSec"
        , "TimeoutStopUSec"
        ]
    _ <- helperProperty "Service" "ExecStart" readVariantDormantNoOp
    mapM_
      (\field -> helperProperty "Service" field readVariantNoExecStop)
      ["ExecCondition", "ExecStartPre", "ExecStartPost", "ExecStop", "ExecStopPost"]
    unless
      ( name == expiry
          && invocation == InvocationAbsent
          && state == "inactive"
          && job == UnitJobAbsent
          && kind == "oneshot"
          && slice == hostPlacementSliceName token
          && not remain
          && mode == "control-group"
          && signal == 9
          && finalSignal == 9
          && sendKill
          && pid == 0
          && values == [memory, 0, tasks, cpu, start, stop]
      )
      (throwE ScopeFamilyScopeMismatch)
    familyDeadline ending
 where
  ending = min (Identity.hostExecutionWorkEnd (hostPlacementWindow token)) (systemdBusDeadline original)
  connection = systemdBusWithin ending original
  expiry = scopeFamilyUnitName intent FamilyExpiry

-- A present but not-yet-invoked helper has no InvocationId. It cannot become
-- an invocation-qualified mutation target through this read-only observation.
data ScopeFamilyPresence
  = ScopeFamilyUnitAbsent
  | ScopeFamilyUnitPresent !InvocationObservation
  | ScopeFamilyUnitUnobservable !BusError
  deriving (Eq, Show)

data ScopeFamilyInventory
  = ScopeFamilyInventory !ScopeFamilyPresence !ScopeFamilyPresence !ScopeFamilyPresence
  deriving (Eq, Show)

observeScopeFamily :: BusConnection -> ScopeFamilyIntent -> BusAction ScopeFamilyInventory
observeScopeFamily connection intent =
  ScopeFamilyInventory <$> observe FamilyScope <*> observe FamilyTimer <*> observe FamilyExpiry
 where
  observe role = do
    let name = scopeFamilyUnitName intent role
    found <-
      lift
        ( runExceptT
            (callManager connection GetUnit (\message -> appendString message name) (`readString` 'o'))
        )
    case found of
      Left (BusMethodRefused 2) -> pure ScopeFamilyUnitAbsent
      Left cause -> pure (ScopeFamilyUnitUnobservable cause)
      Right path -> do
        metadata <- lift (runExceptT (readIdentity name path))
        pure (either ScopeFamilyUnitUnobservable ScopeFamilyUnitPresent metadata)
  readIdentity expected path = do
    actual <- readProperty path "Id" readVariantString
    unless (actual == expected) (throwE BusMalformedReply)
    readProperty path "InvocationID" readVariantInvocationObservation
  readProperty path name = callManager connection (ReadUnitProperty path) $ \message -> do
    appendString message "org.freedesktop.systemd1.Unit"
    appendString message name

scopeFamilyPresence :: ScopeFamilyInventory -> ScopeFamilyRole -> ScopeFamilyPresence
scopeFamilyPresence (ScopeFamilyInventory scope timer expiry) role = case role of
  FamilyScope -> scope
  FamilyTimer -> timer
  FamilyExpiry -> expiry

scopeFamilyAbsent :: ScopeFamilyInventory -> Bool
scopeFamilyAbsent (ScopeFamilyInventory ScopeFamilyUnitAbsent ScopeFamilyUnitAbsent ScopeFamilyUnitAbsent) = True
scopeFamilyAbsent _ = False

type FamilyAction = ExceptT ScopeFamilyError IO

-- Stop the alarm only after independently observed terminal group emptiness.
-- Scope references still belong to KernelScope. Closing absence is read after
-- that bracket releases the scope, not inferred from these stop requests.
retireScopeFamilyAlarms
  :: BusConnection -> Word64 -> ScopeFamilyIntent -> KernelScope -> IO (Either ScopeFamilyError ())
retireScopeFamilyAlarms original requestedEnd intent@(ScopeFamilyIntent _ _ terminalEnd attempted) scope = do
  submitted <- readMVar attempted
  if not submitted
    || not (("/" <> scopeFamilyUnitName intent FamilyScope) `isSuffixOf` kernelScopeControlGroup scope)
    then pure (Left ScopeFamilyScopeMismatch)
    else runExceptT $ do
      now <- lift getMonotonicTimeNSec
      unless (now < ending) (throwE (ScopeFamilyManagerRefused (BusDeadlineReached BusRequest)))
      empty <- lift (observeKernelScopeEmptyBefore ending scope)
      case empty of
        Left cause -> throwE (ScopeFamilyChildRefused cause)
        Right False -> throwE ScopeFamilyGroupNotTerminal
        Right True ->
          withFamilyReference connection (scopeFamilyUnitName intent FamilyTimer) $ \timer ->
            withFamilyReference connection (scopeFamilyUnitName intent FamilyExpiry) $ \expiry -> do
              settle FamilyTimer timer Nothing
              settle FamilyExpiry expiry Nothing
 where
  ending = min terminalEnd (min requestedEnd (systemdBusDeadline original))
  connection = systemdBusWithin ending original
  settle role maybePath stopped = do
    familyDeadline ending
    case maybePath of
      Nothing -> pure ()
      Just path -> do
        (invocation, idle) <- observeIdle connection (scopeFamilyUnitName intent role) path
        if idle
          then pure ()
          else case invocation of
            InvocationPresent identifier | stopped /= Just identifier -> do
              result <- lift (runExceptT (stopInvocation role identifier))
              case result of
                Right _ -> wait role maybePath (Just identifier)
                Left (ScopeFamilyManagerRefused (BusMethodRefused code))
                  | code == 2 || code == 3 -> wait role maybePath Nothing
                Left cause -> throwE cause
            InvocationPresent _ -> wait role maybePath stopped
            InvocationAbsent -> wait role maybePath stopped
  wait role path stopped = lift (threadDelay 1000) >> settle role path stopped
  stopInvocation role identifier = do
    alias <-
      manager
        ( callManager
            connection
            (GetUnitByInvocationID identifier)
            (const (pure ()))
            (readInvocationPath identifier)
        )
    actual <- manager (unitProperty connection (invocationPathText alias) "Id" readVariantString)
    unless (actual == scopeFamilyUnitName intent role) (throwE ScopeFamilyScopeMismatch)
    manager (callManager connection (StopInvocationUnit alias) (const (pure ())) (`readString` 'o'))

familyDeadline :: Word64 -> FamilyAction ()
familyDeadline ending = do
  now <- lift getMonotonicTimeNSec
  unless (now < ending) (throwE ScopeFamilyExpired)

manager :: BusAction value -> FamilyAction value
manager action = ExceptT (either (Left . ScopeFamilyManagerRefused) Right <$> runExceptT action)

unitProperty
  :: BusConnection -> String -> String -> (BusMessage -> BusAction value) -> BusAction value
unitProperty connection path name = callManager connection (ReadUnitProperty path) $ \message -> do
  appendString message "org.freedesktop.systemd1.Unit"
  appendString message name

observeIdle :: BusConnection -> String -> String -> FamilyAction (InvocationObservation, Bool)
observeIdle connection expected path = do
  name <- manager (unitProperty connection path "Id" readVariantString)
  unless (name == expected) (throwE ScopeFamilyScopeMismatch)
  before <- manager (unitProperty connection path "InvocationID" readVariantInvocationObservation)
  state <- manager (unitProperty connection path "ActiveState" readVariantString)
  job <- manager (unitProperty connection path "Job" readVariantJob)
  after <- manager (unitProperty connection path "InvocationID" readVariantInvocationObservation)
  idle <- case state of
    "inactive" -> pure True
    "failed" -> pure True
    "active" -> pure False
    "activating" -> pure False
    "deactivating" -> pure False
    "reloading" -> pure False
    "maintenance" -> pure False
    "refreshing" -> pure False
    _ -> throwE (ScopeFamilyManagerRefused BusMalformedReply)
  pure (after, before == after && idle && job == UnitJobAbsent)

withFamilyReference
  :: BusConnection -> String -> (Maybe String -> FamilyAction value) -> FamilyAction value
withFamilyReference connection name action = ExceptT $ mask $ \restore -> do
  found <-
    runExceptT
      (callManager connection GetUnit (\message -> appendString message name) (`readString` 'o'))
  case found of
    Left (BusMethodRefused 2) -> restore (runExceptT (action Nothing))
    Left cause -> pure (Left (ScopeFamilyManagerRefused cause))
    Right path -> do
      pinned <- runExceptT (callManager connection (RefUnit name) (const (pure ())) (const (pure ())))
      case pinned of
        Left (BusMethodRefused 2) -> restore (runExceptT (action Nothing))
        Left cause -> pure (Left (ScopeFamilyManagerRefused cause))
        Right () -> do
          released <- newIORef Nothing
          let release = do
                result <- runExceptT (callManager connection (UnrefUnit name) (const (pure ())) (const (pure ())))
                writeIORef released (either Just (const Nothing) result)
          result <- restore (runExceptT (action (Just path))) `finally` release
          refusal <- readIORef released
          pure $ case (result, refusal) of
            (Right _, Just cause) -> Left (ScopeFamilyReferenceReleaseRefused cause)
            (Left primary, Just cause) -> Left (ScopeFamilyPrimaryAndReleaseRefused primary cause)
            (_, Nothing) -> result
