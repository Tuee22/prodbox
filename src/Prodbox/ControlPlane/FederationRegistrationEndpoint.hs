{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Durable Lifecycle Authority relay for bidirectional federation bootstrap
-- and post-init child recovery custody.
--
-- The host can coordinate the two special one-shot Jobs, but it transports
-- only public keys, ciphertext and typed receipts.  Every stage is committed
-- here before the next external effect.  Parent Agent calls are made only
-- after their complete inputs are durable and are idempotently recoverable
-- after an applied-but-response-lost call.
module Prodbox.ControlPlane.FederationRegistrationEndpoint
  ( FederationRegistrationRequest (..)
  , FederationRegistrationResponse (..)
  , FederationRegistrationSnapshot (..)
  , FederationRegistrationRepository (..)
  , FederationRegistrationBoundary (..)
  , federationRegistrationAuthenticatedHandler
  , prepareFederationBootstrap
  , observeFederationBootstrap
  , driveFederationBootstrapRecipient
  , driveFederationBootstrapDelivery
  , driveFederationRegistration
  , RegistrationDriveError (..)
  , federationRegistrationStateCodec
  , modelBFederationRegistrationRepository
  , federationRegistrationMaximumBytes
  , federationRegistrationResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , ParentCustodyAcknowledgement
  )
import Prodbox.Cluster.FederationRegistration
  ( ChildBootstrapDeliveryIntent (..)
  , ChildBootstrapDeliveryReceipt (..)
  , ChildBootstrapRecipientAttestation (..)
  , FederationRegistrationCommand (..)
  , FederationRegistrationCompletion
  , FederationRegistrationError (FederationRegistrationBootstrapStageConflict)
  , FederationRegistrationIntent (..)
  , FederationRegistrationState (..)
  , ParentBootstrapCustodyReceipt (..)
  , ParentBootstrapEnvelope (..)
  , applyFederationRegistrationCommand
  , bootstrapCustodyIntent
  , childBootstrapDeliveryTargetAgent
  , federationRegistrationTargetAgent
  , mkFederationRegistrationCompletion
  , newFederationRegistrationState
  , registrationStateBootstrapCustody
  , registrationStateBootstrapIntent
  , registrationStateChildDelivery
  , registrationStateChildRecipient
  , registrationStateCompletion
  , registrationStateCustodyIntent
  , registrationStateParentEnvelope
  , validateChildBootstrapDeliveryIntent
  , validateChildBootstrapDeliveryReceipt
  , validateChildBootstrapRecipientAttestation
  , validateFederationRegistrationCompletion
  , validateFederationRegistrationIntent
  , validateParentBootstrapCustodyReceipt
  , validateParentBootstrapEnvelope
  )
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleReadinessSource
  , layerRoleReadinessSource
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleFederationRegister)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution (TargetAgentIdentity)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )

data FederationRegistrationRequest
  = FederationBootstrapPrepareRequest !ChildBootstrapDeliveryIntent
  | FederationBootstrapObserveRequest !ChildBootstrapDeliveryIntent
  | FederationBootstrapChildRecipientRequest !ChildBootstrapRecipientAttestation
  | FederationBootstrapChildDeliveryRequest !ChildBootstrapDeliveryReceipt
  | FederationCustodyRegistrationRequest !FederationRegistrationIntent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FederationRegistrationResponse
  = FederationBootstrapPrepareSucceeded !ChildBootstrapDeliveryIntent
  | FederationBootstrapObserved !FederationRegistrationState
  | FederationBootstrapParentEnvelopeReady !ParentBootstrapEnvelope
  | FederationBootstrapCustodySucceeded !ParentBootstrapCustodyReceipt
  | FederationRegistrationSucceeded !FederationRegistrationCompletion
  | FederationRegistrationRefused !Text
  | FederationRegistrationUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data FederationRegistrationSnapshot revision = FederationRegistrationSnapshot
  { federationRegistrationRevision :: !revision
  , federationRegistrationSnapshotState :: !FederationRegistrationState
  }
  deriving stock (Eq, Show)

