{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A non-authorizing, process-wide exclusion boundary for one retained root.
-- Every mutating interpreter must use it and separately establish admission,
-- durable intent, effect settlement, and independent resource read-back.
module Prodbox.Control.KindLease
  ( KindLeaseError (..)
  , KindLeaseOutcome (..)
  , KindLeaseInterrupted (..)
  , withKindLease
  , withLockedKindScope
  , KindOperationRefusal (..)
  , KindOperationOutcome (..)
  , withNewKindOperation
  , withNewKindFamilyOperation
  , withNewKindOwnerFamilyOperation
  , withRecoveredKindOperation
  , withRecoveredKindOperationUntil
  , KindLeaseHandoff (..)
  , awaitKindLeaseHandoff
  , prepareNewKindVolumeDirectory
  , prepareRecoveredKindVolumeDirectory
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (Exception, IOException, SomeException, fromException, mask, throwIO, try)
import Data.Bits ((.&.), (.|.))
import Data.Text qualified as Text
import Data.Word (Word64)
import Foreign.C.Error (Errno (..), eAGAIN, eWOULDBLOCK, getErrno)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeDescriptorIoFailure
  , ScopeDescriptorOutcome (..)
  , ScopeGenerationObservation (..)
  , observeScopeGeneration
  , withScopeRootDescriptorPreserving
  )
import Prodbox.Config.KindVolume (KindVolume, KindVolumePreparation)
import Prodbox.Control.KindIntent
  ( KindIntentObservation (..)
  , KindIntentResult (..)
  , observeKindIntent
  , observeKindFamilyIntent
  , observeKindOwnerFamilyIntent
  , observeKindVolumeIntent
  , recordKindIntent
  , recordKindFamilyIntent
  , recordKindOwnerFamilyIntent
  , recordKindVolumeIntent
  )
import Prodbox.Control.KindVolumePrepare (prepareKindVolumeDirectory)
import System.IO.Error (IOErrorType, ioeGetErrorType)
import System.Posix.Files (fileMode, fileOwner, getFdStatus, isDirectory)
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h value LOCK_UN" releaseLock :: CInt
foreign import capi "sys/file.h flock" lockFile :: CInt -> CInt -> IO CInt

data KindLeaseError
  = KindLeaseBusy
  | KindLeaseDeadlineExpired
  | KindLeaseGenerationUnavailable
  | KindLeaseUnobservable
  | KindLeaseScopeCallbackFailed !IOErrorType ![ScopeDescriptorIoFailure]
  | KindLeaseScopeUnconfirmed !IOErrorType ![ScopeDescriptorIoFailure]
  | KindLeaseScopeCleanupAfterRefusal !KindLeaseError ![ScopeDescriptorIoFailure]
  | KindLeaseUnlockAfterRefusal !KindLeaseError !Int
  | KindLeaseCallbackAndUnlockFailed !IOErrorType !Int
  deriving (Eq, Show)

data KindLeaseOutcome value
  = KindLeaseCompleted !value
  | KindLeaseRootChanged !value
  | KindLeaseUnlockFailed !(KindLeaseOutcome value) !Int
  | KindLeaseScopeCleanupFailed !(KindLeaseOutcome value) ![ScopeDescriptorIoFailure]
  deriving (Eq, Show)

data KindOperationRefusal
  = KindOperationLeaseRefused !KindLeaseError
  | KindOperationIntentRefused !KindIntentResult
  | KindOperationObservationRefused !KindIntentObservation
  | KindOperationRootUnavailable
  deriving (Eq, Show)

data KindOperationOutcome value
  = KindOperationRefused !KindOperationRefusal
  | KindOperationUnconfirmed !KindLeaseError
  | KindOperationCallbackReturned !value
  | KindOperationRootChanged !(Either KindOperationRefusal value)
  | KindOperationUnlockFailed !(KindLeaseOutcome (Either KindOperationRefusal value)) !Int
  | KindOperationScopeCleanupFailed
      !(KindLeaseOutcome (Either KindOperationRefusal value))
      ![ScopeDescriptorIoFailure]
  deriving (Eq, Show)

-- The original exception is retained without rendering its arbitrary payload.
data KindLeaseInterrupted = KindLeaseInterrupted !SomeException !Int

instance Show KindLeaseInterrupted where
  show (KindLeaseInterrupted _ code) = "kind lease interrupted; unlock failed with errno " ++ show code

instance Exception KindLeaseInterrupted

-- | Compose exclusion, durable intent and read-back for a new operation.
-- Existing records require a recovery path. This boundary does not itself
-- authorize provider or kind effects, or settle any child spawned by action.
withNewKindOperation
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO value)
  -> IO (KindOperationOutcome value)
