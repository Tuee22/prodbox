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
  , observeCheckpointRetirementDisposition
  , AuthorityCheckpointSerialiseRegression
  , fixedAuthorityCheckpointSerialiseRegression
  , authorityCheckpointLegacyAggregateDecodes
  , authorityCheckpointLegacyRetirementRefused
  , authorityCheckpointDispositionRoundTrips
  )
where

import Codec.Serialise
  ( DeserialiseFailure
  , Serialise (decode, encode)
  , deserialiseOrFail
  , serialise
  )
import Codec.Serialise.Decoding (decodeListLen, decodeWord)
import Codec.Serialise.Encoding (encodeListLen, encodeWord)
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
  , mkPulumiCheckpointOperationRef
  , pulumiCheckpointOperationRefText
  , registeredPulumiCheckpointName
  , registeredPulumiCheckpoints
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CustodyDispositionKind (..)
  , CustodyDispositionRecord (..)
  , dispositionRecordDisposesCheckpoint
  , renderedCheckpointCapability
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

-- | Sprint 4.89: the projection, plus the disposition each retirement operation
-- was permitted under.
--
-- The disposition lives in its own map rather than inside
-- 'CheckpointOperationPermit' so that an aggregate written before this sprint
-- still decodes: the hand-written instance below reads a three-field aggregate
-- and supplies an /empty/ disposition map, which is exactly the state that
-- makes every retirement in it refuse rather than proceed.
data AuthorityPulumiCheckpoints = AuthorityPulumiCheckpoints
  { authorityCheckpointSlots
      :: !(Map Text (Maybe VerifiedPulumiCheckpointRef))
  , authorityCheckpointRetired
      :: !(Map Text [VerifiedPulumiCheckpointRef])
  , authorityCheckpointOperations
      :: !(Map Text CheckpointOperationPermit)
  , authorityCheckpointRetirementDispositions
      :: !(Map Text CustodyDispositionRecord)
  }
  deriving stock (Eq, Show, Generic)

-- | Hand-written so a pre-Sprint-4.89 aggregate decodes.
--
-- A decode that loses the disposition map __refuses__ rather than defaulting to
-- a permissive one: the empty map it supplies is the state in which
-- 'authorizeCheckpointRetirement' and 'applyCheckpointRetirement' refuse every
-- retirement for want of a stated disposition.  Silently admitting those
-- retirements is precisely what this sprint exists to stop.
-- The generic product encoding this replaces is @listLen (fields + 1)@ followed
-- by a zero constructor tag and then the fields, so the pre-Sprint-4.89
-- three-field aggregate is a four-element list.
--
-- __The disposition map is encoded only when it is non-empty.__ That keeps the
-- encoding canonical — each value still has exactly one byte string — while
-- leaving every retained aggregate that predates dispositions byte-identical
-- under re-encoding. Widening the encoding unconditionally would have made
-- every retained Authority object fail the enclosing envelope's own
-- canonicality check on the next read, which is a durability break rather than
-- a migration.
instance Serialise AuthorityPulumiCheckpoints where
  encode registry
    | Map.null dispositions =
        encodeListLen 4
          <> encodeWord 0
          <> encode (authorityCheckpointSlots registry)
          <> encode (authorityCheckpointRetired registry)
          <> encode (authorityCheckpointOperations registry)
    | otherwise =
        encodeListLen 5
          <> encodeWord 0
          <> encode (authorityCheckpointSlots registry)
          <> encode (authorityCheckpointRetired registry)
          <> encode (authorityCheckpointOperations registry)
          <> encode dispositions
   where
    dispositions = authorityCheckpointRetirementDispositions registry

  decode = do
    elements <- decodeListLen
    tag <- decodeWord
    if tag /= 0
      then fail ("unsupported authority checkpoint aggregate tag: " ++ show tag)
      else pure ()
    slots <- decode
    retired <- decode
    operations <- decode
    dispositions <- case elements of
      4 -> pure Map.empty
      5 -> decode
      _ -> fail ("unsupported authority checkpoint aggregate arity: " ++ show elements)
    case dispositions of
      -- An explicitly-encoded empty map is a second byte string for one value,
      -- which is exactly what canonicality forbids.
      _ | elements == 5 && Map.null dispositions -> fail "non-canonical empty disposition map"
      _ -> pure ()
    pure
      AuthorityPulumiCheckpoints
        { authorityCheckpointSlots = slots
        , authorityCheckpointRetired = retired
        , authorityCheckpointOperations = operations
        , authorityCheckpointRetirementDispositions = dispositions
        }

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
  | AuthorityCheckpointDispositionUnowned !Text
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
    , authorityCheckpointRetirementDispositions = Map.empty
    }

-- | The disposition one retirement operation was permitted under, if it was
-- stated at all.
observeCheckpointRetirementDisposition
  :: PulumiCheckpointOperationRef
  -> AuthorityPulumiCheckpoints
  -> Maybe CustodyDispositionRecord
