{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native checks of the actual private scope observer, using only owned
-- blocked fixture children. This is not the production process-lifecycle proof.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (replicateM_, unless, void)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT, throwE)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import Data.Word (Word64)
import Foreign (Ptr, nullPtr)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import Prodbox.Subprocess.KernelScope
import Prodbox.Subprocess.ScopeFamily
import Prodbox.Subprocess.SystemdBus
import System.Environment (getArgs)
import System.Exit (ExitCode (..))
import System.IO (SeekMode (AbsoluteSeek), hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (readSymbolicLink)
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , createPipe
  , defaultFileFlags
  , fdSeek
  , openFd
  , openFdAt
  )
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Process
  ( ProcessStatus (..)
  , exitImmediately
  , forkProcess
  , getProcessID
  , getProcessStatus
  )
import System.Posix.Signals (Handler (..), installHandler, sigTERM)
import System.Posix.Types (Fd (..), ProcessID)
import System.Posix.User (getEffectiveUserID)

foreign import capi "sys/pidfd.h pidfd_open" openPidfd :: CInt -> CUInt -> IO CInt
foreign import capi "sys/pidfd.h pidfd_send_signal"
  signalPidfd :: CInt -> CInt -> Ptr () -> CUInt -> IO CInt

main :: IO ()
main = do
  capabilities <- getNumCapabilities
  unless (capabilities == 1) (fixtureFailure "fixture requires one capability before fork")
  args <- getArgs
  case args of
    ["family", "retire-repeat"] -> replicateM_ 64 (familyMain "retire")
    ["family", mode] -> familyMain mode
    _ -> observationMain args

