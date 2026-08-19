{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the production answer to the host cleanup runner's injected
-- Authority restore boundary.
--
-- [Lifecycle Reconciliation Doctrine § 5b node 9](../../../documents/engineering/lifecycle_reconciliation_doctrine.md#5b-canonical-recover-to-clean-cascade)
-- puts the Lifecycle Authority on the far side of the destructive host
-- boundary: after local RKE2 is uninstalled the cascade re-establishes the
-- Authority and reads its own accepted readiness back.
-- "Prodbox.Lifecycle.HostCleanupAuthorityArms" landed the sequencing —
-- restore, then await admission, and never the reverse — behind an injected
-- 'LifecycleAuthorityRestoreBoundary'.  This module is the production
-- implementation of that boundary.
--
-- Four properties carry the design.
--
--   * __The cascade never mints an authority epoch.__  Restoration succeeds
--     only from @'BackupEstablished'@: the aggregate the re-established
--     Authority serves is the one it already held.  Genesis, mid-genesis
--     establishment, and repair-frozen are each reported as the distinct state
--     they are, because a cascade that ran genesis would produce an Authority
--     that admits requests and has forgotten the run — exactly the empty
--     control plane the ordering rule exists to refuse.
--
--   * __The backup domain is the independent half.__  The retained admission
--     state names its own 'BackupReceipt' and the physically separate Backup
--     Adapter is asked whether that exact receipt is healthy.  A restoration
--     that trusted only the Authority's own answer would be the writer
--     deciding its own durability, which is the separation node 7 already
--     insists on for the pre-uninstall report.
--
--   * __Only a transient failure is waited on.__  A control plane that is not
--     yet routable has said nothing and is retried under the bounded wait; a
--     decoded refusal, an authentication failure, or a state that is decidedly
--     not established is an answer, and retrying an answer would turn a
--     refusal into a timeout.  The classification is the repository's shared
--     transient table, never a flag set at this call site.
--
--   * __Restoration is not admission.__  Restoration decides which aggregate
--     is being served; admission decides whether the control plane accepts
--     work now.  They are separate arms over separate fresh observations, so
--     an Authority that is restored and then freezes for backup repair is
--     reported as not admitting rather than as never restored.
--
-- What this module does not own: whether the readiness survived, which is the
-- runner's separate read-back through
-- "Prodbox.ControlPlane.HostCleanupReadinessRepository"; the genesis and
-- repair choreography, which belongs to
-- "Prodbox.Lifecycle.Authority.BootstrapReconcile" and is deliberately not
-- reachable from here; and installing the workload that hosts the Authority,
-- which is a host mutation belonging to the non-public candidate entrypoint
-- Sprint @4.86@ still owns.
module Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( -- * The two observations re-establishment needs
    RetainedAuthorityAggregateSources (..)
  , productionRetainedAuthorityAggregateSources

    -- * Restoring the aggregate
  , AuthorityAggregateRestoreObservation (..)
  , renderAuthorityAggregateRestoreObservation
  , observeAuthorityAggregateRestore
  , authorityAggregateRestoreResult

    -- * Awaiting admission
  , LifecycleAuthorityAdmissionWait
  , mkLifecycleAuthorityAdmissionWait
  , lifecycleAuthorityAdmissionAttempts
  , lifecycleAuthorityAdmissionDelayMicros
  , LifecycleAuthorityAdmissionOutcome (..)
  , renderLifecycleAuthorityAdmissionOutcome
  , awaitLifecycleAuthorityAdmissionState
  , lifecycleAuthorityAdmissionResult

    -- * The production boundary
  , productionLifecycleAuthorityRestoreBoundary
  , productionHostCleanupAuthorityReestablish

    -- * Regression over the fixed re-establishment closure
  , LifecycleAuthorityRestoreRegression
  , fixedLifecycleAuthorityRestoreRegression
  , authorityRestoreRegressionEstablishedAndHealthyRestores
  , authorityRestoreRegressionGenesisNeverRestores
  , authorityRestoreRegressionRepairFrozenNeverRestores
  , authorityRestoreRegressionUnhealthyBackupRefused
  , authorityRestoreRegressionBackupAskedForTheNamedReceipt
  , authorityRestoreRegressionTransientStateWaited
  , authorityRestoreRegressionDecidedStateNotWaited
  , authorityRestoreRegressionTerminalFailureNotWaited
  , authorityRestoreRegressionAdmissionWaitsThenAdmits
  , authorityRestoreRegressionAdmissionExhausts
  , authorityRestoreRegressionRestoreDoesNotAwait
  )
where

import Data.IORef
  ( atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient
  )
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( observeRetainedAuthorityBackupHealth
  )
import Prodbox.ControlPlane.AuthorityObservationClient
  ( observeLifecycleAuthorityAuthenticated
  )
import Prodbox.ControlPlane.AuthorityObservationEndpoint
  ( LifecycleAuthorityObservation (observedAuthorityAdmission)
  )
import Prodbox.Lifecycle.Authority.BackupRepair (BackupHealth (..))
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityEpoch
  , BackupReceipt (..)
  , TargetAgentGenerationReceipt (..)
  , admitsNormalOperations
  , authorityEpochGenesis
  , authorityEpochValue
  , establishedEpoch
  , initialBackupRepairProgress
  )
import Prodbox.Lifecycle.HostCleanupAuthorityArms
  ( LifecycleAuthorityReestablishment (..)
  , LifecycleAuthorityRestoreBoundary (..)
  , lifecycleAuthorityReestablishmentEffect
  , reestablishLifecycleAuthority
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome
  , HostCleanupRunnerContext
  )
import Prodbox.Lifecycle.ModelBCasTransport (modelBEndpointUnreadyFragments)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Service (isRetryableTransientFailure)

-- ---------------------------------------------------------------------------
-- The two observations re-establishment needs
-- ---------------------------------------------------------------------------

-- | The retained admission projection and the independent backup domain.
--
-- They are two fields of one record rather than two arguments because every
-- arm below takes a /fresh/ observation of each: the whole point of asking
-- twice is that the second answer may differ from the first.
data RetainedAuthorityAggregateSources m = RetainedAuthorityAggregateSources
  { observeRetainedAdmissionState :: m (Either Text AuthorityAdmissionState)
  , observeIndependentBackupHealth :: BackupReceipt -> m (Either Text BackupHealth)
  }

-- | The production sources: the authenticated Lifecycle Authority observation
-- route and the physically separate Authority Backup Adapter.
--
-- Neither reaches an object store directly.  The Authority answers for its own
-- retained projection through the closed authenticated protocol and the Backup
-- Adapter answers for the backup domain through its own; a host-direct read of
-- either namespace would be an unregistered escape path.
productionRetainedAuthorityAggregateSources
  :: Text
  -- ^ the exact Lifecycle Authority scope the observation must echo
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityAggregateBackupClient IO
  -> RetainedAuthorityAggregateSources IO
productionRetainedAuthorityAggregateSources
  authorityScope
  authorityTransport
  backupClient =
    RetainedAuthorityAggregateSources
      { observeRetainedAdmissionState = do
          observed <-
            observeLifecycleAuthorityAuthenticated authorityTransport authorityScope
          pure $ do
            projection <- either (Left . boundedShow) Right observed
            maybe
              (Left "Lifecycle Authority omitted its retained admission projection")
              Right
              (observedAuthorityAdmission projection)
      , observeIndependentBackupHealth =
          observeRetainedAuthorityBackupHealth backupClient
      }

-- ---------------------------------------------------------------------------
-- Restoring the aggregate
-- ---------------------------------------------------------------------------

-- | What one restoration observation saw.
--
-- Every arm except the first is a reason the cascade must not proceed to
-- admission, and each keeps the distinction that decides the operator's
-- remedy: a state that is decidedly not established needs a different action
-- from a backup domain that could not be read.
data AuthorityAggregateRestoreObservation
  = -- | The Authority serves the established aggregate and the independent
    -- backup domain confirms that exact receipt.
    AuthorityAggregateRestored !AuthorityEpoch !BackupReceipt
  | -- | The retained projection is not an established aggregate.  A cascade
    -- never advances this state itself; doing so would mint an epoch that has
    -- forgotten the run.
    AuthorityAggregateNotEstablished !AuthorityAdmissionState
  | -- | The named receipt is not healthy in the independent backup domain.
    AuthorityAggregateBackupUnhealthy !BackupHealth
  | -- | The retained projection could not be observed at all.
    AuthorityAggregateStateUnobservable !Text
  | -- | The backup domain could not be observed at all.
    AuthorityAggregateBackupUnobservable !Text
  deriving (Eq, Show)

renderAuthorityAggregateRestoreObservation
  :: AuthorityAggregateRestoreObservation -> Text
renderAuthorityAggregateRestoreObservation = \case
  AuthorityAggregateRestored epoch (BackupReceipt receipt) ->
    "the lifecycle authority aggregate of epoch "
      <> Text.pack (show (authorityEpochValue epoch))
      <> " is served and independently backed by receipt "
      <> receipt
  AuthorityAggregateNotEstablished state ->
    "the retained admission projection is not an established aggregate: "
      <> boundedShow state
  AuthorityAggregateBackupUnhealthy health ->
    "the independent backup domain does not hold a healthy aggregate: "
      <> boundedShow health
  AuthorityAggregateStateUnobservable detail ->
    "the retained admission projection could not be observed: " <> detail
  AuthorityAggregateBackupUnobservable detail ->
    "the independent backup domain could not be observed: " <> detail

-- | Take one restoration observation.
--
-- The backup domain is asked about the receipt the retained projection itself
-- names, so the two halves are joined by a value neither of them was handed.
observeAuthorityAggregateRestore
  :: (Monad m)
  => RetainedAuthorityAggregateSources m
  -> m AuthorityAggregateRestoreObservation
observeAuthorityAggregateRestore sources = do
  observed <- observeRetainedAdmissionState sources
  case observed of
    Left detail -> pure (AuthorityAggregateStateUnobservable detail)
    Right state -> case state of
      BackupEstablished epoch _ receipt -> do
        health <- observeIndependentBackupHealth sources receipt
        pure $ case health of
          Left detail -> AuthorityAggregateBackupUnobservable detail
          Right BackupHealthy -> AuthorityAggregateRestored epoch receipt
          Right other -> AuthorityAggregateBackupUnhealthy other
      _ -> pure (AuthorityAggregateNotEstablished state)

-- | The boundary's answer: restoration established the aggregate, or the
-- rendered reason it did not.
authorityAggregateRestoreResult
  :: AuthorityAggregateRestoreObservation -> Either Text ()
authorityAggregateRestoreResult = \case
  AuthorityAggregateRestored _ _ -> Right ()
  other -> Left (renderAuthorityAggregateRestoreObservation other)

-- ---------------------------------------------------------------------------
-- Awaiting admission
-- ---------------------------------------------------------------------------

-- | A bounded wait over a control plane that is coming back up.
--
-- The attempt count is at least one, so a wait always takes an observation;
-- a zero-attempt wait would report a control plane it never asked about.
data LifecycleAuthorityAdmissionWait = LifecycleAuthorityAdmissionWait
  { lifecycleAuthorityAdmissionAttempts :: !Natural
  , lifecycleAuthorityAdmissionDelayMicros :: !Natural
  }
  deriving (Eq, Show)

mkLifecycleAuthorityAdmissionWait
  :: Natural
  -> Natural
  -> Either Text LifecycleAuthorityAdmissionWait
mkLifecycleAuthorityAdmissionWait attempts delayMicros
  | attempts == 0 =
      Left "a lifecycle authority admission wait must take at least one observation"
  | otherwise =
      Right
        LifecycleAuthorityAdmissionWait
          { lifecycleAuthorityAdmissionAttempts = attempts
          , lifecycleAuthorityAdmissionDelayMicros = delayMicros
          }

-- | What the bounded wait ended on.
data LifecycleAuthorityAdmissionOutcome
  = LifecycleAuthorityAdmits !AuthorityEpoch
  | -- | The last observation was a decided state that does not admit.
    LifecycleAuthorityDoesNotAdmit !AuthorityAdmissionState
  | -- | The last observation established nothing.
    LifecycleAuthorityAdmissionUnobservable !Text
  deriving (Eq, Show)

renderLifecycleAuthorityAdmissionOutcome
  :: LifecycleAuthorityAdmissionOutcome -> Text
renderLifecycleAuthorityAdmissionOutcome = \case
  LifecycleAuthorityAdmits epoch ->
    "the lifecycle authority admits normal operations under epoch "
      <> Text.pack (show (authorityEpochValue epoch))
  LifecycleAuthorityDoesNotAdmit state ->
    "the lifecycle authority does not admit normal operations: "
      <> boundedShow state
  LifecycleAuthorityAdmissionUnobservable detail ->
    "the lifecycle authority admission state could not be observed: " <> detail

-- | Observe until the Authority admits normal operations, or the bound runs
-- out.
--
-- Both a not-yet-admitting state and an unobservable one are waited on here,
-- because a control plane that is starting is legitimately both in turn.  The
-- delay is an injected effect so the fixed regression can exercise the exact
-- attempt sequence without spending the wall clock it names.
awaitLifecycleAuthorityAdmissionState
  :: (Monad m)
  => (Natural -> m ())
  -> LifecycleAuthorityAdmissionWait
  -> RetainedAuthorityAggregateSources m
  -> m LifecycleAuthorityAdmissionOutcome
awaitLifecycleAuthorityAdmissionState pause wait sources =
  attempt (lifecycleAuthorityAdmissionAttempts wait)
 where
  attempt remaining = do
    observed <- observeRetainedAdmissionState sources
    let outcome = classify observed
    case outcome of
      LifecycleAuthorityAdmits _ -> pure outcome
      _
        | remaining <= 1 -> pure outcome
        | otherwise -> do
            pause (lifecycleAuthorityAdmissionDelayMicros wait)
            attempt (remaining - 1)

  classify = \case
    Left detail -> LifecycleAuthorityAdmissionUnobservable detail
    Right state
      | admitsNormalOperations state
      , Just epoch <- establishedEpoch state ->
          LifecycleAuthorityAdmits epoch
      | otherwise -> LifecycleAuthorityDoesNotAdmit state

-- | The boundary's answer for the admission arm.
lifecycleAuthorityAdmissionResult
  :: LifecycleAuthorityAdmissionOutcome -> Either Text ()
lifecycleAuthorityAdmissionResult = \case
  LifecycleAuthorityAdmits _ -> Right ()
  other -> Left (renderLifecycleAuthorityAdmissionOutcome other)

-- ---------------------------------------------------------------------------
-- The production boundary
-- ---------------------------------------------------------------------------

-- | Compose both arms into the record the host cleanup runner injects.
--
-- The restoration arm waits only while the retained projection is
-- transiently unobservable: a decided refusal is an answer, and waiting on an
-- answer would report a timeout where the run should report a refusal.
productionLifecycleAuthorityRestoreBoundary
  :: (Monad m)
  => (Natural -> m ())
  -> LifecycleAuthorityAdmissionWait
  -> RetainedAuthorityAggregateSources m
  -> LifecycleAuthorityRestoreBoundary m
productionLifecycleAuthorityRestoreBoundary pause wait sources =
  LifecycleAuthorityRestoreBoundary
    { restoreAuthorityAggregateFromBackup =
        authorityAggregateRestoreResult
          <$> observeRestoreWithinBound (lifecycleAuthorityAdmissionAttempts wait)
    , awaitLifecycleAuthorityAdmission =
        lifecycleAuthorityAdmissionResult
          <$> awaitLifecycleAuthorityAdmissionState pause wait sources
    }
 where
  observeRestoreWithinBound remaining = do
    observation <- observeAuthorityAggregateRestore sources
    if remaining > 1 && waitsOn observation
      then do
        pause (lifecycleAuthorityAdmissionDelayMicros wait)
        observeRestoreWithinBound (remaining - 1)
      else pure observation

  waitsOn = \case
    AuthorityAggregateStateUnobservable detail -> transient detail
    AuthorityAggregateBackupUnobservable detail -> transient detail
    _ -> False

  transient detail =
    isRetryableTransientFailure modelBEndpointUnreadyFragments (Text.unpack detail)

-- | The runner arm itself.
--
-- The running context selects nothing here: which Authority is re-established
-- is fixed by the scope and transport the sources already carry, and letting a
-- run choose its own control plane is exactly the ambient selection the
-- lifecycle plane refuses everywhere else.  The arm reports only what the
-- attempt did; whether the readiness survived is the runner's separate
-- read-back.
productionHostCleanupAuthorityReestablish
  :: (Monad m)
  => (Natural -> m ())
  -> LifecycleAuthorityAdmissionWait
  -> RetainedAuthorityAggregateSources m
  -> HostCleanupRunnerContext
  -> m HostCleanupEffectOutcome
productionHostCleanupAuthorityReestablish pause wait sources _context =
  lifecycleAuthorityReestablishmentEffect
    <$> reestablishLifecycleAuthority
      (productionLifecycleAuthorityRestoreBoundary pause wait sources)

-- ---------------------------------------------------------------------------
-- Regression over the fixed re-establishment closure
-- ---------------------------------------------------------------------------

-- | The fixed measurements this module's properties are held to.
--
-- Every arm is exercised through the composed boundary rather than through an
-- internal helper, so the regression measures what the runner injects.
data LifecycleAuthorityRestoreRegression = LifecycleAuthorityRestoreRegression
  { authorityRestoreRegressionEstablishedAndHealthyRestores :: !Bool
  , authorityRestoreRegressionGenesisNeverRestores :: !Bool
  , authorityRestoreRegressionRepairFrozenNeverRestores :: !Bool
  , authorityRestoreRegressionUnhealthyBackupRefused :: !Bool
  , authorityRestoreRegressionBackupAskedForTheNamedReceipt :: !Bool
  , authorityRestoreRegressionTransientStateWaited :: !Bool
  , authorityRestoreRegressionDecidedStateNotWaited :: !Bool
  , authorityRestoreRegressionTerminalFailureNotWaited :: !Bool
  , authorityRestoreRegressionAdmissionWaitsThenAdmits :: !Bool
  , authorityRestoreRegressionAdmissionExhausts :: !Bool
  , authorityRestoreRegressionRestoreDoesNotAwait :: !Bool
  }
  deriving (Eq, Show)

-- | One run of every fixed scenario.
--
-- The wait is three attempts so that "waited once and then succeeded" and
-- "waited until the bound ran out" are different observable counts.
fixedLifecycleAuthorityRestoreRegression
  :: IO (Either Text LifecycleAuthorityRestoreRegression)
fixedLifecycleAuthorityRestoreRegression =
  case mkLifecycleAuthorityAdmissionWait 3 0 of
    Left detail -> pure (Left detail)
    Right wait -> Right <$> measureLifecycleAuthorityRestore wait

measureLifecycleAuthorityRestore
  :: LifecycleAuthorityAdmissionWait -> IO LifecycleAuthorityRestoreRegression
measureLifecycleAuthorityRestore wait = do
  restored <- restoreOver (repeat (Right establishedState))
  genesis <- restoreOver (repeat (Right GenesisFrozen))
  repairFrozen <- restoreOver (repeat (Right repairFrozenState))
  unhealthy <-
    restoreWith
      (repeat (Right establishedState))
      (const (pure (Right BackupPositivelyAbsent)))
  transientThenReady <-
    restoreOver (Left transientDetail : repeat (Right establishedState))
  terminal <- restoreOver (repeat (Left terminalDetail))
  admitted <- admissionOver (Right GenesisFrozen : repeat (Right establishedState))
  exhausted <- admissionOver (repeat (Right GenesisFrozen))
  refused <- reestablishOver (repeat (Right GenesisFrozen))
  pure
    LifecycleAuthorityRestoreRegression
      { authorityRestoreRegressionEstablishedAndHealthyRestores =
          scenarioAnswer restored == Right ()
            && scenarioPauses restored == 0
      , -- A cascade that advanced genesis would produce an Authority that
        -- admits requests and has forgotten the run.
        authorityRestoreRegressionGenesisNeverRestores =
          scenarioAnswer genesis == refusedAs (notEstablished GenesisFrozen)
      , authorityRestoreRegressionRepairFrozenNeverRestores =
          scenarioAnswer repairFrozen == refusedAs (notEstablished repairFrozenState)
            && scenarioAnswer repairFrozen /= scenarioAnswer genesis
      , authorityRestoreRegressionUnhealthyBackupRefused =
          scenarioAnswer unhealthy
            == refusedAs (AuthorityAggregateBackupUnhealthy BackupPositivelyAbsent)
      , -- The independent half is asked about the receipt the retained
        -- projection itself named, never one the caller supplied.
        authorityRestoreRegressionBackupAskedForTheNamedReceipt =
          scenarioReceipts restored == [fixedBackupReceipt]
            && null (scenarioReceipts genesis)
      , authorityRestoreRegressionTransientStateWaited =
          scenarioAnswer transientThenReady == Right ()
            && scenarioPauses transientThenReady == 1
      , -- Waiting on a decided refusal would report a timeout where the run
        -- should report the refusal.
        authorityRestoreRegressionDecidedStateNotWaited =
          scenarioPauses genesis == 0
      , authorityRestoreRegressionTerminalFailureNotWaited =
          scenarioAnswer terminal
            == refusedAs (AuthorityAggregateStateUnobservable terminalDetail)
            && scenarioPauses terminal == 0
      , authorityRestoreRegressionAdmissionWaitsThenAdmits =
          scenarioAnswer admitted == Right ()
            && scenarioPauses admitted == 1
      , authorityRestoreRegressionAdmissionExhausts =
          scenarioAnswer exhausted
            == Left
              ( renderLifecycleAuthorityAdmissionOutcome
                  (LifecycleAuthorityDoesNotAdmit GenesisFrozen)
              )
            && scenarioPauses exhausted == 2
      , -- The composed boundary keeps the ordering the arms record: a failed
        -- restore never reaches the admission wait, measured as the admission
        -- state being observed exactly once in the whole re-establishment.
        authorityRestoreRegressionRestoreDoesNotAwait =
          scenarioAnswer refused
            == LifecycleAuthorityRestoreFailed (renderNotEstablished GenesisFrozen)
            && scenarioObservations refused == 1
      }
 where
  restoreOver states = restoreWith states (const (pure (Right BackupHealthy)))

  restoreWith states health =
    withScenario states health $ \boundary ->
      restoreAuthorityAggregateFromBackup boundary

  admissionOver states =
    withScenario states (const (pure (Right BackupHealthy))) $ \boundary ->
      awaitLifecycleAuthorityAdmission boundary

  reestablishOver states =
    withScenario states (const (pure (Right BackupHealthy))) $ \boundary ->
      reestablishLifecycleAuthority boundary

  notEstablished = AuthorityAggregateNotEstablished

  renderNotEstablished =
    renderAuthorityAggregateRestoreObservation . notEstablished

  refusedAs = Left . renderAuthorityAggregateRestoreObservation

  establishedState =
    BackupEstablished fixedAuthorityEpoch fixedTargetGeneration fixedBackupReceipt

  repairFrozenState =
    BackupRepairFrozen
      fixedAuthorityEpoch
      (initialBackupRepairProgress fixedTargetGeneration fixedBackupReceipt)

  transientDetail = "connection refused"

  terminalDetail = "authority response failed to decode"

  withScenario states health run = do
    scripted <- newIORef states
    pauses <- newIORef (0 :: Int)
    observations <- newIORef (0 :: Int)
    receipts <- newIORef []
    let sources =
          RetainedAuthorityAggregateSources
            { observeRetainedAdmissionState = do
                modifyIORef' observations (+ 1)
                atomicModifyIORef' scripted $ \case
                  [] -> ([], Left terminalDetail)
                  answer : rest -> (rest, answer)
            , observeIndependentBackupHealth = \receipt -> do
                modifyIORef' receipts (++ [receipt])
                health receipt
            }
    answer <-
      run
        ( productionLifecycleAuthorityRestoreBoundary
            (\_ -> modifyIORef' pauses (+ 1))
            wait
            sources
        )
    LifecycleAuthorityRestoreScenario answer
      <$> readIORef pauses
      <*> readIORef observations
      <*> readIORef receipts

-- | One fixed scenario's answer and the effects it took to produce it.
data LifecycleAuthorityRestoreScenario answer = LifecycleAuthorityRestoreScenario
  { scenarioAnswer :: !answer
  , scenarioPauses :: !Int
  , scenarioObservations :: !Int
  , scenarioReceipts :: ![BackupReceipt]
  }

fixedAuthorityEpoch :: AuthorityEpoch
fixedAuthorityEpoch = authorityEpochGenesis

fixedTargetGeneration :: TargetAgentGenerationReceipt
fixedTargetGeneration = TargetAgentGenerationReceipt "fixed-target-generation"

fixedBackupReceipt :: BackupReceipt
fixedBackupReceipt = BackupReceipt "fixed-authority-aggregate-receipt"

boundedShow :: (Show value) => value -> Text
boundedShow = Text.take 4096 . Text.pack . show
