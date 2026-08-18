{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Bounded authenticated wire boundary for Authority-owned AWS stack
-- creation bindings.  A commit request carries only the retained operation,
-- current Provider revision, and exact creation scope.  The Authority reopens
-- admission before writing; callers cannot supply an observed operation.
module Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
  ( AwsStackCreationWireAction (..)
  , AwsStackCreationWireRequest (..)
  , awsStackCreationCommitWireRequest
  , awsStackCreationReadBackWireRequest
  , AwsStackCreationWireCommitDisposition (..)
  , AwsStackCreationWireRefusal (..)
  , AwsStackCreationWireUnavailable (..)
  , AwsStackCreationWireResponse (..)
  , AwsStackCreationEndpointResult
  , awsStackCreationEndpointFormatVersion
  , awsStackCreationEndpointMaximumBytes
  , awsStackCreationEndpointResponseMaximumBytes
  , serveAwsStackCreationEndpointRequest
  , awsStackCreationEndpointStatus
  , awsStackCreationWireResponseStatus
  , awsStackCreationEndpointBody
  , decodeAwsStackCreationEndpointResponse
  , AwsStackCreationEndpointResponseError (..)
  , confirmAwsStackCreationCommitResponse
  , confirmAwsStackCreationReadBackResponse
  , awsStackCreationSelectWireRequest
  , confirmAwsStackCreationSelectResponse
  )
where

import Codec.CBOR.Decoding qualified as Cbor
import Codec.CBOR.Encoding qualified as Cbor
import Codec.Serialise
  ( Serialise (decode, encode)
  , deserialiseOrFail
  , serialise
  )
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationAuthorityIdentity
  , AwsStackCreationBindingError (..)
  , AwsStackCreationBindingRepository (..)
  , AwsStackCreationCommitResult (..)
  , AwsStackCreationReadBackObservation (..)
  , CommittedAwsStackCreationBinding
  , confirmCommittedAwsStackCreationBindingBytes
  , decodeAwsStackCreationAuthorityIdentity
  , encodeAwsStackCreationAuthorityIdentity
  , maximumAwsStackCreationAuthorityIdentityBytes
  , maximumAwsStackCreationBindingBytes
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RegisteredStackCleanupSelection
  ( RegisteredStackCleanupBoundary
  , renderRegisteredStackCleanupError
  , selectRegisteredStackForCleanup
  )
import Prodbox.ControlPlane.RegisteredStackCreationProducer
  ( RegisteredStackCreationBoundary
  , RegisteredStackCreationError (..)
  , commitRegisteredStackCreation
  , registeredStackCreationBinding
  , renderRegisteredStackCreationError
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderRevision)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface
  , DurableObservationRunScope (..)
  , LifecycleOperation (ReconcileDesiredPresent)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , ObservationFailure (..)
  , RegisteredResourceKey
  , RegistryRevision (..)
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , mkObservationEvidenceScope
  , registeredResourceKeyFromText
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.StackGeneration
  ( RegisteredStackGeneration
  , decodeRegisteredStackGeneration
  , encodeRegisteredStackGeneration
  , renderStackGenerationError
  , selectedStackGeneration
  )

data AwsStackCreationWireAction
  = AwsStackCreationWireCommitAttempt
  | AwsStackCreationWireIndependentReadBack
  | -- | Sprint 4.84: select the current lifecycle generation of one registered
    -- stack for cleanup.  This is the consumer half of the same route the
    -- creating run commits through; putting it here rather than on a route of
    -- its own keeps one wire version governing both directions of the
    -- generation, so a caller cannot be current for one and stale for the other.
    AwsStackCreationWireSelectForCleanup
  deriving stock (Eq, Show)

instance Serialise AwsStackCreationWireAction where
  encode action =
    Cbor.encodeListLen 1
      <> Cbor.encodeWord
        ( case action of
            AwsStackCreationWireCommitAttempt -> 0
            AwsStackCreationWireIndependentReadBack -> 1
            AwsStackCreationWireSelectForCleanup -> 2
        )
  decode = do
    requireListLength "AwsStackCreationWireAction" 1
    tag <- Cbor.decodeWord
    case tag of
      0 -> pure AwsStackCreationWireCommitAttempt
      1 -> pure AwsStackCreationWireIndependentReadBack
      2 -> pure AwsStackCreationWireSelectForCleanup
      _ -> fail "AwsStackCreationWireAction: unknown tag"

data AwsStackCreationWireRequest = AwsStackCreationWireRequest
  { awsStackCreationWireRequestVersion :: !Word16
  , awsStackCreationWireRequestAction :: !AwsStackCreationWireAction
  , awsStackCreationWireRequestPayload :: !ByteString
  }
  deriving stock (Eq, Show)

instance Serialise AwsStackCreationWireRequest where
  encode request =
    Cbor.encodeListLen 3
      <> Cbor.encodeWord16 (awsStackCreationWireRequestVersion request)
      <> encode (awsStackCreationWireRequestAction request)
      <> Cbor.encodeBytes (awsStackCreationWireRequestPayload request)
  decode = do
    requireListLength "AwsStackCreationWireRequest" 3
    AwsStackCreationWireRequest
      <$> Cbor.decodeWord16
      <*> decode
      <*> Cbor.decodeBytes

data AwsStackCreationScopeWire = AwsStackCreationScopeWire
  { creationScopeWireSurface :: !Int
  , creationScopeWireRegistryRevision :: !Text
  , creationScopeWireRunScope :: !Text
  , creationScopeWireFoundation :: !Text
  , creationScopeWireAwsAccount :: !(Maybe Text)
  , creationScopeWireAwsRegion :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackCreationCommitPayload = AwsStackCreationCommitPayload
  { creationCommitPayloadOperationId :: !OperationId
  , creationCommitPayloadProviderScopeOperationId :: !OperationId
  -- ^ Sprint 4.84: the admitted @ObserveProviderAwsScope@ operation whose
  -- retained receipt carries the account and region.  The caller names the
  -- operation; it cannot state its content, because the Authority reads the
  -- receipt back from its own aggregate and verifies it there.
  , creationCommitPayloadProviderRevision :: !ProviderRevision
  , creationCommitPayloadScope :: !AwsStackCreationScopeWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

awsStackCreationCommitWireRequest
  :: OperationId
  -> OperationId
  -> ProviderRevision
  -> ObservationEvidenceScope
  -> AwsStackCreationWireRequest
awsStackCreationCommitWireRequest
  operationId
  providerScopeOperationId
  revision
  scope =
    AwsStackCreationWireRequest
      { awsStackCreationWireRequestVersion = awsStackCreationEndpointFormatVersion
      , awsStackCreationWireRequestAction = AwsStackCreationWireCommitAttempt
      , awsStackCreationWireRequestPayload =
          canonicalBytes
            AwsStackCreationCommitPayload
              { creationCommitPayloadOperationId = operationId
              , creationCommitPayloadProviderScopeOperationId =
                  providerScopeOperationId
              , creationCommitPayloadProviderRevision = revision
              , creationCommitPayloadScope = scopeToWire scope
              }
      }

-- | Sprint 4.84: what a cleanup run presents when it goes looking for the
-- stack an earlier run created.
--
-- Note what is /not/ here: no ordinal, no creating run scope, no creating
-- surface, and no account or region.  The cycle is reached through the series
-- cursor, and the account and region come only from the Provider proof the
-- named observation operation retained, so a caller has no field through which
-- to assert its way to a generation.
data AwsStackCreationSelectPayload = AwsStackCreationSelectPayload
  { creationSelectPayloadResourceKey :: !Text
  , creationSelectPayloadProviderScopeOperationId :: !OperationId
  , creationSelectPayloadScope :: !AwsStackCreationScopeWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

awsStackCreationSelectWireRequest
  :: RegisteredResourceKey
  -> OperationId
  -> ObservationEvidenceScope
  -> AwsStackCreationWireRequest
awsStackCreationSelectWireRequest resourceKey providerScopeOperationId scope =
  AwsStackCreationWireRequest
    { awsStackCreationWireRequestVersion = awsStackCreationEndpointFormatVersion
    , awsStackCreationWireRequestAction = AwsStackCreationWireSelectForCleanup
    , awsStackCreationWireRequestPayload =
        canonicalBytes
          AwsStackCreationSelectPayload
            { creationSelectPayloadResourceKey =
                registeredResourceKeyText resourceKey
            , creationSelectPayloadProviderScopeOperationId =
                providerScopeOperationId
            , creationSelectPayloadScope = scopeToWire scope
            }
    }

awsStackCreationReadBackWireRequest
  :: AwsStackCreationAuthorityIdentity -> AwsStackCreationWireRequest
awsStackCreationReadBackWireRequest identity =
  AwsStackCreationWireRequest
    { awsStackCreationWireRequestVersion = awsStackCreationEndpointFormatVersion
    , awsStackCreationWireRequestAction = AwsStackCreationWireIndependentReadBack
    , awsStackCreationWireRequestPayload =
        encodeAwsStackCreationAuthorityIdentity identity
    }

data AwsStackCreationWireCommitDisposition
  = AwsStackCreationWireCommitCreated
  | AwsStackCreationWireCommitExactReplay
  | AwsStackCreationWireCommitConflict
  | AwsStackCreationWireCommitResponseLost !Text
  | AwsStackCreationWireCommitUnavailable !Text
  deriving stock (Eq, Show)

instance Serialise AwsStackCreationWireCommitDisposition where
  encode disposition = case disposition of
    AwsStackCreationWireCommitCreated -> scalar 0
    AwsStackCreationWireCommitExactReplay -> scalar 1
    AwsStackCreationWireCommitConflict -> scalar 2
    AwsStackCreationWireCommitResponseLost detail -> detailed 3 detail
    AwsStackCreationWireCommitUnavailable detail -> detailed 4 detail
   where
    scalar tag = Cbor.encodeListLen 1 <> Cbor.encodeWord tag
    detailed tag detail =
      Cbor.encodeListLen 2 <> Cbor.encodeWord tag <> Cbor.encodeString detail
  decode = do
    fields <- Cbor.decodeListLen
    tag <- Cbor.decodeWord
    case (tag, fields) of
      (0, 1) -> pure AwsStackCreationWireCommitCreated
      (1, 1) -> pure AwsStackCreationWireCommitExactReplay
      (2, 1) -> pure AwsStackCreationWireCommitConflict
      (3, 2) -> AwsStackCreationWireCommitResponseLost <$> Cbor.decodeString
      (4, 2) -> AwsStackCreationWireCommitUnavailable <$> Cbor.decodeString
      _ -> fail "AwsStackCreationWireCommitDisposition: invalid tag or length"

data AwsStackCreationWireRefusal
  = AwsStackCreationWireRequestTooLarge
  | AwsStackCreationWireRequestInvalid
  | AwsStackCreationWireRequestUnsupportedVersion
  | AwsStackCreationWireRequestNonCanonical
  | AwsStackCreationWireCommitPayloadInvalid !Text
  | AwsStackCreationWireIdentityInvalid !Text
  | AwsStackCreationWireReadBackMissing
  | AwsStackCreationWireReadBackCorrupt !Text
  | AwsStackCreationWireReadBackUnbounded !Int !Int
  | AwsStackCreationWireReadBackIdentityMismatch !ByteString
  | AwsStackCreationWireReadBackInvalid !Text
  | -- | Sprint 4.84: the create was admitted, but no Provider AWS-scope proof
    -- was retained for the named observation operation, so no run-invariant
    -- generation could be minted.
    AwsStackCreationWireScopeUnproven !Text
  | -- | Sprint 4.84: cycle reservation or the generation commit refused.
    AwsStackCreationWireGenerationRefused !Text
  | -- | Sprint 4.84: the selection payload named a resource key the compiled
    -- registry does not register, so there is no series to address.
    AwsStackCreationWireSelectKeyUnregistered !Text
  | -- | Sprint 4.84: the series cursor or the generation the ordinal addresses
    -- refused.  An unopened series, an unobservable store, a slot collision,
    -- and a surface that may not select this identity are all distinct here and
    -- none of them degrades into \"nothing is there\".
    AwsStackCreationWireSelectRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackCreationWireUnavailable
  = AwsStackCreationWireAdmissionUnavailable !Text
  | AwsStackCreationWireReadBackUnobservable !Text
  | AwsStackCreationWireEndpointUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackCreationWireResponse
  = AwsStackCreationWireCommitResult
      !Word16
      !ByteString
      !AwsStackCreationWireCommitDisposition
  | AwsStackCreationWireReadBackPresent
      !Word16
      !ByteString
      !ByteString
  | -- | Sprint 4.84: the selected generation's canonical record bytes.  The
    -- response carries the record, not a proof: the caller decodes it with
    -- 'decodeRegisteredStackGeneration', which re-derives the coordinate digest
    -- and registry revision from its own compiled registry and refuses a stored
    -- disagreement, so a selection is validated independently rather than
    -- trusted because the Authority sent it.
    AwsStackCreationWireSelected
      !Word16
      !ByteString
      !ByteString
  | AwsStackCreationWireRefused
      !Word16
      !AwsStackCreationWireRefusal
  | AwsStackCreationWireUnavailable
      !Word16
      !AwsStackCreationWireUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype AwsStackCreationEndpointResult
  = AwsStackCreationEndpointResult AwsStackCreationWireResponse
  deriving stock (Eq, Show)

-- | Bumped to @2@ by Sprint 4.84: the commit payload now names the admitted
-- Provider AWS-scope observation, so a version-1 caller cannot reach the
-- generation-committing path with an unproven scope.
awsStackCreationEndpointFormatVersion :: Word16
awsStackCreationEndpointFormatVersion = 2

awsStackCreationEndpointMaximumBytes :: Int
awsStackCreationEndpointMaximumBytes =
  maximumAwsStackCreationBindingBytes
    + maximumAwsStackCreationAuthorityIdentityBytes
    + 8192

awsStackCreationEndpointResponseMaximumBytes :: Int
awsStackCreationEndpointResponseMaximumBytes =
  awsStackCreationEndpointMaximumBytes

serveAwsStackCreationEndpointRequest
  :: (Monad m)
  => RegisteredStackCreationBoundary m
  -> RegisteredStackCleanupBoundary m
  -> AwsStackCreationBindingRepository m
  -> LazyByteString.ByteString
  -> m AwsStackCreationEndpointResult
serveAwsStackCreationEndpointRequest producer cleanupBoundary repository requestBytes =
  case decodeControlPlaneRequest awsStackCreationEndpointMaximumBytes requestBytes of
    Left err -> pure (endpointResult (requestCodecRefusal err))
    Right request
      | awsStackCreationWireRequestVersion request
          /= awsStackCreationEndpointFormatVersion ->
          pure (refused AwsStackCreationWireRequestUnsupportedVersion)
      | otherwise -> serveAction request
 where
  serveAction request = case awsStackCreationWireRequestAction request of
    AwsStackCreationWireCommitAttempt ->
      case decodeCommitPayload (awsStackCreationWireRequestPayload request) of
        Left detail -> pure (refused (AwsStackCreationWireCommitPayloadInvalid detail))
        Right payload -> do
          attempted <-
            commitRegisteredStackCreation
              producer
              (creationCommitPayloadOperationId payload)
              (creationCommitPayloadProviderScopeOperationId payload)
              (creationCommitPayloadProviderRevision payload)
              (scopeFromWire (creationCommitPayloadScope payload))
          pure $
            either
              creationErrorResult
              ( commitResult (awsStackCreationWireRequestPayload request)
                  . registeredStackCreationBinding
              )
              attempted
    AwsStackCreationWireSelectForCleanup ->
      case decodeSelectPayload (awsStackCreationWireRequestPayload request) of
        Left detail -> pure (refused (AwsStackCreationWireCommitPayloadInvalid detail))
        Right payload ->
          case registeredResourceKeyFromText
            (creationSelectPayloadResourceKey payload) of
            Nothing ->
              pure
                ( refused
                    ( AwsStackCreationWireSelectKeyUnregistered
                        (creationSelectPayloadResourceKey payload)
                    )
                )
            Just resourceKey -> do
              selected <-
                selectRegisteredStackForCleanup
                  cleanupBoundary
                  resourceKey
                  (creationSelectPayloadProviderScopeOperationId payload)
                  (scopeFromWire (creationSelectPayloadScope payload))
              pure $ case selected of
                Left err ->
                  refused
                    ( AwsStackCreationWireSelectRefused
                        (renderRegisteredStackCleanupError err)
                    )
                Right selection ->
                  endpointResult
                    ( AwsStackCreationWireSelected
                        awsStackCreationEndpointFormatVersion
                        (awsStackCreationWireRequestPayload request)
                        ( encodeRegisteredStackGeneration
                            (selectedStackGeneration selection)
                        )
                    )
    AwsStackCreationWireIndependentReadBack ->
      case decodeAwsStackCreationAuthorityIdentity
        (awsStackCreationWireRequestPayload request) of
        Left err -> pure (refused (AwsStackCreationWireIdentityInvalid (renderError err)))
        Right identity -> do
          observed <- independentlyReadBackAwsStackCreationBinding repository identity
          pure (readBackResult identity observed)

commitResult
  :: ByteString
  -> AwsStackCreationCommitResult
  -> AwsStackCreationEndpointResult
commitResult requestPayload disposition =
  endpointResult
    ( AwsStackCreationWireCommitResult
        awsStackCreationEndpointFormatVersion
        requestPayload
        (commitDispositionToWire disposition)
    )

readBackResult
  :: AwsStackCreationAuthorityIdentity
  -> AwsStackCreationReadBackObservation
  -> AwsStackCreationEndpointResult
readBackResult identity observation = case observation of
  AwsStackCreationReadBackPresent bytes ->
    endpointResult
      ( AwsStackCreationWireReadBackPresent
          awsStackCreationEndpointFormatVersion
          identityBytes
          bytes
      )
  AwsStackCreationReadBackMissing -> refused AwsStackCreationWireReadBackMissing
  AwsStackCreationReadBackCorrupt detail ->
    refused (AwsStackCreationWireReadBackCorrupt (bounded detail))
  AwsStackCreationReadBackUnobservable (ObservationFailure detail) ->
    unavailable (AwsStackCreationWireReadBackUnobservable (bounded detail))
  AwsStackCreationReadBackUnbounded actual maximumBytes ->
    refused (AwsStackCreationWireReadBackUnbounded actual maximumBytes)
 where
  identityBytes = encodeAwsStackCreationAuthorityIdentity identity

-- | Lower the producer's typed refusal to the wire.  The scope and generation
-- failures are distinct constructors on purpose: "the create was admitted but
-- its AWS scope was never proven" and "the cycle could not be reserved" are
-- different operator actions, and neither is a malformed payload.
creationErrorResult
  :: RegisteredStackCreationError -> AwsStackCreationEndpointResult
creationErrorResult err = case err of
  RegisteredStackCreationOperationUnobservable detail -> clientErrorResult detail
  RegisteredStackCreationScopeUnproven _ ->
    refused
      ( AwsStackCreationWireScopeUnproven
          (bounded (renderRegisteredStackCreationError err))
      )
  RegisteredStackCreationGenerationRefused _ ->
    refused
      ( AwsStackCreationWireGenerationRefused
          (bounded (renderRegisteredStackCreationError err))
      )
  RegisteredStackCreationBindingIncomplete disposition ->
    commitResult mempty disposition

clientErrorResult
  :: AwsStackCreationBindingError -> AwsStackCreationEndpointResult
clientErrorResult err = case err of
  AwsStackCreationAdmissionUnavailable detail ->
    unavailable (AwsStackCreationWireAdmissionUnavailable (bounded detail))
  AwsStackCreationConfirmationUnobservable (ObservationFailure detail) ->
    unavailable (AwsStackCreationWireReadBackUnobservable (bounded detail))
  AwsStackCreationConfirmationMissing -> refused AwsStackCreationWireReadBackMissing
  AwsStackCreationConfirmationCorrupt detail ->
    refused (AwsStackCreationWireReadBackCorrupt (bounded detail))
  AwsStackCreationConfirmationUnbounded actual maximumBytes ->
    refused (AwsStackCreationWireReadBackUnbounded actual maximumBytes)
  AwsStackCreationIdentityMismatch _ actual ->
    refused
      ( AwsStackCreationWireReadBackIdentityMismatch
          (encodeAwsStackCreationAuthorityIdentity actual)
      )
  _ -> refused (AwsStackCreationWireCommitPayloadInvalid (renderError err))

requestCodecRefusal
  :: ControlPlaneRequestCodecError -> AwsStackCreationWireResponse
requestCodecRefusal err =
  AwsStackCreationWireRefused
    awsStackCreationEndpointFormatVersion
    ( case err of
        ControlPlaneRequestTooLarge -> AwsStackCreationWireRequestTooLarge
        ControlPlaneRequestInvalid -> AwsStackCreationWireRequestInvalid
        ControlPlaneRequestUnsupportedVersion ->
          AwsStackCreationWireRequestUnsupportedVersion
        ControlPlaneRequestNonCanonical -> AwsStackCreationWireRequestNonCanonical
    )

refused :: AwsStackCreationWireRefusal -> AwsStackCreationEndpointResult
refused refusal =
  endpointResult
    ( AwsStackCreationWireRefused
        awsStackCreationEndpointFormatVersion
        refusal
    )

unavailable
  :: AwsStackCreationWireUnavailable -> AwsStackCreationEndpointResult
unavailable reason =
  endpointResult
    ( AwsStackCreationWireUnavailable
        awsStackCreationEndpointFormatVersion
        reason
    )

endpointResult
  :: AwsStackCreationWireResponse -> AwsStackCreationEndpointResult
endpointResult = AwsStackCreationEndpointResult

awsStackCreationEndpointStatus
  :: AwsStackCreationEndpointResult -> ReplyStatus
awsStackCreationEndpointStatus (AwsStackCreationEndpointResult response) =
  awsStackCreationWireResponseStatus response

awsStackCreationWireResponseStatus
  :: AwsStackCreationWireResponse -> ReplyStatus
awsStackCreationWireResponseStatus response = case response of
  AwsStackCreationWireCommitResult {} -> ReplyOk
  AwsStackCreationWireReadBackPresent {} -> ReplyOk
  AwsStackCreationWireSelected {} -> ReplyOk
  AwsStackCreationWireUnavailable {} -> ReplyServiceUnavailable
  AwsStackCreationWireRefused _ refusal -> case refusal of
    AwsStackCreationWireReadBackMissing -> ReplyNotFound
    AwsStackCreationWireReadBackCorrupt {} -> ReplyConflict
    AwsStackCreationWireReadBackUnbounded {} -> ReplyConflict
    AwsStackCreationWireReadBackIdentityMismatch {} -> ReplyConflict
    AwsStackCreationWireReadBackInvalid {} -> ReplyConflict
    -- A cleanup run that finds no generation is looking at a stack no admitted
    -- create ever committed a cycle for; that is a missing record, not a
    -- malformed request.
    AwsStackCreationWireSelectRefused {} -> ReplyNotFound
    _ -> ReplyBadRequest

awsStackCreationEndpointBody :: AwsStackCreationEndpointResult -> ByteString
awsStackCreationEndpointBody (AwsStackCreationEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeAwsStackCreationEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError AwsStackCreationWireResponse
decodeAwsStackCreationEndpointResponse =
  decodeControlPlaneResponse awsStackCreationEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data AwsStackCreationEndpointResponseError
  = AwsStackCreationEndpointResponseVersionMismatch !Word16 !Word16
  | AwsStackCreationEndpointResponseKindMismatch
  | AwsStackCreationEndpointResponseRequestMismatch !ByteString !ByteString
  | AwsStackCreationEndpointResponseIdentityInvalid !AwsStackCreationBindingError
  | AwsStackCreationEndpointResponseIdentityMismatch
      !AwsStackCreationAuthorityIdentity
      !AwsStackCreationAuthorityIdentity
  | AwsStackCreationEndpointResponseReadBackInvalid !AwsStackCreationBindingError
  | -- | Sprint 4.84: the selected generation record did not decode against the
    -- caller's own compiled registry.  A separate arm from the read-back one
    -- because it is a disagreement about the /registry/, not about a binding.
    AwsStackCreationEndpointResponseSelectionInvalid !Text
  | AwsStackCreationEndpointResponseRefused !AwsStackCreationWireRefusal
  | AwsStackCreationEndpointResponseUnavailable !AwsStackCreationWireUnavailable
  deriving stock (Eq, Show)

confirmAwsStackCreationCommitResponse
  :: ByteString
  -> AwsStackCreationWireResponse
  -> Either
       AwsStackCreationEndpointResponseError
       AwsStackCreationCommitResult
confirmAwsStackCreationCommitResponse expectedPayload response = case response of
  AwsStackCreationWireCommitResult version actualPayload disposition -> do
    validateVersion version
    unless
      (actualPayload == expectedPayload)
      ( Left
          ( AwsStackCreationEndpointResponseRequestMismatch
              expectedPayload
              actualPayload
          )
      )
    pure (commitDispositionFromWire disposition)
  AwsStackCreationWireRefused version refusal -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseRefused refusal)
  AwsStackCreationWireUnavailable version reason -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseUnavailable reason)
  AwsStackCreationWireReadBackPresent version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch
  AwsStackCreationWireSelected version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch

confirmAwsStackCreationReadBackResponse
  :: AwsStackCreationAuthorityIdentity
  -> AwsStackCreationWireResponse
  -> Either
       AwsStackCreationEndpointResponseError
       CommittedAwsStackCreationBinding
confirmAwsStackCreationReadBackResponse expected response = case response of
  AwsStackCreationWireReadBackPresent version identityBytes bindingBytes -> do
    validateVersion version
    validateIdentity expected identityBytes
    first
      AwsStackCreationEndpointResponseReadBackInvalid
      (confirmCommittedAwsStackCreationBindingBytes expected bindingBytes)
  AwsStackCreationWireRefused version refusal -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseRefused refusal)
  AwsStackCreationWireUnavailable version reason -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseUnavailable reason)
  AwsStackCreationWireCommitResult version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch
  AwsStackCreationWireSelected version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch

-- | Sprint 4.84: confirm a cleanup selection.
--
-- The response is validated rather than trusted: the echoed request payload
-- must be this caller\'s own, and the record bytes are decoded with
-- 'decodeRegisteredStackGeneration', which re-derives the coordinate digest and
-- registry revision from the /caller\'s/ compiled registry and refuses a stored
-- disagreement. A response therefore cannot hand a caller a generation its own
-- binary does not agree is well formed.
confirmAwsStackCreationSelectResponse
  :: ByteString
  -> AwsStackCreationWireResponse
  -> Either
       AwsStackCreationEndpointResponseError
       RegisteredStackGeneration
confirmAwsStackCreationSelectResponse expectedPayload response = case response of
  AwsStackCreationWireSelected version actualPayload recordBytes -> do
    validateVersion version
    unless
      (actualPayload == expectedPayload)
      ( Left
          ( AwsStackCreationEndpointResponseRequestMismatch
              expectedPayload
              actualPayload
          )
      )
    first
      (AwsStackCreationEndpointResponseSelectionInvalid . renderStackGenerationError)
      (decodeRegisteredStackGeneration recordBytes)
  AwsStackCreationWireRefused version refusal -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseRefused refusal)
  AwsStackCreationWireUnavailable version reason -> do
    validateVersion version
    Left (AwsStackCreationEndpointResponseUnavailable reason)
  AwsStackCreationWireCommitResult version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch
  AwsStackCreationWireReadBackPresent version _ _ -> do
    validateVersion version
    Left AwsStackCreationEndpointResponseKindMismatch