observationMain :: [String] -> IO ()
observationMain args = do
  mode <- case args of
    [value]
      | value
          `elem` [ "kill"
                 , "retired-group"
                 , "terminate"
                 , "terminate-then-kill"
                 , "delayed-admission"
                 , "wrong-limits"
                 , "wrong-cpu"
                 , "foreign-descriptor"
                 , "invalid-unit"
                 , "expired"
                 , "cancel"
                 , "parent-deadline"
                 ] ->
          pure value
    _ -> fixtureFailure "expected scope-observation fixture mode"
  started <- getMonotonicTimeNSec
  owner <- getProcessID
  uid <- getEffectiveUserID
  let deadline = started + 2000000000
      parentDeadline = if mode == "parent-deadline" then started + 200000000 else deadline
      socket = "/run/user/" <> show uid <> "/bus"
      unit = "prodbox-owned-" <> show owner <> "-" <> show started <> ".scope"
  bracket
    (if mode == "terminate-then-kill" then ignoringTermChild else blockedChild)
    (releaseChild deadline)
    $ \first ->
      bracket blockedChild (releaseChild deadline) $ \foreignChild -> do
        entered <- newIORef False
        escaped <- newIORef Nothing
        lateObservation <- newIORef Nothing
        limits <-
          maybe
            (fixtureFailure "fixture limits invalid")
            pure
            (scopeKernelLimits 67108864 0 16 1000000 500000 50000)
        wrong <-
          maybe
            (fixtureFailure "fixture wrong limits invalid")
            pure
            (scopeKernelLimits 33554432 0 16 1000000 500000 50000)
        wrongCpu <-
          maybe
            (fixtureFailure "fixture wrong CPU limit invalid")
            pure
            (scopeKernelLimits 67108864 0 16 500000 500000 50000)
        let callback scope | mode == "retired-group" = do
              writeIORef entered True
              writeIORef escaped (Just scope)
              retiredGroupObservation deadline first scope
            callback scope = do
              writeIORef entered True
              writeIORef escaped (Just scope)
              before <- kernelScopeEmpty scope
              unless (before == Right False) (fixtureFailure ("unexpected pre-kill group: " <> show before))
              killed <-
                if mode `elem` ["terminate", "terminate-then-kill"]
                  then terminateKernelScope deadline scope
                  else killKernelScope scope
              unless (killed == Right ()) (fixtureFailure (show killed))
              if mode == "terminate-then-kill"
                then do
                  threadDelay 20000
                  stillLive <- childLive first
                  populated <- kernelScopeEmpty scope
                  unless
                    (stillLive && populated == Right False)
                    (fixtureFailure "ignored TERM did not preserve the owned live group")
                  forced <- killKernelScope scope
                  unless (forced == Right ()) (fixtureFailure (show forced))
                else pure ()
              stopped <- awaitChild deadline first
              let expectedSignal = if mode == "terminate" then 15 else 9
              unless
                (stopped == Just (Terminated expectedSignal False))
                (fixtureFailure ("child did not stop: " <> show stopped))
              empty <- awaitEmpty deadline scope
              unless empty (fixtureFailure "scope terminal absence unconfirmed")
              pure (Right ())
            observed connection descriptor name selected end action =
              withObservedChildScope connection end descriptor name selected action
            run connection = case mode of
              "delayed-admission" -> do
                withAsync
                  ( threadDelay 50000
                      >> manager deadline socket (\busConnection -> startScope busConnection unit (childFd first))
                  )
                  $ \job -> do
                    result <- observed connection (childFd first) unit limits deadline callback
                    wait job
                    pure result
              "retired-group" -> observed connection (childFd first) unit limits deadline callback
              "wrong-limits" -> observed connection (childFd first) unit wrong deadline callback
              "wrong-cpu" -> observed connection (childFd first) unit wrongCpu deadline callback
              "foreign-descriptor" -> bracket (selfPidfd owner) closeFd $ \self ->
                observed connection self unit limits deadline callback
              "invalid-unit" -> observed connection (childFd first) "foreign.scope" limits deadline callback
              "expired" -> observed connection (childFd first) unit limits (started - 1) callback
              "parent-deadline" ->
                observed connection (childFd first) unit limits deadline $ \scope -> do
                  writeIORef entered True
                  writeIORef escaped (Just scope)
                  now <- getMonotonicTimeNSec
                  let remaining = if now >= parentDeadline then 0 else (parentDeadline - now) `div` 1000
                  threadDelay (fromIntegral remaining + 20000)
                  late <- kernelScopeEmpty scope
                  writeIORef lateObservation (Just late)
                  pure (Right ())
              "cancel" -> do
                ready <- newEmptyMVar
                let blocked scope = do
                      writeIORef entered True
                      writeIORef escaped (Just scope)
                      putMVar ready ()
                      threadDelay 5000000
                      pure (Right ())
                withAsync (observed connection (childFd first) unit limits deadline blocked) $ \worker -> do
                  takeMVar ready
                  cancel worker
                  terminal <- waitCatch worker
                  case terminal of
                    Left _ -> pure (Right ())
                    Right value -> fixtureFailure ("cancellation returned normally: " <> show value)
              "kill" -> observed connection (childFd first) unit limits deadline callback
              "terminate" -> observed connection (childFd first) unit limits deadline callback
              "terminate-then-kill" -> observed connection (childFd first) unit limits deadline callback
              _ -> fixtureFailure "unreachable fixture mode"
        nativeResult <- withSystemdBus parentDeadline socket $ \connection -> do
          unless (mode == "delayed-admission") (void (startScope connection unit (childFd first)))
          lift (run connection)
        late <- readIORef lateObservation
        result <- case nativeResult of
          Left (BusDeadlineReached BusRelease)
            | mode == "parent-deadline" && late == Just (Left KernelScopeDeadlineReached) -> pure (Right ())
          Left cause -> fixtureFailure (show cause)
          Right value -> pure value
        callbackEntered <- readIORef entered
        let expected = case mode of
              "wrong-limits" -> Left KernelScopeResourceMismatch
              "wrong-cpu" -> Left KernelScopeResourceMismatch
              "foreign-descriptor" -> Left KernelScopeChildRefused
              "invalid-unit" -> Left KernelScopeInvalidInput
              "expired" -> Left KernelScopeDeadlineReached
              _ -> Right ()
            shouldEnter =
              mode
                `elem` [ "kill"
                       , "retired-group"
                       , "terminate"
                       , "terminate-then-kill"
                       , "delayed-admission"
                       , "cancel"
                       , "parent-deadline"
                       ]
        unless
          (result == expected && callbackEntered == shouldEnter)
          (fixtureFailure ("unexpected observation: " <> show (result, callbackEntered)))
        retained <- readIORef escaped
        closed <- case retained of
          Nothing -> pure True
          Just scope -> do
            killed <- killKernelScope scope
            empty <- kernelScopeEmpty scope
            boundedEmpty <- observeKernelScopeEmptyBefore deadline scope
            terminated <- terminateKernelScope deadline scope
            pure
              ( killed == Left KernelScopeHandleClosed
                  && empty == Left KernelScopeHandleClosed
                  && ( boundedEmpty == Left KernelScopeHandleClosed
                         || boundedEmpty == Left KernelScopeDeadlineReached
                     )
                  && terminated == Left KernelScopeHandleClosed
              )
        foreignLive <- childLive foreignChild
        firstLive <- childLive first
        let shouldLive = mode `notElem` ["kill", "retired-group", "terminate", "terminate-then-kill", "delayed-admission"]
        unless
          (closed && foreignLive && firstLive == shouldLive)
          (fixtureFailure "handle closure or independent child disposition failed")
        stopChild deadline first
        manager deadline socket (\connection -> awaitAbsent connection unit)
        finished <- getMonotonicTimeNSec
        Lazy.putStrLn
          ( encode
              ( object
                  [ "mode" .= mode
                  , "passed" .= True
                  , "callback_entered" .= callbackEntered
                  , "result" .= show result
                  , "native_bus_result" .= show nativeResult
                  , "late_parent_budget_observation" .= show late
                  , "closed_handle_refused" .= closed
                  , "foreign_child_preserved" .= foreignLive
                  , "own_child_live_before_fixture_cleanup" .= firstLive
                  , "scope_absent_after_reference_release_and_fixture_cleanup" .= True
                  , "elapsed_micros" .= ((finished - started) `div` 1000)
                  , "production_process_lifecycle_claim" .= False
                  ]
              )
          )

