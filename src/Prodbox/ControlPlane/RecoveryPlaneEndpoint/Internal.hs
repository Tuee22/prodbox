{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private Authority execution endpoint for recovery-plane
-- read-backs.  The wire carries only the durable run/current-op/current-attempt
-- identity.  Descriptor reload, component observation, Model-B commit,
-- independent read-back, and Execution validation all remain server-local.
module Prodbox.ControlPlane.RecoveryPlaneEndpoint.Internal
  ( RecoveryPlaneWirePhase (..)
  , RecoveryPlaneWireRequest (..)
  , recoveryPlaneInitialReadBackWireRequest
  , recoveryPlaneFinalDispositionWireRequest
  , RecoveryPlaneWireOutcome (..)
  , RecoveryPlaneWireRefusal (..)
  , RecoveryPlaneWireUnavailable (..)
  , RecoveryPlaneWireResponse (..)
  , RecoveryPlaneEndpointHandler
  , lifecycleAuthorityRecoveryPlaneEndpointHandlerInternal
  , loadDescriptorBoundCleanupRunForAuthorityInternal
  , RecoveryPlaneEndpointResult
  , recoveryPlaneEndpointFormatVersion
  , recoveryPlaneEndpointMaximumBytes
  , recoveryPlaneEndpointResponseMaximumBytes
  , serveRecoveryPlaneEndpointRequest
  , recoveryPlaneEndpointStatus
  , recoveryPlaneWireResponseStatus
  , recoveryPlaneEndpointBody
  , decodeRecoveryPlaneEndpointResponse
  , RecoveryPlaneEndpointResponseError (..)
  , confirmRecoveryPlaneResponse
  , RecoveryPlaneEndpointRegression
  , fixedRecoveryPlaneEndpointRegression
  , recoveryPlaneEndpointValidExact
  , recoveryPlaneEndpointMalformedNoExecution
  , recoveryPlaneEndpointOversizeNoExecution
  , recoveryPlaneEndpointInvalidIdentityNoExecution
  , recoveryPlaneEndpointUnsupportedVersionNoExecution
  , recoveryPlaneEndpointAllArmsValidateVersion
  , recoveryPlaneEndpointAllArmsValidateRequestDigest
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless)
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
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository
  ( CommittedCleanupProgramDescriptor
  , committedCleanupProgramDescriptorDigest
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( confirmCommittedCleanupProgramDescriptorBytes
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError (..)
  , DescriptorBoundCleanupRun
  , descriptorBoundCleanupRunGraph
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunNodeStates
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.CleanupRunClient.Internal
  ( DescriptorBoundCleanupRun (DescriptorBoundCleanupRun)
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunCommand (CleanupRunDescriptorBound)
  , CleanupRunDescriptorCommand (..)
  , CleanupRunDescriptorRefusal (..)
  , CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , CleanupRunRepositoryProvider
  , cleanupRunMaximumBytes
  , serveCleanupRunRequest
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError (..)
  , ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeOutcome (..)
  , CleanupNodeState (CleanupNodeRunning)
  , CleanupOperationId
  , CleanupRun
  , CleanupRunId
  , cleanupAttemptIdText
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunId
  , cleanupRunIdText
  , decodeCleanupRun
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter
  ( RecoveryPlaneInterpreter
  , RecoveryPlaneReadBackPhase (..)
  , executeRecoveryPlaneDescriptorBoundPhase
  )

data RecoveryPlaneWirePhase
  = RecoveryPlaneWireInitialReadBack
  | RecoveryPlaneWireFinalDisposition
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneWireRequest = RecoveryPlaneWireRequest
  { recoveryPlaneWireRequestVersion :: !Word16
  , recoveryPlaneWireRequestPhase :: !RecoveryPlaneWirePhase
  , recoveryPlaneWireRequestRunId :: !Text
  , recoveryPlaneWireRequestOperationId :: !Text
  , recoveryPlaneWireRequestAttemptId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

recoveryPlaneInitialReadBackWireRequest
  :: CleanupRunId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneWireRequest
recoveryPlaneInitialReadBackWireRequest =
  recoveryPlaneWireRequest RecoveryPlaneWireInitialReadBack

recoveryPlaneFinalDispositionWireRequest
  :: CleanupRunId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneWireRequest
recoveryPlaneFinalDispositionWireRequest =
  recoveryPlaneWireRequest RecoveryPlaneWireFinalDisposition

recoveryPlaneWireRequest
  :: RecoveryPlaneWirePhase
  -> CleanupRunId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> RecoveryPlaneWireRequest
recoveryPlaneWireRequest phase runId operationId attemptId =
  RecoveryPlaneWireRequest
    { recoveryPlaneWireRequestVersion = recoveryPlaneEndpointFormatVersion
    , recoveryPlaneWireRequestPhase = phase
    , recoveryPlaneWireRequestRunId = cleanupRunIdText runId
    , recoveryPlaneWireRequestOperationId = cleanupOperationIdText operationId
    , recoveryPlaneWireRequestAttemptId = cleanupAttemptIdText attemptId
    }

data RecoveryPlaneWireOutcome
  = RecoveryPlaneWireSucceeded
  | RecoveryPlaneWireFailed !Text
  | RecoveryPlaneWireEffectUnconfirmed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneWireRefusal
  = RecoveryPlaneWireRequestTooLarge
  | RecoveryPlaneWireRequestInvalid
  | RecoveryPlaneWireRequestUnsupportedVersion
  | RecoveryPlaneWireRequestNonCanonical
  | RecoveryPlaneWireIdentityInvalid !Text
  | RecoveryPlaneWireRunMissing
  | RecoveryPlaneWireDescriptorMissing
  | RecoveryPlaneWireDescriptorCorrupt !Text
  | RecoveryPlaneWireDescriptorUnbounded !Int !Int
  | RecoveryPlaneWireBindingMismatch !Text
  | RecoveryPlaneWirePhaseMismatch !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneWireUnavailable
  = RecoveryPlaneWireRunUnobservable !Text
  | RecoveryPlaneWireDescriptorUnobservable !Text
  | RecoveryPlaneWireExecutionUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data RecoveryPlaneWireResponse
  = RecoveryPlaneWireCompleted
      !Word16
      !ByteString
      !RecoveryPlaneWireOutcome
  | RecoveryPlaneWireRefused
      !Word16
      !ByteString
      !RecoveryPlaneWireRefusal
  | RecoveryPlaneWireUnavailableResponse
      !Word16
      !ByteString
      !RecoveryPlaneWireUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype RecoveryPlaneEndpointHandler m
  = RecoveryPlaneEndpointHandler
      ( ValidRecoveryPlaneRequest
        -> ByteString
        -> m RecoveryPlaneWireResponse
      )

data ValidRecoveryPlaneRequest = ValidRecoveryPlaneRequest
  { validRecoveryPlanePhase :: !RecoveryPlaneWirePhase
  , validRecoveryPlaneRunId :: !CleanupRunId
  , validRecoveryPlaneOperationId :: !CleanupOperationId
  , validRecoveryPlaneAttemptId :: !CleanupAttemptId
  }

newtype RecoveryPlaneEndpointResult
  = RecoveryPlaneEndpointResult RecoveryPlaneWireResponse
  deriving stock (Eq, Show)

recoveryPlaneEndpointFormatVersion :: Word16
recoveryPlaneEndpointFormatVersion = 1

recoveryPlaneEndpointMaximumBytes :: Int
recoveryPlaneEndpointMaximumBytes = 64 * 1024

recoveryPlaneEndpointResponseMaximumBytes :: Int
recoveryPlaneEndpointResponseMaximumBytes = 64 * 1024

-- | Hidden Authority factory.  The provider is never exported through the
-- public endpoint facade, and the resulting handler accepts no raw component
-- observations.  Each call independently reloads the run and descriptor.
lifecycleAuthorityRecoveryPlaneEndpointHandlerInternal
  :: (Monad m)
  => RecoveryPlaneInterpreter m
  -> CleanupRunRepositoryProvider m revision
  -> RecoveryPlaneEndpointHandler m
lifecycleAuthorityRecoveryPlaneEndpointHandlerInternal interpreter provider =
  RecoveryPlaneEndpointHandler $ \request requestDigest -> do
    observed <-
      observeDescriptorBoundCleanupRunFromAuthority
        provider
        (validRecoveryPlaneRunId request)
    case observed of
      Left err -> pure (clientErrorResponse requestDigest err)
      Right bound -> executeBound requestDigest request bound
 where
  executeBound requestDigest request bound
    | descriptorBoundCleanupRunId bound /= validRecoveryPlaneRunId request =
        pure
          ( refused
              requestDigest
              (RecoveryPlaneWireBindingMismatch "reloaded cleanup run id differs")
          )
    | otherwise = case plansForOperation bound (validRecoveryPlaneOperationId request) of
        [] ->
          pure
            ( refused
                requestDigest
                (RecoveryPlaneWireBindingMismatch "operation is not in the committed graph")
            )
        _first : _second : _ ->
          pure
            ( refused
                requestDigest
                (RecoveryPlaneWireBindingMismatch "operation is duplicated in the committed graph")
            )
        plan : _ -> case Map.lookup
          (cleanupNodeId plan)
          (descriptorBoundCleanupRunNodeStates bound) of
          Just (CleanupNodeRunning actualAttempt)
            | actualAttempt == validRecoveryPlaneAttemptId request ->
                case descriptorBoundCleanupNodeExecutionContext bound plan of
                  Left detail ->
                    pure
                      ( refused
                          requestDigest
                          (RecoveryPlaneWireBindingMismatch (bounded detail))
                      )
                  Right context -> do
                    executed <-
                      executeRecoveryPlaneDescriptorBoundPhase
                        interpreter
                        (phaseToInterpreter (validRecoveryPlanePhase request))
                        bound
                        context
                        plan
                    pure $ case executed of
                      Left err ->
                        refused
                          requestDigest
                          (RecoveryPlaneWirePhaseMismatch (render err))
                      Right outcome ->
                        RecoveryPlaneWireCompleted
                          recoveryPlaneEndpointFormatVersion
                          requestDigest
                          (outcomeToWire outcome)
          _ ->
            pure
              ( refused
                  requestDigest
                  (RecoveryPlaneWireBindingMismatch "operation is not running under the exact attempt")
              )

  plansForOperation bound operationId =
    filter
      ((== operationId) . cleanupNodeOperationId)
      (cleanupGraphNodes (descriptorBoundCleanupRunGraph bound))

serveRecoveryPlaneEndpointRequest
  :: (Monad m)
  => RecoveryPlaneEndpointHandler m
  -> LazyByteString.ByteString
  -> m RecoveryPlaneEndpointResult
serveRecoveryPlaneEndpointRequest (RecoveryPlaneEndpointHandler handle) requestBytes = do
  let strictBytes = LazyByteString.toStrict requestBytes
      requestDigest = hexSha256 strictBytes
  case decodeControlPlaneRequest recoveryPlaneEndpointMaximumBytes requestBytes of
    Left err -> pure (RecoveryPlaneEndpointResult (codecRefusal requestDigest err))
    Right request -> case validateRequest request of
      Left refusal -> pure (RecoveryPlaneEndpointResult (refused requestDigest refusal))
      Right valid -> RecoveryPlaneEndpointResult <$> handle valid requestDigest

validateRequest
  :: RecoveryPlaneWireRequest
  -> Either RecoveryPlaneWireRefusal ValidRecoveryPlaneRequest
validateRequest request = do
  unless
    (recoveryPlaneWireRequestVersion request == recoveryPlaneEndpointFormatVersion)
    (Left RecoveryPlaneWireRequestUnsupportedVersion)
  runId <-
    first
      (RecoveryPlaneWireIdentityInvalid . bounded . Text.pack . show)
      (mkCleanupRunId (recoveryPlaneWireRequestRunId request))
  operationId <-
    first
      (RecoveryPlaneWireIdentityInvalid . bounded . Text.pack . show)
      (mkCleanupOperationId (recoveryPlaneWireRequestOperationId request))
  attemptId <-
    first
      (RecoveryPlaneWireIdentityInvalid . bounded . Text.pack . show)
      (mkCleanupAttemptId (recoveryPlaneWireRequestAttemptId request))
  pure
    ValidRecoveryPlaneRequest
      { validRecoveryPlanePhase = recoveryPlaneWireRequestPhase request
      , validRecoveryPlaneRunId = runId
      , validRecoveryPlaneOperationId = operationId
      , validRecoveryPlaneAttemptId = attemptId
      }

observeDescriptorBoundCleanupRunFromAuthority
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunId
  -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
observeDescriptorBoundCleanupRunFromAuthority provider expectedRunId = do
  observed <- callDescriptor (CleanupRunDescriptorObserve (cleanupRunIdText expectedRunId))
  case observed of
    Left err -> pure (Left err)
    Right (CleanupRunDescriptorPresent rawRunId rawDescriptorDigest runBytes) ->
      case decodeRun rawRunId rawDescriptorDigest runBytes of
        Left err -> pure (Left err)
        Right (runId, descriptorDigest, run)
          | runId /= expectedRunId ->
              pure
                ( Left
                    (CleanupRunClientDescriptorBindingMismatch "Authority read back the wrong run id")
                )
          | otherwise -> do
              descriptorResponse <-
                callDescriptor
                  (CleanupRunDescriptorReadBackProgram (cleanupRunIdText runId))
              pure $ do
                committed <-
                  confirmDescriptorResponse runId descriptorDigest descriptorResponse
                let bound = DescriptorBoundCleanupRun committed run
                _ <- withDescriptorBoundCleanupProgram bound (\_ _ _ -> ())
                Right bound
    Right response -> pure (descriptorResponseError response)
 where
  callDescriptor command = do
    result <-
      serveCleanupRunRequest
        provider
        (encodeControlPlaneRequest (CleanupRunDescriptorBound command))
    pure $ case result of
      CleanupRunEndpointDescriptorBound response -> Right response
      _ ->
        Left
          ( CleanupRunClientDescriptorResponseInvalid
              "Authority cleanup endpoint returned a legacy response"
          )

decodeRun
  :: Text
  -> Text
  -> ByteString
  -> Either CleanupRunClientError (CleanupRunId, CleanupDigest, CleanupRun)
decodeRun rawRunId rawDescriptorDigest runBytes = do
  runId <- first CleanupRunClientDescriptorResponseInvalid (mkCleanupRunId rawRunId)
  descriptorDigest <-
    first CleanupRunClientDescriptorResponseInvalid (mkCleanupDigest rawDescriptorDigest)
  run <-
    first
      CleanupRunClientResponseInvalid
      (decodeCleanupRun cleanupRunMaximumBytes runBytes)
  unless
    (cleanupRunId run == runId)
    ( Left
        (CleanupRunClientDescriptorBindingMismatch "Authority run id/body mismatch")
    )
  pure (runId, descriptorDigest, run)

confirmDescriptorResponse
  :: CleanupRunId
  -> CleanupDigest
  -> Either CleanupRunClientError CleanupRunDescriptorResponse
  -> Either CleanupRunClientError CommittedCleanupProgramDescriptor
confirmDescriptorResponse runId expectedDigest response = case response of
  Right
    (CleanupRunDescriptorProgramPresent rawRunId rawDescriptorDigest descriptorBytes) -> do
      observedRunId <-
        first CleanupRunClientDescriptorResponseInvalid (mkCleanupRunId rawRunId)
      observedDigest <-
        first CleanupRunClientDescriptorResponseInvalid (mkCleanupDigest rawDescriptorDigest)
      unless
        (observedRunId == runId)
        (Left (CleanupRunClientDescriptorBindingMismatch "descriptor run id differs"))
      unless
        (observedDigest == expectedDigest)
        (Left (CleanupRunClientDescriptorBindingMismatch "descriptor digest differs"))
      committed <-
        first
          CleanupRunClientDescriptorRepositoryFailed
          (confirmCommittedCleanupProgramDescriptorBytes runId descriptorBytes)
      unless
        (committedCleanupProgramDescriptorDigest committed == expectedDigest)
        (Left (CleanupRunClientDescriptorBindingMismatch "descriptor bytes digest differs"))
      pure committed
  Right other -> descriptorResponseError other
  Left err -> Left err

descriptorResponseError
  :: CleanupRunDescriptorResponse
  -> Either CleanupRunClientError value
descriptorResponseError response = case response of
  CleanupRunDescriptorRefused refusal ->
    Left (CleanupRunClientDescriptorRefused refusal)
  CleanupRunDescriptorNotFound -> Left CleanupRunClientDescriptorMissing
  CleanupRunDescriptorTombstoned rawDescriptorDigest rawReportDigest -> do
    descriptorDigest <-
      first CleanupRunClientDescriptorResponseInvalid (mkCleanupDigest rawDescriptorDigest)
    reportDigest <-
      first CleanupRunClientDescriptorResponseInvalid (mkCleanupDigest rawReportDigest)
    Left (CleanupRunClientDescriptorTombstoned descriptorDigest reportDigest)
  _ ->
    Left
      ( CleanupRunClientDescriptorResponseInvalid
          "unexpected descriptor-bound Authority response"
      )

-- | Shared package-private Authority reload used by commit/read-back endpoint
-- handlers.  It never crosses the public endpoint facade.
loadDescriptorBoundCleanupRunForAuthorityInternal
  :: (Monad m)
  => CleanupRunRepositoryProvider m revision
  -> CleanupRunId
  -> m (Either CleanupRunClientError DescriptorBoundCleanupRun)
loadDescriptorBoundCleanupRunForAuthorityInternal =
  observeDescriptorBoundCleanupRunFromAuthority

clientErrorResponse :: ByteString -> CleanupRunClientError -> RecoveryPlaneWireResponse
clientErrorResponse requestDigest err = case err of
  CleanupRunClientDescriptorMissing ->
    refused requestDigest RecoveryPlaneWireRunMissing
  CleanupRunClientDescriptorRefused refusal -> case refusal of
    CleanupRunDescriptorMissing ->
      refused requestDigest RecoveryPlaneWireDescriptorMissing
    CleanupRunDescriptorCorrupt detail ->
      refused requestDigest (RecoveryPlaneWireDescriptorCorrupt (bounded detail))
    CleanupRunDescriptorUnbounded actual maximumBytes ->
      refused
        requestDigest
        (RecoveryPlaneWireDescriptorUnbounded actual maximumBytes)
    CleanupRunDescriptorUnobservable detail ->
      unavailable requestDigest (RecoveryPlaneWireDescriptorUnobservable (bounded detail))
    CleanupRunDescriptorUnavailable detail ->
      unavailable requestDigest (RecoveryPlaneWireRunUnobservable (bounded detail))
    _ -> refused requestDigest (RecoveryPlaneWireBindingMismatch (render refusal))
  CleanupRunClientTransportFailed detail ->
    unavailable requestDigest (RecoveryPlaneWireRunUnobservable (render detail))
  CleanupRunClientHttpStatus _ detail ->
    unavailable requestDigest (RecoveryPlaneWireRunUnobservable (bounded detail))
  CleanupRunClientDescriptorRepositoryFailed detail ->
    refused requestDigest (RecoveryPlaneWireDescriptorCorrupt (render detail))
  _ -> refused requestDigest (RecoveryPlaneWireBindingMismatch (render err))

phaseToInterpreter :: RecoveryPlaneWirePhase -> RecoveryPlaneReadBackPhase
phaseToInterpreter phase = case phase of
  RecoveryPlaneWireInitialReadBack -> RecoveryPlaneInitialReadBackPhase
  RecoveryPlaneWireFinalDisposition -> RecoveryPlaneFinalDispositionPhase

outcomeToWire :: CleanupNodeOutcome -> RecoveryPlaneWireOutcome
outcomeToWire outcome = case outcome of
  CleanupNodeSucceeded -> RecoveryPlaneWireSucceeded
  CleanupNodeFailed detail -> RecoveryPlaneWireFailed (bounded detail)
  CleanupNodeEffectUnconfirmed detail ->
    RecoveryPlaneWireEffectUnconfirmed (bounded detail)

outcomeFromWire :: RecoveryPlaneWireOutcome -> CleanupNodeOutcome
outcomeFromWire outcome = case outcome of
  RecoveryPlaneWireSucceeded -> CleanupNodeSucceeded
  RecoveryPlaneWireFailed detail -> CleanupNodeFailed (bounded detail)
  RecoveryPlaneWireEffectUnconfirmed detail ->
    CleanupNodeEffectUnconfirmed (bounded detail)

codecRefusal
  :: ByteString
  -> ControlPlaneRequestCodecError
  -> RecoveryPlaneWireResponse
codecRefusal requestDigest err =
  refused requestDigest $ case err of
    ControlPlaneRequestTooLarge -> RecoveryPlaneWireRequestTooLarge
    ControlPlaneRequestInvalid -> RecoveryPlaneWireRequestInvalid
    ControlPlaneRequestUnsupportedVersion -> RecoveryPlaneWireRequestUnsupportedVersion
    ControlPlaneRequestNonCanonical -> RecoveryPlaneWireRequestNonCanonical

refused :: ByteString -> RecoveryPlaneWireRefusal -> RecoveryPlaneWireResponse
refused requestDigest refusal =
  RecoveryPlaneWireRefused
    recoveryPlaneEndpointFormatVersion
    requestDigest
    refusal

unavailable
  :: ByteString
  -> RecoveryPlaneWireUnavailable
  -> RecoveryPlaneWireResponse
unavailable requestDigest reason =
  RecoveryPlaneWireUnavailableResponse
    recoveryPlaneEndpointFormatVersion
    requestDigest
    reason

recoveryPlaneEndpointStatus :: RecoveryPlaneEndpointResult -> ReplyStatus
recoveryPlaneEndpointStatus (RecoveryPlaneEndpointResult response) =
  recoveryPlaneWireResponseStatus response

recoveryPlaneWireResponseStatus :: RecoveryPlaneWireResponse -> ReplyStatus
recoveryPlaneWireResponseStatus response = case response of
  RecoveryPlaneWireCompleted {} -> ReplyOk
  RecoveryPlaneWireUnavailableResponse {} -> ReplyServiceUnavailable
  RecoveryPlaneWireRefused _ _ refusal -> case refusal of
    RecoveryPlaneWireRunMissing -> ReplyNotFound
    RecoveryPlaneWireDescriptorMissing -> ReplyNotFound
    RecoveryPlaneWireDescriptorCorrupt {} -> ReplyConflict
    RecoveryPlaneWireDescriptorUnbounded {} -> ReplyConflict
    RecoveryPlaneWireBindingMismatch {} -> ReplyConflict
    RecoveryPlaneWirePhaseMismatch {} -> ReplyConflict
    _ -> ReplyBadRequest

recoveryPlaneEndpointBody :: RecoveryPlaneEndpointResult -> ByteString
recoveryPlaneEndpointBody (RecoveryPlaneEndpointResult response) =
  LazyByteString.toStrict (encodeControlPlaneResponse response)

decodeRecoveryPlaneEndpointResponse
  :: ByteString
  -> Either ControlPlaneResponseCodecError RecoveryPlaneWireResponse
decodeRecoveryPlaneEndpointResponse =
  decodeControlPlaneResponse recoveryPlaneEndpointResponseMaximumBytes
    . LazyByteString.fromStrict

data RecoveryPlaneEndpointResponseError
  = RecoveryPlaneEndpointResponseVersionMismatch !Word16 !Word16
  | RecoveryPlaneEndpointResponseRequestMismatch !ByteString !ByteString
  | RecoveryPlaneEndpointResponseRefused !RecoveryPlaneWireRefusal
  | RecoveryPlaneEndpointResponseUnavailable !RecoveryPlaneWireUnavailable
  deriving stock (Eq, Show)

confirmRecoveryPlaneResponse
  :: RecoveryPlaneWireRequest
  -> RecoveryPlaneWireResponse
  -> Either RecoveryPlaneEndpointResponseError CleanupNodeOutcome
confirmRecoveryPlaneResponse request response = do
  let expectedDigest =
        hexSha256
          (LazyByteString.toStrict (encodeControlPlaneRequest request))
      confirmBinding version actualDigest = do
        unless
          (version == recoveryPlaneEndpointFormatVersion)
          ( Left
              ( RecoveryPlaneEndpointResponseVersionMismatch
                  recoveryPlaneEndpointFormatVersion
                  version
              )
          )
        unless
          (actualDigest == expectedDigest)
          ( Left
              ( RecoveryPlaneEndpointResponseRequestMismatch
                  expectedDigest
                  actualDigest
              )
          )
  case response of
    RecoveryPlaneWireCompleted version actualDigest outcome -> do
      confirmBinding version actualDigest
      pure (outcomeFromWire outcome)
    RecoveryPlaneWireRefused version actualDigest refusal -> do
      confirmBinding version actualDigest
      Left (RecoveryPlaneEndpointResponseRefused refusal)
    RecoveryPlaneWireUnavailableResponse version actualDigest reason -> do
      confirmBinding version actualDigest
      Left (RecoveryPlaneEndpointResponseUnavailable reason)

data RecoveryPlaneEndpointRegression = RecoveryPlaneEndpointRegression
  { internalRecoveryPlaneEndpointValidExact :: !Bool
  , internalRecoveryPlaneEndpointMalformedNoExecution :: !Bool
  , internalRecoveryPlaneEndpointOversizeNoExecution :: !Bool
  , internalRecoveryPlaneEndpointInvalidIdentityNoExecution :: !Bool
  , internalRecoveryPlaneEndpointUnsupportedVersionNoExecution :: !Bool
  , internalRecoveryPlaneEndpointAllArmsValidateVersion :: !Bool
  , internalRecoveryPlaneEndpointAllArmsValidateRequestDigest :: !Bool
  }

fixedRecoveryPlaneEndpointRegression :: IO RecoveryPlaneEndpointRegression
fixedRecoveryPlaneEndpointRegression =
  case ( mkCleanupRunId "recovery-plane-endpoint-run"
       , mkCleanupOperationId "recovery-plane-readback-operation"
       , mkCleanupAttemptId "recovery-plane-readback-attempt"
       ) of
    (Right runId, Right operationId, Right attemptId) -> do
      executions <- newIORef (0 :: Int)
      let request =
            recoveryPlaneInitialReadBackWireRequest runId operationId attemptId
          requestBytes = encodeControlPlaneRequest request
          requestDigest = hexSha256 (LazyByteString.toStrict requestBytes)
          handler =
            RecoveryPlaneEndpointHandler $ \_ digest -> do
              modifyIORef' executions (+ 1)
              pure
                ( RecoveryPlaneWireCompleted
                    recoveryPlaneEndpointFormatVersion
                    digest
                    RecoveryPlaneWireSucceeded
                )
      validResult <- serveRecoveryPlaneEndpointRequest handler requestBytes
      validCount <- readIORef executions
      malformedResult <-
        serveRecoveryPlaneEndpointRequest handler (LazyByteString.singleton 0)
      malformedCount <- readIORef executions
      oversizeResult <-
        serveRecoveryPlaneEndpointRequest
          handler
          (LazyByteString.replicate (fromIntegral recoveryPlaneEndpointMaximumBytes + 1) 0)
      oversizeCount <- readIORef executions
      invalidIdentityResult <-
        serveRecoveryPlaneEndpointRequest
          handler
          ( encodeControlPlaneRequest
              request {recoveryPlaneWireRequestRunId = ""}
          )
      invalidIdentityCount <- readIORef executions
      unsupportedVersionResult <-
        serveRecoveryPlaneEndpointRequest
          handler
          ( encodeControlPlaneRequest
              request
                { recoveryPlaneWireRequestVersion =
                    recoveryPlaneEndpointFormatVersion + 1
                }
          )
      unsupportedVersionCount <- readIORef executions
      let wrongVersion = recoveryPlaneEndpointFormatVersion + 1
          wrongDigest = ByteString.replicate 32 0
          versionResponses =
            [ RecoveryPlaneWireCompleted
                wrongVersion
                requestDigest
                RecoveryPlaneWireSucceeded
            , RecoveryPlaneWireRefused
                wrongVersion
                requestDigest
                RecoveryPlaneWireRequestInvalid
            , RecoveryPlaneWireUnavailableResponse
                wrongVersion
                requestDigest
                (RecoveryPlaneWireExecutionUnavailable "unavailable")
            ]
          digestResponses =
            [ RecoveryPlaneWireCompleted
                recoveryPlaneEndpointFormatVersion
                wrongDigest
                RecoveryPlaneWireSucceeded
            , RecoveryPlaneWireRefused
                recoveryPlaneEndpointFormatVersion
                wrongDigest
                RecoveryPlaneWireRequestInvalid
            , RecoveryPlaneWireUnavailableResponse
                recoveryPlaneEndpointFormatVersion
                wrongDigest
                (RecoveryPlaneWireExecutionUnavailable "unavailable")
            ]
      pure
        RecoveryPlaneEndpointRegression
          { internalRecoveryPlaneEndpointValidExact =
              validCount == 1
                && endpointResponse validResult
                  == RecoveryPlaneWireCompleted
                    recoveryPlaneEndpointFormatVersion
                    requestDigest
                    RecoveryPlaneWireSucceeded
                && confirmRecoveryPlaneResponse request (endpointResponse validResult)
                  == Right CleanupNodeSucceeded
          , internalRecoveryPlaneEndpointMalformedNoExecution =
              malformedCount == 1
                && hasRefusal RecoveryPlaneWireRequestInvalid malformedResult
          , internalRecoveryPlaneEndpointOversizeNoExecution =
              oversizeCount == 1
                && hasRefusal RecoveryPlaneWireRequestTooLarge oversizeResult
          , internalRecoveryPlaneEndpointInvalidIdentityNoExecution =
              invalidIdentityCount == 1
                && hasIdentityRefusal invalidIdentityResult
          , internalRecoveryPlaneEndpointUnsupportedVersionNoExecution =
              unsupportedVersionCount == 1
                && hasRefusal
                  RecoveryPlaneWireRequestUnsupportedVersion
                  unsupportedVersionResult
          , internalRecoveryPlaneEndpointAllArmsValidateVersion =
              all (isVersionMismatch . confirmRecoveryPlaneResponse request) versionResponses
          , internalRecoveryPlaneEndpointAllArmsValidateRequestDigest =
              all (isRequestMismatch . confirmRecoveryPlaneResponse request) digestResponses
          }
    _ ->
      pure
        RecoveryPlaneEndpointRegression
          { internalRecoveryPlaneEndpointValidExact = False
          , internalRecoveryPlaneEndpointMalformedNoExecution = False
          , internalRecoveryPlaneEndpointOversizeNoExecution = False
          , internalRecoveryPlaneEndpointInvalidIdentityNoExecution = False
          , internalRecoveryPlaneEndpointUnsupportedVersionNoExecution = False
          , internalRecoveryPlaneEndpointAllArmsValidateVersion = False
          , internalRecoveryPlaneEndpointAllArmsValidateRequestDigest = False
          }
 where
  endpointResponse (RecoveryPlaneEndpointResult response) = response

  hasRefusal expected result = case endpointResponse result of
    RecoveryPlaneWireRefused _ _ actual -> actual == expected
    _ -> False

  hasIdentityRefusal result = case endpointResponse result of
    RecoveryPlaneWireRefused _ _ RecoveryPlaneWireIdentityInvalid {} -> True
    _ -> False

  isVersionMismatch result = case result of
    Left RecoveryPlaneEndpointResponseVersionMismatch {} -> True
    _ -> False

  isRequestMismatch result = case result of
    Left RecoveryPlaneEndpointResponseRequestMismatch {} -> True
    _ -> False

recoveryPlaneEndpointValidExact :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointValidExact = internalRecoveryPlaneEndpointValidExact

recoveryPlaneEndpointMalformedNoExecution
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointMalformedNoExecution =
  internalRecoveryPlaneEndpointMalformedNoExecution

recoveryPlaneEndpointOversizeNoExecution
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointOversizeNoExecution =
  internalRecoveryPlaneEndpointOversizeNoExecution

recoveryPlaneEndpointInvalidIdentityNoExecution
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointInvalidIdentityNoExecution =
  internalRecoveryPlaneEndpointInvalidIdentityNoExecution

recoveryPlaneEndpointUnsupportedVersionNoExecution
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointUnsupportedVersionNoExecution =
  internalRecoveryPlaneEndpointUnsupportedVersionNoExecution

recoveryPlaneEndpointAllArmsValidateVersion
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointAllArmsValidateVersion =
  internalRecoveryPlaneEndpointAllArmsValidateVersion

recoveryPlaneEndpointAllArmsValidateRequestDigest
  :: RecoveryPlaneEndpointRegression -> Bool
recoveryPlaneEndpointAllArmsValidateRequestDigest =
  internalRecoveryPlaneEndpointAllArmsValidateRequestDigest

render :: (Show value) => value -> Text
render = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024
