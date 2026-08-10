{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority config observe/propose-CAS protocol.
-- Config bytes are bounded and canonicalized before any store access.  Blob
-- replication precedes promotion into the one admission aggregate, and every
-- CAS is confirmed by aggregate and blob read-back.
module Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigProjectionScope (..)
  , ConfigObserveRequest (..)
  , ConfigProposeCasRequest (..)
  , ConfigProjection (..)
  , ConfigObservation (..)
  , ConfigProposeCasResponse (..)
  , ConfigEndpointResult (..)
  , ConfigPayloadCompiler (..)
  , ConfigBlobObservation (..)
  , ConfigBlobStore (..)
  , ConfigAuthorityRepository (..)
  , configPayloadMaximumBytes
  , configEndpointResponseMaximumBytes
  , configProjectionScopeForCaller
  , aggregateConfigAuthorityRepository
  , serveConfigObserveRequest
  , serveConfigProposeCasRequest
  , configEndpointHttpStatus
  , configEndpointResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (..))
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedCallerSlot
  , verifiedCallerSlotPrincipal
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityConfigProposalDecision (..)
  , AuthoritySubmissionGateRefusal
  , authorityAggregateConfig
  , decideAuthorityConfigProposal
  , stepAuthorityConfigProposal
  )
import Prodbox.Lifecycle.Authority.Config
  ( ConfigDigest (..)
  , ConfigGeneration
  , ConfigProposal (..)
  , ConfigProposeDecision (..)
  , ConfigProposeRefusal
  , ConfigReference (..)
  , ConfigSchemaVersion (..)
  , ConfigState (..)
  , InForceConfig (..)
  , SchemaValidity (..)
  )
import Prodbox.Runtime.Role (RuntimeRole (..))

-- | A caller may request exactly its own compiled projection.  Keeping this
-- closed avoids a free-form role name becoming an authorization bypass.
data ConfigProjectionScope
  = ConfigProjectionBootstrapBroker
  | ConfigProjectionGatewayRuntime
  | ConfigProjectionLifecycleAuthority
  | ConfigProjectionProviderWorker
  | ConfigProjectionAuthorityBackup
  | ConfigProjectionTlsRetention
  | ConfigProjectionTargetSecretAgent
  | ConfigProjectionOperator
  | ConfigProjectionTestHarness
  | ConfigProjectionAdminActionRunner
  | ConfigProjectionCredentialProvisioner
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

