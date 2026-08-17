{-# LANGUAGE OverloadedStrings #-}

-- | Opaque result boundary for one registered-target reconcile operation.
-- Generic mutation success is deliberately insufficient: a result can be
-- constructed only from exact absence or one of the closed AWS mutation
-- authorizations, and every construction retains its target, scope, and
-- stable cleanup-operation binding.
module Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetMutationAttempt (..)
  , RegisteredTargetReconcileDisposition (..)
  , RegisteredTargetReconcileResult
  , registeredTargetReconcileKey
  , registeredTargetReconcileCoordinateDigest
  , registeredTargetReconcileScope
  , registeredTargetReconcileOperationId
  , registeredTargetReconcileDisposition
  , mkAlreadyAbsentRegisteredTargetReconcile
  , mkAwsStackRegisteredTargetReconcile
  , mkAwsEksRegisteredTargetReconcile
  , mkAwsEbsRegisteredTargetReconcile
  , mkRefusedRegisteredTargetReconcile
  , RegisteredTargetReconcileError (..)
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId)
import Prodbox.Lifecycle.Teardown.AwsEbsAdapter
  ( ExactAwsEbsReapAuthorization
  , awsEbsReapScope
  )
import Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
  ( AwsEksDestroyAuthorization
  , awsEksDestroyAuthorizationCoordinateDigest
  , awsEksDestroyAuthorizationKey
  , awsEksDestroyAuthorizationOperationId
  , awsEksDestroyAuthorizationScope
  )
import Prodbox.Lifecycle.Teardown.AwsStackAdapter
  ( AwsStackDestroyAuthorization
  , awsStackDestroyAuthorizationKey
  , awsStackDestroyAuthorizationScope
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , registeredTargetCoordinateDigest
  , registeredTargetKey
  , registeredTargetKind
  , registeredTargetLifecycleClass
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  , registeredIdentityLifecycleClass
  )

-- | The result of invoking one already-authorized provider mutation.  A lost
-- response is distinct from both refusal and confirmed application so the
-- durable runner can retain an unconfirmed effect for stable-key retry.
data RegisteredTargetMutationAttempt
  = RegisteredTargetMutationApplied
  | RegisteredTargetMutationResponseLost !Text
  | RegisteredTargetMutationRefused !Text
  deriving (Eq, Show)

-- | Auditable origin and outcome retained inside the opaque result.  Exporting
-- this observation type does not grant construction authority for the result.
data RegisteredTargetReconcileDisposition
  = RegisteredTargetConfirmedAlreadyAbsent !AbsenceEvidence
  | RegisteredTargetAwsStackMutation !RegisteredTargetMutationAttempt
  | RegisteredTargetAwsEksMutation !RegisteredTargetMutationAttempt
  | RegisteredTargetAwsEbsMutation !RegisteredTargetMutationAttempt
  | RegisteredTargetReconcileRefused !Text
  deriving (Eq, Show)

data RegisteredTargetReconcileResult = RegisteredTargetReconcileResult
  { internalRegisteredTargetReconcileKey :: !RegisteredResourceKey
  , internalRegisteredTargetReconcileCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalRegisteredTargetReconcileScope :: !ObservationEvidenceScope
  , internalRegisteredTargetReconcileOperationId :: !CleanupOperationId
  , internalRegisteredTargetReconcileDisposition
      :: !RegisteredTargetReconcileDisposition
  }
  deriving (Eq, Show)

registeredTargetReconcileKey
  :: RegisteredTargetReconcileResult -> RegisteredResourceKey
registeredTargetReconcileKey = internalRegisteredTargetReconcileKey

registeredTargetReconcileCoordinateDigest
  :: RegisteredTargetReconcileResult -> ManagedResourceCoordinateDigest
registeredTargetReconcileCoordinateDigest =
  internalRegisteredTargetReconcileCoordinateDigest

registeredTargetReconcileScope
  :: RegisteredTargetReconcileResult -> ObservationEvidenceScope
registeredTargetReconcileScope = internalRegisteredTargetReconcileScope

registeredTargetReconcileOperationId
  :: RegisteredTargetReconcileResult -> CleanupOperationId
registeredTargetReconcileOperationId = internalRegisteredTargetReconcileOperationId

registeredTargetReconcileDisposition
  :: RegisteredTargetReconcileResult -> RegisteredTargetReconcileDisposition
registeredTargetReconcileDisposition = internalRegisteredTargetReconcileDisposition

