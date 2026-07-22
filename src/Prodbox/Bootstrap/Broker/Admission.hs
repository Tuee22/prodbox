{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}

-- | Pure bounded admission for the loopback Bootstrap Broker.  Queue wait,
-- service, durable read-back, and response serialization spend one absolute
-- deadline minted when the request entered the process.
module Prodbox.Bootstrap.Broker.Admission
  ( AdmissionLimits
  , mkAdmissionLimits
  , DrainState (..)
  , IdempotencyRecord (..)
  , AdmissionLane
  , emptyAdmissionLane
  , beginDraining
  , AdmissionTicket (..)
  , AdmissionDisposition (..)
  , AdmissionRefusal (..)
  , AdmissionResult (..)
  , admitRequest
  , startAdmission
  , completeAdmission
  , cancelAdmission
  , forgetCompletedAdmission
  , forgetCancelledAdmission
  , queuedAdmissions
  , activeAdmissions
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request
  ( BrokerOperationTag (..)
  , BrokerRequest (..)
  , BrokerServiceIdentity
  , HttpMethod (..)
  , IdempotencyKey
  , RequestDigest
  , RequestMetadata (..)
  , requestAbsoluteDeadline
  , requestCarriesSecret
  , secretPayloadLength
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineAdmission (..)
  , DeadlineObservation (..)
  , MonotonicInstant
  , RemainingDuration (..)
  , RetryAfter (..)
  , WorkEstimate (..)
  , deadlineAdmission
  , deadlineObservation
  )

data AdmissionLimits = AdmissionLimits
  { limitMaximumBodyBytes :: !Natural
  , limitQueueCapacity :: !Natural
  , limitServiceMicros :: !Natural
  , limitReadBackMicros :: !Natural
  , limitSerializationMicros :: !Natural
  }
  deriving stock (Eq, Show)

mkAdmissionLimits
  :: Natural
  -> Natural
  -> Natural
  -> Natural
  -> Natural
  -> Either String AdmissionLimits
mkAdmissionLimits maximumBodyBytes queueCapacity serviceMicros readBackMicros serializationMicros = do
  requirePositive "maximum body bytes" maximumBodyBytes
  requirePositive "queue capacity" queueCapacity
  requirePositive "service estimate" serviceMicros
  requirePositive "read-back estimate" readBackMicros
  requirePositive "serialization estimate" serializationMicros
  Right
    AdmissionLimits
      { limitMaximumBodyBytes = maximumBodyBytes
      , limitQueueCapacity = queueCapacity
      , limitServiceMicros = serviceMicros
      , limitReadBackMicros = readBackMicros
      , limitSerializationMicros = serializationMicros
      }

data DrainState
  = AdmissionServing
  | AdmissionDraining
  deriving stock (Eq, Show)

data IdempotencyRecord
  = IdempotencyQueued !RequestDigest !BrokerOperationTag !Deadline
  | IdempotencyRunning !RequestDigest !BrokerOperationTag !Deadline
  | IdempotencyCompleted !RequestDigest !BrokerOperationTag !RequestDigest
  | IdempotencyCancelled !RequestDigest !BrokerOperationTag
  deriving stock (Eq, Show)

data AdmissionLane = AdmissionLane
  { laneDrainState :: !DrainState
  , laneQueued :: !Natural
  , laneActive :: !Natural
  , laneIdempotency :: !(Map IdempotencyKey IdempotencyRecord)
  }
  deriving stock (Eq, Show)

emptyAdmissionLane :: AdmissionLane
emptyAdmissionLane =
  AdmissionLane
    { laneDrainState = AdmissionServing
    , laneQueued = 0
    , laneActive = 0
    , laneIdempotency = Map.empty
    }

beginDraining :: AdmissionLane -> AdmissionLane
beginDraining lane = lane {laneDrainState = AdmissionDraining}

data AdmissionTicket = AdmissionTicket
  { ticketIdempotencyKey :: !IdempotencyKey
  , ticketRequestDigest :: !RequestDigest
  , ticketOperation :: !BrokerOperationTag
  , ticketDeadline :: !Deadline
  }
  deriving stock (Eq, Show)

data AdmissionDisposition
  = AdmissionNew !AdmissionTicket
  | AdmissionResumeQueued !AdmissionTicket
  | AdmissionResumeRunning !AdmissionTicket
  | AdmissionReturnCached !RequestDigest
  deriving stock (Eq, Show)

data AdmissionRefusal
  = RefuseWrongServiceIdentity
  | RefuseMethod
  | RefuseBodyRequired
  | RefuseBodyForbidden
  | RefuseSecretForbidden
  | RefuseBodyTooLarge !Natural !Natural
  | RefuseContentLengthMismatch !Natural !Natural
  | RefuseIdempotencyConflict
  | RefuseDraining
  | RefuseSaturated !RetryAfter
  | RefuseDeadlineExpired
  | RefuseDeadlineInfeasible !RemainingDuration
  deriving stock (Eq, Show)

data AdmissionResult
  = AdmissionAccepted !AdmissionDisposition
  | AdmissionRefused !AdmissionRefusal
  deriving stock (Eq, Show)

data BodyContract
  = BodyForbidden
  | BodyRequired
  deriving stock (Eq, Show)

admitRequest
  :: MonotonicInstant
  -> BrokerServiceIdentity
  -> AdmissionLimits
  -> AdmissionLane
  -> BrokerRequest
  -> (AdmissionLane, AdmissionResult)
admitRequest now expectedIdentity limits lane request =
  case validateRequestShape expectedIdentity limits request of
    Left refusal -> (lane, AdmissionRefused refusal)
    Right () -> admitValidated
 where
  metadata = brokerRequestMetadata request
  key = requestIdempotencyKey metadata
  digest = requestDigest metadata
  operation = brokerRequestOperation request
  deadline = requestAbsoluteDeadline request
  ticket = AdmissionTicket key digest operation deadline

  admitValidated =
    case Map.lookup key (laneIdempotency lane) of
      Just record -> admitExisting record
      Nothing -> admitFresh AdmissionNew

  admitExisting record =
    case record of
      IdempotencyQueued recordedDigest recordedOperation recordedDeadline
        | exactRequest recordedDigest recordedOperation ->
            ( lane
            , AdmissionAccepted
                (AdmissionResumeQueued (AdmissionTicket key digest operation recordedDeadline))
            )
        | otherwise -> conflict
      IdempotencyRunning recordedDigest recordedOperation recordedDeadline
        | exactRequest recordedDigest recordedOperation ->
            ( lane
            , AdmissionAccepted
                (AdmissionResumeRunning (AdmissionTicket key digest operation recordedDeadline))
            )
        | otherwise -> conflict
      IdempotencyCompleted recordedDigest recordedOperation responseDigest
        | exactRequest recordedDigest recordedOperation ->
            (lane, AdmissionAccepted (AdmissionReturnCached responseDigest))
        | otherwise -> conflict
      IdempotencyCancelled recordedDigest recordedOperation
        | exactRequest recordedDigest recordedOperation -> admitFresh AdmissionNew
        | otherwise -> conflict

  exactRequest recordedDigest recordedOperation =
    recordedDigest == digest && recordedOperation == operation

  conflict = (lane, AdmissionRefused RefuseIdempotencyConflict)

  admitFresh disposition =
    case freshAdmissionRefusal now limits lane deadline of
      Just refusal -> (lane, AdmissionRefused refusal)
      Nothing ->
        let acceptedLane =
              lane
                { laneQueued = laneQueued lane + 1
                , laneIdempotency =
                    Map.insert key (IdempotencyQueued digest operation deadline) (laneIdempotency lane)
                }
         in (acceptedLane, AdmissionAccepted (disposition ticket))

freshAdmissionRefusal
  :: MonotonicInstant
  -> AdmissionLimits
  -> AdmissionLane
  -> Deadline
  -> Maybe AdmissionRefusal
freshAdmissionRefusal now limits lane deadline =
  case laneDrainState lane of
    AdmissionDraining -> Just RefuseDraining
    AdmissionServing
      | occupied >= limitQueueCapacity limits ->
          Just (RefuseSaturated (RetryAfter (limitServiceMicros limits * (laneQueued lane + 1))))
      | otherwise -> deadlineRefusal
 where
  occupied = laneQueued lane + laneActive lane
  totalEstimate =
    WorkEstimate
      ( occupied * limitServiceMicros limits
          + limitServiceMicros limits
          + limitReadBackMicros limits
          + limitSerializationMicros limits
      )
  deadlineRefusal =
    case deadlineObservation now deadline of
      DeadlineExpired -> Just RefuseDeadlineExpired
      DeadlineOpen remaining ->
        case deadlineAdmission remaining totalEstimate of
          AdmissionWithinDeadline _ -> Nothing
          AdmissionMissesDeadline deficit -> Just (RefuseDeadlineInfeasible deficit)

validateRequestShape
  :: BrokerServiceIdentity
  -> AdmissionLimits
  -> BrokerRequest
  -> Either AdmissionRefusal ()
validateRequestShape expectedIdentity limits request = do
  if requestCallerIdentity metadata == expectedIdentity
    then Right ()
    else Left RefuseWrongServiceIdentity
  if requestContentLength metadata <= limitMaximumBodyBytes limits
    then Right ()
    else
      Left
        ( RefuseBodyTooLarge
            (requestContentLength metadata)
            (limitMaximumBodyBytes limits)
        )
  case brokerRequestSecret request of
    Just secret
      | secretPayloadLength secret /= requestContentLength metadata ->
          Left
            ( RefuseContentLengthMismatch
                (requestContentLength metadata)
                (secretPayloadLength secret)
            )
    _ -> Right ()
  validateBodyContract (operationContract (brokerRequestOperation request)) request
 where
  metadata = brokerRequestMetadata request

validateBodyContract
  :: (HttpMethod, BodyContract)
  -> BrokerRequest
  -> Either AdmissionRefusal ()
validateBodyContract (expectedMethod, bodyContract) request = do
  if brokerRequestMethod request == expectedMethod
    then Right ()
    else Left RefuseMethod
  case bodyContract of
    BodyForbidden
      | requestContentLength metadata /= 0 -> Left RefuseBodyForbidden
      | requestCarriesSecret request -> Left RefuseSecretForbidden
      | otherwise -> Right ()
    BodyRequired
      | requestContentLength metadata == 0 -> Left RefuseBodyRequired
      | requestCarriesSecret request -> Left RefuseSecretForbidden
      | otherwise -> Right ()
 where
  metadata = brokerRequestMetadata request

operationContract :: BrokerOperationTag -> (HttpMethod, BodyContract)
operationContract operation =
  case operation of
    BrokerHealth -> (HttpGet, BodyForbidden)
    BrokerReadiness -> (HttpGet, BodyForbidden)
    ObserveBootstrapStatus -> (HttpGet, BodyForbidden)
    EnsureVaultInitialized -> (HttpPost, BodyRequired)
    EnsureVaultUnsealed -> (HttpPost, BodyRequired)
    SealVault -> (HttpPost, BodyRequired)
    RotateUnlockBundle -> (HttpPost, BodyRequired)
    RotateTransitKey -> (HttpPost, BodyRequired)
    RecoverAmbiguousInitialization -> (HttpPost, BodyRequired)
    ReconcileVaultBaseline -> (HttpPost, BodyRequired)
    ObserveVaultPki -> (HttpGet, BodyForbidden)
    IssueVaultPkiTestCertificate -> (HttpPost, BodyRequired)
    CommitChildInitCustody -> (HttpPost, BodyRequired)
    DeliverChildRecovery -> (HttpPost, BodyRequired)
    ObserveChildRecoveryDelivery -> (HttpPost, BodyRequired)

startAdmission :: AdmissionTicket -> AdmissionLane -> Either String AdmissionLane
startAdmission ticket lane =
  case Map.lookup (ticketIdempotencyKey ticket) (laneIdempotency lane) of
    Just (IdempotencyQueued digest operation deadline)
      | digest == ticketRequestDigest ticket
          && operation == ticketOperation ticket
          && deadline == ticketDeadline ticket
          && laneQueued lane > 0 ->
          Right
            lane
              { laneQueued = laneQueued lane - 1
              , laneActive = laneActive lane + 1
              , laneIdempotency =
                  Map.insert
                    (ticketIdempotencyKey ticket)
                    (IdempotencyRunning digest operation deadline)
                    (laneIdempotency lane)
              }
    _ -> Left "admission ticket does not name the currently queued request"

completeAdmission
  :: AdmissionTicket
  -> RequestDigest
  -> AdmissionLane
  -> Either String AdmissionLane
completeAdmission ticket responseDigest lane =
  finishRunning ticket lane $ \digest operation ->
    IdempotencyCompleted digest operation responseDigest

cancelAdmission :: AdmissionTicket -> AdmissionLane -> Either String AdmissionLane
cancelAdmission ticket lane =
  finishRunning ticket lane IdempotencyCancelled

-- | Evict one cached response binding after the runtime evicts the matching
-- bounded reply bytes.  A queued, running, or cancelled request is never
-- removed by this function, so cache pressure cannot create a second live
-- execution for an admitted key.
forgetCompletedAdmission :: IdempotencyKey -> AdmissionLane -> AdmissionLane
forgetCompletedAdmission key lane =
  case Map.lookup key (laneIdempotency lane) of
    Just IdempotencyCompleted {} ->
      lane {laneIdempotency = Map.delete key (laneIdempotency lane)}
    _ -> lane

-- | Drop a cancellation tombstone once the runtime has completed cancellation
-- bookkeeping.  Cancellation has no cached response and the same exact request
-- is explicitly retryable, so retaining an unbounded process-local tombstone
-- would add no safety property.
forgetCancelledAdmission :: IdempotencyKey -> AdmissionLane -> AdmissionLane
forgetCancelledAdmission key lane =
  case Map.lookup key (laneIdempotency lane) of
    Just IdempotencyCancelled {} ->
      lane {laneIdempotency = Map.delete key (laneIdempotency lane)}
    _ -> lane

finishRunning
  :: AdmissionTicket
  -> AdmissionLane
  -> (RequestDigest -> BrokerOperationTag -> IdempotencyRecord)
  -> Either String AdmissionLane
finishRunning ticket lane finishedRecord =
  case Map.lookup (ticketIdempotencyKey ticket) (laneIdempotency lane) of
    Just (IdempotencyRunning digest operation deadline)
      | digest == ticketRequestDigest ticket
          && operation == ticketOperation ticket
          && deadline == ticketDeadline ticket
          && laneActive lane > 0 ->
          Right
            lane
              { laneActive = laneActive lane - 1
              , laneIdempotency =
                  Map.insert
                    (ticketIdempotencyKey ticket)
                    (finishedRecord digest operation)
                    (laneIdempotency lane)
              }
    _ -> Left "admission ticket does not name the currently running request"

queuedAdmissions :: AdmissionLane -> Natural
queuedAdmissions = laneQueued

activeAdmissions :: AdmissionLane -> Natural
activeAdmissions = laneActive

requirePositive :: String -> Natural -> Either String ()
requirePositive label value
  | value == 0 = Left (label ++ " must be positive")
  | otherwise = Right ()
