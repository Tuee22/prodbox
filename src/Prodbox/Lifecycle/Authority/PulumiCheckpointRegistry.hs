{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The bounded Pulumi-checkpoint projection embedded in the Lifecycle
-- Authority aggregate.
--
-- Bytes are immutable and live outside the aggregate.  A slot advances only
-- to a reference whose exact primary and independent-backup copies were both
-- read back.  Mutations are additionally bound to an authority-issued opaque
-- operation reference, the registered stack, the operation kind, and the
-- checkpoint digest observed when the permit was committed.
module Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  , VerifiedPulumiCheckpointRefError (..)
  , mkVerifiedPulumiCheckpointRef
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointCiphertextDigest
  , verifiedPulumiCheckpointPrimaryVersion
  , verifiedPulumiCheckpointBackupVersion
  , CheckpointOperationKind (..)
  , AuthorityPulumiCheckpoints
  , AuthorityPulumiCheckpointInvariantError (..)
  , initialAuthorityPulumiCheckpoints
  , validateAuthorityPulumiCheckpoints
  , observeAuthorityPulumiCheckpoint
  , observeRetiredAuthorityPulumiCheckpoints
  , CheckpointRestoreReadBack (..)
  , observeCheckpointRestoreReadBack
  , CheckpointRetirementReadBack (..)
  , observeCheckpointRetirementReadBack
  , CheckpointPermitDecision (..)
  , registerCheckpointOperationPermit
  , CheckpointMutationDecision (..)
  , CheckpointMutationAuthorization (..)
  , authorizeCheckpointPublication
  , authorizeCheckpointRestore
  , authorizeCheckpointRetirement
  , applyCheckpointPublication
  , applyCheckpointRestore
  , applyCheckpointRetirement
  , compactTerminalCheckpointOperation
  , authorityPulumiCheckpointOperationCount
  , authorityPulumiCheckpointOperationCapacity
  )
where

import Codec.Serialise (Serialise)
import Data.Char (isControl, isSpace)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.PulumiCheckpoint
  ( PulumiCheckpointDigest
  , PulumiCheckpointOperationRef
  , RegisteredPulumiCheckpoint
  , pulumiCheckpointOperationRefText
  , registeredPulumiCheckpointName
  , registeredPulumiCheckpoints
  )

