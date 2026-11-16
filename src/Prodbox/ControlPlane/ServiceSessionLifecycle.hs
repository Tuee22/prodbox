{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exception-safe interpreter for the retained per-role service-session
-- journal. It performs at most one Kubernetes login for a committed attempt.
-- Externally dispatched ambiguous attempts remain occupied pending workload
-- retirement; in-process session cleanup has its own recovery protocol.
module Prodbox.ControlPlane.ServiceSessionLifecycle
  ( ServiceSessionLoginBoundary (..)
  , ServiceSessionSubjects (..)
  , ServiceSessionLifecycleError (..)
  , allocateNextServiceSessionBinding
  , reserveServiceSessionCreation
  , issueServiceSessionCreation
  , prepareReservedServiceSessionDispatch
  , beginReservedServiceSessionDispatch
  , settleReservedServiceSessionDispatch
  , retireReservedServiceSessionWorkload
  , prepareFencedServiceSessionDispatch
  , prepareFencedServiceSessionDispatchWithWorkload
  , activateFencedServiceSessionDispatch
  , closeFencedServiceSessionDispatch
  , recoverRetiredServiceSessionDispatch
  , acquireFencedServiceSession
  , closeFencedServiceSession
  , withFencedServiceSession
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , throwIO
  , try
  )
import Control.Monad qualified
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionCreationReservation
  , ServiceSessionDispatchState (..)
  , ServiceSessionEvent (..)
  , ServiceSessionJournal
  , ServiceSessionJournalError
  , ServiceSessionJournalRepository (..)
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionJournalStoreError (..)
  , ServiceSessionPhase (..)
  , ServiceSessionWorkload
  , ServiceSessionWorkloadEvidence
  , applyServiceSessionJournalEvent
  , mkServiceSessionBinding
  , mkServiceSessionCreationReservation
  , serviceSessionBindingFence
  , serviceSessionBindingRole
  , serviceSessionCreationFence
  , serviceSessionJournalDispatchState
  , serviceSessionJournalPhase
  , serviceSessionJournalRecoverableRetirement
  , serviceSessionJournalRole
  , stepServiceSessionJournal
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditError
  , VaultAccessorAuditOps (..)
  , VaultAccessorSubject
  , revokeAndProveVaultAccessorSubjectAbsent
  , vaultAccessorMatchesSubject
  )
import Prodbox.Lifecycle.Lease (OwnerNonce)
import Prodbox.Lifecycle.LeaseRuntime (generateSecureOwnerNonce)

data ServiceSessionLoginBoundary login = ServiceSessionLoginBoundary
  { attemptServiceSessionLogin :: IO (Either Text login)
  , serviceSessionLoginAccessor :: login -> Text
  , revokeServiceSessionLogin :: login -> IO (Either Text ())
  }

-- | Role-wide cleanup intentionally omits the current ServiceAccount UID,
-- while active-login classification includes it.  The retained journal makes
-- the static role lane single-owner, so recovery can safely remove a session
-- left by a previous incarnation of the same named ServiceAccount.
data ServiceSessionSubjects = ServiceSessionSubjects
  { serviceSessionCleanupSubject :: !VaultAccessorSubject
  , serviceSessionActiveSubject :: !VaultAccessorSubject
  }
  deriving stock (Eq, Show)

data ServiceSessionLifecycleError
  = ServiceSessionLifecycleJournalFailed !ServiceSessionJournalStoreError
  | ServiceSessionLifecycleJournalUnavailable !Text
  | ServiceSessionLifecycleBindingRoleMismatch
  | ServiceSessionLifecycleRoleOccupied
  | ServiceSessionLifecycleBindingInvalid !ServiceSessionJournalError
  | ServiceSessionLifecyclePrecleanFailed !VaultAccessorAuditError
  | ServiceSessionLifecycleLoginFailedCleaned !Text
  | ServiceSessionLifecycleLoginAmbiguityCleaned
  | ServiceSessionLifecycleAccessorInvalid
  | ServiceSessionLifecycleAccessorIdentityMismatch
  | ServiceSessionLifecycleCleanupFailed !VaultAccessorAuditError
  | ServiceSessionLifecycleCleanupThrew
  | ServiceSessionLifecycleCleanupJournalFailed !ServiceSessionJournalStoreError
  | ServiceSessionLifecycleActionFailed !Text
  | ServiceSessionLifecycleUnhandledException
  deriving stock (Eq, Show)

-- | Read the retained role lane and derive its only admissible successor
-- fence.  The later Begin CAS is the allocation linearization point, so two
-- callers racing on this read cannot both own the same successor.
allocateNextServiceSessionBinding
  :: ServiceSessionJournalRepository IO revision
  -> Text
  -> Text
  -> Text
  -> IO (Either ServiceSessionLifecycleError ServiceSessionBinding)
