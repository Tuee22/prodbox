{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TupleSections #-}

-- | Effectful, exception-safe interpreter around the pure SMTP IAM-key repair
-- state machine.  Every external boundary is injected: retained Model-B CAS,
-- authority time/waiting, IAM inventory, IAM delete/create, and fresh lease
-- permit acquisition.  The interpreter never retries key creation.
module Prodbox.Lifecycle.SmtpKeyRepairInterpreter
  ( SmtpKeyCommitFailure (..)
  , SmtpKeyCommitPostconditionFailure (..)
  , SmtpKeyRepairExecutionError (..)
  , SmtpKeyRepairInterpreter (..)
  , SmtpKeyRepairOutcome (..)
  , SmtpKeyRepairRequest (..)
  , runSmtpKeyRepairWith
  , smtpKeyRepairOutcomeCredential
  )
where

import Control.Monad.Catch
  ( ExitCase (..)
  , MonadMask
  , generalBracket
  )
import Data.ByteString (ByteString)
import Data.Text (Text)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBLeaseGuard
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , FencedCommitPermit
  , LeasePolicy
  , addAuthorityDuration
  , leasePolicyProviderVisibilityGrace
  , leasePolicyStableObservationCount
  , modelBLeaseGuardFromPermit
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpAccessKeyId
  , SmtpCommittedProjection
  , SmtpCommittedProjectionCodecError
  , SmtpKeyCleanupResult (..)
  , SmtpKeyCreateAction
  , SmtpKeyInventoryBound
  , SmtpKeyInventoryObservation
  , SmtpKeyRepairPlan (..)
  , SmtpKeyRepairRefusal (..)
  , SmtpRepairContinuation (..)
  , StableSmtpInventoryWitness
  , TimedSmtpKeyInventoryObservation (..)
  , acceptCreatedSmtpCredential
  , authorizeSmtpKeyCreation
  , committedSmtpCredentialGeneration
  , committedSmtpCredentialKeyId
  , confirmSmtpKeyCleanup
  , confirmSmtpReuseAfterCleanup
  , encodeSmtpCommittedProjection
  , mkCommittedSmtpCredential
  , planSmtpKeyRepair
  , proveStableSmtpInventory
  , smtpCommitCandidateDigest
  , smtpCommitCandidateGeneration
  , smtpCommitCandidateKeyId
  , smtpCommitCandidateMaterial
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetCommitValueError
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  )

