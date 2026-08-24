{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}

-- | Exact, attempt-bound interpreter for the Kubernetes-owner portion of an
-- EKS teardown.
--
-- Selection, mutation, and read-back are deliberately separate.  Selection
-- proves complete class queries and records only exact PVC names.  Mutation
-- consumes a read-back committed intent and a fenced attempt, then acquires a
-- fresh Provider-issued session.  Read-back acquires another fresh session,
-- lists both complete resource classes, and queries every persisted PVC name
-- directly.  It never reconstructs the PVC set from surviving PVs.
--
-- The production client is continuation-scoped.  Its bearer is written only
-- to a private FIFO inside a private temporary directory; the ephemeral
-- kubeconfig and FIFO are removed before the continuation returns and cannot
-- escape through the phantom client token.
module Prodbox.Lifecycle.Teardown.EksDrainInterpreter
  ( EksDrainInventoryResult (..)
  , EksDrainKubernetesUidObservation (..)
  , EksDrainPvcObservation (..)
  , EksDrainMutationResponse (..)
  , EksDrainClientEffects (..)
  , EksDrainClientAccessFailure (..)
  , EksDrainClientBoundary
  , mkEksDrainClientBoundary
  , productionEksDrainClientBoundary
  , EksDrainProjectionRequest (..)
  , EksDrainCommitSelectionBoundary
  , mkEksDrainCommitSelectionBoundary
  , productionEksDrainCommitSelectionBoundary
  , EksDrainAttemptBoundary
  , mkEksDrainAttemptBoundary
  , productionEksDrainAttemptBoundary
  , EksDrainCommitSelectionError (..)
  , EksDrainDestroyAdmissionError (..)
  , EksDrainInvocationBinding (..)
  , EksDrainSessionAcquisition (..)
  , EksDrainInterpreter
  , mkEksDrainInterpreter
  , EksDrainSessionArms
  , mkEksDrainSessionArms
  , VerifiedEksDrainSelection
  , verifiedEksDrainSelectionObservation
  , observeVerifiedEksDrainSelection
  , acquireVerifiedEksDrainSelection
  , acquireAwsEksDestroyAuthorization
  , prepareEksDrainIntentFromVerifiedSelection
  , executeCommittedEksDrainIntent
  , executeCommittedEksDrainIntentWithContext
  , observeEksDrainTargetsReadBack
  , observeEksDrainTargetsReadBackWithContext
  , executeEksDrainReadBack
  )
where

