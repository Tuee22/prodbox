{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-owned interpreter for registered AWS stack checkpoints.  AWS
-- target truth is obtained through the existing Provider-dispatch boundary;
-- checkpoint custody remains entirely behind the local Lifecycle Authority.
-- Mutation attempts and their independent read-backs use the cleanup graph's
-- stable operation identities and never allocate a fresh retry key.
module Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
  ( AwsCheckpointAuthorities
  , mkAwsCheckpointAuthorities
  , AwsCheckpointInterpreter (..)
  , AwsCheckpointInterpreterError (..)
  , observeAwsStackCheckpointPair
  , reconcileAwsStackCheckpointRestore
  , readBackAwsStackCheckpointRecovery
  , retireAwsStackCheckpointReference
  , readBackAwsStackCheckpointRetirement
  , executeAwsCheckpointOperation
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityOperationClient
  ( AuthorityOperationClient
  )
import Prodbox.ControlPlane.PulumiCheckpointClient
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  , verifiedPulumiCheckpointBackupVersion
  , verifiedPulumiCheckpointCiphertextDigest
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointPrimaryVersion
  )
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId)
import Prodbox.Lifecycle.PulumiCheckpoint
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
  ( CapabilityCustodyError
  , capabilityDependants
  , dischargeBySucceededAbsenceReadBack
  , rotateOntoRetiredReference
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CustodialCapability (CheckpointCapability)
  , recordCapabilityDisposition
  )
import Prodbox.Lifecycle.Teardown.Checkpoint
import Prodbox.Lifecycle.Teardown.CheckpointAuthority
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry

-- | Closed client inventory.  Construction checks the registration retained
-- by each client, so selecting @aws-eks@ can never silently address the
-- subzone or test-stack checkpoint endpoint.
data AwsCheckpointAuthorities m = AwsCheckpointAuthorities
  { internalAwsEksCheckpointAuthority :: !(PulumiCheckpointAuthority m)
  , internalAwsEksSubzoneCheckpointAuthority :: !(PulumiCheckpointAuthority m)
  , internalAwsTestCheckpointAuthority :: !(PulumiCheckpointAuthority m)
  }

mkAwsCheckpointAuthorities
  :: PulumiCheckpointAuthority m
  -> PulumiCheckpointAuthority m
  -> PulumiCheckpointAuthority m
  -> Either AwsCheckpointInterpreterError (AwsCheckpointAuthorities m)
mkAwsCheckpointAuthorities eks subzone testStack = do
  validateClient AwsEksKey eks
  validateClient AwsEksSubzoneKey subzone
  validateClient AwsTestKey testStack
  Right
    AwsCheckpointAuthorities
      { internalAwsEksCheckpointAuthority = eks
      , internalAwsEksSubzoneCheckpointAuthority = subzone
      , internalAwsTestCheckpointAuthority = testStack
      }

data AwsCheckpointInterpreter m = AwsCheckpointInterpreter
  { awsCheckpointOperationAuthority :: !(AuthorityOperationClient m)
  , awsCheckpointAuthorities :: !(AwsCheckpointAuthorities m)
  , awsCheckpointRegisteredTargetInterpreter
      :: !(AwsRegisteredTargetInterpreter m)
  }

data AwsCheckpointInterpreterError
  = AwsCheckpointTargetUnregistered !RegisteredResourceKey
  | AwsCheckpointTargetNotStack !RegisteredResourceKey !ResourceKind
  | AwsCheckpointTargetBindingMismatch !RegisteredResourceKey
  | AwsCheckpointTargetCoordinateUnsupported
      !RegisteredResourceKey
      !ManagedResourceCoordinate
  | AwsCheckpointRegistrationMissing !RegisteredResourceKey !Text !Text
  | AwsCheckpointClientRegistrationMismatch
      !RegisteredResourceKey
      !Text
      !Text
  | AwsCheckpointPairInvalid !CheckpointPairError
  | AwsCheckpointTargetObservationFailed !AwsRegisteredTargetInterpreterError
  | AwsCheckpointTargetObservationIncomplete !ExactObservationResult
  | AwsCheckpointRestoreInvalid !CheckpointRestoreError
  | AwsCheckpointRetirementInvalid !CheckpointRetirementError
  | -- | Sprint 4.89: this run cannot show it still holds what makes the stack's
    -- resources destroyable, so it may not end custody of the checkpoint.
    AwsCheckpointCustodyUndischarged !CapabilityCustodyError
  | AwsCheckpointAuthorityInvalid !CheckpointAuthorityError
  | AwsCheckpointAuthorityOperationIdMissing
  | AwsCheckpointClientRefused !PulumiCheckpointClientError
  | AwsCheckpointClientUnavailable !PulumiCheckpointClientError
  | AwsCheckpointRestoreRefused !Text
  | AwsCheckpointRestorePending
  | AwsCheckpointRestoreReadBackUnavailable !Text
  | AwsCheckpointRetirementRefused !Text
  | AwsCheckpointRetirementPending
  | AwsCheckpointRetirementStillCurrent
      !(Maybe VerifiedPulumiCheckpointRef)
  | AwsCheckpointRetirementReadBackUnavailable !Text
  | AwsCheckpointAttemptBindingInvalid ![CleanupOperationId]
  deriving (Eq, Show)