data RegisteredTargetReconcileError
  = RegisteredTargetNotInRegistry !RegisteredResourceKey
  | RegisteredTargetRegistryCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | RegisteredTargetRegistryKindMismatch
      !RegisteredResourceKey
      !ResourceKind
      !ResourceKind
  | RegisteredTargetRegistryLifecycleClassMismatch
      !RegisteredResourceKey
      !(Maybe LifecycleClass)
      !(Maybe LifecycleClass)
  | RegisteredTargetObservationKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | RegisteredTargetObservationCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | RegisteredTargetObservationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | RegisteredTargetObservationBindingInvalid !CompleteObservationSetError
  | RegisteredTargetObservationNotAbsent !ExactObservationResult
  | RegisteredTargetStackKindRequired !RegisteredResourceKey !ResourceKind
  | RegisteredTargetStackAuthorizationKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | RegisteredTargetStackAuthorizationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | RegisteredTargetEksKeyRequired !RegisteredResourceKey
  | RegisteredTargetEksKindRequired !ResourceKind
  | RegisteredTargetEksAuthorizationKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | RegisteredTargetEksAuthorizationCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | RegisteredTargetEksAuthorizationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | RegisteredTargetEksAuthorizationOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | RegisteredTargetEbsPerRunKeyRequired !RegisteredResourceKey
  | RegisteredTargetEbsKindRequired !ResourceKind
  | RegisteredTargetEbsAuthorizationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  deriving (Eq, Show)

-- | Exact absence is already a successful desired-absence reconcile.  The
-- complete-observation constructor is reused here so a forged authority,
-- stale registry revision, or disallowed surface cannot mint this result.
mkAlreadyAbsentRegisteredTargetReconcile
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either RegisteredTargetReconcileError RegisteredTargetReconcileResult
mkAlreadyAbsentRegisteredTargetReconcile operationId target scope observation = do
  validateStaticTarget target
  if exactObservationResourceKey observation == registeredTargetKey target
    then Right ()
    else
      Left
        ( RegisteredTargetObservationKeyMismatch
            (registeredTargetKey target)
            (exactObservationResourceKey observation)
        )
  if exactObservationCoordinateDigest observation
    == registeredTargetCoordinateDigest target
    then Right ()
    else
      Left
        ( RegisteredTargetObservationCoordinateMismatch
            (registeredTargetCoordinateDigest target)
            (exactObservationCoordinateDigest observation)
        )
  if exactObservationEvidenceScope observation == scope
    then Right ()
    else
      Left
        ( RegisteredTargetObservationScopeMismatch
            scope
            (exactObservationEvidenceScope observation)
        )
  _ <-
    either
      (Left . RegisteredTargetObservationBindingInvalid)
      Right
      (mkCompleteObservationSet scope [registeredTargetKey target] [observation])
  case exactObservationResult observation of
    ExactResourceAbsent evidence ->
      Right
        ( mkResult
            operationId
            target
            scope
            (RegisteredTargetConfirmedAlreadyAbsent evidence)
        )
    other -> Left (RegisteredTargetObservationNotAbsent other)

-- | Stack mutation results require the opaque authority produced by the
-- exact stack decision adapter.  In particular, backup-restore-required and
-- refused decisions cannot produce this authorization and cannot enter here.
mkAwsStackRegisteredTargetReconcile
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> AwsStackDestroyAuthorization
  -> RegisteredTargetMutationAttempt
  -> Either RegisteredTargetReconcileError RegisteredTargetReconcileResult
mkAwsStackRegisteredTargetReconcile operationId target scope authorization attempt = do
  validateStaticTarget target
  if registeredTargetKind target == Stack
    then Right ()
    else
      Left
        ( RegisteredTargetStackKindRequired
            (registeredTargetKey target)
            (registeredTargetKind target)
        )
  if awsStackDestroyAuthorizationKey authorization == registeredTargetKey target
    then Right ()
    else
      Left
        ( RegisteredTargetStackAuthorizationKeyMismatch
            (registeredTargetKey target)
            (awsStackDestroyAuthorizationKey authorization)
        )
  if awsStackDestroyAuthorizationScope authorization == scope
    then Right ()
    else
      Left
        ( RegisteredTargetStackAuthorizationScopeMismatch
            scope
            (awsStackDestroyAuthorizationScope authorization)
        )
  Right
    ( mkResult
        operationId
        target
        scope
        (RegisteredTargetAwsStackMutation attempt)
    )

-- | EKS is intentionally excluded from the generic stack authorization path.
-- Its mutation result can enter the durable reconcile fold only through the
-- opaque authorization that binds the exact drain read-back, current cluster
-- identity, and this reconcile operation.
mkAwsEksRegisteredTargetReconcile
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> AwsEksDestroyAuthorization
  -> RegisteredTargetMutationAttempt
  -> Either RegisteredTargetReconcileError RegisteredTargetReconcileResult
