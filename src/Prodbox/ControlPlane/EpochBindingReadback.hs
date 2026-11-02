{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Physical observations on the migration route. An authenticated caller may
-- request a readback, but cannot supply the evidence recorded in the aggregate.
-- The observation and resulting CAS use one retained revision.
module Prodbox.ControlPlane.EpochBindingReadback
  ( EpochBindingReadbackProgram (..)
  , EpochAuthenticationBackend (..)
  , EpochBindingReadbackFailure (..)
  , authenticationEpochBindingDigest
  , vaultEpochAuthenticationBackend
  , runEpochBindingReadbackProgram
  , runEpochBindingReadbackProgramWithTargets
  , serveEpochBindingReadbackRequest
  , epochBindingReadbackAuthenticatedHandler
  , epochBindingReadbackVerifiedHandler
  , isPhysicalEpochReadbackForRole
  )
where

import Codec.Serialise (serialise)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter (AuthenticatedRoleHandler (..))
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.MigrationEndpoint
  ( MigrationEndpointResult (..)
  , migrationEndpointHttpStatus
  , migrationEndpointSummary
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestAuthorityEpoch
  , verifiedRequestAuthorityScope
  , verifiedRequestBody
  , verifiedRequestCalleeRole
  , verifiedRequestDeadline
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.RetainedAuthentication
  ( controlPlaneAuthorityEpochPath
  , readRetainedAuthorityEpoch
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.TargetAuthorityEpoch
  ( TargetAuthorityEpochTransition (..)
  , targetEpochDeadline
  , targetEpochPreparationContext
  , targetEpochRecordTransition
  )
import Prodbox.ControlPlane.TargetAuthorityEpochBinding
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityMigration)
  , AuthorityAdmissionDecision (..)
  , AuthorityMigrationMode (..)
  , activeAuthorityEpoch
  , authorityAggregateAuthenticationEpoch
  , authorityAggregateMigration
  , stepAuthorityAdmission
  )
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch, authorityEpochValue)
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationCommand (..)
  , decodeMigrationCommand
  , migrationEpochPromotion
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter (MigrationApplyResult (..))
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Vault.Session (VaultSession)
import System.Timeout (timeout)

data EpochBindingReadbackProgram result where
  ReadPreparedPhysicalBinding
    :: EpochPromotionState -> EpochTopologyBinding -> EpochBindingReadbackProgram EpochBindingReadback
  ReadPromotedPhysicalBinding
    :: EpochPromotionState -> EpochTopologyBinding -> EpochBindingReadbackProgram EpochBindingReadback
  ReadOldPhysicalWriterRejection
    :: EpochPromotionState
    -> EpochTopologyBinding
    -> Word
    -> EpochBindingReadbackProgram EpochBindingReadback
  ReadPreparedPhysicalBindingAbsence
    :: EpochPromotionState -> EpochTopologyBinding -> EpochBindingReadbackProgram ()

-- | The interpreter's primitive reads one existing public coordinate. It has
-- no write, credential lookup, or arbitrary-path operation.
newtype EpochAuthenticationBackend m = EpochAuthenticationBackend
  { observePhysicalAuthenticationEpoch :: m (Either Text AuthorityEpoch)
  }

data EpochBindingReadbackFailure
  = PhysicalBindingUnsupported
  | PhysicalAuthorityUnobservable
  | PhysicalAuthenticationEpochUnobservable
  | PhysicalRetainedEpochMismatch
  | PhysicalPromotionContextMismatch
  | PhysicalBindingWrongPhase
  | PhysicalOldWriterAdmitted
  | PhysicalBindingDigestMismatch
  | PhysicalBindingWriteUnobservable
  | PhysicalBindingConcurrentState
  | PhysicalTargetBindingFailed !TargetEpochBindingFailure
  | PhysicalRequestContextInvalid
  | PhysicalRequestDeadlineReached
  | PhysicalClockUnobservable
  deriving (Eq, Show)