-- Exercise the actual fixed family request, not a second request builder.
familyMain :: String -> IO ()
familyMain mode = do
  unless
    ( mode
        `elem` [ "expiry"
               , "term"
               , "duplicate"
               , "expired-create"
               , "future-create"
               , "foreign-descriptor"
               , "retire"
               , "reject-live-retire"
               , "expired-retire"
               , "unsubmitted-retire"
               ]
    )
    (fixtureFailure "unknown family fixture")
  started <- getMonotonicTimeNSec
  owner <- getProcessID
  uid <- getEffectiveUserID
  let deadline = started + 500000000
      hard = started + 350000000
      creationEnd = started + 150000000
      socket = "/run/user/" <> show uid <> "/bus"
      negative = mode `elem` ["expired-create", "future-create", "foreign-descriptor"]
      early = mode `elem` ["retire", "reject-live-retire", "expired-retire", "unsubmitted-retire"]
  intent <- newScopeFamilyIntent hard deadline >>= either (fixtureFailure . show) pure
  limits <-
    maybe
      (fixtureFailure "invalid family fixture scope limits")
      pure
      (scopeKernelLimits 67108864 0 16 1000000 2000000 50000)
  helper <-
    maybe
      (fixtureFailure "invalid family fixture helper limits")
      pure
      (expiryHelperLimits 16777216 8 1000000 30000 30000)
  bracket blockedChild (releaseChild deadline) $ \first ->
    bracket blockedChild (releaseChild deadline) $ \foreignChild -> do
      stoppedAt <- newIORef Nothing
      manager deadline socket $ \connection -> do
        accepted <- lift $ case mode of
          "foreign-descriptor" -> bracket (selfPidfd owner) closeFd $ \descriptor ->
            startScopeFamily connection creationEnd intent descriptor limits helper
          "expired-create" -> startScopeFamily connection (started - 1) intent (childFd first) limits helper
          "future-create" -> startScopeFamily connection (hard + 1) intent (childFd first) limits helper
          _ -> startScopeFamily connection creationEnd intent (childFd first) limits helper
        let expected = case mode of
              "foreign-descriptor" -> Left (ScopeFamilyChildRefused KernelScopeChildRefused)
              "expired-create" -> Left ScopeFamilyExpired
              "future-create" -> Left ScopeFamilyExpired
              _ -> Right ()
        unless (accepted == expected) (fixtureFailure ("family admission mismatch: " <> show accepted))
        if negative
          then do
            inventory <- observeScopeFamily connection intent
            unless (scopeFamilyAbsent inventory) (fixtureFailure ("rejected family exists: " <> show inventory))
            live <- lift (childLive first)
            unless live (fixtureFailure "rejected request stopped fixture child")
          else do
            whenDuplicate connection intent first limits helper creationEnd
            outcome <- lift
              $ withObservedChildScope
                connection
                deadline
                (childFd first)
                (scopeFamilyUnitName intent FamilyScope)
                limits
              $ \scope -> do
                inventory <- runExceptT (observeScopeFamily connection intent)
                observed <- either (fixtureFailure . show) pure inventory
                unless
                  ( scopeFamilyPresence observed FamilyScope
                      == ScopeFamilyUnitPresent (InvocationPresent (kernelScopeInvocation scope))
                  )
                  (fixtureFailure ("scope identity mismatch: " <> show observed))
                timerInvocation <- case scopeFamilyPresence observed FamilyTimer of
                  ScopeFamilyUnitPresent (InvocationPresent identifier) -> pure identifier
                  value -> fixtureFailure ("timer invocation missing: " <> show value)
                unless
                  (scopeFamilyPresence observed FamilyExpiry == ScopeFamilyUnitPresent InvocationAbsent)
                  (fixtureFailure ("inactive helper observation mismatch: " <> show observed))
                path <-
                  runExceptT
                    ( callManager
                        connection
                        GetUnit
                        (\message -> appendString message (scopeFamilyUnitName intent FamilyExpiry))
                        (`readString` 'o')
                    )
                    >>= either (fixtureFailure . show) pure
                strict <-
                  runExceptT
                    ( callManager
                        connection
                        (ReadUnitProperty path)
                        ( \message -> appendString message "org.freedesktop.systemd1.Unit" >> appendString message "InvocationID"
                        )
                        readVariantInvocationId
                    )
                unless
                  (strict == Left BusMalformedReply)
                  (fixtureFailure "null helper invocation minted an identity")
                assertAlarmArmed connection intent hard timerInvocation
                if mode == "reject-live-retire"
                  then do
                    liveObservation <- observeKernelScopeEmptyBefore (started + 450000000) scope
                    unless
                      (liveObservation == Right False)
                      (fixtureFailure ("live group observation waited: " <> show liveObservation))
                    expired <- observeKernelScopeEmptyBefore (started - 1) scope
                    unless
                      (expired == Left KernelScopeDeadlineReached)
                      (fixtureFailure ("expired observation renewed its bound: " <> show expired))
                    refused <- retireScopeFamilyAlarms connection (started + 450000000) intent scope
                    unless
                      (refused == Left ScopeFamilyGroupNotTerminal)
                      (fixtureFailure ("live group lost its alarm: " <> show refused))
                    assertAlarmArmed connection intent hard timerInvocation
                    live <- childLive first
                    unless live (fixtureFailure "refused retirement stopped the live child")
                  else pure ()
                if mode == "unsubmitted-retire"
                  then do
                    other <- newScopeFamilyIntent hard deadline >>= either (fixtureFailure . show) pure
                    refused <- retireScopeFamilyAlarms connection (started + 450000000) other scope
                    unless
                      (refused == Left ScopeFamilyScopeMismatch)
                      (fixtureFailure ("unsubmitted intent retirement mismatch: " <> show refused))
                    assertAlarmArmed connection intent hard timerInvocation
                    unsubmitted <-
                      runExceptT (observeScopeFamily connection other) >>= either (fixtureFailure . show) pure
                    unless (scopeFamilyAbsent unsubmitted) (fixtureFailure "refused intent created auxiliary units")
                  else pure ()
                if mode == "term"
                  then do
                    now <- getMonotonicTimeNSec
                    sent <- terminateKernelScope (min hard (now + 50000000)) scope
                    unless (sent == Right ()) (fixtureFailure (show sent))
                  else
                    if early
                      then do
                        killed <- killKernelScope scope
                        unless (killed == Right ()) (fixtureFailure (show killed))
                      else pure ()
                empty <- awaitEmpty (started + 450000000) scope
                unless empty (fixtureFailure "family scope not terminal inside original confirmation budget")
                status <- awaitChild deadline first
                let signal = if mode == "term" then 15 else 9
                unless
                  (status == Just (Terminated signal False))
                  (fixtureFailure ("family child status mismatch: " <> show status))
                now <- getMonotonicTimeNSec
                unless (mode == "term" || early || now >= hard) (fixtureFailure "absolute expiry fired early")
                writeIORef stoppedAt (Just now)
                if mode == "expired-retire"
                  then do
                    refused <- retireScopeFamilyAlarms connection (started - 1) intent scope
                    unless
                      (refused == Left (ScopeFamilyManagerRefused (BusDeadlineReached BusRequest)))
                      (fixtureFailure ("expired retirement mutated: " <> show refused))
                    assertAlarmArmed connection intent hard timerInvocation
                  else pure ()
                if early
                  then do
                    retired <- retireScopeFamilyAlarms connection (started + 450000000) intent scope
                    either (fixtureFailure . show) pure retired
                  else pure ()
                pure (Right ())
            either (fixtureFailure . show) pure outcome
            awaitFamilyAbsent (systemdBusWithin (started + 450000000) connection) intent
      foreignLive <- childLive foreignChild
      unless foreignLive (fixtureFailure "family mutation reached unrelated child")
      terminal <- readIORef stoppedAt
      finished <- getMonotonicTimeNSec
      unless (finished < deadline) (fixtureFailure "family fixture exceeded original 500ms")
      unless
        (not early || finished < hard)
        (fixtureFailure "early retirement merely waited for the alarm")
      Lazy.putStrLn
        ( encode
            ( object
                [ "mode" .= mode
                , "passed" .= True
                , "family_names" .= map (scopeFamilyUnitName intent) [FamilyScope, FamilyTimer, FamilyExpiry]
                , "negative_request" .= negative
                , "early_retirement" .= early
                , "refusal_alarm_readback"
                    .= (mode `elem` ["reject-live-retire", "expired-retire", "unsubmitted-retire"])
                , "foreign_child_preserved" .= foreignLive
                , "observed_terminal_ns" .= terminal
                , "elapsed_micros" .= ((finished - started) `div` 1000)
                , "family_absence_observed" .= True
                , "production_process_lifecycle_claim" .= False
                ]
            )
        )
 where
  whenDuplicate connection intent first limits helper creationEnd =
    if mode == "duplicate"
      then do
        again <- lift (startScopeFamily connection creationEnd intent (childFd first) limits helper)
        unless
          (again == Left ScopeFamilyAlreadyAttempted)
          (fixtureFailure ("family intent reused: " <> show again))
      else pure ()