data FederationRegistrationRepository m revision = FederationRegistrationRepository
  { observeFederationRegistration
      :: m (Either Text (Maybe (FederationRegistrationSnapshot revision)))
  , initializeFederationRegistration
      :: ChildBootstrapDeliveryIntent
      -> m (Either Text ())
  , recordFederationChildRecipient
      :: revision
      -> ChildBootstrapRecipientAttestation
      -> m (Either Text ())
  , recordFederationParentEnvelope
      :: revision
      -> ParentBootstrapEnvelope
      -> m (Either Text ())
  , recordFederationChildDelivery
      :: revision
      -> ChildBootstrapDeliveryReceipt
      -> m (Either Text ())
  , completeFederationBootstrapCustody
      :: revision
      -> ParentBootstrapCustodyReceipt
      -> m (Either Text ())
  , prepareFederationRegistrationCustody
      :: revision
      -> FederationRegistrationIntent
      -> m (Either Text ())
  , completeFederationRegistration
      :: revision
      -> FederationRegistrationCompletion
      -> m (Either Text ())
  , federationRegistrationRepositoryReadiness :: !RoleReadinessSource
  }

data FederationRegistrationBoundary m revision = FederationRegistrationBoundary
  { resolveFederationRegistrationRepository
      :: ArtifactDigest
      -> Either Text (FederationRegistrationRepository m revision)
  , prepareFederationParentEnvelope
      :: TargetAgentIdentity
      -> ChildBootstrapRecipientAttestation
      -> m (Either Text ParentBootstrapEnvelope)
  , completeFederationParentBootstrap
      :: TargetAgentIdentity
      -> ChildBootstrapDeliveryReceipt
      -> m (Either Text ParentBootstrapCustodyReceipt)
  , commitFederationRegistrationTarget
      :: TargetAgentIdentity
      -> FederationRegistrationIntent
      -> m (Either Text ParentCustodyAcknowledgement)
  , federationRegistrationBoundaryReadiness :: !RoleReadinessSource
  }

federationRegistrationMaximumBytes :: Int
federationRegistrationMaximumBytes = 8 * 1024 * 1024

federationRegistrationResponseMaximumBytes :: Int
federationRegistrationResponseMaximumBytes = 8 * 1024 * 1024

federationRegistrationCasAttempts :: Natural
federationRegistrationCasAttempts = 8

federationRegistrationAuthenticatedHandler
  :: (Monad m)
  => Int
  -> FederationRegistrationBoundary m revision
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
federationRegistrationAuthenticatedHandler maximumBytes boundary fallback =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness =
        layerRoleReadinessSource
          (federationRegistrationBoundaryReadiness boundary)
          (authenticatedHandlerReadiness fallback)
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleFederationRegister -> do
      response <- case decodeRequest body of
        Left detail -> pure (FederationRegistrationRefused detail)
        Right request -> dispatch request
      pure (Just (responseStatus response, responseBody response))
    _ -> authenticatedHandlerHandle fallback caller route body

  decodeRequest bytes =
    first
      (const "request-codec-rejected")
      (decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict bytes))

  repositoryFor intent =
    resolveFederationRegistrationRepository
      boundary
      (childBootstrapDeliveryOperationDigest intent)

  dispatch request = case request of
    FederationBootstrapPrepareRequest supplied ->
      case validateChildBootstrapDeliveryIntent supplied of
        Left failure -> pure (refused failure)
        Right intent -> case repositoryFor intent of
          Left detail -> pure (FederationRegistrationRefused detail)
          Right repository ->
            projectPrepare
              <$> prepareFederationBootstrap
                federationRegistrationCasAttempts
                repository
                intent
    FederationBootstrapObserveRequest supplied ->
      case validateChildBootstrapDeliveryIntent supplied of
        Left failure -> pure (refused failure)
        Right intent -> case repositoryFor intent of
          Left detail -> pure (FederationRegistrationRefused detail)
          Right repository ->
            projectObserved <$> observeFederationBootstrap repository intent
    FederationBootstrapChildRecipientRequest supplied ->
      case validateChildBootstrapRecipientAttestation supplied of
        Left failure -> pure (refused failure)
        Right recipient -> case repositoryFor (childBootstrapRecipientIntent recipient) of
          Left detail -> pure (FederationRegistrationRefused detail)
          Right repository ->
            projectParentEnvelope
              <$> driveFederationBootstrapRecipient
                federationRegistrationCasAttempts
                repository
                (prepareFederationParentEnvelope boundary)
                recipient
    FederationBootstrapChildDeliveryRequest supplied ->
      case validateChildBootstrapDeliveryReceipt supplied of
        Left failure -> pure (refused failure)
        Right delivery ->
          let intent =
                childBootstrapRecipientIntent
                  ( parentBootstrapEnvelopeChildRecipient
                      (childBootstrapDeliveryParentEnvelope delivery)
                  )
           in case repositoryFor intent of
                Left detail -> pure (FederationRegistrationRefused detail)
                Right repository ->
                  projectBootstrapCustody
                    <$> driveFederationBootstrapDelivery
                      federationRegistrationCasAttempts
                      repository
                      (completeFederationParentBootstrap boundary)
                      delivery
    FederationCustodyRegistrationRequest supplied ->
      case validateFederationRegistrationIntent supplied of
        Left failure -> pure (refused failure)
        Right intent ->
          let bootstrap = bootstrapCustodyIntent (federationRegistrationBootstrapCustody intent)
           in case repositoryFor bootstrap of
                Left detail -> pure (FederationRegistrationRefused detail)
                Right repository ->
                  projectRegistration
                    <$> driveFederationRegistration
                      federationRegistrationCasAttempts
                      repository
                      (commitFederationRegistrationTarget boundary)
                      intent

  refused = FederationRegistrationRefused . Text.pack . show

  projectPrepare = projectDrive FederationBootstrapPrepareSucceeded
  projectObserved = projectDrive FederationBootstrapObserved
  projectParentEnvelope = projectDrive FederationBootstrapParentEnvelopeReady
  projectBootstrapCustody = projectDrive FederationBootstrapCustodySucceeded
  projectRegistration = projectDrive FederationRegistrationSucceeded