allocateNextServiceSessionBinding repository role operationId attemptId = do
  observed <- readServiceSessionJournal repository
  pure $ case observed of
    Left detail -> Left (ServiceSessionLifecycleJournalUnavailable detail)
    Right snapshot
      | role /= serviceSessionJournalRole (serviceSessionJournalObserved snapshot) ->
          Left ServiceSessionLifecycleBindingRoleMismatch
      | otherwise ->
          let nextFence = phaseFence (serviceSessionJournalPhase (serviceSessionJournalObserved snapshot)) + 1
           in case mkServiceSessionBinding role operationId attemptId nextFence of
                Left err -> Left (ServiceSessionLifecycleBindingInvalid err)
                Right binding -> Right binding

-- | Claim the Target role before creating its deterministic Job. Only a
-- positively acknowledged CAS authorizes the caller to issue a create.
reserveServiceSessionCreation
  :: ServiceSessionJournalRepository IO revision
  -> Text
  -> Text
  -> Text
  -> IO (Either ServiceSessionLifecycleError ServiceSessionCreationReservation)
reserveServiceSessionCreation repository role operation job = mask_ $ do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot
      | serviceSessionJournalRole (serviceSessionJournalObserved snapshot) /= role ->
          pure (Left ServiceSessionLifecycleBindingRoleMismatch)
      | otherwise -> case serviceSessionJournalPhase (serviceSessionJournalObserved snapshot) of
          ServiceSessionVacant previousFence ->
            case mkServiceSessionCreationReservation operation job (previousFence + 1) of
              Left err -> pure (Left (ServiceSessionLifecycleBindingInvalid err))
              Right reservation -> do
                committed <-
                  commitExternalTransitionOnce repository snapshot (ReserveServiceSessionCreation reservation)
                pure (reservation <$ committed)
          _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

-- The acknowledged transition must precede the Kubernetes create. A lost
-- reply is ambiguous and must not be adopted as permission to create.
issueServiceSessionCreation
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionCreationReservation
  -> IO (Either ServiceSessionLifecycleError ())
issueServiceSessionCreation repository reservation = mask_ $ do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot ->
      fmap Control.Monad.void $
        commitExternalTransitionOnce repository snapshot (IssueServiceSessionCreation reservation)

prepareReservedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionCreationReservation
  -> ServiceSessionBinding
  -> ServiceSessionWorkloadEvidence
  -> IO (Either ServiceSessionLifecycleError ())
prepareReservedServiceSessionDispatch repository auditOps subject reservation binding evidence =
  prepareFencedServiceSessionDispatchWithEvent
    repository
    auditOps
    subject
    binding
    (BindServiceSessionCreation reservation binding evidence)

-- | Establish the durable boundary for a one-shot process that performs its
-- own Kubernetes login. Success means the role was stably precleaned and
-- @LoginAttemptCommitted@ was stored before stdin or attach may be released.
-- Re-entry at that committed phase is ambiguous and remains occupied instead
-- of dispatching a second login.
prepareFencedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> IO (Either ServiceSessionLifecycleError ())
prepareFencedServiceSessionDispatch repository auditOps cleanupSubject binding =
  prepareFencedServiceSessionDispatchWithEvent
    repository
    auditOps
    cleanupSubject
    binding
    (BeginServiceSessionAcquisition binding)

-- | Atomically retain exact workload identity in the same CAS that claims
-- the external dispatch lane, before any login attempt can be committed.
prepareFencedServiceSessionDispatchWithWorkload
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> ServiceSessionWorkloadEvidence
  -> IO (Either ServiceSessionLifecycleError ())
prepareFencedServiceSessionDispatchWithWorkload repository auditOps cleanupSubject binding evidence =
  prepareFencedServiceSessionDispatchWithEvent
    repository
    auditOps
    cleanupSubject
    binding
    (BeginServiceSessionVerifiedWorkload binding evidence)

prepareFencedServiceSessionDispatchWithEvent
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> ServiceSessionEvent
  -> IO (Either ServiceSessionLifecycleError ())
