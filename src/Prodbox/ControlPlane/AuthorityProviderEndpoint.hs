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
  , ProviderDispatchLane (..)
  , ProviderDispatchResponse (..)
  , AuthorityProviderDispatchBoundary (..)
  , providerDispatchResponseMaximumBytes
  , providerDispatchFormatVersion
  , authorityProviderDispatchAuthenticatedHandler
  , AuthorityProviderClientError (..)
  , dispatchAuthorityProviderIntent
  , dispatchAuthorityProviderIntentWithOperation
  , dispatchAuthorityProviderIntentOwnedBy
  , admitAuthorityProviderIntentOwnedBy
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

-- | Sprint 7.36: whether one dispatch also executes what it admits.
--
-- Admission and execution were already two separate transitions over the
-- retained aggregate — 'Prodbox.Lifecycle.Authority.Admission.AuthorityProviderPending'
-- is a durable state, and
-- 'Prodbox.ControlPlane.AwsStackCreationBindingRepository.observeAuthorityAwsStackCreationOperation'
-- already reads a create out of it — but the route ran both in one call, so an
-- admitted operation id did not exist until its effect had already happened.
-- A caller that must bind durable state to the operation /before/ the effect
-- therefore could not: the registered-stack create lane had to commit the
-- lifecycle generation that names a stack's cycle after the stack existed, and
-- an Authority that became unreachable in between left a stack no later
-- cleanup run could address.
--
-- This lane exposes the boundary the aggregate already had.  It is deliberately
-- a closed two-arm choice rather than a flag: a caller states which of the two
-- lanes it is on, and the handler decides on the same closed value.
data ProviderDispatchLane
  = -- | Admit and execute in one call.  The lane every idempotent observation
    -- and reconcile uses, and the historical behaviour of this route.
    ProviderAdmitAndExecute
  | -- | Admit and stop.  The operation stays Pending and its 'OperationId' is
    -- returned; nothing is signed and nothing reaches the Provider Worker.
    -- Executing it later is a second call on the same submission key, which
    -- the admission ledger recognizes as the same operation.
    ProviderAdmitOnly
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderDispatchPayload = ProviderDispatchPayload
  { providerDispatchVersion :: !Word16
  , providerDispatchSubmissionKey :: !Text
  , providerDispatchIntent :: !ProviderIntent
  , providerDispatchCleanupOwner :: !ProviderOperationCleanupOwner
  -- ^ Sprint 4.85: the cleanup operation that authorized this submission, or
  -- an explicit statement that no cleanup run did.  The Authority retains it
  -- beside the intent, so a disposition can be attributed to the run that
  -- authorized it.
  , providerDispatchLane :: !ProviderDispatchLane
  -- ^ Sprint 7.36: whether this call also executes the operation it admits.
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
--
-- Sprint 7.36: bumped to @4@ when the payload began naming its
-- 'ProviderDispatchLane'.  A caller at version @3@ carries no lane, and the
-- only safe default for a missing one would be to execute — so the version
-- refusal is what keeps an older caller from silently executing an operation a
-- newer Authority would have admitted only.
providerDispatchFormatVersion :: Word16
providerDispatchFormatVersion = 4

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
  | -- | Sprint 7.36: the submission is admitted and Pending, and nothing has
    -- executed.  Appended last so every earlier constructor keeps its
    -- 'Serialise' index.
    ProviderDispatchAdmitted !OperationId
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
            -- Sprint 7.36: the admit-only lane stops here.  Nothing is signed,
            -- nothing reaches the Provider Worker, and the caller is handed the
            -- operation the aggregate now holds Pending.
            Right submission
              | ProviderAdmitOnly <- providerDispatchLane payload ->
                  pure $ case submissionOperation submission of
                    Nothing ->
                      ProviderDispatchUnavailable
                        "provider admission did not retain an operation"
                    Just operation -> ProviderDispatchAdmitted operation
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
  ProviderDispatchAdmitted _ -> ReplyOk
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

-- | The digest identifies /what/ was submitted, deliberately not /how/ this
-- call is running it.
--
-- Sprint 7.36: the lane is normalized out before hashing.  The two-step create
-- lane admits and then executes the same submission at the same key, and a
-- digest that varied with the lane would make the execute call a different
-- request from the admission it is executing — which the submission ledger
-- correctly refuses as a digest conflict.  Normalizing keeps the two calls one
-- submission, which is the property the lane exists to provide.
providerDispatchRequestDigest :: ProviderDispatchPayload -> RequestDigest
providerDispatchRequestDigest payload =
  RequestDigest
    ( TextEncoding.decodeUtf8
        ( hexSha256
            ( LazyByteString.toStrict
                (serialise (1 :: Word, payload {providerDispatchLane = digestNormalizedLane}))
            )
        )
    )

-- | The one lane every digest is taken at, whichever lane the call is on.
digestNormalizedLane :: ProviderDispatchLane
digestNormalizedLane = ProviderAdmitAndExecute

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
  decoded <-
    callProviderDispatchRoute
      transport
      submissionKey
      intent
      owner
      ProviderAdmitAndExecute
  pure $ do
    (status, response) <- decoded
    case response of
      ProviderDispatchCompleted operation evidence
        | status == 200 -> Right (operation, evidence)
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      ProviderDispatchAlreadyCompleted operation evidence
        | status == 200 -> Right (operation, evidence)
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      -- An execute lane that came back admitted-only means the Authority did
      -- not run what this caller asked it to run.  It is not evidence, so it
      -- cannot be returned as evidence.
      ProviderDispatchAdmitted _ ->
        Left
          ( AuthorityProviderRemoteRefused
              status
              "provider dispatch returned an admission to an execute lane"
          )
      ProviderDispatchRefused detail ->
        Left (AuthorityProviderRemoteRefused status detail)
      ProviderDispatchUnavailable detail ->
        Left (AuthorityProviderRemoteRefused status detail)

-- | Sprint 7.36: admit one Provider submission without executing it.
--
-- The returned 'OperationId' names an operation the Authority holds Pending, so
-- a caller can commit durable state against it before the effect happens and
-- execute it afterwards with 'dispatchAuthorityProviderIntentOwnedBy' on the
-- same submission key.
--
-- A replay whose operation has already completed answers with that same
-- operation rather than refusing: the admission ledger recognizes the retry as
-- the operation it already admitted, and refusing it would strand a lane that
-- lost a response.  The invariant the lane exists to hold is unaffected, because
-- the first attempt committed its own durable state before executing.
admitAuthorityProviderIntentOwnedBy
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> ProviderIntent
  -> ProviderOperationCleanupOwner
  -> IO (Either AuthorityProviderClientError OperationId)
admitAuthorityProviderIntentOwnedBy transport submissionKey intent owner = do
  decoded <-
    callProviderDispatchRoute
      transport
      submissionKey
      intent
      owner
      ProviderAdmitOnly
  pure $ do
    (status, response) <- decoded
    case response of
      ProviderDispatchAdmitted operation
        | status == 200 -> Right operation
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      ProviderDispatchAlreadyCompleted operation _
        | status == 200 -> Right operation
        | otherwise -> Left (AuthorityProviderResponseStatusMismatch status)
      -- The admit-only lane never executes, so a completion answer to it means
      -- the Authority did something this caller did not ask for.
      ProviderDispatchCompleted _ _ ->
        Left
          ( AuthorityProviderRemoteRefused
              status
              "provider dispatch executed an admit-only submission"
          )
      ProviderDispatchRefused detail ->
        Left (AuthorityProviderRemoteRefused status detail)
      ProviderDispatchUnavailable detail ->
        Left (AuthorityProviderRemoteRefused status detail)

callProviderDispatchRoute
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ClientSubmissionKey
  -> ProviderIntent
  -> ProviderOperationCleanupOwner
  -> ProviderDispatchLane
  -> IO (Either AuthorityProviderClientError (Int, ProviderDispatchResponse))
callProviderDispatchRoute transport submissionKey intent owner lane = do
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
                , providerDispatchLane = lane
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
    Right (status, decoded)