assertAlarmArmed :: BusConnection -> ScopeFamilyIntent -> Word64 -> InvocationId -> IO ()
assertAlarmArmed connection intent hard expected = do
  observation <- runExceptT $ do
    path <-
      callManager
        connection
        GetUnit
        (\message -> appendString message (scopeFamilyUnitName intent FamilyTimer))
        (`readString` 'o')
    let readProperty interface name = callManager connection (ReadUnitProperty path) $ \message ->
          appendString message interface >> appendString message name
    invocation <- readProperty "org.freedesktop.systemd1.Unit" "InvocationID" readVariantInvocationId
    state <- readProperty "org.freedesktop.systemd1.Unit" "ActiveState" readVariantString
    job <- readProperty "org.freedesktop.systemd1.Unit" "Job" readVariantJob
    expiry <- readProperty "org.freedesktop.systemd1.Timer" "NextElapseUSecMonotonic" readVariantWord64
    pure (invocation, state, job, expiry)
  unless
    (observation == Right (expected, "active", UnitJobAbsent, hard `div` 1000))
    (fixtureFailure ("original expiry alarm changed: " <> show observation))

awaitFamilyAbsent :: BusConnection -> ScopeFamilyIntent -> BusAction ()
awaitFamilyAbsent connection intent = do
  observed <- observeScopeFamily connection intent
  if scopeFamilyAbsent observed
    then pure ()
    else do
      lift (threadDelay 1000)
      awaitFamilyAbsent connection intent