prepareFencedServiceSessionDispatchWithEvent repository auditOps cleanupSubject binding beginEvent =
  mask $ \_ -> do
    attempted <- tryAny drive
    case attempted of
      Left exception
        | isAsyncException exception -> throwIO exception
        | otherwise -> pure (Left ServiceSessionLifecycleUnhandledException)
      Right result -> pure result
 where
  drive = do
    started <- case beginEvent of
      BindServiceSessionCreation {} -> bindReservedDispatchOnce repository binding beginEvent
      _ -> beginExternalDispatchOnce repository binding beginEvent
    case started of
      Left err -> pure (Left err)
      Right journal -> resume journal

  resume journal = case serviceSessionJournalPhase journal of
    ServiceSessionAcquiring existing
      | existing == binding -> do
          precleaned <-
            revokeAndProveVaultAccessorSubjectAbsent auditOps cleanupSubject Nothing
          case precleaned of
            Left err -> pure (Left (ServiceSessionLifecyclePrecleanFailed err))
            Right () -> do
              committed <- commitDispatch (CommitServiceSessionPrecleaned binding)
              either (pure . Left) resume committed
    ServiceSessionPrecleaned existing
      | existing == binding -> do
          committed <- commitDispatch (CommitServiceSessionLoginAttempt binding)
          pure (Control.Monad.void committed)
    ServiceSessionLoginAttemptCommitted existing
      | existing == binding -> pure (Left ServiceSessionLifecycleRoleOccupied)
    ServiceSessionActive existing _
      | existing == binding -> pure (Left ServiceSessionLifecycleRoleOccupied)
    ServiceSessionCleanupRequired existing _
      | existing == binding -> pure (Left ServiceSessionLifecycleRoleOccupied)
    ServiceSessionCleanupProven existing
      | existing == binding -> pure (Left ServiceSessionLifecycleRoleOccupied)
    _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

  commitDispatch event =
    fmap
      (either (Left . ServiceSessionLifecycleJournalFailed) Right)
      (applyServiceSessionJournalEvent repository event)

-- An exact read-back after a failed acquisition CAS cannot identify which
-- caller won. Only a positively acknowledged CAS may authorize dispatch.
beginExternalDispatchOnce
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> ServiceSessionEvent
  -> IO (Either ServiceSessionLifecycleError ServiceSessionJournal)
beginExternalDispatchOnce repository binding beginEvent = do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot
      | serviceSessionJournalRole (serviceSessionJournalObserved snapshot)
          /= serviceSessionBindingRole binding ->
          pure (Left ServiceSessionLifecycleBindingRoleMismatch)
      | otherwise -> case serviceSessionJournalPhase (serviceSessionJournalObserved snapshot) of
          ServiceSessionVacant previousFence
            | serviceSessionBindingFence binding > previousFence ->
                case stepServiceSessionJournal
                  beginEvent
                  (serviceSessionJournalObserved snapshot) of
                  Left failure -> pure (Left (ServiceSessionLifecycleBindingInvalid failure))
                  Right expected -> do
                    written <-
                      compareAndSwapServiceSessionJournal repository (serviceSessionJournalRevision snapshot) expected
                    case written of
                      Left detail ->
                        pure (Left (ServiceSessionLifecycleJournalFailed (ServiceSessionJournalStoreCommitFailed detail)))
                      Right () -> do
                        confirmed <- readServiceSessionJournal repository
                        pure $ case confirmed of
                          Left detail -> Left (ServiceSessionLifecycleJournalFailed (ServiceSessionJournalStoreUnavailable detail))
                          Right actual
                            | serviceSessionJournalObserved actual == expected -> Right expected
                            | otherwise ->
                                Left (ServiceSessionLifecycleJournalFailed ServiceSessionJournalStoreReadBackMismatch)
          _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

bindReservedDispatchOnce
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> ServiceSessionEvent
  -> IO (Either ServiceSessionLifecycleError ServiceSessionJournal)
bindReservedDispatchOnce repository binding event = do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot
      | serviceSessionJournalRole (serviceSessionJournalObserved snapshot)
          /= serviceSessionBindingRole binding ->
          pure (Left ServiceSessionLifecycleBindingRoleMismatch)
      | otherwise -> commitExternalTransitionOnce repository snapshot event

commitExternalTransitionOnce
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionJournalSnapshot revision
  -> ServiceSessionEvent
  -> IO (Either ServiceSessionLifecycleError ServiceSessionJournal)
commitExternalTransitionOnce repository snapshot event =
  case stepServiceSessionJournal event (serviceSessionJournalObserved snapshot) of
    Left failure -> pure (Left (ServiceSessionLifecycleBindingInvalid failure))
    Right expected -> do
      written <-
        compareAndSwapServiceSessionJournal repository (serviceSessionJournalRevision snapshot) expected
      case written of
        Left detail ->
          pure (Left (ServiceSessionLifecycleJournalFailed (ServiceSessionJournalStoreCommitFailed detail)))
        Right () -> do
          confirmed <- readServiceSessionJournal repository
          pure $ case confirmed of
            Left detail -> Left (ServiceSessionLifecycleJournalFailed (ServiceSessionJournalStoreUnavailable detail))
            Right actual
              | serviceSessionJournalObserved actual == expected -> Right expected
              | otherwise ->
                  Left (ServiceSessionLifecycleJournalFailed ServiceSessionJournalStoreReadBackMismatch)