projectDrive
  :: (value -> FederationRegistrationResponse)
  -> Either RegistrationDriveError value
  -> FederationRegistrationResponse
projectDrive success result = case result of
  Right value -> success value
  Left (RegistrationDriveRefused detail) -> FederationRegistrationRefused detail
  Left (RegistrationDriveUnavailable detail) -> FederationRegistrationUnavailable detail

data RegistrationDriveError
  = RegistrationDriveRefused !Text
  | RegistrationDriveUnavailable !Text
  deriving stock (Eq, Show)

-- | Commit the operation anchor before either worker may exist.
prepareFederationBootstrap
  :: (Monad m)
  => Natural
  -> FederationRegistrationRepository m revision
  -> ChildBootstrapDeliveryIntent
  -> m (Either RegistrationDriveError ChildBootstrapDeliveryIntent)
prepareFederationBootstrap maximumAttempts repository supplied =
  case validateChildBootstrapDeliveryIntent supplied of
    Left failure -> pure (registrationRefused failure)
    Right intent -> go maximumAttempts intent
 where
  go 0 _ = pure (unavailable "bootstrap prepare CAS attempts exhausted")
  go remaining intent = do
    observed <- observeFederationRegistration repository
    case observed of
      Left detail -> pure (unavailable detail)
      Right Nothing -> do
        _ <- initializeFederationRegistration repository intent
        go (remaining - 1) intent
      Right (Just snapshot) ->
        case validateStoredState (federationRegistrationSnapshotState snapshot) of
          Left failure -> pure (registrationRefused failure)
          Right state
            | registrationStateBootstrapIntent state == intent -> pure (Right intent)
            | otherwise -> pure (refusal "bootstrap-operation-intent-conflict")

-- | Read the exact retained aggregate so a coordinator can resume after
-- losing any prior HTTP response without recreating either one-shot Job.
observeFederationBootstrap
  :: (Monad m)
  => FederationRegistrationRepository m revision
  -> ChildBootstrapDeliveryIntent
  -> m (Either RegistrationDriveError FederationRegistrationState)
observeFederationBootstrap repository supplied =
  case validateChildBootstrapDeliveryIntent supplied of
    Left failure -> pure (registrationRefused failure)
    Right intent -> do
      observed <- observeFederationRegistration repository
      pure $ case observed of
        Left detail -> unavailable detail
        Right Nothing -> refusal "bootstrap-operation-missing"
        Right (Just snapshot) ->
          case validateStoredState (federationRegistrationSnapshotState snapshot) of
            Left failure -> registrationRefused failure
            Right state
              | registrationStateBootstrapIntent state == intent -> Right state
              | otherwise -> refusal "bootstrap-operation-intent-conflict"

