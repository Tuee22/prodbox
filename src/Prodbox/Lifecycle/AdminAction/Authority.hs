{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained-Authority state machine for one backup-receipted Admin Action.
--
-- Preparation obtains and validates an independent backup receipt before the
-- permit core can enter retained state.  Authorization then binds the exact
-- observed Job/Pod and signs only that envelope with the Authority key.  A
-- final receipt is accepted only when it matches the signed operation, action,
-- and Pod UID.  Every transition is an idempotent Model-B CAS.
module Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthoritySnapshot (..)
  , AdminActionAuthorityRepository (..)
  , modelBAdminActionAuthorityRepository
  , AdminActionAuthorityBoundary (..)
  , AdminActionPrepareRequest (..)
  , AdminActionPodObservation (..)
  , AdminActionAuthorityError (..)
  , prepareAdminAction
  , authorizeAdminAction
  , completeAdminAction
  , completeAdminActionForPermit
  , observeAdminAction
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionBackupReceipt
  , AdminActionExecutionState (..)
  , AdminActionJobBinding
  , AdminActionPermitCore
  , AdminActionPlan
  , AdminActionProtocolError
  , AdminActionReceipt
  , SignedAdminActionPermit
  , adminActionPermitDeadline
  , adminActionPermitImageDigest
  , adminActionPermitOperationId
  , adminActionPermitPlan
  , adminActionPermitSigningPayload
  , commitAdminActionAuthorized
  , commitAdminActionCompleted
  , commitAdminActionPrepared
  , commitAdminActionReauthorized
  , initialAdminActionExecutionState
  , mkAdminActionJobBinding
  , mkAdminActionPermitCore
  , mkSignedAdminActionPermit
  , signedAdminActionPermitBackupReceipt
  , signedAdminActionPermitBinding
  , signedAdminActionPermitCore
  , verifySignedAdminActionPermit
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , manifestPublicKeyBytes
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )

data AdminActionAuthoritySnapshot revision = AdminActionAuthoritySnapshot
  { adminActionAuthorityRevision :: !revision
  , adminActionAuthorityState :: !AdminActionExecutionState
  }
  deriving stock (Eq, Show)

data AdminActionAuthorityRepository m revision = AdminActionAuthorityRepository
  { readAdminActionAuthority
      :: m (Either Text (AdminActionAuthoritySnapshot revision))
  , compareAndSwapAdminActionAuthority
      :: revision
      -> AdminActionExecutionState
      -> m (Either Text ())
  }

modelBAdminActionAuthorityRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m AdminActionExecutionState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> AdminActionAuthorityRepository m (Maybe ModelBObjectVersion)
modelBAdminActionAuthorityRepository adapter coordinate =
  AdminActionAuthorityRepository
    { readAdminActionAuthority = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing ->
            Right
              AdminActionAuthoritySnapshot
                { adminActionAuthorityRevision = Nothing
                , adminActionAuthorityState = initialAdminActionExecutionState
                }
          ModelBObserved revision state ->
            Right
              AdminActionAuthoritySnapshot
                { adminActionAuthorityRevision = Just revision
                , adminActionAuthorityState = state
                }
          ModelBCorrupt detail -> Left ("admin action state is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("admin action state is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("admin action state is unobservable: " <> detail)
    , compareAndSwapAdminActionAuthority = \expected state -> do
        result <-
          modelBCompareAndSwap adapter $ case expected of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        pure $ case result of
          ModelBCasApplied _ _ -> Right ()
          ModelBCasConflict _ -> Left "admin action CAS conflict"
          ModelBCasRefusedCorrupt detail -> Left ("admin action CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("admin action CAS is not ready: " <> detail)
          ModelBCasUnobservable detail -> Left ("admin action CAS is unobservable: " <> detail)
    }

data AdminActionAuthorityBoundary m = AdminActionAuthorityBoundary
  { adminActionAuthorityScope :: !Text
  , adminActionAuthorityEndpoint :: !Text
  , adminActionAuthorityNow :: m (Either Text AuthorityTime)
  , freshAdminActionNonce :: Text -> m (Either Text Text)
  , backupAdminActionPermitCore
      :: AdminActionPermitCore
      -> m (Either Text AdminActionBackupReceipt)
  , adminActionAuthoritySigner :: AuthorityManifestSigner m
  }

data AdminActionPrepareRequest = AdminActionPrepareRequest
  { adminActionPrepareOperationId :: !Text
  , adminActionPreparePlan :: !AdminActionPlan
  , adminActionPrepareDeadlineMicros :: !Natural
  , adminActionPrepareImageDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionPodObservation = AdminActionPodObservation
  { adminActionObservedJobName :: !Text
  , adminActionObservedJobUid :: !Text
  , adminActionObservedPodName :: !Text
  , adminActionObservedPodUid :: !Text
  , adminActionObservedImageDigest :: !Text
  , adminActionObservedServiceAccount :: !Text
  , adminActionObservedServiceAccountUid :: !Text
  , adminActionObservedHeartbeatMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminActionAuthorityError
  = AdminActionAuthorityUnavailable !Text
  | AdminActionAuthorityProtocolRejected !AdminActionProtocolError
  | AdminActionAuthorityOperationMismatch
  | AdminActionAuthorityStateConflict
  | AdminActionAuthorityBackupFailed !Text
  | AdminActionAuthoritySignerFailed !Text
  | AdminActionAuthoritySignerGenerationChanged !Natural !Natural
  | AdminActionAuthorityCommitFailed !Text
  deriving stock (Eq, Show)

prepareAdminAction
  :: (Monad m)
  => AdminActionAuthorityRepository m revision
  -> AdminActionAuthorityBoundary m
  -> AdminActionPrepareRequest
  -> m (Either AdminActionAuthorityError (AdminActionPermitCore, AdminActionBackupReceipt))
prepareAdminAction repository boundary request = do
  snapshotResult <- readAdminActionAuthority repository
  case snapshotResult of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case preparedValue (adminActionAuthorityState snapshot) of
      Just existing
        | requestMatchesCore request (fst existing) -> pure (Right existing)
        | otherwise -> pure (Left AdminActionAuthorityStateConflict)
      Nothing -> case adminActionAuthorityState snapshot of
        AdminActionExecutionIdle -> prepareFresh snapshot
        _ -> pure (Left AdminActionAuthorityStateConflict)
 where
  prepareFresh snapshot = do
    nonceResult <- freshAdminActionNonce boundary (adminActionPrepareOperationId request)
    case nonceResult of
      Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
      Right nonce -> case makeCore nonce of
        Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
        Right core -> do
          backupResult <- backupAdminActionPermitCore boundary core
          case backupResult of
            Left detail -> pure (Left (AdminActionAuthorityBackupFailed detail))
            Right backup -> case commitAdminActionPrepared core backup initialAdminActionExecutionState of
              Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
              Right state -> do
                committed <-
                  compareAndSwapAdminActionAuthority
                    repository
                    (adminActionAuthorityRevision snapshot)
                    state
                pure $ case committed of
                  Left detail -> Left (AdminActionAuthorityCommitFailed detail)
                  Right () -> Right (core, backup)
  makeCore nonce =
    mkAdminActionPermitCore
      (adminActionPrepareOperationId request)
      (adminActionAuthorityScope boundary)
      (adminActionAuthorityEndpoint boundary)
      (adminActionPreparePlan request)
      nonce
      (authorityTimeFromRequest request)
      (adminActionPrepareImageDigest request)

authorizeAdminAction
  :: (Monad m)
  => AdminActionAuthorityRepository m revision
  -> AdminActionAuthorityBoundary m
  -> Text
  -> AdminActionPodObservation
  -> m (Either AdminActionAuthorityError SignedAdminActionPermit)
authorizeAdminAction repository boundary operationId observation = do
  snapshotResult <- readAdminActionAuthority repository
  case snapshotResult of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case adminActionAuthorityState snapshot of
      AdminActionExecutionAuthorized permit ->
        case existingAuthorized operationId observation permit of
          Right existing -> pure (Right existing)
          Left AdminActionAuthorityStateConflict ->
            authorizeSuccessor snapshot permit
          Left err -> pure (Left err)
      AdminActionExecutionCompleted permit _ ->
        pure (existingAuthorized operationId observation permit)
      AdminActionExecutionPrepared core backup
        | adminActionPermitOperationId core /= operationId ->
            pure (Left AdminActionAuthorityOperationMismatch)
        | otherwise -> authorizeFresh snapshot core backup
      _ -> pure (Left AdminActionAuthorityStateConflict)
 where
  authorizeFresh snapshot core backup = do
    authorizeWith
      snapshot
      core
      backup
      (commitAdminActionAuthorized)
  authorizeSuccessor snapshot existing =
    let core = signedAdminActionPermitCore existing
        backup = signedAdminActionPermitBackupReceipt existing
     in if adminActionPermitOperationId core /= operationId
          then pure (Left AdminActionAuthorityOperationMismatch)
          else
            authorizeWith
              snapshot
              core
              backup
              commitAdminActionReauthorized
  authorizeWith snapshot core backup commitAuthorized = do
    nowResult <- adminActionAuthorityNow boundary
    case nowResult of
      Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
      Right now -> case bindingFor core observation of
        Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
        Right binding -> do
          publicResult <- readAuthorityManifestPublicKey signer
          case publicResult of
            Left detail -> pure (Left (AdminActionAuthoritySignerFailed detail))
            Right (publicGeneration, publicKey) -> do
              signatureResult <-
                signAuthorityManifestPayload
                  signer
                  (adminActionPermitSigningPayload publicGeneration core backup binding)
              case signatureResult of
                Left detail -> pure (Left (AdminActionAuthoritySignerFailed detail))
                Right (signatureGeneration, signature)
                  | signatureGeneration /= publicGeneration ->
                      pure
                        ( Left
                            ( AdminActionAuthoritySignerGenerationChanged
                                publicGeneration
                                signatureGeneration
                            )
                        )
                  | otherwise -> case makePermit now publicGeneration publicKey core backup binding signature of
                      Left err -> pure (Left err)
                      Right permit -> case commitAuthorized permit (adminActionAuthorityState snapshot) of
                        Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
                        Right state -> do
                          committed <-
                            compareAndSwapAdminActionAuthority
                              repository
                              (adminActionAuthorityRevision snapshot)
                              state
                          pure $ case committed of
                            Left detail -> Left (AdminActionAuthorityCommitFailed detail)
                            Right () -> Right permit
  signer = adminActionAuthoritySigner boundary

completeAdminAction
  :: (Monad m)
  => AdminActionAuthorityRepository m revision
  -> Text
  -> AdminActionReceipt
  -> m (Either AdminActionAuthorityError AdminActionReceipt)
completeAdminAction repository operationId receipt = do
  snapshotResult <- readAdminActionAuthority repository
  case snapshotResult of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case adminActionAuthorityState snapshot of
      AdminActionExecutionCompleted permit existing
        | adminActionPermitOperationId (signedAdminActionPermitCore permit) /= operationId ->
            pure (Left AdminActionAuthorityOperationMismatch)
        | existing == receipt -> pure (Right existing)
        | otherwise -> pure (Left AdminActionAuthorityStateConflict)
      AdminActionExecutionAuthorized permit
        | adminActionPermitOperationId (signedAdminActionPermitCore permit) /= operationId ->
            pure (Left AdminActionAuthorityOperationMismatch)
        | otherwise -> case commitAdminActionCompleted receipt (adminActionAuthorityState snapshot) of
            Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
            Right state -> do
              committed <-
                compareAndSwapAdminActionAuthority
                  repository
                  (adminActionAuthorityRevision snapshot)
                  state
              pure $ case committed of
                Left detail -> Left (AdminActionAuthorityCommitFailed detail)
                Right () -> Right receipt
      _ -> pure (Left AdminActionAuthorityStateConflict)

-- | Runner-side terminal handoff.  The exact signed Job/Pod permit must still
-- be the retained current attempt at the CAS linearization point.  A stale
-- worker cannot complete a successor attempt, while response-loss replay of
-- the same permit and receipt is idempotent.
completeAdminActionForPermit
  :: (Monad m)
  => AdminActionAuthorityRepository m revision
  -> SignedAdminActionPermit
  -> AdminActionReceipt
  -> m (Either AdminActionAuthorityError AdminActionReceipt)
completeAdminActionForPermit repository suppliedPermit receipt = do
  snapshotResult <- readAdminActionAuthority repository
  case snapshotResult of
    Left detail -> pure (Left (AdminActionAuthorityUnavailable detail))
    Right snapshot -> case adminActionAuthorityState snapshot of
      AdminActionExecutionCompleted retainedPermit existing
        | retainedPermit /= suppliedPermit ->
            pure (Left AdminActionAuthorityStateConflict)
        | existing == receipt -> pure (Right existing)
        | otherwise -> pure (Left AdminActionAuthorityStateConflict)
      AdminActionExecutionAuthorized retainedPermit
        | retainedPermit /= suppliedPermit ->
            pure (Left AdminActionAuthorityStateConflict)
        | otherwise ->
            case commitAdminActionCompleted receipt (adminActionAuthorityState snapshot) of
              Left err -> pure (Left (AdminActionAuthorityProtocolRejected err))
              Right state -> do
                committed <-
                  compareAndSwapAdminActionAuthority
                    repository
                    (adminActionAuthorityRevision snapshot)
                    state
                pure $ case committed of
                  Left detail -> Left (AdminActionAuthorityCommitFailed detail)
                  Right () -> Right receipt
      _ -> pure (Left AdminActionAuthorityStateConflict)

observeAdminAction
  :: (Monad m)
  => AdminActionAuthorityRepository m revision
  -> Text
  -> m (Either AdminActionAuthorityError AdminActionExecutionState)
observeAdminAction repository operationId = do
  snapshotResult <- readAdminActionAuthority repository
  pure $ do
    snapshot <- first AdminActionAuthorityUnavailable snapshotResult
    let state = adminActionAuthorityState snapshot
    case stateOperationId state of
      Nothing -> Left AdminActionAuthorityStateConflict
      Just observed
        | observed == operationId -> Right state
        | otherwise -> Left AdminActionAuthorityOperationMismatch

preparedValue
  :: AdminActionExecutionState
  -> Maybe (AdminActionPermitCore, AdminActionBackupReceipt)
preparedValue state = case state of
  AdminActionExecutionIdle -> Nothing
  AdminActionExecutionPrepared core backup -> Just (core, backup)
  AdminActionExecutionAuthorized permit ->
    Just (signedAdminActionPermitCore permit, signedAdminActionPermitBackupReceipt permit)
  AdminActionExecutionCompleted permit _ ->
    Just (signedAdminActionPermitCore permit, signedAdminActionPermitBackupReceipt permit)

stateOperationId :: AdminActionExecutionState -> Maybe Text
stateOperationId = fmap (adminActionPermitOperationId . fst) . preparedValue

requestMatchesCore :: AdminActionPrepareRequest -> AdminActionPermitCore -> Bool
requestMatchesCore request core =
  adminActionPrepareOperationId request == adminActionPermitOperationId core
    && adminActionPreparePlan request == adminActionPermitPlan core
    && adminActionPrepareImageDigest request == adminActionPermitImageDigest core
    && adminActionPrepareDeadlineMicros request
      == authorityTimeMicros (adminActionPermitDeadline core)

bindingFor
  :: AdminActionPermitCore
  -> AdminActionPodObservation
  -> Either AdminActionProtocolError AdminActionJobBinding
bindingFor core observation =
  mkAdminActionJobBinding
    core
    (adminActionObservedJobName observation)
    (adminActionObservedJobUid observation)
    (adminActionObservedPodName observation)
    (adminActionObservedPodUid observation)
    (adminActionObservedImageDigest observation)
    (adminActionObservedServiceAccount observation)
    (adminActionObservedServiceAccountUid observation)
    (authorityTimeFromMicros (adminActionObservedHeartbeatMicros observation))

existingAuthorized
  :: Text
  -> AdminActionPodObservation
  -> SignedAdminActionPermit
  -> Either AdminActionAuthorityError SignedAdminActionPermit
existingAuthorized operationId observation permit
  | adminActionPermitOperationId core /= operationId =
      Left AdminActionAuthorityOperationMismatch
  | bindingFor core observation == Right (signedAdminActionPermitBinding permit) = Right permit
  | otherwise = Left AdminActionAuthorityStateConflict
 where
  core = signedAdminActionPermitCore permit

makePermit
  :: AuthorityTime
  -> Natural
  -> ManifestPublicKey
  -> AdminActionPermitCore
  -> AdminActionBackupReceipt
  -> AdminActionJobBinding
  -> ByteString
  -> Either AdminActionAuthorityError SignedAdminActionPermit
makePermit now signerGeneration publicKey core backup binding signature = do
  permit <-
    first
      AdminActionAuthorityProtocolRejected
      (mkSignedAdminActionPermit signerGeneration core backup binding signature)
  first
    AdminActionAuthorityProtocolRejected
    (verifySignedAdminActionPermit (manifestPublicKeyBytes publicKey) now permit)
  pure permit

authorityTimeFromRequest :: AdminActionPrepareRequest -> AuthorityTime
authorityTimeFromRequest = authorityTimeFromMicros . adminActionPrepareDeadlineMicros