-- | Only an acknowledged transition grants authority to attach the worker.
beginReservedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> IO (Either ServiceSessionLifecycleError ())
beginReservedServiceSessionDispatch repository binding =
  fmap
    Control.Monad.void
    (bindReservedDispatchOnce repository binding (BeginServiceSessionDispatch binding))

-- | Record the worker's acknowledged terminal cleanup before lane cleanup.
settleReservedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> IO (Either ServiceSessionLifecycleError ())
settleReservedServiceSessionDispatch repository binding =
  fmap
    Control.Monad.void
    (bindReservedDispatchOnce repository binding (SettleServiceSessionDispatch binding))

-- | Record exact Job/Pod absence before session cleanup can begin.
retireReservedServiceSessionWorkload
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> ServiceSessionWorkload
  -> IO (Either ServiceSessionLifecycleError ())
retireReservedServiceSessionWorkload repository binding workload =
  fmap
    Control.Monad.void
    (bindReservedDispatchOnce repository binding (RetireServiceSessionWorkload binding workload))

-- | Bind a server-issued accessor to an externally executed login attempt.
-- The one-shot worker must remain blocked until this returns: classification
-- uses the exact active subject (including its ServiceAccount UID), and the
-- durable @Active@ transition is the authorization to begin worker cleanup.
activateFencedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> Text
  -> IO (Either ServiceSessionLifecycleError ())
activateFencedServiceSessionDispatch repository auditOps activeSubject binding rawAccessor =
  mask_ $ do
    let accessor = Text.strip rawAccessor
    if Text.null accessor || accessor /= rawAccessor || Text.length accessor > 512
      then pure (Left ServiceSessionLifecycleAccessorInvalid)
      else do
        classified <- auditLookupAccessor auditOps accessor
        case classified of
          Left _ -> pure (Left ServiceSessionLifecycleAccessorIdentityMismatch)
          Right info
            | not (vaultAccessorMatchesSubject activeSubject info) ->
                pure (Left ServiceSessionLifecycleAccessorIdentityMismatch)
            | otherwise -> commitActive accessor
 where
  commitActive accessor = do
    observed <- readServiceSessionJournal repository
    case observed of
      Left detail ->
        pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
      Right snapshot
        | serviceSessionJournalRole (serviceSessionJournalObserved snapshot)
            /= serviceSessionBindingRole binding ->
            pure (Left ServiceSessionLifecycleBindingRoleMismatch)
        | otherwise ->
            case serviceSessionJournalPhase (serviceSessionJournalObserved snapshot) of
              ServiceSessionLoginAttemptCommitted existing
                | existing == binding ->
                    fmap
                      (either (Left . ServiceSessionLifecycleJournalFailed) (const (Right ())))
                      ( applyServiceSessionJournalEvent
                          repository
                          (CommitServiceSessionActive binding accessor)
                      )
              ServiceSessionActive existing activeAccessor
                | existing == binding && activeAccessor == accessor -> pure (Right ())
              _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

-- | Close an externally executed login attempt without ever requiring its
-- bearer in coordinator memory. The role-wide auditor proves stable absence,
-- then the retained lane advances through @CleanupProven@ to @Vacant@.
closeFencedServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> IO (Either ServiceSessionLifecycleError ())
closeFencedServiceSessionDispatch repository auditOps cleanupSubject binding = mask_ $ do
  ownerResult <- generateSecureOwnerNonce
  case ownerResult of
    Left _ -> pure (Left (ServiceSessionLifecycleActionFailed "cleanup owner generation failed"))
    Right owner -> do
      observed <- readServiceSessionJournal repository
      case observed of
        Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
        Right snapshot -> do
          claimed <-
            commitExternalTransitionOnce repository snapshot (ClaimServiceSessionCleanup binding owner)
          case claimed of
            Left err -> pure (Left err)
            Right journal -> finishOwnedDispatchCleanup repository auditOps cleanupSubject binding owner journal

-- | Release a durably proven owned cleanup, or claim an unclaimed retirement.
-- The latter claim precedes independent exact-UID observation and role audit.
recoverRetiredServiceSessionDispatch
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> (ServiceSessionWorkload -> IO (Either Text Bool))
  -> IO (Either ServiceSessionLifecycleError Bool)
recoverRetiredServiceSessionDispatch repository auditOps cleanupSubject observeAbsent = mask_ $ do
  attempted <-
    tryAny (recoverRetiredServiceSessionDispatchOnce repository auditOps cleanupSubject observeAbsent)
  case attempted of
    Left exception
      | isAsyncException exception -> throwIO exception
      | otherwise -> pure (Left ServiceSessionLifecycleUnhandledException)
    Right result -> pure result

