{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Closed descriptor-bound runtime for the three cascade Stage-C nodes.
--
-- The runtime reconstructs convergence from the opaque durable run on every
-- entry, takes a fresh exact terminal audit under the audit node's stable
-- operation identity, and persists only the opaque Ready binding.  It keeps no
-- process-local proof cache, so response loss or process restart resumes from
-- Authority and retained-root facts rather than from remembered values.
module Prodbox.ControlPlane.CascadePreUninstallRuntime.Internal
  ( CascadePreUninstallRuntime
  , mkCascadePreUninstallRuntime
  , cascadePreUninstallDescriptorBoundNodeActionInternal
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.CascadeReportRepository
  ( CascadeReportAuthorityClient
  )
import Prodbox.ControlPlane.CleanupReportBackupClient
  ( CleanupReportBackupClient
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunNodeStates
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( DescriptorBoundCleanupNodeExecutionAction
  , descriptorBoundCleanupNodeAction
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentStore
  , hostCleanupReadyMatches
  , observeHostCleanupIntentForResume
  , observedHostCleanupIntent
  , persistHostCleanupReady
  , restoreObservedHostCleanupReady
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeAbsenceEvidence
  , CascadeCapabilityCustodyEvidence
  , CascadeCredentialDispositionEvidence
  , CascadePreUninstallReportObservation (..)
  , CascadeTerminalAuditEvidence
  , ReadyToUninstallEvidence
  , mkCascadeRunConvergenceEvidence
  , mkCascadeTerminalConvergenceEvidence
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAudit
  ( observeCascadeTerminalAudit
  )
import Prodbox.Lifecycle.Teardown.CascadeTerminalAuditAdapter
  ( providerCascadeTerminalAuditBoundary
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( LifecycleTeardownEffects (..)
  , TeardownExecutionContext
  , TeardownNodeResult (..)
  , runCompiledTeardownNodeWithDescriptorContext
  , teardownExecutionOperationIdFor
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (Cascade)
  , CleanupSurfaceWitness (..)
  , evidenceAwsScope
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( TerminalAuditObservation
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReadiness
  ( PreUninstallReadinessOutcome (..)
  , PreUninstallReadinessRun (..)
  , commitPreUninstallReport
  , renderPreUninstallReadinessRefusal
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReport
  ( preUninstallReportBytes
  , preUninstallReportDigest
  , renderPreUninstallReport
  )
import Prodbox.Lifecycle.Teardown.PreUninstallReportCommit
  ( cascadeReportCommitBoundary
  )
import Prodbox.Lifecycle.Teardown.PreUninstallStageC
  ( CascadeStageC (..)
  , renderCascadeStageCRefusal
  , runCascadeStageC
  )
import Prodbox.Lifecycle.Teardown.Program
  ( TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchPurpose (ProviderTerminalAudit)
  , TeardownProviderBoundary
  , dispatchRegisteredProviderObservation
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  , retainedCatalogFor
  )

data CascadePreUninstallRuntime = CascadePreUninstallRuntime
  { cascadePreUninstallRetainedBinding :: !RetainedNameBinding
  , cascadePreUninstallReportAuthority :: !(CascadeReportAuthorityClient IO)
  , cascadePreUninstallReportBackup :: !(CleanupReportBackupClient IO)
  , cascadePreUninstallProvider :: !(TeardownProviderBoundary IO)
  , cascadePreUninstallHostStore :: !HostCleanupIntentStore
  }

mkCascadePreUninstallRuntime
  :: RetainedNameBinding
  -> CascadeReportAuthorityClient IO
  -> CleanupReportBackupClient IO
  -> TeardownProviderBoundary IO
  -> HostCleanupIntentStore
  -> CascadePreUninstallRuntime
mkCascadePreUninstallRuntime = CascadePreUninstallRuntime

cascadePreUninstallDescriptorBoundNodeActionInternal
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupNodeExecutionAction
cascadePreUninstallDescriptorBoundNodeActionInternal runtime =
  descriptorBoundCleanupNodeAction $ \running _ compiled context plan ->
    runCascadePreUninstallEffects
      ( runCompiledTeardownNodeWithDescriptorContext
          running
          compiled
          context
          plan
      )
      runtime
      running

-- | Reader-like carrier whose environment contains only the closed Stage-C
-- runtime and the opaque descriptor-bound run.  The operation interpreter
-- re-opens that handle on every effect, so it never trusts a caller-supplied
-- compiled program or process-local proof cache.
newtype CascadePreUninstallEffects value = CascadePreUninstallEffects
  { runCascadePreUninstallEffects
      :: CascadePreUninstallRuntime
      -> DescriptorBoundCleanupRun
      -> IO value
  }

instance Functor CascadePreUninstallEffects where
  fmap transform action =
    CascadePreUninstallEffects $ \runtime running ->
      fmap transform (runCascadePreUninstallEffects action runtime running)

instance Applicative CascadePreUninstallEffects where
  pure value = CascadePreUninstallEffects $ \_ _ -> pure value
  function <*> value =
    CascadePreUninstallEffects $ \runtime running -> do
      transform <- runCascadePreUninstallEffects function runtime running
      input <- runCascadePreUninstallEffects value runtime running
      pure (transform input)

instance Monad CascadePreUninstallEffects where
  action >>= next =
    CascadePreUninstallEffects $ \runtime running -> do
      value <- runCascadePreUninstallEffects action runtime running
      runCascadePreUninstallEffects (next value) runtime running

instance LifecycleTeardownEffects CascadePreUninstallEffects where
  executeLifecycleTeardownOperation context operation =
    CascadePreUninstallEffects executeOperation
   where
    executeOperation runtime running = case operation of
      AuditCascadeEscapes ->
        withCascadeProgram
          running
          (\compiled -> runAudit runtime compiled context)
      CommitCascadePreUninstallReport ->
        withCascadeProgram
          running
          (\compiled -> runCommit runtime running compiled context)
      ReadBackCascadePreUninstallReport ->
        withCascadeProgram
          running
          (\compiled -> runReadBack runtime running compiled context)
      _ ->
        pure
          ( TeardownNodeRefused
              ( "cascade pre-uninstall runtime does not own `"
                  <> teardownOperationTag operation
                  <> "`"
              )
          )

withCascadeProgram
  :: DescriptorBoundCleanupRun
  -> (CompiledDesiredAbsenceProgram 'Cascade -> IO (TeardownNodeResult 'Cascade))
  -> IO (TeardownNodeResult 'Cascade)
withCascadeProgram running consume =
  case withDescriptorBoundCleanupProgram running select of
    Left err -> pure (TeardownNodeRefused (Text.pack (show err)))
    Right action -> action
 where
  select
    :: forall surface
     . CleanupSurfaceWitness surface
    -> CompiledDesiredAbsenceProgram surface
    -> DescriptorBoundCleanupRun
    -> IO (TeardownNodeResult 'Cascade)
  select witness compiled _ = case witness of
    CascadeSurface -> consume compiled
    _ ->
      pure
        ( TeardownNodeRefused
            "cascade pre-uninstall runtime received a non-cascade descriptor"
        )

runAudit
  :: CascadePreUninstallRuntime
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade)
runAudit runtime compiled context = do
  observed <- observeTerminal runtime compiled context
  pure $ case observed of
    Left detail -> TeardownNodeRefused detail
    Right (_, observation) ->
      TeardownTerminalAuditObservation observation

runCommit
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade)
runCommit runtime running compiled context = do
  convergence <- convergenceEvidence runtime running compiled context
  case convergence of
    Left detail -> pure (TeardownNodeRefused detail)
    Right (absence, credentials, audit, _custody) ->
      case renderPreUninstallReport compiled absence credentials audit of
        Left err -> pure (TeardownNodeRefused (Text.pack (show err)))
        Right report ->
          case cascadeReportCommitBoundary
            (cascadePreUninstallReportAuthority runtime)
            (cascadePreUninstallReportBackup runtime)
            compiled
            (preUninstallReportBytes report) of
            Left detail -> pure (TeardownNodeRefused detail)
            Right boundary -> do
              committed <- commitPreUninstallReport boundary (preUninstallReportDigest report)
              pure (TeardownMutationAttempt committed)

runReadBack
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO (TeardownNodeResult 'Cascade)
runReadBack runtime running compiled context = do
  convergence <- convergenceEvidence runtime running compiled context
  case convergence of
    Left detail -> pure (TeardownNodeRefused detail)
    Right (absence, credentials, audit, custody) -> do
      staged <-
        runCascadeStageC
          (cascadePreUninstallReportAuthority runtime)
          (cascadePreUninstallReportBackup runtime)
          compiled
          absence
          credentials
          audit
          custody
      case staged of
        Left err -> pure (TeardownNodeRefused (Text.pack (renderCascadeStageCRefusal err)))
        Right stage -> case preUninstallReadinessOutcome (cascadeStageCRun stage) of
          PreUninstallNotReady err ->
            pure (TeardownNodeRefused (Text.pack (renderPreUninstallReadinessRefusal err)))
          PreUninstallReady ready -> do
            persisted <- persistReady runtime ready
            pure $ case persisted of
              Left detail -> TeardownNodeRefused detail
              Right () ->
                TeardownDurableReceiptObservation
                  ( cascadePreUninstallReportReceipt
                      (preUninstallReadinessObservation (cascadeStageCRun stage))
                  )

-- | Reconstruct every pre-uninstall proof from durable run state plus the
-- stable terminal-audit operation.  The audit is deliberately repeated for
-- commit/read-back retries; its Provider submission and revision stay stable.
convergenceEvidence
  :: CascadePreUninstallRuntime
  -> DescriptorBoundCleanupRun
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO
       ( Either
           Text
           ( CascadeAbsenceEvidence
           , CascadeCredentialDispositionEvidence
           , CascadeTerminalAuditEvidence
           , CascadeCapabilityCustodyEvidence
           )
       )
convergenceEvidence runtime running compiled context =
  case first
    (Text.pack . show)
    (mkCascadeRunConvergenceEvidence compiled (descriptorBoundCleanupRunNodeStates running)) of
    Left detail -> pure (Left detail)
    Right (absence, custody) -> do
      observed <- observeTerminal runtime compiled context
      pure $ do
        (credentials, audit) <- fst <$> observed
        Right (absence, credentials, audit, custody)

observeTerminal
  :: CascadePreUninstallRuntime
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownExecutionContext 'Cascade
  -> IO
       ( Either
           Text
           ( ( CascadeCredentialDispositionEvidence
             , CascadeTerminalAuditEvidence
             )
           , TerminalAuditObservation 'Cascade
           )
       )
observeTerminal runtime compiled context =
  case evidenceAwsScope (compiledDesiredAbsenceObservationScope compiled) of
    Nothing -> pure (Left "cascade terminal audit has no compiled AWS scope")
    Just awsScope -> case retainedCatalogFor
      CascadeSurface
      awsScope
      (cascadePreUninstallRetainedBinding runtime) of
      Left err -> pure (Left (Text.pack (show err)))
      Right catalog -> case teardownExecutionOperationIdFor context AuditCascadeEscapes of
        Nothing -> pure (Left "cascade terminal audit operation identity is missing")
        Just operationId -> case mkProviderDispatchKey operationId ProviderTerminalAudit of
          Left err -> pure (Left (Text.pack (show err)))
          Right dispatchKey -> do
            let dispatch intent =
                  first (Text.pack . show)
                    <$> dispatchRegisteredProviderObservation
                      (cascadePreUninstallProvider runtime)
                      dispatchKey
                      intent
                boundary = providerCascadeTerminalAuditBoundary awsScope dispatch
            observation <-
              observeCascadeTerminalAudit
                boundary
                (cascadePreUninstallRetainedBinding runtime)
                compiled
                (observationRevisionForProviderDispatchKey dispatchKey)
            pure $ do
              exact <- first (Text.pack . show) observation
              evidence <-
                first
                  (Text.pack . show)
                  (mkCascadeTerminalConvergenceEvidence catalog compiled exact)
              Right (evidence, exact)

persistReady
  :: CascadePreUninstallRuntime
  -> ReadyToUninstallEvidence
  -> IO (Either Text ())
persistReady runtime ready = do
  observed <- observeHostCleanupIntentForResume (cascadePreUninstallHostStore runtime)
  case observed of
    Left err -> pure (Left (Text.pack (show err)))
    Right Nothing -> pure (Left "cascade host-cleanup intent is missing")
    Right (Just exact) -> do
      let intent = observedHostCleanupIntent exact
      persisted <-
        persistHostCleanupReady
          (cascadePreUninstallHostStore runtime)
          intent
          ready
      case persisted of
        Left err -> pure (Left (Text.pack (show err)))
        Right _ -> do
          readBack <- observeHostCleanupIntentForResume (cascadePreUninstallHostStore runtime)
          pure $ case readBack of
            Left err -> Left (Text.pack (show err))
            Right Nothing -> Left "cascade host-cleanup Ready binding disappeared"
            Right (Just durable) -> do
              restored <- first (Text.pack . show) (restoreObservedHostCleanupReady durable)
              matches <-
                first
                  (Text.pack . show)
                  (hostCleanupReadyMatches (observedHostCleanupIntent durable) restored)
              if restored == ready && matches
                then Right ()
                else Left "cascade host-cleanup Ready binding read-back mismatched"
