{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | The entry protocol for one durable, descriptor-bound cleanup run.
--
-- This module does not compile a graph, allocate an identity, interpret a
-- teardown operation, or decide whether node outcomes amount to success.  It
-- binds a caller-supplied stable run id to the already-compiled lifecycle
-- program and initial 'CleanupRun', captures their canonical program
-- descriptor, commits the matching host intent before the first mutation, and
-- speaks only the authenticated descriptor-bound cleanup protocol once the
-- Lifecycle Authority is reachable.
--
-- Sprint @4.86@ moved it out of @Prodbox.Test.*@.  Nothing here is
-- validation-specific: capturing the descriptor, preparing the host intent
-- before any mutation, observing-or-creating the run, claiming it, attaching
-- the primary outcome, and reading the terminal report back independently
-- before compacting are what /any/ caller of the descriptor-bound protocol must
-- do.  It was named as harness-owned, and the first production caller — the
-- non-public cascade candidate entrypoint — could not reach it without crossing
-- the boundary the Sprint-@4.85@ harness-namespace gate makes
-- non-constructible.  The validation harness remains a client; it is no longer
-- the owner.
module Prodbox.Lifecycle.CleanupRunEntry
  ( -- * What a surface records on the host
    CleanupHostIntent (..)
  , CleanupHostPreparation (..)
  , LifecycleCleanupDescriptor
  , mkLifecycleCleanupDescriptor
  , mkOrdinaryCleanupDescriptor
  , lifecycleCleanupDescriptorRunId
  , lifecycleCleanupDescriptorProgram
  , lifecycleCleanupDescriptorInitialRun
  , lifecycleCleanupDescriptorProgramDescriptor
  , lifecycleCleanupDescriptorHostRecord
  , lifecycleCleanupDescriptorHostIntent
  , LifecycleCleanupDescriptorError (..)
  , RegisteredLifecycleCleanup
  , registeredLifecycleCleanupBoundRun
  , registeredLifecycleCleanupHostRecord
  , registeredLifecycleCleanupHostIntent
  , prepareLifecycleCleanupBeforeMutation
  , registerLifecycleCleanupRun
  , claimLifecycleCleanupRun
  , attachLifecycleCleanupPrimaryOutcome
  , LifecycleCleanupResult (..)
  , LifecycleCleanupIncomplete (..)
  , LifecycleCleanupReobserveDiagnostic (..)
  , LifecycleCleanupClientError (..)
  , observeLifecycleCleanupResult
  )
where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError (..)
  , DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunDescriptorDigest
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunLease
  , descriptorBoundCleanupRunNodeStates
  , descriptorBoundCleanupRunPrimaryOutcome
  , descriptorBoundCleanupRunReport
  , descriptorBoundCleanupRunTerminal
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( cleanupRunMaximumBytes
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupLease (..)
  , CleanupNodeId
  , CleanupNodeState (..)
  , CleanupOperationId
  , CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRun (..)
  , CleanupRunCodecError
  , CleanupRunError (..)
  , CleanupRunId
  , CleanupRunReport (..)
  , cleanupDigestOfBytes
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , encodeCleanupRunReport
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntent
  , HostCleanupIntentError
  , HostCleanupIntentStore
  , HostTerminalPermitId
  , mkHostCleanupIntent
  , mkHostCleanupScope
  , mkHostCleanupTerminalIdentity
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupRunnerError
  , prepareHostCleanupRunner
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , CleanupProgramDescriptorError
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorGraphDigest
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade, ExplicitPerRun)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (UninstallCascadeLocalFoundation)
  )

-- | Exact validation binding to the lifecycle-owned program.  The constructor
-- is private so the host intent, compiled graph, and initial Authority run
-- cannot disagree.
-- | What a surface's cleanup run durably records on the host.
--
-- Sprint @5.36@: the entry protocol was fixed to the cascade, and that was not
-- an oversight — the host cleanup record is the record that licenses
-- uninstalling the retained local foundation, and @mkHostCleanupScope@ refuses
-- any surface but the cascade for exactly that reason.  A per-run cleanup
-- mutates registered targets and never the host, so it has no local-uninstall
-- operation to bind a record to and no business holding the record that
-- authorizes one.
--
-- The two answers are constructors rather than a @Maybe@, so a surface cannot
-- carry the wrong one and an ordinary caller cannot reach the cascade's record
-- at all.
data CleanupHostIntent (surface :: CleanupSurface) where
  CascadeHostIntent :: !HostCleanupIntent -> CleanupHostIntent 'Cascade
  NoHostIntent :: CleanupHostIntent 'ExplicitPerRun