data VerifiedPulumiCheckpointRef = VerifiedPulumiCheckpointRef
  { internalVerifiedCheckpointDigest :: !PulumiCheckpointDigest
  , internalVerifiedCheckpointCiphertextDigest :: !Text
  , internalVerifiedCheckpointPrimaryVersion :: !Text
  , internalVerifiedCheckpointBackupVersion :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data VerifiedPulumiCheckpointRefError
  = VerifiedCheckpointCiphertextDigestInvalid !Text
  | VerifiedCheckpointPrimaryVersionInvalid !Text
  | VerifiedCheckpointBackupDigestMismatch !Text !Text
  | VerifiedCheckpointBackupVersionInvalid !Text
  deriving stock (Eq, Show)

mkVerifiedPulumiCheckpointRef
  :: PulumiCheckpointDigest
  -> Text
  -> Text
  -> Text
  -> Text
  -> Either VerifiedPulumiCheckpointRefError VerifiedPulumiCheckpointRef
mkVerifiedPulumiCheckpointRef
  digest
  primaryCiphertextDigest
  primaryVersion
  backupCiphertextDigest
  backupVersion = do
    ciphertextDigest <- validateCiphertextDigest primaryCiphertextDigest
    primary <-
      validateVersion
        VerifiedCheckpointPrimaryVersionInvalid
        primaryVersion
    if backupCiphertextDigest == ciphertextDigest
      then pure ()
      else
        Left
          ( VerifiedCheckpointBackupDigestMismatch
              ciphertextDigest
              backupCiphertextDigest
          )
    backup <-
      validateVersion
        VerifiedCheckpointBackupVersionInvalid
        backupVersion
    pure
      VerifiedPulumiCheckpointRef
        { internalVerifiedCheckpointDigest = digest
        , internalVerifiedCheckpointCiphertextDigest = ciphertextDigest
        , internalVerifiedCheckpointPrimaryVersion = primary
        , internalVerifiedCheckpointBackupVersion = backup
        }

verifiedPulumiCheckpointDigest
  :: VerifiedPulumiCheckpointRef -> PulumiCheckpointDigest
verifiedPulumiCheckpointDigest = internalVerifiedCheckpointDigest

-- | SHA-256 of the one sealed envelope copied byte-for-byte to both stores.
-- This intentionally differs from 'verifiedPulumiCheckpointDigest', which is
-- the digest of the canonical plaintext checkpoint.
verifiedPulumiCheckpointCiphertextDigest
  :: VerifiedPulumiCheckpointRef -> Text
verifiedPulumiCheckpointCiphertextDigest =
  internalVerifiedCheckpointCiphertextDigest

verifiedPulumiCheckpointPrimaryVersion
  :: VerifiedPulumiCheckpointRef -> Text
verifiedPulumiCheckpointPrimaryVersion =
  internalVerifiedCheckpointPrimaryVersion

verifiedPulumiCheckpointBackupVersion
  :: VerifiedPulumiCheckpointRef -> Text
verifiedPulumiCheckpointBackupVersion =
  internalVerifiedCheckpointBackupVersion

data CheckpointOperationKind
  = PublishCheckpoint
  | RestoreCheckpoint
  | RetireCheckpoint
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CheckpointOperationPhase
  = CheckpointOperationPending
  | CheckpointPublicationApplied !VerifiedPulumiCheckpointRef
  | CheckpointRestoreApplied
      !VerifiedPulumiCheckpointRef
      !VerifiedPulumiCheckpointRef
  | CheckpointRetirementApplied !(Maybe VerifiedPulumiCheckpointRef)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CheckpointOperationPermit = CheckpointOperationPermit
  { checkpointPermitReference :: !PulumiCheckpointOperationRef
  , checkpointPermitRegistration :: !Text
  , checkpointPermitKind :: !CheckpointOperationKind
  , checkpointPermitExpectedDigest :: !(Maybe PulumiCheckpointDigest)
  , checkpointPermitPhase :: !CheckpointOperationPhase
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityPulumiCheckpoints = AuthorityPulumiCheckpoints
  { authorityCheckpointSlots
      :: !(Map Text (Maybe VerifiedPulumiCheckpointRef))
  , authorityCheckpointRetired
      :: !(Map Text [VerifiedPulumiCheckpointRef])
  , authorityCheckpointOperations
      :: !(Map Text CheckpointOperationPermit)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityPulumiCheckpointOperationCapacity :: Natural
authorityPulumiCheckpointOperationCapacity = 256

authorityPulumiCheckpointRetiredCapacity :: Natural
authorityPulumiCheckpointRetiredCapacity = 64

authorityPulumiCheckpointOperationCount :: AuthorityPulumiCheckpoints -> Natural
authorityPulumiCheckpointOperationCount =
  fromIntegral . Map.size . authorityCheckpointOperations

data AuthorityPulumiCheckpointInvariantError
  = AuthorityCheckpointSlotInventoryMismatch
  | AuthorityCheckpointRetiredInventoryMismatch
  | AuthorityCheckpointRetiredOverCapacity !Text !Natural !Natural
  | AuthorityCheckpointOperationOverCapacity !Natural !Natural
  | AuthorityCheckpointOperationKeyMismatch !Text !Text
  | AuthorityCheckpointOperationRegistrationUnknown !Text
  | AuthorityCheckpointOperationPhaseMismatch !Text
  deriving stock (Eq, Show)

initialAuthorityPulumiCheckpoints :: AuthorityPulumiCheckpoints
initialAuthorityPulumiCheckpoints =
  AuthorityPulumiCheckpoints
    { authorityCheckpointSlots =
        Map.fromList
          [ (registeredPulumiCheckpointName checkpoint, Nothing)
          | checkpoint <- registeredPulumiCheckpoints
          ]
    , authorityCheckpointRetired =
        Map.fromList
          [ (registeredPulumiCheckpointName checkpoint, [])
          | checkpoint <- registeredPulumiCheckpoints
          ]
    , authorityCheckpointOperations = Map.empty
    }

validateAuthorityPulumiCheckpoints
  :: AuthorityPulumiCheckpoints
  -> Either AuthorityPulumiCheckpointInvariantError ()
validateAuthorityPulumiCheckpoints registry
  | Map.keysSet slots /= registeredNames =
      Left AuthorityCheckpointSlotInventoryMismatch
  | Map.keysSet retired /= registeredNames =
      Left AuthorityCheckpointRetiredInventoryMismatch
  | operationCount > authorityPulumiCheckpointOperationCapacity =
      Left
        ( AuthorityCheckpointOperationOverCapacity
            operationCount
            authorityPulumiCheckpointOperationCapacity
        )
  | otherwise = do
      traverse_ validateRetired (Map.toList retired)
      traverse_ validateOperation (Map.toList operations)
 where
  slots = authorityCheckpointSlots registry
  retired = authorityCheckpointRetired registry
  operations = authorityCheckpointOperations registry
  operationCount = fromIntegral (Map.size operations)
  registeredNames =
    Set.fromList
      (map registeredPulumiCheckpointName registeredPulumiCheckpoints)
  validateRetired (name, references)
    | fromIntegral (length references) > authorityPulumiCheckpointRetiredCapacity =
        Left
          ( AuthorityCheckpointRetiredOverCapacity
              name
              (fromIntegral (length references))
              authorityPulumiCheckpointRetiredCapacity
          )
    | otherwise = Right ()
  validateOperation (key, permit)
    | key /= pulumiCheckpointOperationRefText (checkpointPermitReference permit) =
        Left
          ( AuthorityCheckpointOperationKeyMismatch
              key
              (pulumiCheckpointOperationRefText (checkpointPermitReference permit))
          )
    | not (Set.member (checkpointPermitRegistration permit) registeredNames) =
        Left
          ( AuthorityCheckpointOperationRegistrationUnknown
              (checkpointPermitRegistration permit)
          )
    | otherwise = validatePhase key (checkpointPermitKind permit) (checkpointPermitPhase permit)
  validatePhase _ _ CheckpointOperationPending = Right ()
  validatePhase _ PublishCheckpoint (CheckpointPublicationApplied _) = Right ()
  validatePhase _ RestoreCheckpoint (CheckpointRestoreApplied _ _) = Right ()
  validatePhase _ RetireCheckpoint (CheckpointRetirementApplied _) = Right ()
  validatePhase key _ _ = Left (AuthorityCheckpointOperationPhaseMismatch key)

observeAuthorityPulumiCheckpoint
  :: RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Maybe VerifiedPulumiCheckpointRef
observeAuthorityPulumiCheckpoint registered registry =
  Map.lookup
    (registeredPulumiCheckpointName registered)
    (authorityCheckpointSlots registry)
    >>= id

observeRetiredAuthorityPulumiCheckpoints
  :: RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> [VerifiedPulumiCheckpointRef]
observeRetiredAuthorityPulumiCheckpoints registered registry =
  Map.findWithDefault
    []
    (registeredPulumiCheckpointName registered)
    (authorityCheckpointRetired registry)

data CheckpointRestoreReadBack
  = CheckpointRestoreOperationPending
  | CheckpointRestoreOperationApplied
      !VerifiedPulumiCheckpointRef
      !VerifiedPulumiCheckpointRef
  deriving stock (Eq, Show)

observeCheckpointRestoreReadBack
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Maybe CheckpointRestoreReadBack
observeCheckpointRestoreReadBack operation registered registry = do
  permit <- lookupPermit operation registry
  if checkpointPermitRegistration permit
    /= registeredPulumiCheckpointName registered
    || checkpointPermitKind permit /= RestoreCheckpoint
    then Nothing
    else case checkpointPermitPhase permit of
      CheckpointOperationPending -> Just CheckpointRestoreOperationPending
      CheckpointRestoreApplied predecessor current ->
        Just (CheckpointRestoreOperationApplied predecessor current)
      _ -> Nothing

data CheckpointRetirementReadBack
  = CheckpointRetirementOperationPending
  | CheckpointRetirementOperationApplied
      !(Maybe VerifiedPulumiCheckpointRef)
  deriving stock (Eq, Show)

observeCheckpointRetirementReadBack
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Maybe CheckpointRetirementReadBack
observeCheckpointRetirementReadBack operation registered registry = do
  permit <- lookupPermit operation registry
  if checkpointPermitRegistration permit
    /= registeredPulumiCheckpointName registered
    || checkpointPermitKind permit /= RetireCheckpoint
    then Nothing
    else case checkpointPermitPhase permit of
      CheckpointOperationPending -> Just CheckpointRetirementOperationPending
      CheckpointRetirementApplied reference ->
        Just (CheckpointRetirementOperationApplied reference)
      _ -> Nothing

data CheckpointPermitDecision
  = CheckpointPermitRegistered
  | CheckpointPermitAlreadyRegistered
  | CheckpointPermitRefusedSubmissionUnknown
  | CheckpointPermitRefusedSubmissionBinding
  | CheckpointPermitRefusedSubmissionNotInFlight
  | CheckpointPermitRefusedOperationReuse
  | CheckpointPermitRefusedCapacity
  | CheckpointPermitRefusedCurrentDigest
      !(Maybe VerifiedPulumiCheckpointRef)
  deriving stock (Eq, Show)

registerCheckpointOperationPermit
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> CheckpointOperationKind
  -> Maybe PulumiCheckpointDigest
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (CheckpointPermitDecision, AuthorityPulumiCheckpoints)
registerCheckpointOperationPermit operation registered kind expected registry = do
  validateAuthorityPulumiCheckpoints registry
  let key = pulumiCheckpointOperationRefText operation
      name = registeredPulumiCheckpointName registered
      permit =
        CheckpointOperationPermit
          { checkpointPermitReference = operation
          , checkpointPermitRegistration = name
          , checkpointPermitKind = kind
          , checkpointPermitExpectedDigest = expected
          , checkpointPermitPhase = CheckpointOperationPending
          }
  case Map.lookup key (authorityCheckpointOperations registry) of
    Just existing
      | checkpointPermitBindingMatches existing permit ->
          pure (CheckpointPermitAlreadyRegistered, registry)
      | otherwise -> pure (CheckpointPermitRefusedOperationReuse, registry)
    Nothing
      | fromIntegral (Map.size (authorityCheckpointOperations registry))
          >= authorityPulumiCheckpointOperationCapacity ->
          pure (CheckpointPermitRefusedCapacity, registry)
      | currentDigest registered registry /= expected ->
          pure
            ( CheckpointPermitRefusedCurrentDigest
                (observeAuthorityPulumiCheckpoint registered registry)
            , registry
            )
      | otherwise ->
          pure
            ( CheckpointPermitRegistered
            , registry
                { authorityCheckpointOperations =
                    Map.insert
                      key
                      permit
                      (authorityCheckpointOperations registry)
                }
            )

checkpointPermitBindingMatches
  :: CheckpointOperationPermit
  -> CheckpointOperationPermit
  -> Bool
checkpointPermitBindingMatches existing candidate =
  checkpointPermitReference existing == checkpointPermitReference candidate
    && checkpointPermitRegistration existing
      == checkpointPermitRegistration candidate
    && checkpointPermitKind existing == checkpointPermitKind candidate
    && checkpointPermitExpectedDigest existing
      == checkpointPermitExpectedDigest candidate

data CheckpointMutationDecision
  = CheckpointMutationApplied
  | CheckpointMutationAlreadyApplied
  | CheckpointMutationRefusedUnknownOperation
  | CheckpointMutationRefusedBinding
  | CheckpointMutationRefusedKind
  | CheckpointMutationRefusedDigestConflict
      !(Maybe VerifiedPulumiCheckpointRef)
  | CheckpointMutationRefusedReplayConflict
  | CheckpointMutationRefusedRestoreReferenceMismatch
      !(Maybe VerifiedPulumiCheckpointRef)
  | CheckpointMutationRefusedRetiredCapacity
  deriving stock (Eq, Show)

data CheckpointMutationAuthorization
  = CheckpointMutationAuthorized
  | CheckpointMutationAlreadyAppliedWith
      !(Maybe VerifiedPulumiCheckpointRef)
  | CheckpointMutationAuthorizationRefused
      !CheckpointMutationDecision
  deriving stock (Eq, Show)

authorizeCheckpointPublication
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> PulumiCheckpointDigest
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       CheckpointMutationAuthorization
authorizeCheckpointPublication operation registered candidateDigest registry = do
  validateAuthorityPulumiCheckpoints registry
  pure $ case lookupPermit operation registry of
    Nothing -> refused CheckpointMutationRefusedUnknownOperation
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          refused CheckpointMutationRefusedBinding
      | checkpointPermitKind permit /= PublishCheckpoint ->
          refused CheckpointMutationRefusedKind
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointPublicationApplied existing
            | verifiedPulumiCheckpointDigest existing == candidateDigest ->
                CheckpointMutationAlreadyAppliedWith (Just existing)
            | otherwise ->
                refused CheckpointMutationRefusedReplayConflict
          CheckpointOperationPending
            | currentDigest registered registry
                == checkpointPermitExpectedDigest permit ->
                CheckpointMutationAuthorized
            | otherwise ->
                refused
                  ( CheckpointMutationRefusedDigestConflict
                      (observeAuthorityPulumiCheckpoint registered registry)
                  )
          CheckpointRestoreApplied _ _ ->
            refused CheckpointMutationRefusedKind
          CheckpointRetirementApplied _ ->
            refused CheckpointMutationRefusedKind
 where
  refused = CheckpointMutationAuthorizationRefused

authorizeCheckpointRestore
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       CheckpointMutationAuthorization
authorizeCheckpointRestore operation registered predecessor candidate registry = do
  validateAuthorityPulumiCheckpoints registry
  pure $ case lookupPermit operation registry of
    Nothing -> refused CheckpointMutationRefusedUnknownOperation
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          refused CheckpointMutationRefusedBinding
      | checkpointPermitKind permit /= RestoreCheckpoint ->
          refused CheckpointMutationRefusedKind
      | not (validRestoreTransition predecessor candidate) ->
          refused
            (CheckpointMutationRefusedRestoreReferenceMismatch (Just candidate))
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointRestoreApplied appliedPredecessor appliedCurrent
            | appliedPredecessor == predecessor && appliedCurrent == candidate ->
                CheckpointMutationAlreadyAppliedWith (Just appliedCurrent)
            | otherwise -> refused CheckpointMutationRefusedReplayConflict
          CheckpointOperationPending
            | observeAuthorityPulumiCheckpoint registered registry
                /= Just predecessor ->
                refused
                  ( CheckpointMutationRefusedRestoreReferenceMismatch
                      (observeAuthorityPulumiCheckpoint registered registry)
                  )
            | predecessor /= candidate
                && not (retiredCapacityAvailable registered predecessor registry) ->
                refused CheckpointMutationRefusedRetiredCapacity
            | otherwise -> CheckpointMutationAuthorized
          _ -> refused CheckpointMutationRefusedKind
 where
  refused = CheckpointMutationAuthorizationRefused

authorizeCheckpointRetirement
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       CheckpointMutationAuthorization
authorizeCheckpointRetirement operation registered registry = do
  validateAuthorityPulumiCheckpoints registry
  pure $ case lookupPermit operation registry of
    Nothing -> refused CheckpointMutationRefusedUnknownOperation
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          refused CheckpointMutationRefusedBinding
      | checkpointPermitKind permit /= RetireCheckpoint ->
          refused CheckpointMutationRefusedKind
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointRetirementApplied _ ->
            CheckpointMutationAlreadyAppliedWith Nothing
          CheckpointOperationPending
            | currentDigest registered registry
                == checkpointPermitExpectedDigest permit ->
                CheckpointMutationAuthorized
            | otherwise ->
                refused
                  ( CheckpointMutationRefusedDigestConflict
                      (observeAuthorityPulumiCheckpoint registered registry)
                  )
          CheckpointPublicationApplied _ ->
            refused CheckpointMutationRefusedKind
          CheckpointRestoreApplied _ _ ->
            refused CheckpointMutationRefusedKind
 where
  refused = CheckpointMutationAuthorizationRefused

applyCheckpointPublication
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (CheckpointMutationDecision, AuthorityPulumiCheckpoints)
applyCheckpointPublication operation registered reference registry = do
  validateAuthorityPulumiCheckpoints registry
  case lookupPermit operation registry of
    Nothing -> pure (CheckpointMutationRefusedUnknownOperation, registry)
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          pure (CheckpointMutationRefusedBinding, registry)
      | checkpointPermitKind permit /= PublishCheckpoint ->
          pure (CheckpointMutationRefusedKind, registry)
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointPublicationApplied existing
            | existing == reference ->
                pure (CheckpointMutationAlreadyApplied, registry)
            | otherwise ->
                pure (CheckpointMutationRefusedReplayConflict, registry)
          CheckpointOperationPending
            | currentDigest registered registry
                /= checkpointPermitExpectedDigest permit ->
                pure
                  ( CheckpointMutationRefusedDigestConflict
                      (observeAuthorityPulumiCheckpoint registered registry)
                  , registry
                  )
            | otherwise ->
                pure
                  ( CheckpointMutationApplied
                  , updatePublished operation registered reference permit registry
                  )
          CheckpointRestoreApplied _ _ ->
            pure (CheckpointMutationRefusedKind, registry)
          CheckpointRetirementApplied _ ->
            pure (CheckpointMutationRefusedKind, registry)

applyCheckpointRestore
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (CheckpointMutationDecision, AuthorityPulumiCheckpoints)
applyCheckpointRestore operation registered predecessor candidate registry = do
  validateAuthorityPulumiCheckpoints registry
  case lookupPermit operation registry of
    Nothing -> pure (CheckpointMutationRefusedUnknownOperation, registry)
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          pure (CheckpointMutationRefusedBinding, registry)
      | checkpointPermitKind permit /= RestoreCheckpoint ->
          pure (CheckpointMutationRefusedKind, registry)
      | not (validRestoreTransition predecessor candidate) ->
          pure
            ( CheckpointMutationRefusedRestoreReferenceMismatch
                (observeAuthorityPulumiCheckpoint registered registry)
            , registry
            )
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointRestoreApplied appliedPredecessor appliedCurrent
            | appliedPredecessor == predecessor && appliedCurrent == candidate ->
                pure (CheckpointMutationAlreadyApplied, registry)
            | otherwise ->
                pure (CheckpointMutationRefusedReplayConflict, registry)
          CheckpointOperationPending
            | observeAuthorityPulumiCheckpoint registered registry
                /= Just predecessor ->
                pure
                  ( CheckpointMutationRefusedRestoreReferenceMismatch
                      (observeAuthorityPulumiCheckpoint registered registry)
                  , registry
                  )
            | predecessor /= candidate
                && not (retiredCapacityAvailable registered predecessor registry) ->
                pure (CheckpointMutationRefusedRetiredCapacity, registry)
            | otherwise ->
                pure
                  ( CheckpointMutationApplied
                  , updateRestored
                      operation
                      registered
                      predecessor
                      candidate
                      permit
                      registry
                  )
          _ -> pure (CheckpointMutationRefusedKind, registry)

applyCheckpointRetirement
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (CheckpointMutationDecision, AuthorityPulumiCheckpoints)
applyCheckpointRetirement operation registered registry = do
  validateAuthorityPulumiCheckpoints registry
  case lookupPermit operation registry of
    Nothing -> pure (CheckpointMutationRefusedUnknownOperation, registry)
    Just permit
      | checkpointPermitRegistration permit
          /= registeredPulumiCheckpointName registered ->
          pure (CheckpointMutationRefusedBinding, registry)
      | checkpointPermitKind permit /= RetireCheckpoint ->
          pure (CheckpointMutationRefusedKind, registry)
      | otherwise -> case checkpointPermitPhase permit of
          CheckpointRetirementApplied _ ->
            pure (CheckpointMutationAlreadyApplied, registry)
          CheckpointOperationPending
            | currentDigest registered registry
                /= checkpointPermitExpectedDigest permit ->
                pure
                  ( CheckpointMutationRefusedDigestConflict
                      (observeAuthorityPulumiCheckpoint registered registry)
                  , registry
                  )
            | not
                ( maybe
                    True
                    (\reference -> retiredCapacityAvailable registered reference registry)
                    (observeAuthorityPulumiCheckpoint registered registry)
                ) ->
                pure (CheckpointMutationRefusedRetiredCapacity, registry)
            | otherwise ->
                pure
                  ( CheckpointMutationApplied
                  , updateRetired operation registered permit registry
                  )
          CheckpointPublicationApplied _ ->
            pure (CheckpointMutationRefusedKind, registry)
          CheckpointRestoreApplied _ _ ->
            pure (CheckpointMutationRefusedKind, registry)

-- | Remove one terminal operation tombstone after the owning submission has
-- been selected for compaction.  Publication can be forgotten once its
-- current aggregate reference is durable.  Restore and retirement phases
-- retain the exact predecessor/reference needed by a cleanup read-back after
-- response loss, so they deliberately apply bounded backpressure until a
-- future explicit read-back acknowledgement/GC protocol exists.
compactTerminalCheckpointOperation
  :: PulumiCheckpointOperationRef
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (Bool, AuthorityPulumiCheckpoints)
compactTerminalCheckpointOperation operation registry = do
  validateAuthorityPulumiCheckpoints registry
  let key = pulumiCheckpointOperationRefText operation
  case Map.lookup key (authorityCheckpointOperations registry) of
    Nothing -> pure (True, registry)
    Just permit -> case checkpointPermitPhase permit of
      CheckpointOperationPending -> pure (False, registry)
      CheckpointPublicationApplied _ -> removed key
      CheckpointRestoreApplied _ _ -> pure (False, registry)
      CheckpointRetirementApplied _ -> pure (False, registry)
 where
  removed key = do
    let next =
          registry
            { authorityCheckpointOperations =
                Map.delete key (authorityCheckpointOperations registry)
            }
    validateAuthorityPulumiCheckpoints next
    pure (True, next)

lookupPermit
  :: PulumiCheckpointOperationRef
  -> AuthorityPulumiCheckpoints
  -> Maybe CheckpointOperationPermit
lookupPermit operation =
  Map.lookup (pulumiCheckpointOperationRefText operation)
    . authorityCheckpointOperations

currentDigest
  :: RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Maybe PulumiCheckpointDigest
currentDigest registered =
  fmap verifiedPulumiCheckpointDigest
    . observeAuthorityPulumiCheckpoint registered

updatePublished
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> CheckpointOperationPermit
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
updatePublished operation registered reference permit registry =
  registry
    { authorityCheckpointSlots =
        Map.insert
          (registeredPulumiCheckpointName registered)
          (Just reference)
          (authorityCheckpointSlots registry)
    , authorityCheckpointOperations =
        Map.insert
          (pulumiCheckpointOperationRefText operation)
          permit {checkpointPermitPhase = CheckpointPublicationApplied reference}
          (authorityCheckpointOperations registry)
    }

updateRestored
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> VerifiedPulumiCheckpointRef
  -> CheckpointOperationPermit
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
updateRestored operation registered predecessor current permit registry =
  restoredBase
    { authorityCheckpointSlots =
        Map.insert
          (registeredPulumiCheckpointName registered)
          (Just current)
          (authorityCheckpointSlots registry)
    , authorityCheckpointOperations =
        Map.insert
          (pulumiCheckpointOperationRefText operation)
          permit
            { checkpointPermitPhase =
                CheckpointRestoreApplied predecessor current
            }
          (authorityCheckpointOperations registry)
    }
 where
  restoredBase
    | predecessor == current = registry
    | otherwise = recordRetiredReference registered predecessor registry

updateRetired
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> CheckpointOperationPermit
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
updateRetired operation registered permit registry =
  (recordMaybeRetiredReference registered current registry)
    { authorityCheckpointSlots =
        Map.insert
          (registeredPulumiCheckpointName registered)
          Nothing
          (authorityCheckpointSlots registry)
    , authorityCheckpointOperations =
        Map.insert
          (pulumiCheckpointOperationRefText operation)
          permit {checkpointPermitPhase = CheckpointRetirementApplied current}
          (authorityCheckpointOperations registry)
    }
 where
  current = observeAuthorityPulumiCheckpoint registered registry

validRestoreTransition
  :: VerifiedPulumiCheckpointRef
  -> VerifiedPulumiCheckpointRef
  -> Bool
validRestoreTransition predecessor candidate =
  verifiedPulumiCheckpointDigest predecessor
    == verifiedPulumiCheckpointDigest candidate
    && verifiedPulumiCheckpointCiphertextDigest predecessor
      == verifiedPulumiCheckpointCiphertextDigest candidate
    && verifiedPulumiCheckpointBackupVersion predecessor
      == verifiedPulumiCheckpointBackupVersion candidate

retiredCapacityAvailable
  :: RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> Bool
retiredCapacityAvailable registered reference registry =
  reference `elem` retired
    || fromIntegral (length retired) < authorityPulumiCheckpointRetiredCapacity
 where
  retired = observeRetiredAuthorityPulumiCheckpoints registered registry

recordMaybeRetiredReference
  :: RegisteredPulumiCheckpoint
  -> Maybe VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
recordMaybeRetiredReference _ Nothing registry = registry
recordMaybeRetiredReference registered (Just reference) registry =
  recordRetiredReference registered reference registry

recordRetiredReference
  :: RegisteredPulumiCheckpoint
  -> VerifiedPulumiCheckpointRef
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
recordRetiredReference registered reference registry
  | reference `elem` retired = registry
  | otherwise =
      registry
        { authorityCheckpointRetired =
            Map.insert name (retired <> [reference]) (authorityCheckpointRetired registry)
        }
 where
  name = registeredPulumiCheckpointName registered
  retired = observeRetiredAuthorityPulumiCheckpoints registered registry

validateVersion
  :: (Text -> VerifiedPulumiCheckpointRefError)
  -> Text
  -> Either VerifiedPulumiCheckpointRefError Text
validateVersion invalid raw
  | Text.null raw
      || Text.length raw > 512
      || Text.any (\character -> isControl character || isSpace character) raw =
      Left (invalid raw)
  | otherwise = Right raw

validateCiphertextDigest
  :: Text
  -> Either VerifiedPulumiCheckpointRefError Text
validateCiphertextDigest digest
  | Text.length digest == 64
      && Text.all isLowerHex digest =
      Right digest
  | otherwise = Left (VerifiedCheckpointCiphertextDigestInvalid digest)
 where
  isLowerHex character =
    ('0' <= character && character <= '9')
      || ('a' <= character && character <= 'f')