mkAwsEksRegisteredTargetReconcile operationId target scope authorization attempt = do
  validateStaticTarget target
  if registeredTargetKey target == AwsEksKey
    then Right ()
    else Left (RegisteredTargetEksKeyRequired (registeredTargetKey target))
  if registeredTargetKind target == Stack
    then Right ()
    else Left (RegisteredTargetEksKindRequired (registeredTargetKind target))
  if awsEksDestroyAuthorizationKey authorization == registeredTargetKey target
    then Right ()
    else
      Left
        ( RegisteredTargetEksAuthorizationKeyMismatch
            (registeredTargetKey target)
            (awsEksDestroyAuthorizationKey authorization)
        )
  if awsEksDestroyAuthorizationCoordinateDigest authorization
    == registeredTargetCoordinateDigest target
    then Right ()
    else
      Left
        ( RegisteredTargetEksAuthorizationCoordinateMismatch
            (registeredTargetCoordinateDigest target)
            (awsEksDestroyAuthorizationCoordinateDigest authorization)
        )
  if awsEksDestroyAuthorizationScope authorization == scope
    then Right ()
    else
      Left
        ( RegisteredTargetEksAuthorizationScopeMismatch
            scope
            (awsEksDestroyAuthorizationScope authorization)
        )
  if awsEksDestroyAuthorizationOperationId authorization == operationId
    then Right ()
    else
      Left
        ( RegisteredTargetEksAuthorizationOperationMismatch
            operationId
            (awsEksDestroyAuthorizationOperationId authorization)
        )
  Right
    ( mkResult
        operationId
        target
        scope
        (RegisteredTargetAwsEksMutation attempt)
    )

-- | The EBS path is deliberately closed to the registered per-run family.
-- Presence of the separately registered retained family cannot construct the
-- adapter authorization accepted here.
mkAwsEbsRegisteredTargetReconcile
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> ExactAwsEbsReapAuthorization
  -> RegisteredTargetMutationAttempt
  -> Either RegisteredTargetReconcileError RegisteredTargetReconcileResult
mkAwsEbsRegisteredTargetReconcile operationId target scope authorization attempt = do
  validateStaticTarget target
  if registeredTargetKey target == AwsEbsPerRunTestKey
    then Right ()
    else Left (RegisteredTargetEbsPerRunKeyRequired (registeredTargetKey target))
  if registeredTargetKind target == VolumeFamily
    then Right ()
    else Left (RegisteredTargetEbsKindRequired (registeredTargetKind target))
  if awsEbsReapScope authorization == scope
    then Right ()
    else
      Left
        ( RegisteredTargetEbsAuthorizationScopeMismatch
            scope
            (awsEbsReapScope authorization)
        )
  Right
    ( mkResult
        operationId
        target
        scope
        (RegisteredTargetAwsEbsMutation attempt)
    )

-- | Preserve an exact interpreter refusal without opening the reconcile node
-- to the generic mutation result.  This constructor validates the immutable
-- registry binding but grants no mutation or absence authority; Execution
-- always lowers the resulting disposition to a failed cleanup node.
mkRefusedRegisteredTargetReconcile
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> Text
  -> Either RegisteredTargetReconcileError RegisteredTargetReconcileResult
mkRefusedRegisteredTargetReconcile operationId target scope detail = do
  validateStaticTarget target
  Right
    ( mkResult
        operationId
        target
        scope
        (RegisteredTargetReconcileRefused detail)
    )

mkResult
  :: CleanupOperationId
  -> RegisteredTargetBinding
  -> ObservationEvidenceScope
  -> RegisteredTargetReconcileDisposition
  -> RegisteredTargetReconcileResult
mkResult operationId target scope disposition =
  RegisteredTargetReconcileResult
    { internalRegisteredTargetReconcileKey = registeredTargetKey target
    , internalRegisteredTargetReconcileCoordinateDigest =
        registeredTargetCoordinateDigest target
    , internalRegisteredTargetReconcileScope = scope
    , internalRegisteredTargetReconcileOperationId = operationId
    , internalRegisteredTargetReconcileDisposition = disposition
    }

validateStaticTarget
  :: RegisteredTargetBinding -> Either RegisteredTargetReconcileError ()
validateStaticTarget target = do
  identity <-
    maybe
      (Left (RegisteredTargetNotInRegistry key))
      Right
      (lookupRegisteredIdentity key)
  if registeredTargetCoordinateDigest target
    == registeredIdentityCoordinateDigest identity
    then Right ()
    else
      Left
        ( RegisteredTargetRegistryCoordinateMismatch
            key
            (registeredIdentityCoordinateDigest identity)
            (registeredTargetCoordinateDigest target)
        )
  if registeredTargetKind target == registeredIdentityKind identity
    then Right ()
    else
      Left
        ( RegisteredTargetRegistryKindMismatch
            key
            (registeredIdentityKind identity)
            (registeredTargetKind target)
        )
  if registeredTargetLifecycleClass target
    == registeredIdentityLifecycleClass identity
    then Right ()
    else
      Left
        ( RegisteredTargetRegistryLifecycleClassMismatch
            key
            (registeredIdentityLifecycleClass identity)
            (registeredTargetLifecycleClass target)
        )
 where
  key = registeredTargetKey target