deriving stock instance Eq (CleanupHostIntent surface)

deriving stock instance Show (CleanupHostIntent surface)

-- | The store half of the same answer, supplied at protocol time because the
-- retained root is resolved by the composition root after the plan is built.
--
-- A surface with no host record has no store to pass, so an ordinary caller
-- cannot supply one it does not use and a cascade caller cannot omit one.
data CleanupHostPreparation (surface :: CleanupSurface) where
  PrepareHostUninstallRecord
    :: !HostCleanupIntentStore -> CleanupHostPreparation 'Cascade
  NoHostPreparation :: CleanupHostPreparation 'ExplicitPerRun

data LifecycleCleanupDescriptor (surface :: CleanupSurface)
  = LifecycleCleanupDescriptor
  { internalLifecycleCleanupRunId :: !CleanupRunId
  , internalLifecycleCleanupProgram
      :: !(CompiledDesiredAbsenceProgram surface)
  , internalLifecycleCleanupInitialRun :: !CleanupRun
  , internalLifecycleCleanupProgramDescriptor :: !CleanupProgramDescriptor
  , internalLifecycleCleanupHostRecord :: !(CleanupHostIntent surface)
  }

lifecycleCleanupDescriptorRunId
  :: LifecycleCleanupDescriptor surface -> CleanupRunId
lifecycleCleanupDescriptorRunId = internalLifecycleCleanupRunId

lifecycleCleanupDescriptorProgram
  :: LifecycleCleanupDescriptor surface
  -> CompiledDesiredAbsenceProgram surface
lifecycleCleanupDescriptorProgram = internalLifecycleCleanupProgram

lifecycleCleanupDescriptorInitialRun
  :: LifecycleCleanupDescriptor surface -> CleanupRun
lifecycleCleanupDescriptorInitialRun = internalLifecycleCleanupInitialRun

lifecycleCleanupDescriptorProgramDescriptor
  :: LifecycleCleanupDescriptor surface -> CleanupProgramDescriptor
lifecycleCleanupDescriptorProgramDescriptor =
  internalLifecycleCleanupProgramDescriptor

lifecycleCleanupDescriptorHostRecord
  :: LifecycleCleanupDescriptor surface -> CleanupHostIntent surface
lifecycleCleanupDescriptorHostRecord = internalLifecycleCleanupHostRecord

-- | The cascade's host record, reachable only at the surface that has one.
lifecycleCleanupDescriptorHostIntent
  :: LifecycleCleanupDescriptor 'Cascade -> HostCleanupIntent
lifecycleCleanupDescriptorHostIntent descriptor =
  case internalLifecycleCleanupHostRecord descriptor of
    CascadeHostIntent intent -> intent

data LifecycleCleanupDescriptorError
  = LifecycleCleanupCompiledRunIdMismatch !CleanupRunId !CleanupRunId
  | LifecycleCleanupInitialRunIdMismatch !CleanupRunId !CleanupRunId
  | LifecycleCleanupInitialGraphMismatch
  | LifecycleCleanupInitialGraphDigestMismatch !CleanupDigest !CleanupDigest
  | LifecycleCleanupTerminalOperationMissing
  | LifecycleCleanupTerminalOperationDuplicated !Int
  | LifecycleCleanupProgramDescriptorInvalid !CleanupProgramDescriptorError
  | LifecycleCleanupHostScopeInvalid !HostCleanupIntentError
  | LifecycleCleanupHostIntentInvalid !HostCleanupIntentError
  deriving stock (Eq, Show)