-- | Persist the exact child recipient before the parent Agent call.  The
-- callback is invoked at most once per driver invocation.
driveFederationBootstrapRecipient
  :: (Monad m)
  => Natural
  -> FederationRegistrationRepository m revision
  -> ( TargetAgentIdentity
       -> ChildBootstrapRecipientAttestation
       -> m (Either Text ParentBootstrapEnvelope)
     )
  -> ChildBootstrapRecipientAttestation
  -> m (Either RegistrationDriveError ParentBootstrapEnvelope)
driveFederationBootstrapRecipient maximumAttempts repository parentTarget supplied =
  case validateChildBootstrapRecipientAttestation supplied of
    Left failure -> pure (registrationRefused failure)
    Right recipient -> ensureRecorded maximumAttempts recipient
 where
  ensureRecorded 0 _ = pure (unavailable "child-recipient CAS attempts exhausted")
  ensureRecorded remaining recipient = do
    observed <- observeFederationRegistration repository
    case observed of
      Left detail -> pure (unavailable detail)
      Right Nothing -> pure (refusal "bootstrap-operation-missing")
      Right (Just snapshot) ->
        case validateStoredState (federationRegistrationSnapshotState snapshot) of
          Left failure -> pure (registrationRefused failure)
          Right state
            | registrationStateBootstrapIntent state /= childBootstrapRecipientIntent recipient ->
                pure (refusal "bootstrap-operation-intent-conflict")
            | Just current <- registrationStateChildRecipient state
            , current /= recipient ->
                pure (refusal "child-recipient-conflict")
            | Just envelope <- registrationStateParentEnvelope state -> pure (Right envelope)
            | registrationStateChildRecipient state == Nothing -> do
                _ <- recordFederationChildRecipient repository (federationRegistrationRevision snapshot) recipient
                ensureRecorded (remaining - 1) recipient
            | otherwise -> callParent snapshot recipient

  callParent snapshot recipient =
    case childBootstrapDeliveryTargetAgent (childBootstrapRecipientIntent recipient) of
      Left failure -> pure (registrationRefused failure)
      Right target -> do
        attempted <- parentTarget target recipient
        case attempted of
          Left detail -> pure (unavailable ("parent bootstrap worker: " <> detail))
          Right suppliedEnvelope -> case validateParentBootstrapEnvelope suppliedEnvelope of
            Left failure -> pure (registrationRefused failure)
            Right envelope
              | parentBootstrapEnvelopeChildRecipient envelope /= recipient ->
                  pure (refusal "parent-envelope-recipient-conflict")
              | otherwise -> do
                  _ <- recordFederationParentEnvelope repository (federationRegistrationRevision snapshot) envelope
                  confirmParentEnvelope recipient envelope

  confirmParentEnvelope recipient expected = do
    observed <- observeFederationRegistration repository
    pure $ case observed of
      Left detail -> unavailable detail
      Right Nothing -> unavailable "parent envelope read-back is absent"
      Right (Just snapshot) -> case validateStoredState (federationRegistrationSnapshotState snapshot) of
        Left failure -> registrationRefused failure
        Right state
          | registrationStateChildRecipient state /= Just recipient -> refusal "child-recipient-conflict"
          | registrationStateParentEnvelope state == Just expected -> Right expected
          | registrationStateParentEnvelope state == Nothing ->
              unavailable "parent envelope CAS was not observed"
          | otherwise -> refusal "parent-envelope-conflict"

-- | Persist the child Secret/ciphertext/cleanup receipt before allowing the
-- parent worker to decrypt the return envelope and commit parent custody.
driveFederationBootstrapDelivery
  :: (Monad m)
  => Natural
  -> FederationRegistrationRepository m revision
  -> ( TargetAgentIdentity
       -> ChildBootstrapDeliveryReceipt
       -> m (Either Text ParentBootstrapCustodyReceipt)
     )
  -> ChildBootstrapDeliveryReceipt
  -> m (Either RegistrationDriveError ParentBootstrapCustodyReceipt)