observeCheckpointRetirementDisposition operation registry =
  Map.lookup
    (pulumiCheckpointOperationRefText operation)
    (authorityCheckpointRetirementDispositions registry)

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
  | orphaned : _ <- orphanedDispositions =
      Left (AuthorityCheckpointDispositionUnowned orphaned)
  | otherwise = do
      traverse_ validateRetired (Map.toList retired)
      traverse_ validateOperation (Map.toList operations)
 where
  slots = authorityCheckpointSlots registry
  retired = authorityCheckpointRetired registry
  operations = authorityCheckpointOperations registry
  operationCount = fromIntegral (Map.size operations)
  -- A disposition names the retirement it was stated for. One that outlives its
  -- operation is a claim nothing can consume, which is a different defect from
  -- a retirement with no disposition and is refused separately.
  orphanedDispositions =
    [ key
    | key <- Map.keys (authorityCheckpointRetirementDispositions registry)
    , not (Map.member key operations)
    ]
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
  | -- | Sprint 4.89: a retirement permit was asked for with no stated
    -- disposition for the checkpoint it retires.
    CheckpointPermitRefusedRetirementDisposition
  deriving stock (Eq, Show)

registerCheckpointOperationPermit
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> CheckpointOperationKind
  -> Maybe PulumiCheckpointDigest
  -> Maybe CustodyDispositionRecord
  -> AuthorityPulumiCheckpoints
  -> Either
       AuthorityPulumiCheckpointInvariantError
       (CheckpointPermitDecision, AuthorityPulumiCheckpoints)
registerCheckpointOperationPermit operation registered kind expected disposition registry = do
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
      -- Sprint 4.89: a retirement permit is registered only against a stated
      -- disposition for the checkpoint being retired.  The Authority cannot
      -- observe AWS and so cannot check the proof; what it refuses is a
      -- retirement for which no disposition was ever stated, which is the
      -- failure that stranded two AWS resources.
      | kind == RetireCheckpoint
      , not (any (dispositionRecordDisposesCheckpoint name) disposition) ->
          pure (CheckpointPermitRefusedRetirementDisposition, registry)
      | otherwise ->
          pure
            ( CheckpointPermitRegistered
            , registry
                { authorityCheckpointOperations =
                    Map.insert
                      key
                      permit
                      (authorityCheckpointOperations registry)
                , authorityCheckpointRetirementDispositions =
                    maybe
                      (authorityCheckpointRetirementDispositions registry)
                      ( \record ->
                          Map.insert
                            key
                            record
                            (authorityCheckpointRetirementDispositions registry)
                      )
                      (retirementDisposition kind disposition)
                }
            )

-- | Only a retirement carries one.  A publication or restore that supplied one
-- would be recording a claim nothing consumes.
retirementDisposition
  :: CheckpointOperationKind
  -> Maybe CustodyDispositionRecord
  -> Maybe CustodyDispositionRecord
retirementDisposition kind disposition = case kind of
  RetireCheckpoint -> disposition
  PublishCheckpoint -> Nothing
  RestoreCheckpoint -> Nothing

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
  | -- | Sprint 4.89: this retirement operation has no stated disposition for
    -- the checkpoint it retires.  An aggregate written before the disposition
    -- existed lands here rather than proceeding.
    CheckpointMutationRefusedRetirementDisposition
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
      -- Sprint 4.89: an aggregate written before this sprint carries no
      -- disposition map, so every retirement permit it holds lands here and
      -- refuses.  That is deliberate: a decode that loses the observation must
      -- refuse rather than default to a permissive answer.
      | not (statedDispositionFor operation registered registry) ->
          refused CheckpointMutationRefusedRetirementDisposition
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

-- | Whether this run stated a disposition for the checkpoint it is retiring.
statedDispositionFor
  :: PulumiCheckpointOperationRef
  -> RegisteredPulumiCheckpoint
  -> AuthorityPulumiCheckpoints
  -> Bool