-- | Bind one caller-owned stable identity to already-compiled lifecycle data.
-- The local-uninstall operation id is selected from that compiled graph; this
-- client never derives a second operation id.
mkLifecycleCleanupDescriptor
  :: CleanupRunId
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> CleanupRun
  -> HostTerminalPermitId
  -> Either
       LifecycleCleanupDescriptorError
       (LifecycleCleanupDescriptor 'Cascade)
mkLifecycleCleanupDescriptor suppliedRunId compiled initialRun terminalPermit = do
  programDescriptor <- requireCleanupBinding suppliedRunId compiled initialRun
  terminalOperation <- compiledTerminalOperationId compiled
  scope <-
    first
      LifecycleCleanupHostScopeInvalid
      ( mkHostCleanupScope
          suppliedRunId
          (compiledDesiredAbsenceObservationScope compiled)
      )
  hostIntent <-
    first
      LifecycleCleanupHostIntentInvalid
      ( mkHostCleanupIntent
          suppliedRunId
          (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled))
          initialRun
          scope
          (mkHostCleanupTerminalIdentity terminalOperation terminalPermit)
      )
  Right
    LifecycleCleanupDescriptor
      { internalLifecycleCleanupRunId = suppliedRunId
      , internalLifecycleCleanupProgram = compiled
      , internalLifecycleCleanupInitialRun = initialRun
      , internalLifecycleCleanupProgramDescriptor = programDescriptor
      , internalLifecycleCleanupHostRecord = CascadeHostIntent hostIntent
      }

-- | Sprint @5.36@: the same binding for an ordinary per-run cleanup.
--
-- It runs exactly the checks the cascade constructor runs, because both call
-- one 'requireCleanupBinding', and then stops: there is no host record on this
-- surface, so there is no local-uninstall operation to select and no host
-- scope to build. A caller that needs one is on the wrong surface, and the type
-- says so rather than a runtime refusal.
mkOrdinaryCleanupDescriptor
  :: CleanupRunId
  -> CompiledDesiredAbsenceProgram 'ExplicitPerRun
  -> CleanupRun
  -> Either
       LifecycleCleanupDescriptorError
       (LifecycleCleanupDescriptor 'ExplicitPerRun)
mkOrdinaryCleanupDescriptor suppliedRunId compiled initialRun = do
  programDescriptor <- requireCleanupBinding suppliedRunId compiled initialRun
  Right
    LifecycleCleanupDescriptor
      { internalLifecycleCleanupRunId = suppliedRunId
      , internalLifecycleCleanupProgram = compiled
      , internalLifecycleCleanupInitialRun = initialRun
      , internalLifecycleCleanupProgramDescriptor = programDescriptor
      , internalLifecycleCleanupHostRecord = NoHostIntent
      }

-- | The identity checks every surface's binding makes, written once.
--
-- Keeping them here rather than in each constructor is what stops a second
-- surface from being admitted by a weaker prefix of the cascade's checks.
requireCleanupBinding
  :: CleanupRunId
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either LifecycleCleanupDescriptorError CleanupProgramDescriptor
requireCleanupBinding suppliedRunId compiled initialRun = do
  let compiledRunId = compiledDesiredAbsenceRunId compiled
      initialRunId = cleanupRunId initialRun
      compiledGraph = compiledDesiredAbsenceGraph compiled
      expectedDigest = cleanupGraphDigest compiledGraph
      actualDigest = cleanupRunGraphDigest initialRun
  if compiledRunId == suppliedRunId
    then Right ()
    else Left (LifecycleCleanupCompiledRunIdMismatch suppliedRunId compiledRunId)
  if initialRunId == suppliedRunId
    then Right ()
    else Left (LifecycleCleanupInitialRunIdMismatch suppliedRunId initialRunId)
  if cleanupRunGraph initialRun == compiledGraph
    then Right ()
    else Left LifecycleCleanupInitialGraphMismatch
  if actualDigest == expectedDigest
    then Right ()
    else
      Left
        ( LifecycleCleanupInitialGraphDigestMismatch
            expectedDigest
            actualDigest
        )
  first
    LifecycleCleanupProgramDescriptorInvalid
    (captureCleanupProgramDescriptor compiled initialRun)

compiledTerminalOperationId
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Either LifecycleCleanupDescriptorError CleanupOperationId
compiledTerminalOperationId compiled =
  case [ cleanupNodeOperationId node
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , operation == UninstallCascadeLocalFoundation
       , node <- cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)
       , cleanupNodeId node == nodeId
       ] of
    [operationId] -> Right operationId
    [] -> Left LifecycleCleanupTerminalOperationMissing
    operations ->
      Left (LifecycleCleanupTerminalOperationDuplicated (length operations))