driveFederationBootstrapDelivery maximumAttempts repository parentTarget supplied =
  case validateChildBootstrapDeliveryReceipt supplied of
    Left failure -> pure (registrationRefused failure)
    Right delivery -> ensureRecorded maximumAttempts delivery
 where
  ensureRecorded 0 _ = pure (unavailable "child-delivery CAS attempts exhausted")
  ensureRecorded remaining delivery = do
    observed <- observeFederationRegistration repository
    case observed of
      Left detail -> pure (unavailable detail)
      Right Nothing -> pure (refusal "bootstrap-operation-missing")
      Right (Just snapshot) ->
        case validateStoredState (federationRegistrationSnapshotState snapshot) of
          Left failure -> pure (registrationRefused failure)
          Right state
            | registrationStateParentEnvelope state /= Just (childBootstrapDeliveryParentEnvelope delivery) ->
                pure (refusal "parent-envelope-conflict")
            | Just current <- registrationStateChildDelivery state
            , current /= delivery ->
                pure (refusal "child-delivery-conflict")
            | Just completed <- registrationStateBootstrapCustody state -> pure (Right completed)
            | registrationStateChildDelivery state == Nothing -> do
                _ <- recordFederationChildDelivery repository (federationRegistrationRevision snapshot) delivery
                ensureRecorded (remaining - 1) delivery
            | otherwise -> callParent snapshot delivery

  callParent snapshot delivery =
    let intent =
          childBootstrapRecipientIntent
            (parentBootstrapEnvelopeChildRecipient (childBootstrapDeliveryParentEnvelope delivery))
     in case childBootstrapDeliveryTargetAgent intent of
          Left failure -> pure (registrationRefused failure)
          Right target -> do
            attempted <- parentTarget target delivery
            case attempted of
              Left detail -> pure (unavailable ("parent bootstrap custody worker: " <> detail))
              Right suppliedCustody -> case validateParentBootstrapCustodyReceipt suppliedCustody of
                Left failure -> pure (registrationRefused failure)
                Right custody
                  | parentBootstrapCustodyChildDelivery custody /= delivery ->
                      pure (refusal "parent-bootstrap-custody-conflict")
                  | otherwise -> do
                      _ <- completeFederationBootstrapCustody repository (federationRegistrationRevision snapshot) custody
                      confirmCustody delivery custody

  confirmCustody delivery expected = do
    observed <- observeFederationRegistration repository
    pure $ case observed of
      Left detail -> unavailable detail
      Right Nothing -> unavailable "parent bootstrap custody read-back is absent"
      Right (Just snapshot) -> case validateStoredState (federationRegistrationSnapshotState snapshot) of
        Left failure -> registrationRefused failure
        Right state
          | registrationStateChildDelivery state /= Just delivery -> refusal "child-delivery-conflict"
          | registrationStateBootstrapCustody state == Just expected -> Right expected
          | registrationStateBootstrapCustody state == Nothing ->
              unavailable "parent bootstrap custody CAS was not observed"
          | otherwise -> refusal "parent-bootstrap-custody-conflict"

driveFederationRegistration
  :: (Monad m)
  => Natural
  -> FederationRegistrationRepository m revision
  -> ( TargetAgentIdentity
       -> FederationRegistrationIntent
       -> m (Either Text ParentCustodyAcknowledgement)
     )
  -> FederationRegistrationIntent
  -> m (Either RegistrationDriveError FederationRegistrationCompletion)
