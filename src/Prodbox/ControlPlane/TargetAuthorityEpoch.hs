{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One bounded, target-local epoch transition. Pending authority is never
-- the active worker projection. Retirement survives delayed preparation.
module Prodbox.ControlPlane.TargetAuthorityEpoch
  ( TargetAuthorityEpochContext
  , mkTargetAuthorityEpochContext
  , targetEpochPredecessor
  , targetEpochTarget
  , targetEpochTopology
  , targetEpochDeadline
  , TargetAuthorityEpochPreparation
  , mkTargetAuthorityEpochPreparation
  , targetEpochPreparationContext
  , targetEpochPreparationAuthority
  , TargetAuthorityEpochTransition (..)
  , TargetAuthorityEpochRecord
  , initialTargetAuthorityEpochRecord
  , restoreTargetAuthorityEpochRecord
  , targetEpochRecordTarget
  , targetEpochRecordActive
  , targetEpochWorkerAuthority
  , targetEpochRecordRetiredThrough
  , targetEpochRecordTransition
  , TargetAuthorityEpochAction (..)
  , TargetAuthorityEpochRefusal (..)
  , validateTargetAuthorityEpochRecord
  , stepTargetAuthorityEpoch
  , advanceOrdinaryTargetAuthority
  , renderTargetAuthorityEpochRefusal
  )
where

import Control.Monad (unless)
import Data.Foldable (for_)
import Data.Text (Text)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , AcceptedTargetAuthorityAdvanceError
  , acceptedTargetAuthorityEpoch
  , acceptedTargetId
  , validateAcceptedTargetAuthorityAdvance
  )
import Prodbox.Lifecycle.Authority.EpochTopology (CutoverDigest, cutoverDigestText, mkCutoverDigest)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)