-- | Authority registration witness.  It contains only the exact observed
-- lifecycle aggregate and the independently read-back host descriptor.
data RegisteredLifecycleCleanup (surface :: CleanupSurface)
  = RegisteredLifecycleCleanup
  { internalRegisteredLifecycleCleanupBoundRun :: !DescriptorBoundCleanupRun
  , internalRegisteredLifecycleCleanupHostRecord
      :: !(CleanupHostIntent surface)
  , internalRegisteredLifecycleCleanupDescriptor
      :: !(LifecycleCleanupDescriptor surface)
  }

registeredLifecycleCleanupBoundRun
  :: RegisteredLifecycleCleanup surface -> DescriptorBoundCleanupRun
registeredLifecycleCleanupBoundRun =
  internalRegisteredLifecycleCleanupBoundRun

registeredLifecycleCleanupHostRecord
  :: RegisteredLifecycleCleanup surface -> CleanupHostIntent surface
registeredLifecycleCleanupHostRecord =
  internalRegisteredLifecycleCleanupHostRecord

registeredLifecycleCleanupHostIntent
  :: RegisteredLifecycleCleanup 'Cascade -> HostCleanupIntent
registeredLifecycleCleanupHostIntent registered =
  case internalRegisteredLifecycleCleanupHostRecord registered of
    CascadeHostIntent intent -> intent

data LifecycleCleanupReobserveDiagnostic
  = LifecycleCleanupReobserveClientFailed !CleanupRunClientError
  | LifecycleCleanupReobservePostStateRejected !Text.Text
  deriving stock (Eq, Show)

data LifecycleCleanupClientError
  = LifecycleCleanupHostRunnerFailed !HostCleanupRunnerError
  | LifecycleCleanupAuthorityFailed !CleanupRunClientError
  | LifecycleCleanupAuthorityIndependentReadBackFailed !CleanupRunClientError
  | LifecycleCleanupAuthorityIndependentReadBackRejected
      !LifecycleCleanupReobserveDiagnostic
  | LifecycleCleanupAuthorityResponseUnconfirmed
      !CleanupRunClientError
      !LifecycleCleanupReobserveDiagnostic
  | LifecycleCleanupAuthorityRunIdMismatch !CleanupRunId !CleanupRunId
  | LifecycleCleanupAuthorityDescriptorDigestMismatch !CleanupDigest !CleanupDigest
  | LifecycleCleanupAuthorityGraphDigestMismatch !CleanupDigest !CleanupDigest
  | LifecycleCleanupAuthorityGraphMismatch
  | LifecycleCleanupClaimInvalid !CleanupRunError
  | LifecycleCleanupClaimReadBackMismatch
      !CleanupOwnerId
      !Natural
  | LifecycleCleanupPrimaryInvalid !CleanupRunError
  | LifecycleCleanupPrimaryOutcomeConflict
      !CleanupPrimaryOutcome
      !CleanupPrimaryOutcome
  | LifecycleCleanupPrimaryReadBackMismatch !CleanupPrimaryOutcome
  | LifecycleCleanupRunNotTerminal !CleanupRunId
  | LifecycleCleanupReportInvalid !CleanupRunError
  | LifecycleCleanupReportEncodeFailed !CleanupRunCodecError
  | LifecycleCleanupReportRunIdMismatch !CleanupRunId !CleanupRunId
  | LifecycleCleanupReportGraphDigestMismatch !CleanupDigest !CleanupDigest
  | LifecycleCleanupReportReadBackMismatch
      !CleanupRunReport
      !CleanupRunReport
  deriving stock (Eq, Show)

-- | Persist and independently read back the host descriptor before invoking
-- the supplied first mutation.  Runtime exceptions, including cancellation,
-- deliberately propagate; the durable descriptor remains for the next owner.
prepareLifecycleCleanupBeforeMutation
  :: CleanupHostPreparation surface
  -> LifecycleCleanupDescriptor surface
  -> IO value
  -> IO (Either LifecycleCleanupClientError value)
prepareLifecycleCleanupBeforeMutation preparation descriptor mutation = do
  prepared <- prepareDescriptor preparation descriptor
  case prepared of
    Left err -> pure (Left err)
    Right _ -> Right <$> mutation

-- | Observe an existing run first; create only when the exact stable id is
-- absent.  A lost create response is resolved solely by observing that same
-- id and exact graph binding.
registerLifecycleCleanupRun
  :: CleanupHostPreparation surface
  -> DescriptorBoundCleanupRunClient IO
  -> LifecycleCleanupDescriptor surface
  -> IO
       ( Either
           LifecycleCleanupClientError
           (RegisteredLifecycleCleanup surface)
       )