data BoundCheckpointPair = BoundCheckpointPair
  { boundCheckpointPairObservation :: !CheckpointPairObservation
  , boundCheckpointPairReference :: !(Maybe VerifiedPulumiCheckpointRef)
  }

observeAwsStackCheckpointPair
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsCheckpointInterpreterError CheckpointPairObservation)
observeAwsStackCheckpointPair interpreter context target = do
  selected <- selectAuthority interpreter target
  case selected of
    Left err -> pure (Left err)
    Right (_, authority) ->
      fmap boundCheckpointPairObservation
        <$> observeBoundCheckpointPair
          authority
          (registeredTargetKey target)
          (teardownExecutionObservationScope context)

reconcileAwsStackCheckpointRestore
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsCheckpointInterpreterError CheckpointRestoreOutcome)
reconcileAwsStackCheckpointRestore interpreter context target = do
  selected <- selectAuthority interpreter target
  case selected of
    Left err -> pure (Left err)
    Right (_, authority) -> do
      exactResult <-
        observeAwsRegisteredTarget
          (awsCheckpointRegisteredTargetInterpreter interpreter)
          context
          target
      case exactResult of
        Left err -> pure (Left (AwsCheckpointTargetObservationFailed err))
        Right exact -> case exactObservationResult exact of
          ExactResourceAbsent _ ->
            pure
              ( mapRestore
                  ( mkCheckpointRestoreNotRequiredOutcome
                      operationId
                      key
                      scope
                      exact
                  )
              )
          ExactResourcePresent _ -> do
            observed <- observeBoundCheckpointPair authority key scope
            case observed of
              Left err -> pure (Left err)
              Right bound -> restoreFromBoundPair authority bound
          incomplete ->
            pure (Left (AwsCheckpointTargetObservationIncomplete incomplete))
 where
  operationId = teardownExecutionOperationId context
  key = registeredTargetKey target
  scope = teardownExecutionObservationScope context

  restoreFromBoundPair authority bound =
    case validateRecoverableBoundPair bound of
      Left err -> pure (Left err)
      Right () ->
        case mkCheckpointRestoreNoMutationOutcome
          operationId
          key
          scope
          (boundCheckpointPairObservation bound) of
          Right outcome -> pure (Right outcome)
          Left (CheckpointRestoreMutationRequired _) ->
            case boundCheckpointPairReference bound of
              Nothing ->
                pure
                  ( Left
                      ( AwsCheckpointRestoreInvalid
                          ( CheckpointRestoreRecoveryIncomplete
                              BackupCheckpointCopy
                              CheckpointAbsent
                          )
                      )
                  )
              Just reference -> restoreFromBackup authority bound reference
          Left err -> pure (Left (AwsCheckpointRestoreInvalid err))

  restoreFromBackup authority bound reference =
    case mkCheckpointRestoreRequest
      operationId
      key
      scope
      (backupCheckpointObservation (boundCheckpointPairObservation bound)) of
      Left err -> pure (Left (AwsCheckpointRestoreInvalid err))
      Right request -> do
        admitted <-
          admitCheckpointAuthorityOperation
            (awsCheckpointOperationAuthority interpreter)
            operationId
            key
            scope
            CheckpointPrimaryRestore
            (Just reference)
        case admitted of
          Left err ->
            pure
              ( Right
                  ( recordCheckpointRestoreAttempt
                      request
                      (authorityRestoreAttempt err)
                  )
              )
          Right operation -> case checkpointAuthorityOperationId operation of
            Nothing -> pure (Left AwsCheckpointAuthorityOperationIdMissing)
            Just authorityOperation -> do
              attempted <-
                restorePulumiCheckpointPrimary
                  authority
                  authorityOperation
                  (verifiedPulumiCheckpointDigest reference)
                  reference
              pure
                ( Right
                    ( recordCheckpointRestoreAttempt
                        request
                        (restoreAttempt attempted)
                    )
                )