data TargetAuthorityEpochContext = TargetAuthorityEpochContext
  { targetEpochPredecessor :: !Word
  , targetEpochTarget :: !Word
  , targetEpochTopology :: !CutoverDigest
  , targetEpochDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

mkTargetAuthorityEpochContext
  :: Word
  -> Word
  -> CutoverDigest
  -> AuthorityTime
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochContext
mkTargetAuthorityEpochContext predecessor target topology deadline
  | predecessor == 0 || target <= predecessor = Left TargetEpochInvalidContext
  | mkCutoverDigest (cutoverDigestText topology) /= Just topology = Left TargetEpochInvalidContext
  | authorityTimeMicros deadline == 0 = Left TargetEpochInvalidContext
  | otherwise = Right (TargetAuthorityEpochContext predecessor target topology deadline)

data TargetAuthorityEpochPreparation = TargetAuthorityEpochPreparation
  { targetEpochPreparationContext :: !TargetAuthorityEpochContext
  , targetEpochPreparationAuthority :: !AcceptedTargetAuthority
  }
  deriving stock (Eq, Show)

mkTargetAuthorityEpochPreparation
  :: TargetAuthorityEpochContext
  -> AcceptedTargetAuthority
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochPreparation
mkTargetAuthorityEpochPreparation context desired
  | acceptedTargetAuthorityEpoch desired /= coordinateEpoch (targetEpochTarget context) =
      Left TargetEpochAuthorityEpochMismatch
  | otherwise = Right (TargetAuthorityEpochPreparation context desired)

data TargetAuthorityEpochTransition
  = TargetEpochNoTransition
  | TargetEpochPrepared !TargetAuthorityEpochPreparation
  | TargetEpochPromoted !TargetAuthorityEpochPreparation
  | TargetEpochRetired !TargetAuthorityEpochPreparation
  deriving stock (Eq, Show)

data TargetAuthorityEpochRecord = TargetAuthorityEpochRecord
  { targetEpochRecordTarget :: !TargetSecretId
  , targetEpochRecordActive :: !(Maybe AcceptedTargetAuthority)
  , targetEpochRecordRetiredThrough :: !Word
  , targetEpochRecordTransition :: !TargetAuthorityEpochTransition
  }
  deriving stock (Eq, Show)

initialTargetAuthorityEpochRecord
  :: TargetSecretId
  -> Maybe AcceptedTargetAuthority
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochRecord
initialTargetAuthorityEpochRecord target active =
  restoreTargetAuthorityEpochRecord target active 0 TargetEpochNoTransition

restoreTargetAuthorityEpochRecord
  :: TargetSecretId
  -> Maybe AcceptedTargetAuthority
  -> Word
  -> TargetAuthorityEpochTransition
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochRecord
restoreTargetAuthorityEpochRecord target active retired transition = do
  let record = TargetAuthorityEpochRecord target active retired transition
  validateTargetAuthorityEpochRecord record
  pure record

data TargetAuthorityEpochAction
  = PrepareTargetAuthorityEpoch !TargetAuthorityEpochPreparation
  | PromoteTargetAuthorityEpoch !TargetAuthorityEpochPreparation
  | RetireTargetAuthorityEpoch !TargetAuthorityEpochPreparation
  deriving stock (Eq, Show)

data TargetAuthorityEpochRefusal
  = TargetEpochInvalidContext
  | TargetEpochAuthorityEpochMismatch
  | TargetEpochTargetMismatch
  | TargetEpochPublishedEpochMismatch
  | TargetEpochDeadlineReached
  | TargetEpochAlreadyRetired
  | TargetEpochPreparationConflict
  | TargetEpochPreparationMissing
  | TargetEpochRequiresForwardRecovery
  | TargetEpochOrdinaryInstallFrozen
  | TargetEpochInvalidRecord
  | TargetEpochAuthorityAdvanceRefused !AcceptedTargetAuthorityAdvanceError
  deriving stock (Eq, Show)

validateTargetAuthorityEpochRecord
  :: TargetAuthorityEpochRecord -> Either TargetAuthorityEpochRefusal ()
validateTargetAuthorityEpochRecord record = do
  for_ (targetEpochRecordActive record) requireTarget
  case targetEpochRecordTransition record of
    TargetEpochNoTransition -> require (retired == 0)
    TargetEpochPrepared preparation -> do
      validatePreparation preparation
      require (retired < targetEpochTarget (context preparation))
      requirePredecessor preparation
      validateDesiredAdvance record preparation
    TargetEpochPromoted preparation -> do
      validatePreparation preparation
      require (retired < targetEpochTarget (context preparation))
      case targetEpochRecordActive record of
        Nothing -> Left TargetEpochInvalidRecord
        Just active -> do
          require
            (acceptedTargetAuthorityEpoch active == coordinateEpoch (targetEpochTarget (context preparation)))
          advance (targetEpochPreparationAuthority preparation) active
    TargetEpochRetired preparation -> do
      validatePreparation preparation
      require (retired == targetEpochTarget (context preparation))
      requirePredecessor preparation
      validateDesiredAdvance record preparation
 where
  retired = targetEpochRecordRetiredThrough record
  context = targetEpochPreparationContext
  require = flip unless (Left TargetEpochInvalidRecord)
  requireTarget accepted =
    unless
      (acceptedTargetId accepted == targetEpochRecordTarget record)
      (Left TargetEpochTargetMismatch)
  validatePreparation preparation = do
    requireTarget (targetEpochPreparationAuthority preparation)
    _ <-
      mkTargetAuthorityEpochPreparation
        (context preparation)
        (targetEpochPreparationAuthority preparation)
    pure ()
  requirePredecessor preparation = case targetEpochRecordActive record of
    Nothing -> pure ()
    Just active ->
      require
        ( acceptedTargetAuthorityEpoch active
            <= coordinateEpoch (targetEpochPredecessor (context preparation))
        )

-- | The interpreter independently observes the published authentication epoch
-- and time. No caller-supplied phase can substitute for those observations.
stepTargetAuthorityEpoch
  :: AuthorityEpoch
  -> AuthorityTime
  -> TargetAuthorityEpochAction
  -> TargetAuthorityEpochRecord
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochRecord
stepTargetAuthorityEpoch published now action record = do
  validateTargetAuthorityEpochRecord record
  unless (acceptedTargetId desired == targetEpochRecordTarget record) (Left TargetEpochTargetMismatch)
  case action of
    PrepareTargetAuthorityEpoch _ -> do
      requirePublished (targetEpochPredecessor context)
      requireLive
      unless
        (targetEpochTarget context > targetEpochRecordRetiredThrough record)
        (Left TargetEpochAlreadyRetired)
      validateDesiredAdvance record preparation
      prepare
    PromoteTargetAuthorityEpoch _ -> do
      requirePublished (targetEpochTarget context)
      requireLive
      promote
    RetireTargetAuthorityEpoch _ -> do
      requirePublished (targetEpochPredecessor context)
      retire
 where
  preparation = case action of
    PrepareTargetAuthorityEpoch value -> value
    PromoteTargetAuthorityEpoch value -> value
    RetireTargetAuthorityEpoch value -> value
  context = targetEpochPreparationContext preparation
  desired = targetEpochPreparationAuthority preparation
  requirePublished value = unless (published == coordinateEpoch value) (Left TargetEpochPublishedEpochMismatch)
  requireLive = unless (now < targetEpochDeadline context) (Left TargetEpochDeadlineReached)
  finish next = validateTargetAuthorityEpochRecord next >> pure next
  prepared retired =
    finish
      record
        { targetEpochRecordRetiredThrough = retired
        , targetEpochRecordTransition = TargetEpochPrepared preparation
        }
  prepare = case targetEpochRecordTransition record of
    TargetEpochNoTransition -> prepared (targetEpochRecordRetiredThrough record)
    TargetEpochPrepared retained
      | retained == preparation -> pure record
      | targetEpochPredecessor context >= targetEpochTarget (targetEpochPreparationContext retained) ->
          prepared
            ( max
                (targetEpochRecordRetiredThrough record)
                (targetEpochTarget (targetEpochPreparationContext retained))
            )
      | otherwise -> Left TargetEpochPreparationConflict
    TargetEpochPromoted retained
      | targetEpochTarget context > targetEpochTarget (targetEpochPreparationContext retained) ->
          prepared (targetEpochRecordRetiredThrough record)
      | otherwise -> Left TargetEpochPreparationConflict
    TargetEpochRetired _ -> prepared (targetEpochRecordRetiredThrough record)
  promote = case targetEpochRecordTransition record of
    TargetEpochPrepared retained
      | retained == preparation ->
          finish
            record
              { targetEpochRecordActive = Just desired
              , targetEpochRecordTransition = TargetEpochPromoted preparation
              }
      | otherwise -> Left TargetEpochPreparationConflict
    TargetEpochPromoted retained
      | retained == preparation -> pure record
      | otherwise -> Left TargetEpochPreparationConflict
    TargetEpochNoTransition -> Left TargetEpochPreparationMissing
    TargetEpochRetired _ -> Left TargetEpochAlreadyRetired
  retire
    | targetEpochRecordRetiredThrough record >= targetEpochTarget context = pure record
    | otherwise = case targetEpochRecordTransition record of
        TargetEpochNoTransition -> markRetired
        TargetEpochPrepared retained
          | retained == preparation -> markRetired
          | otherwise -> Left TargetEpochPreparationConflict
        TargetEpochPromoted retained
          | targetEpochTarget (targetEpochPreparationContext retained) <= targetEpochPredecessor context ->
              markRetired
          | otherwise -> Left TargetEpochRequiresForwardRecovery
        TargetEpochRetired _ -> markRetired
  markRetired =
    finish
      record
        { targetEpochRecordRetiredThrough = targetEpochTarget context
        , targetEpochRecordTransition = TargetEpochRetired preparation
        }

-- | Existing active installation may advance after promotion, but must never
-- replace the whole row and erase a pending or retired fence.
advanceOrdinaryTargetAuthority
  :: AcceptedTargetAuthority
  -> TargetAuthorityEpochRecord
  -> Either TargetAuthorityEpochRefusal TargetAuthorityEpochRecord
advanceOrdinaryTargetAuthority desired record = do
  validateTargetAuthorityEpochRecord record
  unless (acceptedTargetId desired == targetEpochRecordTarget record) (Left TargetEpochTargetMismatch)
  case targetEpochRecordTransition record of
    TargetEpochPrepared _ -> Left TargetEpochOrdinaryInstallFrozen
    TargetEpochRetired _ -> Left TargetEpochOrdinaryInstallFrozen
    TargetEpochNoTransition -> install
    TargetEpochPromoted _ -> case targetEpochRecordActive record of
      Just active
        | acceptedTargetAuthorityEpoch desired == acceptedTargetAuthorityEpoch active -> install
      _ -> Left TargetEpochAuthorityEpochMismatch
 where
  install = do
    case targetEpochRecordActive record of
      Nothing -> pure ()
      Just current -> advance current desired
    let next = record {targetEpochRecordActive = Just desired}
    validateTargetAuthorityEpochRecord next
    pure next

-- | The retained predecessor remains available for recovery, but neither old
-- nor future workers receive authority while preparation/retirement is frozen.
-- Omitting the legacy field also closes workers from the prior image.
targetEpochWorkerAuthority :: TargetAuthorityEpochRecord -> Maybe AcceptedTargetAuthority
targetEpochWorkerAuthority record = case targetEpochRecordTransition record of
  TargetEpochNoTransition -> targetEpochRecordActive record
  TargetEpochPrepared _ -> Nothing
  TargetEpochPromoted _ -> targetEpochRecordActive record
  TargetEpochRetired _ -> Nothing

validateDesiredAdvance
  :: TargetAuthorityEpochRecord
  -> TargetAuthorityEpochPreparation
  -> Either TargetAuthorityEpochRefusal ()
validateDesiredAdvance record preparation = case targetEpochRecordActive record of
  Nothing -> pure ()
  Just current -> advance current (targetEpochPreparationAuthority preparation)

advance
  :: AcceptedTargetAuthority -> AcceptedTargetAuthority -> Either TargetAuthorityEpochRefusal ()
advance current desired =
  either
    (Left . TargetEpochAuthorityAdvanceRefused)
    Right
    (validateAcceptedTargetAuthorityAdvance current desired)

coordinateEpoch :: Word -> AuthorityEpoch
coordinateEpoch = AuthorityEpoch . fromIntegral

renderTargetAuthorityEpochRefusal :: TargetAuthorityEpochRefusal -> Text
renderTargetAuthorityEpochRefusal refusal = case refusal of
  TargetEpochInvalidContext -> "context-invalid"
  TargetEpochAuthorityEpochMismatch -> "authority-epoch-mismatch"
  TargetEpochTargetMismatch -> "target-mismatch"
  TargetEpochPublishedEpochMismatch -> "published-epoch-mismatch"
  TargetEpochDeadlineReached -> "deadline-reached"
  TargetEpochAlreadyRetired -> "epoch-retired"
  TargetEpochPreparationConflict -> "preparation-conflict"
  TargetEpochPreparationMissing -> "preparation-missing"
  TargetEpochRequiresForwardRecovery -> "greater-epoch-recovery-required"
  TargetEpochOrdinaryInstallFrozen -> "ordinary-install-frozen"
  TargetEpochInvalidRecord -> "record-invalid"
  TargetEpochAuthorityAdvanceRefused _ -> "authority-advance-refused"
