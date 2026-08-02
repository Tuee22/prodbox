{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Secret-safe host coordination for the special pre-Vault federation Jobs.
--
-- The coordinator can represent public keys, ciphertext, Kubernetes object
-- identities, commitments and absence proofs only.  The child worker owns
-- decryption and Secret CAS/read-back; the parent worker owns Transit token
-- creation, return-envelope decryption and parent custody.  A durable
-- ciphertext-only checkpoint closes the crash window between the child
-- worker response and the Authority's child-delivery CAS.
module Prodbox.ControlPlane.FederationBootstrapCoordinator
  ( FederationChildDeliveryCheckpoint
  , mkFederationChildDeliveryCheckpoint
  , federationCheckpointParentEnvelope
  , federationCheckpointWorker
  , federationCheckpointSecretUid
  , federationCheckpointSecretResourceVersion
  , federationCheckpointSecretCommitment
  , federationCheckpointParentCiphertext
  , FederationBootstrapAuthorityBoundary (..)
  , FederationBootstrapChildBoundary (..)
  , FederationBootstrapCheckpointBoundary (..)
  , FederationBootstrapCoordinatorError (..)
  , coordinateFederationBootstrap
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types (ArtifactDigest)
import Prodbox.Cluster.FederationRegistration
  ( ChildBootstrapDeliveryIntent (..)
  , ChildBootstrapDeliveryReceipt (..)
  , ChildBootstrapRecipientAttestation (..)
  , ChildKubernetesUid
  , FederationRegistrationState
  , FederationWorkerBinding
  , FederationWorkerCleanup (..)
  , ParentBootstrapCustodyReceipt (..)
  , ParentBootstrapEnvelope (..)
  , mkChildBootstrapDeliveryReceipt
  , mkFederationWorkerCleanup
  , registrationStateBootstrapCustody
  , registrationStateBootstrapIntent
  , registrationStateChildDelivery
  , registrationStateChildRecipient
  , registrationStateParentEnvelope
  , validateChildBootstrapDeliveryIntent
  , validateChildBootstrapDeliveryReceipt
  , validateChildBootstrapRecipientAttestation
  , validateParentBootstrapCustodyReceipt
  , validateParentBootstrapEnvelope
  )

-- | Durable secret-free result returned by the still-running child Job.  It
-- is persisted before Job deletion; replay can therefore prove absence and
-- reconstruct the exact Authority receipt without retaining an ephemeral
-- private key or plaintext Transit credential on the host.
data FederationChildDeliveryCheckpoint = FederationChildDeliveryCheckpoint
  { internalCheckpointParentEnvelope :: !ParentBootstrapEnvelope
  , internalCheckpointWorker :: !FederationWorkerBinding
  , internalCheckpointSecretUid :: !ChildKubernetesUid
  , internalCheckpointSecretResourceVersion :: !Text
  , internalCheckpointSecretCommitment :: !ArtifactDigest
  , internalCheckpointParentCiphertext :: !ByteString
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show FederationChildDeliveryCheckpoint where
  show checkpoint =
    "FederationChildDeliveryCheckpoint <"
      <> show (ByteString.length (internalCheckpointParentCiphertext checkpoint))
      <> " ciphertext bytes>"

mkFederationChildDeliveryCheckpoint
  :: ParentBootstrapEnvelope
  -> FederationWorkerBinding
  -> ChildKubernetesUid
  -> Text
  -> ArtifactDigest
  -> ByteString
  -> Either FederationBootstrapCoordinatorError FederationChildDeliveryCheckpoint
mkFederationChildDeliveryCheckpoint envelope worker secretUid rawResourceVersion secretCommitment parentCiphertext = do
  _ <- mapRegistrationError (validateParentBootstrapEnvelope envelope)
  if worker
    /= childBootstrapRecipientWorker
      (parentBootstrapEnvelopeChildRecipient envelope)
    then Left FederationBootstrapCoordinatorWorkerBindingMismatch
    else Right ()
  resourceVersion <- validateResourceVersion rawResourceVersion
  if ByteString.null parentCiphertext
    || ByteString.length parentCiphertext > maximumCheckpointCiphertextBytes
    then Left FederationBootstrapCoordinatorCiphertextInvalid
    else
      Right
        FederationChildDeliveryCheckpoint
          { internalCheckpointParentEnvelope = envelope
          , internalCheckpointWorker = worker
          , internalCheckpointSecretUid = secretUid
          , internalCheckpointSecretResourceVersion = resourceVersion
          , internalCheckpointSecretCommitment = secretCommitment
          , internalCheckpointParentCiphertext = parentCiphertext
          }

federationCheckpointParentEnvelope
  :: FederationChildDeliveryCheckpoint -> ParentBootstrapEnvelope
federationCheckpointParentEnvelope = internalCheckpointParentEnvelope

federationCheckpointWorker
  :: FederationChildDeliveryCheckpoint -> FederationWorkerBinding
federationCheckpointWorker = internalCheckpointWorker

federationCheckpointSecretUid
  :: FederationChildDeliveryCheckpoint -> ChildKubernetesUid
federationCheckpointSecretUid = internalCheckpointSecretUid

federationCheckpointSecretResourceVersion
  :: FederationChildDeliveryCheckpoint -> Text
federationCheckpointSecretResourceVersion = internalCheckpointSecretResourceVersion

federationCheckpointSecretCommitment
  :: FederationChildDeliveryCheckpoint -> ArtifactDigest
federationCheckpointSecretCommitment = internalCheckpointSecretCommitment

federationCheckpointParentCiphertext
  :: FederationChildDeliveryCheckpoint -> ByteString
federationCheckpointParentCiphertext = internalCheckpointParentCiphertext

-- | Authenticated Lifecycle Authority calls.  Every implementation must
-- return only after validating the exact typed response evidence.
data FederationBootstrapAuthorityBoundary m = FederationBootstrapAuthorityBoundary
  { authorityPrepareFederationBootstrap
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text ChildBootstrapDeliveryIntent)
  , authorityObserveFederationBootstrap
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text FederationRegistrationState)
  , authorityRecordFederationChildRecipient
      :: ChildBootstrapRecipientAttestation
      -> m (Either Text ParentBootstrapEnvelope)
  , authorityRecordFederationChildDelivery
      :: ChildBootstrapDeliveryReceipt
      -> m (Either Text ParentBootstrapCustodyReceipt)
  }

-- | Child-cluster Job boundary.  Create/recover includes exact
-- Job/Pod/ServiceAccount UID and rollout attestation.  Continue attaches only
-- the parent ciphertext envelope; plaintext never crosses this interface.
data FederationBootstrapChildBoundary m = FederationBootstrapChildBoundary
  { observeFederationBootstrapTimeMicros :: m (Either Text Natural)
  , createOrRecoverFederationChildRecipient
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text ChildBootstrapRecipientAttestation)
  , continueFederationChildDelivery
      :: ParentBootstrapEnvelope
      -> m (Either Text FederationChildDeliveryCheckpoint)
  , cleanupFederationChildWorker
      :: FederationWorkerBinding
      -> m (Either Text FederationWorkerCleanup)
  }