readBackAwsStackCheckpointRecovery
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsCheckpointInterpreterError CheckpointRecoveryReadBackEvidence)
readBackAwsStackCheckpointRecovery interpreter context target =
  case onlyAttemptOperation context of
    Left err -> pure (Left err)
    Right attemptOperation -> do
      selected <- selectAuthority interpreter target
      case selected of
        Left err -> pure (Left err)
        Right (_, authority) -> do
          exactResult <-
            readBackAwsRegisteredTargetAbsent
              (awsCheckpointRegisteredTargetInterpreter interpreter)
              context
              target
          case exactResult of
            Left err -> pure (Left (AwsCheckpointTargetObservationFailed err))
            Right exact -> case exactObservationResult exact of
              ExactResourceAbsent _ ->
                pure
                  ( mapRestore
                      ( confirmCheckpointNoRestoreReadBack
                          attemptOperation
                          key
                          scope
                          exact
                      )
                  )
              ExactResourcePresent _ ->
                readBackRestore authority attemptOperation
              incomplete ->
                pure (Left (AwsCheckpointTargetObservationIncomplete incomplete))
 where
  key = registeredTargetKey target
  scope = teardownExecutionObservationScope context

  readBackRestore authority attemptOperation = do
    observed <-
      observeCheckpointAuthorityOperation
        (awsCheckpointOperationAuthority interpreter)
        attemptOperation
        key
        scope
        CheckpointPrimaryRestore
    case observed of
      Left err -> pure (Left (AwsCheckpointAuthorityInvalid err))
      Right recovered -> do
        readBack <-
          readBackPulumiCheckpointRestore
            authority
            (observedCheckpointAuthorityOperationId recovered)
        case readBack of
          Left err -> pure (Left (classifyReadBackClientError err))
          Right PulumiCheckpointRestorePending -> do
            current <- observeBoundCheckpointPair authority key scope
            pure $ do
              bound <- current
              _ <- bindRecovered recovered (boundCheckpointPairReference bound)
              Left AwsCheckpointRestorePending
          Right (PulumiCheckpointRestoreConfirmed predecessor current) ->
            pure $ do
              _ <- bindRecovered recovered (Just predecessor)
              pair <- exactPairForReference key scope (Just current)
              mapRestore
                ( confirmCheckpointRecoveryReadBack
                    attemptOperation
                    key
                    scope
                    pair
                )
          Right (PulumiCheckpointRestoreReadBackRefused detail) ->
            pure (Left (AwsCheckpointRestoreRefused detail))
          Right (PulumiCheckpointRestoreReadBackUnavailable detail) ->
            pure (Left (AwsCheckpointRestoreReadBackUnavailable detail))