withNewKindOperation bootstrap operationId =
  withIntentOperation bootstrap operationId (observeKindIntent bootstrap) $ do
    intent <- recordKindIntent bootstrap operationId
    pure $ if intent == KindIntentRecorded then Right () else Left (KindOperationIntentRefused intent)

-- The protocol choice is part of the exclusive initial record. In particular,
-- it cannot be attached later to an operation of unknown provenance.
withNewKindFamilyOperation
  :: BootstrapProjection -> String -> (IO Bool -> IO value) -> IO (KindOperationOutcome value)
withNewKindFamilyOperation bootstrap operationId =
  withIntentOperation bootstrap operationId (observeKindFamilyIntent bootstrap) $ do
    intent <- recordKindFamilyIntent bootstrap operationId
    pure $ if intent == KindIntentRecorded then Right () else Left (KindOperationIntentRefused intent)

withNewKindOwnerFamilyOperation
  :: BootstrapProjection -> String -> (IO Bool -> IO value) -> IO (KindOperationOutcome value)
withNewKindOwnerFamilyOperation bootstrap operationId =
  withIntentOperation bootstrap operationId (observeKindOwnerFamilyIntent bootstrap) $ do
    intent <- recordKindOwnerFamilyIntent bootstrap operationId
    pure $ if intent == KindIntentRecorded then Right () else Left (KindOperationIntentRefused intent)

-- | Reacquire an existing, exactly matching intent without creating or
-- replacing it. The caller must independently settle any previous worker and
-- establish lifecycle admission before performing an effect.
withRecoveredKindOperation
  :: BootstrapProjection
  -> String
  -> (IO Bool -> IO value)
  -> IO (KindOperationOutcome value)
withRecoveredKindOperation bootstrap operationId =
  withIntentOperation bootstrap operationId (observeKindIntent bootstrap) (pure (Right ()))

-- Retry only a confirmed busy lease before entering the callback. Once a
-- callback starts its own bounds and settlement govern it; this helper never
-- times it out or repeats it. Unobservable and changed states fail closed.
withRecoveredKindOperationUntil
  :: Word64 -> BootstrapProjection -> String -> (IO Bool -> IO value)
  -> IO (KindOperationOutcome value)
withRecoveredKindOperationUntil ending bootstrap operation action = go
 where
  go = do
    now <- getMonotonicTimeNSec
    if now >= ending then pure (KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired)) else do
      result <- withRecoveredKindOperation bootstrap operation action
      case result of
        KindOperationRefused (KindOperationLeaseRefused KindLeaseBusy) -> do
          after <- getMonotonicTimeNSec
          if after >= ending then pure (KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired))
            else do
              let remaining = (ending - after) `div` 1000
              if remaining == 0 then pure (KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired))
                else threadDelay (fromIntegral (min 50000 remaining)) >> go
        _ -> pure result

data KindLeaseHandoff
  = KindLeaseHandoffReady
  | KindLeaseHandoffExpired
  | KindLeaseHandoffUnstable
  | KindLeaseHandoffRefused !(KindOperationOutcome Bool)
  deriving (Eq, Show)