-- | Only public coordinate/target metadata is hashed. Preparation names this
-- pending target in the aggregate; promotion independently reads its published
-- Vault epoch. Neither hashes a credential or claims preparation published it.
authenticationEpochBindingDigest :: Word -> Maybe CutoverDigest
authenticationEpochBindingDigest target
  | target == 0 = Nothing
  | otherwise =
      mkCutoverDigest
        ( Text.pack
            ( concatMap
                hexByte
                ( ByteString.unpack
                    ( SHA256.hash
                        ( LazyByteString.toStrict
                            (serialise (1 :: Word, RetainedAuthenticationEpochBinding, controlPlaneAuthorityEpochPath, target))
                        )
                    )
                )
            )
        )
 where
  hexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

vaultEpochAuthenticationBackend :: VaultSession -> EpochAuthenticationBackend IO
vaultEpochAuthenticationBackend session = EpochAuthenticationBackend (readRetainedAuthorityEpoch session)

runEpochBindingReadbackProgram
  :: forall m result
   . (Monad m)
  => EpochAuthenticationBackend m
  -> AuthorityAdmissionAggregate
  -> EpochBindingReadbackProgram result
  -> m (Either EpochBindingReadbackFailure result)
runEpochBindingReadbackProgram backend aggregate program = case program of
  ReadPreparedPhysicalBinding state binding -> observe state binding (observePrepared state)
  ReadPromotedPhysicalBinding state binding -> observe state binding (observePromoted state)
  ReadOldPhysicalWriterRejection state binding rejectedEpoch -> observe state binding (observeOldRejected state rejectedEpoch)
  ReadPreparedPhysicalBindingAbsence state binding -> observe state binding (observeAbsence state)
 where
  observePrepared state epoch = do
    validateCurrentPhase state epoch
    metadata state
  observePromoted state epoch = do
    case epochPromotionPhase state of
      EpochFrozen -> pure ()
      EpochAdmissionOpen -> pure ()
      EpochPrepared -> Left PhysicalBindingWrongPhase
      EpochPreparedRollback -> Left PhysicalBindingWrongPhase
      EpochPreparedBindingsRetired -> Left PhysicalBindingWrongPhase
    validateCurrentPhase state epoch
    metadata state
  observeOldRejected state rejectedEpoch epoch = do
    validateCurrentPhase state epoch
    if rejectedEpoch /= epochPromotionPredecessorEpoch state
      then Left PhysicalPromotionContextMismatch
      else case activeAuthorityEpoch aggregate of
        Right admitted
          | authorityEpochValue admitted == fromIntegral rejectedEpoch -> Left PhysicalOldWriterAdmitted
        _ -> pure ()
    metadata state
  observeAbsence state epoch = do
    case epochPromotionPhase state of
      EpochPreparedRollback -> pure ()
      EpochPreparedBindingsRetired -> pure ()
      EpochPrepared -> Left PhysicalBindingWrongPhase
      EpochFrozen -> Left PhysicalBindingWrongPhase
      EpochAdmissionOpen -> Left PhysicalBindingWrongPhase
    -- This binding has no separately installed pending Vault object. Before
    -- commit, only the aggregate names it; exact non-publication is its physical
    -- absence. This does not restore a predecessor credential or writer.
    if authorityEpochValue epoch == fromIntegral (epochPromotionTargetEpoch state)
      then Left PhysicalRetainedEpochMismatch
      else Right ()
  observe
    :: forall value
     . EpochPromotionState
    -> EpochTopologyBinding
    -> (AuthorityEpoch -> Either EpochBindingReadbackFailure value)
    -> m (Either EpochBindingReadbackFailure value)
  observe state binding project = case validateContext state binding of
    Left failure -> pure (Left failure)
    Right () -> do
      actual <- observePhysicalAuthenticationEpoch backend
      pure $ case actual of
        Left _ -> Left PhysicalAuthenticationEpochUnobservable
        Right epoch
          | epoch /= authorityAggregateAuthenticationEpoch aggregate -> Left PhysicalRetainedEpochMismatch
          | otherwise -> project epoch
  validateContext state binding = do
    case validateEpochPromotionState state of
      Left _ -> Left PhysicalPromotionContextMismatch
      Right () -> pure ()
    if aggregatePromotion aggregate /= Just state
      then Left PhysicalPromotionContextMismatch
      else pure ()
    case binding of
      RetainedAuthenticationEpochBinding -> Right ()
      AgentControllerBinding _ -> Left PhysicalBindingUnsupported
      AgentOneShotWorkerBinding _ -> Left PhysicalBindingUnsupported
      PendingAcceptedAuthorityBinding _ -> Left PhysicalBindingUnsupported
      HomeTlsEnvelopeLaneBinding -> Left PhysicalBindingUnsupported
      InForceConfigReferenceBinding -> Left PhysicalBindingUnsupported
      CapabilityServiceBinding _ -> Left PhysicalBindingUnsupported
      BackendCredentialGenerationBinding _ -> Left PhysicalBindingUnsupported
      BackendIssuerBinding _ -> Left PhysicalBindingUnsupported
      CommittedTlsCurrentBinding _ _ -> Left PhysicalBindingUnsupported
      ManagedDnsCoordinateBinding _ _ -> Left PhysicalBindingUnsupported
      AuthorityControllerBinding -> Left PhysicalBindingUnsupported
  validateCurrentPhase state epoch = case epochPromotionPhase state of
    EpochPrepared -> requireEpoch (epochPromotionPredecessorEpoch state)
    EpochFrozen -> requireEpoch (epochPromotionTargetEpoch state)
    EpochAdmissionOpen -> requireEpoch (epochPromotionTargetEpoch state)
    EpochPreparedRollback -> Left PhysicalBindingWrongPhase
    EpochPreparedBindingsRetired -> Left PhysicalBindingWrongPhase
   where
    requireEpoch expected
      | authorityEpochValue epoch == fromIntegral expected = Right ()
      | otherwise = Left PhysicalRetainedEpochMismatch
  metadata state = case authenticationEpochBindingDigest (epochPromotionTargetEpoch state) of
    Nothing -> Left PhysicalPromotionContextMismatch
    Just digest -> Right (EpochBindingReadback RetainedAuthenticationEpochBinding digest)