retireAwsStackCheckpointReference
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsCheckpointInterpreterError CheckpointRetirementOutcome)
retireAwsStackCheckpointReference interpreter context target = do
  selected <- selectAuthority interpreter target
  case selected of
    Left err -> pure (Left err)
    Right (_, authority) -> do
      exactResult <-
        readBackAwsRegisteredTargetAbsent
          (awsCheckpointRegisteredTargetInterpreter interpreter)
          context
          target
      case exactResult of
        Left err -> pure (Left (AwsCheckpointTargetObservationFailed err))
        Right exact -> case exactObservationResult exact of
          ExactResourceAbsent _ -> do
            observed <- observeBoundCheckpointPair authority key scope
            case observed of
              Left err -> pure (Left err)
              Right bound -> retireBound authority exact bound
          incomplete ->
            pure (Left (AwsCheckpointTargetObservationIncomplete incomplete))
 where
  operationId = teardownExecutionOperationId context
  key = registeredTargetKey target
  scope = teardownExecutionObservationScope context

  -- Sprint 4.89: the absences this run already read back, kept rather than
  -- discarded.  The retirement node waits on a successful
  -- @ReadBackRegisteredTargetAbsent@ for every resource the checkpoint reaches,
  -- so the run holds a provider-observed absence for each one; before this
  -- sprint the interpreter re-observed only its own stack and ended custody of
  -- a capability reaching families nobody had asked about.
  succeededAbsenceReadBacks =
    [ registeredTargetKey readBackTarget
    | predecessor <- teardownExecutionSuccessfulPredecessors context
    , ReadBackRegisteredTargetAbsent readBackTarget <-
        [teardownSucceededPredecessorOperation predecessor]
    ]

  capability = CheckpointCapability key

  retireBound authority exact bound =
    case dischargeBySucceededAbsenceReadBack
      capability
      (capabilityDependants capability)
      succeededAbsenceReadBacks of
      Left err -> pure (Left (AwsCheckpointCustodyUndischarged err))
      Right disposition -> retireDisposed authority exact bound disposition

  retireDisposed authority exact bound disposition =
    case authorizeCheckpointRetirement
      operationId
      RetireActiveCheckpointReference
      scope
      disposition
      exact
      (boundCheckpointPairObservation bound) of
      Left err -> pure (Left (AwsCheckpointRetirementInvalid err))
      Right authorization -> do
        admitted <-
          admitCheckpointAuthorityOperation
            (awsCheckpointOperationAuthority interpreter)
            operationId
            key
            scope
            CheckpointReferenceRetirement
            (boundCheckpointPairReference bound)
        case admitted of
          Left err ->
            pure
              ( Right
                  ( recordCheckpointRetirementAttempt
                      authorization
                      (authorityRetirementAttempt err)
                  )
              )
          Right operation -> case checkpointAuthorityOperationId operation of
            Nothing -> pure (Left AwsCheckpointAuthorityOperationIdMissing)
            Just authorityOperation -> do
              attempted <-
                attemptPulumiCheckpointRetirement
                  authority
                  authorityOperation
                  ( verifiedPulumiCheckpointDigest
                      <$> boundCheckpointPairReference bound
                  )
                  (recordCapabilityDisposition disposition)
                  (boundCheckpointPairReference bound)
              pure
                ( Right
                    ( recordCheckpointRetirementAttempt
                        authorization
                        (retirementAttempt attempted)
                    )
                )