-- Wait only for the launcher to release this same recovered operation. A
-- busy lease is the sole retryable observation; all uncertain closing results
-- and changes to the pinned process owner fail closed. This does not carry a
-- lease into the worker or replace the worker's own per-effect acquisition.
awaitKindLeaseHandoff :: Word64 -> BootstrapProjection -> String -> IO Bool -> IO KindLeaseHandoff
awaitKindLeaseHandoff ending bootstrap operation ownerStable = do
  now <- getMonotonicTimeNSec
  if now >= ending || (ending - now) `div` 1000 == 0
    then pure KindLeaseHandoffExpired
    else do
      let micros = min (fromIntegral (maxBound :: Int) :: Word64) ((ending - now) `div` 1000)
      result <- timeout (fromIntegral micros) loop
      finished <- getMonotonicTimeNSec
      pure $ case result of
        Nothing -> KindLeaseHandoffExpired
        Just KindLeaseHandoffReady | finished >= ending -> KindLeaseHandoffExpired
        Just outcome -> outcome
 where
  loop = do
    owner <- ownerStable
    if not owner then pure KindLeaseHandoffUnstable else do
      observed <- withRecoveredKindOperation bootstrap operation $ \stable -> (&&) <$> stable <*> ownerStable
      case observed of
        KindOperationRefused (KindOperationLeaseRefused KindLeaseBusy) -> threadDelay 50000 >> loop
        KindOperationCallbackReturned True -> do
          final <- ownerStable
          pure (if final then KindLeaseHandoffReady else KindLeaseHandoffUnstable)
        KindOperationCallbackReturned False -> pure KindLeaseHandoffUnstable
        _ -> pure (KindLeaseHandoffRefused observed)

-- | Record the exact volume before entering the callback. This is not a
-- lifecycle admission permit or proof that an earlier worker settled.
prepareNewKindVolumeDirectory
  :: BootstrapProjection
  -> String
  -> KindVolume
  -> IO (KindOperationOutcome KindVolumePreparation)
prepareNewKindVolumeDirectory bootstrap operationId volume =
  withIntentOperation bootstrap operationId (observeKindVolumeIntent bootstrap volume) prepare $ \recheck ->
    prepareKindVolumeDirectory bootstrap volume recheck
 where
  prepare = do
    intent <- recordKindVolumeIntent bootstrap operationId volume
    pure $ if intent == KindIntentRecorded then Right () else Left (KindOperationIntentRefused intent)

prepareRecoveredKindVolumeDirectory
  :: BootstrapProjection
  -> String
  -> KindVolume
  -> IO (KindOperationOutcome KindVolumePreparation)
prepareRecoveredKindVolumeDirectory bootstrap operationId volume =
  withIntentOperation
    bootstrap
    operationId
    (observeKindVolumeIntent bootstrap volume)
    (pure (Right ()))
    (prepareKindVolumeDirectory bootstrap volume)

withIntentOperation
  :: BootstrapProjection
  -> String
  -> IO KindIntentObservation
  -> IO (Either KindOperationRefusal ())
  -> (IO Bool -> IO value)
  -> IO (KindOperationOutcome value)
withIntentOperation bootstrap operationId observe prepare action = do
  result <- withKindLease bootstrap $ \recheck -> do
    prepared <- prepare
    case prepared of
      Left refusal -> pure (Left refusal)
      Right () -> do
        observed <- observe
        if observed /= KindIntentMatches operationId
          then pure (Left (KindOperationObservationRefused observed))
          else do
            let recheckIntent = do
                  before <- recheck
                  current <- observe
                  after <- recheck
                  pure (before && current == KindIntentMatches operationId && after)
            stable <- recheckIntent
            if not stable
              then pure (Left KindOperationRootUnavailable)
              else Right <$> action recheckIntent
  pure $ case result of
    Left failure | leaseErrorUnconfirmed failure -> KindOperationUnconfirmed failure
    Left failure -> KindOperationRefused (KindOperationLeaseRefused failure)
    Right (KindLeaseCompleted (Left failure)) -> KindOperationRefused failure
    Right (KindLeaseCompleted (Right value)) -> KindOperationCallbackReturned value
    Right (KindLeaseRootChanged step) -> KindOperationRootChanged step
    Right (KindLeaseUnlockFailed step failure) -> KindOperationUnlockFailed step failure
    Right (KindLeaseScopeCleanupFailed step failures) -> KindOperationScopeCleanupFailed step failures

leaseErrorUnconfirmed :: KindLeaseError -> Bool
leaseErrorUnconfirmed failure = case failure of
  KindLeaseScopeCallbackFailed {} -> True
  KindLeaseScopeUnconfirmed {} -> True
  KindLeaseCallbackAndUnlockFailed {} -> True
  KindLeaseScopeCleanupAfterRefusal previous _ -> leaseErrorUnconfirmed previous
  KindLeaseUnlockAfterRefusal previous _ -> leaseErrorUnconfirmed previous
  _ -> False