driveFederationRegistration maximumAttempts repository commitTarget supplied =
  case validateFederationRegistrationIntent supplied of
    Left failure -> pure (registrationRefused failure)
    Right intent -> ensurePrepared maximumAttempts intent
 where
  ensurePrepared 0 _ = pure (unavailable "registration CAS attempts exhausted")
  ensurePrepared remaining intent = do
    observed <- observeFederationRegistration repository
    case observed of
      Left detail -> pure (unavailable detail)
      Right Nothing -> pure (refusal "bootstrap-operation-missing")
      Right (Just snapshot) ->
        case validateStoredState (federationRegistrationSnapshotState snapshot) of
          Left failure -> pure (registrationRefused failure)
          Right state
            | registrationStateBootstrapCustody state /= Just (federationRegistrationBootstrapCustody intent) ->
                pure (refusal "bootstrap-custody-conflict")
            | Just current <- registrationStateCustodyIntent state
            , current /= intent ->
                pure (refusal "operation-intent-conflict")
            | Just completion <- registrationStateCompletion state -> pure (Right completion)
            | registrationStateCustodyIntent state == Nothing -> do
                _ <-
                  prepareFederationRegistrationCustody repository (federationRegistrationRevision snapshot) intent
                ensurePrepared (remaining - 1) intent
            | otherwise -> callParent snapshot intent

  callParent snapshot intent = case federationRegistrationTargetAgent intent of
    Left failure -> pure (registrationRefused failure)
    Right target -> do
      committed <- commitTarget target intent
      case committed of
        Left detail -> pure (unavailable ("parent Target Agent custody commit: " <> detail))
        Right acknowledgement -> case mkFederationRegistrationCompletion intent acknowledgement of
          Left failure -> pure (registrationRefused failure)
          Right completion -> do
            _ <- completeFederationRegistration repository (federationRegistrationRevision snapshot) completion
            confirmCompletion intent completion

  confirmCompletion intent expected = do
    observed <- observeFederationRegistration repository
    pure $ case observed of
      Left detail -> unavailable detail
      Right Nothing -> unavailable "registration completion read-back is absent"
      Right (Just snapshot) -> case validateStoredState (federationRegistrationSnapshotState snapshot) of
        Left failure -> registrationRefused failure
        Right state
          | registrationStateCustodyIntent state /= Just intent -> refusal "operation-intent-conflict"
          | registrationStateCompletion state == Just expected -> Right expected
          | registrationStateCompletion state == Nothing ->
              unavailable "registration completion CAS was not observed"
          | otherwise -> refusal "registration-completion-conflict"

registrationRefused
  :: FederationRegistrationError -> Either RegistrationDriveError value
registrationRefused = Left . RegistrationDriveRefused . Text.pack . show

refusal :: Text -> Either RegistrationDriveError value
refusal = Left . RegistrationDriveRefused

unavailable :: Text -> Either RegistrationDriveError value
unavailable = Left . RegistrationDriveUnavailable

responseStatus :: FederationRegistrationResponse -> Int
responseStatus response = case response of
  FederationBootstrapPrepareSucceeded {} -> 200
  FederationBootstrapObserved {} -> 200
  FederationBootstrapParentEnvelopeReady {} -> 200
  FederationBootstrapCustodySucceeded {} -> 200
  FederationRegistrationSucceeded {} -> 200
  FederationRegistrationRefused {} -> 409
  FederationRegistrationUnavailable {} -> 503

responseBody :: FederationRegistrationResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

validateStoredState
  :: FederationRegistrationState
  -> Either FederationRegistrationError FederationRegistrationState
validateStoredState state = do
  initial <- newFederationRegistrationState (registrationStateBootstrapIntent state)
  withRecipient <- case registrationStateChildRecipient state of
    Nothing -> Right initial
    Just value -> applyFederationRegistrationCommand initial (RecordFederationChildRecipient value)
  withEnvelope <- case registrationStateParentEnvelope state of
    Nothing -> Right withRecipient
    Just value -> applyFederationRegistrationCommand withRecipient (RecordFederationParentEnvelope value)
  withDelivery <- case registrationStateChildDelivery state of
    Nothing -> Right withEnvelope
    Just value -> applyFederationRegistrationCommand withEnvelope (RecordFederationChildDelivery value)
  withBootstrap <- case registrationStateBootstrapCustody state of
    Nothing -> Right withDelivery
    Just value -> applyFederationRegistrationCommand withDelivery (CompleteFederationBootstrapCustody value)
  withIntent <- case registrationStateCustodyIntent state of
    Nothing -> Right withBootstrap
    Just value -> applyFederationRegistrationCommand withBootstrap (PrepareFederationRegistration value)
  rebuilt <- case registrationStateCompletion state of
    Nothing -> Right withIntent
    Just value -> applyFederationRegistrationCommand withIntent (CompleteFederationRegistration value)
  if rebuilt == state then Right state else Left FederationRegistrationBootstrapStageConflict