readBackAwsStackCheckpointRetirement
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsCheckpointInterpreterError CheckpointRetirementEvidence)
readBackAwsStackCheckpointRetirement interpreter context target =
  case onlyAttemptOperation context of
    Left err -> pure (Left err)
    Right attemptOperation -> do
      selected <- selectAuthority interpreter target
      case selected of
        Left err -> pure (Left err)
        Right (_, authority) -> do
          exactResult <-
            readBackAwsRegisteredTargetAbsent
              (awsCheckpointRegisteredTargetInterpreter interpreter)
              context
              target
          case exactResult of
            Left err -> pure (Left (AwsCheckpointTargetObservationFailed err))
            Right exact -> case exactObservationResult exact of
              ExactResourceAbsent _ ->
                readBackRetirement authority attemptOperation exact
              incomplete ->
                pure (Left (AwsCheckpointTargetObservationIncomplete incomplete))
 where
  key = registeredTargetKey target
  scope = teardownExecutionObservationScope context
  capability = CheckpointCapability key

  readBackRetirement authority attemptOperation exact = do
    observed <-
      observeCheckpointAuthorityOperation
        (awsCheckpointOperationAuthority interpreter)
        attemptOperation
        key
        scope
        CheckpointReferenceRetirement
    case observed of
      Left err -> pure (Left (AwsCheckpointAuthorityInvalid err))
      Right recovered -> do
        readBack <-
          readBackPulumiCheckpointRetirement
            authority
            (observedCheckpointAuthorityOperationId recovered)
        case readBack of
          Left err -> pure (Left (classifyReadBackClientError err))
          Right PulumiCheckpointRetirementPending -> do
            current <- observeBoundCheckpointPair authority key scope
            pure $ do
              bound <- current
              _ <- bindRecovered recovered (boundCheckpointPairReference bound)
              Left AwsCheckpointRetirementPending
          Right (PulumiCheckpointReferenceRetired retiredReference) ->
            pure
              ( confirmRetiredReference
                  attemptOperation
                  exact
                  recovered
                  retiredReference
              )
          Right (PulumiCheckpointReferenceStillCurrent currentReference) ->
            pure $ do
              _ <- bindRecovered recovered currentReference
              Left (AwsCheckpointRetirementStillCurrent currentReference)
          Right (PulumiCheckpointRetirementReadBackRefused detail) ->
            pure (Left (AwsCheckpointRetirementRefused detail))
          Right (PulumiCheckpointRetirementReadBackUnavailable detail) ->
            pure (Left (AwsCheckpointRetirementReadBackUnavailable detail))

  confirmRetiredReference attemptOperation exact recovered retiredReference = do
    _ <- bindRecovered recovered retiredReference
    pair <- exactPairForReference key scope retiredReference
    -- Sprint 4.89: the read-back's own discharge.  It has just observed the
    -- Lifecycle Authority holding the reference in its retired set, which is
    -- the evidence that the capability moved rather than ceased — so it
    -- reconstructs the authorization against a rotation onto that retained
    -- reference rather than re-deriving the retirement's absence discharge from
    -- an ordering it deliberately does not wait on.
    custody <-
      either
        (Left . AwsCheckpointCustodyUndischarged)
        Right
        (rotateOntoRetiredReference capability)
    authorization <-
      mapRetirement
        ( authorizeCheckpointRetirement
            attemptOperation
            RetireActiveCheckpointReference
            scope
            custody
            exact
            pair
        )
    let primary = primaryCheckpointObservation pair
        backup = backupCheckpointObservation pair
        disposition = case retiredReference of
          Nothing -> CheckpointReferenceAlreadyRetired
          Just reference -> CheckpointReferenceRetired (logicalVersion reference)
    mapRetirement
      ( confirmCheckpointRetirement
          authorization
          CheckpointRetirementObservation
            { checkpointRetirementObservationOperationId = attemptOperation
            , checkpointRetirementObservationStackKey = key
            , checkpointRetirementObservationScope = scope
            , checkpointRetirementObservationPrimaryProvenance =
                checkpointObservationProvenance primary
            , checkpointRetirementObservationBackupProvenance =
                checkpointObservationProvenance backup
            , checkpointRetirementObservationReferenceDisposition = disposition
            }
      )

-- | Composable GADT interpreter.  Non-checkpoint operations are returned to
-- the caller unchanged rather than being hidden behind an effect callback.
executeAwsCheckpointOperation
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> TeardownExecutionContext surface
  -> TeardownOperation surface
  -> m
       ( Either
           AwsCheckpointInterpreterError
           (Maybe (TeardownNodeResult surface))
       )
executeAwsCheckpointOperation interpreter context operation = case operation of
  ObserveStackCheckpointPair target ->
    fmap (Just . TeardownCheckpointPairObservation)
      <$> observeAwsStackCheckpointPair interpreter context target
  ReconcileStackCheckpointRestore target ->
    fmap (Just . TeardownCheckpointRestore)
      <$> reconcileAwsStackCheckpointRestore interpreter context target
  ReadBackStackCheckpointRecovery target ->
    fmap (Just . TeardownCheckpointRecoveryReadBack)
      <$> readBackAwsStackCheckpointRecovery interpreter context target
  RetireStackCheckpointPair target ->
    fmap (Just . TeardownCheckpointRetirement)
      <$> retireAwsStackCheckpointReference interpreter context target
  ReadBackStackCheckpointRetirement target ->
    fmap (Just . TeardownCheckpointRetirementReadBack)
      <$> readBackAwsStackCheckpointRetirement interpreter context target
  _ -> pure (Right Nothing)

selectAuthority
  :: (Monad m)
  => AwsCheckpointInterpreter m
  -> RegisteredTargetBinding
  -> m
       ( Either
           AwsCheckpointInterpreterError
           (RegisteredPulumiCheckpoint, PulumiCheckpointAuthority m)
       )