newtype ConfigObserveRequest = ConfigObserveRequest
  { configObserveRequestedScope :: ConfigProjectionScope
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ConfigProposeCasRequest = ConfigProposeCasRequest
  { configProposeExpectedGeneration :: !(Maybe ConfigGeneration)
  , configProposeSchema :: !ConfigSchemaVersion
  , configProposeCanonicalBytes :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ConfigProjection = ConfigProjection
  { configProjectionIdentity :: !InForceConfig
  , configProjectionScope :: !ConfigProjectionScope
  , configProjectionBytes :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ConfigObservation
  = ConfigObservationMissing
  | ConfigObservationObserved !ConfigProjection
  | ConfigObservationCorrupt !Text
  | ConfigObservationUnobservable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ConfigProposeCasResponse
  = ConfigProposalSeeded !InForceConfig
  | ConfigProposalAdvanced !InForceConfig
  | ConfigProposalAlreadyCurrent !InForceConfig
  | ConfigProposalRefusedByGate !AuthoritySubmissionGateRefusal
  | ConfigProposalRefused !ConfigProposeRefusal
  | ConfigProposalInvalid !Text
  | ConfigProposalConflict !ConfigObservation
  | ConfigProposalUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ConfigEndpointResult response
  = ConfigEndpointRespond !response
  | ConfigEndpointBadRequest !ControlPlaneRequestCodecError
  | ConfigEndpointForbidden
  deriving stock (Eq, Show)

-- | Schema validation and role projection are injected so the protocol and
-- aggregate repository remain independent of Dhall and filesystem layout.
data ConfigPayloadCompiler m = ConfigPayloadCompiler
  { compileCanonicalConfig
      :: ByteString
      -> m (Either Text ByteString)
  , compileConfigProjection
      :: ConfigProjectionScope
      -> ByteString
      -> m (Either Text ByteString)
  }

data ConfigBlobObservation
  = ConfigBlobMissing
  | ConfigBlobCurrent !ByteString
  | ConfigBlobCorrupt !Text
  | ConfigBlobUnobservable !Text
  deriving stock (Eq, Show)

-- | A successful replication result is constructible only after primary and
-- independent backup copies of the exact ciphertext have been read back.
data ConfigBlobStore m = ConfigBlobStore
  { replicateConfigBlob
      :: ConfigDigest
      -> ByteString
      -> m (Either Text ConfigReference)
  , observeConfigBlob
      :: ConfigDigest
      -> ConfigReference
      -> m ConfigBlobObservation
  }

data ConfigAuthorityRepository m = ConfigAuthorityRepository
  { observeAuthorityConfig
      :: ConfigProjectionScope
      -> m ConfigObservation
  , proposeAuthorityConfig
      :: ConfigProposeCasRequest
      -> m ConfigProposeCasResponse
  }

configPayloadMaximumBytes :: Int
configPayloadMaximumBytes = 4 * 1024 * 1024

configEndpointResponseMaximumBytes :: Int
configEndpointResponseMaximumBytes = configPayloadMaximumBytes + 64 * 1024

configProjectionScopeForCaller :: CallerPrincipal -> ConfigProjectionScope
configProjectionScopeForCaller principal = case principal of
  CallerOperatorCli -> ConfigProjectionOperator
  CallerTestHarness -> ConfigProjectionTestHarness
  CallerAdminActionRunner -> ConfigProjectionAdminActionRunner
  CallerCredentialProvisioner -> ConfigProjectionCredentialProvisioner
  CallerService role -> case role of
    BootstrapBroker -> ConfigProjectionBootstrapBroker
    GatewayRuntime -> ConfigProjectionGatewayRuntime
    LifecycleAuthorityRuntime -> ConfigProjectionLifecycleAuthority
    ProviderWorkerRuntime -> ConfigProjectionProviderWorker
    AuthorityBackupRuntime -> ConfigProjectionAuthorityBackup
    TlsRetentionRuntime -> ConfigProjectionTlsRetention
    TargetSecretAgentRuntime -> ConfigProjectionTargetSecretAgent

aggregateConfigAuthorityRepository
  :: (Monad m)
  => AuthorityAdmissionRepository m revision
  -> ConfigBlobStore m
  -> ConfigPayloadCompiler m
  -> ConfigAuthorityRepository m
aggregateConfigAuthorityRepository authorityRepository blobStore compiler =
  ConfigAuthorityRepository
    { observeAuthorityConfig = observeCurrent
    , proposeAuthorityConfig = propose
    }
 where
  observeCurrent scope = do
    observed <- readAuthorityAdmission authorityRepository
    case observed of
      Left detail -> pure (ConfigObservationUnobservable detail)
      Right snapshot ->
        observeAggregate scope (authorityAdmissionSnapshotState snapshot)

  observeAggregate scope aggregate =
    case authorityAggregateConfig aggregate of
      ConfigUnseeded -> pure ConfigObservationMissing
      ConfigInForce current -> do
        blob <- observeReferenced current
        case blob of
          ConfigBlobMissing ->
            pure
              (ConfigObservationCorrupt "Authority config reference names a missing blob")
          ConfigBlobCorrupt detail -> pure (ConfigObservationCorrupt detail)
          ConfigBlobUnobservable detail -> pure (ConfigObservationUnobservable detail)
          ConfigBlobCurrent canonicalBytes -> do
            projected <- compileConfigProjection compiler scope canonicalBytes
            pure $ case projected of
              Left detail -> ConfigObservationCorrupt detail
              Right bytes ->
                ConfigObservationObserved
                  ConfigProjection
                    { configProjectionIdentity = current
                    , configProjectionScope = scope
                    , configProjectionBytes = bytes
                    }

  observeReferenced current = do
    observed <-
      observeConfigBlob
        blobStore
        (inForceDigest current)
        (inForceReference current)
    pure $ case observed of
      ConfigBlobCurrent bytes
        | digestBytes bytes == inForceDigest current -> ConfigBlobCurrent bytes
        | otherwise -> ConfigBlobCorrupt "Authority config plaintext digest mismatch"
      other -> other

  propose request
    | ByteString.null proposedBytes =
        pure (ConfigProposalInvalid "config proposal must not be empty")
    | ByteString.length proposedBytes > configPayloadMaximumBytes =
        pure (ConfigProposalInvalid "config proposal exceeds the compiled bound")
    | otherwise = do
        compiled <- compileCanonicalConfig compiler proposedBytes
        case compiled of
          Left detail -> pure (ConfigProposalInvalid detail)
          Right canonicalBytes
            | canonicalBytes /= proposedBytes ->
                pure (ConfigProposalInvalid "config proposal is not canonical")
            | otherwise -> proposeCanonical canonicalBytes
   where
    proposedBytes = configProposeCanonicalBytes request

    proposeCanonical canonicalBytes = do
      observed <- readAuthorityAdmission authorityRepository
      case observed of
        Left detail -> pure (ConfigProposalUnavailable detail)
        Right snapshot -> do
          let digest = digestBytes canonicalBytes
              preliminary = proposalFor digest (ConfigReference (configDigestText digest))
          case decideAuthorityConfigProposal schemaValidity current preliminary of
            AuthorityConfigProposalRefusedByGate refusal ->
              pure (ConfigProposalRefusedByGate refusal)
            AuthorityConfigProposalDecided decision -> case decision of
              ConfigProposeRefused refusal -> pure (ConfigProposalRefused refusal)
              ConfigProposeNoop inForce -> confirmNoop inForce
              ConfigSeeded _ -> publishAndPromote snapshot digest canonicalBytes
              ConfigProposed _ -> publishAndPromote snapshot digest canonicalBytes
         where
          current = authorityAdmissionSnapshotState snapshot

    confirmNoop inForce = do
      observed <- observeReferenced inForce
      pure $ case observed of
        ConfigBlobCurrent _ -> ConfigProposalAlreadyCurrent inForce
        ConfigBlobMissing ->
          ConfigProposalUnavailable "current Authority config blob is missing"
        ConfigBlobCorrupt detail -> ConfigProposalUnavailable detail
        ConfigBlobUnobservable detail -> ConfigProposalUnavailable detail

    publishAndPromote snapshot digest canonicalBytes = do
      replicated <- replicateConfigBlob blobStore digest canonicalBytes
      case replicated of
        Left detail -> pure (ConfigProposalUnavailable detail)
        Right reference -> do
          let proposal = proposalFor digest reference
              current = authorityAdmissionSnapshotState snapshot
              (decision, next) =
                stepAuthorityConfigProposal schemaValidity current proposal
          case decision of
            AuthorityConfigProposalRefusedByGate refusal ->
              pure (ConfigProposalRefusedByGate refusal)
            AuthorityConfigProposalDecided (ConfigProposeRefused refusal) ->
              pure (ConfigProposalRefused refusal)
            AuthorityConfigProposalDecided decided -> do
              attempted <-
                if next == current
                  then pure (Right ())
                  else
                    compareAndSwapAuthorityAdmission
                      authorityRepository
                      (authorityAdmissionRevision snapshot)
                      next
              confirmPromotion attempted decided digest reference

    confirmPromotion attempted decision digest reference = do
      readback <- readAuthorityAdmission authorityRepository
      case readback of
        Left detail ->
          pure
            ( ConfigProposalUnavailable
                (attemptDetail attempted <> "; config CAS read-back failed: " <> detail)
            )
        Right confirmed ->
          case authorityAggregateConfig (authorityAdmissionSnapshotState confirmed) of
            ConfigInForce actual
              | inForceDigest actual == digest
                  && inForceSchema actual == configProposeSchema request
                  && inForceReference actual == reference -> do
                  blob <- observeReferenced actual
                  pure $ case blob of
                    ConfigBlobCurrent _ -> responseForDecision decision actual
                    ConfigBlobMissing ->
                      ConfigProposalUnavailable "promoted Authority config blob is missing"
                    ConfigBlobCorrupt detail -> ConfigProposalUnavailable detail
                    ConfigBlobUnobservable detail -> ConfigProposalUnavailable detail
              | otherwise -> conflictFrom confirmed
            ConfigUnseeded -> conflictFrom confirmed

    conflictFrom confirmed = do
      observation <-
        observeAggregate
          ConfigProjectionOperator
          (authorityAdmissionSnapshotState confirmed)
      pure (ConfigProposalConflict observation)

    proposalFor digest reference =
      ConfigProposal
        { proposalExpectedPrior = configProposeExpectedGeneration request
        , proposalSchema = configProposeSchema request
        , proposalDigest = digest
        , proposalReference = reference
        }

    schemaValidity = case configProposeSchema request of
      ConfigSchemaVersion 1 -> SchemaSupported
      ConfigSchemaVersion _ -> SchemaUnsupported

  responseForDecision decision actual = case decision of
    ConfigSeeded _ -> ConfigProposalSeeded actual
    ConfigProposed _ -> ConfigProposalAdvanced actual
    ConfigProposeNoop _ -> ConfigProposalAlreadyCurrent actual
    ConfigProposeRefused refusal -> ConfigProposalRefused refusal

serveConfigObserveRequest
  :: (Monad m)
  => Int
  -> ConfigAuthorityRepository m
  -> VerifiedCallerSlot
  -> LazyByteString.ByteString
  -> m (ConfigEndpointResult ConfigObservation)
serveConfigObserveRequest maximumBytes repository callerSlot body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (ConfigEndpointBadRequest err)
    Right request
      | configObserveRequestedScope request /= callerScope ->
          pure ConfigEndpointForbidden
      | otherwise ->
          ConfigEndpointRespond
            <$> observeAuthorityConfig repository callerScope
 where
  callerScope =
    configProjectionScopeForCaller (verifiedCallerSlotPrincipal callerSlot)

serveConfigProposeCasRequest
  :: (Monad m)
  => Int
  -> ConfigAuthorityRepository m
  -> VerifiedCallerSlot
  -> LazyByteString.ByteString
  -> m (ConfigEndpointResult ConfigProposeCasResponse)
serveConfigProposeCasRequest maximumBytes repository callerSlot body
  | not (callerCanPropose (verifiedCallerSlotPrincipal callerSlot)) =
      pure ConfigEndpointForbidden
  | otherwise = case decodeControlPlaneRequest maximumBytes body of
      Left err -> pure (ConfigEndpointBadRequest err)
      Right request -> ConfigEndpointRespond <$> proposeAuthorityConfig repository request
 where
  callerCanPropose principal = case principal of
    CallerOperatorCli -> True
    CallerTestHarness -> True
    CallerAdminActionRunner -> False
    CallerCredentialProvisioner -> False
    CallerService _ -> False

configEndpointHttpStatus :: ConfigEndpointResult response -> ReplyStatus
configEndpointHttpStatus result = case result of
  ConfigEndpointBadRequest _ -> ReplyBadRequest
  ConfigEndpointForbidden -> ReplyForbidden
  ConfigEndpointRespond _ -> ReplyOk

configEndpointResponseBody
  :: (Serialise response)
  => ConfigEndpointResult response
  -> ByteString
configEndpointResponseBody result = case result of
  ConfigEndpointRespond response ->
    LazyByteString.toStrict (encodeControlPlaneResponse response)
  ConfigEndpointBadRequest err ->
    TextEncoding.encodeUtf8
      ("config-bad-request:" <> controlPlaneRequestCodecToken err)
  ConfigEndpointForbidden -> "config-forbidden"

digestBytes :: ByteString -> ConfigDigest
digestBytes = ConfigDigest . TextEncoding.decodeUtf8 . hexSha256

configDigestText :: ConfigDigest -> Text
configDigestText (ConfigDigest value) = value

attemptDetail :: Either Text () -> Text
attemptDetail attempted = case attempted of
  Left detail -> detail
  Right () -> "config CAS was not confirmed"