import Data.Kind (Type)
import Data.List (group, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksClientAuthClient
  ( EksClientAuthClientError (..)
  , withEksClientAuthProjectionForTeardownExecution
  )
import Prodbox.ControlPlane.EksClientAuthProjection (EksClientAuthProjection)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRevision
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
  ( AwsEksDestroyAuthorization
  , AwsEksDestroyRefusal (..)
  , authorizeAwsEksDestroy
  )
import Prodbox.Lifecycle.Teardown.Decision
  ( StackDesiredAbsenceDecision
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
  ( EphemeralKubectl
  , EphemeralKubectlUnavailable (..)
  , runEphemeralKubectl
  , withEphemeralKubectlForProjection
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownExecutionContext
  , teardownExecutionAttemptId
  , teardownExecutionGraphDigest
  , teardownExecutionIdentity
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  , teardownExecutionOperationIdFor
  , teardownExecutionRunId
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , TeardownOperation (..)
  , registeredTargetCoordinateDigest
  , registeredTargetKey
  , registeredTargetKind
  , registeredTargetLifecycleClass
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchError
  , ProviderDispatchPurpose (ProviderDecisionObservation)
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKey
  , registeredIdentityKind
  , registeredIdentityLifecycleClass
  )

-- | A complete list is positive evidence about the whole queried class.
-- Partial and unobservable results are intentionally distinct and can never
-- be normalized to an empty list.
data EksDrainInventoryResult value
  = EksDrainInventoryComplete ![value]
  | EksDrainInventoryPartial ![value] !(NonEmpty ObservationFailure)
  | EksDrainInventoryUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data EksDrainKubernetesUidObservation
  = EksDrainKubernetesUidPresent !Text
  | EksDrainKubernetesUidUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

-- | Presence carries the live UID for diagnostics.  The durable intent is
-- name-bound, so any object at that name -- including a recreated object with
-- another UID -- blocks absence confirmation.
data EksDrainPvcObservation
  = EksDrainPvcObservedAbsent !AbsenceEvidence
  | EksDrainPvcObservedPresent !Text
  | EksDrainPvcObservationUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

data EksDrainMutationResponse
  = EksDrainMutationResponseApplied
  | EksDrainMutationResponseRefused !ObservationFailure
  | EksDrainMutationResponseLost !ObservationFailure
  deriving (Eq, Show)

-- | Credential-free operations available inside one ephemeral client
-- lifetime.  The constructor is useful to deterministic fakes; production
-- creates the same value only after installing its private FIFO/kubeconfig.
data EksDrainClientEffects m = EksDrainClientEffects
  { eksDrainClientObserveKubernetesUid
      :: m EksDrainKubernetesUidObservation
  , eksDrainClientObserveLoadBalancerServices
      :: m (EksDrainInventoryResult EksNamespacedName)
  , eksDrainClientObserveIngresses
      :: m (EksDrainInventoryResult EksNamespacedName)
  , eksDrainClientObserveControllerOwners
      :: m (EksDrainInventoryResult EksNamespacedName)
  , eksDrainClientObserveDeletePolicyPvcs
      :: m (EksDrainInventoryResult EksNamespacedName)
  , eksDrainClientDeleteLoadBalancerServices
      :: m EksDrainMutationResponse
  , eksDrainClientDeleteIngresses
      :: m EksDrainMutationResponse
  , eksDrainClientDeleteControllerOwners
      :: m EksDrainMutationResponse
  , eksDrainClientDeletePvc
      :: EksNamespacedName -> m EksDrainMutationResponse
  , eksDrainClientObservePvc
      :: EksNamespacedName -> m EksDrainPvcObservation
  }

data EksDrainClientAccessFailure
  = EksDrainClientAccessRefused !ObservationFailure
  | EksDrainClientAccessUnobservable !ObservationFailure
  deriving (Eq, Show)

-- The token is universally quantified by 'EksDrainClientBoundary'.  A client
-- therefore cannot be returned from the continuation and used after its
-- private temporary directory has been removed.
newtype EksDrainEphemeralClient token m = EksDrainEphemeralClient
  { internalEksDrainClientEffects :: EksDrainClientEffects m
  }

newtype EksDrainClientBoundary m = EksDrainClientBoundary
  { internalWithEksDrainClient
      :: forall result
       . EksDrainSession
      -> ( forall (token :: Type)
            . Either
                EksDrainClientAccessFailure
                (EksDrainEphemeralClient token m)
           -> m result
         )
      -> m result
  }

-- | Build a continuation-scoped boundary from a credential-free resource
-- factory.  This is the fake seam; callers never receive the phantom client
-- constructor.
mkEksDrainClientBoundary
  :: ( forall result
        . EksDrainSession
       -> (Either EksDrainClientAccessFailure (EksDrainClientEffects m) -> m result)
       -> m result
     )
  -> EksDrainClientBoundary m
mkEksDrainClientBoundary factory =
  EksDrainClientBoundary $ \session consume ->
    factory session (consumeCreatedClient consume)
 where
  consumeCreatedClient consume created = case created of
    Left failure -> consume (Left failure)
    Right effects -> consume (Right (EksDrainEphemeralClient effects))

-- | Safe coordinates needed by the Provider auth issuer.  The request never
-- contains a bearer, endpoint, certificate authority, or caller-made
-- operation identity; the latter comes separately from the opaque teardown
-- execution admission.
data EksDrainProjectionRequest = EksDrainProjectionRequest
  { eksDrainProjectionAccountId :: !Text
  , eksDrainProjectionRegion :: !Text
  , eksDrainProjectionClusterName :: !Text
  }
  deriving (Eq, Show)

-- The projection and client share one rank-2 lifetime.  In particular, the
-- raw projection cannot be returned by 'acquireVerifiedEksDrainSelection'.
data EksDrainCommitSelectionClient token m = EksDrainCommitSelectionClient
  { internalEksDrainCommitSelectionProjection :: !EksClientAuthProjection
  , internalEksDrainCommitSelectionEffects :: !(EksDrainClientEffects m)
  }

newtype EksDrainCommitSelectionBoundary m = EksDrainCommitSelectionBoundary
  { internalWithEksDrainCommitSelectionClient
      :: forall result
       . TeardownExecutionIdentity
      -> EksDrainProjectionRequest
      -> ( forall (token :: Type)
            . Either
                EksDrainClientAccessFailure
                (EksDrainCommitSelectionClient token m)
           -> m result
         )
      -> m result
  }

-- | Fake/adapter constructor.  Its callback is itself continuation-scoped;
-- only this module can wrap the projection into the rank-2 client consumed by
-- the commit selector.
mkEksDrainCommitSelectionBoundary
  :: ( forall result
        . TeardownExecutionIdentity
       -> EksDrainProjectionRequest
       -> ( Either
              EksDrainClientAccessFailure
              (EksClientAuthProjection, EksDrainClientEffects m)
            -> m result
          )
       -> m result
     )
  -> EksDrainCommitSelectionBoundary m
mkEksDrainCommitSelectionBoundary factory =
  EksDrainCommitSelectionBoundary $ \execution request consume ->
    factory execution request (consumeCreatedClient consume)
 where
  consumeCreatedClient consume created = case created of
    Left failure -> consume (Left failure)
    Right (projection, effects) ->
      consume
        ( Right
            EksDrainCommitSelectionClient
              { internalEksDrainCommitSelectionProjection = projection
              , internalEksDrainCommitSelectionEffects = effects
              }
        )

-- | Attempt-aware projection boundary for the mutation and mandatory
-- read-back nodes.  It has the same continuation-only credential lifetime as
-- commit selection, but is a distinct type so production composition cannot
-- accidentally substitute a commit-node capability for an effect node.
newtype EksDrainAttemptBoundary m = EksDrainAttemptBoundary
  { internalWithEksDrainAttemptClient
      :: forall result
       . TeardownExecutionIdentity
      -> EksDrainProjectionRequest
      -> ( forall (token :: Type)
            . Either
                EksDrainClientAccessFailure
                (EksDrainCommitSelectionClient token m)
           -> m result
         )
      -> m result
  }

mkEksDrainAttemptBoundary
  :: ( forall result
        . TeardownExecutionIdentity
       -> EksDrainProjectionRequest
       -> ( Either
              EksDrainClientAccessFailure
              (EksClientAuthProjection, EksDrainClientEffects m)
            -> m result
          )
       -> m result
     )
  -> EksDrainAttemptBoundary m
mkEksDrainAttemptBoundary factory =
  EksDrainAttemptBoundary $ \execution request consume ->
    factory execution request (consumeCreatedClient consume)
 where
  consumeCreatedClient consume created = case created of
    Left failure -> consume (Left failure)
    Right (projection, effects) ->
      consume
        ( Right
            EksDrainCommitSelectionClient
              { internalEksDrainCommitSelectionProjection = projection
              , internalEksDrainCommitSelectionEffects = effects
              }
        )

data EksDrainCommitSelectionError
  = EksDrainCommitSelectionRegistryIdentityMissing
  | EksDrainCommitSelectionTargetKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | EksDrainCommitSelectionTargetLifecycleMismatch
      !(Maybe LifecycleClass)
      !(Maybe LifecycleClass)
  | EksDrainCommitSelectionTargetKindMismatch !ResourceKind !ResourceKind
  | EksDrainCommitSelectionTargetCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | EksDrainCommitSelectionExecutionScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainCommitSelectionExecutionRunMismatch !CleanupRunId !CleanupRunId
  | EksDrainCommitSelectionExecutionGraphMismatch !CleanupDigest !CleanupDigest
  | EksDrainCommitSelectionCurrentOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainCommitSelectionCatalogOperationMissing !Text
  | EksDrainCommitSelectionBindingOperationMismatch
      !Text
      !CleanupOperationId
      !CleanupOperationId
  | EksDrainCommitSelectionProviderObservationInvalid !EksDrainSessionError
  | EksDrainCommitSelectionProviderDispatchKeyInvalid !ProviderDispatchError
  | EksDrainCommitSelectionProviderObservationRevisionMismatch
      !ObservationRevision
      !ObservationRevision
  | EksDrainCommitSelectionAccessRefused !ObservationFailure
  | EksDrainCommitSelectionAccessUnobservable !ObservationFailure
  | EksDrainCommitSelectionKubernetesUidUnobservable
      !(NonEmpty ObservationFailure)
  | EksDrainCommitSelectionSessionInvalid !EksDrainSessionError
  | EksDrainCommitSelectionKubernetesUidChanged
      !(NonEmpty ObservationFailure)
  | EksDrainCommitSelectionIncomplete !EksDrainTargetSelectionObservation
  | EksDrainCommitSelectionIntentInvalid !EksDrainIntentError
  deriving (Eq, Show)

-- | Fail-closed admission errors for the later registered EKS stack destroy.
-- Context/catalog failures are deliberately shared with commit selection:
-- both entry points must prove the same exact target and four-operation drain
-- protocol before acquiring a Provider projection.
data EksDrainDestroyAdmissionError
  = EksDrainDestroyAdmissionContextInvalid !EksDrainCommitSelectionError
  | EksDrainDestroyAdmissionAccessRefused !ObservationFailure
  | EksDrainDestroyAdmissionAccessUnobservable !ObservationFailure
  | EksDrainDestroyAdmissionKubernetesUidUnobservable
      !(NonEmpty ObservationFailure)
  | EksDrainDestroyAdmissionSessionInvalid !EksDrainSessionError
  | EksDrainDestroyAdmissionRefused !AwsEksDestroyRefusal
  | EksDrainDestroyAdmissionServiceClassNotAbsent
      !(EksDrainInventoryResult EksNamespacedName)
  | EksDrainDestroyAdmissionIngressClassNotAbsent
      !(EksDrainInventoryResult EksNamespacedName)
  | EksDrainDestroyAdmissionControllerOwnerClassNotAbsent
      !(EksDrainInventoryResult EksNamespacedName)
  | EksDrainDestroyAdmissionPvcNotAbsent
      !EksNamespacedName
      !EksDrainPvcObservation
  deriving (Eq, Show)

-- | Untrusted invocation projection.  Production derives it from the sealed
-- teardown execution context.  Public fields let decoders and tests represent
-- stale cross-run/cross-attempt responses; every interpreter entry point
-- validates it against the committed intent.
data EksDrainInvocationBinding = EksDrainInvocationBinding
  { eksDrainInvocationScope :: !ObservationEvidenceScope
  , eksDrainInvocationRunId :: !CleanupRunId
  , eksDrainInvocationGraphDigest :: !CleanupDigest
  , eksDrainInvocationOperationId :: !CleanupOperationId
  , eksDrainInvocationAttemptId :: !CleanupAttemptId
  }
  deriving (Eq, Show)

-- | Fresh session acquisition result.  The returned binding is checked in
-- both directions so an Authority answer for another attempt cannot be used.
data EksDrainSessionAcquisition
  = EksDrainSessionAcquired
      !EksDrainInvocationBinding
      !EksDrainSession
  | EksDrainSessionAcquisitionRefused !ObservationFailure
  | EksDrainSessionAcquisitionUnobservable !ObservationFailure
  deriving (Eq, Show)

-- | Everything the interpreter itself owns: liveness, and nothing else.
--
-- Sprint @4.86@: this record used to carry a session-acquisition arm and the
-- ephemeral-client boundary that arm's session opens.  Neither was reachable
-- from the descriptor-bound path — the three entry points
-- 'Prodbox.Lifecycle.Teardown.EksTeardownExecutor.executeEksTeardownOperation'
-- uses go through the commit-selection and attempt boundaries, which issue
-- their own Provider auth and build their own session — and the acquisition arm
-- was moreover /unproducible/ in production: the session it must return needs a
-- fresh 'VerifiedAwsEksObservation' that 'EksDrainInvocationBinding' does not
-- carry.  A production composition therefore had no honest value to put there.
-- The arms now belong to 'EksDrainSessionArms', which only the session-driven
-- entry points below take, so a production cloud runtime names exactly the
-- clock it uses.
newtype EksDrainInterpreter m = EksDrainInterpreter
  { internalEksDrainCurrentEpochSeconds :: m Integer
  }

mkEksDrainInterpreter :: m Integer -> EksDrainInterpreter m
mkEksDrainInterpreter = EksDrainInterpreter

-- | The session-driven half, taken explicitly by the entry points that need
-- it rather than carried by every interpreter.
data EksDrainSessionArms m = EksDrainSessionArms
  { internalEksDrainAcquireSession
      :: EksDrainInvocationBinding -> m EksDrainSessionAcquisition
  , internalEksDrainClientBoundary :: EksDrainClientBoundary m
  }

mkEksDrainSessionArms
  :: (EksDrainInvocationBinding -> m EksDrainSessionAcquisition)
  -> EksDrainClientBoundary m
  -> EksDrainSessionArms m
mkEksDrainSessionArms = EksDrainSessionArms

-- | Opaque complete pre-mutation selection.  The intent is prepared while
-- the projection is still inside its rank-2 continuation, so the value that
-- escapes contains only durable-safe identity digests and exact selected
-- names.  It cannot retain a session, bearer, endpoint, CA bytes, or
-- kubeconfig.
data VerifiedEksDrainSelection = VerifiedEksDrainSelection
  { internalVerifiedEksDrainSelectionIntent :: !EksDrainIntent
  , internalVerifiedEksDrainSelectionObservation
      :: !EksDrainTargetSelectionObservation
  }

instance Show VerifiedEksDrainSelection where
  show selection =
    "<verified-eks-drain-selection:"
      <> Text.unpack
        (eksDrainSelectionClusterArn (verifiedEksDrainSelectionObservation selection))
      <> ">"

verifiedEksDrainSelectionObservation
  :: VerifiedEksDrainSelection -> EksDrainTargetSelectionObservation
verifiedEksDrainSelectionObservation =
  internalVerifiedEksDrainSelectionObservation

-- | Query the live UID first, then independently query all three complete
-- selection surfaces.  Only three complete answers can construct the opaque
-- result.
observeVerifiedEksDrainSelection
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainSessionArms m
  -> EksDrainOperationBinding
  -> ObservationRevision
  -> EksDrainSession
  -> m (Either EksDrainTargetSelectionObservation VerifiedEksDrainSelection)
observeVerifiedEksDrainSelection interpreter arms binding revision session = do
  now <- internalEksDrainCurrentEpochSeconds interpreter
  case validateSessionEnvelope now expectedScope expectedOperation session of
    Left detail -> pure (incomplete (singletonFailure detail))
    Right () ->
      internalWithEksDrainClient
        (internalEksDrainClientBoundary arms)
        session
        selectWithCreatedClient
 where
  expectedScope = eksDrainBindingScope binding
  expectedOperation = eksDrainBindingEffectOperationId binding
  observation result = eksDrainTargetSelectionObservationFor session revision result
  incomplete failures = Left (observation (EksDrainTargetSelectionUnobservable failures))

  selectWithCreatedClient created = case created of
    Left failure -> pure (incomplete (clientAccessFailures failure))
    Right client -> selectWithClient client

  selectWithClient client = do
    let effects = internalEksDrainClientEffects client
    uid <- eksDrainClientObserveKubernetesUid effects
    case validateLiveUid session uid of
      Left failures -> pure (incomplete failures)
      Right () -> do
        services <- normalizeInventory <$> eksDrainClientObserveLoadBalancerServices effects
        ingresses <- normalizeInventory <$> eksDrainClientObserveIngresses effects
        owners <- normalizeInventory <$> eksDrainClientObserveControllerOwners effects
        pvcs <- normalizeInventory <$> eksDrainClientObserveDeletePolicyPvcs effects
        case combineSelection services ingresses owners pvcs of
          EksDrainTargetSelectionComplete targets -> do
            let completeObservation =
                  observation (EksDrainTargetSelectionComplete targets)
            pure
              ( case verifiedSelection binding session completeObservation of
                  Left err ->
                    Left
                      ( observation
                          ( EksDrainTargetSelectionUnobservable
                              ( ObservationFailure
                                  ( "complete EKS selection could not bind its intent: "
                                      <> Text.pack (show err)
                                  )
                                  :| []
                              )
                          )
                      )
                  Right verified -> Right verified
              )
          result -> pure (Left (observation result))

-- | Acquire a Provider-issued projection under the current commit node's
-- opaque execution identity, but bind the resulting session to the distinct
-- future drain-effect operation recovered from the same sealed compiled
-- catalog.  The projection and ephemeral client die before this function
-- returns; only an already-prepared, durable-safe selection can escape.
acquireVerifiedEksDrainSelection
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainCommitSelectionBoundary m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> ObservationRevision
  -> ObservationRevision
  -> Integer
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> m (Either EksDrainCommitSelectionError VerifiedEksDrainSelection)
acquireVerifiedEksDrainSelection
  interpreter
  boundary
  context
  target
  binding
  kubernetesRevision
  selectionRevision
  deadline
  verified = do
    now <- internalEksDrainCurrentEpochSeconds interpreter
    case validateCommitSelectionAdmission context target binding verified of
      Left err -> pure (Left err)
      Right (request, providerArn) ->
        internalWithEksDrainCommitSelectionClient
          boundary
          (teardownExecutionIdentity context)
          request
          (selectWithCreatedProjectionClient now providerArn)
   where
    scope = eksDrainBindingScope binding
    effectOperation = eksDrainBindingEffectOperationId binding

    selectWithCreatedProjectionClient now providerArn created = case created of
      Left (EksDrainClientAccessRefused failure) ->
        pure (Left (EksDrainCommitSelectionAccessRefused failure))
      Left (EksDrainClientAccessUnobservable failure) ->
        pure (Left (EksDrainCommitSelectionAccessUnobservable failure))
      Right client ->
        selectWithProjectionClient now providerArn client

    selectWithProjectionClient now providerArn client = do
      let effects = internalEksDrainCommitSelectionEffects client
          projection = internalEksDrainCommitSelectionProjection client
      initialUid <- eksDrainClientObserveKubernetesUid effects
      case initialUid of
        EksDrainKubernetesUidUnobservable failures ->
          pure
            (Left (EksDrainCommitSelectionKubernetesUidUnobservable failures))
        EksDrainKubernetesUidPresent uid -> do
          let identityObservation =
                eksKubernetesIdentityObservationFor
                  scope
                  kubernetesRevision
                  providerArn
                  (EksKubernetesIdentityPresent uid)
                  projection
          case mkEksDrainSession
            now
            deadline
            effectOperation
            scope
            verified
            identityObservation
            projection of
            Left err -> pure (Left (EksDrainCommitSelectionSessionInvalid err))
            Right session -> do
              confirmedUid <- eksDrainClientObserveKubernetesUid effects
              case validateLiveUid session confirmedUid of
                Left failures ->
                  pure
                    (Left (EksDrainCommitSelectionKubernetesUidChanged failures))
                Right () -> selectCompleteInventory session effects

    selectCompleteInventory session effects = do
      services <- normalizeInventory <$> eksDrainClientObserveLoadBalancerServices effects
      ingresses <- normalizeInventory <$> eksDrainClientObserveIngresses effects
      owners <- normalizeInventory <$> eksDrainClientObserveControllerOwners effects
      pvcs <- normalizeInventory <$> eksDrainClientObserveDeletePolicyPvcs effects
      let result = combineSelection services ingresses owners pvcs
          observation =
            eksDrainTargetSelectionObservationFor session selectionRevision result
      case result of
        EksDrainTargetSelectionComplete _ ->
          pure
            ( either
                (Left . EksDrainCommitSelectionIntentInvalid)
                Right
                (verifiedSelection binding session observation)
            )
        _ -> pure (Left (EksDrainCommitSelectionIncomplete observation))

-- | Re-acquire the current EKS identity under the sealed registered-target
-- reconcile attempt and mint only the opaque AWS destroy authorization.  The
-- projection, bearer, Kubernetes client, and intermediate session all remain
-- inside the rank-2 continuation.  This function does not dispatch the
-- Provider mutation.
acquireAwsEksDestroyAuthorization
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainCommitSelectionBoundary m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> ProviderRevision
  -> StackDesiredAbsenceDecision
  -> EksDrainTargetsAbsentEvidence
  -> ObservationRevision
  -> Integer
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> m
       ( Either
           EksDrainDestroyAdmissionError
           AwsEksDestroyAuthorization
       )
acquireAwsEksDestroyAuthorization
  interpreter
  boundary
  context
  target
  binding
  providerRevision
  decision
  drainEvidence
  kubernetesRevision
  deadline
  verified = do
    now <- internalEksDrainCurrentEpochSeconds interpreter
    case mapLeft
      EksDrainDestroyAdmissionContextInvalid
      ( validateEksDrainProjectionAdmission
          ReconcileRegisteredTargetAbsent
          context
          target
          binding
          verified
      ) of
      Left err -> pure (Left err)
      Right (request, providerArn) ->
        internalWithEksDrainCommitSelectionClient
          boundary
          (teardownExecutionIdentity context)
          request
          (authorizeWithCreatedProjectionClient now providerArn)
   where
    scope = eksDrainBindingScope binding
    destroyOperation = teardownExecutionOperationId context

    authorizeWithCreatedProjectionClient now providerArn created = case created of
      Left (EksDrainClientAccessRefused failure) ->
        pure (Left (EksDrainDestroyAdmissionAccessRefused failure))
      Left (EksDrainClientAccessUnobservable failure) ->
        pure (Left (EksDrainDestroyAdmissionAccessUnobservable failure))
      Right client ->
        authorizeWithProjectionClient now providerArn client

    authorizeWithProjectionClient now providerArn client = do
      let effects = internalEksDrainCommitSelectionEffects client
          projection = internalEksDrainCommitSelectionProjection client
      observedUid <- eksDrainClientObserveKubernetesUid effects
      case observedUid of
        EksDrainKubernetesUidUnobservable failures ->
          pure
            ( Left
                (EksDrainDestroyAdmissionKubernetesUidUnobservable failures)
            )
        EksDrainKubernetesUidPresent uid -> do
          let identityObservation =
                eksKubernetesIdentityObservationFor
                  scope
                  kubernetesRevision
                  providerArn
                  (EksKubernetesIdentityPresent uid)
                  projection
          case mkEksDrainSession
            now
            deadline
            destroyOperation
            scope
            verified
            identityObservation
            projection of
            Left err -> pure (Left (EksDrainDestroyAdmissionSessionInvalid err))
            Right session -> do
              freshAbsence <-
                validateFreshDestroyTargetsAbsent
                  (eksDrainIntentTarget (eksDrainTargetsAbsentIntent drainEvidence))
                  session
                  effects
              pure $ do
                () <- freshAbsence
                mapLeft
                  EksDrainDestroyAdmissionRefused
                  ( authorizeAwsEksDestroy
                      now
                      providerRevision
                      binding
                      (eksDrainTargetsAbsentEffectAttemptId drainEvidence)
                      destroyOperation
                      verified
                      session
                      decision
                      drainEvidence
                  )

validateFreshDestroyTargetsAbsent
  :: (Monad m)
  => EksDrainIntentTarget
  -> EksDrainSession
  -> EksDrainClientEffects m
  -> m (Either EksDrainDestroyAdmissionError ())
validateFreshDestroyTargetsAbsent target session effects = case target of
  EksDrainNoKubernetesTarget {} ->
    pure
      ( Left
          ( EksDrainDestroyAdmissionRefused
              AwsEksDestroyNoKubernetesTargetCannotAuthorizeMutation
          )
      )
  EksDrainExactKubernetesTarget {eksDrainTargetDeletePolicyPvcs = targets} -> do
    liveUid <- eksDrainClientObserveKubernetesUid effects
    case validateLiveUid session liveUid of
      Left failures ->
        pure
          (Left (EksDrainDestroyAdmissionKubernetesUidUnobservable failures))
      Right () -> do
        owners <- normalizeInventory <$> eksDrainClientObserveControllerOwners effects
        case owners of
          EksDrainInventoryComplete [] -> do
            services <- normalizeInventory <$> eksDrainClientObserveLoadBalancerServices effects
            case services of
              EksDrainInventoryComplete [] -> do
                ingresses <- normalizeInventory <$> eksDrainClientObserveIngresses effects
                case ingresses of
                  EksDrainInventoryComplete [] -> validatePvcs targets
                  _ -> pure (Left (EksDrainDestroyAdmissionIngressClassNotAbsent ingresses))
              _ -> pure (Left (EksDrainDestroyAdmissionServiceClassNotAbsent services))
          _ ->
            pure
              (Left (EksDrainDestroyAdmissionControllerOwnerClassNotAbsent owners))
 where
  validatePvcs targets = case targets of
    [] -> pure (Right ())
    pvc : remaining -> do
      observed <- eksDrainClientObservePvc effects pvc
      case observed of
        EksDrainPvcObservedAbsent _ -> validatePvcs remaining
        _ -> pure (Left (EksDrainDestroyAdmissionPvcNotAbsent pvc observed))

prepareEksDrainIntentFromVerifiedSelection
  :: VerifiedEksDrainSelection -> Either EksDrainIntentError EksDrainIntent
prepareEksDrainIntentFromVerifiedSelection =
  Right . internalVerifiedEksDrainSelectionIntent

verifiedSelection
  :: EksDrainOperationBinding
  -> EksDrainSession
  -> EksDrainTargetSelectionObservation
  -> Either EksDrainIntentError VerifiedEksDrainSelection
verifiedSelection binding session observation = do
  intent <- prepareEksKubernetesDrainIntent binding session observation
  Right
    VerifiedEksDrainSelection
      { internalVerifiedEksDrainSelectionIntent = intent
      , internalVerifiedEksDrainSelectionObservation = observation
      }

-- | Execute one fenced effect attempt.  A structural or identity refusal is
-- recorded as a failed exact attempt; response loss remains unobservable and
-- can be closed only by the independent read-back entry point below.
executeCommittedEksDrainIntent
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainSessionArms m
  -> EksDrainInvocationBinding
  -> CommittedEksDrainIntent
  -> m (Either EksDrainIntentError EksDrainAttemptEvidence)
executeCommittedEksDrainIntent interpreter arms invocation committed = do
  let intent = committedEksDrainIntent committed
      attempt = beginEksDrainAttempt committed (eksDrainInvocationAttemptId invocation)
  case validateInvocation
    (eksDrainBindingEffectOperationId (eksDrainIntentBinding intent))
    invocation
    intent of
    Left detail -> pure (recordOutcome attempt (failedOutcome detail))
    Right () -> case eksDrainIntentTarget intent of
      EksDrainNoKubernetesTarget {} ->
        pure (recordOutcome attempt EksDrainSkippedNoKubernetesTarget)
      target@EksDrainExactKubernetesTarget {} -> do
        acquired <- internalEksDrainAcquireSession arms invocation
        case acquired of
          EksDrainSessionAcquisitionRefused failure ->
            pure (recordOutcome attempt (EksDrainMutationFailed failure))
          EksDrainSessionAcquisitionUnobservable failure ->
            pure (recordOutcome attempt (EksDrainMutationUnobservable failure))
          EksDrainSessionAcquired observedBinding session
            | observedBinding /= invocation ->
                pure
                  ( recordOutcome
                      attempt
                      (failedOutcome "fresh EKS session acquisition binding mismatch")
                  )
            | otherwise -> do
                now <- internalEksDrainCurrentEpochSeconds interpreter
                case validateSessionForTarget now invocation target session of
                  Left detail -> pure (recordOutcome attempt (failedOutcome detail))
                  Right () -> do
                    outcome <- mutateWithSession arms target session
                    pure (recordOutcome attempt outcome)

-- | Production-safe effect entry point.  The sealed execution context is
-- checked against the committed intent's four-operation binding before auth
-- issuance.  A fresh projection, UID observation, session, and Kubernetes
-- client exist only inside the attempt boundary continuation.
executeCommittedEksDrainIntentWithContext
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainAttemptBoundary m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> ObservationRevision
  -> Integer
  -> Maybe (VerifiedAwsEksObservation 'ObserveEksForDecision)
  -> CommittedEksDrainIntent
  -> m (Either EksDrainIntentError EksDrainAttemptEvidence)
executeCommittedEksDrainIntentWithContext
  interpreter
  boundary
  context
  registeredTarget
  kubernetesRevision
  deadline
  verified
  committed = do
    let intent = committedEksDrainIntent committed
        binding = eksDrainIntentBinding intent
        attempt = beginEksDrainAttempt committed (teardownExecutionAttemptId context)
        invocation = invocationForContext context
        refused err = recordOutcome attempt (failedOutcome (renderBounded err))
    case validateEksDrainProtocolContext
      DrainEksKubernetesResources
      context
      registeredTarget
      binding of
      Left err -> pure (refused err)
      Right () -> case validateInvocation
        (eksDrainBindingEffectOperationId binding)
        invocation
        intent of
        Left detail -> pure (recordOutcome attempt (failedOutcome detail))
        Right () -> case eksDrainIntentTarget intent of
          EksDrainNoKubernetesTarget {}
            | Just _ <- verified ->
                pure
                  ( recordOutcome
                      attempt
                      ( failedOutcome
                          "no-target EKS drain effect must not carry a Provider observation"
                      )
                  )
            | otherwise ->
                pure (recordOutcome attempt EksDrainSkippedNoKubernetesTarget)
          exactTarget@EksDrainExactKubernetesTarget {}
            | Nothing <- verified ->
                pure
                  ( recordOutcome
                      attempt
                      (failedOutcome "exact EKS drain effect requires a fresh Provider observation")
                  )
            | Just exactVerified <- verified ->
                case validateProviderObservationRevision context exactVerified
                  >> eksDrainProjectionRequestFor binding exactVerified of
                  Left err -> pure (refused err)
                  Right (request, providerArn) -> do
                    now <- internalEksDrainCurrentEpochSeconds interpreter
                    internalWithEksDrainAttemptClient
                      boundary
                      (teardownExecutionIdentity context)
                      request
                      ( executeWithCreatedProjectionClient
                          now
                          providerArn
                          invocation
                          attempt
                          exactVerified
                          exactTarget
                      )
   where
    executeWithCreatedProjectionClient
      now
      providerArn
      invocation
      attempt
      exactVerified
      target
      created = case created of
        Left (EksDrainClientAccessRefused failure) ->
          pure
            ( recordOutcome
                attempt
                (EksDrainMutationFailed failure)
            )
        Left (EksDrainClientAccessUnobservable failure) ->
          pure
            ( recordOutcome
                attempt
                (EksDrainMutationUnobservable failure)
            )
        Right client ->
          executeWithProjectionClient
            now
            providerArn
            invocation
            attempt
            exactVerified
            target
            client

    executeWithProjectionClient now providerArn invocation attempt exactVerified target client = do
      let effects = internalEksDrainCommitSelectionEffects client
          projection = internalEksDrainCommitSelectionProjection client
      observedUid <- eksDrainClientObserveKubernetesUid effects
      case observedUid of
        EksDrainKubernetesUidUnobservable failures ->
          pure
            ( recordOutcome
                attempt
                ( EksDrainMutationUnobservable
                    (combineObservationFailures "live EKS UID" failures)
                )
            )
        EksDrainKubernetesUidPresent uid -> do
          let identityObservation =
                eksKubernetesIdentityObservationFor
                  (eksDrainInvocationScope invocation)
                  kubernetesRevision
                  providerArn
                  (EksKubernetesIdentityPresent uid)
                  projection
          case mkEksDrainSession
            now
            deadline
            (eksDrainInvocationOperationId invocation)
            (eksDrainInvocationScope invocation)
            exactVerified
            identityObservation
            projection of
            Left err -> pure (recordOutcome attempt (failedOutcome (renderBounded err)))
            Right session -> case validateSessionForTarget now invocation target session of
              Left detail -> pure (recordOutcome attempt (failedOutcome detail))
              Right () -> do
                outcome <- mutateWithClient target session effects
                pure (recordOutcome attempt outcome)

-- | Produce the flat independent observation consumed by
-- 'confirmEksDrainTargetsAbsent'.  A failed/response-lost mutation is not
-- trusted; the same exact queries run for every attempt outcome.
observeEksDrainTargetsReadBack
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainSessionArms m
  -> EksDrainInvocationBinding
  -> EksDrainAttemptEvidence
  -> m EksDrainTargetReadBackObservation
observeEksDrainTargetsReadBack interpreter arms invocation attempt = do
  let intent = eksDrainAttemptIntent attempt
      binding = eksDrainIntentBinding intent
      refuse detail =
        eksDrainTargetReadBackObservationFor
          attempt
          (EksDrainTargetReadBackUnobservable (singletonFailure detail))
  case validateInvocation
    (eksDrainBindingDrainReadBackOperationId binding)
    invocation
    intent of
    Left detail -> pure (refuse detail)
    Right () -> case eksDrainIntentTarget intent of
      EksDrainNoKubernetesTarget {} ->
        pure
          ( eksDrainTargetReadBackObservationFor
              attempt
              EksDrainObservedNoKubernetesTarget
          )
      target@EksDrainExactKubernetesTarget {} -> do
        acquired <- internalEksDrainAcquireSession arms invocation
        case acquired of
          EksDrainSessionAcquisitionRefused failure ->
            pure (unobservableReadBack attempt (failure :| []))
          EksDrainSessionAcquisitionUnobservable failure ->
            pure (unobservableReadBack attempt (failure :| []))
          EksDrainSessionAcquired observedBinding session
            | observedBinding /= invocation ->
                pure
                  ( refuse
                      "fresh EKS read-back session acquisition binding mismatch"
                  )
            | otherwise -> do
                now <- internalEksDrainCurrentEpochSeconds interpreter
                case validateSessionForTarget now invocation target session of
                  Left detail -> pure (refuse detail)
                  Right () -> readBackWithSession arms attempt target session

-- | Production-safe mandatory read-back.  It performs its own auth issuance
-- under the sealed read-back attempt and queries the exact durable intent PVC
-- names.  The committed intent is supplied separately so a recovered attempt
-- from another intent cannot be paired with this context.
observeEksDrainTargetsReadBackWithContext
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainAttemptBoundary m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> ObservationRevision
  -> Integer
  -> Maybe (VerifiedAwsEksObservation 'ObserveEksForDecision)
  -> CommittedEksDrainIntent
  -> EksDrainAttemptEvidence
  -> m EksDrainTargetReadBackObservation
observeEksDrainTargetsReadBackWithContext
  interpreter
  boundary
  context
  registeredTarget
  kubernetesRevision
  deadline
  verified
  committed
  attempt = do
    let intent = committedEksDrainIntent committed
        binding = eksDrainIntentBinding intent
        invocation = invocationForContext context
        refuse detail =
          unobservableReadBack attempt (singletonFailure detail)
        refuseShow = refuse . renderBounded
    if eksDrainAttemptIntent attempt /= intent
      then pure (refuse "EKS read-back attempt does not match committed intent")
      else case validateEksDrainProtocolContext
        ReadBackEksKubernetesDrain
        context
        registeredTarget
        binding of
        Left err -> pure (refuseShow err)
        Right () -> case validateInvocation
          (eksDrainBindingDrainReadBackOperationId binding)
          invocation
          intent of
          Left detail -> pure (refuse detail)
          Right () -> case eksDrainIntentTarget intent of
            EksDrainNoKubernetesTarget {}
              | Just _ <- verified ->
                  pure
                    ( refuse
                        "no-target EKS drain read-back must not carry a Provider observation"
                    )
              | otherwise ->
                  pure
                    ( eksDrainTargetReadBackObservationFor
                        attempt
                        EksDrainObservedNoKubernetesTarget
                    )
            exactTarget@EksDrainExactKubernetesTarget {}
              | Nothing <- verified ->
                  pure (refuse "exact EKS drain read-back requires a fresh Provider observation")
              | Just exactVerified <- verified ->
                  case validateProviderObservationRevision context exactVerified
                    >> eksDrainProjectionRequestFor binding exactVerified of
                    Left err -> pure (refuseShow err)
                    Right (request, providerArn) -> do
                      now <- internalEksDrainCurrentEpochSeconds interpreter
                      internalWithEksDrainAttemptClient
                        boundary
                        (teardownExecutionIdentity context)
                        request
                        ( readBackWithCreatedProjectionClient
                            now
                            providerArn
                            invocation
                            attempt
                            exactVerified
                            exactTarget
                        )
   where
    readBackWithCreatedProjectionClient
      now
      providerArn
      invocation
      attempted
      exactVerified
      target
      created = case created of
        Left failure ->
          pure
            ( unobservableReadBack
                attempted
                (clientAccessFailures failure)
            )
        Right client ->
          readBackWithProjectionClient
            now
            providerArn
            invocation
            attempted
            exactVerified
            target
            client

    readBackWithProjectionClient now providerArn invocation attempted exactVerified target client = do
      let effects = internalEksDrainCommitSelectionEffects client
          projection = internalEksDrainCommitSelectionProjection client
      observedUid <- eksDrainClientObserveKubernetesUid effects
      case observedUid of
        EksDrainKubernetesUidUnobservable failures ->
          pure (unobservableReadBack attempted failures)
        EksDrainKubernetesUidPresent uid -> do
          let identityObservation =
                eksKubernetesIdentityObservationFor
                  (eksDrainInvocationScope invocation)
                  kubernetesRevision
                  providerArn
                  (EksKubernetesIdentityPresent uid)
                  projection
          case mkEksDrainSession
            now
            deadline
            (eksDrainInvocationOperationId invocation)
            (eksDrainInvocationScope invocation)
            exactVerified
            identityObservation
            projection of
            Left err ->
              pure (unobservableReadBack attempted (singletonFailure (renderBounded err)))
            Right session -> case validateSessionForTarget now invocation target session of
              Left detail -> pure (unobservableReadBack attempted (singletonFailure detail))
              Right () -> readBackWithClient attempted target session effects

executeEksDrainReadBack
  :: (Monad m)
  => EksDrainInterpreter m
  -> EksDrainSessionArms m
  -> EksDrainInvocationBinding
  -> EksDrainAttemptEvidence
  -> m (Either EksDrainIntentError EksDrainTargetsAbsentEvidence)
executeEksDrainReadBack interpreter arms invocation attempt = do
  observation <-
    observeEksDrainTargetsReadBack interpreter arms invocation attempt
  pure (confirmEksDrainTargetsAbsent attempt observation)

mutateWithSession
  :: (Monad m)
  => EksDrainSessionArms m
  -> EksDrainIntentTarget
  -> EksDrainSession
  -> m EksDrainAttemptOutcome
mutateWithSession arms target session =
  internalWithEksDrainClient
    (internalEksDrainClientBoundary arms)
    session
    mutateWithCreatedClient
 where
  mutateWithCreatedClient created = case created of
    Left (EksDrainClientAccessRefused failure) ->
      pure (EksDrainMutationFailed failure)
    Left (EksDrainClientAccessUnobservable failure) ->
      pure (EksDrainMutationUnobservable failure)
    Right client ->
      mutateWithClient
        target
        session
        (internalEksDrainClientEffects client)

mutateWithClient
  :: (Monad m)
  => EksDrainIntentTarget
  -> EksDrainSession
  -> EksDrainClientEffects m
  -> m EksDrainAttemptOutcome
mutateWithClient target session effects = do
  uid <- eksDrainClientObserveKubernetesUid effects
  case validateLiveUid session uid of
    Left failures ->
      pure
        ( EksDrainMutationUnobservable
            (combineObservationFailures "live EKS UID" failures)
        )
    Right () -> do
      ownerResponse <- eksDrainClientDeleteControllerOwners effects
      serviceResponse <- eksDrainClientDeleteLoadBalancerServices effects
      ingressResponse <- eksDrainClientDeleteIngresses effects
      pvcResponses <-
        mapM
          (eksDrainClientDeletePvc effects)
          (eksDrainTargetDeletePolicyPvcs target)
      pure
        ( classifyMutationResponses
            (ownerResponse : serviceResponse : ingressResponse : pvcResponses)
        )

readBackWithSession
  :: (Monad m)
  => EksDrainSessionArms m
  -> EksDrainAttemptEvidence
  -> EksDrainIntentTarget
  -> EksDrainSession
  -> m EksDrainTargetReadBackObservation
readBackWithSession arms attempt target session =
  internalWithEksDrainClient
    (internalEksDrainClientBoundary arms)
    session
    readBackWithCreatedClient
 where
  readBackWithCreatedClient created = case created of
    Left failure -> pure (unobservableReadBack attempt (clientAccessFailures failure))
    Right client ->
      readBackWithClient
        attempt
        target
        session
        (internalEksDrainClientEffects client)

readBackWithClient
  :: (Monad m)
  => EksDrainAttemptEvidence
  -> EksDrainIntentTarget
  -> EksDrainSession
  -> EksDrainClientEffects m
  -> m EksDrainTargetReadBackObservation
readBackWithClient attempt target session effects = do
  uid <- eksDrainClientObserveKubernetesUid effects
  case validateLiveUid session uid of
    Left failures -> pure (unobservableReadBack attempt failures)
    Right () -> do
      services <-
        normalizeInventory
          <$> eksDrainClientObserveLoadBalancerServices effects
      ingresses <- normalizeInventory <$> eksDrainClientObserveIngresses effects
      owners <- normalizeInventory <$> eksDrainClientObserveControllerOwners effects
      -- Load-bearing: these are exact persisted intent names.  The PV
      -- selection callback is deliberately not reachable here.
      pvcs <-
        mapM
          (observeExactPvc effects)
          (eksDrainTargetDeletePolicyPvcs target)
      pure
        ( eksDrainTargetReadBackObservationFor
            attempt
            ( EksDrainObservedKubernetesTarget
                EksDrainKubernetesTargetReadBack
                  { eksDrainReadBackProviderArn =
                      eksClusterArnText (eksDrainSessionClusterArn session)
                  , eksDrainReadBackKubernetesUid =
                      eksClusterUidText (eksDrainSessionClusterUid session)
                  , eksDrainReadBackEndpointDigest =
                      eksDrainSessionEndpointDigest session
                  , eksDrainReadBackCertificateAuthorityDigest =
                      eksDrainSessionCertificateAuthorityDigest session
                  , eksDrainReadBackLoadBalancerServiceClass =
                      LoadBalancerServiceClassReadBack
                        ( inventoryReadBack
                            "complete LoadBalancer Service class absent"
                            services
                        )
                  , eksDrainReadBackIngressClass =
                      IngressClassReadBack
                        ( inventoryReadBack
                            "complete Ingress class absent"
                            ingresses
                        )
                  , eksDrainReadBackControllerOwnerClass =
                      ControllerOwnerClassReadBack
                        ( inventoryReadBack
                            "exact registered public-edge controller owner absent"
                            owners
                        )
                  , eksDrainReadBackDeletePolicyPvcs = pvcs
                  }
            )
        )

observeExactPvc
  :: (Monad m)
  => EksDrainClientEffects m
  -> EksNamespacedName
  -> m EksDrainPvcReadBack
observeExactPvc effects target = do
  observed <- eksDrainClientObservePvc effects target
  pure
    ( EksDrainPvcReadBack
        target
        ( case observed of
            EksDrainPvcObservedAbsent evidence -> EksDrainPvcAbsent evidence
            EksDrainPvcObservedPresent _ -> EksDrainPvcPresent
            EksDrainPvcObservationUnobservable failures ->
              EksDrainPvcUnobservable failures
        )
    )

validateCommitSelectionAdmission
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> Either
       EksDrainCommitSelectionError
       (EksDrainProjectionRequest, Text)
validateCommitSelectionAdmission =
  validateEksDrainProjectionAdmission CommitEksDrainIntent

validateEksDrainProjectionAdmission
  :: (RegisteredTargetBinding -> TeardownOperation surface)
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> Either
       EksDrainCommitSelectionError
       (EksDrainProjectionRequest, Text)
validateEksDrainProjectionAdmission currentOperation context target binding verified = do
  validateEksDrainProtocolContext currentOperation context target binding
  validateProviderObservationRevision context verified
  eksDrainProjectionRequestFor binding verified

validateProviderObservationRevision
  :: TeardownExecutionContext surface
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> Either EksDrainCommitSelectionError ()
validateProviderObservationRevision context verified = do
  dispatchKey <-
    mapLeft
      EksDrainCommitSelectionProviderDispatchKeyInvalid
      ( mkProviderDispatchKey
          (teardownExecutionOperationId context)
          ProviderDecisionObservation
      )
  requireEqual
    EksDrainCommitSelectionProviderObservationRevisionMismatch
    (observationRevisionForProviderDispatchKey dispatchKey)
    ( exactObservationRevision
        (verifiedAwsEksExactObservation verified)
    )

validateEksDrainProtocolContext
  :: (RegisteredTargetBinding -> TeardownOperation surface)
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> Either EksDrainCommitSelectionError ()
validateEksDrainProtocolContext currentOperation context target binding = do
  validateExactEksTarget target
  requireEqual
    EksDrainCommitSelectionExecutionScopeMismatch
    (eksDrainBindingScope binding)
    (teardownExecutionObservationScope context)
  requireEqual
    EksDrainCommitSelectionExecutionRunMismatch
    (eksDrainBindingRunId binding)
    (teardownExecutionRunId context)
  requireEqual
    EksDrainCommitSelectionExecutionGraphMismatch
    (eksDrainBindingGraphDigest binding)
    (teardownExecutionGraphDigest context)

  commitOperation <-
    catalogOperation "commit EKS drain intent" (CommitEksDrainIntent target)
  intentReadBackOperation <-
    catalogOperation "read back EKS drain intent" (ReadBackEksDrainIntent target)
  effectOperation <-
    catalogOperation "drain EKS Kubernetes resources" (DrainEksKubernetesResources target)
  drainReadBackOperation <-
    catalogOperation "read back EKS Kubernetes drain" (ReadBackEksKubernetesDrain target)
  admittedCurrentOperation <-
    catalogOperation "current EKS lifecycle operation" (currentOperation target)

  requireEqual
    EksDrainCommitSelectionCurrentOperationMismatch
    admittedCurrentOperation
    (teardownExecutionOperationId context)
  validateBindingOperation
    "commit EKS drain intent"
    commitOperation
    (eksDrainBindingIntentCommitOperationId binding)
  validateBindingOperation
    "read back EKS drain intent"
    intentReadBackOperation
    (eksDrainBindingIntentReadBackOperationId binding)
  validateBindingOperation
    "drain EKS Kubernetes resources"
    effectOperation
    (eksDrainBindingEffectOperationId binding)
  validateBindingOperation
    "read back EKS Kubernetes drain"
    drainReadBackOperation
    (eksDrainBindingDrainReadBackOperationId binding)
 where
  catalogOperation label operation =
    maybe
      (Left (EksDrainCommitSelectionCatalogOperationMissing label))
      Right
      (teardownExecutionOperationIdFor context operation)

  validateBindingOperation label expected actual =
    requireEqual
      (EksDrainCommitSelectionBindingOperationMismatch label)
      expected
      actual

eksDrainProjectionRequestFor
  :: EksDrainOperationBinding
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> Either
       EksDrainCommitSelectionError
       (EksDrainProjectionRequest, Text)
eksDrainProjectionRequestFor binding verified = do
  clusterArn <-
    mapLeft
      EksDrainCommitSelectionProviderObservationInvalid
      ( eksClusterArnFromExactObservation
          (eksDrainBindingScope binding)
          (verifiedAwsEksExactObservation verified)
      )
  awsScope <-
    maybe
      ( Left
          ( EksDrainCommitSelectionProviderObservationInvalid
              EksDrainObservationAwsScopeMissing
          )
      )
      Right
      (evidenceAwsScope (eksDrainBindingScope binding))
  let AwsScope (AwsAccountId account) (AwsRegion region) = awsScope
      providerArn = eksClusterArnText clusterArn
      (_, clusterName) = Text.breakOnEnd "cluster/" providerArn
  Right
    ( EksDrainProjectionRequest
        { eksDrainProjectionAccountId = account
        , eksDrainProjectionRegion = region
        , eksDrainProjectionClusterName = clusterName
        }
    , providerArn
    )

validateExactEksTarget
  :: RegisteredTargetBinding -> Either EksDrainCommitSelectionError ()
validateExactEksTarget target = do
  identity <-
    maybe
      (Left EksDrainCommitSelectionRegistryIdentityMissing)
      Right
      (lookupRegisteredIdentity AwsEksKey)
  requireEqual
    EksDrainCommitSelectionTargetKeyMismatch
    (registeredIdentityKey identity)
    (registeredTargetKey target)
  requireEqual
    EksDrainCommitSelectionTargetLifecycleMismatch
    (registeredIdentityLifecycleClass identity)
    (registeredTargetLifecycleClass target)
  requireEqual
    EksDrainCommitSelectionTargetKindMismatch
    (registeredIdentityKind identity)
    (registeredTargetKind target)
  requireEqual
    EksDrainCommitSelectionTargetCoordinateMismatch
    (registeredIdentityCoordinateDigest identity)
    (registeredTargetCoordinateDigest target)

validateInvocation
  :: CleanupOperationId
  -> EksDrainInvocationBinding
  -> EksDrainIntent
  -> Either Text ()
validateInvocation expectedOperation invocation intent
  | eksDrainInvocationScope invocation /= eksDrainBindingScope binding =
      Left "EKS drain invocation scope mismatch"
  | eksDrainInvocationRunId invocation /= eksDrainBindingRunId binding =
      Left "EKS drain invocation run mismatch"
  | eksDrainInvocationGraphDigest invocation /= eksDrainBindingGraphDigest binding =
      Left "EKS drain invocation graph mismatch"
  | eksDrainInvocationOperationId invocation /= expectedOperation =
      Left "EKS drain invocation operation mismatch"
  | otherwise = Right ()
 where
  binding = eksDrainIntentBinding intent

invocationForContext
  :: TeardownExecutionContext surface -> EksDrainInvocationBinding
invocationForContext context =
  EksDrainInvocationBinding
    { eksDrainInvocationScope = teardownExecutionObservationScope context
    , eksDrainInvocationRunId = teardownExecutionRunId context
    , eksDrainInvocationGraphDigest = teardownExecutionGraphDigest context
    , eksDrainInvocationOperationId = teardownExecutionOperationId context
    , eksDrainInvocationAttemptId = teardownExecutionAttemptId context
    }

validateSessionEnvelope
  :: Integer
  -> ObservationEvidenceScope
  -> CleanupOperationId
  -> EksDrainSession
  -> Either Text ()
validateSessionEnvelope now expectedScope expectedOperation session
  | eksDrainSessionEvidenceScope session /= expectedScope =
      Left "fresh EKS session scope mismatch"
  | eksDrainSessionOperationId session /= expectedOperation =
      Left "fresh EKS session operation mismatch"
  | eksDrainSessionExpiresAtEpochSeconds session <= now =
      Left "fresh EKS session is expired"
  | otherwise = Right ()

validateSessionForTarget
  :: Integer
  -> EksDrainInvocationBinding
  -> EksDrainIntentTarget
  -> EksDrainSession
  -> Either Text ()
validateSessionForTarget now invocation target session = do
  validateSessionEnvelope
    now
    (eksDrainInvocationScope invocation)
    (eksDrainInvocationOperationId invocation)
    session
  case target of
    EksDrainNoKubernetesTarget {} -> Left "EKS session supplied for no-target intent"
    EksDrainExactKubernetesTarget arn uid endpoint ca _ _ _ _ _
      | arn /= eksClusterArnText (eksDrainSessionClusterArn session) ->
          Left "fresh EKS session provider ARN mismatch"
      | uid /= eksClusterUidText (eksDrainSessionClusterUid session) ->
          Left "fresh EKS session Kubernetes UID mismatch"
      | endpoint /= eksDrainSessionEndpointDigest session ->
          Left "fresh EKS session endpoint digest mismatch"
      | ca /= eksDrainSessionCertificateAuthorityDigest session ->
          Left "fresh EKS session certificate-authority digest mismatch"
      | otherwise -> Right ()

validateLiveUid
  :: EksDrainSession
  -> EksDrainKubernetesUidObservation
  -> Either (NonEmpty ObservationFailure) ()
validateLiveUid session observed = case observed of
  EksDrainKubernetesUidUnobservable failures -> Left failures
  EksDrainKubernetesUidPresent uid
    | uid == eksClusterUidText (eksDrainSessionClusterUid session) -> Right ()
    | otherwise ->
        Left
          ( ObservationFailure
              "live Kubernetes UID does not match the fresh EKS session"
              :| []
          )

recordOutcome
  :: EksDrainAttempt
  -> EksDrainAttemptOutcome
  -> Either EksDrainIntentError EksDrainAttemptEvidence
recordOutcome attempt =
  recordEksDrainAttempt attempt . eksDrainAttemptObservationFor attempt

failedOutcome :: Text -> EksDrainAttemptOutcome
failedOutcome = EksDrainMutationFailed . ObservationFailure

classifyMutationResponses
  :: [EksDrainMutationResponse] -> EksDrainAttemptOutcome
classifyMutationResponses responses =
  case [failure | EksDrainMutationResponseLost failure <- responses] of
    first : rest ->
      EksDrainMutationUnobservable
        ( combineObservationFailures
            "Kubernetes delete response loss"
            (first :| (rest <> refusedFailures))
        )
    [] -> case refusedFailures of
      first : rest ->
        EksDrainMutationFailed
          ( combineObservationFailures
              "Kubernetes delete refusal"
              (first :| rest)
          )
      [] -> EksDrainMutationApplied
 where
  refusedFailures =
    [failure | EksDrainMutationResponseRefused failure <- responses]

combineSelection
  :: EksDrainInventoryResult EksNamespacedName
  -> EksDrainInventoryResult EksNamespacedName
  -> EksDrainInventoryResult EksNamespacedName
  -> EksDrainInventoryResult EksNamespacedName
  -> EksDrainTargetSelectionResult
combineSelection services ingresses owners pvcs
  | not (null unobservableFailures) =
      EksDrainTargetSelectionUnobservable
        (NonEmpty.fromList (unobservableFailures <> partialFailures))
  | not (null partialFailures) =
      EksDrainTargetSelectionPartial
        (inventoryKnownValues pvcs)
        (NonEmpty.fromList partialFailures)
  | otherwise =
      EksDrainTargetSelectionComplete (inventoryKnownValues pvcs)
 where
  inventories = [services, ingresses, owners, pvcs]
  unobservableFailures = concatMap inventoryUnobservableFailures inventories
  partialFailures = concatMap inventoryPartialFailures inventories

inventoryKnownValues :: EksDrainInventoryResult value -> [value]
inventoryKnownValues result = case result of
  EksDrainInventoryComplete values -> values
  EksDrainInventoryPartial values _ -> values
  EksDrainInventoryUnobservable _ -> []

inventoryUnobservableFailures
  :: EksDrainInventoryResult value -> [ObservationFailure]
inventoryUnobservableFailures result = case result of
  EksDrainInventoryUnobservable failures -> NonEmpty.toList failures
  _ -> []

inventoryPartialFailures
  :: EksDrainInventoryResult value -> [ObservationFailure]
inventoryPartialFailures result = case result of
  EksDrainInventoryPartial _ failures -> NonEmpty.toList failures
  _ -> []

normalizeInventory
  :: (Ord value)
  => EksDrainInventoryResult value
  -> EksDrainInventoryResult value
normalizeInventory result = case result of
  EksDrainInventoryComplete values -> case duplicateValues values of
    [] -> EksDrainInventoryComplete (sort values)
    _ ->
      EksDrainInventoryPartial
        (sort values)
        (ObservationFailure "Kubernetes inventory contained duplicate identities" :| [])
  EksDrainInventoryPartial values failures ->
    EksDrainInventoryPartial (sort values) failures
  EksDrainInventoryUnobservable failures ->
    EksDrainInventoryUnobservable failures

inventoryReadBack
  :: Text
  -> EksDrainInventoryResult EksNamespacedName
  -> EksDrainResourceClassReadBack
inventoryReadBack absence result = case result of
  EksDrainInventoryComplete [] ->
    EksDrainResourceClassAbsent (AbsenceEvidence absence)
  EksDrainInventoryComplete (first : rest) ->
    EksDrainResourceClassPresent (first :| rest)
  EksDrainInventoryPartial values failures ->
    EksDrainResourceClassPartial values failures
  EksDrainInventoryUnobservable failures ->
    EksDrainResourceClassUnobservable failures

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ first
  | first : _second : _ <- group (sort values)
  ]

unobservableReadBack
  :: EksDrainAttemptEvidence
  -> NonEmpty ObservationFailure
  -> EksDrainTargetReadBackObservation
unobservableReadBack attempt =
  eksDrainTargetReadBackObservationFor attempt . EksDrainTargetReadBackUnobservable

clientAccessFailures
  :: EksDrainClientAccessFailure -> NonEmpty ObservationFailure
clientAccessFailures failure = case failure of
  EksDrainClientAccessRefused value -> value :| []
  EksDrainClientAccessUnobservable value -> value :| []

singletonFailure :: Text -> NonEmpty ObservationFailure
singletonFailure detail = ObservationFailure detail :| []

renderBounded :: (Show value) => value -> Text
renderBounded = Text.take 4096 . Text.pack . show

requireEqual
  :: (Eq value)
  => (value -> value -> err)
  -> value
  -> value
  -> Either err ()
requireEqual mismatch expected actual
  | expected == actual = Right ()
  | otherwise = Left (mismatch expected actual)

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft transform result = case result of
  Left err -> Left (transform err)
  Right value -> Right value

combineObservationFailures
  :: Text -> NonEmpty ObservationFailure -> ObservationFailure
combineObservationFailures label failures =
  ObservationFailure
    ( Text.take
        4096
        ( label
            <> ": "
            <> Text.intercalate
              "; "
              [detail | ObservationFailure detail <- NonEmpty.toList failures]
        )
    )

-- Production ephemeral client ------------------------------------------------

-- | Production commit-time boundary.  Provider issuance is keyed by the
-- current sealed commit execution identity.  The projection is then consumed
-- by the same private FIFO/kubeconfig machinery as mutation/read-back, and
-- cannot outlive the rank-2 continuation.
productionEksDrainCommitSelectionBoundary
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksDrainCommitSelectionBoundary IO
productionEksDrainCommitSelectionBoundary caller repoRoot kubectl environment workingDirectory =
  mkEksDrainCommitSelectionBoundary $ \execution request consume -> do
    acquired <-
      withEksClientAuthProjectionForTeardownExecution
        caller
        repoRoot
        execution
        (eksDrainProjectionAccountId request)
        (eksDrainProjectionRegion request)
        (eksDrainProjectionClusterName request)
        ( \projection ->
            withProductionEksDrainClientProjection
              kubectl
              environment
              workingDirectory
              projection
              ( \created ->
                  consume
                    ( fmap
                        (projection,)
                        created
                    )
              )
        )
    case acquired of
      Left err -> consume (Left (eksClientAuthAccessFailure err))
      Right result -> pure result

-- | Production effect/read-back boundary.  Provider issuance is keyed by the
-- current sealed node and fenced attempt, and the projection is consumed by
-- the hermetic client before the continuation returns.
productionEksDrainAttemptBoundary
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksDrainAttemptBoundary IO
productionEksDrainAttemptBoundary caller repoRoot kubectl environment workingDirectory =
  mkEksDrainAttemptBoundary $ \execution request consume -> do
    acquired <-
      withEksClientAuthProjectionForTeardownExecution
        caller
        repoRoot
        execution
        (eksDrainProjectionAccountId request)
        (eksDrainProjectionRegion request)
        (eksDrainProjectionClusterName request)
        ( \projection ->
            withProductionEksDrainClientProjection
              kubectl
              environment
              workingDirectory
              projection
              ( \created ->
                  consume
                    ( fmap
                        (projection,)
                        created
                    )
              )
        )
    case acquired of
      Left err -> consume (Left (eksClientAuthAccessFailure err))
      Right result -> pure result

-- | Production kubectl boundary with an explicit executable, environment,
-- and working directory.  Ambient Kubernetes and AWS credential variables
-- are removed; the sole target is the temporary kubeconfig derived from the
-- opaque session projection.
productionEksDrainClientBoundary
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksDrainClientBoundary IO
productionEksDrainClientBoundary kubectl environment workingDirectory =
  mkEksDrainClientBoundary $ \session consume ->
    withEksDrainClientProjection session $ \projection ->
      withProductionEksDrainClientProjection
        kubectl
        environment
        workingDirectory
        projection
        consume

-- | The drain's Kubernetes effects, over the shared ephemeral client.
--
-- Sprint 7.36 moved the private-kubeconfig, FIFO-token, and
-- ambient-credential-scrub machinery to
-- "Prodbox.Lifecycle.Teardown.EphemeralKubectl" when the DNS01 challenge family
-- became the second teardown path that reaches Kubernetes.  What stays here is
-- the drain's own vocabulary: which classes it observes, which it deletes, and
-- how an unusable client is classified.
withProductionEksDrainClientProjection
  :: FilePath
  -> [(String, String)]
  -> Maybe FilePath
  -> EksClientAuthProjection
  -> (Either EksDrainClientAccessFailure (EksDrainClientEffects IO) -> IO result)
  -> IO result
withProductionEksDrainClientProjection kubectl environment workingDirectory projection consume =
  withEphemeralKubectlForProjection
    kubectl
    environment
    workingDirectory
    projection
    ( \acquired ->
        consume $ case acquired of
          Left (EphemeralKubectlUnavailable failure) ->
            Left (EksDrainClientAccessUnobservable failure)
          Right client -> Right (productionClientEffects client)
    )

eksClientAuthAccessFailure
  :: EksClientAuthClientError -> EksDrainClientAccessFailure
eksClientAuthAccessFailure err = case err of
  EksClientAuthIdentityDispatchFailed _ -> unobservable
  EksClientAuthDispatchFailed _ -> unobservable
  EksClientAuthIdentityEvidenceInvalid -> refused
  EksClientAuthRequestInvalid -> refused
  EksClientAuthEvidenceInvalid -> refused
  EksClientAuthProjectionExpired -> refused
  EksClientAuthProjectionBindingMismatch -> refused
 where
  detail =
    ObservationFailure
      (Text.take 4096 ("EKS auth projection acquisition failed: " <> Text.pack (show err)))
  refused = EksDrainClientAccessRefused detail
  unobservable = EksDrainClientAccessUnobservable detail

productionClientEffects :: EphemeralKubectl -> EksDrainClientEffects IO
productionClientEffects client =
  EksDrainClientEffects
    { eksDrainClientObserveKubernetesUid = observeProductionUid client
    , eksDrainClientObserveLoadBalancerServices =
        observeNamespacedClass
          client
          [ "get"
          , "services"
          , "--all-namespaces"
          , "--field-selector=spec.type=LoadBalancer"
          , "-o"
          , namespacedJsonPath
          ]
    , eksDrainClientObserveIngresses =
        observeNamespacedClass
          client
          [ "get"
          , "ingresses"
          , "--all-namespaces"
          , "-o"
          , namespacedJsonPath
          ]
    , eksDrainClientObserveControllerOwners = observeProductionControllerOwners client
    , eksDrainClientObserveDeletePolicyPvcs = observeDeletePolicyPvcs client
    , eksDrainClientDeleteLoadBalancerServices =
        runProductionMutation
          client
          [ "delete"
          , "services"
          , "--all-namespaces"
          , "--field-selector=spec.type=LoadBalancer"
          , "--wait=false"
          , "--ignore-not-found=true"
          ]
    , eksDrainClientDeleteIngresses =
        runProductionMutation
          client
          [ "delete"
          , "ingresses"
          , "--all-namespaces"
          , "--all"
          , "--wait=false"
          , "--ignore-not-found=true"
          ]
    , eksDrainClientDeleteControllerOwners =
        deleteProductionControllerOwners client
    , eksDrainClientDeletePvc = \target ->
        runProductionMutation
          client
          [ "delete"
          , "persistentvolumeclaim"
          , Text.unpack (eksNamespacedNameName target)
          , "--namespace"
          , Text.unpack (eksNamespacedNameNamespace target)
          , "--wait=false"
          , "--ignore-not-found=true"
          ]
    , eksDrainClientObservePvc = observeProductionPvc client
    }

observeProductionControllerOwners
  :: EphemeralKubectl -> IO (EksDrainInventoryResult EksNamespacedName)
observeProductionControllerOwners client = do
  observed <-
    runProductionKubectl
      client
      [ "get"
      , "envoyproxy.gateway.envoyproxy.io"
      , "prodbox-public-edge"
      , "--namespace"
      , "envoy-gateway-system"
      , "--ignore-not-found=true"
      , "-o"
      , "jsonpath={.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.metadata.uid}{\"\\n\"}"
      ]
  pure $ case observed of
    Left failures
      | controllerOwnerApiAbsent failures -> EksDrainInventoryComplete []
      | otherwise -> EksDrainInventoryUnobservable failures
    Right output -> parseNamespacedRows (Text.pack output)

deleteProductionControllerOwners
  :: EphemeralKubectl -> IO EksDrainMutationResponse
deleteProductionControllerOwners client = do
  deleted <-
    runProductionKubectl
      client
      [ "delete"
      , "envoyproxy.gateway.envoyproxy.io"
      , "prodbox-public-edge"
      , "--namespace"
      , "envoy-gateway-system"
      , "--wait=false"
      , "--ignore-not-found=true"
      ]
  pure $ case deleted of
    Right _ -> EksDrainMutationResponseApplied
    Left failures
      | controllerOwnerApiAbsent failures -> EksDrainMutationResponseApplied
      | otherwise ->
          EksDrainMutationResponseLost
            (combineObservationFailures "delete exact controller owner" failures)

controllerOwnerApiAbsent :: NonEmpty ObservationFailure -> Bool
controllerOwnerApiAbsent =
  all
    ( \(ObservationFailure detail) ->
        any
          (`Text.isInfixOf` Text.toLower detail)
          [ "server doesn't have a resource type"
          , "the server could not find the requested resource"
          , "no matches for kind"
          ]
    )
    . NonEmpty.toList

observeProductionUid
  :: EphemeralKubectl -> IO EksDrainKubernetesUidObservation
observeProductionUid client = do
  observed <-
    runProductionKubectl
      client
      [ "get"
      , "namespace"
      , "kube-system"
      , "--request-timeout=5s"
      , "-o"
      , "jsonpath={.metadata.uid}"
      ]
  pure $ case observed of
    Left failures -> EksDrainKubernetesUidUnobservable failures
    Right output -> case filter (not . Text.null) (map Text.strip (Text.lines (Text.pack output))) of
      [uid] -> EksDrainKubernetesUidPresent uid
      _ ->
        EksDrainKubernetesUidUnobservable
          (ObservationFailure "Kubernetes UID response was empty or ambiguous" :| [])

observeNamespacedClass
  :: EphemeralKubectl
  -> [String]
  -> IO (EksDrainInventoryResult EksNamespacedName)
observeNamespacedClass client arguments = do
  observed <- runProductionKubectl client arguments
  pure $ case observed of
    Left failures -> EksDrainInventoryUnobservable failures
    Right output -> parseNamespacedRows (Text.pack output)

observeDeletePolicyPvcs
  :: EphemeralKubectl -> IO (EksDrainInventoryResult EksNamespacedName)
observeDeletePolicyPvcs client = do
  observed <-
    runProductionKubectl
      client
      [ "get"
      , "persistentvolumes"
      , "-o"
      , deletePolicyPvcJsonPath
      ]
  pure $ case observed of
    Left failures -> EksDrainInventoryUnobservable failures
    Right output -> parseDeletePolicyPvcRows (Text.pack output)

observeProductionPvc
  :: EphemeralKubectl
  -> EksNamespacedName
  -> IO EksDrainPvcObservation
observeProductionPvc client target = do
  observed <-
    runProductionKubectl
      client
      [ "get"
      , "persistentvolumeclaim"
      , Text.unpack (eksNamespacedNameName target)
      , "--namespace"
      , Text.unpack (eksNamespacedNameNamespace target)
      , "--ignore-not-found=true"
      , "-o"
      , "jsonpath={.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.metadata.uid}"
      ]
  pure $ case observed of
    Left failures -> EksDrainPvcObservationUnobservable failures
    Right raw
      | Text.null (Text.strip (Text.pack raw)) ->
          EksDrainPvcObservedAbsent
            (AbsenceEvidence "exact PVC name absent from successful Kubernetes API read-back")
      | otherwise -> case Text.splitOn "|" (Text.strip (Text.pack raw)) of
          [namespace, name, uid]
            | namespace == eksNamespacedNameNamespace target
                && name == eksNamespacedNameName target
                && not (Text.null uid) ->
                EksDrainPvcObservedPresent uid
          _ ->
            EksDrainPvcObservationUnobservable
              (ObservationFailure "exact PVC read-back was malformed or cross-target" :| [])

runProductionMutation
  :: EphemeralKubectl -> [String] -> IO EksDrainMutationResponse
runProductionMutation client arguments = do
  result <- runProductionKubectl client arguments
  pure $ case result of
    Right _ -> EksDrainMutationResponseApplied
    Left failures ->
      EksDrainMutationResponseLost
        (combineObservationFailures "kubectl mutation result unknown" failures)

runProductionKubectl
  :: EphemeralKubectl -> [String] -> IO (Either (NonEmpty ObservationFailure) String)
runProductionKubectl = runEphemeralKubectl

namespacedJsonPath :: String
namespacedJsonPath =
  "jsonpath={range .items[*]}{.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.metadata.uid}{\"\\n\"}{end}"

deletePolicyPvcJsonPath :: String
deletePolicyPvcJsonPath =
  "jsonpath={range .items[?(@.spec.persistentVolumeReclaimPolicy==\"Delete\")]}{.metadata.uid}{\"|\"}{.spec.claimRef.namespace}{\"|\"}{.spec.claimRef.name}{\"\\n\"}{end}"

parseNamespacedRows :: Text -> EksDrainInventoryResult EksNamespacedName
parseNamespacedRows raw = inventoryFromParsedRows (map parseRow (nonemptyLines raw))
 where
  parseRow row = case Text.splitOn "|" row of
    [namespace, name, uid]
      | not (Text.null uid) ->
          case mkEksNamespacedName namespace name of
            Left err -> Left (ObservationFailure ("invalid Kubernetes identity: " <> Text.pack (show err)))
            Right value -> Right (Just value)
    _ -> Left (ObservationFailure "malformed Kubernetes class inventory row")

parseDeletePolicyPvcRows :: Text -> EksDrainInventoryResult EksNamespacedName
parseDeletePolicyPvcRows raw = inventoryFromParsedRows (map parseRow (nonemptyLines raw))
 where
  parseRow row = case Text.splitOn "|" row of
    [pvUid, namespace, name]
      | Text.null pvUid -> Left (ObservationFailure "Delete-policy PV row omitted its UID")
      | Text.null namespace && Text.null name -> Right Nothing
      | Text.null namespace || Text.null name ->
          Left (ObservationFailure "Delete-policy PV row carried a partial claim reference")
      | otherwise ->
          case mkEksNamespacedName namespace name of
            Left err -> Left (ObservationFailure ("invalid Delete-policy PVC identity: " <> Text.pack (show err)))
            Right value -> Right (Just value)
    _ -> Left (ObservationFailure "malformed Delete-policy PV inventory row")

inventoryFromParsedRows
  :: [Either ObservationFailure (Maybe EksNamespacedName)]
  -> EksDrainInventoryResult EksNamespacedName
inventoryFromParsedRows rows =
  let values = sort [value | Right (Just value) <- rows]
      failures = [failure | Left failure <- rows]
      duplicateFailures =
        [ ObservationFailure "Kubernetes inventory contained duplicate identities"
        | not (null (duplicateValues values))
        ]
   in case failures <> duplicateFailures of
        [] -> EksDrainInventoryComplete values
        first : rest -> EksDrainInventoryPartial values (first :| rest)

nonemptyLines :: Text -> [Text]
nonemptyLines = filter (not . Text.null) . map Text.strip . Text.lines