selectAuthority interpreter target =
  pure $ do
    registered <- validateTarget target
    let key = registeredTargetKey target
        authorities = awsCheckpointAuthorities interpreter
        authority = case key of
          AwsEksKey -> Right (internalAwsEksCheckpointAuthority authorities)
          AwsEksSubzoneKey ->
            Right (internalAwsEksSubzoneCheckpointAuthority authorities)
          AwsTestKey -> Right (internalAwsTestCheckpointAuthority authorities)
          _ -> Left (AwsCheckpointTargetNotStack key (registeredTargetKind target))
    selected <- authority
    validateClient key selected
    Right (registered, selected)

validateTarget
  :: RegisteredTargetBinding
  -> Either AwsCheckpointInterpreterError RegisteredPulumiCheckpoint
validateTarget target = do
  let key = registeredTargetKey target
  identity <-
    maybe
      (Left (AwsCheckpointTargetUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  if registeredIdentityKind identity == Stack
    && registeredTargetKind target == Stack
    && registeredIdentityCoordinateDigest identity
      == registeredTargetCoordinateDigest target
    then Right ()
    else Left (AwsCheckpointTargetBindingMismatch key)
  case registeredIdentityCoordinate identity of
    AwsPulumiStackCoordinate project stack ->
      either
        (const (Left (AwsCheckpointRegistrationMissing key project stack)))
        Right
        (registeredPulumiCheckpointFor project stack)
    coordinate -> Left (AwsCheckpointTargetCoordinateUnsupported key coordinate)

validateClient
  :: RegisteredResourceKey
  -> PulumiCheckpointAuthority m
  -> Either AwsCheckpointInterpreterError ()
validateClient key authority = do
  expected <- checkpointRegistrationForKey key
  let expectedName = registeredPulumiCheckpointName expected
      actualName =
        registeredPulumiCheckpointName
          (pulumiCheckpointAuthorityRegistration authority)
  if expectedName == actualName
    then Right ()
    else
      Left
        ( AwsCheckpointClientRegistrationMismatch
            key
            expectedName
            actualName
        )

checkpointRegistrationForKey
  :: RegisteredResourceKey
  -> Either AwsCheckpointInterpreterError RegisteredPulumiCheckpoint
checkpointRegistrationForKey key = do
  identity <-
    maybe
      (Left (AwsCheckpointTargetUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  case registeredIdentityCoordinate identity of
    AwsPulumiStackCoordinate project stack ->
      either
        (const (Left (AwsCheckpointRegistrationMissing key project stack)))
        Right
        (registeredPulumiCheckpointFor project stack)
    coordinate -> Left (AwsCheckpointTargetCoordinateUnsupported key coordinate)

observeBoundCheckpointPair
  :: (Monad m)
  => PulumiCheckpointAuthority m
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either AwsCheckpointInterpreterError BoundCheckpointPair)
observeBoundCheckpointPair authority key scope = do
  observed <- observePulumiCheckpointPair authority
  pure $ case observed of
    Left err -> pairFromUnknown key scope (boundedError err)
    Right wire -> pairFromWire key scope wire

pairFromWire
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> PulumiCheckpointPairObservation
  -> Either AwsCheckpointInterpreterError BoundCheckpointPair
pairFromWire key scope wire = case wire of
  PulumiCheckpointPairNoCurrentReference ->
    BoundCheckpointPair <$> exactPairForReference key scope Nothing <*> pure Nothing
  PulumiCheckpointPairCurrent reference primary backup -> do
    pair <-
      mkPair
        key
        scope
        ( copyResult
            PrimaryCheckpointCopy
            (verifiedPulumiCheckpointPrimaryVersion reference)
            reference
            primary
        )
        ( copyResult
            BackupCheckpointCopy
            (verifiedPulumiCheckpointBackupVersion reference)
            reference
            backup
        )
    Right
      BoundCheckpointPair
        { boundCheckpointPairObservation = pair
        , boundCheckpointPairReference = Just reference
        }
  PulumiCheckpointPairUnobservable detail ->
    pairFromUnknown key scope detail

pairFromUnknown
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Text
  -> Either AwsCheckpointInterpreterError BoundCheckpointPair
pairFromUnknown key scope detail = do
  let unavailable = CheckpointUnobservable (ObservationFailure detail :| [])
  pair <- mkPair key scope unavailable unavailable
  Right
    BoundCheckpointPair
      { boundCheckpointPairObservation = pair
      , boundCheckpointPairReference = Nothing
      }

copyResult
  :: CheckpointCopy
  -> Text
  -> VerifiedPulumiCheckpointRef
  -> PulumiCheckpointCopyObservation
  -> CheckpointResult
copyResult copy expectedVersion reference observation = case observation of
  PulumiCheckpointCopyCurrent actualVersion
    | actualVersion == expectedVersion -> CheckpointPresent (logicalVersion reference)
    | otherwise ->
        partial
          ( copyName copy
              <> " checkpoint version mismatch: expected "
              <> expectedVersion
              <> ", observed "
              <> actualVersion
          )
  PulumiCheckpointCopyMissing -> CheckpointAbsent
  PulumiCheckpointCopyCorrupt detail ->
    partial (copyName copy <> " checkpoint copy is corrupt: " <> detail)
  PulumiCheckpointCopyUnobservable detail ->
    CheckpointUnobservable (ObservationFailure (copyName copy <> ": " <> detail) :| [])
 where
  partial detail = CheckpointPartial (ObservationFailure detail :| [])

-- An active aggregate reference makes the backup copy mandatory.  An exact
-- missing primary is the sole recoverable incomplete state; every other
-- missing, partial, or unknown copy is refused before an effect can be
-- admitted.  Conversely, no active reference is valid only when both copies
-- are exactly absent.
validateRecoverableBoundPair
  :: BoundCheckpointPair
  -> Either AwsCheckpointInterpreterError ()
validateRecoverableBoundPair bound =
  case boundCheckpointPairReference bound of
    Nothing -> do
      requireExactResult PrimaryCheckpointCopy CheckpointAbsent primaryResult
      requireExactResult BackupCheckpointCopy CheckpointAbsent backupResult
    Just _ -> do
      requirePrimaryRecoverable primaryResult
      case backupResult of
        CheckpointPresent _ -> Right ()
        other -> recoveryIncomplete BackupCheckpointCopy other
 where
  pair = boundCheckpointPairObservation bound
  primaryResult =
    checkpointObservationResult (primaryCheckpointObservation pair)
  backupResult =
    checkpointObservationResult (backupCheckpointObservation pair)

  requirePrimaryRecoverable result = case result of
    CheckpointPresent _ -> Right ()
    CheckpointAbsent -> Right ()
    other -> recoveryIncomplete PrimaryCheckpointCopy other

  requireExactResult copy expected actual
    | actual == expected = Right ()
    | otherwise = recoveryIncomplete copy actual

  recoveryIncomplete copy result =
    Left
      ( AwsCheckpointRestoreInvalid
          (CheckpointRestoreRecoveryIncomplete copy result)
      )

exactPairForReference
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Maybe VerifiedPulumiCheckpointRef
  -> Either AwsCheckpointInterpreterError CheckpointPairObservation
exactPairForReference key scope reference = case reference of
  Nothing -> mkPair key scope CheckpointAbsent CheckpointAbsent
  Just exact ->
    mkPair
      key
      scope
      (CheckpointPresent (logicalVersion exact))
      (CheckpointPresent (logicalVersion exact))

mkPair
  :: RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointResult
  -> CheckpointResult
  -> Either AwsCheckpointInterpreterError CheckpointPairObservation
mkPair key scope primaryResult backupResult =
  either
    (Left . AwsCheckpointPairInvalid)
    Right
    ( mkCheckpointPairObservation
        key
        scope
        CheckpointObservation
          { checkpointObservationStackKey = key
          , checkpointObservationCopy = PrimaryCheckpointCopy
          , checkpointObservationProvenance = checkpointProvenance key PrimaryCheckpointCopy
          , checkpointObservationEvidenceScope = scope
          , checkpointObservationResult = primaryResult
          }
        CheckpointObservation
          { checkpointObservationStackKey = key
          , checkpointObservationCopy = BackupCheckpointCopy
          , checkpointObservationProvenance = checkpointProvenance key BackupCheckpointCopy
          , checkpointObservationEvidenceScope = scope
          , checkpointObservationResult = backupResult
          }
    )

checkpointProvenance
  :: RegisteredResourceKey -> CheckpointCopy -> CheckpointProvenance
checkpointProvenance key copy =
  CheckpointProvenance
    ( "lifecycle-authority/checkpoint/"
        <> registeredResourceKeyText key
        <> "/"
        <> copyName copy
    )

copyName :: CheckpointCopy -> Text
copyName copy = case copy of
  PrimaryCheckpointCopy -> "primary"
  BackupCheckpointCopy -> "backup"

logicalVersion :: VerifiedPulumiCheckpointRef -> CheckpointVersion
logicalVersion reference =
  CheckpointVersion
    ("ciphertext-sha256:" <> verifiedPulumiCheckpointCiphertextDigest reference)

onlyAttemptOperation
  :: TeardownExecutionContext surface
  -> Either AwsCheckpointInterpreterError CleanupOperationId
onlyAttemptOperation context = case teardownExecutionAttemptOperationIds context of
  [operation] -> Right operation
  operations -> Left (AwsCheckpointAttemptBindingInvalid operations)

bindRecovered
  :: ObservedCheckpointAuthorityOperation
  -> Maybe VerifiedPulumiCheckpointRef
  -> Either AwsCheckpointInterpreterError CheckpointAuthorityOperation
bindRecovered recovered =
  either
    (Left . AwsCheckpointAuthorityInvalid)
    Right
    . bindObservedCheckpointAuthorityOperation recovered

authorityRestoreAttempt :: CheckpointAuthorityError -> CheckpointRestoreAttempt
authorityRestoreAttempt err = case err of
  CheckpointAuthorityAdmissionUnavailable _ -> CheckpointRestoreResponseLost
  _ -> CheckpointRestoreRefused (ObservationFailure (boundedError err))

authorityRetirementAttempt
  :: CheckpointAuthorityError -> CheckpointRetirementAttempt
authorityRetirementAttempt err = case err of
  CheckpointAuthorityAdmissionUnavailable _ -> CheckpointRetirementResponseLost
  _ -> CheckpointRetirementRefused (ObservationFailure (boundedError err))

restoreAttempt
  :: Either PulumiCheckpointClientError PulumiCheckpointRestoreResult
  -> CheckpointRestoreAttempt
restoreAttempt attempted = case attempted of
  Left PulumiCheckpointRemoteRefused {} ->
    CheckpointRestoreRefused (ObservationFailure (boundedError attempted))
  Left _ -> CheckpointRestoreResponseLost
  Right PulumiCheckpointRestoreApplied {} -> CheckpointRestoreApplied
  Right PulumiCheckpointRestoreAlreadyApplied {} -> CheckpointRestoreApplied
  Right (PulumiCheckpointRestoreRefused detail) ->
    CheckpointRestoreRefused (ObservationFailure detail)
  Right PulumiCheckpointRestoreUnavailable {} -> CheckpointRestoreResponseLost

retirementAttempt
  :: Either PulumiCheckpointClientError PulumiCheckpointRetirementAttemptResult
  -> CheckpointRetirementAttempt
retirementAttempt attempted = case attempted of
  Left PulumiCheckpointRemoteRefused {} ->
    CheckpointRetirementRefused (ObservationFailure (boundedError attempted))
  Left _ -> CheckpointRetirementResponseLost
  Right PulumiCheckpointRetirementApplied -> CheckpointRetirementApplied
  Right PulumiCheckpointRetirementAlreadyApplied -> CheckpointRetirementApplied
  Right (PulumiCheckpointRetirementAttemptRefused detail) ->
    CheckpointRetirementRefused (ObservationFailure detail)
  Right PulumiCheckpointRetirementAttemptUnavailable {} ->
    CheckpointRetirementResponseLost

classifyReadBackClientError
  :: PulumiCheckpointClientError -> AwsCheckpointInterpreterError
classifyReadBackClientError err = case err of
  PulumiCheckpointRemoteRefused {} -> AwsCheckpointClientRefused err
  _ -> AwsCheckpointClientUnavailable err

mapRestore
  :: Either CheckpointRestoreError value
  -> Either AwsCheckpointInterpreterError value
mapRestore = either (Left . AwsCheckpointRestoreInvalid) Right

mapRetirement
  :: Either CheckpointRetirementError value
  -> Either AwsCheckpointInterpreterError value
mapRetirement = either (Left . AwsCheckpointRetirementInvalid) Right

boundedError :: (Show value) => value -> Text
boundedError = Text.take 512 . Text.pack . show