statedDispositionFor operation registered registry =
  any
    (dispositionRecordDisposesCheckpoint (registeredPulumiCheckpointName registered))
    (observeCheckpointRetirementDisposition operation registry)

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
      | not (statedDispositionFor operation registered registry) ->
          pure (CheckpointMutationRefusedRetirementDisposition, registry)
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
  -- A disposition names the retirement it was stated for, so it is forgotten
  -- with the operation rather than surviving it.  Only a publication is
  -- compactable today and a publication never carries one, so this is the
  -- pairing rule written down rather than a live deletion.
  removed key = do
    let next =
          registry
            { authorityCheckpointOperations =
                Map.delete key (authorityCheckpointOperations registry)
            , authorityCheckpointRetirementDispositions =
                Map.delete key (authorityCheckpointRetirementDispositions registry)
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

-- ---------------------------------------------------------------------------
-- The frozen Serialise compatibility fixture
-- ---------------------------------------------------------------------------

-- | The aggregate exactly as it was encoded before Sprint 4.89.
--
-- It is a separate type deriving the same generic encoding rather than a
-- captured byte string, so it stays honest about the shape it claims to be:
-- if the first three fields ever change, this stops matching the real
-- aggregate's prefix and the regression fails instead of asserting over stale
-- bytes.
data LegacyAuthorityPulumiCheckpoints = LegacyAuthorityPulumiCheckpoints
  { legacyAuthorityCheckpointSlots
      :: !(Map Text (Maybe VerifiedPulumiCheckpointRef))
  , legacyAuthorityCheckpointRetired
      :: !(Map Text [VerifiedPulumiCheckpointRef])
  , legacyAuthorityCheckpointOperations
      :: !(Map Text CheckpointOperationPermit)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Non-authorizing booleans a dependent test can read.
data AuthorityCheckpointSerialiseRegression = AuthorityCheckpointSerialiseRegression
  { authorityCheckpointLegacyAggregateDecodes :: !Bool
  , authorityCheckpointLegacyRetirementRefused :: !Bool
  , authorityCheckpointDispositionRoundTrips :: !Bool
  }

-- | Sprint 4.89: a pre-change aggregate decodes, and every retirement in it
-- refuses rather than defaulting to a permissive answer.
fixedAuthorityCheckpointSerialiseRegression
  :: AuthorityCheckpointSerialiseRegression
fixedAuthorityCheckpointSerialiseRegression =
  AuthorityCheckpointSerialiseRegression
    { authorityCheckpointLegacyAggregateDecodes = legacyDecodes
    , authorityCheckpointLegacyRetirementRefused = legacyRetirementRefused
    , authorityCheckpointDispositionRoundTrips = roundTrips
    }
 where
  registered = case registeredPulumiCheckpoints of
    checkpoint : _ -> checkpoint
    [] -> error "the registry declares no Pulumi checkpoint"

  registeredName = registeredPulumiCheckpointName registered

  operationKey = "fixed-retirement-operation"

  fixedOperationRef = case mkPulumiCheckpointOperationRef operationKey of
    Right reference -> reference
    Left err -> error ("fixed checkpoint operation reference: " ++ show err)

  retirementPermit =
    CheckpointOperationPermit
      { checkpointPermitReference = fixedOperationRef
      , checkpointPermitRegistration = registeredName
      , checkpointPermitKind = RetireCheckpoint
      , checkpointPermitExpectedDigest = Nothing
      , checkpointPermitPhase = CheckpointOperationPending
      }

  legacyAggregate =
    LegacyAuthorityPulumiCheckpoints
      { legacyAuthorityCheckpointSlots =
          authorityCheckpointSlots initialAuthorityPulumiCheckpoints
      , legacyAuthorityCheckpointRetired =
          authorityCheckpointRetired initialAuthorityPulumiCheckpoints
      , legacyAuthorityCheckpointOperations =
          Map.singleton operationKey retirementPermit
      }

  decoded =
    deserialiseOrFail (serialise legacyAggregate)
      :: Either DeserialiseFailure AuthorityPulumiCheckpoints

  legacyDecodes = case decoded of
    Left _ -> False
    Right registry ->
      serialise registry == serialise legacyAggregate
        && authorityCheckpointSlots registry
          == legacyAuthorityCheckpointSlots legacyAggregate
        && authorityCheckpointRetired registry
          == legacyAuthorityCheckpointRetired legacyAggregate
        && authorityCheckpointOperations registry
          == legacyAuthorityCheckpointOperations legacyAggregate
        && Map.null (authorityCheckpointRetirementDispositions registry)

  -- The whole point of the empty map: a decode that lost the observation
  -- refuses the retirement rather than defaulting to a permissive answer.
  legacyRetirementRefused = case decoded of
    Left _ -> False
    Right registry ->
      authorizeCheckpointRetirement fixedOperationRef registered registry
        == Right
          ( CheckpointMutationAuthorizationRefused
              CheckpointMutationRefusedRetirementDisposition
          )
        && fmap
          fst
          (applyCheckpointRetirement fixedOperationRef registered registry)
          == Right CheckpointMutationRefusedRetirementDisposition

  fixedDisposition =
    CustodyDispositionRecord
      { custodyDispositionCapability = renderedCheckpointCapability registeredName
      , custodyDispositionKind = DispositionDischargedByAbsence
      , custodyDispositionDetail = "fixed regression discharge"
      , custodyDispositionDependants = [registeredName]
      }

  currentAggregate =
    initialAuthorityPulumiCheckpoints
      { authorityCheckpointOperations = Map.singleton operationKey retirementPermit
      , authorityCheckpointRetirementDispositions =
          Map.singleton operationKey fixedDisposition
      }

  roundTrips =
    ( deserialiseOrFail (serialise currentAggregate)
        :: Either DeserialiseFailure AuthorityPulumiCheckpoints
    )
      == Right currentAggregate
      && authorizeCheckpointRetirement fixedOperationRef registered currentAggregate
        == Right CheckpointMutationAuthorized