aggregatePromotion :: AuthorityAdmissionAggregate -> Maybe EpochPromotionState
aggregatePromotion aggregate = case authorityAggregateMigration aggregate of
  AuthorityCleanInstall -> Nothing
  AuthorityMigrationControlled state -> migrationEpochPromotion state

runEpochBindingReadbackProgramWithTargets
  :: forall m result
   . (Monad m)
  => AuthorityTime
  -> EpochAuthenticationBackend m
  -> TargetEpochBindingInterpreter m
  -> AuthorityAdmissionAggregate
  -> EpochBindingReadbackProgram result
  -> m (Either EpochBindingReadbackFailure result)
runEpochBindingReadbackProgramWithTargets deadline authentication targets aggregate program = case program of
  ReadPreparedPhysicalBinding state (PendingAcceptedAuthorityBinding substrate) ->
    fmap
      (fmap (EpochBindingReadback (PendingAcceptedAuthorityBinding substrate)))
      (targetQuery state substrate ReadPreparedTargetBinding)
  ReadPromotedPhysicalBinding state (PendingAcceptedAuthorityBinding substrate) ->
    fmap
      (fmap (EpochBindingReadback (PendingAcceptedAuthorityBinding substrate)))
      (targetQuery state substrate ReadPromotedTargetBinding)
  ReadOldPhysicalWriterRejection state (PendingAcceptedAuthorityBinding substrate) old ->
    fmap
      (fmap (EpochBindingReadback (PendingAcceptedAuthorityBinding substrate)))
      (targetQuery state substrate (ReadRejectedTargetWriter old))
  ReadPreparedPhysicalBindingAbsence state (PendingAcceptedAuthorityBinding substrate) ->
    targetQuery state substrate ReadRetiredTargetBinding
  _ -> runEpochBindingReadbackProgram authentication aggregate program
 where
  targetQuery
    :: EpochPromotionState
    -> CutoverSubstrate
    -> TargetEpochBindingQuery value
    -> m (Either EpochBindingReadbackFailure value)
  targetQuery state substrate query
    | aggregatePromotion aggregate /= Just state = pure (Left PhysicalPromotionContextMismatch)
    | otherwise =
        fmap
          (either (Left . PhysicalTargetBindingFailed) Right)
          (runTargetEpochBindingQuery deadline targets state substrate query)

-- | Nothing delegates a non-readback request to the existing dispatcher.
-- Physical readbacks are never delegated, including unsupported bindings.
serveEpochBindingReadbackRequest
  :: (Monad m)
  => Int
  -> EpochAuthenticationBackend m
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m (Maybe (ReplyStatus, ByteString))
serveEpochBindingReadbackRequest maximumBytes backend repository body =
  serveEpochBindingReadbackRequestUsing
    (const (pure (Right ())))
    (runEpochBindingReadbackProgram backend)
    maximumBytes
    repository
    body