recoverRetiredServiceSessionDispatchOnce
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> (ServiceSessionWorkload -> IO (Either Text Bool))
  -> IO (Either ServiceSessionLifecycleError Bool)
recoverRetiredServiceSessionDispatchOnce repository auditOps cleanupSubject observeAbsent = do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot -> recoverSnapshot snapshot
 where
  recoverSnapshot snapshot = case (serviceSessionJournalPhase journal, serviceSessionJournalDispatchState journal) of
    (ServiceSessionCreationPrepared reservation, _) ->
      fmap (fmap (const True)) $
        commitExternalTransitionOnce repository snapshot (ReleasePreparedServiceSessionCreation reservation)
    (ServiceSessionCleanupProven binding, Just (ServiceSessionDispatchCleanupOwned owner)) ->
      fmap (fmap (const True)) $
        commitExternalTransitionOnce repository snapshot (ReleaseOwnedServiceSession binding owner)
    _ -> recoverRetirement snapshot
   where
    journal = serviceSessionJournalObserved snapshot

  recoverRetirement snapshot = case serviceSessionJournalRecoverableRetirement (serviceSessionJournalObserved snapshot) of
    Nothing -> pure (Right False)
    Just (binding, workload) -> do
      ownerResult <- generateSecureOwnerNonce
      case ownerResult of
        Left _ -> pure (Left (ServiceSessionLifecycleActionFailed "cleanup owner generation failed"))
        Right owner -> do
          claimed <-
            commitExternalTransitionOnce repository snapshot (ClaimServiceSessionCleanup binding owner)
          case claimed of
            Left err -> pure (Left err)
            Right journal -> do
              absent <- tryAny (observeAbsent workload)
              case absent of
                Left exception | isAsyncException exception -> throwIO exception
                Right (Right True) ->
                  fmap
                    (fmap (const True))
                    (finishOwnedDispatchCleanup repository auditOps cleanupSubject binding owner journal)
                _ -> pure (Left (ServiceSessionLifecycleActionFailed "retired workload absence unobservable"))

finishOwnedDispatchCleanup
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> OwnerNonce
  -> ServiceSessionJournal
  -> IO (Either ServiceSessionLifecycleError ())
finishOwnedDispatchCleanup repository auditOps cleanupSubject binding owner journal = do
  let knownAccessor = case serviceSessionJournalPhase journal of
        ServiceSessionActive _ accessor -> Just accessor
        _ -> Nothing
      applyOwned event =
        fmap
          (either (Left . ServiceSessionLifecycleCleanupJournalFailed) Right)
          (applyServiceSessionJournalEvent repository event)
  required <- applyOwned (RequireOwnedServiceSessionCleanup binding owner)
  case required of
    Left err -> pure (Left err)
    Right _ -> do
      audited <- tryAny (revokeAndProveVaultAccessorSubjectAbsent auditOps cleanupSubject knownAccessor)
      case audited of
        Left exception | isAsyncException exception -> throwIO exception
        Left _ -> pure (Left ServiceSessionLifecycleCleanupThrew)
        Right (Left err) -> pure (Left (ServiceSessionLifecycleCleanupFailed err))
        Right (Right ()) -> do
          proven <- applyOwned (ProveOwnedServiceSessionCleanup binding owner)
          case proven of
            Left err -> pure (Left err)
            Right _ -> fmap Control.Monad.void (applyOwned (ReleaseOwnedServiceSession binding owner))

acquireFencedServiceSession
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> ServiceSessionSubjects
  -> ServiceSessionBinding
  -> ServiceSessionLoginBoundary login
  -> IO (Either ServiceSessionLifecycleError login)