registerLifecycleCleanupRun preparation client descriptor = do
  prepared <- prepareDescriptor preparation descriptor
  case prepared of
    Left err -> pure (Left err)
    Right hostRecord -> do
      registered <- observeOrCreate client descriptor
      pure $
        RegisteredLifecycleCleanup
          <$> registered
          <*> Right hostRecord
          <*> Right descriptor

-- | Claim the exact run through the Authority.  Expired-owner takeover and
-- its typed 'CleanupPrimaryRunnerLost' outcome remain lifecycle-kernel facts;
-- this client neither rewrites nor narrates them.
claimLifecycleCleanupRun
  :: DescriptorBoundCleanupRunClient IO
  -> CleanupOwnerId
  -> Natural
  -> Natural
  -> RegisteredLifecycleCleanup surface
  -> IO
       ( Either
           LifecycleCleanupClientError
           (RegisteredLifecycleCleanup surface)
       )
claimLifecycleCleanupRun client owner now expires registered = do
  refreshed <- observeBoundRun client descriptor
  case refreshed of
    Left err -> pure (Left err)
    Right current
      | descriptorBoundCleanupRunTerminal current ->
          pure (Right (withBoundRun current))
      | otherwise -> case expectedClaimProjection owner now expires current of
          Left err -> pure (Left (LifecycleCleanupClaimInvalid err))
          Right expected -> do
            attempted <-
              claimDescriptorBoundCleanupRun
                client
                current
                owner
                now
                expires
            confirmed <-
              confirmDescriptorMutation
                client
                descriptor
                attempted
                (validateClaim expected)
            pure (withBoundRun <$> confirmed)
 where
  descriptor = internalRegisteredLifecycleCleanupDescriptor registered
  withBoundRun run =
    registered {internalRegisteredLifecycleCleanupBoundRun = run}
  validateClaim expected observed = do
    bound <- validateBoundRun descriptor observed
    let (expectedLease, expectedPrimary, expectedStates) = expected
        actualLease = descriptorBoundCleanupRunLease bound
    if cleanupLeaseOwner actualLease == cleanupLeaseOwner expectedLease
      && cleanupLeaseFence actualLease == cleanupLeaseFence expectedLease
      && cleanupLeaseExpiresAtMicros actualLease
        == cleanupLeaseExpiresAtMicros expectedLease
      && descriptorBoundCleanupRunPrimaryOutcome bound == expectedPrimary
      && descriptorBoundCleanupRunNodeStates bound == expectedStates
      then Right bound
      else
        Left
          ( LifecycleCleanupClaimReadBackMismatch
              owner
              (cleanupLeaseFence expectedLease)
          )

-- | Attach the original typed outcome without running cleanup locally.  If
-- the transition response is lost, exact observation of that constructor on
-- the same run closes the ambiguity.
attachLifecycleCleanupPrimaryOutcome
  :: DescriptorBoundCleanupRunClient IO
  -> CleanupPrimaryOutcome
  -> RegisteredLifecycleCleanup surface
  -> IO
       ( Either
           LifecycleCleanupClientError
           (RegisteredLifecycleCleanup surface)
       )
attachLifecycleCleanupPrimaryOutcome client outcome registered = do
  refreshed <- observeBoundRun client descriptor
  case refreshed of
    Left err -> pure (Left err)
    Right current -> case descriptorBoundCleanupRunPrimaryOutcome current of
      Just observed
        | observed == outcome -> pure (Right (withBoundRun current))
        | otherwise ->
            pure
              ( Left
                  (LifecycleCleanupPrimaryOutcomeConflict outcome observed)
              )
      Nothing -> do
        let currentLease = descriptorBoundCleanupRunLease current
        attempted <-
          recordDescriptorBoundCleanupPrimary
            client
            current
            (cleanupLeaseOwner currentLease)
            (cleanupLeaseFence currentLease)
            outcome
        confirmed <-
          confirmDescriptorMutation
            client
            descriptor
            attempted
            validatePrimary
        pure (withBoundRun <$> confirmed)
 where
  descriptor = internalRegisteredLifecycleCleanupDescriptor registered
  withBoundRun run =
    registered {internalRegisteredLifecycleCleanupBoundRun = run}
  validatePrimary observed = do
    bound <- validateBoundRun descriptor observed
    if descriptorBoundCleanupRunPrimaryOutcome bound == Just outcome
      then Right bound
      else Left (LifecycleCleanupPrimaryReadBackMismatch outcome)

