{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-Authority-owned Provider dispatch.  The exact closed intent is
-- admitted into the retained aggregate before the Authority signs or sends it
-- to the Provider Worker; completion and bounded evidence are settled by a
-- second confirmed aggregate CAS.
module Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( ProviderDispatchPayload (..)
  , ProviderDispatchResponse (..)
  , AuthorityProviderDispatchBoundary (..)
  , providerDispatchResponseMaximumBytes
  , providerDispatchFormatVersion
  , authorityProviderDispatchAuthenticatedHandler
  , AuthorityProviderClientError (..)
  , dispatchAuthorityProviderIntent
  , dispatchAuthorityProviderIntentWithOperation
  , dispatchAuthorityProviderIntentOwnedBy
  )
where

import Codec.Serialise (Serialise, serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (fromLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  , registeredGenerationForSlot
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerTestHarness)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleProviderDispatchRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneRequest
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (AuthorityEpoch))
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderCommittedIntentSpec (..)
  , ProviderIntentExecutionResult (..)
  , encodeSignedProviderCommittedIntent
  , mkProviderIssuerKeyGeneration
  , mkUnsignedProviderCommittedIntent
  , signProviderCommittedIntentWith
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigningCapability
  , VerifiedCallerSlot
  , requestSigningCapabilityGeneration
  , signingKeyGenerationValue
  , verifiedCallerSlotPrincipal
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleProviderDispatch)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityProviderSettlementDecision (..)
  , AuthorityProviderSubmissionDecision (..)
  , ProviderOperationCleanupOwner (..)
  , stepRegisteredProviderSettlement
  , stepRegisteredProviderSubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , RegisteredClientGeneration
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Authority.Submission
  ( ClientSequence (ClientSequence)
  , OperationId (..)
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , addAuthorityDuration
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent
  , ProviderRevision
  )