acquireFencedServiceSession repository auditOps subjects binding loginBoundary =
  mask $ \restore -> do
    loginRef <- newIORef Nothing
    attempted <- tryAny (drive restore loginRef)
    case attempted of
      Left exception -> do
        cleaned <- cleanupIfOwned loginRef
        if isAsyncException exception
          then throwIO exception
          else pure $ case cleaned of
            Left err -> Left err
            Right () -> Left ServiceSessionLifecycleUnhandledException
      Right (Right login) -> pure (Right login)
      Right (Left err) -> do
        cleaned <- cleanupIfOwned loginRef
        pure $ case cleaned of
          Left cleanupError -> Left cleanupError
          Right () -> Left err
 where
  drive restore loginRef = do
    started <- beginOrResume repository binding
    case started of
      Left ServiceSessionLifecycleRoleOccupied ->
        recoverPredecessor restore loginRef
      Left err -> pure (Left err)
      Right journal -> resume restore loginRef journal

  recoverPredecessor restore loginRef = do
    observed <- readServiceSessionJournal repository
    case observed of
      Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
      Right snapshot ->
        case phaseBinding
          (serviceSessionJournalPhase (serviceSessionJournalObserved snapshot)) of
          Just predecessor
            | predecessor /= binding
                && serviceSessionBindingFence binding
                  > serviceSessionBindingFence predecessor -> do
                cleaned <-
                  cleanupFencedSession
                    repository
                    auditOps
                    cleanupSubject
                    predecessor
                    loginBoundary
                    loginRef
                case cleaned of
                  Left err -> pure (Left err)
                  Right () -> drive restore loginRef
          _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

  cleanupIfOwned loginRef = do
    maybeLogin <- readIORef loginRef
    case maybeLogin of
      -- Once a login response has returned, the in-memory bearer is sufficient
      -- cleanup authority even if the retained journal is temporarily
      -- unreadable.  cleanupFencedSession revokes it before attempting any
      -- journal transition.
      Just _ ->
        cleanupFencedSession
          repository
          auditOps
          cleanupSubject
          binding
          loginBoundary
          loginRef
      Nothing -> do
        observed <- readServiceSessionJournal repository
        case observed of
          Left detail ->
            pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
          Right snapshot
            | phaseBinding (serviceSessionJournalPhase (serviceSessionJournalObserved snapshot))
                == Just binding ->
                cleanupFencedSession
                  repository
                  auditOps
                  cleanupSubject
                  binding
                  loginBoundary
                  loginRef
          _ -> pure (Right ())

  resume restore loginRef journal = case serviceSessionJournalPhase journal of
    ServiceSessionAcquiring existing
      | existing == binding -> do
          precleaned <-
            revokeAndProveVaultAccessorSubjectAbsent auditOps cleanupSubject Nothing
          case precleaned of
            Left err -> pure (Left (ServiceSessionLifecyclePrecleanFailed err))
            Right () -> do
              committed <- commit (CommitServiceSessionPrecleaned binding)
              either (pure . Left) (resume restore loginRef) committed
    ServiceSessionPrecleaned existing
      | existing == binding -> do
          committed <- commit (CommitServiceSessionLoginAttempt binding)
          case committed of
            Left err -> pure (Left err)
            Right _ -> loginOnce restore loginRef
    -- This phase is durable before the HTTP request.  Seeing it on entry is
    -- ambiguous by construction, so recovery must not dispatch another login.
    ServiceSessionLoginAttemptCommitted existing
      | existing == binding -> do
          cleaned <-
            cleanupFencedSession
              repository
              auditOps
              cleanupSubject
              binding
              loginBoundary
              loginRef
          pure $ case cleaned of
            Left err -> Left err
            Right () -> Left ServiceSessionLifecycleLoginAmbiguityCleaned
    ServiceSessionActive existing _
      | existing == binding -> do
          -- The bearer value is deliberately absent from the journal.  A
          -- restarted process therefore cleans the correlated accessor and
          -- requires a greater fenced successor rather than pretending to
          -- resume the old in-memory session.
          cleaned <-
            cleanupFencedSession
              repository
              auditOps
              cleanupSubject
              binding
              loginBoundary
              loginRef
          pure $ case cleaned of
            Left err -> Left err
            Right () -> Left ServiceSessionLifecycleLoginAmbiguityCleaned
    ServiceSessionCleanupRequired existing _
      | existing == binding -> cleanRecovered
    ServiceSessionCleanupProven existing
      | existing == binding -> cleanRecovered
    _ -> pure (Left ServiceSessionLifecycleRoleOccupied)
   where
    cleanRecovered = do
      cleaned <-
        cleanupFencedSession
          repository
          auditOps
          cleanupSubject
          binding
          loginBoundary
          loginRef
      pure $ case cleaned of
        Left err -> Left err
        Right () -> Left ServiceSessionLifecycleLoginAmbiguityCleaned

  loginOnce restore loginRef = do
    result <- restore (attemptServiceSessionLogin loginBoundary)
    case result of
      Left detail -> do
        cleaned <-
          cleanupFencedSession
            repository
            auditOps
            cleanupSubject
            binding
            loginBoundary
            loginRef
        pure $ case cleaned of
          Left err -> Left err
          Right () -> Left (ServiceSessionLifecycleLoginFailedCleaned (Text.take 256 detail))
      Right login -> do
        -- Returning from @restore@ reinstates the mask before this write, so
        -- cancellation cannot lose a successfully returned token between the
        -- login response and terminal cleanup ownership.
        writeIORef loginRef (Just login)
        let accessor = Text.strip (serviceSessionLoginAccessor loginBoundary login)
        if Text.null accessor || accessor /= serviceSessionLoginAccessor loginBoundary login
          then cleanupAfterRefusal ServiceSessionLifecycleAccessorInvalid
          else do
            classified <- auditLookupAccessor auditOps accessor
            case classified of
              Left _ -> cleanupAfterRefusal ServiceSessionLifecycleAccessorIdentityMismatch
              Right info
                | not (vaultAccessorMatchesSubject activeSubject info) ->
                    cleanupAfterRefusal ServiceSessionLifecycleAccessorIdentityMismatch
                | otherwise -> do
                    activated <- commit (CommitServiceSessionActive binding accessor)
                    pure $ login <$ activated
   where
    cleanupAfterRefusal refusal = do
      cleaned <-
        cleanupFencedSession
          repository
          auditOps
          cleanupSubject
          binding
          loginBoundary
          loginRef
      pure $ case cleaned of
        Left err -> Left err
        Right () -> Left refusal

  commit event =
    fmap
      (either (Left . ServiceSessionLifecycleJournalFailed) Right)
      (applyServiceSessionJournalEvent repository event)

  cleanupSubject = serviceSessionCleanupSubject subjects
  activeSubject = serviceSessionActiveSubject subjects

