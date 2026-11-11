{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Complete, target-keyed physical trust observations. Binding metadata is
-- independent of its enclosing topology digest and of transition progress.
module Prodbox.ControlPlane.TargetAuthorityEpochBinding
  ( TargetEpochAgentRegistry
  , TargetEpochAgentRegistryError (..)
  , mkTargetEpochAgentRegistry
  , homeTargetEpochAgentRegistry
  , targetEpochRegistrySubstrateForCluster
  , TargetEpochBindingEffect (..)
  , TargetEpochBindingInterpreter (..)
  , TargetEpochBindingQuery (..)
  , TargetEpochBindingFailure (..)
  , targetEpochBindingDigest
  , runTargetEpochBindingQuery
  , vaultTargetEpochBindingInterpreter
  , renderTargetEpochBindingFailure
  , targetEpochBindingFailureStatus
  )
where

import Codec.Serialise (serialise)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.ControlPlane.AuthenticatedTransport (AuthenticatedClientTransport)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochClient
  ( observeTargetAuthorityEpochWithClient
  , targetEpochClientWithin
  )
import Prodbox.ControlPlane.TargetAuthorityEpochExecution
  ( TargetEpochExecutionError (..)
  , TargetEpochExecutionInterpreter (..)
  , TargetEpochExecutionProgram (..)
  , TargetEpochObservation
  , vaultTargetEpochExecutionInterpreter
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , targetSecretIdToken
  , targetWorkerAuthorizationIds
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , TargetIntentPublicKey
  , TargetIssuerKeyGeneration
  , acceptedTargetAgentIdentity
  , acceptedTargetAuthorityEpoch
  , acceptedTargetId
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , encodeAcceptedTargetAuthority
  , targetAgentClusterIdentity
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyConflict, ReplyServiceUnavailable))
import Prodbox.Lifecycle.Authority.EpochPromotion
  ( EpochPromotionPhase (..)
  , EpochPromotionState (..)
  , validateEpochPromotionState
  )
import Prodbox.Lifecycle.Authority.EpochTopology
  ( CutoverDigest
  , CutoverSubstrate (..)
  , EpochTopologyBinding (PendingAcceptedAuthorityBinding)
  , epochTopologyBindingDigest
  , epochTopologyDigest
  , mkCutoverDigest
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime)
  , runtimeRoleName
  )
import Prodbox.Vault.Session (VaultSession)
import System.Timeout (timeout)