data Child = Child !ProcessID !Fd !Fd !(IORef (Maybe ProcessStatus))

childFd :: Child -> Fd
childFd (Child _ descriptor _ _) = descriptor

blockedChild :: IO Child
blockedChild = do
  (reader, writer) <- createPipe
  pid <- forkProcess $ do
    closeFd writer
    _ <- Posix.fdRead reader 1
    exitImmediately (ExitFailure 125)
  closeFd reader
  descriptor <- openPidfd (fromIntegral pid) 0
  unless (descriptor >= 0) (fixtureFailure "fixture child pidfd unavailable")
  state <- newIORef Nothing
  pure (Child pid (Fd descriptor) writer state)

ignoringTermChild :: IO Child
ignoringTermChild = bracket (installHandler sigTERM Ignore Nothing) restore (const blockedChild)
 where
  restore handler = void (installHandler sigTERM handler Nothing)

selfPidfd :: ProcessID -> IO Fd
selfPidfd pid = do
  descriptor <- openPidfd (fromIntegral pid) 0
  unless (descriptor >= 0) (fixtureFailure "fixture self pidfd unavailable")
  pure (Fd descriptor)

childLive :: Child -> IO Bool
childLive child = do
  let Fd descriptor = childFd child
  (== 0) <$> signalPidfd descriptor 0 nullPtr 0