validateVersion
  :: Word16 -> Either AwsStackCreationEndpointResponseError ()
validateVersion actual
  | actual == awsStackCreationEndpointFormatVersion = Right ()
  | otherwise =
      Left
        ( AwsStackCreationEndpointResponseVersionMismatch
            awsStackCreationEndpointFormatVersion
            actual
        )

validateIdentity
  :: AwsStackCreationAuthorityIdentity
  -> ByteString
  -> Either AwsStackCreationEndpointResponseError ()
validateIdentity expected bytes = do
  actual <-
    first
      AwsStackCreationEndpointResponseIdentityInvalid
      (decodeAwsStackCreationAuthorityIdentity bytes)
  unless
    (actual == expected)
    ( Left
        ( AwsStackCreationEndpointResponseIdentityMismatch
            expected
            actual
        )
    )

decodeCommitPayload
  :: ByteString -> Either Text AwsStackCreationCommitPayload
decodeCommitPayload bytes = do
  when (ByteString.null bytes) (Left "commit payload was empty")
  when
    (ByteString.length bytes > maximumAwsStackCreationBindingBytes)
    (Left "commit payload exceeded the route-local bound")
  payload <-
    first
      (bounded . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (canonicalBytes payload == bytes)
    (Left "commit payload was non-canonical")
  validateScopeWire (creationCommitPayloadScope payload)
  Right payload

decodeSelectPayload
  :: ByteString -> Either Text AwsStackCreationSelectPayload
decodeSelectPayload bytes = do
  when (ByteString.null bytes) (Left "selection payload was empty")
  when
    (ByteString.length bytes > maximumAwsStackCreationBindingBytes)
    (Left "selection payload exceeded the route-local bound")
  payload <-
    first
      (bounded . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (canonicalBytes payload == bytes)
    (Left "selection payload was non-canonical")
  validateScopeWire (creationSelectPayloadScope payload)
  Right payload

scopeToWire :: ObservationEvidenceScope -> AwsStackCreationScopeWire
scopeToWire scope =
  AwsStackCreationScopeWire
    { creationScopeWireSurface = fromEnum (evidenceCleanupSurface scope)
    , creationScopeWireRegistryRevision =
        registryRevisionText (evidenceRegistryRevision scope)
    , creationScopeWireRunScope =
        durableRunScopeText (evidenceDurableRunScope scope)
    , creationScopeWireFoundation =
        foundationText (evidenceLinuxRke2Foundation scope)
    , creationScopeWireAwsAccount =
        awsAccountText <$> evidenceAwsScope scope
    , creationScopeWireAwsRegion =
        awsRegionText <$> evidenceAwsScope scope
    }

scopeFromWire :: AwsStackCreationScopeWire -> ObservationEvidenceScope
scopeFromWire wire =
  mkObservationEvidenceScope
    (toEnum (creationScopeWireSurface wire))
    (RegistryRevision (creationScopeWireRegistryRevision wire))
    (DurableObservationRunScope (creationScopeWireRunScope wire))
    (LinuxRke2FoundationId (creationScopeWireFoundation wire))
    awsScope
    ReconcileDesiredPresent
 where
  awsScope = case (creationScopeWireAwsAccount wire, creationScopeWireAwsRegion wire) of
    (Just account, Just region) ->
      Just (AwsScope (AwsAccountId account) (AwsRegion region))
    _ -> Nothing

validateScopeWire :: AwsStackCreationScopeWire -> Either Text ()
validateScopeWire wire = do
  unless
    ( creationScopeWireSurface wire >= fromEnum (minBound :: CleanupSurface)
        && creationScopeWireSurface wire <= fromEnum (maxBound :: CleanupSurface)
    )
    (Left "creation scope surface was outside the closed enum")
  validateText "registry revision" 512 (creationScopeWireRegistryRevision wire)
  validateText "durable run scope" 512 (creationScopeWireRunScope wire)
  validateText "Linux RKE2 foundation" 512 (creationScopeWireFoundation wire)
  case (creationScopeWireAwsAccount wire, creationScopeWireAwsRegion wire) of
    (Nothing, Nothing) -> Right ()
    (Just account, Just region) -> do
      validateText "AWS account" 128 account
      validateText "AWS region" 128 region
    _ -> Left "creation scope carried only one AWS coordinate"

validateText :: Text -> Int -> Text -> Either Text ()
validateText label maximumLength value =
  unless
    (not (Text.null value) && Text.length value <= maximumLength)
    (Left (label <> " was empty or exceeded its bound"))

canonicalBytes :: (Serialise value) => value -> ByteString
canonicalBytes = LazyByteString.toStrict . serialise

commitDispositionToWire
  :: AwsStackCreationCommitResult -> AwsStackCreationWireCommitDisposition
commitDispositionToWire disposition = case disposition of
  AwsStackCreationCommitCreated -> AwsStackCreationWireCommitCreated
  AwsStackCreationCommitExactReplay -> AwsStackCreationWireCommitExactReplay
  AwsStackCreationCommitConflict -> AwsStackCreationWireCommitConflict
  AwsStackCreationCommitResponseLost (ObservationFailure detail) ->
    AwsStackCreationWireCommitResponseLost (bounded detail)
  AwsStackCreationCommitUnavailable (ObservationFailure detail) ->
    AwsStackCreationWireCommitUnavailable (bounded detail)

commitDispositionFromWire
  :: AwsStackCreationWireCommitDisposition -> AwsStackCreationCommitResult
commitDispositionFromWire disposition = case disposition of
  AwsStackCreationWireCommitCreated -> AwsStackCreationCommitCreated
  AwsStackCreationWireCommitExactReplay -> AwsStackCreationCommitExactReplay
  AwsStackCreationWireCommitConflict -> AwsStackCreationCommitConflict
  AwsStackCreationWireCommitResponseLost detail ->
    AwsStackCreationCommitResponseLost (ObservationFailure (bounded detail))
  AwsStackCreationWireCommitUnavailable detail ->
    AwsStackCreationCommitUnavailable (ObservationFailure (bounded detail))

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

durableRunScopeText :: DurableObservationRunScope -> Text
durableRunScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

awsAccountText :: AwsScope -> Text
awsAccountText (AwsScope (AwsAccountId value) _) = value

awsRegionText :: AwsScope -> Text
awsRegionText (AwsScope _ (AwsRegion value)) = value

renderError :: AwsStackCreationBindingError -> Text
renderError = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024

requireListLength :: String -> Int -> Cbor.Decoder s ()
requireListLength label expected = do
  actual <- Cbor.decodeListLen
  unless (actual == expected) $
    fail (label <> ": expected " <> show expected <> " fields")
