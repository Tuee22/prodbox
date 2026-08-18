{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The host-side lane that makes a registered stack's creation addressable.
--
-- Sprint @4.84@ landed the run-invariant generation, its durable slot, the
-- ordinal succession, the Authority-side producer, and the read-back-bound
-- cleanup selector.  Every one of those was proven and none of them ran,
-- because no production path could reach the producer: committing a generation
-- needs the @OperationId@ of the admitted create and of the admitted
-- @ObserveProviderAwsScope@, and an 'OperationId' is
-- @(epoch, client, sequence, digest)@ — the epoch and sequence are assigned at
-- admission, so a submitter cannot derive one.  It has to be told, and the
-- dispatch response discarded it.
--
-- That is now fixed at the route, and this module is the composition it
-- enables.  One submission does, in order:
--
--   1. dispatch @ObserveProviderAwsScope@ and keep the operation that carried
--      it, so the account and region behind the generation key are ones the
--      Provider Worker observed under an admitted operation;
--   2. dispatch the caller's create intent and keep /its/ operation; and
--   3. present both to the Authority's registered-stack creation route, which
--      reserves the cycle, commits the run-invariant generation, and only then
--      commits the run-scoped creation binding.
--
-- __The foundation is the retained cluster, not an invented value.__  The
-- foundation id is part of the run-invariant generation /key/, so a later
-- cleanup run must compute the same one without knowing anything about this
-- run.  It therefore comes from the retained local RKE2 control plane's own
-- cluster id — the one fact that is stable across runs by construction — and
-- never from a per-invocation value.  The creating run scope and surface, by
-- contrast, are provenance the selector never consults, so a per-invocation
-- value there is correct rather than merely tolerable.
module Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( -- * The submission
    RegisteredStackCreationSubmission (..)
  , RegisteredStackCreationSubmitError (..)
  , renderRegisteredStackCreationSubmitError
  , submitRegisteredStackCreation

    -- * The scope a creation is submitted under
  , homeLinuxRke2FoundationId
  , registeredStackCreationScope
  , registeredStackCreationRunScope

    -- * The consumer half
  , RegisteredStackCleanupSelectError (..)
  , renderRegisteredStackCleanupSelectError
  , registeredStackCleanupScope
  , selectRegisteredStackGenerationForCleanup
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.Config.Basics (UnencryptedBasics (basicsClusterId))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationBindingClient (..)
  , AwsStackCreationBindingError
  , AwsStackCreationCommitResult (..)
  )
import Prodbox.ControlPlane.AwsStackCreationBindingTransportClient
  ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  , selectRegisteredStackGenerationOverTransport
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError
  , dispatchAuthenticatedProviderIntentFreshWithOperation
  , renderProviderCallerError
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , ProviderRevision
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (ExplicitPerRun)
  , DurableObservationRunScope (..)
  , LifecycleOperation (ReconcileDesiredAbsent, ReconcileDesiredPresent)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegisteredResourceKey
  , mkObservationEvidenceScope
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.StackGeneration (RegisteredStackGeneration)

-- | What one admitted registered-stack creation produced.
data RegisteredStackCreationSubmission = RegisteredStackCreationSubmission
  { submittedCreateOperation :: !OperationId
  -- ^ The admitted create, named so a later diagnosis can join to it.
  , submittedProviderScopeOperation :: !OperationId
  -- ^ The admitted scope observation whose retained receipt proved the
  -- account and region.
  , submittedCreateEvidence :: !Text
  -- ^ The Provider receipt the create returned, unmodified.
  , submittedGenerationDisposition :: !AwsStackCreationCommitResult
  }
  deriving (Eq, Show)

data RegisteredStackCreationSubmitError
  = -- | The retained local control plane's identity could not be read, so the
    -- foundation the generation key is built on is unknown.  Creation refuses
    -- rather than minting a key a later cleanup run could not reproduce.
    RegisteredStackCreationFoundationUnknown !String
  | -- | The @ObserveProviderAwsScope@ dispatch failed.  Without it the account
    -- and region would have to be asserted, which the producer refuses.
    RegisteredStackCreationScopeDispatchFailed !ProviderCallerError
  | -- | The create dispatch itself failed.  No generation is committed.
    RegisteredStackCreationDispatchFailed !ProviderCallerError
  | -- | The stack was created but the Authority could not be reached to commit
    -- its generation, so the stack exists and no later run can name its cycle.
    RegisteredStackCreationAuthorityUnreachable
      !Text
      !LifecycleAuthorityAuthenticationError
  | -- | The Authority refused or could not settle the generation commit.
    -- Carries the create evidence, because the stack may well exist.
    RegisteredStackCreationGenerationRefused !Text !AwsStackCreationBindingError
  | -- | The commit was reached and did not settle as committed.
    RegisteredStackCreationGenerationUnsettled !Text !AwsStackCreationCommitResult
  deriving (Eq, Show)

renderRegisteredStackCreationSubmitError
  :: RegisteredStackCreationSubmitError -> String
renderRegisteredStackCreationSubmitError err = case err of
  RegisteredStackCreationFoundationUnknown detail ->
    "resolve the retained local RKE2 foundation identity for the registered \
    \stack generation: "
      ++ detail
  RegisteredStackCreationScopeDispatchFailed detail ->
    "observe the Provider AWS scope before creating a registered stack: "
      ++ renderProviderCallerError detail
  RegisteredStackCreationDispatchFailed detail ->
    "dispatch the registered stack create: " ++ renderProviderCallerError detail
  RegisteredStackCreationAuthorityUnreachable evidence detail ->
    "the registered stack was created but its lifecycle generation could not \
    \be committed, so no later cleanup run can name its cycle: "
      ++ renderLifecycleAuthorityAuthenticationError detail
      ++ withEvidence evidence
  RegisteredStackCreationGenerationRefused evidence detail ->
    "the registered stack was created but the Authority refused its lifecycle \
    \generation: "
      ++ show detail
      ++ withEvidence evidence
  RegisteredStackCreationGenerationUnsettled evidence disposition ->
    "the registered stack was created but its lifecycle generation did not \
    \settle as committed: "
      ++ show disposition
      ++ withEvidence evidence
 where
  withEvidence evidence =
    " (Provider receipt: " ++ Text.unpack evidence ++ ")"

-- | The foundation id every generation key for this host is built on.
--
-- Derived from the retained control plane's cluster id, so a cleanup run
-- computes the same value from the same retained config without knowing which
-- run created the stack.  The prefix keeps it self-describing in a durable
-- record.
homeLinuxRke2FoundationId :: Text -> LinuxRke2FoundationId
homeLinuxRke2FoundationId clusterId =
  LinuxRke2FoundationId ("linux-rke2/" <> clusterId)

-- | A creating run scope.  Provenance only: 'selectRegisteredStackGeneration'
-- records it and never matches on it, which is exactly why a per-invocation
-- value is correct here and would not be in the key.
registeredStackCreationRunScope :: Integer -> DurableObservationRunScope
registeredStackCreationRunScope micros =
  DurableObservationRunScope ("stack-create/" <> Text.pack (show micros))

-- | The evidence scope one registered-stack creation is submitted under.
--
-- The AWS scope is deliberately 'Nothing': the account and region enter the
-- generation only through the Provider proof the Authority reads back, so
-- offering a slot for them here would be offering a slot for an assertion.
registeredStackCreationScope
  :: LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> ObservationEvidenceScope
registeredStackCreationScope foundation runScope =
  mkObservationEvidenceScope
    ExplicitPerRun
    lifecycleRegistryRevision
    runScope
    foundation
    Nothing
    ReconcileDesiredPresent

-- | Submit one registered-stack creation through the Authority and commit its
-- lifecycle generation.
--
-- The order is the producer's, and it matters: the scope observation precedes
-- the create so the generation can be committed immediately after, and the
-- generation precedes the run-scoped binding so a failure midway leaves the
-- addressable record present rather than a stack whose cycle no later run can
-- name.
submitRegisteredStackCreation
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Text
  -- ^ submission-key prefix for this create
  -> ProviderRevision
  -> ProviderIntent
  -- ^ the caller's exact registered-stack create intent
  -> IO (Either RegisteredStackCreationSubmitError RegisteredStackCreationSubmission)
submitRegisteredStackCreation authentication repoRoot prefix revision intent = do
  basics <- loadUnencryptedBasics repoRoot
  case basics of
    Left detail -> pure (Left (RegisteredStackCreationFoundationUnknown detail))
    Right identity -> do
      scopeDispatch <-
        dispatchAuthenticatedProviderIntentFreshWithOperation
          authentication
          (prefix <> "-observe-aws-scope")
          ObserveProviderAwsScope
      case scopeDispatch of
        Left err -> pure (Left (RegisteredStackCreationScopeDispatchFailed err))
        Right (scopeOperation, _) -> do
          createDispatch <-
            dispatchAuthenticatedProviderIntentFreshWithOperation
              authentication
              prefix
              intent
          case createDispatch of
            Left err -> pure (Left (RegisteredStackCreationDispatchFailed err))
            Right (createOperation, evidence) ->
              commitGeneration
                (basicsClusterId identity)
                scopeOperation
                createOperation
                evidence
 where
  commitGeneration clusterId scopeOperation createOperation evidence = do
    micros <- currentMicros
    let scope =
          registeredStackCreationScope
            (homeLinuxRke2FoundationId clusterId)
            (registeredStackCreationRunScope micros)
    committed <-
      withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
        attemptAwsStackCreationBindingCommit
          (lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient transport)
          createOperation
          scopeOperation
          revision
          scope
    pure $ case committed of
      Left err ->
        Left (RegisteredStackCreationAuthorityUnreachable evidence err)
      Right (Left err) ->
        Left (RegisteredStackCreationGenerationRefused evidence err)
      Right (Right disposition)
        | settled disposition ->
            Right
              RegisteredStackCreationSubmission
                { submittedCreateOperation = createOperation
                , submittedProviderScopeOperation = scopeOperation
                , submittedCreateEvidence = evidence
                , submittedGenerationDisposition = disposition
                }
        | otherwise ->
            Left (RegisteredStackCreationGenerationUnsettled evidence disposition)

  -- A replay is a settled outcome: the retried create was recognized as the
  -- same admitted operation and handed back its own cycle, which is the
  -- property that makes this lane safe to retry.
  settled disposition = case disposition of
    AwsStackCreationCommitCreated -> True
    AwsStackCreationCommitExactReplay -> True
    AwsStackCreationCommitConflict -> False
    AwsStackCreationCommitResponseLost {} -> False
    AwsStackCreationCommitUnavailable {} -> False

-- ---------------------------------------------------------------------------
-- The consumer half
-- ---------------------------------------------------------------------------

data RegisteredStackCleanupSelectError
  = -- | The retained control plane\'s identity could not be read, so the
    -- foundation this cleanup run would address the series under is unknown.
    -- It refuses rather than addressing a series it invented.
    RegisteredStackCleanupFoundationUnknown !String
  | -- | This cleanup run could not observe the Provider AWS scope, so the
    -- account and region that address the series are unproven.
    RegisteredStackCleanupScopeDispatchFailed !ProviderCallerError
  | -- | The Authority could not be reached.
    RegisteredStackCleanupAuthorityUnreachable !LifecycleAuthorityAuthenticationError
  | -- | The series cursor or the generation the ordinal addresses refused.  An
    -- unopened series, an unobservable store, a slot collision, and a surface
    -- that may not select this identity are distinct refusals behind this arm,
    -- and none of them degrades into \"nothing is there\".
    RegisteredStackCleanupSelectionRefused !AwsStackCreationBindingError
  deriving (Eq, Show)

renderRegisteredStackCleanupSelectError
  :: RegisteredStackCleanupSelectError -> String
renderRegisteredStackCleanupSelectError err = case err of
  RegisteredStackCleanupFoundationUnknown detail ->
    "resolve the retained local RKE2 foundation identity for registered stack \
    \cleanup selection: "
      ++ detail
  RegisteredStackCleanupScopeDispatchFailed detail ->
    "observe the Provider AWS scope before selecting a registered stack for \
    \cleanup: "
      ++ renderProviderCallerError detail
  RegisteredStackCleanupAuthorityUnreachable detail ->
    "reach the Lifecycle Authority to select a registered stack generation: "
      ++ renderLifecycleAuthorityAuthenticationError detail
  RegisteredStackCleanupSelectionRefused detail ->
    "the registered stack generation could not be selected for cleanup: "
      ++ show detail

-- | The evidence scope a cleanup run selects under.
--
-- The foundation is the same value a creating run used, because both derive it
-- from the retained cluster id — that identity is what makes selection across
-- runs possible at all.  The run scope differs and is meant to: the selector
-- records it and never matches on it.
registeredStackCleanupScope
  :: CleanupSurface
  -> LinuxRke2FoundationId
  -> DurableObservationRunScope
  -> ObservationEvidenceScope
registeredStackCleanupScope surface foundation runScope =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    runScope
    foundation
    Nothing
    ReconcileDesiredAbsent

-- | Select the current lifecycle generation of one registered stack for
-- cleanup, from a run that knows only which stack it intends to act on.
--
-- This is the production consumer the sprint owed.  It presents facts it can
-- prove — the registered key, its own admitted Provider AWS-scope observation,
-- its foundation, and its own run scope and surface — and reaches the cycle
-- through the series cursor and the generation that cursor's ordinal
-- addresses, and through nothing else.  There is no parameter through which
-- visible residue, the creating run's scope, or a caller-asserted account could
-- enter.
selectRegisteredStackGenerationForCleanup
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> RegisteredResourceKey
  -> CleanupSurface
  -> IO
       ( Either
           RegisteredStackCleanupSelectError
           RegisteredStackGeneration
       )
selectRegisteredStackGenerationForCleanup
  authentication
  repoRoot
  resourceKey
  surface = do
    basics <- loadUnencryptedBasics repoRoot
    case basics of
      Left detail -> pure (Left (RegisteredStackCleanupFoundationUnknown detail))
      Right identity -> do
        scopeDispatch <-
          dispatchAuthenticatedProviderIntentFreshWithOperation
            authentication
            "cleanup-observe-aws-scope"
            ObserveProviderAwsScope
        case scopeDispatch of
          Left err ->
            pure (Left (RegisteredStackCleanupScopeDispatchFailed err))
          Right (scopeOperation, _) ->
            select (basicsClusterId identity) scopeOperation
   where
    select clusterId scopeOperation = do
      micros <- currentMicros
      let scope =
            registeredStackCleanupScope
              surface
              (homeLinuxRke2FoundationId clusterId)
              (registeredStackCleanupRunScope micros)
      selected <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          selectRegisteredStackGenerationOverTransport
            transport
            resourceKey
            scopeOperation
            scope
      pure $ case selected of
        Left err -> Left (RegisteredStackCleanupAuthorityUnreachable err)
        Right (Left err) -> Left (RegisteredStackCleanupSelectionRefused err)
        Right (Right generation) -> Right generation

registeredStackCleanupRunScope :: Integer -> DurableObservationRunScope
registeredStackCleanupRunScope micros =
  DurableObservationRunScope ("stack-cleanup/" <> Text.pack (show micros))

currentMicros :: IO Integer
currentMicros = floor . (* 1000000) <$> getPOSIXTime