newtype TargetEpochAgentRegistry
  = TargetEpochAgentRegistry
      (Map CutoverSubstrate (TargetAgentIdentity, AuthenticatedClientTransport 'TargetSecretAgentRuntime))

data TargetEpochAgentRegistryError
  = TargetEpochRegistryHomeMissing
  | TargetEpochRegistryDuplicateSubstrate
  | TargetEpochRegistryAliasedCluster
  deriving (Eq, Show)

mkTargetEpochAgentRegistry
  :: [(CutoverSubstrate, TargetAgentIdentity, AuthenticatedClientTransport 'TargetSecretAgentRuntime)]
  -> Either TargetEpochAgentRegistryError TargetEpochAgentRegistry
mkTargetEpochAgentRegistry entries
  | Map.notMember CutoverHome rows = Left TargetEpochRegistryHomeMissing
  | Map.size rows /= length entries = Left TargetEpochRegistryDuplicateSubstrate
  | Set.size clusters /= length entries = Left TargetEpochRegistryAliasedCluster
  | otherwise = Right (TargetEpochAgentRegistry rows)
 where
  rows = Map.fromList [(substrate, (agent, transport)) | (substrate, agent, transport) <- entries]
  clusters = Set.fromList [targetAgentClusterIdentity agent | (_, agent, _) <- entries]

homeTargetEpochAgentRegistry
  :: TargetAgentIdentity
  -> AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetEpochAgentRegistry
homeTargetEpochAgentRegistry agent transport = TargetEpochAgentRegistry (Map.singleton CutoverHome (agent, transport))

-- | The substrate and agent a registry holds for exactly this cluster identity,
-- or 'Nothing'. A retained-delivery request names its target by cluster
-- identity text; this is the closed-set membership test that replaces
-- comparing it with one configured agent (Sprint 7.47, D6/D7). It matches the
-- whole identity text, so a prefix, a different case or an empty string is not
-- registered.
targetEpochRegistrySubstrateForCluster
  :: TargetEpochAgentRegistry -> Text -> Maybe (CutoverSubstrate, TargetAgentIdentity)
targetEpochRegistrySubstrateForCluster (TargetEpochAgentRegistry rows) cluster =
  case [ (substrate, agent)
       | (substrate, (agent, _)) <- Map.toList rows
       , targetAgentClusterIdentity agent == cluster
       ] of
    found : _ -> Just found
    [] -> Nothing

data TargetEpochBindingEffect result where
  ReadTargetBindingTime :: TargetEpochBindingEffect AuthorityTime
  ReadTargetBindingEpoch :: AuthorityTime -> TargetEpochBindingEffect AuthorityEpoch
  ReadTargetBindingIssuer
    :: AuthorityTime -> TargetEpochBindingEffect (TargetIssuerKeyGeneration, TargetIntentPublicKey)
  ReadTargetBindingAgent :: CutoverSubstrate -> TargetEpochBindingEffect TargetAgentIdentity
  ReadTargetBindingRow
    :: AuthorityTime
    -> CutoverSubstrate
    -> TargetSecretId
    -> TargetEpochBindingEffect TargetEpochObservation

newtype TargetEpochBindingInterpreter m = TargetEpochBindingInterpreter
  { runTargetEpochBindingEffect
      :: forall result. TargetEpochBindingEffect result -> m (Either TargetEpochBindingFailure result)
  }

data TargetEpochBindingQuery result where
  ReadPreparedTargetBinding :: TargetEpochBindingQuery CutoverDigest
  ReadPromotedTargetBinding :: TargetEpochBindingQuery CutoverDigest
  ReadRejectedTargetWriter :: Word -> TargetEpochBindingQuery CutoverDigest
  ReadRetiredTargetBinding :: TargetEpochBindingQuery ()

data TargetEpochBindingFailure
  = TargetBindingScopeInvalid
  | TargetBindingAgentUnregistered
  | TargetBindingClockUnavailable
  | TargetBindingDeadlineReached
  | TargetBindingEffectTimedOut
  | TargetBindingEpochUnavailable
  | TargetBindingEpochMismatch
  | TargetBindingIssuerUnavailable
  | TargetBindingIssuerMismatch
  | TargetBindingRowUnavailable !TargetSecretId
  | TargetBindingRowMissing !TargetSecretId
  | TargetBindingRowVersionInvalid
  | TargetBindingAgentMismatch
  | TargetBindingContextMismatch
  | TargetBindingPhaseMismatch
  | TargetBindingInventoryMismatch
  | TargetBindingDigestMismatch
  | TargetBindingObservationChanged
  | TargetBindingOldWriterAdmitted
  deriving (Eq, Show)

-- | Public accepted-authority bytes bind exact issuer, key, epoch, fence,
-- Agent and sink. Only predecessor/target/deadline are taken from the context;
-- including its whole-topology digest would introduce a self-hash.
targetEpochBindingDigest
  :: CutoverSubstrate
  -> [TargetAuthorityEpochPreparation]
  -> Either TargetEpochBindingFailure CutoverDigest
targetEpochBindingDigest substrate preparations = do
  let rows =
        Map.fromList
          [(acceptedTargetId (targetEpochPreparationAuthority value), value) | value <- preparations]
  unless
    ( Map.size rows == length preparations
        && Map.keysSet rows == Set.fromList targetWorkerAuthorizationIds
    )
    (Left TargetBindingInventoryMismatch)
  firstPreparation <- case Map.elems rows of
    value : _ -> Right value
    [] -> Left TargetBindingInventoryMismatch
  let context = targetEpochPreparationContext firstPreparation
      agent = acceptedTargetAgentIdentity (targetEpochPreparationAuthority firstPreparation)
  unless
    (all (sameContext context agent) (Map.elems rows))
    (Left TargetBindingContextMismatch)
  let metadata =
        ( 1 :: Word
        , PendingAcceptedAuthorityBinding substrate
        , targetEpochPredecessor context
        , targetEpochTarget context
        , authorityTimeMicros (targetEpochDeadline context)
        , [ (target, encodeAcceptedTargetAuthority (targetEpochPreparationAuthority value))
          | (target, value) <- Map.toAscList rows
          ]
        )
      digest = SHA256.hash (LazyByteString.toStrict (serialise metadata))
  maybe
    (Left TargetBindingDigestMismatch)
    Right
    (mkCutoverDigest (Text.pack (concatMap hexByte (ByteString.unpack digest))))
 where
  sameContext context agent value =
    targetEpochPreparationContext value == context
      && acceptedTargetAgentIdentity (targetEpochPreparationAuthority value) == agent
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

runTargetEpochBindingQuery
  :: forall m result
   . (Monad m)
  => AuthorityTime
  -> TargetEpochBindingInterpreter m
  -> EpochPromotionState
  -> CutoverSubstrate
  -> TargetEpochBindingQuery result
  -> m (Either TargetEpochBindingFailure result)
runTargetEpochBindingQuery requestDeadline interpreter state substrate query = runExceptT $ do
  require (validateEpochPromotionState state == Right ()) TargetBindingScopeInvalid
  expectedDigest <-
    maybe
      (throwE TargetBindingScopeInvalid)
      pure
      ( epochTopologyBindingDigest
          (epochPromotionTopology state)
          (PendingAcceptedAuthorityBinding substrate)
      )
  validateQueryPhase
  _ <- freshTime requestDeadline
  agent <- effect (ReadTargetBindingAgent substrate)
  (firstTarget, remainingTargets) <- case targetWorkerAuthorizationIds of
    target : remaining -> pure (target, remaining)
    [] -> throwE TargetBindingInventoryMismatch
  firstRow <- readRow requestDeadline agent firstTarget
  firstPreparation <- preparationFromRow (snd firstRow)
  let context = targetEpochPreparationContext firstPreparation
      deadline = case query of
        ReadRetiredTargetBinding -> requestDeadline
        ReadPreparedTargetBinding -> liveDeadline context
        ReadPromotedTargetBinding -> liveDeadline context
        ReadRejectedTargetWriter _ -> liveDeadline context
  _ <- freshTime deadline
  initialEpoch <- effect (ReadTargetBindingEpoch deadline)
  require (initialEpoch == expectedEpoch) TargetBindingEpochMismatch
  beforeIssuer <- readIssuer deadline
  firstSnapshot <- (firstRow :) <$> traverse (readRow deadline agent) remainingTargets
  secondSnapshot <- traverse (readRow deadline agent) targetWorkerAuthorizationIds
  require (firstSnapshot == secondSnapshot) TargetBindingObservationChanged
  preparations <- traverse (validateRow context beforeIssuer . snd) firstSnapshot
  digest <- either throwE pure (targetEpochBindingDigest substrate preparations)
  require (digest == expectedDigest) TargetBindingDigestMismatch
  closingEpoch <- effect (ReadTargetBindingEpoch deadline)
  closingIssuer <- readIssuer deadline
  _ <- freshTime deadline
  require
    (closingEpoch == initialEpoch && closingIssuer == beforeIssuer)
    TargetBindingObservationChanged
  case query of
    ReadPreparedTargetBinding -> pure digest
    ReadPromotedTargetBinding -> pure digest
    ReadRejectedTargetWriter _ -> pure digest
    ReadRetiredTargetBinding -> pure ()
 where
  effect :: TargetEpochBindingEffect value -> ExceptT TargetEpochBindingFailure m value
  effect = ExceptT . runTargetEpochBindingEffect interpreter
  require condition failure = unless condition (throwE failure)
  liveDeadline context = case epochPromotionPhase state of
    EpochAdmissionOpen -> requestDeadline
    _ -> min requestDeadline (targetEpochDeadline context)
  expectedEpoch =
    AuthorityEpoch
      ( fromIntegral
          ( case epochPromotionPhase state of
              EpochPrepared -> epochPromotionPredecessorEpoch state
              EpochPreparedRollback -> epochPromotionPredecessorEpoch state
              EpochPreparedBindingsRetired -> epochPromotionPredecessorEpoch state
              EpochFrozen -> epochPromotionTargetEpoch state
              EpochAdmissionOpen -> epochPromotionTargetEpoch state
          )
      )
  freshTime deadline = do
    now <- effect ReadTargetBindingTime
    require (now < deadline && now < requestDeadline) TargetBindingDeadlineReached
    pure now
  readRow deadline agent target = do
    _ <- freshTime deadline
    observed <- effect (ReadTargetBindingRow deadline substrate target)
    _ <- freshTime deadline
    (version, record) <- maybe (throwE (TargetBindingRowMissing target)) pure observed
    require (version > 0) TargetBindingRowVersionInvalid
    require (targetEpochRecordTarget record == target) TargetBindingInventoryMismatch
    preparation <- preparationFromRow record
    require
      (acceptedTargetAgentIdentity (targetEpochPreparationAuthority preparation) == agent)
      TargetBindingAgentMismatch
    pure (version, record)
  preparationFromRow record = case targetEpochRecordTransition record of
    TargetEpochNoTransition -> throwE TargetBindingPhaseMismatch
    TargetEpochPrepared value -> pure value
    TargetEpochPromoted value -> pure value
    TargetEpochRetired value -> pure value
  readIssuer deadline = case query of
    ReadRetiredTargetBinding -> pure Nothing
    ReadPreparedTargetBinding -> Just <$> effect (ReadTargetBindingIssuer deadline)
    ReadPromotedTargetBinding -> Just <$> effect (ReadTargetBindingIssuer deadline)
    ReadRejectedTargetWriter _ -> Just <$> effect (ReadTargetBindingIssuer deadline)
  validateRow context issuer record = do
    preparation <- preparationFromRow record
    let actualContext = targetEpochPreparationContext preparation
        authority = targetEpochPreparationAuthority preparation
    require
      ( actualContext == context
          && targetEpochPredecessor actualContext == epochPromotionPredecessorEpoch state
          && targetEpochTarget actualContext == epochPromotionTargetEpoch state
          && targetEpochTopology actualContext == epochTopologyDigest (epochPromotionTopology state)
      )
      TargetBindingContextMismatch
    case issuer of
      Nothing -> pure ()
      Just (generation, public) ->
        require
          ( acceptedTargetIssuerGeneration authority == generation
              && acceptedTargetIssuerPublicKey authority == public
              && acceptedTargetIssuerIdentity authority == Text.pack (runtimeRoleName LifecycleAuthorityRuntime)
          )
          TargetBindingIssuerMismatch
    case query of
      ReadPreparedTargetBinding -> require (preparedOrPromoted record) TargetBindingPhaseMismatch
      ReadPromotedTargetBinding -> require (promoted record) TargetBindingPhaseMismatch
      ReadRejectedTargetWriter old -> do
        require (preparedOrPromoted record) TargetBindingPhaseMismatch
        require
          ( maybe
              True
              ((/= AuthorityEpoch (fromIntegral old)) . acceptedTargetAuthorityEpoch)
              (targetEpochWorkerAuthority record)
          )
          TargetBindingOldWriterAdmitted
      ReadRetiredTargetBinding -> do
        require
          (targetEpochRecordTransition record == TargetEpochRetired preparation)
          TargetBindingPhaseMismatch
        require
          ( targetEpochRecordRetiredThrough record == epochPromotionTargetEpoch state
              && targetEpochWorkerAuthority record == Nothing
          )
          TargetBindingPhaseMismatch
    pure preparation
  preparedOrPromoted record = case targetEpochRecordTransition record of
    TargetEpochPrepared _ -> epochPromotionPhase state /= EpochAdmissionOpen && targetEpochWorkerAuthority record == Nothing
    TargetEpochPromoted _ -> epochPromotionPhase state /= EpochPrepared && promoted record
    TargetEpochRetired _ -> False
    TargetEpochNoTransition -> False
  promoted record = case targetEpochRecordTransition record of
    TargetEpochPromoted _ ->
      maybe
        False
        ((== AuthorityEpoch (fromIntegral (epochPromotionTargetEpoch state))) . acceptedTargetAuthorityEpoch)
        (targetEpochWorkerAuthority record)
    TargetEpochPrepared _ -> False
    TargetEpochRetired _ -> False
    TargetEpochNoTransition -> False
  validateQueryPhase = case query of
    ReadRetiredTargetBinding ->
      require
        (epochPromotionPhase state `elem` [EpochPreparedRollback, EpochPreparedBindingsRetired])
        TargetBindingPhaseMismatch
    ReadPromotedTargetBinding ->
      require
        (epochPromotionPhase state `elem` [EpochFrozen, EpochAdmissionOpen])
        TargetBindingPhaseMismatch
    ReadPreparedTargetBinding ->
      require
        (epochPromotionPhase state `elem` [EpochPrepared, EpochFrozen, EpochAdmissionOpen])
        TargetBindingPhaseMismatch
    ReadRejectedTargetWriter old -> do
      require (old == epochPromotionPredecessorEpoch state) TargetBindingContextMismatch
      require
        (epochPromotionPhase state `elem` [EpochPrepared, EpochFrozen, EpochAdmissionOpen])
        TargetBindingPhaseMismatch

vaultTargetEpochBindingInterpreter
  :: VaultSession
  -> IO (Either Text AuthorityTime)
  -> TargetEpochAgentRegistry
  -> TargetEpochBindingInterpreter IO
vaultTargetEpochBindingInterpreter session readTime (TargetEpochAgentRegistry agents) =
  TargetEpochBindingInterpreter interpret
 where
  execution = vaultTargetEpochExecutionInterpreter session readTime
  interpret :: TargetEpochBindingEffect result -> IO (Either TargetEpochBindingFailure result)
  interpret program = case program of
    ReadTargetBindingTime -> first (const TargetBindingClockUnavailable) <$> readTime
    ReadTargetBindingEpoch deadline ->
      first (effectFailure TargetBindingEpochUnavailable)
        <$> runTargetEpochExecutionProgram execution (ReadPublishedTargetEpoch deadline)
    ReadTargetBindingIssuer deadline ->
      first (effectFailure TargetBindingIssuerUnavailable)
        <$> runTargetEpochExecutionProgram execution (ReadTargetEpochIssuer deadline)
    ReadTargetBindingAgent substrate -> pure (fst <$> registered substrate)
    ReadTargetBindingRow deadline substrate target -> case registered substrate of
      Left failure -> pure (Left failure)
      Right (_, transport) -> bounded deadline $ do
        result <- observeTargetAuthorityEpochWithClient (targetEpochClientWithin deadline transport) target
        pure (first (const (TargetBindingRowUnavailable target)) result)
  registered substrate = maybe (Left TargetBindingAgentUnregistered) Right (Map.lookup substrate agents)
  effectFailure fallback failure = case failure of
    TargetEpochClockUnavailable -> TargetBindingClockUnavailable
    TargetEpochExecutionDeadlineReached -> TargetBindingDeadlineReached
    TargetEpochEffectTimedOut -> TargetBindingEffectTimedOut
    _ -> fallback
  bounded
    :: AuthorityTime
    -> IO (Either TargetEpochBindingFailure value)
    -> IO (Either TargetEpochBindingFailure value)
  bounded deadline action = do
    observed <- readTime
    case observed of
      Left _ -> pure (Left TargetBindingClockUnavailable)
      Right now
        | now >= deadline -> pure (Left TargetBindingDeadlineReached)
        | otherwise -> do
            let remaining = min (authorityTimeMicros deadline - authorityTimeMicros now) (fromIntegral (maxBound :: Int))
            result <- timeout (fromIntegral remaining) action
            pure (maybe (Left TargetBindingEffectTimedOut) id result)

renderTargetEpochBindingFailure :: TargetEpochBindingFailure -> Text
renderTargetEpochBindingFailure failure = case failure of
  TargetBindingScopeInvalid -> "scope-invalid"
  TargetBindingAgentUnregistered -> "agent-unregistered"
  TargetBindingClockUnavailable -> "clock-unavailable"
  TargetBindingDeadlineReached -> "deadline-reached"
  TargetBindingEffectTimedOut -> "effect-timed-out"
  TargetBindingEpochUnavailable -> "epoch-unavailable"
  TargetBindingEpochMismatch -> "epoch-mismatch"
  TargetBindingIssuerUnavailable -> "issuer-unavailable"
  TargetBindingIssuerMismatch -> "issuer-mismatch"
  TargetBindingRowUnavailable target -> "row-unavailable/" <> targetSecretIdToken target
  TargetBindingRowMissing target -> "row-missing/" <> targetSecretIdToken target
  TargetBindingRowVersionInvalid -> "row-version-invalid"
  TargetBindingAgentMismatch -> "agent-mismatch"
  TargetBindingContextMismatch -> "context-mismatch"
  TargetBindingPhaseMismatch -> "phase-mismatch"
  TargetBindingInventoryMismatch -> "inventory-mismatch"
  TargetBindingDigestMismatch -> "digest-mismatch"
  TargetBindingObservationChanged -> "observation-changed"
  TargetBindingOldWriterAdmitted -> "old-writer-admitted"

targetEpochBindingFailureStatus :: TargetEpochBindingFailure -> ReplyStatus
targetEpochBindingFailureStatus failure = case failure of
  TargetBindingAgentUnregistered -> ReplyServiceUnavailable
  TargetBindingClockUnavailable -> ReplyServiceUnavailable
  TargetBindingEffectTimedOut -> ReplyServiceUnavailable
  TargetBindingEpochUnavailable -> ReplyServiceUnavailable
  TargetBindingIssuerUnavailable -> ReplyServiceUnavailable
  TargetBindingRowUnavailable _ -> ReplyServiceUnavailable
  _ -> ReplyConflict