data FederationRegistrationEnvelope = FederationRegistrationEnvelope
  { federationRegistrationEnvelopeVersion :: !Word16
  , federationRegistrationEnvelopeState :: !FederationRegistrationState
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

federationRegistrationCodecVersion :: Word16
federationRegistrationCodecVersion = 3

federationRegistrationStateCodec
  :: Int -> ModelBCodec FederationRegistrationState
federationRegistrationStateCodec maximumBytes =
  ModelBCodec
    { encodeModelBValue = \state -> do
        _ <- first show (validateStoredState state)
        let bytes =
              LazyByteString.toStrict
                ( serialise
                    FederationRegistrationEnvelope
                      { federationRegistrationEnvelopeVersion = federationRegistrationCodecVersion
                      , federationRegistrationEnvelopeState = state
                      }
                )
        if maximumBytes < 0 || ByteString.length bytes > maximumBytes
          then Left "federation registration state exceeds the encoded-size bound"
          else Right bytes
    , decodeModelBValue = \bytes ->
        if maximumBytes < 0 || ByteString.length bytes > maximumBytes
          then Left "federation registration state exceeds the encoded-size bound"
          else do
            envelope <-
              first
                (const "federation registration state is not canonical CBOR")
                (deserialiseOrFail (LazyByteString.fromStrict bytes))
            if federationRegistrationEnvelopeVersion envelope /= federationRegistrationCodecVersion
              then Left "federation registration state schema is unsupported"
              else do
                state <- first show (validateStoredState (federationRegistrationEnvelopeState envelope))
                if LazyByteString.toStrict (serialise envelope) /= bytes
                  then Left "federation registration state is non-canonical"
                  else Right state
    }

modelBFederationRegistrationRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m FederationRegistrationState
  -> ModelBObjectCoordinate 'ClusterRetained
  -> RoleReadinessSource
  -> FederationRegistrationRepository m ModelBObjectVersion
modelBFederationRegistrationRepository adapter coordinate ready =
  FederationRegistrationRepository
    { observeFederationRegistration = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right Nothing
          ModelBObserved revision state ->
            Right
              ( Just
                  FederationRegistrationSnapshot
                    { federationRegistrationRevision = revision
                    , federationRegistrationSnapshotState = state
                    }
              )
          ModelBCorrupt detail -> Left ("federation registration is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("federation registration store is not ready: " <> detail)
          ModelBUnobservable detail -> Left ("federation registration is unobservable: " <> detail)
    , initializeFederationRegistration = \intent ->
        replaceFrom Nothing (newFederationRegistrationState intent)
    , recordFederationChildRecipient = \revision value ->
        replaceFrom
          (Just revision)
          (FederationChildRecipientRecorded <$> validateChildBootstrapRecipientAttestation value)
    , recordFederationParentEnvelope = \revision value ->
        replaceFrom
          (Just revision)
          (FederationParentEnvelopeRecorded <$> validateParentBootstrapEnvelope value)
    , recordFederationChildDelivery = \revision value ->
        replaceFrom
          (Just revision)
          (FederationChildDeliveryRecorded <$> validateChildBootstrapDeliveryReceipt value)
    , completeFederationBootstrapCustody = \revision value ->
        replaceFrom
          (Just revision)
          (FederationBootstrapCustodyCompleted <$> validateParentBootstrapCustodyReceipt value)
    , prepareFederationRegistrationCustody = \revision value ->
        replaceFrom
          (Just revision)
          (FederationRegistrationPrepared <$> validateFederationRegistrationIntent value)
    , completeFederationRegistration = \revision value ->
        replaceFrom
          (Just revision)
          (FederationRegistrationCompleted <$> validateFederationRegistrationCompletion value)
    , federationRegistrationRepositoryReadiness = ready
    }
 where
  replaceFrom maybeRevision validated = case validated of
    Left failure -> pure (Left (Text.pack (show failure)))
    Right state ->
      applyCas
        ( case maybeRevision of
            Nothing -> ModelBInitialize coordinate state
            Just revision -> ModelBReplace coordinate revision state
        )

  applyCas request = do
    result <- modelBCompareAndSwap adapter request
    pure $ case result of
      ModelBCasApplied _ _ -> Right ()
      ModelBCasConflict _ -> Left "federation registration CAS conflict"
      ModelBCasRefusedCorrupt detail -> Left ("federation registration CAS refused corrupt state: " <> detail)
      ModelBCasEndpointUnready detail -> Left ("federation registration CAS endpoint is not ready: " <> detail)
      ModelBCasUnobservable detail -> Left ("federation registration CAS is unobservable: " <> detail)