data SmtpKeyRepairInterpreter m = SmtpKeyRepairInterpreter
  { smtpKeyRepairModelB :: !(ModelBCasAdapter 'ClusterRetained m SmtpCommittedProjection)
  , smtpKeyRepairAuthorityNow :: !(m (Either Text AuthorityTime))
  , smtpKeyRepairWaitUntil :: !(AuthorityTime -> m (Either Text ()))
  , smtpKeyRepairObserveInventory :: !(m SmtpKeyInventoryObservation)
  , smtpKeyRepairDeleteKey :: !(SmtpAccessKeyId -> m SmtpKeyCleanupResult)
  , smtpKeyRepairFreshFencedPermit :: !(m (Either Text FencedCommitPermit))
  , smtpKeyRepairCreateKey
      :: !( SmtpKeyCreateAction
            -> m (Either Text (SmtpAccessKeyId, ByteString))
          )
  , smtpKeyRepairDigestMaterial :: !(ByteString -> TargetValueDigest)
  }

data SmtpKeyRepairRequest = SmtpKeyRepairRequest
  { smtpKeyRepairProjectionCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , smtpKeyRepairLeaseCoordinate :: !(ModelBObjectCoordinate 'ClusterRetained)
  , smtpKeyRepairInventoryBound :: !SmtpKeyInventoryBound
  , smtpKeyRepairLeasePolicy :: !LeasePolicy
  }
  deriving (Eq, Show)

data SmtpKeyRepairOutcome
  = SmtpKeyRepairReused !SmtpCommittedProjection
  | SmtpKeyRepairCreated !SmtpCommittedProjection
  deriving (Eq)

-- Do not render recoverable access-key material into diagnostics.
instance Show SmtpKeyRepairOutcome where
  show outcome = case outcome of
    SmtpKeyRepairReused committed ->
      "SmtpKeyRepairReused "
        ++ show (committedSmtpCredentialKeyId committed)
        ++ " <material-redacted>"
    SmtpKeyRepairCreated committed ->
      "SmtpKeyRepairCreated "
        ++ show (committedSmtpCredentialKeyId committed)
        ++ " <material-redacted>"

smtpKeyRepairOutcomeCredential
  :: SmtpKeyRepairOutcome -> SmtpCommittedProjection
smtpKeyRepairOutcomeCredential outcome = case outcome of
  SmtpKeyRepairReused committed -> committed
  SmtpKeyRepairCreated committed -> committed

data SmtpKeyCommitFailure
  = SmtpKeyCommitConflict
  | SmtpKeyCommitRefusedCorrupt !Text
  | SmtpKeyCommitUnobservable !Text
  | SmtpKeyCommitProjectionInvalid !SmtpCommittedProjectionCodecError
  deriving (Eq, Show)

data SmtpKeyCommitPostconditionFailure
  = SmtpKeyCommitPostconditionMissing
  | SmtpKeyCommitPostconditionVersionMismatch
      !ModelBObjectVersion
      !ModelBObjectVersion
  | SmtpKeyCommitPostconditionProjectionMismatch
  | SmtpKeyCommitPostconditionCorrupt !Text
  | SmtpKeyCommitPostconditionUnobservable !Text
  deriving (Eq, Show)

data SmtpKeyRepairExecutionError
  = SmtpKeyRepairProjectionCorrupt !Text
  | SmtpKeyRepairProjectionUnobservable !Text
  | SmtpKeyRepairPlanRefused !SmtpKeyRepairRefusal
  | SmtpKeyRepairCleanupRefused
      ![SmtpKeyCleanupResult]
      !SmtpKeyRepairRefusal
  | SmtpKeyRepairAuthorityClockUnobservable !Text
  | SmtpKeyRepairWaitFailed !Text
  | SmtpKeyRepairStableInventoryRefused !SmtpKeyRepairRefusal
  | SmtpKeyRepairGenerationInvalid !TargetCommitValueError
  | SmtpKeyRepairFreshPermitFailed !Text
  | SmtpKeyRepairCreateFailed !Text
  | SmtpKeyRepairCommitFailed !SmtpKeyCommitFailure
  | SmtpKeyRepairCommitFailedAndCleanupRefused
      !SmtpKeyCommitFailure
      !SmtpKeyCleanupResult
      !SmtpKeyRepairRefusal
  | SmtpKeyRepairCommitPostconditionFailed
      !SmtpKeyCommitPostconditionFailure
  deriving (Eq, Show)

data LoadedSmtpProjection
  = LoadedSmtpProjectionMissing
  | LoadedSmtpProjectionObserved
      !ModelBObjectVersion
      !SmtpCommittedProjection

data CreatedCommitResult
  = CreatedCreateFailed !Text
  | CreatedCommitSucceeded !SmtpKeyRepairOutcome
  | CreatedCommitNotApplied !SmtpKeyCommitFailure
  | CreatedCommitUnconfirmed !SmtpKeyCommitPostconditionFailure

data CreatedCleanupFailure = CreatedCleanupFailure
  { createdCleanupResult :: !SmtpKeyCleanupResult
  , createdCleanupRefusal :: !SmtpKeyRepairRefusal
  }

-- | Execute one complete repair transaction.  Creation is reachable only
-- after stable expected inventory and one freshly acquired fenced permit.  A
-- created key is bracketed immediately: explicit pre-commit failure, CAS
-- conflict/failure, synchronous exception, or asynchronous interruption runs
-- the injected delete before control leaves the interpreter.  Once CAS reports
-- Applied, an unobservable postcondition is deliberately not compensated: the
-- key may already be committed, so deleting it would corrupt retained state.
runSmtpKeyRepairWith
  :: (MonadMask m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> m (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
runSmtpKeyRepairWith interpreter request = do
  observedProjection <-
    modelBObserve
      (smtpKeyRepairModelB interpreter)
      (smtpKeyRepairProjectionCoordinate request)
  case loadProjection observedProjection of
    Left err -> pure (Left err)
    Right loaded -> do
      inventory <- smtpKeyRepairObserveInventory interpreter
      let plan =
            planSmtpKeyRepair
              (smtpKeyRepairInventoryBound request)
              inventory
              (loadedCommittedProjection loaded)
      runRepairPlan interpreter request loaded plan

loadProjection
  :: ModelBObservation SmtpCommittedProjection
  -> Either SmtpKeyRepairExecutionError LoadedSmtpProjection
loadProjection observation = case observation of
  ModelBMissing -> Right LoadedSmtpProjectionMissing
  ModelBObserved version committed ->
    Right (LoadedSmtpProjectionObserved version committed)
  ModelBCorrupt detail -> Left (SmtpKeyRepairProjectionCorrupt detail)
  ModelBUnobservable detail -> Left (SmtpKeyRepairProjectionUnobservable detail)

loadedCommittedProjection
  :: LoadedSmtpProjection -> Maybe SmtpCommittedProjection
loadedCommittedProjection loaded = case loaded of
  LoadedSmtpProjectionMissing -> Nothing
  LoadedSmtpProjectionObserved _ committed -> Just committed

runRepairPlan
  :: (MonadMask m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> LoadedSmtpProjection
  -> SmtpKeyRepairPlan ByteString
  -> m (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
runRepairPlan interpreter request loaded plan = case plan of
  SmtpReuseCommitted committed ->
    pure (Right (SmtpKeyRepairReused committed))
  SmtpKeyRepairRefused refusal ->
    pure (Left (SmtpKeyRepairPlanRefused refusal))
  SmtpAwaitStableInventory continuation ->
    continueAfterStableInventory interpreter request loaded continuation
  SmtpDeleteKeys keyIds _ -> do
    cleanupResults <- mapM (smtpKeyRepairDeleteKey interpreter) keyIds
    case confirmSmtpKeyCleanup plan cleanupResults of
      Left refusal ->
        pure
          ( Left
              (SmtpKeyRepairCleanupRefused cleanupResults refusal)
          )
      Right (SmtpAwaitStableInventory confirmedContinuation) ->
        continueAfterStableInventory
          interpreter
          request
          loaded
          confirmedContinuation
      Right _ ->
        pure
          ( Left
              (SmtpKeyRepairPlanRefused SmtpCleanupPlanExpected)
          )

continueAfterStableInventory
  :: (MonadMask m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> LoadedSmtpProjection
  -> SmtpRepairContinuation ByteString
  -> m (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
continueAfterStableInventory interpreter request loaded continuation = do
  samplesResult <- collectStableInventorySamples interpreter request
  case samplesResult of
    Left err -> pure (Left err)
    Right (notBefore, samples) -> do
      let expected = expectedInventory continuation
      case proveStableSmtpInventory
        (smtpKeyRepairLeasePolicy request)
        notBefore
        (smtpKeyRepairInventoryBound request)
        expected
        samples of
        Left refusal ->
          pure (Left (SmtpKeyRepairStableInventoryRefused refusal))
        Right witness ->
          case continuation of
            SmtpReuseAfterCleanup _ ->
              pure $ case confirmSmtpReuseAfterCleanup continuation witness of
                Left refusal -> Left (SmtpKeyRepairStableInventoryRefused refusal)
                Right committed -> Right (SmtpKeyRepairReused committed)
            SmtpCreateAfterStableAbsence ->
              createAndCommit interpreter request loaded continuation witness

expectedInventory
  :: SmtpRepairContinuation ByteString -> [SmtpAccessKeyId]
expectedInventory continuation = case continuation of
  SmtpReuseAfterCleanup committed -> [committedSmtpCredentialKeyId committed]
  SmtpCreateAfterStableAbsence -> []

collectStableInventorySamples
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> m
       ( Either
           SmtpKeyRepairExecutionError
           (AuthorityTime, [TimedSmtpKeyInventoryObservation])
       )
collectStableInventorySamples interpreter request = do
  startedResult <- smtpKeyRepairAuthorityNow interpreter
  case startedResult of
    Left detail ->
      pure (Left (SmtpKeyRepairAuthorityClockUnobservable detail))
    Right startedAt -> do
      let visibility =
            leasePolicyProviderVisibilityGrace
              (smtpKeyRepairLeasePolicy request)
          notBefore = addAuthorityDuration startedAt visibility
      firstWait <- smtpKeyRepairWaitUntil interpreter notBefore
      case firstWait of
        Left detail -> pure (Left (SmtpKeyRepairWaitFailed detail))
        Right () -> do
          samples <-
            collectSamples
              interpreter
              visibility
              (leasePolicyStableObservationCount (smtpKeyRepairLeasePolicy request))
          pure (fmap (notBefore,) samples)

collectSamples
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> AuthorityDuration
  -> Int
  -> m (Either SmtpKeyRepairExecutionError [TimedSmtpKeyInventoryObservation])
collectSamples interpreter visibility sampleCount = go sampleCount
 where
  go remaining
    | remaining <= 0 = pure (Right [])
    | otherwise = do
        nowResult <- smtpKeyRepairAuthorityNow interpreter
        case nowResult of
          Left detail ->
            pure (Left (SmtpKeyRepairAuthorityClockUnobservable detail))
          Right observedAt -> do
            observation <- smtpKeyRepairObserveInventory interpreter
            let sample = TimedSmtpKeyInventoryObservation observedAt observation
            if remaining == 1
              then pure (Right [sample])
              else do
                waited <-
                  smtpKeyRepairWaitUntil
                    interpreter
                    (addAuthorityDuration observedAt visibility)
                case waited of
                  Left detail -> pure (Left (SmtpKeyRepairWaitFailed detail))
                  Right () -> fmap (fmap (sample :)) (go (remaining - 1))

createAndCommit
  :: (MonadMask m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> LoadedSmtpProjection
  -> SmtpRepairContinuation ByteString
  -> StableSmtpInventoryWitness
  -> m (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
createAndCommit interpreter request loaded continuation witness = do
  permitResult <- smtpKeyRepairFreshFencedPermit interpreter
  case permitResult of
    Left detail -> pure (Left (SmtpKeyRepairFreshPermitFailed detail))
    Right permit ->
      case nextCredentialGeneration loaded of
        Left err -> pure (Left err)
        Right generation ->
          case authorizeSmtpKeyCreation
            permit
            generation
            continuation
            witness of
            Left refusal ->
              pure (Left (SmtpKeyRepairStableInventoryRefused refusal))
            Right createAction ->
              createBracketed interpreter request loaded permit createAction

nextCredentialGeneration
  :: LoadedSmtpProjection
  -> Either SmtpKeyRepairExecutionError CredentialGeneration
nextCredentialGeneration loaded =
  let nextValue = case loaded of
        LoadedSmtpProjectionMissing -> 1
        LoadedSmtpProjectionObserved _ committed ->
          credentialGenerationValue
            (committedSmtpCredentialGeneration committed)
            + 1
   in either
        (Left . SmtpKeyRepairGenerationInvalid)
        Right
        (mkCredentialGeneration nextValue)

createBracketed
  :: (MonadMask m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> LoadedSmtpProjection
  -> FencedCommitPermit
  -> SmtpKeyCreateAction
  -> m (Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome)
createBracketed interpreter request loaded permit createAction = do
  (commitResult, maybeCleanupFailure) <-
    generalBracket
      (smtpKeyRepairCreateKey interpreter createAction)
      (releaseCreatedKey interpreter)
      (commitCreatedKey interpreter request loaded permit createAction)
  pure (interpretCreatedCommitResult commitResult maybeCleanupFailure)

releaseCreatedKey
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> Either Text (SmtpAccessKeyId, ByteString)
  -> ExitCase CreatedCommitResult
  -> m (Maybe CreatedCleanupFailure)
releaseCreatedKey interpreter acquired exitCase = case acquired of
  Left _ -> pure Nothing
  Right (keyId, _) ->
    if createdKeyMustBeDeleted exitCase
      then deleteCreatedKey interpreter keyId
      else pure Nothing

createdKeyMustBeDeleted :: ExitCase CreatedCommitResult -> Bool
createdKeyMustBeDeleted exitCase = case exitCase of
  ExitCaseSuccess (CreatedCreateFailed _) -> False
  ExitCaseSuccess (CreatedCommitSucceeded _) -> False
  ExitCaseSuccess (CreatedCommitUnconfirmed _) -> False
  ExitCaseSuccess (CreatedCommitNotApplied _) -> True
  ExitCaseException _ -> True
  ExitCaseAbort -> True

deleteCreatedKey
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> SmtpAccessKeyId
  -> m (Maybe CreatedCleanupFailure)
deleteCreatedKey interpreter keyId = do
  result <- smtpKeyRepairDeleteKey interpreter keyId
  let plan = SmtpDeleteKeys [keyId] SmtpCreateAfterStableAbsence
  pure $ case confirmSmtpKeyCleanup plan [result] of
    Left refusal -> Just (CreatedCleanupFailure result refusal)
    Right _ -> Nothing

commitCreatedKey
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> LoadedSmtpProjection
  -> FencedCommitPermit
  -> SmtpKeyCreateAction
  -> Either Text (SmtpAccessKeyId, ByteString)
  -> m CreatedCommitResult
commitCreatedKey interpreter request loaded permit createAction acquired =
  case acquired of
    Left detail -> pure (CreatedCreateFailed detail)
    Right (keyId, material) -> do
      let candidate =
            acceptCreatedSmtpCredential
              (smtpKeyRepairDigestMaterial interpreter)
              createAction
              keyId
              material
          committed =
            mkCommittedSmtpCredential
              (smtpCommitCandidateKeyId candidate)
              (smtpCommitCandidateGeneration candidate)
              (smtpCommitCandidateDigest candidate)
              (Just (smtpCommitCandidateMaterial candidate))
      case encodeSmtpCommittedProjection committed of
        Left codecError ->
          pure
            ( CreatedCommitNotApplied
                (SmtpKeyCommitProjectionInvalid codecError)
            )
        Right _ -> do
          let guard =
                modelBLeaseGuardFromPermit
                  (smtpKeyRepairLeaseCoordinate request)
                  permit
              casRequest =
                committedProjectionCasRequest
                  (smtpKeyRepairProjectionCoordinate request)
                  guard
                  loaded
                  committed
          casResult <-
            modelBCompareAndSwap
              (smtpKeyRepairModelB interpreter)
              casRequest
          case casResult of
            ModelBCasApplied version _ ->
              confirmCommittedProjection
                interpreter
                request
                version
                committed
            ModelBCasConflict _ ->
              pure (CreatedCommitNotApplied SmtpKeyCommitConflict)
            ModelBCasRefusedCorrupt detail ->
              pure
                ( CreatedCommitNotApplied
                    (SmtpKeyCommitRefusedCorrupt detail)
                )
            ModelBCasUnobservable detail ->
              pure
                ( CreatedCommitNotApplied
                    (SmtpKeyCommitUnobservable detail)
                )

committedProjectionCasRequest
  :: ModelBObjectCoordinate 'ClusterRetained
  -> ModelBLeaseGuard
  -> LoadedSmtpProjection
  -> SmtpCommittedProjection
  -> ModelBCasRequest 'ClusterRetained SmtpCommittedProjection
committedProjectionCasRequest coordinate guard loaded committed = case loaded of
  LoadedSmtpProjectionMissing ->
    ModelBInitializeGuarded coordinate guard committed
  LoadedSmtpProjectionObserved version _ ->
    ModelBReplaceGuarded coordinate version guard committed

confirmCommittedProjection
  :: (Monad m)
  => SmtpKeyRepairInterpreter m
  -> SmtpKeyRepairRequest
  -> ModelBObjectVersion
  -> SmtpCommittedProjection
  -> m CreatedCommitResult
confirmCommittedProjection interpreter request expectedVersion expectedProjection = do
  observation <-
    modelBObserve
      (smtpKeyRepairModelB interpreter)
      (smtpKeyRepairProjectionCoordinate request)
  pure $ case observation of
    ModelBMissing ->
      CreatedCommitUnconfirmed SmtpKeyCommitPostconditionMissing
    ModelBObserved actualVersion actualProjection
      | actualVersion /= expectedVersion ->
          CreatedCommitUnconfirmed
            ( SmtpKeyCommitPostconditionVersionMismatch
                expectedVersion
                actualVersion
            )
      | actualProjection /= expectedProjection ->
          CreatedCommitUnconfirmed SmtpKeyCommitPostconditionProjectionMismatch
      | otherwise ->
          CreatedCommitSucceeded (SmtpKeyRepairCreated expectedProjection)
    ModelBCorrupt detail ->
      CreatedCommitUnconfirmed (SmtpKeyCommitPostconditionCorrupt detail)
    ModelBUnobservable detail ->
      CreatedCommitUnconfirmed (SmtpKeyCommitPostconditionUnobservable detail)

interpretCreatedCommitResult
  :: CreatedCommitResult
  -> Maybe CreatedCleanupFailure
  -> Either SmtpKeyRepairExecutionError SmtpKeyRepairOutcome
interpretCreatedCommitResult commitResult maybeCleanupFailure =
  case (commitResult, maybeCleanupFailure) of
    (CreatedCreateFailed detail, _) ->
      Left (SmtpKeyRepairCreateFailed detail)
    (CreatedCommitSucceeded outcome, Nothing) -> Right outcome
    (CreatedCommitSucceeded _, Just cleanupFailure) ->
      Left
        ( SmtpKeyRepairCleanupRefused
            [createdCleanupResult cleanupFailure]
            (createdCleanupRefusal cleanupFailure)
        )
    (CreatedCommitUnconfirmed failure, _) ->
      Left (SmtpKeyRepairCommitPostconditionFailed failure)
    (CreatedCommitNotApplied failure, Nothing) ->
      Left (SmtpKeyRepairCommitFailed failure)
    (CreatedCommitNotApplied failure, Just cleanupFailure) ->
      Left
        ( SmtpKeyRepairCommitFailedAndCleanupRefused
            failure
            (createdCleanupResult cleanupFailure)
            (createdCleanupRefusal cleanupFailure)
        )
