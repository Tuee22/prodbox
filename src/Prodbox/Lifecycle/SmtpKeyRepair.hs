{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure bounded repair protocol for the SES SMTP IAM access-key edge.
--
-- IAM is authoritative for key IDs, while recoverable secret material and the
-- committed key ID live in fenced retained state.  Creation is reachable only
-- after every uncommitted or unrecoverable key has been deleted and a stable
-- authoritative inventory has confirmed the expected post-cleanup state.
module Prodbox.Lifecycle.SmtpKeyRepair
  ( CommittedSmtpCredential
  , SmtpCommittedProjection
  , SmtpCommittedProjectionCodecError (..)
  , SmtpAccessKeyId
  , SmtpCommitCandidate
  , SmtpKeyCleanupResult (..)
  , SmtpKeyCreateAction
  , SmtpKeyInventoryBound
  , SmtpKeyInventoryObservation (..)
  , SmtpKeyRepairPlan (..)
  , SmtpKeyRepairRefusal (..)
  , SmtpKeyValueError (..)
  , SmtpRepairContinuation (..)
  , StableSmtpInventoryWitness
  , TimedSmtpKeyInventoryObservation (..)
  , acceptCreatedSmtpCredential
  , authorizeSmtpKeyCreation
  , committedSmtpCredentialDigest
  , committedSmtpCredentialGeneration
  , committedSmtpCredentialKeyId
  , committedSmtpCredentialMaterial
  , confirmSmtpKeyCleanup
  , confirmSmtpReuseAfterCleanup
  , decodeSmtpCommittedProjection
  , encodeSmtpCommittedProjection
  , mkCommittedSmtpCredential
  , mkSmtpAccessKeyId
  , mkSmtpKeyInventoryBound
  , planSmtpKeyRepair
  , proveStableSmtpInventory
  , smtpAccessKeyIdText
  , smtpCommitCandidateDigest
  , smtpCommitCandidateFencingToken
  , smtpCommitCandidateGeneration
  , smtpCommitCandidateKeyId
  , smtpCommitCandidateMaterial
  , smtpCommitCandidateOwnerNonce
  , smtpCommittedProjectionMaximumEncodedBytes
  , smtpKeyCreateActionGeneration
  , smtpKeyCreateActionOwnerNonce
  , smtpKeyCreateActionFencingToken
  , smtpKeyInventoryMaximum
  , stableSmtpInventoryKeyIds
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , FencedCommitPermit
  , FencingToken
  , LeasePolicy
  , OwnerNonce
  , addAuthorityDuration
  , fencedCommitFencingToken
  , fencedCommitOwnerNonce
  , leasePolicyProviderVisibilityGrace
  , leasePolicyStableObservationCount
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetCommitValueError
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )

newtype SmtpAccessKeyId = SmtpAccessKeyId
  { internalSmtpAccessKeyIdText :: Text
  }
  deriving (Eq, Ord, Show)

newtype SmtpKeyInventoryBound = SmtpKeyInventoryBound
  { internalSmtpKeyInventoryMaximum :: Int
  }
  deriving (Eq, Show)

data SmtpKeyValueError
  = SmtpAccessKeyIdEmpty
  | SmtpAccessKeyIdTooLong !Int !Int
  | SmtpAccessKeyIdContainsUnsafeCharacter !Char
  | SmtpKeyInventoryBoundMustBePositive
  | SmtpKeyInventoryBoundExceedsIamMaximum !Natural !Natural
  deriving (Eq, Show)

mkSmtpAccessKeyId :: Text -> Either SmtpKeyValueError SmtpAccessKeyId
mkSmtpAccessKeyId raw
  | Text.null value = Left SmtpAccessKeyIdEmpty
  | Text.length value > maximumLength =
      Left (SmtpAccessKeyIdTooLong (Text.length value) maximumLength)
  | Just unsafe <- Text.find (not . safe) value =
      Left (SmtpAccessKeyIdContainsUnsafeCharacter unsafe)
  | otherwise = Right (SmtpAccessKeyId value)
 where
  value = Text.strip raw
  maximumLength = 128
  safe character =
    isAsciiLower character || isAsciiUpper character || isDigit character

smtpAccessKeyIdText :: SmtpAccessKeyId -> Text
smtpAccessKeyIdText = internalSmtpAccessKeyIdText

-- | IAM currently admits at most two active access keys for one user.  The
-- hard maximum is part of the protocol rather than an adapter convention.
mkSmtpKeyInventoryBound
  :: Natural -> Either SmtpKeyValueError SmtpKeyInventoryBound
mkSmtpKeyInventoryBound value
  | value == 0 = Left SmtpKeyInventoryBoundMustBePositive
  | value > iamAccessKeyHardMaximum =
      Left (SmtpKeyInventoryBoundExceedsIamMaximum value iamAccessKeyHardMaximum)
  | otherwise = Right (SmtpKeyInventoryBound (fromIntegral value))

iamAccessKeyHardMaximum :: Natural
iamAccessKeyHardMaximum = 2

smtpKeyInventoryMaximum :: SmtpKeyInventoryBound -> Int
smtpKeyInventoryMaximum = internalSmtpKeyInventoryMaximum

data CommittedSmtpCredential payload = CommittedSmtpCredential
  { internalCommittedSmtpCredentialKeyId :: !SmtpAccessKeyId
  , internalCommittedSmtpCredentialGeneration :: !CredentialGeneration
  , internalCommittedSmtpCredentialDigest :: !TargetValueDigest
  , internalCommittedSmtpCredentialMaterial :: !(Maybe payload)
  }
  deriving (Eq, Show)

-- | 'Nothing' material explicitly represents an unrecoverable committed key.
-- IAM never returns old secret material, so repair must delete that key rather
-- than pretending it can be reconstructed from the key ID.
mkCommittedSmtpCredential
  :: SmtpAccessKeyId
  -> CredentialGeneration
  -> TargetValueDigest
  -> Maybe payload
  -> CommittedSmtpCredential payload
mkCommittedSmtpCredential keyId generation digest material =
  CommittedSmtpCredential
    { internalCommittedSmtpCredentialKeyId = keyId
    , internalCommittedSmtpCredentialGeneration = generation
    , internalCommittedSmtpCredentialDigest = digest
    , internalCommittedSmtpCredentialMaterial = material
    }

committedSmtpCredentialKeyId
  :: CommittedSmtpCredential payload -> SmtpAccessKeyId
committedSmtpCredentialKeyId = internalCommittedSmtpCredentialKeyId

committedSmtpCredentialGeneration
  :: CommittedSmtpCredential payload -> CredentialGeneration
committedSmtpCredentialGeneration = internalCommittedSmtpCredentialGeneration

committedSmtpCredentialDigest
  :: CommittedSmtpCredential payload -> TargetValueDigest
committedSmtpCredentialDigest = internalCommittedSmtpCredentialDigest

committedSmtpCredentialMaterial
  :: CommittedSmtpCredential payload -> Maybe payload
committedSmtpCredentialMaterial = internalCommittedSmtpCredentialMaterial

type SmtpCommittedProjection = CommittedSmtpCredential ByteString

data WireSmtpCommittedProjection = WireSmtpCommittedProjection
  { wireSmtpCommittedVersion :: !Word16
  , wireSmtpCommittedKeyId :: !Text
  , wireSmtpCommittedGeneration :: !Natural
  , wireSmtpCommittedDigest :: !Text
  , wireSmtpCommittedMaterial :: !(Maybe ByteString)
  }
  deriving (Eq, Generic, Show)

instance Serialise WireSmtpCommittedProjection

data SmtpCommittedProjectionCodecError
  = SmtpCommittedProjectionCodecTooLarge !Int !Int
  | SmtpCommittedProjectionCodecDecodeFailed !Text
  | SmtpCommittedProjectionCodecUnsupportedVersion !Word16
  | SmtpCommittedProjectionCodecKeyInvalid !SmtpKeyValueError
  | SmtpCommittedProjectionCodecValueInvalid !TargetCommitValueError
  | SmtpCommittedProjectionCodecMaterialTooLarge !Int !Int
  | SmtpCommittedProjectionCodecNonCanonical
  deriving (Eq, Show)

smtpCommittedProjectionMaximumEncodedBytes :: Int
smtpCommittedProjectionMaximumEncodedBytes = 32 * 1024

smtpCommittedMaterialMaximumBytes :: Int
smtpCommittedMaterialMaximumBytes = 16 * 1024

smtpCommittedProjectionCodecVersion :: Word16
smtpCommittedProjectionCodecVersion = 1

encodeSmtpCommittedProjection
  :: SmtpCommittedProjection
  -> Either SmtpCommittedProjectionCodecError ByteString
encodeSmtpCommittedProjection committed = do
  validateCommittedMaterial (committedSmtpCredentialMaterial committed)
  pure (BL.toStrict (serialise (wireSmtpCommittedProjection committed)))

decodeSmtpCommittedProjection
  :: ByteString
  -> Either SmtpCommittedProjectionCodecError SmtpCommittedProjection
decodeSmtpCommittedProjection bytes
  | BS.length bytes > smtpCommittedProjectionMaximumEncodedBytes =
      Left
        ( SmtpCommittedProjectionCodecTooLarge
            (BS.length bytes)
            smtpCommittedProjectionMaximumEncodedBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (BL.fromStrict bytes) of
        Left err ->
          Left (SmtpCommittedProjectionCodecDecodeFailed (Text.pack (show err)))
        Right value -> Right value
      unless
        (wireSmtpCommittedVersion wire == smtpCommittedProjectionCodecVersion)
        ( Left
            ( SmtpCommittedProjectionCodecUnsupportedVersion
                (wireSmtpCommittedVersion wire)
            )
        )
      keyId <-
        either
          (Left . SmtpCommittedProjectionCodecKeyInvalid)
          Right
          (mkSmtpAccessKeyId (wireSmtpCommittedKeyId wire))
      generation <-
        either
          (Left . SmtpCommittedProjectionCodecValueInvalid)
          Right
          (mkCredentialGeneration (wireSmtpCommittedGeneration wire))
      digest <-
        either
          (Left . SmtpCommittedProjectionCodecValueInvalid)
          Right
          (mkTargetValueDigest (wireSmtpCommittedDigest wire))
      validateCommittedMaterial (wireSmtpCommittedMaterial wire)
      let committed =
            mkCommittedSmtpCredential
              keyId
              generation
              digest
              (wireSmtpCommittedMaterial wire)
      canonical <- encodeSmtpCommittedProjection committed
      unless
        (canonical == bytes)
        (Left SmtpCommittedProjectionCodecNonCanonical)
      pure committed

wireSmtpCommittedProjection
  :: SmtpCommittedProjection -> WireSmtpCommittedProjection
wireSmtpCommittedProjection committed =
  WireSmtpCommittedProjection
    { wireSmtpCommittedVersion = smtpCommittedProjectionCodecVersion
    , wireSmtpCommittedKeyId =
        smtpAccessKeyIdText (committedSmtpCredentialKeyId committed)
    , wireSmtpCommittedGeneration =
        credentialGenerationValue (committedSmtpCredentialGeneration committed)
    , wireSmtpCommittedDigest =
        targetValueDigestText (committedSmtpCredentialDigest committed)
    , wireSmtpCommittedMaterial = committedSmtpCredentialMaterial committed
    }

validateCommittedMaterial
  :: Maybe ByteString -> Either SmtpCommittedProjectionCodecError ()
validateCommittedMaterial maybeMaterial = case maybeMaterial of
  Just material
    | BS.length material > smtpCommittedMaterialMaximumBytes ->
        Left
          ( SmtpCommittedProjectionCodecMaterialTooLarge
              (BS.length material)
              smtpCommittedMaterialMaximumBytes
          )
  _ -> Right ()

data SmtpKeyInventoryObservation
  = SmtpKeyInventoryObserved ![SmtpAccessKeyId]
  | SmtpKeyInventoryPending !Text
  | SmtpKeyInventoryUnobservable !Text
  | SmtpKeyInventoryOverBound !Natural !Natural
  deriving (Eq, Show)

data SmtpRepairContinuation payload
  = SmtpReuseAfterCleanup !(CommittedSmtpCredential payload)
  | SmtpCreateAfterStableAbsence
  deriving (Eq, Show)

data SmtpKeyRepairPlan payload
  = SmtpReuseCommitted !(CommittedSmtpCredential payload)
  | SmtpDeleteKeys
      ![SmtpAccessKeyId]
      !(SmtpRepairContinuation payload)
  | SmtpAwaitStableInventory !(SmtpRepairContinuation payload)
  | SmtpKeyRepairRefused !SmtpKeyRepairRefusal
  deriving (Eq, Show)

data SmtpKeyRepairRefusal
  = SmtpInventoryPending !Text
  | SmtpInventoryUnobservable !Text
  | SmtpInventoryOverBound !Natural !Natural
  | SmtpInventoryDuplicateKey !SmtpAccessKeyId
  | SmtpCleanupResultMissing !SmtpAccessKeyId
  | SmtpCleanupResultUnexpected !SmtpAccessKeyId
  | SmtpCleanupResultDuplicate !SmtpAccessKeyId
  | SmtpCleanupFailed !SmtpAccessKeyId !Text
  | SmtpCleanupPlanExpected
  | SmtpStableSampleCountMismatch !Int !Int
  | SmtpStableObservationBeforeDeadline !AuthorityTime !AuthorityTime
  | SmtpStableObservationsTooClose !AuthorityTime !AuthorityTime !AuthorityDuration
  | SmtpStableInventoryChanged
  | SmtpStableInventoryUnexpected ![SmtpAccessKeyId] ![SmtpAccessKeyId]
  | SmtpCreationRequiresStableEmptyInventory ![SmtpAccessKeyId]
  | SmtpReuseWitnessMismatch ![SmtpAccessKeyId] ![SmtpAccessKeyId]
  deriving (Eq, Show)

planSmtpKeyRepair
  :: SmtpKeyInventoryBound
  -> SmtpKeyInventoryObservation
  -> Maybe (CommittedSmtpCredential payload)
  -> SmtpKeyRepairPlan payload
planSmtpKeyRepair bound observation maybeCommitted =
  case normalizedInventory bound observation of
    Left refusal -> SmtpKeyRepairRefused refusal
    Right inventory ->
      case recoverableCommitted inventory maybeCommitted of
        Just committed ->
          let committedKey = committedSmtpCredentialKeyId committed
              uncommitted = filter (/= committedKey) inventory
           in if null uncommitted
                then SmtpReuseCommitted committed
                else SmtpDeleteKeys uncommitted (SmtpReuseAfterCleanup committed)
        Nothing ->
          if null inventory
            then SmtpAwaitStableInventory SmtpCreateAfterStableAbsence
            else SmtpDeleteKeys inventory SmtpCreateAfterStableAbsence

recoverableCommitted
  :: [SmtpAccessKeyId]
  -> Maybe (CommittedSmtpCredential payload)
  -> Maybe (CommittedSmtpCredential payload)
recoverableCommitted inventory maybeCommitted = case maybeCommitted of
  Just committed
    | committedSmtpCredentialKeyId committed `elem` inventory
        && hasRecoverableMaterial committed ->
        Just committed
  _ -> Nothing
 where
  hasRecoverableMaterial committed = case committedSmtpCredentialMaterial committed of
    Just _ -> True
    Nothing -> False

data SmtpKeyCleanupResult
  = SmtpKeyDeleted !SmtpAccessKeyId
  | SmtpKeyDeleteFailed !SmtpAccessKeyId !Text
  deriving (Eq, Show)

-- | Cleanup completion is explicit plan data.  Any missing, duplicate,
-- unexpected, or failed deletion stops the fold before stable observation or
-- creation can be authorized.
confirmSmtpKeyCleanup
  :: SmtpKeyRepairPlan payload
  -> [SmtpKeyCleanupResult]
  -> Either SmtpKeyRepairRefusal (SmtpKeyRepairPlan payload)
confirmSmtpKeyCleanup plan results = case plan of
  SmtpDeleteKeys expected continuation -> do
    indexed <- indexCleanupResults results
    mapM_ (requireCleanupResult indexed) expected
    mapM_ (rejectUnexpected expected) (Map.keys indexed)
    pure (SmtpAwaitStableInventory continuation)
  _ -> Left SmtpCleanupPlanExpected

indexCleanupResults
  :: [SmtpKeyCleanupResult]
  -> Either SmtpKeyRepairRefusal (Map SmtpAccessKeyId SmtpKeyCleanupResult)
indexCleanupResults = foldl' insertResult (Right Map.empty)
 where
  insertResult accumulated result = do
    indexed <- accumulated
    let keyId = cleanupResultKeyId result
    if Map.member keyId indexed
      then Left (SmtpCleanupResultDuplicate keyId)
      else Right (Map.insert keyId result indexed)

requireCleanupResult
  :: Map SmtpAccessKeyId SmtpKeyCleanupResult
  -> SmtpAccessKeyId
  -> Either SmtpKeyRepairRefusal ()
requireCleanupResult indexed keyId = case Map.lookup keyId indexed of
  Nothing -> Left (SmtpCleanupResultMissing keyId)
  Just (SmtpKeyDeleteFailed _ detail) -> Left (SmtpCleanupFailed keyId detail)
  Just (SmtpKeyDeleted _) -> Right ()

rejectUnexpected
  :: [SmtpAccessKeyId]
  -> SmtpAccessKeyId
  -> Either SmtpKeyRepairRefusal ()
rejectUnexpected expected keyId =
  unless
    (keyId `elem` expected)
    (Left (SmtpCleanupResultUnexpected keyId))

cleanupResultKeyId :: SmtpKeyCleanupResult -> SmtpAccessKeyId
cleanupResultKeyId result = case result of
  SmtpKeyDeleted keyId -> keyId
  SmtpKeyDeleteFailed keyId _ -> keyId

data TimedSmtpKeyInventoryObservation = TimedSmtpKeyInventoryObservation
  { timedSmtpKeyInventoryObservedAt :: !AuthorityTime
  , timedSmtpKeyInventoryObservation :: !SmtpKeyInventoryObservation
  }
  deriving (Eq, Show)

data StableSmtpInventoryWitness = StableSmtpInventoryWitness
  { internalStableSmtpInventoryKeyIds :: ![SmtpAccessKeyId]
  , internalStableSmtpInventoryObservedThrough :: !AuthorityTime
  }
  deriving (Eq, Show)

stableSmtpInventoryKeyIds
  :: StableSmtpInventoryWitness -> [SmtpAccessKeyId]
stableSmtpInventoryKeyIds = internalStableSmtpInventoryKeyIds

proveStableSmtpInventory
  :: LeasePolicy
  -> AuthorityTime
  -> SmtpKeyInventoryBound
  -> [SmtpAccessKeyId]
  -> [TimedSmtpKeyInventoryObservation]
  -> Either SmtpKeyRepairRefusal StableSmtpInventoryWitness
proveStableSmtpInventory policy notBefore bound expected samples = do
  let required = leasePolicyStableObservationCount policy
      actual = length samples
  unless
    (actual == required)
    (Left (SmtpStableSampleCountMismatch required actual))
  observed <- mapM observeSample samples
  validateSmtpIntervals
    (leasePolicyProviderVisibilityGrace policy)
    (map timedSmtpKeyInventoryObservedAt samples)
  case observed of
    [] -> Left (SmtpStableSampleCountMismatch required actual)
    firstInventory : remaining -> do
      unless
        (all (== firstInventory) remaining)
        (Left SmtpStableInventoryChanged)
      let normalizedExpected = sort expected
      unless
        (firstInventory == normalizedExpected)
        (Left (SmtpStableInventoryUnexpected normalizedExpected firstInventory))
      pure
        StableSmtpInventoryWitness
          { internalStableSmtpInventoryKeyIds = firstInventory
          , internalStableSmtpInventoryObservedThrough = timedSmtpKeyInventoryObservedAt (last samples)
          }
 where
  observeSample sample = do
    when
      (timedSmtpKeyInventoryObservedAt sample < notBefore)
      ( Left
          ( SmtpStableObservationBeforeDeadline
              (timedSmtpKeyInventoryObservedAt sample)
              notBefore
          )
      )
    normalizedInventory bound (timedSmtpKeyInventoryObservation sample)

data SmtpKeyCreateAction = SmtpKeyCreateAction
  { internalSmtpKeyCreateActionOwnerNonce :: !OwnerNonce
  , internalSmtpKeyCreateActionFencingToken :: !FencingToken
  , internalSmtpKeyCreateActionGeneration :: !CredentialGeneration
  }
  deriving (Eq, Show)

authorizeSmtpKeyCreation
  :: FencedCommitPermit
  -> CredentialGeneration
  -> SmtpRepairContinuation payload
  -> StableSmtpInventoryWitness
  -> Either SmtpKeyRepairRefusal SmtpKeyCreateAction
authorizeSmtpKeyCreation permit generation continuation witness = case continuation of
  SmtpReuseAfterCleanup _ ->
    Left
      ( SmtpCreationRequiresStableEmptyInventory
          (stableSmtpInventoryKeyIds witness)
      )
  SmtpCreateAfterStableAbsence
    | null (stableSmtpInventoryKeyIds witness) ->
        Right
          SmtpKeyCreateAction
            { internalSmtpKeyCreateActionOwnerNonce = fencedCommitOwnerNonce permit
            , internalSmtpKeyCreateActionFencingToken = fencedCommitFencingToken permit
            , internalSmtpKeyCreateActionGeneration = generation
            }
    | otherwise ->
        Left
          ( SmtpCreationRequiresStableEmptyInventory
              (stableSmtpInventoryKeyIds witness)
          )

smtpKeyCreateActionOwnerNonce :: SmtpKeyCreateAction -> OwnerNonce
smtpKeyCreateActionOwnerNonce = internalSmtpKeyCreateActionOwnerNonce

smtpKeyCreateActionFencingToken :: SmtpKeyCreateAction -> FencingToken
smtpKeyCreateActionFencingToken = internalSmtpKeyCreateActionFencingToken

smtpKeyCreateActionGeneration :: SmtpKeyCreateAction -> CredentialGeneration
smtpKeyCreateActionGeneration = internalSmtpKeyCreateActionGeneration

confirmSmtpReuseAfterCleanup
  :: SmtpRepairContinuation payload
  -> StableSmtpInventoryWitness
  -> Either SmtpKeyRepairRefusal (CommittedSmtpCredential payload)
confirmSmtpReuseAfterCleanup continuation witness = case continuation of
  SmtpCreateAfterStableAbsence ->
    Left
      ( SmtpReuseWitnessMismatch
          []
          (stableSmtpInventoryKeyIds witness)
      )
  SmtpReuseAfterCleanup committed ->
    let expected = [committedSmtpCredentialKeyId committed]
        observed = stableSmtpInventoryKeyIds witness
     in if observed == expected
          then Right committed
          else Left (SmtpReuseWitnessMismatch expected observed)

data SmtpCommitCandidate payload = SmtpCommitCandidate
  { internalSmtpCommitCandidateKeyId :: !SmtpAccessKeyId
  , internalSmtpCommitCandidateGeneration :: !CredentialGeneration
  , internalSmtpCommitCandidateDigest :: !TargetValueDigest
  , internalSmtpCommitCandidateMaterial :: !payload
  , internalSmtpCommitCandidateOwnerNonce :: !OwnerNonce
  , internalSmtpCommitCandidateFencingToken :: !FencingToken
  }
  deriving (Eq, Show)

-- | Interpret one successful create response into the sole candidate that may
-- enter the global intent/checkpoint commit.  The action contains one
-- generation and one fence; retry is not represented.  A failed external
-- create must return to authoritative inventory observation instead.
acceptCreatedSmtpCredential
  :: (payload -> TargetValueDigest)
  -> SmtpKeyCreateAction
  -> SmtpAccessKeyId
  -> payload
  -> SmtpCommitCandidate payload
acceptCreatedSmtpCredential digestPayload action keyId material =
  SmtpCommitCandidate
    { internalSmtpCommitCandidateKeyId = keyId
    , internalSmtpCommitCandidateGeneration = smtpKeyCreateActionGeneration action
    , internalSmtpCommitCandidateDigest = digestPayload material
    , internalSmtpCommitCandidateMaterial = material
    , internalSmtpCommitCandidateOwnerNonce = smtpKeyCreateActionOwnerNonce action
    , internalSmtpCommitCandidateFencingToken = smtpKeyCreateActionFencingToken action
    }

smtpCommitCandidateKeyId :: SmtpCommitCandidate payload -> SmtpAccessKeyId
smtpCommitCandidateKeyId = internalSmtpCommitCandidateKeyId

smtpCommitCandidateGeneration
  :: SmtpCommitCandidate payload -> CredentialGeneration
smtpCommitCandidateGeneration = internalSmtpCommitCandidateGeneration

smtpCommitCandidateDigest :: SmtpCommitCandidate payload -> TargetValueDigest
smtpCommitCandidateDigest = internalSmtpCommitCandidateDigest

smtpCommitCandidateMaterial :: SmtpCommitCandidate payload -> payload
smtpCommitCandidateMaterial = internalSmtpCommitCandidateMaterial

smtpCommitCandidateOwnerNonce :: SmtpCommitCandidate payload -> OwnerNonce
smtpCommitCandidateOwnerNonce = internalSmtpCommitCandidateOwnerNonce

smtpCommitCandidateFencingToken :: SmtpCommitCandidate payload -> FencingToken
smtpCommitCandidateFencingToken = internalSmtpCommitCandidateFencingToken

normalizedInventory
  :: SmtpKeyInventoryBound
  -> SmtpKeyInventoryObservation
  -> Either SmtpKeyRepairRefusal [SmtpAccessKeyId]
normalizedInventory bound observation = case observation of
  SmtpKeyInventoryPending detail -> Left (SmtpInventoryPending detail)
  SmtpKeyInventoryUnobservable detail -> Left (SmtpInventoryUnobservable detail)
  SmtpKeyInventoryOverBound actual maximumCardinality ->
    Left (SmtpInventoryOverBound actual maximumCardinality)
  SmtpKeyInventoryObserved keyIds -> do
    let actual = length keyIds
        maximumCardinality = smtpKeyInventoryMaximum bound
    when
      (actual > maximumCardinality)
      (Left (SmtpInventoryOverBound (fromIntegral actual) (fromIntegral maximumCardinality)))
    rejectDuplicateKeys keyIds
    pure (sort keyIds)

rejectDuplicateKeys
  :: [SmtpAccessKeyId] -> Either SmtpKeyRepairRefusal ()
rejectDuplicateKeys = go Map.empty
 where
  go _ [] = Right ()
  go seen (keyId : remaining)
    | Map.member keyId seen = Left (SmtpInventoryDuplicateKey keyId)
    | otherwise = go (Map.insert keyId () seen) remaining

validateSmtpIntervals
  :: AuthorityDuration
  -> [AuthorityTime]
  -> Either SmtpKeyRepairRefusal ()
validateSmtpIntervals visibility times = case times of
  earlier : later : remaining
    | later < addAuthorityDuration earlier visibility ->
        Left (SmtpStableObservationsTooClose earlier later visibility)
    | otherwise -> validateSmtpIntervals visibility (later : remaining)
  _ -> Right ()