serveEpochBindingReadbackRequestUsing
  :: (Monad m)
  => (Maybe AuthorityAdmissionAggregate -> m (Either EpochBindingReadbackFailure ()))
  -> ( forall result
        . AuthorityAdmissionAggregate
       -> EpochBindingReadbackProgram result
       -> m (Either EpochBindingReadbackFailure result)
     )
  -> Int
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m (Maybe (ReplyStatus, ByteString))
serveEpochBindingReadbackRequestUsing check runProgram maximumBytes repository body =
  case decodeMigrationCommand maximumBytes (LazyByteString.fromStrict body) of
    Right command@(ApplyPreparedEpochPromotion request)
      | isPhysicalReadback (promotionRequestAction request) -> Just <$> serve command request
    _ -> pure Nothing
 where
  serve command request = do
    result <- runExceptT $ do
      ExceptT (check Nothing)
      snapshot <-
        ExceptT
          (fmap (either (const (Left PhysicalAuthorityUnobservable)) Right) (readAuthorityAdmission repository))
      let aggregate = authorityAdmissionSnapshotState snapshot
      ExceptT (check (Just aggregate))
      state <- maybe (throwE PhysicalPromotionContextMismatch) pure (aggregatePromotion aggregate)
      unless
        ( promotionRequestEpoch request == epochPromotionTargetEpoch state
            && promotionRequestTopology request == epochTopologyDigest (epochPromotionTopology state)
        )
        (throwE PhysicalPromotionContextMismatch)
      ExceptT (verifyReadback aggregate state (promotionRequestAction request))
      ExceptT (check (Just aggregate))
      record snapshot command
    pure (either failureResponse id result)
  verifyReadback aggregate state action = case action of
    ObservePreparedEpochBinding supplied ->
      matching supplied
        <$> runProgram
          aggregate
          (ReadPreparedPhysicalBinding state (readbackBinding supplied))
    ObservePromotedEpochBinding supplied ->
      matching supplied
        <$> runProgram
          aggregate
          (ReadPromotedPhysicalBinding state (readbackBinding supplied))
    ObserveOldEpochRejected supplied oldEpoch ->
      matching supplied
        <$> runProgram
          aggregate
          (ReadOldPhysicalWriterRejection state (readbackBinding supplied) oldEpoch)
    ObservePreparedEpochBindingAbsent binding ->
      runProgram aggregate (ReadPreparedPhysicalBindingAbsence state binding)
    CommitFrozenEpoch -> pure (Left PhysicalBindingWrongPhase)
    OpenEpochAdmission -> pure (Left PhysicalBindingWrongPhase)
    BeginPreparedEpochRollback -> pure (Left PhysicalBindingWrongPhase)
    FinishPreparedEpochRollback -> pure (Left PhysicalBindingWrongPhase)
  matching supplied observed = do
    actual <- observed
    if actual == supplied then Right () else Left PhysicalBindingDigestMismatch
  record snapshot command = do
    let initial = authorityAdmissionSnapshotState snapshot
        (decision, next) = stepAuthorityAdmission initial (ApplyAuthorityMigration command)
    if next == initial
      then pure (decisionResponse decision next)
      else do
        ExceptT (check (Just initial))
        _ <-
          lift (compareAndSwapAuthorityAdmission repository (authorityAdmissionRevision snapshot) next)
        confirmed <- lift (readAuthorityAdmission repository)
        ExceptT (check (Just next))
        case confirmed of
          Right actual
            | authorityAdmissionSnapshotState actual == next -> pure (decisionResponse decision next)
          Right _ -> throwE PhysicalBindingConcurrentState
          Left _ -> throwE PhysicalBindingWriteUnobservable

isPhysicalReadback :: EpochPromotionAction -> Bool
isPhysicalReadback action = case action of
  ObservePreparedEpochBinding _ -> True
  ObservePromotedEpochBinding _ -> True
  ObserveOldEpochRejected _ _ -> True
  ObservePreparedEpochBindingAbsent _ -> True
  CommitFrozenEpoch -> False
  OpenEpochAdmission -> False
  BeginPreparedEpochRollback -> False
  FinishPreparedEpochRollback -> False

