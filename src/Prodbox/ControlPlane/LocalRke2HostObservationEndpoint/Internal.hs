{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private commit-only endpoint for the host-observed local RKE2
-- Healthy receipt.  Candidate construction happens on the host after the
-- fenced Establish Begin; the Authority independently reloads the exact
-- descriptor-bound run before validating and committing those canonical
-- bytes.  No positive read-back proof crosses this protocol.
module Prodbox.ControlPlane.LocalRke2HostObservationEndpoint.Internal
  ( LocalRke2HostObservationWireRequest (..)
  , localRke2HostObservationCommitWireRequestInternal
  , LocalRke2HostObservationWireDisposition (..)
  , LocalRke2HostObservationWireRefusal (..)
  , LocalRke2HostObservationWireResponse (..)
  , LocalRke2HostObservationEndpointHandler
  , lifecycleAuthorityLocalRke2HostObservationEndpointHandlerInternal
  , LocalRke2HostObservationEndpointResult
  , localRke2HostObservationEndpointFormatVersion
  , localRke2HostObservationEndpointMaximumBytes
  , localRke2HostObservationEndpointResponseMaximumBytes
  , serveLocalRke2HostObservationEndpointRequest
  , localRke2HostObservationEndpointStatus
  , localRke2HostObservationWireResponseStatus
  , localRke2HostObservationEndpointBody
  , decodeLocalRke2HostObservationEndpointResponseInternal
  , LocalRke2HostObservationEndpointResponseError (..)
  , confirmLocalRke2HostObservationResponseInternal
  , LocalRke2HostObservationEndpointRegression
  , fixedLocalRke2HostObservationEndpointRegression
  , localRke2HostObservationEndpointValidExact
  , localRke2HostObservationEndpointMalformedNoExecution
  , localRke2HostObservationEndpointOversizeNoExecution
  , localRke2HostObservationEndpointInvalidIdentityNoExecution
  , localRke2HostObservationEndpointUnsupportedVersionNoExecution
  , localRke2HostObservationEndpointCandidateBoundNoExecution
  , localRke2HostObservationEndpointAllArmsValidateVersion
  , localRke2HostObservationEndpointAllArmsValidateRequestDigest
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunGraphDigest
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunRepositoryProvider
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.LocalRke2HostObservationRepository
  ( LocalRke2HostObservationCommitResult (..)
  , LocalRke2HostObservationRepositoryError (..)
  )
import Prodbox.ControlPlane.LocalRke2HostObservationRepository.Internal
  ( LocalRke2HostObservationRepositoryClient
  , commitEncodedLocalRke2HostObservationAttemptInternal
  )
import Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal
  ( loadDescriptorBoundCleanupRunForAuthorityInternal
  )
import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
  ( withDescriptorBoundRecoveryPlaneIdentityInternal
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupNodeState (CleanupNodeRunning)
  , CleanupOperationId
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupAttemptId
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( cleanupNodeExecutionAttemptId
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  , descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation
  ( LocalRke2HostObservationIdentity
  , localRke2HostObservationEstablishAttemptId
  , localRke2HostObservationEstablishOperationId
  , localRke2HostObservationRunId
  , maximumLocalRke2HostObservationBytes
  )
import Prodbox.Lifecycle.Teardown.LocalRke2HostObservation.Internal
  ( LocalRke2HostObservationCandidate
  , encodeLocalRke2HostObservationCandidateInternal
  , localRke2HostObservationCandidateIdentityInternal
  , localRke2HostObservationIdentityFromBindingInternal
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationFailure (ObservationFailure)
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneIdentity
  , recoveryPlaneIdentityEstablishOperationId
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( recoveryPlaneAttemptBindingInternal
  )

data LocalRke2HostObservationWireRequest
  = LocalRke2HostObservationWireRequest
  { localRke2HostObservationWireRequestVersion :: !Word16
  , localRke2HostObservationWireRequestRunId :: !Text
  , localRke2HostObservationWireRequestOperationId :: !Text
  , localRke2HostObservationWireRequestAttemptId :: !Text
  , localRke2HostObservationWireRequestCandidate :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

localRke2HostObservationCommitWireRequestInternal
  :: LocalRke2HostObservationCandidate surface
  -> LocalRke2HostObservationWireRequest
localRke2HostObservationCommitWireRequestInternal candidate =
  LocalRke2HostObservationWireRequest
    { localRke2HostObservationWireRequestVersion =
        localRke2HostObservationEndpointFormatVersion
    , localRke2HostObservationWireRequestRunId =
        cleanupRunIdText (localRke2HostObservationRunId identity)
    , localRke2HostObservationWireRequestOperationId =
        cleanupOperationIdText
          (localRke2HostObservationEstablishOperationId identity)
    , localRke2HostObservationWireRequestAttemptId =
        cleanupAttemptIdText
          (localRke2HostObservationEstablishAttemptId identity)
    , localRke2HostObservationWireRequestCandidate =
        encodeLocalRke2HostObservationCandidateInternal candidate
    }
 where
  identity = localRke2HostObservationCandidateIdentityInternal candidate

data LocalRke2HostObservationWireDisposition
  = LocalRke2HostObservationWireCreated
  | LocalRke2HostObservationWireExactReplay
  | LocalRke2HostObservationWireConflict
  | LocalRke2HostObservationWireResponseLost !Text
  | LocalRke2HostObservationWireUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LocalRke2HostObservationWireRefusal
  = LocalRke2HostObservationWireRequestTooLarge
  | LocalRke2HostObservationWireRequestInvalid
  | LocalRke2HostObservationWireRequestUnsupportedVersion
  | LocalRke2HostObservationWireRequestNonCanonical
  | LocalRke2HostObservationWireIdentityInvalid !Text
  | LocalRke2HostObservationWireRunUnavailable !Text
  | LocalRke2HostObservationWireBindingMismatch !Text
  | LocalRke2HostObservationWireCandidateInvalid !Text
  | LocalRke2HostObservationWireRepositoryRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data LocalRke2HostObservationWireResponse
  = LocalRke2HostObservationWireCommitted
      !Word16
      !ByteString
      !LocalRke2HostObservationWireDisposition
  | LocalRke2HostObservationWireRefused
      !Word16
      !ByteString
      !LocalRke2HostObservationWireRefusal
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype LocalRke2HostObservationEndpointHandler m
  = LocalRke2HostObservationEndpointHandler
      ( ValidLocalRke2HostObservationRequest
        -> ByteString
        -> m LocalRke2HostObservationWireResponse
      )

data ValidLocalRke2HostObservationRequest
  = ValidLocalRke2HostObservationRequest
  { validLocalRke2HostObservationRunId :: !CleanupRunId
  , validLocalRke2HostObservationOperationId :: !CleanupOperationId
  , validLocalRke2HostObservationAttemptId :: !CleanupAttemptId
  , validLocalRke2HostObservationCandidate :: !ByteString
  }

newtype LocalRke2HostObservationEndpointResult
  = LocalRke2HostObservationEndpointResult
      LocalRke2HostObservationWireResponse
  deriving stock (Eq, Show)

localRke2HostObservationEndpointFormatVersion :: Word16
localRke2HostObservationEndpointFormatVersion = 1

localRke2HostObservationEndpointMaximumBytes :: Int
localRke2HostObservationEndpointMaximumBytes = 24 * 1024

localRke2HostObservationEndpointResponseMaximumBytes :: Int
localRke2HostObservationEndpointResponseMaximumBytes = 16 * 1024

lifecycleAuthorityLocalRke2HostObservationEndpointHandlerInternal
  :: (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> CleanupRunRepositoryProvider m revision
  -> LocalRke2HostObservationEndpointHandler m
lifecycleAuthorityLocalRke2HostObservationEndpointHandlerInternal repository provider =
  LocalRke2HostObservationEndpointHandler $ \request requestDigest -> do
    observed <-
      loadDescriptorBoundCleanupRunForAuthorityInternal
        provider
        (validLocalRke2HostObservationRunId request)
    case observed of
      Left err -> pure (runUnavailable requestDigest err)
      Right bound -> executeAgainstBound repository bound request requestDigest

executeAgainstBound
  :: forall m
   . (Monad m)
  => LocalRke2HostObservationRepositoryClient m
  -> DescriptorBoundCleanupRun
  -> ValidLocalRke2HostObservationRequest
  -> ByteString
  -> m LocalRke2HostObservationWireResponse
executeAgainstBound repository bound request requestDigest
  | descriptorBoundCleanupRunId bound
      /= validLocalRke2HostObservationRunId request =
      pure (bindingRefusal requestDigest "reloaded cleanup run id differs")
  | otherwise =
      case withDescriptorBoundRecoveryPlaneIdentityInternal bound selectIdentity of
        Left err -> pure (bindingRefusal requestDigest (render err))
        Right action -> action
 where
  selectIdentity
    :: forall surface
     . RecoveryPlaneIdentity surface
    -> m LocalRke2HostObservationWireResponse
  selectIdentity recoveryIdentity
    | expectedOperation /= validLocalRke2HostObservationOperationId request =
        pure (bindingRefusal requestDigest "request operation is not the compiled Establish operation")
    | otherwise = case matchingPlans of
        [] -> pure (bindingRefusal requestDigest "compiled Establish operation is absent")
        _first : _second : _ ->
          pure (bindingRefusal requestDigest "compiled Establish operation is duplicated")
        plan : _ -> case Map.lookup
          (cleanupNodeId plan)
          (descriptorBoundCleanupRunNodeStates bound) of
          Just (CleanupNodeRunning actualAttempt)
            | actualAttempt == validLocalRke2HostObservationAttemptId request ->
                case descriptorBoundCleanupNodeExecutionContext bound plan of
                  Left detail -> pure (bindingRefusal requestDigest detail)
                  Right context
                    | not (contextMatches plan context) ->
                        pure (bindingRefusal requestDigest "durable execution context differs")
                    | otherwise -> case expectedObservationIdentity recoveryIdentity actualAttempt of
                        Left err -> pure (bindingRefusal requestDigest (render err))
                        Right expected -> do
                          committed <-
                            commitEncodedLocalRke2HostObservationAttemptInternal
                              repository
                              expected
                              (validLocalRke2HostObservationCandidate request)
                          pure $ case committed of
                            Left err -> repositoryRefusal requestDigest err
                            Right disposition -> committedResponse requestDigest disposition
          Just (CleanupNodeRunning _) ->
            pure (bindingRefusal requestDigest "Establish attempt differs")
          _ -> pure (bindingRefusal requestDigest "Establish node is not currently Running")
   where
    expectedOperation =
      recoveryPlaneIdentityEstablishOperationId recoveryIdentity
    matchingPlans =
      filter
        ((== expectedOperation) . cleanupNodeOperationId)
        (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound))

    contextMatches plan context =
      cleanupNodeExecutionRunId context == descriptorBoundCleanupRunId bound
        && cleanupNodeExecutionGraphDigest context
          == descriptorBoundCleanupRunGraphDigest bound
        && cleanupNodeExecutionNodeId context == cleanupNodeId plan
        && cleanupNodeExecutionAttemptId context
          == validLocalRke2HostObservationAttemptId request

    expectedObservationIdentity
      :: RecoveryPlaneIdentity surface
      -> CleanupAttemptId
      -> Either
           LocalRke2HostObservationRepositoryError
           (LocalRke2HostObservationIdentity surface)
    expectedObservationIdentity identity attempt =
      first
        LocalRke2HostObservationRepositoryAdmissionInvalid
        ( localRke2HostObservationIdentityFromBindingInternal
            identity
            (recoveryPlaneAttemptBindingInternal identity expectedOperation attempt)
        )

serveLocalRke2HostObservationEndpointRequest
  :: (Monad m)
  => LocalRke2HostObservationEndpointHandler m
  -> LazyByteString.ByteString
  -> m LocalRke2HostObservationEndpointResult
serveLocalRke2HostObservationEndpointRequest
  (LocalRke2HostObservationEndpointHandler handle)
  requestBytes = do
    let strictBytes = LazyByteString.toStrict requestBytes
        requestDigest = hexSha256 strictBytes
    response <- case decodeControlPlaneRequest localRke2HostObservationEndpointMaximumBytes requestBytes of
      Left err -> pure (codecRefusal requestDigest err)
      Right request -> case validateRequest request of
        Left refusal -> pure (refused requestDigest refusal)
        Right valid -> handle valid requestDigest
    pure (LocalRke2HostObservationEndpointResult response)

validateRequest
  :: LocalRke2HostObservationWireRequest
  -> Either
       LocalRke2HostObservationWireRefusal
       ValidLocalRke2HostObservationRequest
validateRequest request = do
  unless
    ( localRke2HostObservationWireRequestVersion request
        == localRke2HostObservationEndpointFormatVersion
    )
    (Left LocalRke2HostObservationWireRequestUnsupportedVersion)
  runId <-
    first
      identityInvalid
      (mkCleanupRunId (localRke2HostObservationWireRequestRunId request))
  operationId <-
    first
      identityInvalid
      (mkCleanupOperationId (localRke2HostObservationWireRequestOperationId request))
  attemptId <-
    first
      identityInvalid
      (mkCleanupAttemptId (localRke2HostObservationWireRequestAttemptId request))
  let candidate = localRke2HostObservationWireRequestCandidate request
  when
    (ByteString.null candidate)
    (Left (LocalRke2HostObservationWireCandidateInvalid "candidate is empty"))
  when
    (ByteString.length candidate > maximumLocalRke2HostObservationBytes)
    ( Left
        ( LocalRke2HostObservationWireCandidateInvalid
            "candidate exceeds the canonical host-observation bound"
        )
    )
  pure
    ValidLocalRke2HostObservationRequest
      { validLocalRke2HostObservationRunId = runId
      , validLocalRke2HostObservationOperationId = operationId
      , validLocalRke2HostObservationAttemptId = attemptId
      , validLocalRke2HostObservationCandidate = candidate
      }
 where
  identityInvalid =
    LocalRke2HostObservationWireIdentityInvalid . bounded . Text.pack . show

localRke2HostObservationEndpointStatus
  :: LocalRke2HostObservationEndpointResult -> ReplyStatus
localRke2HostObservationEndpointStatus
  (LocalRke2HostObservationEndpointResult response) =
    localRke2HostObservationWireResponseStatus response

localRke2HostObservationWireResponseStatus
  :: LocalRke2HostObservationWireResponse -> ReplyStatus
localRke2HostObservationWireResponseStatus response = case response of
  LocalRke2HostObservationWireCommitted _ _ disposition -> case disposition of
    LocalRke2HostObservationWireCreated -> ReplyOk
    LocalRke2HostObservationWireExactReplay -> ReplyOk
    LocalRke2HostObservationWireConflict -> ReplyConflict
    LocalRke2HostObservationWireResponseLost _ -> ReplyServiceUnavailable
    LocalRke2HostObservationWireUnavailable _ -> ReplyServiceUnavailable
  LocalRke2HostObservationWireRefused _ _ refusal -> case refusal of
    LocalRke2HostObservationWireRequestTooLarge -> ReplyBadRequest
    LocalRke2HostObservationWireRequestInvalid -> ReplyBadRequest
    LocalRke2HostObservationWireRequestUnsupportedVersion -> ReplyBadRequest
    LocalRke2HostObservationWireRequestNonCanonical -> ReplyBadRequest
    LocalRke2HostObservationWireIdentityInvalid _ -> ReplyBadRequest
    LocalRke2HostObservationWireRunUnavailable _ -> ReplyServiceUnavailable
    LocalRke2HostObservationWireBindingMismatch _ -> ReplyConflict
    LocalRke2HostObservationWireCandidateInvalid _ -> ReplyConflict
    LocalRke2HostObservationWireRepositoryRefused _ -> ReplyConflict

localRke2HostObservationEndpointBody
  :: LocalRke2HostObservationEndpointResult -> ByteString
localRke2HostObservationEndpointBody
  (LocalRke2HostObservationEndpointResult response) =
    LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeLocalRke2HostObservationEndpointResponseInternal
  :: ByteString
  -> Either ControlPlaneResponseCodecError LocalRke2HostObservationWireResponse
decodeLocalRke2HostObservationEndpointResponseInternal =
  decodeControlPlaneResponse localRke2HostObservationEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data LocalRke2HostObservationEndpointResponseError
  = LocalRke2HostObservationEndpointResponseVersionMismatch !Word16 !Word16
  | LocalRke2HostObservationEndpointResponseRequestMismatch !ByteString !ByteString
  | LocalRke2HostObservationEndpointResponseRefused !LocalRke2HostObservationWireRefusal
  deriving stock (Eq, Show)

confirmLocalRke2HostObservationResponseInternal
  :: LocalRke2HostObservationWireRequest
  -> LocalRke2HostObservationWireResponse
  -> Either
       LocalRke2HostObservationEndpointResponseError
       LocalRke2HostObservationCommitResult
confirmLocalRke2HostObservationResponseInternal request response = do
  let expectedDigest =
        hexSha256
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      confirmBinding version actualDigest = do
        unless
          (version == localRke2HostObservationEndpointFormatVersion)
          ( Left
              ( LocalRke2HostObservationEndpointResponseVersionMismatch
                  localRke2HostObservationEndpointFormatVersion
                  version
              )
          )
        unless
          (actualDigest == expectedDigest)
          ( Left
              ( LocalRke2HostObservationEndpointResponseRequestMismatch
                  expectedDigest
                  actualDigest
              )
          )
  case response of
    LocalRke2HostObservationWireCommitted version actualDigest disposition -> do
      confirmBinding version actualDigest
      pure (dispositionFromWire disposition)
    LocalRke2HostObservationWireRefused version actualDigest refusal -> do
      confirmBinding version actualDigest
      Left (LocalRke2HostObservationEndpointResponseRefused refusal)

-- | Fixed non-authorizing endpoint regression.  Only booleans cross the
-- public facade; wire constructors, handler construction, and candidate bytes
-- remain confined to this hidden module.
data LocalRke2HostObservationEndpointRegression
  = LocalRke2HostObservationEndpointRegression
  { internalLocalRke2HostObservationEndpointValidExact :: !Bool
  , internalLocalRke2HostObservationEndpointMalformedNoExecution :: !Bool
  , internalLocalRke2HostObservationEndpointOversizeNoExecution :: !Bool
  , internalLocalRke2HostObservationEndpointInvalidIdentityNoExecution :: !Bool
  , internalLocalRke2HostObservationEndpointUnsupportedVersionNoExecution :: !Bool
  , internalLocalRke2HostObservationEndpointCandidateBoundNoExecution :: !Bool
  , internalLocalRke2HostObservationEndpointAllArmsValidateVersion :: !Bool
  , internalLocalRke2HostObservationEndpointAllArmsValidateRequestDigest :: !Bool
  }

fixedLocalRke2HostObservationEndpointRegression
  :: IO LocalRke2HostObservationEndpointRegression
fixedLocalRke2HostObservationEndpointRegression =
  case ( mkCleanupRunId "local-rke2-host-observation-run"
       , mkCleanupOperationId "establish-recovery-plane"
       , mkCleanupAttemptId "establish-recovery-plane-attempt"
       ) of
    (Right runId, Right operationId, Right attemptId) -> do
      executions <- newIORef (0 :: Int)
      let request =
            LocalRke2HostObservationWireRequest
              localRke2HostObservationEndpointFormatVersion
              (cleanupRunIdText runId)
              (cleanupOperationIdText operationId)
              (cleanupAttemptIdText attemptId)
              "canonical-opaque-healthy-candidate"
          requestBytes = encodeControlPlaneRequest request
          requestDigest = hexSha256 (LazyByteString.toStrict requestBytes)
          handler =
            LocalRke2HostObservationEndpointHandler $ \_ digest -> do
              modifyIORef' executions (+ 1)
              pure
                ( LocalRke2HostObservationWireCommitted
                    localRke2HostObservationEndpointFormatVersion
                    digest
                    LocalRke2HostObservationWireCreated
                )
      validResult <- serveLocalRke2HostObservationEndpointRequest handler requestBytes
      validCount <- readIORef executions
      malformedResult <-
        serveLocalRke2HostObservationEndpointRequest handler (LazyByteString.singleton 0)
      malformedCount <- readIORef executions
      oversizeResult <-
        serveLocalRke2HostObservationEndpointRequest
          handler
          ( LazyByteString.replicate
              (fromIntegral localRke2HostObservationEndpointMaximumBytes + 1)
              0
          )
      oversizeCount <- readIORef executions
      invalidIdentityResult <-
        serveLocalRke2HostObservationEndpointRequest
          handler
          ( encodeControlPlaneRequest
              request {localRke2HostObservationWireRequestRunId = ""}
          )
      invalidIdentityCount <- readIORef executions
      unsupportedVersionResult <-
        serveLocalRke2HostObservationEndpointRequest
          handler
          ( encodeControlPlaneRequest
              request
                { localRke2HostObservationWireRequestVersion =
                    localRke2HostObservationEndpointFormatVersion + 1
                }
          )
      unsupportedVersionCount <- readIORef executions
      candidateBoundResult <-
        serveLocalRke2HostObservationEndpointRequest
          handler
          ( encodeControlPlaneRequest
              request
                { localRke2HostObservationWireRequestCandidate =
                    ByteString.replicate
                      (maximumLocalRke2HostObservationBytes + 1)
                      0
                }
          )
      candidateBoundCount <- readIORef executions
      let wrongVersion = localRke2HostObservationEndpointFormatVersion + 1
          wrongDigest = ByteString.replicate 32 0
          dispositions =
            [ LocalRke2HostObservationWireCreated
            , LocalRke2HostObservationWireExactReplay
            , LocalRke2HostObservationWireConflict
            , LocalRke2HostObservationWireResponseLost "response-lost"
            , LocalRke2HostObservationWireUnavailable "unavailable"
            ]
          versionResponses =
            map
              ( LocalRke2HostObservationWireCommitted
                  wrongVersion
                  requestDigest
              )
              dispositions
              <> [ LocalRke2HostObservationWireRefused
                     wrongVersion
                     requestDigest
                     LocalRke2HostObservationWireRequestInvalid
                 ]
          digestResponses =
            map
              ( LocalRke2HostObservationWireCommitted
                  localRke2HostObservationEndpointFormatVersion
                  wrongDigest
              )
              dispositions
              <> [ LocalRke2HostObservationWireRefused
                     localRke2HostObservationEndpointFormatVersion
                     wrongDigest
                     LocalRke2HostObservationWireRequestInvalid
                 ]
      pure
        LocalRke2HostObservationEndpointRegression
          { internalLocalRke2HostObservationEndpointValidExact =
              validCount == 1
                && endpointResponse validResult
                  == LocalRke2HostObservationWireCommitted
                    localRke2HostObservationEndpointFormatVersion
                    requestDigest
                    LocalRke2HostObservationWireCreated
                && confirmLocalRke2HostObservationResponseInternal
                  request
                  (endpointResponse validResult)
                  == Right LocalRke2HostObservationCommitCreated
          , internalLocalRke2HostObservationEndpointMalformedNoExecution =
              malformedCount == 1
                && hasRefusal LocalRke2HostObservationWireRequestInvalid malformedResult
          , internalLocalRke2HostObservationEndpointOversizeNoExecution =
              oversizeCount == 1
                && hasRefusal LocalRke2HostObservationWireRequestTooLarge oversizeResult
          , internalLocalRke2HostObservationEndpointInvalidIdentityNoExecution =
              invalidIdentityCount == 1
                && hasIdentityRefusal invalidIdentityResult
          , internalLocalRke2HostObservationEndpointUnsupportedVersionNoExecution =
              unsupportedVersionCount == 1
                && hasRefusal
                  LocalRke2HostObservationWireRequestUnsupportedVersion
                  unsupportedVersionResult
          , internalLocalRke2HostObservationEndpointCandidateBoundNoExecution =
              candidateBoundCount == 1
                && hasCandidateRefusal candidateBoundResult
          , internalLocalRke2HostObservationEndpointAllArmsValidateVersion =
              all
                ( isVersionMismatch
                    . confirmLocalRke2HostObservationResponseInternal request
                )
                versionResponses
          , internalLocalRke2HostObservationEndpointAllArmsValidateRequestDigest =
              all
                ( isRequestMismatch
                    . confirmLocalRke2HostObservationResponseInternal request
                )
                digestResponses
          }
    _ -> pure falseLocalRke2HostObservationEndpointRegression
 where
  endpointResponse (LocalRke2HostObservationEndpointResult response) = response

  hasRefusal expected result = case endpointResponse result of
    LocalRke2HostObservationWireRefused _ _ actual -> actual == expected
    _ -> False

  hasIdentityRefusal result = case endpointResponse result of
    LocalRke2HostObservationWireRefused _ _ LocalRke2HostObservationWireIdentityInvalid {} -> True
    _ -> False

  hasCandidateRefusal result = case endpointResponse result of
    LocalRke2HostObservationWireRefused _ _ LocalRke2HostObservationWireCandidateInvalid {} -> True
    _ -> False

  isVersionMismatch result = case result of
    Left LocalRke2HostObservationEndpointResponseVersionMismatch {} -> True
    _ -> False

  isRequestMismatch result = case result of
    Left LocalRke2HostObservationEndpointResponseRequestMismatch {} -> True
    _ -> False

falseLocalRke2HostObservationEndpointRegression
  :: LocalRke2HostObservationEndpointRegression
falseLocalRke2HostObservationEndpointRegression =
  LocalRke2HostObservationEndpointRegression
    { internalLocalRke2HostObservationEndpointValidExact = False
    , internalLocalRke2HostObservationEndpointMalformedNoExecution = False
    , internalLocalRke2HostObservationEndpointOversizeNoExecution = False
    , internalLocalRke2HostObservationEndpointInvalidIdentityNoExecution = False
    , internalLocalRke2HostObservationEndpointUnsupportedVersionNoExecution = False
    , internalLocalRke2HostObservationEndpointCandidateBoundNoExecution = False
    , internalLocalRke2HostObservationEndpointAllArmsValidateVersion = False
    , internalLocalRke2HostObservationEndpointAllArmsValidateRequestDigest = False
    }

localRke2HostObservationEndpointValidExact
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointValidExact =
  internalLocalRke2HostObservationEndpointValidExact

localRke2HostObservationEndpointMalformedNoExecution
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointMalformedNoExecution =
  internalLocalRke2HostObservationEndpointMalformedNoExecution

localRke2HostObservationEndpointOversizeNoExecution
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointOversizeNoExecution =
  internalLocalRke2HostObservationEndpointOversizeNoExecution

localRke2HostObservationEndpointInvalidIdentityNoExecution
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointInvalidIdentityNoExecution =
  internalLocalRke2HostObservationEndpointInvalidIdentityNoExecution

localRke2HostObservationEndpointUnsupportedVersionNoExecution
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointUnsupportedVersionNoExecution =
  internalLocalRke2HostObservationEndpointUnsupportedVersionNoExecution

localRke2HostObservationEndpointCandidateBoundNoExecution
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointCandidateBoundNoExecution =
  internalLocalRke2HostObservationEndpointCandidateBoundNoExecution

localRke2HostObservationEndpointAllArmsValidateVersion
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointAllArmsValidateVersion =
  internalLocalRke2HostObservationEndpointAllArmsValidateVersion

localRke2HostObservationEndpointAllArmsValidateRequestDigest
  :: LocalRke2HostObservationEndpointRegression -> Bool
localRke2HostObservationEndpointAllArmsValidateRequestDigest =
  internalLocalRke2HostObservationEndpointAllArmsValidateRequestDigest

committedResponse
  :: ByteString
  -> LocalRke2HostObservationCommitResult
  -> LocalRke2HostObservationWireResponse
committedResponse requestDigest result =
  LocalRke2HostObservationWireCommitted
    localRke2HostObservationEndpointFormatVersion
    requestDigest
    (dispositionToWire result)

refused
  :: ByteString
  -> LocalRke2HostObservationWireRefusal
  -> LocalRke2HostObservationWireResponse
refused requestDigest refusal =
  LocalRke2HostObservationWireRefused
    localRke2HostObservationEndpointFormatVersion
    requestDigest
    refusal

bindingRefusal :: ByteString -> Text -> LocalRke2HostObservationWireResponse
bindingRefusal requestDigest =
  refused requestDigest . LocalRke2HostObservationWireBindingMismatch . bounded

repositoryRefusal
  :: ByteString
  -> LocalRke2HostObservationRepositoryError
  -> LocalRke2HostObservationWireResponse
repositoryRefusal requestDigest =
  refused requestDigest . LocalRke2HostObservationWireRepositoryRefused . render

runUnavailable
  :: ByteString
  -> CleanupRunClientError
  -> LocalRke2HostObservationWireResponse
runUnavailable requestDigest =
  refused requestDigest . LocalRke2HostObservationWireRunUnavailable . render

codecRefusal
  :: ByteString
  -> ControlPlaneRequestCodecError
  -> LocalRke2HostObservationWireResponse
codecRefusal requestDigest err =
  refused requestDigest $ case err of
    ControlPlaneRequestTooLarge {} -> LocalRke2HostObservationWireRequestTooLarge
    ControlPlaneRequestInvalid -> LocalRke2HostObservationWireRequestInvalid
    ControlPlaneRequestUnsupportedVersion ->
      LocalRke2HostObservationWireRequestUnsupportedVersion
    ControlPlaneRequestNonCanonical -> LocalRke2HostObservationWireRequestNonCanonical

dispositionToWire
  :: LocalRke2HostObservationCommitResult
  -> LocalRke2HostObservationWireDisposition
dispositionToWire result = case result of
  LocalRke2HostObservationCommitCreated -> LocalRke2HostObservationWireCreated
  LocalRke2HostObservationCommitExactReplay ->
    LocalRke2HostObservationWireExactReplay
  LocalRke2HostObservationCommitConflict -> LocalRke2HostObservationWireConflict
  LocalRke2HostObservationCommitResponseLost (ObservationFailure detail) ->
    LocalRke2HostObservationWireResponseLost (bounded detail)
  LocalRke2HostObservationCommitUnavailable (ObservationFailure detail) ->
    LocalRke2HostObservationWireUnavailable (bounded detail)

dispositionFromWire
  :: LocalRke2HostObservationWireDisposition
  -> LocalRke2HostObservationCommitResult
dispositionFromWire disposition = case disposition of
  LocalRke2HostObservationWireCreated -> LocalRke2HostObservationCommitCreated
  LocalRke2HostObservationWireExactReplay ->
    LocalRke2HostObservationCommitExactReplay
  LocalRke2HostObservationWireConflict -> LocalRke2HostObservationCommitConflict
  LocalRke2HostObservationWireResponseLost detail ->
    LocalRke2HostObservationCommitResponseLost (ObservationFailure (bounded detail))
  LocalRke2HostObservationWireUnavailable detail ->
    LocalRke2HostObservationCommitUnavailable (ObservationFailure (bounded detail))

render :: (Show value) => value -> Text
render = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024