import Prodbox.Lifecycle.TargetCommitIntent (sha256TargetValueDigest)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data ProviderDispatchPayload = ProviderDispatchPayload
  { providerDispatchVersion :: !Word16
  , providerDispatchSubmissionKey :: !Text
  , providerDispatchIntent :: !ProviderIntent
  , providerDispatchCleanupOwner :: !ProviderOperationCleanupOwner
  -- ^ Sprint 4.85: the cleanup operation that authorized this submission, or
  -- an explicit statement that no cleanup run did.  The Authority retains it
  -- beside the intent, so a disposition can be attributed to the run that
  -- authorized it.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Sprint 4.84: bumped to @2@ when the settled response began naming the
-- admitted 'OperationId'.
--
-- The route previously carried no version at all, so a change to either side of
-- its wire shape would have been decided by a decode failure rather than by a
-- refusal that says what happened. A caller at another version is refused
-- explicitly, in the same idiom as
-- 'Prodbox.ControlPlane.AwsStackCreationBindingEndpoint.awsStackCreationEndpointFormatVersion'.
--
-- Sprint 4.85: bumped to @3@ when the payload began naming the cleanup
-- operation that authorized the submission.
providerDispatchFormatVersion :: Word16
providerDispatchFormatVersion = 3

-- | Sprint 4.84: a settled dispatch names the operation the Authority admitted.
--
-- The identity was already in hand at both settlement sites and was discarded
-- at both — the duplicate-completed arm literally pattern-matched it to @_@ —
-- so a caller could prove it had submitted an intent but could not name the
-- operation that carried it. That is the whole reason no production submitter
-- could reach the generation-committing route: 'OperationId' is
-- @(epoch, client, sequence, digest)@, and the epoch and sequence are assigned
-- at admission, so a caller cannot derive one. It has to be told.
data ProviderDispatchResponse
  = ProviderDispatchCompleted !OperationId !Text
  | ProviderDispatchAlreadyCompleted !OperationId !Text
  | ProviderDispatchRefused !Text
  | ProviderDispatchUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityProviderDispatchBoundary m revision = AuthorityProviderDispatchBoundary
  { authorityProviderAdmissionRepository :: !(AuthorityAdmissionRepository m revision)
  , authorityProviderSigningCapability :: !(RequestSigningCapability m)
  , authorityProviderNow :: m (Either Text AuthorityTime)
  , authorityProviderIntentLifetime :: !AuthorityDuration
  , authorityProviderRevision :: m (Either Text ProviderRevision)
  , authorityProviderWorkerDispatch
      :: ByteString
      -> m (Either Text ProviderIntentExecutionResult)
  }

providerDispatchResponseMaximumBytes :: Int
providerDispatchResponseMaximumBytes = 64 * 1024

authorityProviderDispatchAuthenticatedHandler
  :: (Monad m)
  => Int
  -> AuthorityProviderDispatchBoundary m revision
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
authorityProviderDispatchAuthenticatedHandler maximumBytes boundary fallback =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness fallback
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleProviderDispatch
      | callerAllowed (verifiedCallerSlotPrincipal caller) ->
          Just <$> serve caller body
      | otherwise ->
          pure (Just (ReplyForbidden, responseBody (ProviderDispatchRefused "caller-refused")))
    _ -> authenticatedHandlerHandle fallback caller route body

  callerAllowed principal = case principal of
    CallerOperatorCli -> True
    CallerTestHarness -> True
    _ -> False

  serve caller body =
    case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
      Left err ->
        pure
          ( ReplyBadRequest
          , responseBody (ProviderDispatchRefused (Text.pack (show err)))
          )
      Right payload -> do
        response <- runProviderDispatch boundary caller payload
        pure (providerResponseStatus response, responseBody response)

  responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

runProviderDispatch
  :: (Monad m)
  => AuthorityProviderDispatchBoundary m revision
  -> VerifiedCallerSlot
  -> ProviderDispatchPayload
  -> m ProviderDispatchResponse
runProviderDispatch _boundary _caller payload
  | providerDispatchVersion payload /= providerDispatchFormatVersion =
      pure
        ( ProviderDispatchRefused
            ( "provider dispatch format version "
                <> Text.pack (show (providerDispatchVersion payload))
                <> " is not supported; this Authority serves version "
                <> Text.pack (show providerDispatchFormatVersion)
            )
        )
runProviderDispatch boundary caller payload =
  case mkClientSubmissionKey (providerDispatchSubmissionKey payload) of
    Left err -> pure (ProviderDispatchRefused (Text.pack (show err)))
    Right submissionKey ->
      case registeredGenerationForSlot caller of
        Left detail -> pure (ProviderDispatchRefused detail)
        Right generation -> do
          admitted <- admitProviderOperation boundary caller generation submissionKey payload
          case admitted of
            Left detail -> pure (ProviderDispatchUnavailable detail)
            Right (AuthorityProviderSubmissionRefused refusal) ->
              pure (ProviderDispatchRefused (Text.pack (show refusal)))
            -- The operation was already in hand here and was discarded; a
            -- replay names the same operation the first attempt admitted,
            -- which is exactly what makes the submitting lane idempotent.
            Right (AuthorityProviderSubmissionDuplicateCompleted operation evidence) ->
              pure (ProviderDispatchAlreadyCompleted operation evidence)
            Right submission -> do
              nowResult <- authorityProviderNow boundary
              revisionResult <- authorityProviderRevision boundary
              case (nowResult, revisionResult, submissionOperation submission) of
                (Left detail, _, _) -> pure (ProviderDispatchUnavailable detail)
                (_, Left detail, _) -> pure (ProviderDispatchUnavailable detail)
                (_, _, Nothing) ->
                  pure (ProviderDispatchUnavailable "provider admission did not retain an operation")
                (Right now, Right revision, Just operation) -> do
                  signed <- buildSignedIntent boundary now revision operation submissionKey payload
                  case signed of
                    Left detail -> pure (ProviderDispatchRefused detail)
                    Right bytes -> do
                      executed <- authorityProviderWorkerDispatch boundary bytes
                      case executed of
                        Left detail -> pure (ProviderDispatchUnavailable detail)
                        Right result -> do
                          let evidence = providerExecutionEvidence result
                          settled <-
                            settleProviderOperation
                              boundary
                              caller
                              generation
                              operation
                              (providerDispatchIntent payload)
                              evidence
                          pure $ case settled of
                            Left detail -> ProviderDispatchUnavailable detail
                            Right AuthorityProviderSettlementCompleted ->
                              ProviderDispatchCompleted operation evidence
                            Right (AuthorityProviderSettlementAlreadyCompleted retained) ->
                              ProviderDispatchAlreadyCompleted operation retained
                            Right (AuthorityProviderSettlementRefused detail) ->
                              ProviderDispatchRefused detail

providerResponseStatus :: ProviderDispatchResponse -> ReplyStatus
providerResponseStatus response = case response of
  ProviderDispatchCompleted _ _ -> ReplyOk
  ProviderDispatchAlreadyCompleted _ _ -> ReplyOk
  ProviderDispatchRefused _ -> ReplyConflict
  ProviderDispatchUnavailable _ -> ReplyServiceUnavailable

submissionOperation :: AuthorityProviderSubmissionDecision -> Maybe OperationId
submissionOperation decision = case decision of
  AuthorityProviderSubmissionAccepted operation -> Just operation
  AuthorityProviderSubmissionDuplicatePending operation -> Just operation
  AuthorityProviderSubmissionDuplicateCompleted operation _ -> Just operation
  AuthorityProviderSubmissionRefused _ -> Nothing

admitProviderOperation
  :: (Monad m)
  => AuthorityProviderDispatchBoundary m revision
  -> VerifiedCallerSlot
  -> RegisteredClientGeneration
  -> ClientSubmissionKey
  -> ProviderDispatchPayload
  -> m (Either Text AuthorityProviderSubmissionDecision)
admitProviderOperation boundary caller generation submissionKey payload = do
  observed <- readAuthorityAdmission repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot ->
      case transition (authorityAdmissionSnapshotState snapshot) of
        Left err -> pure (Left (Text.pack (show err)))
        Right (decision, next)
          | next == authorityAdmissionSnapshotState snapshot -> pure (Right decision)
          | otherwise -> do
              attempted <-
                compareAndSwapAuthorityAdmission
                  repository
                  (authorityAdmissionRevision snapshot)
                  next
              confirmed <- readAuthorityAdmission repository
              pure $ case confirmed of
                Left detail -> Left detail
                Right readback ->
                  case transition (authorityAdmissionSnapshotState readback) of
                    Right (duplicate, _)
                      | confirmsProviderAdmission decision duplicate -> Right decision
                    _ -> Left (fromLeft "provider admission CAS was not confirmed" attempted)
 where
  repository = authorityProviderAdmissionRepository boundary
  digest = providerDispatchRequestDigest payload
  transition aggregate =
    stepRegisteredProviderSubmission
      aggregate
      (verifiedCallerSlotPrincipal caller)
      generation
      submissionKey
      digest
      (providerDispatchIntent payload)
      (providerDispatchCleanupOwner payload)

confirmsProviderAdmission
  :: AuthorityProviderSubmissionDecision
  -> AuthorityProviderSubmissionDecision
  -> Bool
confirmsProviderAdmission original confirmed =
  submissionOperation original == submissionOperation confirmed
    && case confirmed of
      AuthorityProviderSubmissionDuplicatePending _ -> True
      AuthorityProviderSubmissionDuplicateCompleted _ _ -> True
      _ -> False

settleProviderOperation
  :: (Monad m)
  => AuthorityProviderDispatchBoundary m revision
  -> VerifiedCallerSlot
  -> RegisteredClientGeneration
  -> OperationId
  -> ProviderIntent
  -> Text
  -> m (Either Text AuthorityProviderSettlementDecision)
settleProviderOperation boundary caller generation operation intent evidence = do
  observed <- readAuthorityAdmission repository
  case observed of
    Left detail -> pure (Left detail)
    Right snapshot ->
      case transition (authorityAdmissionSnapshotState snapshot) of
        Left err -> pure (Left (Text.pack (show err)))
        Right (decision, next)
          | next == authorityAdmissionSnapshotState snapshot -> pure (Right decision)
          | otherwise -> do
              attempted <-
                compareAndSwapAuthorityAdmission
                  repository
                  (authorityAdmissionRevision snapshot)
                  next
              confirmed <- readAuthorityAdmission repository
              pure $ case confirmed of
                Left detail -> Left detail
                Right readback -> case transition (authorityAdmissionSnapshotState readback) of
                  Right (AuthorityProviderSettlementAlreadyCompleted retained, _)
                    | retained == evidence -> Right decision
                  _ -> Left (fromLeft "provider settlement CAS was not confirmed" attempted)
 where
  repository = authorityProviderAdmissionRepository boundary
  transition =
    stepRegisteredProviderSettlement
      (verifiedCallerSlotPrincipal caller)
      generation
      operation
      intent
      evidence

buildSignedIntent
  :: (Monad m)
  => AuthorityProviderDispatchBoundary m revision
  -> AuthorityTime
  -> ProviderRevision
  -> OperationId
  -> ClientSubmissionKey
  -> ProviderDispatchPayload
  -> m (Either Text ByteString)
buildSignedIntent boundary now revision operation submissionKey payload =
  case buildUnsigned of
    Left err -> pure (Left err)
    Right unsigned -> do
      signed <- signProviderCommittedIntentWith signer unsigned
      pure (first (Text.pack . show) (encodeSignedProviderCommittedIntent <$> signed))
 where
  signer = authorityProviderSigningCapability boundary
  operationBytes = LazyByteString.toStrict (serialise operation)
  operationDigest = TextEncoding.decodeUtf8 (hexSha256 operationBytes)
  issuerGeneration =
    mkProviderIssuerKeyGeneration
      (signingKeyGenerationValue (requestSigningCapabilityGeneration signer))
  fence = case operationIdSequence operation of
    ClientSequence sequenceNumber -> mkFencingToken sequenceNumber
  buildUnsigned = do
    generation <- first (Text.pack . show) issuerGeneration
    owner <- first (Text.pack . show) (mkOwnerNonce operationDigest)
    fencing <- first (Text.pack . show) fence
    first (Text.pack . show) $
      mkUnsignedProviderCommittedIntent
        ProviderCommittedIntentSpec
          { providerIntentIssuerGeneration = generation
          , providerIntentIssuerIdentity = "lifecycle-authority"
          , providerIntentAuthorityEpoch =
              AuthorityEpoch (Genesis.authorityEpochValue (operationIdEpoch operation))
          , providerIntentOperationId = operationDigest
          , providerIntentActionIndex = 0
          , providerIntentCommitReceiptDigest = sha256TargetValueDigest operationBytes
          , providerIntentOwnerNonce = owner
          , providerIntentFencingToken = fencing
          , providerIntentRevision = revision
          , providerIntentAction = providerDispatchIntent payload
          , providerIntentDeadline = addAuthorityDuration now (authorityProviderIntentLifetime boundary)
          , providerIntentIdempotencyKey = clientSubmissionKeyText submissionKey
          , providerIntentExpectedCredentialSession = Nothing
          , providerIntentExpectedAcceptedAuthority = Nothing
          }

providerDispatchRequestDigest :: ProviderDispatchPayload -> RequestDigest
providerDispatchRequestDigest payload =
  RequestDigest
    ( TextEncoding.decodeUtf8
        ( hexSha256
            ( LazyByteString.toStrict
                (serialise (1 :: Word, payload))
            )
        )
    )

providerExecutionEvidence :: ProviderIntentExecutionResult -> Text
providerExecutionEvidence result = case result of
  ProviderIntentExecutionApplied _ evidence -> evidence
  ProviderIntentExecutionAlreadySatisfied _ evidence -> evidence
  ProviderIntentExecutionObserved _ evidence -> evidence

data AuthorityProviderClientError
  = AuthorityProviderTransportFailed !AuthenticatedClientError
  | AuthorityProviderResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityProviderResponseStatusMismatch !Int
  | AuthorityProviderRemoteRefused !Int !Text
  deriving stock (Eq, Show)

-- | Dispatch and keep only the bounded evidence.
--
-- Retained for the many callers that narrate a receipt and decide nothing from
-- the operation; 'dispatchAuthorityProviderIntentWithOperation' is the form a
-- caller uses when it must later name what it submitted.
dispatchAuthorityProviderIntent
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> ProviderIntent
  -> IO (Either AuthorityProviderClientError Text)
dispatchAuthorityProviderIntent transport submissionKey intent =
  fmap snd
    <$> dispatchAuthorityProviderIntentWithOperation transport submissionKey intent

dispatchAuthorityProviderIntentWithOperation
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> ProviderIntent
  -> IO (Either AuthorityProviderClientError (OperationId, Text))
dispatchAuthorityProviderIntentWithOperation transport submissionKey intent =
  dispatchAuthorityProviderIntentOwnedBy
    transport
    submissionKey
    intent
    ProviderOperationUnownedByCleanupRun

-- | Sprint 4.85: dispatch and name the cleanup operation that authorized it.
--
-- The two forms above remain for desired-present provisioning work, which no
-- cleanup run authorizes; they state that explicitly rather than leaving the
-- Authority to infer it.
dispatchAuthorityProviderIntentOwnedBy
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> ProviderIntent
  -> ProviderOperationCleanupOwner
  -> IO (Either AuthorityProviderClientError (OperationId, Text))
dispatchAuthorityProviderIntentOwnedBy transport submissionKey intent owner = do
  response <-
    callAuthenticatedClientTransport
      transport
      LifecycleProviderDispatchRoute
      ( LazyByteString.toStrict
          ( encodeControlPlaneRequest
              ProviderDispatchPayload
                { providerDispatchVersion = providerDispatchFormatVersion
                , providerDispatchSubmissionKey = clientSubmissionKeyText submissionKey
                , providerDispatchIntent = intent
                , providerDispatchCleanupOwner = owner
                }
          )
      )
  pure $ do
    ControlPlaneResponse status bytes <- first AuthorityProviderTransportFailed response
    decoded <-
      first
        AuthorityProviderResponseInvalid
        ( decodeControlPlaneResponse
            providerDispatchResponseMaximumBytes
            (LazyByteString.fromStrict bytes)
        )
    case decoded of
      ProviderDispatchCompleted operation evidence
        | status == 200 -> Right (operation, evidence)
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      ProviderDispatchAlreadyCompleted operation evidence
        | status == 200 -> Right (operation, evidence)
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      ProviderDispatchRefused detail ->
        Left (AuthorityProviderRemoteRefused status detail)
      ProviderDispatchUnavailable detail ->
        Left (AuthorityProviderRemoteRefused status detail)
