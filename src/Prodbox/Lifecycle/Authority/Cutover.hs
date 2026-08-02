{-# LANGUAGE DerivingStrategies #-}

-- | Restart-safe orchestration of the authority-epoch cutover.
--
-- Every effect is injected and closed over the finite projection/binding
-- inventories.  The sequence imports and completes the legacy projections,
-- obtains a stable shadow proof, suspends and reads back every legacy writer,
-- proves the shadow digest did not move, durably freezes admission, prepares
-- and reads back every binding, activates one replacement epoch, and finally
-- re-observes that exact epoch.  No step dual-writes and an activation response
-- is never accepted without the authoritative read-back.
module Prodbox.Lifecycle.Authority.Cutover
  ( AuthorityCutoverBoundary (..)
  , AuthorityCutoverStage (..)
  , AuthorityCutoverFailure (..)
  , AuthorityCutoverResult (..)
  , requiredCutoverBindings
  , requiredCutoverProjections
  , runAuthorityCutover
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , MigrationBinding
  , MigrationCommand (..)
  , MigrationDecision (..)
  , MigrationDigest
  , MigrationEpoch
  , MigrationProjection
  , MigrationRefusal
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( ProjectionShadowProof
  , projectionShadowDigest
  )

data AuthorityCutoverBoundary m = AuthorityCutoverBoundary
  { cutoverObserveAuthority
      :: !(m (Either Text MigrationAuthorityStatus))
  , cutoverImportProjection
      :: !(MigrationProjection -> m (Either Text ()))
  , cutoverCompleteImports
      :: !(m (Either Text ()))
  , cutoverObserveShadow
      :: !(m (Either Text ProjectionShadowProof))
  , cutoverSuspendLegacyWritersAndReadBack
      :: !(MigrationDigest -> m (Either Text ()))
  , cutoverPrepareBindingAndReadBack
      :: !(MigrationBinding -> m (Either Text ()))
  , cutoverApplyMigration
      :: !(MigrationCommand -> m (Either Text MigrationDecision))
  }

data AuthorityCutoverStage
  = CutoverInitialObservation
  | CutoverImport !MigrationProjection
  | CutoverCompleteImports
  | CutoverInitialShadow
  | CutoverVerifyShadow
  | CutoverSuspendLegacy
  | CutoverPostSuspendShadow
  | CutoverFreeze
  | CutoverFrozenReadback
  | CutoverPostFreezeShadow
  | CutoverPreparePhysical !MigrationBinding
  | CutoverRecordPrepared !MigrationBinding
  | CutoverActivate
  | CutoverActivatedReadback
  deriving stock (Eq, Show)

data AuthorityCutoverFailure
  = AuthorityCutoverEffectFailed !AuthorityCutoverStage !Text
  | AuthorityCutoverMigrationRefused
      !AuthorityCutoverStage
      !MigrationRefusal
  | AuthorityCutoverShadowChanged
      !AuthorityCutoverStage
      !MigrationDigest
      !MigrationDigest
  | AuthorityCutoverStatusMismatch
      !AuthorityCutoverStage
      !MigrationAuthorityStatus
  | AuthorityCutoverEpochConflict !MigrationEpoch
  deriving stock (Eq, Show)

data AuthorityCutoverResult
  = AuthorityCutoverActivated !MigrationEpoch !MigrationDigest
  | AuthorityCutoverAlreadyActive !MigrationEpoch
  deriving stock (Eq, Show)

requiredCutoverBindings :: [MigrationBinding]
requiredCutoverBindings = [minBound .. maxBound]

requiredCutoverProjections :: [MigrationProjection]
requiredCutoverProjections = [minBound .. maxBound]

runAuthorityCutover
  :: (Monad m)
  => AuthorityCutoverBoundary m
  -> MigrationEpoch
  -> m (Either AuthorityCutoverFailure AuthorityCutoverResult)
runAuthorityCutover boundary targetEpoch = do
  initial <- cutoverObserveAuthority boundary
  case initial of
    Left detail ->
      pure (Left (AuthorityCutoverEffectFailed CutoverInitialObservation detail))
    Right (MigrationReplacementWriterActive activeEpoch)
      | activeEpoch == targetEpoch ->
          pure (Right (AuthorityCutoverAlreadyActive activeEpoch))
      | otherwise -> pure (Left (AuthorityCutoverEpochConflict activeEpoch))
    Right _ -> runPendingCutover
 where
  runPendingCutover = do
    imported <- runProjectionImports requiredCutoverProjections
    case imported of
      Left failure -> pure (Left failure)
      Right () -> do
        completed <- cutoverCompleteImports boundary
        case completed of
          Left detail ->
            pure (Left (AuthorityCutoverEffectFailed CutoverCompleteImports detail))
          Right () -> runShadowAndFreeze

  runProjectionImports projections = case projections of
    [] -> pure (Right ())
    projection : remaining -> do
      imported <- cutoverImportProjection boundary projection
      case imported of
        Left detail ->
          pure
            ( Left
                (AuthorityCutoverEffectFailed (CutoverImport projection) detail)
            )
        Right () -> runProjectionImports remaining

  runShadowAndFreeze = do
    initialShadow <- observeShadowAt CutoverInitialShadow
    case initialShadow of
      Left failure -> pure (Left failure)
      Right proof -> do
        let digest = projectionShadowDigest proof
        verified <- applyAt CutoverVerifyShadow (VerifyShadow digest)
        case verified of
          Left failure -> pure (Left failure)
          Right () -> do
            suspended <- cutoverSuspendLegacyWritersAndReadBack boundary digest
            case suspended of
              Left detail ->
                pure (Left (AuthorityCutoverEffectFailed CutoverSuspendLegacy detail))
              Right () -> verifyPostSuspend digest

  verifyPostSuspend digest = do
    postSuspend <- observeShadowAt CutoverPostSuspendShadow
    case postSuspend of
      Left failure -> pure (Left failure)
      Right proof
        | projectionShadowDigest proof /= digest ->
            pure
              ( Left
                  ( AuthorityCutoverShadowChanged
                      CutoverPostSuspendShadow
                      digest
                      (projectionShadowDigest proof)
                  )
              )
        | otherwise -> do
            frozen <- applyAt CutoverFreeze (FreezeLegacy digest)
            case frozen of
              Left failure -> pure (Left failure)
              Right () -> verifyFrozen digest

  verifyFrozen digest = do
    status <- cutoverObserveAuthority boundary
    case status of
      Left detail ->
        pure (Left (AuthorityCutoverEffectFailed CutoverFrozenReadback detail))
      Right MigrationWritersQuiesced -> do
        postFreeze <- observeShadowAt CutoverPostFreezeShadow
        case postFreeze of
          Left failure -> pure (Left failure)
          Right proof
            | projectionShadowDigest proof /= digest ->
                pure
                  ( Left
                      ( AuthorityCutoverShadowChanged
                          CutoverPostFreezeShadow
                          digest
                          (projectionShadowDigest proof)
                      )
                  )
            | otherwise -> prepareBindings digest requiredCutoverBindings
      Right actual ->
        pure
          ( Left
              (AuthorityCutoverStatusMismatch CutoverFrozenReadback actual)
          )

  prepareBindings digest bindings = case bindings of
    [] -> activate digest
    binding : remaining -> do
      prepared <- cutoverPrepareBindingAndReadBack boundary binding
      case prepared of
        Left detail ->
          pure
            ( Left
                ( AuthorityCutoverEffectFailed
                    (CutoverPreparePhysical binding)
                    detail
                )
            )
        Right () -> do
          recorded <- applyAt (CutoverRecordPrepared binding) (PrepareBinding binding)
          case recorded of
            Left failure -> pure (Left failure)
            Right () -> prepareBindings digest remaining

  activate digest = do
    activated <- applyAt CutoverActivate (ActivateReplacement targetEpoch)
    case activated of
      Left failure -> pure (Left failure)
      Right () -> do
        status <- cutoverObserveAuthority boundary
        pure $ case status of
          Left detail ->
            Left (AuthorityCutoverEffectFailed CutoverActivatedReadback detail)
          Right (MigrationReplacementWriterActive activeEpoch)
            | activeEpoch == targetEpoch ->
                Right (AuthorityCutoverActivated activeEpoch digest)
            | otherwise -> Left (AuthorityCutoverEpochConflict activeEpoch)
          Right actual ->
            Left
              (AuthorityCutoverStatusMismatch CutoverActivatedReadback actual)

  observeShadowAt stage = do
    observed <- cutoverObserveShadow boundary
    pure $ case observed of
      Left detail -> Left (AuthorityCutoverEffectFailed stage detail)
      Right proof -> Right proof

  applyAt stage command = do
    applied <- cutoverApplyMigration boundary command
    pure $ case applied of
      Left detail -> Left (AuthorityCutoverEffectFailed stage detail)
      Right (MigrationAccepted _) -> Right ()
      Right MigrationAlreadyApplied -> Right ()
      Right (MigrationRefused refusal) ->
        Left (AuthorityCutoverMigrationRefused stage refusal)
