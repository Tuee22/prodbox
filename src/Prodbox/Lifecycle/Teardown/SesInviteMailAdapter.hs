{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact registered mail-family observation and its evidence-bound reap
-- authorization. Stored coordinates, not current configuration, select mail.
module Prodbox.Lifecycle.Teardown.SesInviteMailAdapter
  ( InviteMailCleanupRequest
  , mkInviteMailCleanupRequest
  , inviteMailCleanupObservationIntent
  , decodeInviteMailCleanupObservation
  , InviteMailCleanupAuthorization
  , authorizeInviteMailCleanup
  , inviteMailCleanupAuthorizationScope
  , inviteMailCleanupReapIntent
  , InviteMailCleanupError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Prodbox.ControlPlane.ProviderWorkerExecution (ProviderIntentExecutionResult (..))
import Prodbox.Lifecycle.ProviderWorker.Evidence (decodeProviderEvidenceText)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveSesInviteMailResidue, ReapSesInviteMailResidue)
  , inviteMailCleanupEvidenceFamily
  , providerIntentCoordinate
  , providerIntentResourceKey
  , validateProviderIntentEvidence
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings

data InviteMailCleanupRequest
  = InviteMailCleanupRequest
      !RegisteredIdentity
      !ObservationEvidenceScope
      !ObservationRevision
      !InviteMailScope
  deriving (Eq, Show)

data InviteMailCleanupAuthorization
  = InviteMailCleanupAuthorization
      !ObservationEvidenceScope
      !InviteMailScope
  deriving (Eq, Show)

data InviteMailCleanupError
  = InviteMailCleanupRegistryUnavailable
  | InviteMailCleanupBindingMissing
  | InviteMailCleanupScopeInvalid
  | InviteMailCleanupSelectionInvalid !CleanupSelectionError
  | InviteMailCleanupObservationInvalid !CompleteObservationSetError
  | InviteMailCleanupEvidenceInvalid !Text
  deriving (Eq, Show)

mkInviteMailCleanupRequest
  :: CleanupSurfaceWitness surface
  -> ObservationRevision
  -> ObservationEvidenceScope
  -> Either InviteMailCleanupError InviteMailCleanupRequest
mkInviteMailCleanupRequest witness revision scope = do
  identity <-
    maybe
      (Left InviteMailCleanupRegistryUnavailable)
      Right
      (lookupRegisteredIdentity SesInviteMailObjectsKey)
  _ <- either (Left . InviteMailCleanupSelectionInvalid) Right (projectCleanupTarget witness identity)
  if evidenceCleanupSurface scope == cleanupSurfaceFromWitness witness
    && evidenceRegistryRevision scope == lifecycleRegistryRevision
    && evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    && evidenceAwsScope scope /= Nothing
    then Right ()
    else Left InviteMailCleanupScopeInvalid
  binding <-
    maybe
      (Left InviteMailCleanupBindingMissing)
      Right
      (evidenceResourceScopeBindings scope >>= resourceScopeInviteMail)
  Right (InviteMailCleanupRequest identity scope revision binding)

inviteMailCleanupObservationIntent :: InviteMailCleanupRequest -> ProviderIntent
inviteMailCleanupObservationIntent (InviteMailCleanupRequest _ _ _ binding) =
  ObserveSesInviteMailResidue binding

decodeInviteMailCleanupObservation
  :: InviteMailCleanupRequest
  -> Either Text ProviderIntentExecutionResult
  -> Either InviteMailCleanupError ExactResourceObservation
decodeInviteMailCleanupObservation request@(InviteMailCleanupRequest identity scope revision _) response =
  case response of
    Left detail -> Right (observed (ExactResourceUnobservable (ObservationFailure detail :| [])))
    Right (ProviderIntentExecutionObserved coordinate evidence)
      | coordinate /= providerIntentCoordinate intent ->
          Left (InviteMailCleanupEvidenceInvalid "mail cleanup coordinate mismatch")
      | otherwise -> case validateProviderIntentEvidence intent evidence
          >> decodeProviderEvidenceText inviteMailCleanupEvidenceFamily evidence of
          Left detail -> Right (observed (ExactResourceUnobservable (ObservationFailure detail :| [])))
          Right (family : rows)
            | family == ["family", providerIntentResourceKey intent] -> do
                identifiers <- traverse versionIdentity rows
                Right $ observed $ case identifiers of
                  [] ->
                    ExactResourceAbsent
                      (providerWorkerAbsence "registered invitation data-version family returned its complete empty set")
                  first : rest ->
                    ExactResourcePresent
                      (ExactResourceInventory (ObservedResourceIdentity first :| map ObservedResourceIdentity rest))
          Right _ -> Left (InviteMailCleanupEvidenceInvalid "mail cleanup answered another family")
    Right _ -> Left (InviteMailCleanupEvidenceInvalid "mail cleanup observation received a mutation result")
 where
  intent = inviteMailCleanupObservationIntent request
  observed = exactResourceObservationFor identity revision scope
  versionIdentity row = case row of
    ["version", value] -> Right value
    _ -> Left (InviteMailCleanupEvidenceInvalid "mail cleanup version row is malformed")

authorizeInviteMailCleanup
  :: InviteMailCleanupRequest
  -> ExactResourceObservation
  -> Either InviteMailCleanupError (Maybe InviteMailCleanupAuthorization)
authorizeInviteMailCleanup (InviteMailCleanupRequest _ scope _ binding) exact = do
  complete <-
    either
      (Left . InviteMailCleanupObservationInvalid)
      Right
      (mkCompleteObservationSet scope [SesInviteMailObjectsKey] [exact])
  case decideCompleteObservationSet complete of
    AllSelectedResourcesAbsent -> Right Nothing
    SelectedResourcesRequireCleanup _ -> Right (Just (InviteMailCleanupAuthorization scope binding))
    CompleteObservationsRefused _ -> Left (InviteMailCleanupEvidenceInvalid "mail cleanup observation is unresolved")

inviteMailCleanupAuthorizationScope :: InviteMailCleanupAuthorization -> ObservationEvidenceScope
inviteMailCleanupAuthorizationScope (InviteMailCleanupAuthorization scope _) = scope

inviteMailCleanupReapIntent :: InviteMailCleanupAuthorization -> ProviderIntent
inviteMailCleanupReapIntent (InviteMailCleanupAuthorization _ binding) = ReapSesInviteMailResidue binding