stopChild :: Word64 -> Child -> IO ()
stopChild deadline child@(Child _ (Fd descriptor) _ _) = do
  void (signalPidfd descriptor 9 nullPtr 0)
  void (awaitChild deadline child)

releaseChild :: Word64 -> Child -> IO ()
releaseChild deadline child@(Child _ descriptor writer _) =
  stopChild deadline child `finally` (close writer `finally` close descriptor)
 where
  close fd = void (try (closeFd fd) :: IO (Either IOException ()))

awaitChild :: Word64 -> Child -> IO (Maybe ProcessStatus)
awaitChild deadline child@(Child pid _ _ state) = do
  prior <- readIORef state
  case prior of
    Just value -> pure (Just value)
    Nothing -> do
      observed <- getProcessStatus False False pid
      case observed of
        Just value -> writeIORef state (Just value) >> pure observed
        Nothing -> do
          now <- getMonotonicTimeNSec
          if now >= deadline then pure Nothing else threadDelay 1000 >> awaitChild deadline child

-- Hold an independent observer before exit, then require actual directory
-- retirement before asking the production observer. EOF/error alone is not proof.
retiredGroupObservation :: Word64 -> Child -> KernelScope -> IO (Either KernelScopeError ())
retiredGroupObservation deadline child scope =
  bracket
    (openFd ("/sys/fs/cgroup" <> kernelScopeControlGroup scope) ReadOnly flags {directory = True})
    closeFd
    $ \root ->
      bracket (openFdAt (Just root) "cgroup.events" ReadOnly flags) closeFd $ \events -> do
        before <- kernelScopeEmpty scope
        unless
          (before == Right False)
          (fixtureFailure ("retired control was not populated: " <> show before))
        killed <- killKernelScope scope
        unless (killed == Right ()) (fixtureFailure (show killed))
        stopped <- awaitChild deadline child
        unless (stopped == Just (Terminated 9 False)) (fixtureFailure "retired control child did not stop")
        let awaitRetirement = do
              now <- getMonotonicTimeNSec
              unless (now < deadline) (fixtureFailure "retired control exceeded original bound")
              target <- readSymbolicLink ("/proc/self/fd/" <> show root)
              relative <-
                try (bracket (openFdAt (Just root) "cgroup.events" ReadOnly flags) closeFd (const (pure ())))
              case relative :: Either IOException () of
                Left cause | isDoesNotExistError cause && " (deleted)" `isSuffixOf` target -> pure ()
                _ -> threadDelay 1000 >> awaitRetirement
        awaitRetirement
        raw <- try (fdSeek events AbsoluteSeek 0 >> Posix.fdRead events 4096)
        observed <- kernelScopeEmpty scope
        Lazy.putStrLn $
          encode $
            object
              [ "independent_held_group_retired" .= True
              , "retired_events_read" .= either show Bytes.unpack (raw :: Either IOException Bytes.ByteString)
              , "production_retirement_observation" .= show observed
              ]
        unless
          (observed == Right True)
          (fixtureFailure "retired group was not recognized by production observer")
        pure (Right ())
 where
  flags = defaultFileFlags {nofollow = True, cloexec = True}