-- | The lifecycle report is returned intact, including failed and blocked
-- nodes.  This module intentionally has no validation-owned success fold.
data LifecycleCleanupResult
  = LifecycleCleanupReportObserved !CleanupRunReport
  | LifecycleCleanupIncompleteResult !LifecycleCleanupIncomplete
  deriving stock (Eq, Show)

data LifecycleCleanupIncomplete = LifecycleCleanupIncomplete
  { lifecycleCleanupIncompleteRunId :: !CleanupRunId
  , lifecycleCleanupIncompletePrimaryOutcome
      :: !(Maybe CleanupPrimaryOutcome)
  , lifecycleCleanupIncompleteFailures
      :: !(NonEmpty LifecycleCleanupClientError)
  }
  deriving stock (Eq, Show)

-- | Observe terminal state, then ask the Authority to compact and read back
-- its backed-up report.  A lost compaction response is retried against the
-- same tombstoned run id; any unresolved arm is an explicit incomplete result.
observeLifecycleCleanupResult
  :: DescriptorBoundCleanupRunClient IO
  -> Natural
  -> Natural
  -> RegisteredLifecycleCleanup surface
  -> IO LifecycleCleanupResult
observeLifecycleCleanupResult client now retention registered = do
  observed <- observeBoundRun client descriptor
  case observed of
    Left err -> pure (incomplete Nothing (err :| []))
    Right run
      | not (descriptorBoundCleanupRunTerminal run) ->
          pure
            ( incomplete
                (descriptorBoundCleanupRunPrimaryOutcome run)
                (LifecycleCleanupRunNotTerminal runId :| [])
            )
      | otherwise -> case descriptorBoundCleanupRunReport run of
          Left err ->
            pure
              ( incomplete
                  (descriptorBoundCleanupRunPrimaryOutcome run)
                  (LifecycleCleanupReportInvalid err :| [])
              )
          Right expected -> do
            case encodeCleanupRunReport cleanupRunMaximumBytes expected of
              Left err ->
                pure
                  ( incomplete
                      (descriptorBoundCleanupRunPrimaryOutcome run)
                      (LifecycleCleanupReportEncodeFailed err :| [])
                  )
              Right reportBytes -> do
                attempted <-
                  compactDescriptorBoundCleanupRun
                    client
                    run
                    now
                    retention
                observedAfterAttempt <-
                  observeDescriptorBoundCleanupRun client runId
                let tombstone =
                      validateCompactionReadBack
                        descriptor
                        (cleanupDigestOfBytes reportBytes)
                        observedAfterAttempt
                pure $ case attempted of
                  Right report -> case validateReport expected report of
                    Left err ->
                      incomplete
                        (descriptorBoundCleanupRunPrimaryOutcome run)
                        (err :| [])
                    Right exact -> case tombstone of
                      Left diagnostic ->
                        incomplete
                          (descriptorBoundCleanupRunPrimaryOutcome run)
                          ( LifecycleCleanupAuthorityIndependentReadBackRejected
                              diagnostic
                              :| []
                          )
                      Right () -> LifecycleCleanupReportObserved exact
                  Left firstFailure -> case tombstone of
                    Right () -> LifecycleCleanupReportObserved expected
                    Left diagnostic ->
                      incomplete
                        (descriptorBoundCleanupRunPrimaryOutcome run)
                        ( LifecycleCleanupAuthorityResponseUnconfirmed
                            firstFailure
                            diagnostic
                            :| []
                        )
 where
  descriptor = internalRegisteredLifecycleCleanupDescriptor registered
  runId = lifecycleCleanupDescriptorRunId descriptor
  incomplete primary failures =
    LifecycleCleanupIncompleteResult
      LifecycleCleanupIncomplete
        { lifecycleCleanupIncompleteRunId = runId
        , lifecycleCleanupIncompletePrimaryOutcome = primary
        , lifecycleCleanupIncompleteFailures = failures
        }
  validateReport expected observed
    | cleanupReportRunId observed /= runId =
        Left
          ( LifecycleCleanupReportRunIdMismatch
              runId
              (cleanupReportRunId observed)
          )
    | cleanupReportGraphDigest observed
        /= cleanupProgramDescriptorGraphDigest
          (lifecycleCleanupDescriptorProgramDescriptor descriptor) =
        Left
          ( LifecycleCleanupReportGraphDigestMismatch
              ( cleanupProgramDescriptorGraphDigest
                  (lifecycleCleanupDescriptorProgramDescriptor descriptor)
              )
              (cleanupReportGraphDigest observed)
          )
    | observed /= expected =
        Left (LifecycleCleanupReportReadBackMismatch expected observed)
    | otherwise = Right observed