-- | Durable ciphertext-only checkpoint.  Create/delete operations include
-- exact read-back in their production contract; absence is a separate stable
-- observation and cannot be inferred from delete acceptance.
data FederationBootstrapCheckpointBoundary m = FederationBootstrapCheckpointBoundary
  { observeFederationChildDeliveryCheckpoint
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text (Maybe FederationChildDeliveryCheckpoint))
  , createFederationChildDeliveryCheckpoint
      :: ChildBootstrapDeliveryIntent
      -> FederationChildDeliveryCheckpoint
      -> m (Either Text FederationChildDeliveryCheckpoint)
  , deleteFederationChildDeliveryCheckpoint
      :: ChildBootstrapDeliveryIntent
      -> FederationChildDeliveryCheckpoint
      -> m (Either Text ())
  , observeFederationChildDeliveryCheckpointAbsent
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text Bool)
  }

data FederationBootstrapCoordinatorError
  = FederationBootstrapCoordinatorIntentInvalid !Text
  | FederationBootstrapCoordinatorPrepareUnavailable !Text
  | FederationBootstrapCoordinatorAuthorityObservationUnavailable !Text
  | FederationBootstrapCoordinatorAuthorityStateConflict
  | FederationBootstrapCoordinatorDeadlineElapsed
  | FederationBootstrapCoordinatorTimeUnavailable !Text
  | FederationBootstrapCoordinatorRecipientUnavailable !Text
  | FederationBootstrapCoordinatorRecipientConflict
  | FederationBootstrapCoordinatorParentEnvelopeUnavailable !Text
  | FederationBootstrapCoordinatorParentEnvelopeConflict
  | FederationBootstrapCoordinatorChildDeliveryUnavailable !Text
  | FederationBootstrapCoordinatorCheckpointUnavailable !Text
  | FederationBootstrapCoordinatorCheckpointConflict
  | FederationBootstrapCoordinatorCleanupUnavailable !Text
  | FederationBootstrapCoordinatorCleanupBindingMismatch
  | FederationBootstrapCoordinatorDeliveryInvalid !Text
  | FederationBootstrapCoordinatorParentCustodyUnavailable !Text
  | FederationBootstrapCoordinatorParentCustodyConflict
  | FederationBootstrapCoordinatorCheckpointDeleteUnavailable !Text
  | FederationBootstrapCoordinatorCheckpointStillPresent
  | FederationBootstrapCoordinatorWorkerBindingMismatch
  | FederationBootstrapCoordinatorResourceVersionInvalid
  | FederationBootstrapCoordinatorCiphertextInvalid
  deriving stock (Eq, Show)