decisionResponse
  :: AuthorityAdmissionDecision -> AuthorityAdmissionAggregate -> (ReplyStatus, ByteString)
decisionResponse decision aggregate =
  let result = case decision of
        AuthorityMigrationDecided migrationDecision -> case authorityAggregateMigration aggregate of
          AuthorityMigrationControlled migration -> MigrationEndpointApplied (MigrationApplyResult migration migrationDecision)
          AuthorityCleanInstall -> MigrationEndpointAggregateMismatch
        AuthorityAdmissionCommandRefused refusal -> MigrationEndpointAdmissionRefused refusal
        _ -> MigrationEndpointAggregateMismatch
   in (migrationEndpointHttpStatus result, TextEncoding.encodeUtf8 (migrationEndpointSummary result))

failureResponse :: EpochBindingReadbackFailure -> (ReplyStatus, ByteString)
failureResponse failure = (status, "epoch-binding-readback/" <> token)
 where
  (status, token) = case failure of
    PhysicalBindingUnsupported -> (ReplyServiceUnavailable, "unsupported-binding")
    PhysicalAuthorityUnobservable -> (ReplyServiceUnavailable, "authority-unobservable")
    PhysicalAuthenticationEpochUnobservable -> (ReplyServiceUnavailable, "authentication-epoch-unobservable")
    PhysicalRetainedEpochMismatch -> (ReplyConflict, "retained-epoch-mismatch")
    PhysicalPromotionContextMismatch -> (ReplyConflict, "context-mismatch")
    PhysicalBindingWrongPhase -> (ReplyConflict, "wrong-phase")
    PhysicalOldWriterAdmitted -> (ReplyConflict, "old-writer-admitted")
    PhysicalBindingDigestMismatch -> (ReplyConflict, "binding-digest-mismatch")
    PhysicalBindingWriteUnobservable -> (ReplyServiceUnavailable, "write-unobservable")
    PhysicalBindingConcurrentState -> (ReplyConflict, "concurrent-state")
    PhysicalTargetBindingFailed cause ->
      ( targetEpochBindingFailureStatus cause
      , "target/" <> TextEncoding.encodeUtf8 (renderTargetEpochBindingFailure cause)
      )
    PhysicalRequestContextInvalid -> (ReplyConflict, "request-context-invalid")
    PhysicalRequestDeadlineReached -> (ReplyConflict, "request-deadline-reached")
    PhysicalClockUnobservable -> (ReplyServiceUnavailable, "clock-unobservable")

-- | Readback metadata writes also require fresh observations. Their retained
-- CAS remains idempotent, but an old cached reply is not a new physical fact.
isPhysicalEpochReadbackForRole :: Int -> RuntimeRole -> ControlPlaneRoute -> ByteString -> Bool
isPhysicalEpochReadbackForRole maximumBytes role route body =
  role == LifecycleAuthorityRuntime
    && route == LifecycleMigrationApply
    && case decodeMigrationCommand maximumBytes (LazyByteString.fromStrict body) of
      Right (ApplyPreparedEpochPromotion request) -> isPhysicalReadback (promotionRequestAction request)
      _ -> False

epochBindingReadbackVerifiedHandler
  :: Int
  -> AuthorityScope
  -> IO (Either Text AuthorityTime)
  -> EpochAuthenticationBackend IO
  -> TargetEpochBindingInterpreter IO
  -> AuthorityAdmissionRepository IO revision
  -> VerifiedControlPlaneRequest
  -> IO (Maybe (ReplyStatus, ByteString))
