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
  , CheckpointPermitDecision (..)
  , registerCheckpointOperationPermit
  , CheckpointMutationDecision (..)
  , CheckpointMutationAuthorization (..)
  , authorizeCheckpointPublication
  , authorizeCheckpointRetirement
  , applyCheckpointPublication
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
  | RetireCheckpoint
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CheckpointOperationPhase
  = CheckpointOperationPending
  | CheckpointPublicationApplied !VerifiedPulumiCheckpointRef
  | CheckpointRetirementApplied
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
  , authorityCheckpointOperations
      :: !(Map Text CheckpointOperationPermit)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

authorityPulumiCheckpointOperationCapacity :: Natural
authorityPulumiCheckpointOperationCapacity = 256

authorityPulumiCheckpointOperationCount :: AuthorityPulumiCheckpoints -> Natural
authorityPulumiCheckpointOperationCount =
  fromIntegral . Map.size . authorityCheckpointOperations

data AuthorityPulumiCheckpointInvariantError
  = AuthorityCheckpointSlotInventoryMismatch
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
    , authorityCheckpointOperations = Map.empty
    }

validateAuthorityPulumiCheckpoints
  :: AuthorityPulumiCheckpoints
  -> Either AuthorityPulumiCheckpointInvariantError ()
validateAuthorityPulumiCheckpoints registry
  | Map.keysSet slots /= registeredNames =
      Left AuthorityCheckpointSlotInventoryMismatch
  | operationCount > authorityPulumiCheckpointOperationCapacity =
      Left
        ( AuthorityCheckpointOperationOverCapacity
            operationCount
            authorityPulumiCheckpointOperationCapacity
        )
  | otherwise = traverse_ validateOperation (Map.toList operations)
 where
  slots = authorityCheckpointSlots registry
  operations = authorityCheckpointOperations registry
  operationCount = fromIntegral (Map.size operations)
  registeredNames =
    Set.fromList
      (map registeredPulumiCheckpointName registeredPulumiCheckpoints)
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
  validatePhase _ RetireCheckpoint CheckpointRetirementApplied = Right ()
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
          CheckpointRetirementApplied ->
            refused CheckpointMutationRefusedKind
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
          CheckpointRetirementApplied ->
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
          CheckpointRetirementApplied ->
            pure (CheckpointMutationRefusedKind, registry)

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
          CheckpointRetirementApplied ->
            pure (CheckpointMutationAlreadyApplied, registry)
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
                  , updateRetired operation registered permit registry
                  )
          CheckpointPublicationApplied _ ->
            pure (CheckpointMutationRefusedKind, registry)

-- | Remove one terminal operation tombstone after the owning submission has
-- been selected for compaction.  A missing checkpoint permit is already
-- compacted and therefore succeeds idempotently.  A pending permit refuses by
-- returning @False@: its admitted mutation has not reached a terminal state
-- and may not be evicted to make capacity.
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
      CheckpointRetirementApplied -> removed key
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

updateRetired
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> CheckpointOperationPermit
  -> AuthorityPulumiCheckpoints
  -> AuthorityPulumiCheckpoints
updateRetired operation registered permit registry =
  registry
    { authorityCheckpointSlots =
        Map.insert
          (registeredPulumiCheckpointName registered)
          Nothing
          (authorityCheckpointSlots registry)
    , authorityCheckpointOperations =
        Map.insert
          (pulumiCheckpointOperationRefText operation)
          permit {checkpointPermitPhase = CheckpointRetirementApplied}
          (authorityCheckpointOperations registry)
    }

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