-- | Borrow an already validated scope descriptor and attempt its lease once.
-- The supplied recheck must bind the descriptor to the selected generation;
-- this helper does not establish that binding, admit effects or settle work.
-- Unlock is always attempted after acquisition. A returned value or callback
-- I/O failure remains separate from an unlock failure. Other exceptions are
-- rethrown after unlock, with the original retained if unlock also fails.
withLockedKindScope
  :: forall value
   . Fd
  -> IO Bool
  -> (IO Bool -> IO value)
  -> IO (Either KindLeaseError (KindLeaseOutcome value))
withLockedKindScope (Fd descriptor) recheck action = mask $ \restore -> do
  acquired <- lockFile descriptor (exclusiveLock .|. nonBlockingLock)
  if acquired /= 0
    then do
      cause <- getErrno
      pure $
        Left (if cause == eAGAIN || cause == eWOULDBLOCK then KindLeaseBusy else KindLeaseUnobservable)
    else do
      primary <- try $ do
        fresh <- recheck
        if not fresh
          then pure (Left KindLeaseGenerationUnavailable)
          else do
            value <- restore (action recheck)
            final <- recheck
            pure $ Right (if final then KindLeaseCompleted value else KindLeaseRootChanged value)
      released <- lockFile descriptor releaseLock
      cleanup <-
        if released == 0 then pure Nothing else do Errno code <- getErrno; pure (Just (fromIntegral code))
      case (primary :: Either SomeException (Either KindLeaseError (KindLeaseOutcome value)), cleanup) of
        (Right outcome, Nothing) -> pure outcome
        (Right (Left failure), Just code) -> pure (Left (KindLeaseUnlockAfterRefusal failure code))
        (Right (Right value), Just code) -> pure (Right (KindLeaseUnlockFailed value code))
        (Left exception, Nothing) -> case fromException exception of
          Just (failure :: IOException) -> pure (Left (KindLeaseScopeCallbackFailed (ioeGetErrorType failure) []))
          Nothing -> throwIO exception
        (Left exception, Just code) -> case fromException exception of
          Just (failure :: IOException) -> pure (Left (KindLeaseCallbackAndUnlockFailed (ioeGetErrorType failure) code))
          Nothing -> throwIO (KindLeaseInterrupted exception code)

-- | The callback receives a fresh root/generation observation to recheck at
-- effect boundaries. A lease excludes only cooperating users of this same
-- inode. It does not provide admission, stop a detached child, or establish
-- that any resources are absent. Callback I/O failures are retained as
-- unconfirmed categories after release; asynchronous exceptions propagate.
withKindLease
  :: BootstrapProjection -> (IO Bool -> IO value) -> IO (Either KindLeaseError (KindLeaseOutcome value))
withKindLease bootstrap action = do
  outcome <- withScopeRootDescriptorPreserving scope $ \root sameRoot -> mask $ \restore -> do
    current <- validRoot root sameRoot
    if not current
      then pure (Left KindLeaseGenerationUnavailable)
      else restore (withLockedKindScope root (validRoot root sameRoot) action)
  pure $ case outcome of
    ScopeDescriptorRefused _ _ -> Left KindLeaseUnobservable
    ScopeDescriptorCallbackFailed failure details -> Left (KindLeaseScopeCallbackFailed failure details)
    ScopeDescriptorUnconfirmed failure details -> Left (KindLeaseScopeUnconfirmed failure details)
    ScopeDescriptorReturned result -> result
    ScopeDescriptorCleanupFailedAfter (Left failure) details -> Left (KindLeaseScopeCleanupAfterRefusal failure details)
    ScopeDescriptorCleanupFailedAfter (Right result) details -> Right (KindLeaseScopeCleanupFailed result details)
 where
  scope = bootstrapScope bootstrap
  generation = Text.unpack (bootstrapRootGeneration bootstrap)
  validRoot root sameRoot = do
    result <- try $ do
      owner <- getEffectiveUserID
      status <- getFdStatus root
      stable <- sameRoot
      observed <- observeScopeGeneration scope generation
      pure
        ( isDirectory status
            && fileOwner status == owner
            && fileMode status .&. 0o022 == 0
            && stable
            && observed == Right ScopeGenerationMatches
        )
    pure $ either (const False) id (result :: Either IOException Bool)