epochBindingReadbackVerifiedHandler maximumBytes scope readTime authentication targets repository verified
  | not
      ( isPhysicalEpochReadbackForRole
          maximumBytes
          LifecycleAuthorityRuntime
          (verifiedRequestRoute verified)
          (verifiedRequestBody verified)
      ) =
      pure Nothing
  | verifiedRequestCalleeRole verified /= LifecycleAuthorityRuntime
      || verifiedRequestAuthorityScope verified /= scope =
      pure (Just (failureResponse PhysicalRequestContextInvalid))
  | otherwise = do
      budget <- newIORef deadline
      capPreparation <- newIORef (not retiring)
      let observeTarget :: TargetEpochBindingEffect value -> IO (Either TargetEpochBindingFailure value)
          observeTarget program = do
            result <- runTargetEpochBindingEffect targets program
            case program of
              ReadTargetBindingRow {} -> case result of
                Right (Just (_, record)) -> do
                  cap <- readIORef capPreparation
                  when cap $ case targetEpochRecordTransition record of
                    TargetEpochNoTransition -> pure ()
                    TargetEpochPrepared preparation -> narrow preparation
                    TargetEpochPromoted preparation -> narrow preparation
                    TargetEpochRetired preparation -> narrow preparation
                _ -> pure ()
              _ -> pure ()
            pure result
           where
            narrow preparation = modifyIORef' budget (min (targetEpochDeadline (targetEpochPreparationContext preparation)))
          runProgram
            :: AuthorityAdmissionAggregate
            -> EpochBindingReadbackProgram value
            -> IO (Either EpochBindingReadbackFailure value)
          runProgram aggregate program = do
            currentDeadline <- readIORef budget
            runEpochBindingReadbackProgramWithTargets
              currentDeadline
              authentication
              (TargetEpochBindingInterpreter observeTarget)
              aggregate
              program
          check aggregate = do
            currentDeadline <- readIORef budget
            observedTime <- readTime
            case aggregate of
              Just value ->
                writeIORef
                  capPreparation
                  ( not retiring
                      && maybe True ((/= EpochAdmissionOpen) . epochPromotionPhase) (aggregatePromotion value)
                  )
              Nothing -> pure ()
            pure $ case observedTime of
              Left _ -> Left PhysicalClockUnobservable
              Right now
                | now >= currentDeadline -> Left PhysicalRequestDeadlineReached
                | maybe
                    False
                    ((/= verifiedRequestAuthorityEpoch verified) . authorityAggregateAuthenticationEpoch)
                    aggregate ->
                    Left PhysicalRequestContextInvalid
                | otherwise -> Right ()
          bounded :: IO (Either Text value) -> IO (Either Text value)
          bounded action = do
            currentDeadline <- readIORef budget
            observedTime <- readTime
            case observedTime of
              Left _ -> pure (Left "epoch readback clock unavailable")
              Right now
                | now >= currentDeadline -> pure (Left "epoch readback deadline reached")
                | otherwise -> do
                    let remaining =
                          min (authorityTimeMicros currentDeadline - authorityTimeMicros now) (fromIntegral (maxBound :: Int))
                    result <- timeout (fromIntegral remaining) action
                    pure (maybe (Left "epoch readback effect unobservable") id result)
          boundedRepository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = bounded (readAuthorityAdmission repository)
              , compareAndSwapAuthorityAdmission = \revision next -> bounded (compareAndSwapAuthorityAdmission repository revision next)
              }
      observed <- readTime
      case observed of
        Left _ -> pure (Just (failureResponse PhysicalClockUnobservable))
        Right now
          | now >= deadline -> pure (Just (failureResponse PhysicalRequestDeadlineReached))
          | otherwise -> do
              let remaining = min (authorityTimeMicros deadline - authorityTimeMicros now) (fromIntegral (maxBound :: Int))
              result <-
                timeout
                  (fromIntegral remaining)
                  ( serveEpochBindingReadbackRequestUsing
                      check
                      runProgram
                      maximumBytes
                      boundedRepository
                      (verifiedRequestBody verified)
                  )
              pure (maybe (Just (failureResponse PhysicalRequestDeadlineReached)) id result)
 where
  deadline = verifiedRequestDeadline verified
  retiring = case decodeMigrationCommand maximumBytes (LazyByteString.fromStrict (verifiedRequestBody verified)) of
    Right (ApplyPreparedEpochPromotion request) -> case promotionRequestAction request of
      ObservePreparedEpochBindingAbsent _ -> True
      _ -> False
    _ -> False

epochBindingReadbackAuthenticatedHandler
  :: (Monad m)
  => Int
  -> EpochAuthenticationBackend m
  -> AuthorityAdmissionRepository m revision
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
epochBindingReadbackAuthenticatedHandler maximumBytes backend repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleMigrationApply -> do
      observed <- serveEpochBindingReadbackRequest maximumBytes backend repository body
      case observed of
        Just response -> pure (Just response)
        Nothing -> authenticatedHandlerHandle inner caller route body
    _ -> authenticatedHandlerHandle inner caller route body