-- | Persist and read back the host record for the surface that has one.
--
-- Total over the two answers rather than a store call some callers are
-- expected to skip: a surface with no host record has nothing to persist and
-- nothing to read back.
prepareDescriptor
  :: CleanupHostPreparation surface
  -> LifecycleCleanupDescriptor surface
  -> IO (Either LifecycleCleanupClientError (CleanupHostIntent surface))
prepareDescriptor preparation descriptor =
  case (preparation, lifecycleCleanupDescriptorHostRecord descriptor) of
    (PrepareHostUninstallRecord store, CascadeHostIntent intent) ->
      fmap
        (fmap CascadeHostIntent)
        ( first LifecycleCleanupHostRunnerFailed
            <$> prepareHostCleanupRunner store intent
        )
    (NoHostPreparation, NoHostIntent) -> pure (Right NoHostIntent)

observeOrCreate
  :: DescriptorBoundCleanupRunClient IO
  -> LifecycleCleanupDescriptor surface
  -> IO (Either LifecycleCleanupClientError DescriptorBoundCleanupRun)
observeOrCreate client descriptor = do
  observed <- observeDescriptorBoundCleanupRun client runId
  case observed of
    Right run -> pure (validateBoundRun descriptor run)
    Left CleanupRunClientDescriptorMissing -> create
    Left err -> pure (Left (LifecycleCleanupAuthorityFailed err))
 where
  runId = lifecycleCleanupDescriptorRunId descriptor
  create = do
    created <-
      createDescriptorBoundCleanupRun
        client
        (lifecycleCleanupDescriptorProgramDescriptor descriptor)
    confirmDescriptorMutation client descriptor created Right

observeBoundRun
  :: DescriptorBoundCleanupRunClient IO
  -> LifecycleCleanupDescriptor surface
  -> IO (Either LifecycleCleanupClientError DescriptorBoundCleanupRun)
observeBoundRun client descriptor = do
  observed <-
    observeDescriptorBoundCleanupRun
      client
      (lifecycleCleanupDescriptorRunId descriptor)
  pure $ case observed of
    Left err -> Left (LifecycleCleanupAuthorityFailed err)
    Right run -> validateBoundRun descriptor run

validateBoundRun
  :: LifecycleCleanupDescriptor surface
  -> DescriptorBoundCleanupRun
  -> Either LifecycleCleanupClientError DescriptorBoundCleanupRun
validateBoundRun descriptor observed
  | descriptorBoundCleanupRunId observed /= expectedRunId =
      Left
        ( LifecycleCleanupAuthorityRunIdMismatch
            expectedRunId
            (descriptorBoundCleanupRunId observed)
        )
  | descriptorBoundCleanupRunDescriptorDigest observed
      /= expectedDescriptorDigest =
      Left
        ( LifecycleCleanupAuthorityDescriptorDigestMismatch
            expectedDescriptorDigest
            (descriptorBoundCleanupRunDescriptorDigest observed)
        )
  | descriptorBoundCleanupRunGraphDigest observed /= expectedGraphDigest =
      Left
        ( LifecycleCleanupAuthorityGraphDigestMismatch
            expectedGraphDigest
            (descriptorBoundCleanupRunGraphDigest observed)
        )
  | descriptorBoundCleanupRunGraph observed /= expectedGraph =
      Left LifecycleCleanupAuthorityGraphMismatch
  | otherwise = Right observed
 where
  expectedRunId = lifecycleCleanupDescriptorRunId descriptor
  expectedDescriptorDigest =
    cleanupProgramDescriptorDigest
      (lifecycleCleanupDescriptorProgramDescriptor descriptor)
  expectedGraph =
    compiledDesiredAbsenceGraph
      (lifecycleCleanupDescriptorProgram descriptor)
  expectedGraphDigest = cleanupGraphDigest expectedGraph