coordinateFederationBootstrap
  :: (Monad m)
  => FederationBootstrapAuthorityBoundary m
  -> FederationBootstrapChildBoundary m
  -> FederationBootstrapCheckpointBoundary m
  -> ChildBootstrapDeliveryIntent
  -> m
       ( Either
           FederationBootstrapCoordinatorError
           ParentBootstrapCustodyReceipt
       )
coordinateFederationBootstrap authority child checkpoint supplied =
  case validateChildBootstrapDeliveryIntent supplied of
    Left failure -> pure (Left (registrationFailure failure))
    Right intent -> do
      prepared <- authorityPrepareFederationBootstrap authority intent
      case prepared of
        Left detail -> pure (Left (FederationBootstrapCoordinatorPrepareUnavailable detail))
        Right observed
          | observed /= intent ->
              pure (Left FederationBootstrapCoordinatorAuthorityStateConflict)
          | otherwise -> resume intent
 where
  resume intent = do
    live <- requireBeforeDeadline child intent
    case live of
      Left failure -> pure (Left failure)
      Right () -> do
        observed <- authorityObserveFederationBootstrap authority intent
        case observed of
          Left detail ->
            pure
              (Left (FederationBootstrapCoordinatorAuthorityObservationUnavailable detail))
          Right state
            | registrationStateBootstrapIntent state /= intent ->
                pure (Left FederationBootstrapCoordinatorAuthorityStateConflict)
            | Just custody <- registrationStateBootstrapCustody state ->
                if custodyMatchesIntent intent custody
                  then finishCompleted intent custody
                  else pure (Left FederationBootstrapCoordinatorParentCustodyConflict)
            | Just delivery <- registrationStateChildDelivery state ->
                if deliveryMatchesIntent intent delivery
                  then finishDelivery intent delivery
                  else pure (Left FederationBootstrapCoordinatorParentCustodyConflict)
            | Just envelope <- registrationStateParentEnvelope state ->
                continueFromEnvelope intent envelope
            | Just recipient <- registrationStateChildRecipient state ->
                continueFromRecipient intent recipient
            | otherwise -> startRecipient intent

  startRecipient intent = do
    created <- createOrRecoverFederationChildRecipient child intent
    case created of
      Left detail ->
        pure (Left (FederationBootstrapCoordinatorRecipientUnavailable detail))
      Right recipient
        | childBootstrapRecipientIntent recipient /= intent ->
            pure (Left FederationBootstrapCoordinatorRecipientConflict)
        | otherwise -> case validateChildBootstrapRecipientAttestation recipient of
            Left failure -> pure (Left (registrationFailure failure))
            Right _ -> continueFromRecipient intent recipient

  continueFromRecipient intent recipient = do
    live <- requireBeforeDeadline child intent
    case live of
      Left failure -> pure (Left failure)
      Right () -> do
        attempted <- authorityRecordFederationChildRecipient authority recipient
        case attempted of
          Left detail ->
            pure
              (Left (FederationBootstrapCoordinatorParentEnvelopeUnavailable detail))
          Right envelope
            | parentBootstrapEnvelopeChildRecipient envelope /= recipient ->
                pure (Left FederationBootstrapCoordinatorParentEnvelopeConflict)
            | otherwise -> case validateParentBootstrapEnvelope envelope of
                Left failure -> pure (Left (registrationFailure failure))
                Right _ -> continueFromEnvelope intent envelope

  continueFromEnvelope intent envelope = do
    stored <- observeFederationChildDeliveryCheckpoint checkpoint intent
    case stored of
      Left detail ->
        pure (Left (FederationBootstrapCoordinatorCheckpointUnavailable detail))
      Right (Just existing)
        | federationCheckpointParentEnvelope existing /= envelope ->
            pure (Left FederationBootstrapCoordinatorCheckpointConflict)
        | otherwise -> cleanupAndSubmit intent existing
      Right Nothing -> do
        live <- requireBeforeDeadline child intent
        case live of
          Left failure -> pure (Left failure)
          Right () -> do
            delivered <- continueFederationChildDelivery child envelope
            case delivered of
              Left detail ->
                pure
                  (Left (FederationBootstrapCoordinatorChildDeliveryUnavailable detail))
              Right provisional
                | federationCheckpointParentEnvelope provisional /= envelope ->
                    pure (Left FederationBootstrapCoordinatorCheckpointConflict)
                | otherwise -> do
                    persisted <-
                      createFederationChildDeliveryCheckpoint
                        checkpoint
                        intent
                        provisional
                    case persisted of
                      Left detail ->
                        pure
                          (Left (FederationBootstrapCoordinatorCheckpointUnavailable detail))
                      Right observed
                        | observed /= provisional ->
                            pure (Left FederationBootstrapCoordinatorCheckpointConflict)
                        | otherwise -> cleanupAndSubmit intent provisional

  cleanupAndSubmit intent provisional = do
    cleaned <-
      cleanupFederationChildWorker
        child
        (federationCheckpointWorker provisional)
    case cleaned of
      Left detail ->
        pure (Left (FederationBootstrapCoordinatorCleanupUnavailable detail))
      Right cleanup
        | not (cleanupMatches (federationCheckpointWorker provisional) cleanup) ->
            pure (Left FederationBootstrapCoordinatorCleanupBindingMismatch)
        | otherwise ->
            case mkChildBootstrapDeliveryReceipt
              (federationCheckpointParentEnvelope provisional)
              (federationCheckpointWorker provisional)
              (federationCheckpointSecretUid provisional)
              (federationCheckpointSecretResourceVersion provisional)
              (federationCheckpointSecretCommitment provisional)
              (federationCheckpointParentCiphertext provisional)
              cleanup of
              Left failure -> pure (Left (registrationFailure failure))
              Right delivery -> finishDelivery intent delivery

  finishDelivery intent delivery = do
    case validateChildBootstrapDeliveryReceipt delivery of
      Left failure -> pure (Left (registrationFailure failure))
      Right _
        | not (deliveryMatchesIntent intent delivery) ->
            pure (Left FederationBootstrapCoordinatorParentCustodyConflict)
        | otherwise -> do
            completed <- authorityRecordFederationChildDelivery authority delivery
            case completed of
              Left detail ->
                pure (Left (FederationBootstrapCoordinatorParentCustodyUnavailable detail))
              Right custody
                | parentBootstrapCustodyChildDelivery custody /= delivery ->
                    pure (Left FederationBootstrapCoordinatorParentCustodyConflict)
                | otherwise -> finishCompleted intent custody

  finishCompleted intent custody = case validateParentBootstrapCustodyReceipt custody of
    Left failure -> pure (Left (registrationFailure failure))
    Right _
      | not (custodyMatchesIntent intent custody) ->
          pure (Left FederationBootstrapCoordinatorParentCustodyConflict)
    Right _ -> do
      observed <- observeFederationChildDeliveryCheckpoint checkpoint intent
      case observed of
        Left detail ->
          pure (Left (FederationBootstrapCoordinatorCheckpointUnavailable detail))
        Right Nothing -> confirmCheckpointAbsent intent custody
        Right (Just provisional)
          | federationCheckpointParentEnvelope provisional
              /= childBootstrapDeliveryParentEnvelope
                (parentBootstrapCustodyChildDelivery custody) ->
              pure (Left FederationBootstrapCoordinatorCheckpointConflict)
          | otherwise -> do
              deleted <-
                deleteFederationChildDeliveryCheckpoint checkpoint intent provisional
              case deleted of
                Left detail ->
                  pure
                    (Left (FederationBootstrapCoordinatorCheckpointDeleteUnavailable detail))
                Right () -> confirmCheckpointAbsent intent custody

  confirmCheckpointAbsent intent custody = do
    absent <- observeFederationChildDeliveryCheckpointAbsent checkpoint intent
    pure $ case absent of
      Left detail ->
        Left (FederationBootstrapCoordinatorCheckpointDeleteUnavailable detail)
      Right False -> Left FederationBootstrapCoordinatorCheckpointStillPresent
      Right True -> Right custody