awaitEmpty :: Word64 -> KernelScope -> IO Bool
awaitEmpty deadline scope = do
  observed <- kernelScopeEmpty scope
  case observed of
    Left cause -> fixtureFailure (show cause)
    Right True -> pure True
    Right False -> do
      now <- getMonotonicTimeNSec
      if now >= deadline then pure False else threadDelay 1000 >> awaitEmpty deadline scope

manager :: Word64 -> FilePath -> (BusConnection -> BusAction value) -> IO value
manager deadline socket action = withSystemdBus deadline socket action >>= either (fixtureFailure . show) pure

startScope :: BusConnection -> String -> Fd -> BusAction ()
startScope connection name (Fd descriptor) = void (callManager connection StartTransientUnit build (`readString` 'o'))
 where
  build message = do
    appendString message name
    appendString message "fail"
    withContainer message 'a' "(sv)" $ do
      property message "PIDFDs" "ah" (withContainer message 'a' "h" (appendDescriptor message descriptor))
      property message "CollectMode" "s" (appendString message "inactive-or-failed")
      mapM_
        (\(key, value) -> property message key "t" (appendWord64 message value))
        [ ("MemoryMax", 67108864)
        , ("MemorySwapMax", 0)
        , ("TasksMax", 16)
        , ("CPUQuotaPerSecUSec", 1000000)
        , ("RuntimeMaxUSec", 500000)
        , ("TimeoutStopUSec", 50000)
        ]
    withContainer message 'a' "(sa(sv))" (pure ())

property :: BusMessage -> String -> String -> BusAction () -> BusAction ()
property message name signature action = withContainer message 'r' "sv" $ do
  appendString message name
  withContainer message 'v' signature action

awaitAbsent :: BusConnection -> String -> BusAction ()
awaitAbsent connection name = do
  result <-
    lift
      ( runExceptT
          (callManager connection GetUnit (\message -> appendString message name) (`readString` 'o'))
      )
  case result of
    Left (BusMethodRefused 2) -> pure ()
    Left cause -> throwE cause
    Right _ -> lift (threadDelay 1000) >> awaitAbsent connection name

fixtureFailure :: (MonadIO m) => String -> m value
fixtureFailure message = liftIO (hPutStrLn stderr message >> ioError (userError message))