closeFencedServiceSession
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> ServiceSessionSubjects
  -> ServiceSessionBinding
  -> ServiceSessionLoginBoundary login
  -> login
  -> IO (Either ServiceSessionLifecycleError ())
closeFencedServiceSession repository auditOps subjects binding loginBoundary login = do
  mask_ $ do
    loginRef <- newIORef (Just login)
    cleanupFencedSession
      repository
      auditOps
      (serviceSessionCleanupSubject subjects)
      binding
      loginBoundary
      loginRef

withFencedServiceSession
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> ServiceSessionSubjects
  -> ServiceSessionBinding
  -> ServiceSessionLoginBoundary login
  -> (login -> IO (Either Text value))
  -> IO (Either ServiceSessionLifecycleError value)
withFencedServiceSession repository auditOps subjects binding loginBoundary action =
  mask $ \restore -> do
    acquired <- acquireFencedServiceSession repository auditOps subjects binding loginBoundary
    case acquired of
      Left err -> pure (Left err)
      Right login -> do
        attempted <- tryAny (restore (action login))
        closed <-
          closeFencedServiceSession
            repository
            auditOps
            subjects
            binding
            loginBoundary
            login
        case attempted of
          Left exception
            | isAsyncException exception -> throwIO exception
          _ -> pure $ case closed of
            Left err -> Left err
            Right () -> case attempted of
              Left _ -> Left ServiceSessionLifecycleUnhandledException
              Right (Left detail) ->
                Left (ServiceSessionLifecycleActionFailed (Text.take 256 detail))
              Right (Right value) -> Right value

beginOrResume
  :: ServiceSessionJournalRepository IO revision
  -> ServiceSessionBinding
  -> IO (Either ServiceSessionLifecycleError ServiceSessionJournal)
beginOrResume repository binding = do
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot
      | serviceSessionJournalRole (serviceSessionJournalObserved snapshot)
          /= serviceSessionBindingRole binding ->
          pure (Left ServiceSessionLifecycleBindingRoleMismatch)
      | otherwise -> case serviceSessionJournalPhase (serviceSessionJournalObserved snapshot) of
          ServiceSessionVacant previousFence
            | serviceSessionBindingFence binding > previousFence ->
                fmap
                  (either (Left . ServiceSessionLifecycleJournalFailed) Right)
                  ( applyServiceSessionJournalEvent
                      repository
                      (BeginServiceSessionAcquisition binding)
                  )
          phase
            | phaseBinding phase == Just binding ->
                pure (Right (serviceSessionJournalObserved snapshot))
          _ -> pure (Left ServiceSessionLifecycleRoleOccupied)

cleanupFencedSession
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> ServiceSessionLoginBoundary login
  -> IORef (Maybe login)
  -> IO (Either ServiceSessionLifecycleError ())
cleanupFencedSession repository auditOps subject binding loginBoundary loginRef = do
  -- A successfully returned login is sufficient authority to revoke that
  -- exact bearer.  Do this before consulting the retained journal so a
  -- transient journal read failure cannot leak the one-shot token.
  maybeLogin <- readIORef loginRef
  case maybeLogin of
    Nothing -> pure ()
    Just login -> do
      _ <- tryAny (revokeServiceSessionLogin loginBoundary login)
      pure ()
  observed <- readServiceSessionJournal repository
  case observed of
    Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
    Right snapshot
      | serviceSessionJournalRole (serviceSessionJournalObserved snapshot)
          /= serviceSessionBindingRole binding ->
          pure (Left ServiceSessionLifecycleBindingRoleMismatch)
      | otherwise ->
          cleanupFencedSessionMatching
            repository
            auditOps
            subject
            binding
            loginBoundary
            loginRef