requireBeforeDeadline
  :: (Monad m)
  => FederationBootstrapChildBoundary m
  -> ChildBootstrapDeliveryIntent
  -> m (Either FederationBootstrapCoordinatorError ())
requireBeforeDeadline boundary intent = do
  observed <- observeFederationBootstrapTimeMicros boundary
  pure $ case observed of
    Left detail -> Left (FederationBootstrapCoordinatorTimeUnavailable detail)
    Right now
      | now >= childBootstrapDeliveryDeadlineMicros intent ->
          Left FederationBootstrapCoordinatorDeadlineElapsed
      | otherwise -> Right ()

cleanupMatches
  :: FederationWorkerBinding -> FederationWorkerCleanup -> Bool
cleanupMatches expected cleanup =
  federationWorkerCleanupBinding cleanup == expected
    && cleanup
      == mkFederationWorkerCleanup
        expected
        (federationWorkerSessionAbsence cleanup)
        (federationWorkerJobAbsence cleanup)
        (federationWorkerPodAbsence cleanup)

deliveryMatchesIntent
  :: ChildBootstrapDeliveryIntent -> ChildBootstrapDeliveryReceipt -> Bool
deliveryMatchesIntent intent delivery =
  childBootstrapRecipientIntent
    ( parentBootstrapEnvelopeChildRecipient
        (childBootstrapDeliveryParentEnvelope delivery)
    )
    == intent

