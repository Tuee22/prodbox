{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | One bounded write-ahead protocol. Source metadata is read by the server;
-- requests carry only a public stable operation key and expected generation.
module Prodbox.ControlPlane.RpcAdmissionBirthExecution
  ( RpcBirthCommand (..)
  , RpcBirthStatus (..)
  , RpcBirthContext
  , mkRpcBirthContext
  , rpcBirthContextDeadline
  , RpcBirthDescriptorContext
  , mkRpcBirthDescriptorContext
  , rpcBirthDescriptorContextDeadline
  , rpcBirthDescriptorRequest
  , isRpcBirthDescriptorRequest
  , RpcBirthDescriptorObservation
  , rpcBirthObservationStatus
  , rpcBirthObservationDescriptor
  , rpcBirthObservationRequiresRegistration
  , rpcBirthObservationMaximumBytes
  , encodeRpcBirthDescriptorObservation
  , decodeRpcBirthDescriptorObservation
  , RpcBirthRegistryContext
  , mkRpcBirthRegistryContext
  , rpcBirthRegistryContextDeadline
  , rpcBirthRegistryRequest
  , isRpcBirthRegistryRequest
  , RpcBirthRegistryObservation
  , rpcBirthRegistryBirth
  , rpcBirthObservedRegistry
  , rpcBirthRegistryObservationMaximumBytes
  , encodeRpcBirthRegistryObservation
  , decodeRpcBirthRegistryObservation
  , RpcBirthReadProgram (..)
  , RpcBirthReadInterpreter (..)
  , rpcBirthReadInterpreter
  , executeRpcBirthDescriptorObservation
  , executeRpcBirthRegistryObservation
  , executeRpcBirthOwnBindingHint
  , encodeRpcBirthCommand
  , decodeRpcBirthCommand
  , isRpcBirthRequest
  , isRpcBirthObservation
  , RpcBirthProgram (..)
  , RpcBirthInterpreter (..)
  , executeRpcBirth
  , observeRpcBirthPair
  , rpcBirthNormalAdmission
  , rpcBirthAuthenticationAdmission
  , rpcBirthAuthenticationRegistry
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli, CallerTestHarness))
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneRequest)
import Prodbox.ControlPlane.Coordinate (AuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestAuthorityEpoch
  , verifiedRequestAuthorityScope
  , verifiedRequestBody
  , verifiedRequestCalleeRole
  , verifiedRequestCallerPrincipal
  , verifiedRequestDeadline
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.Route (ControlPlaneRoute (LifecycleMigrationApply))
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthWire
  ( isRpcBirthDescriptorRequest
  , isRpcBirthRegistryRequest
  , isRpcBirthRequest
  , rpcBirthDescriptorRequest
  , rpcBirthObservationMaximumBytes
  , rpcBirthRegistryObservationMaximumBytes
  , rpcBirthRegistryRequest
  , rpcBirthRequestPrefix
  , rpcBirthSignedDescriptorRequest
  , rpcBirthSignedRegistryRequest
  )
import Prodbox.ControlPlane.RpcKeyRegistry
  ( RpcKeyRegistry
  , decodeRpcKeyRegistry
  , encodeRpcKeyRegistry
  , rpcKeyRegistryScope
  )
import Prodbox.ControlPlane.RpcOwnBindingHint
  ( RpcOwnBindingHint
  , RpcOwnBindingQuery
  , rpcOwnBindingQueryScope
  , selectRpcOwnBindingHint
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAuthenticationEpoch
  , authorityAggregateRegisteredClients
  , authorityAggregateRpcKeyRegistry
  )
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasResult
  , ModelBObjectVersion
  , ModelBObservation (..)
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data RpcBirthCommand
  = ObserveRpcBirth
  | PrepareRpcBirth !Natural !Text
  | CompleteRpcBirth !Natural !Text
  | AbortRpcBirth !Natural !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RpcBirthStatus = RpcBirthStatus
  { rpcBirthStatusPhase :: !RpcBirthPhase
  , rpcBirthStatusGeneration :: !Natural
  , rpcBirthStatusCommitted :: !Bool
  , rpcBirthStatusDescriptorDigest :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RpcBirthContext
  = RpcBirthContext !AuthorityScope !AuthorityEpoch !AuthorityTime !RpcBirthServingMode !RpcBirthCommand

data RpcBirthDescriptorContext
  = RpcBirthDescriptorContext !AuthorityScope !AuthorityTime !RpcBirthServingMode

data RpcBirthDescriptorObservation
  = RpcBirthDescriptorObservation !RpcBirthStatus !(Maybe RpcBirthDescriptor) !Bool
  deriving stock (Eq, Show)

data RpcBirthObservationWire = RpcBirthObservationWire !Word !RpcBirthStatus !(Maybe ByteString) !Bool
  deriving stock (Generic)
  deriving anyclass (Serialise)

data RpcBirthRegistryContext
  = RpcBirthRegistryContext !AuthorityScope !AuthorityTime !RpcBirthServingMode

data RpcBirthRegistryObservation
  = RpcBirthRegistryObservation !RpcBirthDescriptorObservation !RpcKeyRegistry
  deriving stock (Eq, Show)

data RpcBirthRegistryObservationWire
  = RpcBirthRegistryObservationWire !Word !ByteString !ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)

rpcBirthRegistryObservationPrefix :: ByteString
rpcBirthRegistryObservationPrefix = "prodbox-rpc-birth-registry-response/v1\NUL"

rpcBirthRegistryBirth :: RpcBirthRegistryObservation -> RpcBirthDescriptorObservation
rpcBirthRegistryBirth (RpcBirthRegistryObservation value _) = value

rpcBirthObservedRegistry :: RpcBirthRegistryObservation -> RpcKeyRegistry
rpcBirthObservedRegistry (RpcBirthRegistryObservation _ value) = value

encodeRpcBirthRegistryObservation
  :: RpcBirthRegistryObservation -> Either RpcBirthError ByteString
encodeRpcBirthRegistryObservation observation@(RpcBirthRegistryObservation birth registry) = do
  validateRegistryObservation observation
  descriptor <- encodeRpcBirthDescriptorObservation birth
  registered <- first (const RpcBirthSeedInvalid) (encodeRpcKeyRegistry registry)
  let bytes =
        rpcBirthRegistryObservationPrefix
          <> Lazy.toStrict (serialise (RpcBirthRegistryObservationWire 1 descriptor registered))
  unless (BS.length bytes <= rpcBirthRegistryObservationMaximumBytes) (Left RpcBirthStateTooLarge)
  pure bytes

decodeRpcBirthRegistryObservation
  :: AuthorityScope -> ByteString -> Either RpcBirthError RpcBirthRegistryObservation
decodeRpcBirthRegistryObservation scope bytes = do
  unless (BS.length bytes <= rpcBirthRegistryObservationMaximumBytes) (Left RpcBirthStateTooLarge)
  body <-
    maybe
      (Left RpcBirthDescriptorInvalid)
      Right
      (BS.stripPrefix rpcBirthRegistryObservationPrefix bytes)
  wire@(RpcBirthRegistryObservationWire version descriptor registered) <-
    first (const RpcBirthDescriptorInvalid) (deserialiseOrFail (Lazy.fromStrict body))
  unless (version == 1 && Lazy.toStrict (serialise wire) == body) (Left RpcBirthDescriptorInvalid)
  birth <- decodeRpcBirthDescriptorObservation scope descriptor
  registry <- first (const RpcBirthSeedInvalid) (decodeRpcKeyRegistry registered)
  let observation = RpcBirthRegistryObservation birth registry
  validateRegistryObservation observation
  pure observation

validateRegistryObservation :: RpcBirthRegistryObservation -> Either RpcBirthError ()
validateRegistryObservation (RpcBirthRegistryObservation birth registry) = do
  validateDescriptorObservation birth
  descriptor <- maybe (Left RpcBirthDescriptorInvalid) Right (rpcBirthObservationDescriptor birth)
  unless
    (rpcKeyRegistryScope registry == rpcBirthDescriptorScope descriptor)
    (Left RpcBirthScopeMismatch)
  original <- rpcBirthOriginalHomeSeed registry
  digest <- rpcBirthSeedDigest original
  unless (digest == rpcBirthDescriptorSeedDigest descriptor) (Left RpcBirthSeedChanged)

rpcBirthObservationPrefix :: ByteString
rpcBirthObservationPrefix = "prodbox-rpc-birth-descriptor-response/v1\NUL"

rpcBirthObservationStatus :: RpcBirthDescriptorObservation -> RpcBirthStatus
rpcBirthObservationStatus (RpcBirthDescriptorObservation value _ _) = value

rpcBirthObservationDescriptor :: RpcBirthDescriptorObservation -> Maybe RpcBirthDescriptor
rpcBirthObservationDescriptor (RpcBirthDescriptorObservation _ value _) = value

rpcBirthObservationRequiresRegistration :: RpcBirthDescriptorObservation -> Bool
rpcBirthObservationRequiresRegistration (RpcBirthDescriptorObservation _ _ value) = value

encodeRpcBirthDescriptorObservation
  :: RpcBirthDescriptorObservation -> Either RpcBirthError ByteString
encodeRpcBirthDescriptorObservation observation@(RpcBirthDescriptorObservation status descriptor pinned) = do
  validateDescriptorObservation observation
  encoded <- traverse encodeRpcBirthDescriptor descriptor
  let bytes =
        rpcBirthObservationPrefix
          <> Lazy.toStrict (serialise (RpcBirthObservationWire 1 status encoded pinned))
  unless (BS.length bytes <= rpcBirthObservationMaximumBytes) (Left RpcBirthStateTooLarge)
  pure bytes

decodeRpcBirthDescriptorObservation
  :: AuthorityScope -> ByteString -> Either RpcBirthError RpcBirthDescriptorObservation
decodeRpcBirthDescriptorObservation scope bytes = do
  unless (BS.length bytes <= rpcBirthObservationMaximumBytes) (Left RpcBirthStateTooLarge)
  body <-
    maybe (Left RpcBirthDescriptorInvalid) Right (BS.stripPrefix rpcBirthObservationPrefix bytes)
  wire@(RpcBirthObservationWire version status descriptor pinned) <-
    first (const RpcBirthDescriptorInvalid) (deserialiseOrFail (Lazy.fromStrict body))
  unless (version == 1 && Lazy.toStrict (serialise wire) == body) (Left RpcBirthDescriptorInvalid)
  decoded <- traverse (decodeRpcBirthDescriptor scope) descriptor
  let observation = RpcBirthDescriptorObservation status decoded pinned
  validateDescriptorObservation observation
  pure observation

validateDescriptorObservation :: RpcBirthDescriptorObservation -> Either RpcBirthError ()
validateDescriptorObservation (RpcBirthDescriptorObservation status descriptor pinned) =
  case (rpcBirthStatusPhase status, descriptor) of
    (BirthLegacy, Nothing) ->
      unless
        ( rpcBirthStatusGeneration status == 0
            && not (rpcBirthStatusCommitted status)
            && rpcBirthStatusDescriptorDigest status == Nothing
            && not pinned
        )
        (Left RpcBirthDescriptorInvalid)
    (BirthLegacy, Just _) -> Left RpcBirthDescriptorInvalid
    (_, Nothing) -> Left RpcBirthDescriptorInvalid
    (phase, Just value) ->
      unless
        ( rpcBirthStatusGeneration status == rpcBirthDescriptorGeneration value
            && rpcBirthStatusDescriptorDigest status == Just (rpcBirthDescriptorDigest value)
            && (not (rpcBirthStatusCommitted status) || phase == BirthCommitted)
        )
        (Left RpcBirthDescriptorInvalid)

mkRpcBirthContext
  :: AuthorityScope
  -> RpcBirthServingMode
  -> VerifiedControlPlaneRequest
  -> Either RpcBirthError RpcBirthContext
mkRpcBirthContext expected mode request = do
  validateRpcBirthRequestContext expected request
  command <- decodeRpcBirthCommand (verifiedRequestBody request)
  pure
    ( RpcBirthContext
        expected
        (verifiedRequestAuthorityEpoch request)
        (verifiedRequestDeadline request)
        mode
        command
    )

mkRpcBirthDescriptorContext
  :: AuthorityScope
  -> RpcBirthServingMode
  -> VerifiedControlPlaneRequest
  -> Either RpcBirthError RpcBirthDescriptorContext
mkRpcBirthDescriptorContext expected mode request = do
  validateRpcBirthRequestContext expected request
  unless
    (verifiedRequestBody request `elem` [rpcBirthDescriptorRequest, rpcBirthSignedDescriptorRequest])
    (Left RpcBirthRequestInvalid)
  pure (RpcBirthDescriptorContext expected (verifiedRequestDeadline request) mode)

rpcBirthDescriptorContextDeadline :: RpcBirthDescriptorContext -> AuthorityTime
rpcBirthDescriptorContextDeadline (RpcBirthDescriptorContext _ value _) = value

mkRpcBirthRegistryContext
  :: AuthorityScope
  -> RpcBirthServingMode
  -> VerifiedControlPlaneRequest
  -> Either RpcBirthError RpcBirthRegistryContext
mkRpcBirthRegistryContext expected mode request = do
  validateRpcBirthRequestContext expected request
  unless
    (verifiedRequestBody request `elem` [rpcBirthRegistryRequest, rpcBirthSignedRegistryRequest])
    (Left RpcBirthRequestInvalid)
  pure (RpcBirthRegistryContext expected (verifiedRequestDeadline request) mode)

rpcBirthRegistryContextDeadline :: RpcBirthRegistryContext -> AuthorityTime
rpcBirthRegistryContextDeadline (RpcBirthRegistryContext _ value _) = value

validateRpcBirthRequestContext
  :: AuthorityScope -> VerifiedControlPlaneRequest -> Either RpcBirthError ()
validateRpcBirthRequestContext expected request = do
  unless (verifiedRequestAuthorityScope request == expected) (Left RpcBirthScopeMismatch)
  unless
    ( verifiedRequestRoute request == LifecycleMigrationApply
        && verifiedRequestCalleeRole request == LifecycleAuthorityRuntime
        && verifiedRequestCallerPrincipal request `elem` [CallerOperatorCli, CallerTestHarness]
    )
    (Left RpcBirthRequestContextInvalid)

rpcBirthContextDeadline :: RpcBirthContext -> AuthorityTime
rpcBirthContextDeadline (RpcBirthContext _ _ value _ _) = value

encodeRpcBirthCommand :: RpcBirthCommand -> ByteString
encodeRpcBirthCommand command = rpcBirthRequestPrefix <> Lazy.toStrict (encodeControlPlaneRequest command)

decodeRpcBirthCommand :: ByteString -> Either RpcBirthError RpcBirthCommand
decodeRpcBirthCommand bytes = do
  body <- maybe (Left RpcBirthRequestInvalid) Right (BS.stripPrefix rpcBirthRequestPrefix bytes)
  command <-
    first (const RpcBirthRequestInvalid) (decodeControlPlaneRequest 2048 (Lazy.fromStrict body))
  let validate generation key =
        unless
          ( generation > 0
              && generation <= fromIntegral (maxBound :: Word64)
              && Text.length key == 32
              && Text.all (\character -> character `elem` (['0' .. '9'] <> ['a' .. 'f'])) key
          )
          (Left RpcBirthRequestInvalid)
  case command of
    ObserveRpcBirth -> Right ()
    PrepareRpcBirth generation key -> validate generation key
    CompleteRpcBirth generation key -> validate generation key
    AbortRpcBirth generation key -> validate generation key
  pure command

isRpcBirthObservation :: ByteString -> Bool
isRpcBirthObservation bytes = decodeRpcBirthCommand bytes == Right ObserveRpcBirth

data RpcBirthProgram result where
  ReadRpcBirthTime :: RpcBirthProgram AuthorityTime
  ReadRpcBirthRecord :: RpcBirthProgram (ModelBObservation RpcBirthRecord)
  ReadRpcBirthMarker :: RpcBirthProgram (ModelBObservation RpcBirthMarker)
  ReadRpcBirthHomeSeed :: RpcBirthProgram RpcKeyRegistry
  CasRpcBirthRecord
    :: ModelBObjectVersion -> RpcBirthRecord -> RpcBirthProgram (ModelBCasResult RpcBirthRecord)
  CasRpcBirthMarker
    :: Maybe ModelBObjectVersion -> RpcBirthMarker -> RpcBirthProgram (ModelBCasResult RpcBirthMarker)

newtype RpcBirthInterpreter m = RpcBirthInterpreter
  { runRpcBirthProgram
      :: forall result
       . AuthorityTime
      -> RpcBirthProgram result
      -> m (Either RpcBirthError result)
  }

data RpcBirthPair
  = RpcBirthPair
      !(Maybe (ModelBObjectVersion, RpcBirthRecord))
      !(Maybe (ModelBObjectVersion, RpcBirthMarker))

-- This interpreter cannot name a seed/key read or a mutation. The adapter
-- restricts the already owned native capability without creating another owner.
data RpcBirthReadProgram result where
  ReadBirthObservationTime :: RpcBirthReadProgram AuthorityTime
  ReadBirthObservationRecord :: RpcBirthReadProgram (ModelBObservation RpcBirthRecord)
  ReadBirthObservationMarker :: RpcBirthReadProgram (ModelBObservation RpcBirthMarker)

newtype RpcBirthReadInterpreter m = RpcBirthReadInterpreter
  { runRpcBirthReadProgram
      :: forall result
       . AuthorityTime
      -> RpcBirthReadProgram result
      -> m (Either RpcBirthError result)
  }

rpcBirthReadInterpreter :: forall m. RpcBirthInterpreter m -> RpcBirthReadInterpreter m
rpcBirthReadInterpreter interpreter = RpcBirthReadInterpreter readOnly
 where
  readOnly
    :: forall result. AuthorityTime -> RpcBirthReadProgram result -> m (Either RpcBirthError result)
  readOnly deadline program = case program of
    ReadBirthObservationTime -> runRpcBirthProgram interpreter deadline ReadRpcBirthTime
    ReadBirthObservationRecord -> runRpcBirthProgram interpreter deadline ReadRpcBirthRecord
    ReadBirthObservationMarker -> runRpcBirthProgram interpreter deadline ReadRpcBirthMarker

rpcBirthReadEffect
  :: (Monad m)
  => RpcBirthReadInterpreter m
  -> AuthorityTime
  -> RpcBirthReadProgram result
  -> ExceptT RpcBirthError m result
rpcBirthReadEffect interpreter deadline program = do
  now <- ExceptT (runRpcBirthReadProgram interpreter deadline ReadBirthObservationTime)
  when (now >= deadline) (throwE RpcBirthDeadlineReached)
  value <- ExceptT (runRpcBirthReadProgram interpreter deadline program)
  closing <- ExceptT (runRpcBirthReadProgram interpreter deadline ReadBirthObservationTime)
  when (closing >= deadline) (throwE RpcBirthDeadlineReached)
  pure value

readRpcBirthPairWithin
  :: (Monad m)
  => RpcBirthReadInterpreter m
  -> AuthorityScope
  -> RpcBirthServingMode
  -> AuthorityTime
  -> ExceptT RpcBirthError m RpcBirthPair
readRpcBirthPairWithin interpreter scope mode deadline = do
  record <- rpcBirthReadEffect interpreter deadline ReadBirthObservationRecord
  marker <- rpcBirthReadEffect interpreter deadline ReadBirthObservationMarker
  confirmation <- rpcBirthReadEffect interpreter deadline ReadBirthObservationRecord
  let confirmed = confirmRpcBirthPrimaryObservation record confirmation
  pair <- either throwE pure (pairFromObservations confirmed marker)
  either throwE pure (validatePair pair)
  case pair of
    RpcBirthPair Nothing _ -> when (rpcBirthServingModeRequiresRegistration mode) (throwE RpcBirthAdmissionMissing)
    RpcBirthPair (Just (_, selectedRecord)) _ -> case rpcBirthDescriptor selectedRecord of
      Nothing -> when (rpcBirthServingModeRequiresRegistration mode) (throwE RpcBirthRegisteredStateUnbound)
      Just descriptor -> do
        unless (rpcBirthDescriptorScope descriptor == scope) (throwE RpcBirthScopeMismatch)
        when
          (rpcBirthServingModeRequiresRegistration mode && not (rpcBirthServingModeMatches mode descriptor))
          (throwE RpcBirthMarkerMismatch)
  pure pair

executeRpcBirthDescriptorObservation
  :: (Monad m)
  => RpcBirthReadInterpreter m
  -> RpcBirthDescriptorContext
  -> m (Either RpcBirthError RpcBirthDescriptorObservation)
executeRpcBirthDescriptorObservation interpreter (RpcBirthDescriptorContext scope deadline mode) = runExceptT $ do
  RpcBirthPair record marker <- readRpcBirthPairWithin interpreter scope mode deadline
  let observation =
        RpcBirthDescriptorObservation
          (statusFor record marker)
          (record >>= rpcBirthDescriptor . snd)
          (rpcBirthServingModeRequiresRegistration mode)
  _ <- either throwE pure (encodeRpcBirthDescriptorObservation observation)
  pure observation

executeRpcBirthRegistryObservation
  :: (Monad m)
  => RpcBirthReadInterpreter m
  -> RpcBirthRegistryContext
  -> m (Either RpcBirthError RpcBirthRegistryObservation)
executeRpcBirthRegistryObservation interpreter (RpcBirthRegistryContext scope deadline mode) = runExceptT $ do
  RpcBirthPair record marker <- readRpcBirthPairWithin interpreter scope mode deadline
  selected <-
    either throwE pure $
      rpcBirthAuthenticationRegistry
        mode
        (maybe ModelBMissing (uncurry ModelBObserved) record)
        (maybe ModelBMissing (uncurry ModelBObserved) marker)
  registry <- maybe (throwE RpcBirthAdmissionMissing) pure selected
  let birth =
        RpcBirthDescriptorObservation
          (statusFor record marker)
          (record >>= rpcBirthDescriptor . snd)
          (rpcBirthServingModeRequiresRegistration mode)
      observation = RpcBirthRegistryObservation birth registry
  _ <- either throwE pure (encodeRpcBirthRegistryObservation observation)
  pure observation

-- Public discovery selects one exact external origin from the same fenced
-- authentication projection. It cannot name native seed observation or CAS,
-- and deliberately returns neither the full registry nor the birth record.
executeRpcBirthOwnBindingHint
  :: (Monad m)
  => RpcBirthReadInterpreter m
  -> AuthorityScope
  -> RpcBirthServingMode
  -> AuthorityTime
  -> RpcOwnBindingQuery
  -> m (Either RpcBirthError RpcOwnBindingHint)
executeRpcBirthOwnBindingHint interpreter scope mode deadline query = runExceptT $ do
  unless (rpcOwnBindingQueryScope query == scope) (throwE RpcBirthScopeMismatch)
  unless (rpcBirthServingModeRequiresRegistration mode) (throwE RpcBirthRegisteredStateUnbound)
  RpcBirthPair record marker <- readRpcBirthPairWithin interpreter scope mode deadline
  selected <-
    either throwE pure $
      rpcBirthAuthenticationRegistry
        mode
        (maybe ModelBMissing (uncurry ModelBObserved) record)
        (maybe ModelBMissing (uncurry ModelBObserved) marker)
  registry <- maybe (throwE RpcBirthAdmissionMissing) pure selected
  either (const (throwE RpcBirthRequestContextInvalid)) pure (selectRpcOwnBindingHint query registry)

-- Runtime trust/signing and authenticated observation share this exact fenced
-- projection. Absence never permits a fresh native seed read.
rpcBirthAuthenticationRegistry
  :: RpcBirthServingMode
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError (Maybe RpcKeyRegistry)
rpcBirthAuthenticationRegistry mode record marker = do
  aggregate <- rpcBirthAuthenticationAdmission mode record marker
  case aggregate >>= authorityAggregateRpcKeyRegistry of
    Just registry -> Right (Just registry)
    Nothing -> Right $ case record of
      ModelBObserved _ value -> rpcBirthPublicSeed value
      _ -> Nothing

-- These projections consume authoritative observations, not caller metadata.
observeRpcBirthPair
  :: ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError (RpcBirthStatus, Maybe AuthorityAdmissionAggregate)
observeRpcBirthPair recordObservation markerObservation = do
  pair <- pairFromObservations recordObservation markerObservation
  validatePair pair
  let RpcBirthPair record marker = pair
  pure (statusFor record marker, rpcBirthAdmission . snd <$> record)

rpcBirthNormalAdmission
  :: RpcBirthServingMode
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError (Maybe (ModelBObjectVersion, AuthorityAdmissionAggregate))
rpcBirthNormalAdmission mode recordObservation markerObservation = do
  pair@(RpcBirthPair record marker) <- pairFromObservations recordObservation markerObservation
  validatePair pair
  case record of
    Nothing
      | rpcBirthServingModeRequiresRegistration mode -> Left RpcBirthAdmissionMissing
      | otherwise -> Right Nothing
    Just (version, value) -> case rpcBirthPhase value of
      BirthLegacy
        | not (rpcBirthServingModeRequiresRegistration mode) ->
            Right (Just (version, rpcBirthAdmission value))
      BirthRetired
        | not (rpcBirthServingModeRequiresRegistration mode) ->
            Right (Just (version, rpcBirthAdmission value))
      BirthCommitted
        | maybe False (rpcBirthServingModeMatches mode) (rpcBirthDescriptor value)
        , maybe False ((== BirthMarkerCommitted) . rpcBirthMarkerPhase . snd) marker ->
            Right (Just (version, rpcBirthAdmission value))
      _ -> Left RpcBirthWrongPhase

rpcBirthAuthenticationAdmission
  :: RpcBirthServingMode
  -> ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError (Maybe AuthorityAdmissionAggregate)
rpcBirthAuthenticationAdmission mode record marker = do
  pair@(RpcBirthPair observed _) <- pairFromObservations record marker
  validatePair pair
  case observed of
    Nothing
      | rpcBirthServingModeRequiresRegistration mode -> Left RpcBirthAdmissionMissing
      | otherwise -> Right Nothing
    Just (_, value)
      | rpcBirthPhase value == BirthCommitted
      , not (rpcBirthServingModeRequiresRegistration mode) ->
          Left RpcBirthPublicationRequired
      | not (rpcBirthServingModeRequiresRegistration mode) -> Right (Just (rpcBirthAdmission value))
      | maybe False (rpcBirthServingModeMatches mode) (rpcBirthDescriptor value)
          && rpcBirthPhase value /= BirthLegacy ->
          Right (Just (rpcBirthAdmission value))
      | otherwise -> Left RpcBirthMarkerMismatch

pairFromObservations
  :: ModelBObservation RpcBirthRecord
  -> ModelBObservation RpcBirthMarker
  -> Either RpcBirthError RpcBirthPair
pairFromObservations record marker = RpcBirthPair <$> observed record <*> observed marker
 where
  observed observation = case observation of
    ModelBMissing -> Right Nothing
    ModelBObserved version value -> Right (Just (version, value))
    ModelBCorrupt _ -> Left RpcBirthStateInvalid
    ModelBEndpointUnready _ -> Left RpcBirthObservationUnavailable
    ModelBUnobservable _ -> Left RpcBirthObservationUnavailable

validatePair :: RpcBirthPair -> Either RpcBirthError ()
validatePair (RpcBirthPair Nothing Nothing) = Right ()
validatePair (RpcBirthPair Nothing (Just _)) = Left RpcBirthAdmissionMissing
validatePair (RpcBirthPair (Just (_, record)) marker) =
  case rpcBirthPhase record of
    BirthLegacy -> unless (marker == Nothing) (Left RpcBirthRegisteredStateUnbound)
    phase -> do
      descriptor <- maybe (Left RpcBirthDescriptorInvalid) Right (rpcBirthDescriptor record)
      let exact expected = maybe False (rpcBirthMarkerMatches expected descriptor . snd) marker
          predecessor = case marker of
            Nothing -> rpcBirthDescriptorGeneration descriptor == 1
            Just (_, value) ->
              rpcBirthMarkerScope value == rpcBirthDescriptorScope descriptor
                && rpcBirthMarkerPhase value == BirthMarkerRetired
                && rpcBirthMarkerGeneration value + 1 == rpcBirthDescriptorGeneration descriptor
          require condition =
            unless
              condition
              (Left (if marker == Nothing then RpcBirthMarkerMissing else RpcBirthMarkerMismatch))
      case phase of
        BirthPrepared -> require (predecessor || exact BirthMarkerPrepared)
        BirthArmed -> require (exact BirthMarkerPrepared)
        BirthCommitted -> require (exact BirthMarkerPrepared || exact BirthMarkerCommitted)
        BirthRetiring -> require (predecessor || exact BirthMarkerPrepared || exact BirthMarkerRetired)
        BirthRetired -> require (exact BirthMarkerRetired)

statusFor
  :: Maybe (ModelBObjectVersion, RpcBirthRecord)
  -> Maybe (ModelBObjectVersion, RpcBirthMarker)
  -> RpcBirthStatus
statusFor record marker = RpcBirthStatus phase generation published binding
 where
  phase = maybe BirthLegacy (rpcBirthPhase . snd) record
  generation = maybe 0 (maybe 0 rpcBirthDescriptorGeneration . rpcBirthDescriptor . snd) record
  binding = fmap rpcBirthDescriptorDigest (record >>= rpcBirthDescriptor . snd)
  published =
    phase == BirthCommitted
      && maybe False ((== BirthMarkerCommitted) . rpcBirthMarkerPhase . snd) marker

executeRpcBirth
  :: forall m
   . (Monad m)
  => RpcBirthInterpreter m
  -> RpcBirthContext
  -> m (Either RpcBirthError RpcBirthStatus)
executeRpcBirth interpreter (RpcBirthContext scope epoch parentDeadline mode command) = runExceptT $ do
  pair <- readPair parentDeadline
  case command of
    ObserveRpcBirth -> pure (pairStatus pair)
    PrepareRpcBirth generation key -> prepare generation key pair
    CompleteRpcBirth generation key -> drive False generation key (6 :: Int) pair
    AbortRpcBirth generation key -> drive True generation key (6 :: Int) pair
 where
  effect :: forall result. AuthorityTime -> RpcBirthProgram result -> ExceptT RpcBirthError m result
  effect deadline program = do
    now <- ExceptT (runRpcBirthProgram interpreter deadline ReadRpcBirthTime)
    when (now >= deadline) (throwE RpcBirthDeadlineReached)
    value <- ExceptT (runRpcBirthProgram interpreter deadline program)
    closing <- ExceptT (runRpcBirthProgram interpreter deadline ReadRpcBirthTime)
    when (closing >= deadline) (throwE RpcBirthDeadlineReached)
    pure value
  readPair deadline =
    readRpcBirthPairWithin (rpcBirthReadInterpreter interpreter) scope mode deadline
  pairStatus (RpcBirthPair record marker) = statusFor record marker
  requireRecord (RpcBirthPair record _) = maybe (throwE RpcBirthAdmissionMissing) pure record
  descriptorFor generation key record = do
    descriptor <- maybe (throwE RpcBirthLegacyStateRequired) pure (rpcBirthDescriptor record)
    unless (rpcBirthDescriptorScope descriptor == scope) (throwE RpcBirthScopeMismatch)
    unless
      (rpcBirthDescriptorGeneration descriptor == generation && rpcBirthDescriptorKey descriptor == key)
      (throwE RpcBirthGenerationMismatch)
    pure descriptor
  prepare generation key pair = do
    (version, record) <- requireRecord pair
    if rpcBirthPhase record `notElem` [BirthLegacy, BirthRetired]
      then do
        _ <- descriptorFor generation key record
        pure (pairStatus pair)
      else do
        when (rpcBirthServingModeRequiresRegistration mode) (throwE RpcBirthAlreadyCommitted)
        unless
          (authorityAggregateAuthenticationEpoch (rpcBirthAdmission record) == epoch)
          (throwE RpcBirthRequestContextInvalid)
        either throwE pure (validateRpcBirthPredecessor (rpcBirthAdmission record))
        seed <- effect parentDeadline ReadRpcBirthHomeSeed
        descriptor <-
          either
            throwE
            pure
            ( mkRpcBirthDescriptor
                scope
                generation
                key
                epoch
                parentDeadline
                version
                seed
                (authorityAggregateRegisteredClients (rpcBirthAdmission record))
            )
        next <- either throwE (pure . rpcBirthStageRecord) (prepareRpcBirth descriptor seed record)
        writeRecord parentDeadline version next
        fresh <- readPair parentDeadline
        -- No marker write happens before the primary's fence is read back.
        pure (pairStatus fresh)
  drive cleanup generation key remaining pair@(RpcBirthPair _ marker) = do
    when (remaining <= 0) (throwE RpcBirthWriteUnconfirmed)
    (version, record) <- requireRecord pair
    descriptor <- descriptorFor generation key record
    let deadline =
          if cleanup || rpcBirthPhase record == BirthCommitted
            then parentDeadline
            else min parentDeadline (rpcBirthDescriptorDeadline descriptor)
        currentMarker = snd <$> marker
        mark phase = rpcBirthMarkerFor phase descriptor
        continue = readPair deadline >>= drive cleanup generation key (remaining - 1)
        advance
          :: RpcBirthTransition from to -> RpcBirthPhaseWitness from -> ExceptT RpcBirthError m RpcBirthStatus
        advance transition witness = do
          stage <- maybe (throwE RpcBirthWrongPhase) pure (rpcBirthStage witness record)
          next <- either throwE (pure . rpcBirthStageRecord) (advanceRpcBirth transition stage currentMarker)
          writeRecord deadline version next
          continue
        writeMarker phase = writeMarkerAndConfirm deadline (fst <$> marker) (mark phase) >> continue
    if cleanup
      then case rpcBirthPhase record of
        BirthLegacy -> throwE RpcBirthLegacyStateRequired
        BirthCommitted -> throwE RpcBirthAlreadyCommitted
        BirthRetired -> pure (pairStatus pair)
        BirthPrepared -> advance RetirePreparedRpcBirth PreparedBirth
        BirthArmed -> advance RetireArmedRpcBirth ArmedBirth
        BirthRetiring
          | maybe False (rpcBirthMarkerMatches BirthMarkerRetired descriptor) currentMarker ->
              advance FinishRpcBirthRetirement RetiringBirth
          | otherwise -> writeMarker BirthMarkerRetired
      else do
        unless
          ( if rpcBirthPhase record == BirthCommitted
              then
                authorityAggregateAuthenticationEpoch (rpcBirthAdmission record) == epoch
                  && epoch >= rpcBirthDescriptorEpoch descriptor
              else rpcBirthDescriptorEpoch descriptor == epoch
          )
          (throwE RpcBirthRequestContextInvalid)
        case rpcBirthPhase record of
          BirthLegacy -> throwE RpcBirthLegacyStateRequired
          BirthRetiring -> throwE RpcBirthWrongPhase
          BirthRetired -> throwE RpcBirthWrongPhase
          BirthPrepared
            | maybe False (rpcBirthMarkerMatches BirthMarkerPrepared descriptor) currentMarker ->
                advance ArmRpcBirth PreparedBirth
            | otherwise -> writeMarker BirthMarkerPrepared
          BirthArmed -> do
            unless (rpcBirthServingModeMatches mode descriptor) (throwE RpcBirthPublicationRequired)
            actual <- effect deadline ReadRpcBirthHomeSeed
            unless (Just actual == rpcBirthCandidate record) (throwE RpcBirthNativeSourceChanged)
            advance CommitRpcBirth ArmedBirth
          BirthCommitted
            | maybe False (rpcBirthMarkerMatches BirthMarkerCommitted descriptor) currentMarker ->
                pure (pairStatus pair)
            | otherwise -> writeMarker BirthMarkerCommitted
  writeRecord deadline version next = do
    _ <- effect deadline (CasRpcBirthRecord version next)
    readback <- effect deadline ReadRpcBirthRecord
    case readback of
      ModelBObserved _ actual | actual == next -> pure ()
      _ -> throwE RpcBirthWriteUnconfirmed
  writeMarkerAndConfirm deadline version next = do
    _ <- effect deadline (CasRpcBirthMarker version next)
    readback <- effect deadline ReadRpcBirthMarker
    case readback of
      ModelBObserved _ actual | actual == next -> pure ()
      _ -> throwE RpcBirthWriteUnconfirmed