cleanupFencedSessionMatching
  :: ServiceSessionJournalRepository IO revision
  -> VaultAccessorAuditOps IO
  -> VaultAccessorSubject
  -> ServiceSessionBinding
  -> ServiceSessionLoginBoundary login
  -> IORef (Maybe login)
  -> IO (Either ServiceSessionLifecycleError ())
cleanupFencedSessionMatching repository auditOps subject binding loginBoundary loginRef = do
  maybeLogin <- readIORef loginRef
  required <- ensureCleanupRequired
  case required of
    Left err -> pure (Left err)
    Right (False, _) -> pure (Right ())
    Right (True, maybeAccessor) -> do
      let known = case maybeLogin of
            Just login -> Just (serviceSessionLoginAccessor loginBoundary login)
            Nothing -> maybeAccessor
      audited <- tryAny (revokeAndProveVaultAccessorSubjectAbsent auditOps subject known)
      case audited of
        Left _ -> pure (Left ServiceSessionLifecycleCleanupThrew)
        Right (Left err) -> pure (Left (ServiceSessionLifecycleCleanupFailed err))
        Right (Right ()) -> do
          proven <- applyCleanupEvent (CommitServiceSessionCleanupProven binding)
          case proven of
            Left err -> pure (Left err)
            Right _ -> do
              released <- applyCleanupEvent (ReleaseServiceSession binding)
              pure (Control.Monad.void released)
 where
  ensureCleanupRequired = do
    observed <- readServiceSessionJournal repository
    case observed of
      Left detail -> pure (Left (ServiceSessionLifecycleJournalUnavailable detail))
      Right snapshot -> case serviceSessionJournalPhase (serviceSessionJournalObserved snapshot) of
        ServiceSessionCleanupRequired existing accessor
          | existing == binding -> pure (Right (True, accessor))
        ServiceSessionCleanupProven existing
          | existing == binding -> pure (Right (True, Nothing))
        ServiceSessionVacant fence
          | fence == serviceSessionBindingFence binding -> pure (Right (False, Nothing))
        phase
          | phaseBinding phase == Just binding -> do
              committed <- applyCleanupEvent (RequireServiceSessionCleanup binding)
              pure $ case committed of
                Left err -> Left err
                Right journal -> case serviceSessionJournalPhase journal of
                  ServiceSessionCleanupRequired _ accessor -> Right (True, accessor)
                  _ -> Left ServiceSessionLifecycleRoleOccupied
        _ -> pure (Left ServiceSessionLifecycleRoleOccupied)
  applyCleanupEvent event =
    fmap
      (either (Left . ServiceSessionLifecycleCleanupJournalFailed) Right)
      (applyServiceSessionJournalEvent repository event)

phaseBinding :: ServiceSessionPhase -> Maybe ServiceSessionBinding
phaseBinding phase = case phase of
  ServiceSessionVacant _ -> Nothing
  ServiceSessionAcquiring binding -> Just binding
  ServiceSessionPrecleaned binding -> Just binding
  ServiceSessionLoginAttemptCommitted binding -> Just binding
  ServiceSessionActive binding _ -> Just binding
  ServiceSessionCleanupRequired binding _ -> Just binding
  ServiceSessionCleanupProven binding -> Just binding
  ServiceSessionWorkloadOwned inner _ -> phaseBinding inner
  ServiceSessionVerifiedWorkloadOwned inner _ -> phaseBinding inner
  ServiceSessionCreationReserved _ -> Nothing
  ServiceSessionCreationPrepared _ -> Nothing
  ServiceSessionDispatchOwned inner _ _ -> phaseBinding inner

phaseFence :: ServiceSessionPhase -> Natural
phaseFence phase = case phase of
  ServiceSessionVacant fence -> fence
  ServiceSessionAcquiring binding -> serviceSessionBindingFence binding
  ServiceSessionPrecleaned binding -> serviceSessionBindingFence binding
  ServiceSessionLoginAttemptCommitted binding -> serviceSessionBindingFence binding
  ServiceSessionActive binding _ -> serviceSessionBindingFence binding
  ServiceSessionCleanupRequired binding _ -> serviceSessionBindingFence binding
  ServiceSessionCleanupProven binding -> serviceSessionBindingFence binding
  ServiceSessionWorkloadOwned inner _ -> phaseFence inner
  ServiceSessionVerifiedWorkloadOwned inner _ -> phaseFence inner
  ServiceSessionCreationReserved reservation -> serviceSessionCreationFence reservation
  ServiceSessionCreationPrepared reservation -> serviceSessionCreationFence reservation
  ServiceSessionDispatchOwned inner _ _ -> phaseFence inner

tryAny :: IO value -> IO (Either SomeException value)
tryAny = try

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)