custodyMatchesIntent
  :: ChildBootstrapDeliveryIntent -> ParentBootstrapCustodyReceipt -> Bool
custodyMatchesIntent intent custody =
  deliveryMatchesIntent intent (parentBootstrapCustodyChildDelivery custody)

validateResourceVersion
  :: Text -> Either FederationBootstrapCoordinatorError Text
validateResourceVersion raw
  | Text.null value = Left FederationBootstrapCoordinatorResourceVersionInvalid
  | Text.length value > 256 = Left FederationBootstrapCoordinatorResourceVersionInvalid
  | Text.any (\character -> isControl character || isSpace character) value =
      Left FederationBootstrapCoordinatorResourceVersionInvalid
  | otherwise = Right value
 where
  value = Text.strip raw

mapRegistrationError
  :: (Show error)
  => Either error value
  -> Either FederationBootstrapCoordinatorError value
mapRegistrationError =
  either
    (Left . FederationBootstrapCoordinatorDeliveryInvalid . Text.pack . show)
    Right

registrationFailure :: (Show error) => error -> FederationBootstrapCoordinatorError
registrationFailure =
  FederationBootstrapCoordinatorDeliveryInvalid . Text.pack . show

maximumCheckpointCiphertextBytes :: Int
maximumCheckpointCiphertextBytes = 1024 * 1024