expectedClaimProjection
  :: CleanupOwnerId
  -> Natural
  -> Natural
  -> DescriptorBoundCleanupRun
  -> Either
       CleanupRunError
       ( CleanupLease
       , Maybe CleanupPrimaryOutcome
       , Map CleanupNodeId CleanupNodeState
       )
expectedClaimProjection owner now expires run
  | expires <= now = Left CleanupLeaseInvalid
  | now < cleanupLeaseExpiresAtMicros lease
      && owner /= cleanupLeaseOwner lease =
      Left (CleanupLeaseHeld (cleanupLeaseOwner lease))
  | now < cleanupLeaseExpiresAtMicros lease =
      Right
        ( lease {cleanupLeaseExpiresAtMicros = expires}
        , descriptorBoundCleanupRunPrimaryOutcome run
        , descriptorBoundCleanupRunNodeStates run
        )
  | otherwise =
      Right
        ( CleanupLease owner (cleanupLeaseFence lease + 1) expires
        , case descriptorBoundCleanupRunPrimaryOutcome run of
            Nothing -> Just CleanupPrimaryRunnerLost
            observed -> observed
        , Map.map recoverRunning (descriptorBoundCleanupRunNodeStates run)
        )
 where
  lease = descriptorBoundCleanupRunLease run
  recoverRunning state = case state of
    CleanupNodeRunning _ -> CleanupNodePending
    other -> other

confirmDescriptorMutation
  :: DescriptorBoundCleanupRunClient IO
  -> LifecycleCleanupDescriptor surface
  -> Either CleanupRunClientError DescriptorBoundCleanupRun
  -> ( DescriptorBoundCleanupRun
       -> Either LifecycleCleanupClientError DescriptorBoundCleanupRun
     )
  -> IO (Either LifecycleCleanupClientError DescriptorBoundCleanupRun)
confirmDescriptorMutation client descriptor attempted validatePostState = do
  independentlyObserved <-
    observeDescriptorBoundCleanupRun
      client
      (lifecycleCleanupDescriptorRunId descriptor)
  pure $ case attempted of
    Right response -> do
      responseBound <- validateBoundRun descriptor response
      _ <- validatePostState responseBound
      case independentlyObserved of
        Left err ->
          Left (LifecycleCleanupAuthorityIndependentReadBackFailed err)
        Right observed -> do
          bound <- validateBoundRun descriptor observed
          validatePostState bound
    Left firstFailure -> case independentlyObserved of
      Left readBackFailure ->
        Left
          ( LifecycleCleanupAuthorityResponseUnconfirmed
              firstFailure
              (LifecycleCleanupReobserveClientFailed readBackFailure)
          )
      Right observed -> case validateBoundRun descriptor observed >>= validatePostState of
        Right exact -> Right exact
        Left rejection ->
          Left
            ( LifecycleCleanupAuthorityResponseUnconfirmed
                firstFailure
                ( LifecycleCleanupReobservePostStateRejected
                    (Text.pack (show rejection))
                )
            )

validateCompactionReadBack
  :: LifecycleCleanupDescriptor surface
  -> CleanupDigest
  -> Either CleanupRunClientError DescriptorBoundCleanupRun
  -> Either LifecycleCleanupReobserveDiagnostic ()
validateCompactionReadBack descriptor expectedReportDigest observed =
  case observed of
    Left
      ( CleanupRunClientDescriptorTombstoned
          observedDescriptorDigest
          observedReportDigest
        )
        | observedDescriptorDigest == expectedDescriptorDigest
            && observedReportDigest == expectedReportDigest ->
            Right ()
        | otherwise ->
            Left
              ( LifecycleCleanupReobservePostStateRejected
                  "descriptor-bound cleanup tombstone has the wrong digest binding"
              )
    Left err -> Left (LifecycleCleanupReobserveClientFailed err)
    Right live ->
      Left
        ( LifecycleCleanupReobservePostStateRejected
            ( "descriptor-bound cleanup run remained live after compaction: "
                <> Text.pack (show (descriptorBoundCleanupRunId live))
            )
        )
 where
  expectedDescriptorDigest =
    cleanupProgramDescriptorDigest
      (lifecycleCleanupDescriptorProgramDescriptor descriptor)
