{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Lifecycle-Authority-retained inputs for registered AWS stack decisions.
-- One create-if-absent object binds the exact cleanup run, graph, scope,
-- operation, registered stack, checkpoint pair, complete ownership evidence,
-- Provider revision, and closed Provider configuration.  Read APIs return the
-- two opaque values consumed by 'AwsRegisteredTargetInterpreter'; no caller can
-- recover a manifest proof from fields or choose a different object name.
module Prodbox.ControlPlane.AwsStackReaderRepository.Internal
  ( AwsStackReaderSubmissionKey
  , awsStackReaderSubmissionKeyText
  , AwsStackReaderAuthorityIdentity
  , awsStackReaderAuthorityIdentity
  , awsStackReaderAuthoritySubmissionKey
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityCoordinateDigest
  , awsStackReaderAuthorityScope
  , awsStackReaderAuthorityLogicalName
  , maximumAwsStackReaderAuthorityIdentityBytes
  , encodeAwsStackReaderAuthorityIdentity
  , decodeAwsStackReaderAuthorityIdentity
  , AwsStackReaderBundle
  , prepareAwsStackReaderBundle
  , decodeAwsStackReaderBundle
  , awsStackReaderBundleIdentity
  , awsStackReaderBundleDecisionInputs
  , awsStackReaderBundleProviderBinding
  , awsStackReaderBundleBytes
  , AwsStackReaderError (..)
  , maximumAwsStackReaderBytes
  , AwsStackReaderCommitResult (..)
  , AwsStackReaderReadBackObservation (..)
  , AwsStackReaderRepository (..)
  , awsStackReaderModelBCodec
  , modelBAwsStackReaderRepository
  , CommittedAwsStackReaderBundle
  , committedAwsStackReaderIdentity
  , committedAwsStackReaderDecisionInputs
  , committedAwsStackReaderProviderBinding
  , committedAwsStackReaderBytes
  , confirmCommittedAwsStackReaderBytes
  , AwsStackReaderClient (..)
  , commitAwsStackReaderBundleAttempt
  , independentlyReadBackCommittedAwsStackReaderBundle
  , commitAndReadBackAwsStackReaderBundle
  , readBackAwsStackDecisionInputs
  , readBackAwsStackProviderBinding
  , AwsStackReaderClientError (..)
  , nonAuthorizingAwsStackReaderDiagnosticClient
  , lifecycleAuthorityAwsStackReaderClient
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  , cleanupDigestText
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupDigest
  , mkCleanupOperationId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderStackConfig
  , ProviderStackConfigView (..)
  , mkAwsEksProfileProviderStackConfig
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProfileProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkProviderRevision
  , providerRevisionNatural
  , providerStackConfigView
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
  ( AwsRegisteredTargetInterpreterError
  , AwsStackDecisionInputs
  , AwsStackProviderBinding
  , awsStackDecisionInputsCheckpointPair
  , awsStackDecisionInputsKey
  , awsStackDecisionInputsManifest
  , awsStackDecisionInputsOperationId
  , awsStackDecisionInputsScope
  , awsStackProviderBindingConfig
  , awsStackProviderBindingKey
  , awsStackProviderBindingOperationId
  , awsStackProviderBindingRevision
  , awsStackProviderBindingScope
  , mkAwsStackDecisionInputs
  , mkAwsStackProviderBinding
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestDecisionEvidence
  , OwnershipManifestDecisionView (..)
  , ownershipManifestDecisionView
  , ownershipManifestObservationOnly
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  )
import Prodbox.Settings.AwsSubstrateProfile (AwsSubstrateProfile)

newtype AwsStackReaderSubmissionKey = AwsStackReaderSubmissionKey Text
  deriving stock (Eq, Ord, Show)

awsStackReaderSubmissionKeyText :: AwsStackReaderSubmissionKey -> Text
awsStackReaderSubmissionKeyText (AwsStackReaderSubmissionKey value) = value

data AwsStackReaderAuthorityIdentity = AwsStackReaderAuthorityIdentity
  { internalAwsStackReaderSubmissionKey :: !AwsStackReaderSubmissionKey
  , internalAwsStackReaderRunId :: !CleanupRunId
  , internalAwsStackReaderGraphDigest :: !CleanupDigest
  , internalAwsStackReaderOperationId :: !CleanupOperationId
  , internalAwsStackReaderKey :: !RegisteredResourceKey
  , internalAwsStackReaderCoordinateDigest :: !ManagedResourceCoordinateDigest
  , internalAwsStackReaderScope :: !ObservationEvidenceScope
  }
  deriving stock (Eq, Show)

data AwsStackReaderBundle = AwsStackReaderBundle
  { internalAwsStackReaderBundleIdentity :: !AwsStackReaderAuthorityIdentity
  , internalAwsStackReaderBundleDecisionInputs :: !AwsStackDecisionInputs
  , internalAwsStackReaderBundleProviderBinding :: !AwsStackProviderBinding
  , internalAwsStackReaderBundleBytes :: !ByteString
  }

instance Eq AwsStackReaderBundle where
  left == right = awsStackReaderBundleBytes left == awsStackReaderBundleBytes right

instance Show AwsStackReaderBundle where
  show bundle =
    "<aws-stack-reader-bundle:"
      <> show (internalAwsStackReaderKey (awsStackReaderBundleIdentity bundle))
      <> ">"

awsStackReaderBundleIdentity
  :: AwsStackReaderBundle -> AwsStackReaderAuthorityIdentity
awsStackReaderBundleIdentity = internalAwsStackReaderBundleIdentity

awsStackReaderBundleDecisionInputs
  :: AwsStackReaderBundle -> AwsStackDecisionInputs
awsStackReaderBundleDecisionInputs = internalAwsStackReaderBundleDecisionInputs

awsStackReaderBundleProviderBinding
  :: AwsStackReaderBundle -> AwsStackProviderBinding
awsStackReaderBundleProviderBinding = internalAwsStackReaderBundleProviderBinding

awsStackReaderBundleBytes :: AwsStackReaderBundle -> ByteString
awsStackReaderBundleBytes = internalAwsStackReaderBundleBytes

maximumAwsStackReaderBytes :: Int
maximumAwsStackReaderBytes = 64 * 1024

data AwsStackReaderError
  = AwsStackReaderRunScopeMismatch !CleanupRunId !DurableObservationRunScope
  | AwsStackReaderDecisionProviderOperationMismatch !CleanupOperationId !CleanupOperationId
  | AwsStackReaderDecisionProviderKeyMismatch !RegisteredResourceKey !RegisteredResourceKey
  | AwsStackReaderDecisionProviderScopeMismatch !ObservationEvidenceScope !ObservationEvidenceScope
  | AwsStackReaderStackUnregistered !RegisteredResourceKey
  | AwsStackReaderResourceNotStack !RegisteredResourceKey !ResourceKind
  | AwsStackReaderRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | AwsStackReaderScopeOperationInvalid !LifecycleOperation
  | AwsStackReaderAwsScopeMissing
  | AwsStackReaderCompleteManifestUnsupported
  | AwsStackReaderInterpreterValueInvalid !AwsRegisteredTargetInterpreterError
  | AwsStackReaderFieldInvalid !Text
  | AwsStackReaderEmpty
  | AwsStackReaderTooLarge !Int !Int
  | AwsStackReaderDecodeFailed !Text
  | AwsStackReaderNonCanonical
  | AwsStackReaderVersionUnsupported !Int
  | AwsStackReaderIdentityMismatch
      !AwsStackReaderAuthorityIdentity
      !AwsStackReaderAuthorityIdentity
  deriving stock (Eq, Show)

data AwsStackReaderCommitResult
  = AwsStackReaderCommitCreated
  | AwsStackReaderCommitExactReplay
  | AwsStackReaderCommitConflict
  | AwsStackReaderCommitResponseLost !ObservationFailure
  | AwsStackReaderCommitUnavailable !ObservationFailure
  deriving stock (Eq, Show)

data AwsStackReaderReadBackObservation
  = AwsStackReaderReadBackPresent !ByteString
  | AwsStackReaderReadBackMissing
  | AwsStackReaderReadBackCorrupt !Text
  | AwsStackReaderReadBackUnobservable !ObservationFailure
  | AwsStackReaderReadBackUnbounded !Int !Int
  deriving stock (Eq, Show)

data AwsStackReaderRepository m = AwsStackReaderRepository
  { createOrReplayAwsStackReaderBundle
      :: AwsStackReaderBundle -> m AwsStackReaderCommitResult
  , independentlyReadBackAwsStackReaderBundle
      :: AwsStackReaderAuthorityIdentity
      -> m AwsStackReaderReadBackObservation
  }

data CommittedAwsStackReaderBundle = CommittedAwsStackReaderBundle
  { internalCommittedAwsStackReaderBundle :: !AwsStackReaderBundle
  }

committedAwsStackReaderIdentity
  :: CommittedAwsStackReaderBundle -> AwsStackReaderAuthorityIdentity
committedAwsStackReaderIdentity =
  awsStackReaderBundleIdentity . internalCommittedAwsStackReaderBundle

committedAwsStackReaderDecisionInputs
  :: CommittedAwsStackReaderBundle -> AwsStackDecisionInputs
committedAwsStackReaderDecisionInputs =
  awsStackReaderBundleDecisionInputs . internalCommittedAwsStackReaderBundle

committedAwsStackReaderProviderBinding
  :: CommittedAwsStackReaderBundle -> AwsStackProviderBinding
committedAwsStackReaderProviderBinding =
  awsStackReaderBundleProviderBinding . internalCommittedAwsStackReaderBundle

committedAwsStackReaderBytes :: CommittedAwsStackReaderBundle -> ByteString
committedAwsStackReaderBytes =
  awsStackReaderBundleBytes . internalCommittedAwsStackReaderBundle

confirmCommittedAwsStackReaderBytes
  :: AwsStackReaderAuthorityIdentity
  -> ByteString
  -> Either AwsStackReaderClientError CommittedAwsStackReaderBundle
confirmCommittedAwsStackReaderBytes expected bytes =
  CommittedAwsStackReaderBundle
    <$> confirmReadBack expected (AwsStackReaderReadBackPresent bytes)

data AwsStackReaderClient m = AwsStackReaderClient
  { internalCommitAwsStackReaderBundleAttempt
      :: AwsStackDecisionInputs
      -> AwsStackProviderBinding
      -> m (Either AwsStackReaderClientError AwsStackReaderCommitResult)
  , internalIndependentlyReadBackCommittedAwsStackReaderBundle
      :: CleanupOperationId
      -> RegisteredResourceKey
      -> ObservationEvidenceScope
      -> m (Either AwsStackReaderClientError CommittedAwsStackReaderBundle)
  , internalCommitAndReadBackAwsStackReaderBundle
      :: AwsStackDecisionInputs
      -> AwsStackProviderBinding
      -> m (Either AwsStackReaderClientError CommittedAwsStackReaderBundle)
  , internalReadBackAwsStackDecisionInputs
      :: CleanupOperationId
      -> RegisteredResourceKey
      -> ObservationEvidenceScope
      -> m (Either Text AwsStackDecisionInputs)
  , internalReadBackAwsStackProviderBinding
      :: CleanupOperationId
      -> RegisteredResourceKey
      -> ObservationEvidenceScope
      -> m (Either Text AwsStackProviderBinding)
  }

commitAwsStackReaderBundleAttempt
  :: AwsStackReaderClient m
  -> AwsStackDecisionInputs
  -> AwsStackProviderBinding
  -> m (Either AwsStackReaderClientError AwsStackReaderCommitResult)
commitAwsStackReaderBundleAttempt = internalCommitAwsStackReaderBundleAttempt

independentlyReadBackCommittedAwsStackReaderBundle
  :: AwsStackReaderClient m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either AwsStackReaderClientError CommittedAwsStackReaderBundle)
independentlyReadBackCommittedAwsStackReaderBundle =
  internalIndependentlyReadBackCommittedAwsStackReaderBundle

commitAndReadBackAwsStackReaderBundle
  :: AwsStackReaderClient m
  -> AwsStackDecisionInputs
  -> AwsStackProviderBinding
  -> m (Either AwsStackReaderClientError CommittedAwsStackReaderBundle)
commitAndReadBackAwsStackReaderBundle = internalCommitAndReadBackAwsStackReaderBundle

readBackAwsStackDecisionInputs
  :: AwsStackReaderClient m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either Text AwsStackDecisionInputs)
readBackAwsStackDecisionInputs = internalReadBackAwsStackDecisionInputs

readBackAwsStackProviderBinding
  :: AwsStackReaderClient m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either Text AwsStackProviderBinding)
readBackAwsStackProviderBinding = internalReadBackAwsStackProviderBinding

data AwsStackReaderClientError
  = AwsStackReaderClientRequestInvalid !AwsStackReaderError
  | AwsStackReaderClientCommitUnconfirmed
      !AwsStackReaderCommitResult
      !AwsStackReaderReadBackObservation
  | AwsStackReaderClientMissing
  | AwsStackReaderClientCorrupt !Text
  | AwsStackReaderClientUnobservable !ObservationFailure
  | AwsStackReaderClientUnbounded !Int !Int
  | AwsStackReaderClientReadBackInvalid !AwsStackReaderError
  | AwsStackReaderClientTransportFailed !Text
  | AwsStackReaderClientResponseInvalid !Text
  | AwsStackReaderClientHttpStatusMismatch !Int !Int
  | AwsStackReaderClientRemoteRefused !Text
  | AwsStackReaderClientRemoteUnavailable !Text
  deriving stock (Eq, Show)

-- | Public tests and outer dispatchers may need a closed client value to
-- exercise refusal plumbing before production Authority composition is
-- installed.  Every operation fails with the same fixed diagnostic; this
-- boundary can neither claim a commit nor return a committed bundle.
nonAuthorizingAwsStackReaderDiagnosticClient
  :: (Applicative m)
  => AwsStackReaderClientError
  -> AwsStackReaderClient m
nonAuthorizingAwsStackReaderDiagnosticClient readError =
  AwsStackReaderClient
    { internalCommitAwsStackReaderBundleAttempt = \_ _ -> pure (Left readError)
    , internalIndependentlyReadBackCommittedAwsStackReaderBundle = \_ _ _ ->
        pure (Left readError)
    , internalCommitAndReadBackAwsStackReaderBundle = \_ _ -> pure (Left readError)
    , internalReadBackAwsStackDecisionInputs = \_ _ _ -> pure (Left diagnostic)
    , internalReadBackAwsStackProviderBinding = \_ _ _ -> pure (Left diagnostic)
    }
 where
  diagnostic = "non-authorizing AWS stack-reader diagnostic client"

prepareAwsStackReaderBundle
  :: CleanupRunId
  -> CleanupDigest
  -> AwsStackDecisionInputs
  -> AwsStackProviderBinding
  -> Either AwsStackReaderError AwsStackReaderBundle
prepareAwsStackReaderBundle runId graphDigest decisionInputs providerBinding = do
  validatePair runId decisionInputs providerBinding
  identity <-
    awsStackReaderAuthorityIdentity
      runId
      graphDigest
      (awsStackDecisionInputsOperationId decisionInputs)
      (awsStackDecisionInputsKey decisionInputs)
      (awsStackDecisionInputsScope decisionInputs)
  wire <- wireFromValues identity decisionInputs providerBinding
  let bytes = canonicalBytes wire
  -- Reopen the candidate through the same strict decoder used after process
  -- loss.  This prevents the write path from accepting a value whose flat
  -- provenance/version/failure fields could not later remint the two opaque
  -- interpreter inputs.
  decodeAwsStackReaderBundle bytes

awsStackReaderAuthorityIdentity
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either AwsStackReaderError AwsStackReaderAuthorityIdentity
awsStackReaderAuthorityIdentity runId graphDigest operationId key scope = do
  validateIdentity runId key scope
  identity <-
    maybe
      (Left (AwsStackReaderStackUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  let coordinate = registeredIdentityCoordinateDigest identity
      submission =
        AwsStackReaderSubmissionKey
          ( "aws-stack-reader-v1-"
              <> TextEncoding.decodeUtf8
                (hexSha256 (TextEncoding.encodeUtf8 canonicalIdentity))
          )
      value =
        AwsStackReaderAuthorityIdentity
          { internalAwsStackReaderSubmissionKey = submission
          , internalAwsStackReaderRunId = runId
          , internalAwsStackReaderGraphDigest = graphDigest
          , internalAwsStackReaderOperationId = operationId
          , internalAwsStackReaderKey = key
          , internalAwsStackReaderCoordinateDigest = coordinate
          , internalAwsStackReaderScope = scope
          }
  pure value
 where
  canonicalIdentity =
    Text.concat
      ( map
          frame
          ( [ "aws-stack-reader/v1"
            , cleanupRunIdText runId
            , cleanupDigestText graphDigest
            , cleanupOperationIdText operationId
            , registeredResourceKeyText key
            ]
              ++ scopeIdentityFields scope
          )
      )

awsStackReaderAuthoritySubmissionKey
  :: AwsStackReaderAuthorityIdentity -> AwsStackReaderSubmissionKey
awsStackReaderAuthoritySubmissionKey = internalAwsStackReaderSubmissionKey

awsStackReaderAuthorityRunId
  :: AwsStackReaderAuthorityIdentity -> CleanupRunId
awsStackReaderAuthorityRunId = internalAwsStackReaderRunId

awsStackReaderAuthorityGraphDigest
  :: AwsStackReaderAuthorityIdentity -> CleanupDigest
awsStackReaderAuthorityGraphDigest = internalAwsStackReaderGraphDigest

awsStackReaderAuthorityOperationId
  :: AwsStackReaderAuthorityIdentity -> CleanupOperationId
awsStackReaderAuthorityOperationId = internalAwsStackReaderOperationId

awsStackReaderAuthorityKey
  :: AwsStackReaderAuthorityIdentity -> RegisteredResourceKey
awsStackReaderAuthorityKey = internalAwsStackReaderKey

awsStackReaderAuthorityCoordinateDigest
  :: AwsStackReaderAuthorityIdentity -> ManagedResourceCoordinateDigest
awsStackReaderAuthorityCoordinateDigest = internalAwsStackReaderCoordinateDigest

awsStackReaderAuthorityScope
  :: AwsStackReaderAuthorityIdentity -> ObservationEvidenceScope
awsStackReaderAuthorityScope = internalAwsStackReaderScope

awsStackReaderAuthorityLogicalName
  :: AwsStackReaderAuthorityIdentity -> Text
awsStackReaderAuthorityLogicalName identity =
  "authority/aws-stack-readers/"
    <> awsStackReaderSubmissionKeyText
      (internalAwsStackReaderSubmissionKey identity)

awsStackReaderModelBCodec :: ModelBCodec ByteString
awsStackReaderModelBCodec =
  ModelBCodec
    { encodeModelBValue = first show . validateCanonicalAwsStackReaderBytes
    , decodeModelBValue = first show . validateCanonicalAwsStackReaderBytes
    }

modelBAwsStackReaderRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> AwsStackReaderRepository m
modelBAwsStackReaderRepository authority adapter =
  AwsStackReaderRepository
    { createOrReplayAwsStackReaderBundle = createOrReplay
    , independentlyReadBackAwsStackReaderBundle = readBack
    }
 where
  createOrReplay bundle = case coordinateFor (awsStackReaderBundleIdentity bundle) of
    Left failure -> pure (AwsStackReaderCommitUnavailable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      case observed of
        ModelBMissing -> initialize coordinate bundle
        ModelBObserved _ existing -> pure (existingDisposition bundle existing)
        ModelBCorrupt detail -> pure (unavailable "corrupt" detail)
        ModelBEndpointUnready detail -> pure (unavailable "endpoint-unready" detail)
        ModelBUnobservable detail -> pure (unavailable "unobservable" detail)

  initialize coordinate bundle = do
    result <-
      modelBCompareAndSwap
        adapter
        (ModelBInitialize coordinate (awsStackReaderBundleBytes bundle))
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == awsStackReaderBundleBytes bundle -> AwsStackReaderCommitCreated
        | otherwise -> AwsStackReaderCommitConflict
      ModelBCasConflict observation -> conflictDisposition bundle observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        AwsStackReaderCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBack identity = case coordinateFor identity of
    Left failure -> pure (AwsStackReaderReadBackUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> AwsStackReaderReadBackMissing
        ModelBObserved _ bytes
          | ByteString.length bytes > maximumAwsStackReaderBytes ->
              AwsStackReaderReadBackUnbounded
                (ByteString.length bytes)
                maximumAwsStackReaderBytes
          | otherwise -> AwsStackReaderReadBackPresent bytes
        ModelBCorrupt detail -> AwsStackReaderReadBackCorrupt detail
        ModelBEndpointUnready detail -> unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (awsStackReaderAuthorityLogicalName identity)
      )
  unavailable category detail =
    AwsStackReaderCommitUnavailable (repositoryFailure category detail)
  unobservable category detail =
    AwsStackReaderReadBackUnobservable (repositoryFailure category detail)

lifecycleAuthorityAwsStackReaderClient
  :: (Monad m)
  => CleanupRunId
  -> CleanupDigest
  -> AwsStackReaderRepository m
  -> AwsStackReaderClient m
lifecycleAuthorityAwsStackReaderClient runId graphDigest repository =
  AwsStackReaderClient
    { internalCommitAwsStackReaderBundleAttempt = commitAttempt
    , internalIndependentlyReadBackCommittedAwsStackReaderBundle = readExact
    , internalCommitAndReadBackAwsStackReaderBundle = commitAndReadBack
    , internalReadBackAwsStackDecisionInputs = \operationId key scope ->
        fmap
          (first renderClientError . fmap committedAwsStackReaderDecisionInputs)
          (readExact operationId key scope)
    , internalReadBackAwsStackProviderBinding = \operationId key scope ->
        fmap
          (first renderClientError . fmap committedAwsStackReaderProviderBinding)
          (readExact operationId key scope)
    }
 where
  commitAttempt inputs binding =
    case prepareAwsStackReaderBundle runId graphDigest inputs binding of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right candidate ->
        Right <$> createOrReplayAwsStackReaderBundle repository candidate

  commitAndReadBack inputs binding =
    case prepareAwsStackReaderBundle runId graphDigest inputs binding of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right candidate -> do
        committed <- createOrReplayAwsStackReaderBundle repository candidate
        observed <-
          independentlyReadBackAwsStackReaderBundle
            repository
            (awsStackReaderBundleIdentity candidate)
        pure $ case confirmReadBack (awsStackReaderBundleIdentity candidate) observed of
          Left _ -> Left (AwsStackReaderClientCommitUnconfirmed committed observed)
          Right exact
            | awsStackReaderBundleBytes exact == awsStackReaderBundleBytes candidate ->
                Right (CommittedAwsStackReaderBundle exact)
            | otherwise -> Left (AwsStackReaderClientCommitUnconfirmed committed observed)

  readExact operationId key scope =
    case awsStackReaderAuthorityIdentity runId graphDigest operationId key scope of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right identity -> do
        observed <- independentlyReadBackAwsStackReaderBundle repository identity
        pure (CommittedAwsStackReaderBundle <$> confirmReadBack identity observed)

confirmReadBack
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackReaderReadBackObservation
  -> Either AwsStackReaderClientError AwsStackReaderBundle
confirmReadBack expected observation = case observation of
  AwsStackReaderReadBackMissing -> Left AwsStackReaderClientMissing
  AwsStackReaderReadBackCorrupt detail -> Left (AwsStackReaderClientCorrupt detail)
  AwsStackReaderReadBackUnobservable failure ->
    Left (AwsStackReaderClientUnobservable failure)
  AwsStackReaderReadBackUnbounded actual maximumBytes ->
    Left (AwsStackReaderClientUnbounded actual maximumBytes)
  AwsStackReaderReadBackPresent bytes ->
    case decodeAwsStackReaderBundle bytes of
      Left err -> Left (AwsStackReaderClientReadBackInvalid err)
      Right bundle
        | awsStackReaderBundleIdentity bundle == expected -> Right bundle
        | otherwise ->
            Left
              ( AwsStackReaderClientReadBackInvalid
                  ( AwsStackReaderIdentityMismatch
                      expected
                      (awsStackReaderBundleIdentity bundle)
                  )
              )

data ScopeWire = ScopeWire
  { scopeWireSurface :: !Int
  , scopeWireRegistryRevision :: !Text
  , scopeWireRunScope :: !Text
  , scopeWireFoundation :: !Text
  , scopeWireAwsAccount :: !(Maybe Text)
  , scopeWireAwsRegion :: !(Maybe Text)
  , scopeWireOperation :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackReaderIdentityWire = AwsStackReaderIdentityWire
  { identityWireVersion :: !Int
  , identityWireRunId :: !Text
  , identityWireGraphDigest :: !Text
  , identityWireOperationId :: !Text
  , identityWireKey :: !Int
  , identityWireCoordinateDigest :: !Text
  , identityWireScope :: !ScopeWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

maximumAwsStackReaderAuthorityIdentityBytes :: Int
maximumAwsStackReaderAuthorityIdentityBytes = 16 * 1024

encodeAwsStackReaderAuthorityIdentity
  :: AwsStackReaderAuthorityIdentity -> ByteString
encodeAwsStackReaderAuthorityIdentity =
  LazyByteString.toStrict . serialise . identityToWire

decodeAwsStackReaderAuthorityIdentity
  :: ByteString -> Either AwsStackReaderError AwsStackReaderAuthorityIdentity
decodeAwsStackReaderAuthorityIdentity bytes = do
  when (ByteString.null bytes) (Left AwsStackReaderEmpty)
  when
    (ByteString.length bytes > maximumAwsStackReaderAuthorityIdentityBytes)
    ( Left
        ( AwsStackReaderTooLarge
            maximumAwsStackReaderAuthorityIdentityBytes
            (ByteString.length bytes)
        )
    )
  wire <-
    first
      (AwsStackReaderDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left AwsStackReaderNonCanonical)
  unless
    (identityWireVersion wire == 1)
    (Left (AwsStackReaderVersionUnsupported (identityWireVersion wire)))
  runId <- decodeText "run ID" mkCleanupRunId (identityWireRunId wire)
  graphDigest <- decodeText "graph digest" mkCleanupDigest (identityWireGraphDigest wire)
  operationId <- decodeText "operation ID" mkCleanupOperationId (identityWireOperationId wire)
  key <- decodeBoundedEnum "registered key" (identityWireKey wire)
  scope <- scopeFromWire (identityWireScope wire)
  identity <- awsStackReaderAuthorityIdentity runId graphDigest operationId key scope
  unless
    ( identityWireCoordinateDigest wire
        == managedResourceCoordinateDigestText
          (awsStackReaderAuthorityCoordinateDigest identity)
    )
    (Left (AwsStackReaderFieldInvalid "registered coordinate digest mismatch"))
  pure identity

identityToWire :: AwsStackReaderAuthorityIdentity -> AwsStackReaderIdentityWire
identityToWire identity =
  AwsStackReaderIdentityWire
    { identityWireVersion = 1
    , identityWireRunId = cleanupRunIdText (awsStackReaderAuthorityRunId identity)
    , identityWireGraphDigest =
        cleanupDigestText (awsStackReaderAuthorityGraphDigest identity)
    , identityWireOperationId =
        cleanupOperationIdText (awsStackReaderAuthorityOperationId identity)
    , identityWireKey = fromEnum (awsStackReaderAuthorityKey identity)
    , identityWireCoordinateDigest =
        managedResourceCoordinateDigestText
          (awsStackReaderAuthorityCoordinateDigest identity)
    , identityWireScope = scopeToWire (awsStackReaderAuthorityScope identity)
    }

data CheckpointResultWire
  = CheckpointAbsentWire
  | CheckpointPresentWire !Text
  | CheckpointPartialWire ![Text]
  | CheckpointUnobservableWire ![Text]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CheckpointObservationWire = CheckpointObservationWire
  { checkpointWireKey :: !Int
  , checkpointWireCopy :: !Int
  , checkpointWireProvenance :: !Text
  , checkpointWireScope :: !ScopeWire
  , checkpointWireResult :: !CheckpointResultWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ManifestObservationResultWire
  = ManifestAbsentWire
  | ManifestPresentWire !Text
  | ManifestPartialWire ![Text]
  | ManifestUnobservableWire ![Text]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ManifestWire
  = ManifestObservationWire
      !Int
      !Text
      !ScopeWire
      !ManifestObservationResultWire
  | ManifestCompleteWire !ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderConfigWire
  = AwsEksProviderConfigWire !Text
  | AwsTestProviderConfigWire !Text
  | AwsEksSubzoneProviderConfigWire !Text !Text
  | AwsEksProfileProviderConfigWire !AwsSubstrateProfile !Natural
  | AwsTestProfileProviderConfigWire !AwsSubstrateProfile
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsStackReaderWire = AwsStackReaderWire
  { readerWireVersion :: !Int
  , readerWireRunId :: !Text
  , readerWireGraphDigest :: !Text
  , readerWireOperationId :: !Text
  , readerWireKey :: !Int
  , readerWireCoordinateDigest :: !Text
  , readerWireScope :: !ScopeWire
  , readerWirePrimaryCheckpoint :: !CheckpointObservationWire
  , readerWireBackupCheckpoint :: !CheckpointObservationWire
  , readerWireManifest :: !ManifestWire
  , readerWireProviderRevision :: !Integer
  , readerWireProviderConfig :: !ProviderConfigWire
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

wireFromValues
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackDecisionInputs
  -> AwsStackProviderBinding
  -> Either AwsStackReaderError AwsStackReaderWire
wireFromValues identity decisionInputs providerBinding = do
  manifest <- manifestToWire (awsStackDecisionInputsManifest decisionInputs)
  let pair = awsStackDecisionInputsCheckpointPair decisionInputs
  pure
    AwsStackReaderWire
      { readerWireVersion = 1
      , readerWireRunId = cleanupRunIdText (internalAwsStackReaderRunId identity)
      , readerWireGraphDigest = cleanupDigestText (internalAwsStackReaderGraphDigest identity)
      , readerWireOperationId = cleanupOperationIdText (internalAwsStackReaderOperationId identity)
      , readerWireKey = fromEnum (internalAwsStackReaderKey identity)
      , readerWireCoordinateDigest =
          managedResourceCoordinateDigestText
            (internalAwsStackReaderCoordinateDigest identity)
      , readerWireScope = scopeToWire (internalAwsStackReaderScope identity)
      , readerWirePrimaryCheckpoint =
          checkpointToWire (primaryCheckpointObservation pair)
      , readerWireBackupCheckpoint =
          checkpointToWire (backupCheckpointObservation pair)
      , readerWireManifest = manifest
      , readerWireProviderRevision =
          toInteger (providerRevisionNatural (awsStackProviderBindingRevision providerBinding))
      , readerWireProviderConfig =
          providerConfigToWire (awsStackProviderBindingConfig providerBinding)
      }

decodeAwsStackReaderBundle
  :: ByteString -> Either AwsStackReaderError AwsStackReaderBundle
decodeAwsStackReaderBundle bytes = do
  when (ByteString.null bytes) (Left AwsStackReaderEmpty)
  when
    (ByteString.length bytes > maximumAwsStackReaderBytes)
    (Left (AwsStackReaderTooLarge maximumAwsStackReaderBytes (ByteString.length bytes)))
  wire <-
    first
      (AwsStackReaderDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless (canonicalBytes wire == bytes) (Left AwsStackReaderNonCanonical)
  unless
    (readerWireVersion wire == 1)
    (Left (AwsStackReaderVersionUnsupported (readerWireVersion wire)))
  runId <- decodeText "run ID" mkCleanupRunId (readerWireRunId wire)
  graphDigest <- decodeText "graph digest" mkCleanupDigest (readerWireGraphDigest wire)
  operationId <- decodeText "operation ID" mkCleanupOperationId (readerWireOperationId wire)
  key <- decodeBoundedEnum "registered key" (readerWireKey wire)
  scope <- scopeFromWire (readerWireScope wire)
  identity <- awsStackReaderAuthorityIdentity runId graphDigest operationId key scope
  unless
    ( readerWireCoordinateDigest wire
        == managedResourceCoordinateDigestText (internalAwsStackReaderCoordinateDigest identity)
    )
    (Left (AwsStackReaderFieldInvalid "registered coordinate digest mismatch"))
  primary <- checkpointFromWire (readerWirePrimaryCheckpoint wire)
  backup <- checkpointFromWire (readerWireBackupCheckpoint wire)
  pair <-
    first
      (AwsStackReaderFieldInvalid . Text.pack . show)
      (mkCheckpointPairObservation key scope primary backup)
  manifest <- manifestFromWire (readerWireManifest wire)
  decisionInputs <-
    first
      AwsStackReaderInterpreterValueInvalid
      (mkAwsStackDecisionInputs operationId key scope pair manifest)
  revisionInteger <- checkedNatural "provider revision" (readerWireProviderRevision wire)
  revision <- first AwsStackReaderFieldInvalid (mkProviderRevision revisionInteger)
  config <- providerConfigFromWire (readerWireProviderConfig wire)
  providerBinding <-
    first
      AwsStackReaderInterpreterValueInvalid
      (mkAwsStackProviderBinding operationId key scope revision config)
  validatePair runId decisionInputs providerBinding
  pure
    AwsStackReaderBundle
      { internalAwsStackReaderBundleIdentity = identity
      , internalAwsStackReaderBundleDecisionInputs = decisionInputs
      , internalAwsStackReaderBundleProviderBinding = providerBinding
      , internalAwsStackReaderBundleBytes = bytes
      }

validateCanonicalAwsStackReaderBytes
  :: ByteString -> Either AwsStackReaderError ByteString
validateCanonicalAwsStackReaderBytes bytes = do
  _ <- decodeAwsStackReaderBundle bytes
  pure bytes

validatePair
  :: CleanupRunId
  -> AwsStackDecisionInputs
  -> AwsStackProviderBinding
  -> Either AwsStackReaderError ()
validatePair runId inputs binding = do
  validateIdentity runId (awsStackDecisionInputsKey inputs) (awsStackDecisionInputsScope inputs)
  unless
    (awsStackDecisionInputsOperationId inputs == awsStackProviderBindingOperationId binding)
    ( Left
        ( AwsStackReaderDecisionProviderOperationMismatch
            (awsStackDecisionInputsOperationId inputs)
            (awsStackProviderBindingOperationId binding)
        )
    )
  unless
    (awsStackDecisionInputsKey inputs == awsStackProviderBindingKey binding)
    ( Left
        ( AwsStackReaderDecisionProviderKeyMismatch
            (awsStackDecisionInputsKey inputs)
            (awsStackProviderBindingKey binding)
        )
    )
  unless
    (awsStackDecisionInputsScope inputs == awsStackProviderBindingScope binding)
    ( Left
        ( AwsStackReaderDecisionProviderScopeMismatch
            (awsStackDecisionInputsScope inputs)
            (awsStackProviderBindingScope binding)
        )
    )

validateIdentity
  :: CleanupRunId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> Either AwsStackReaderError ()
validateIdentity runId key scope = do
  unless
    (evidenceDurableRunScope scope == DurableObservationRunScope (cleanupRunIdText runId))
    (Left (AwsStackReaderRunScopeMismatch runId (evidenceDurableRunScope scope)))
  identity <-
    maybe
      (Left (AwsStackReaderStackUnregistered key))
      Right
      (lookupRegisteredIdentity key)
  unless
    (registeredIdentityKind identity == Stack)
    (Left (AwsStackReaderResourceNotStack key (registeredIdentityKind identity)))
  unless
    (evidenceRegistryRevision scope == lifecycleRegistryRevision)
    ( Left
        ( AwsStackReaderRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
    )
  unless
    (evidenceLifecycleOperation scope == ReconcileDesiredAbsent)
    (Left (AwsStackReaderScopeOperationInvalid (evidenceLifecycleOperation scope)))
  _ <- checkedText "registry revision" 512 (registryRevisionText (evidenceRegistryRevision scope))
  _ <- checkedText "run scope" 512 (runScopeText (evidenceDurableRunScope scope))
  _ <- checkedText "foundation" 512 (foundationText (evidenceLinuxRke2Foundation scope))
  case evidenceAwsScope scope of
    Nothing -> Left AwsStackReaderAwsScopeMissing
    Just aws -> do
      _ <- checkedText "AWS account" 128 (accountText aws)
      _ <- checkedText "AWS region" 128 (regionText aws)
      Right ()

manifestToWire
  :: OwnershipManifestDecisionEvidence
  -> Either AwsStackReaderError ManifestWire
manifestToWire evidence = case ownershipManifestDecisionView evidence of
  OwnershipManifestDecisionObservation observation ->
    pure
      ( ManifestObservationWire
          (fromEnum (ownershipManifestStackKey observation))
          (manifestProvenanceText (ownershipManifestProvenance observation))
          (scopeToWire (ownershipManifestEvidenceScope observation))
          (manifestResultToWire (ownershipManifestResult observation))
      )
  OwnershipManifestDecisionComplete {} ->
    Left AwsStackReaderCompleteManifestUnsupported

manifestFromWire
  :: ManifestWire -> Either AwsStackReaderError OwnershipManifestDecisionEvidence
manifestFromWire wire = case wire of
  ManifestObservationWire rawKey provenance rawScope result -> do
    key <- decodeBoundedEnum "manifest key" rawKey
    scope <- scopeFromWire rawScope
    observedProvenance <-
      OwnershipManifestProvenance <$> checkedText "manifest provenance" 1024 provenance
    observedResult <- manifestResultFromWire result
    pure
      ( ownershipManifestObservationOnly
          OwnershipManifestObservation
            { ownershipManifestStackKey = key
            , ownershipManifestProvenance = observedProvenance
            , ownershipManifestEvidenceScope = scope
            , ownershipManifestResult = observedResult
            }
      )
  ManifestCompleteWire _ ->
    Left AwsStackReaderCompleteManifestUnsupported

checkpointToWire :: CheckpointObservation -> CheckpointObservationWire
checkpointToWire observation =
  CheckpointObservationWire
    { checkpointWireKey = fromEnum (checkpointObservationStackKey observation)
    , checkpointWireCopy = case checkpointObservationCopy observation of
        PrimaryCheckpointCopy -> 0
        BackupCheckpointCopy -> 1
    , checkpointWireProvenance = checkpointProvenanceText (checkpointObservationProvenance observation)
    , checkpointWireScope = scopeToWire (checkpointObservationEvidenceScope observation)
    , checkpointWireResult = checkpointResultToWire (checkpointObservationResult observation)
    }

checkpointFromWire
  :: CheckpointObservationWire -> Either AwsStackReaderError CheckpointObservation
checkpointFromWire wire = do
  key <- decodeBoundedEnum "checkpoint key" (checkpointWireKey wire)
  copy <- case checkpointWireCopy wire of
    0 -> Right PrimaryCheckpointCopy
    1 -> Right BackupCheckpointCopy
    other -> Left (AwsStackReaderFieldInvalid ("invalid checkpoint copy " <> Text.pack (show other)))
  provenance <-
    CheckpointProvenance
      <$> checkedText "checkpoint provenance" 1024 (checkpointWireProvenance wire)
  scope <- scopeFromWire (checkpointWireScope wire)
  result <- checkpointResultFromWire (checkpointWireResult wire)
  pure
    CheckpointObservation
      { checkpointObservationStackKey = key
      , checkpointObservationCopy = copy
      , checkpointObservationProvenance = provenance
      , checkpointObservationEvidenceScope = scope
      , checkpointObservationResult = result
      }

checkpointResultToWire :: CheckpointResult -> CheckpointResultWire
checkpointResultToWire result = case result of
  CheckpointAbsent -> CheckpointAbsentWire
  CheckpointPresent version -> CheckpointPresentWire (checkpointVersionText version)
  CheckpointPartial failures -> CheckpointPartialWire (failureTexts failures)
  CheckpointUnobservable failures -> CheckpointUnobservableWire (failureTexts failures)

checkpointResultFromWire
  :: CheckpointResultWire -> Either AwsStackReaderError CheckpointResult
checkpointResultFromWire wire = case wire of
  CheckpointAbsentWire -> Right CheckpointAbsent
  CheckpointPresentWire version ->
    CheckpointPresent . CheckpointVersion <$> checkedText "checkpoint version" 512 version
  CheckpointPartialWire failures -> CheckpointPartial <$> checkedFailures failures
  CheckpointUnobservableWire failures -> CheckpointUnobservable <$> checkedFailures failures

manifestResultToWire :: OwnershipManifestResult -> ManifestObservationResultWire
manifestResultToWire result = case result of
  OwnershipManifestAbsent -> ManifestAbsentWire
  OwnershipManifestPresent version -> ManifestPresentWire (manifestVersionText version)
  OwnershipManifestPartial failures -> ManifestPartialWire (failureTexts failures)
  OwnershipManifestUnobservable failures -> ManifestUnobservableWire (failureTexts failures)

manifestResultFromWire
  :: ManifestObservationResultWire
  -> Either AwsStackReaderError OwnershipManifestResult
manifestResultFromWire wire = case wire of
  ManifestAbsentWire -> Right OwnershipManifestAbsent
  ManifestPresentWire version ->
    OwnershipManifestPresent . OwnershipManifestVersion
      <$> checkedText "manifest version" 512 version
  ManifestPartialWire failures -> OwnershipManifestPartial <$> checkedFailures failures
  ManifestUnobservableWire failures -> OwnershipManifestUnobservable <$> checkedFailures failures

scopeToWire :: ObservationEvidenceScope -> ScopeWire
scopeToWire scope =
  ScopeWire
    { scopeWireSurface = fromEnum (evidenceCleanupSurface scope)
    , scopeWireRegistryRevision = registryRevisionText (evidenceRegistryRevision scope)
    , scopeWireRunScope = runScopeText (evidenceDurableRunScope scope)
    , scopeWireFoundation = foundationText (evidenceLinuxRke2Foundation scope)
    , scopeWireAwsAccount = accountText <$> evidenceAwsScope scope
    , scopeWireAwsRegion = regionText <$> evidenceAwsScope scope
    , scopeWireOperation = lifecycleOperationTag (evidenceLifecycleOperation scope)
    }

scopeFromWire :: ScopeWire -> Either AwsStackReaderError ObservationEvidenceScope
scopeFromWire wire = do
  surface <- decodeBoundedEnum "cleanup surface" (scopeWireSurface wire)
  revision <-
    RegistryRevision <$> checkedText "registry revision" 512 (scopeWireRegistryRevision wire)
  runScope <- DurableObservationRunScope <$> checkedText "run scope" 512 (scopeWireRunScope wire)
  foundation <- LinuxRke2FoundationId <$> checkedText "foundation" 512 (scopeWireFoundation wire)
  awsScope <- case (scopeWireAwsAccount wire, scopeWireAwsRegion wire) of
    (Nothing, Nothing) -> Right Nothing
    (Just account, Just region) ->
      Just
        <$> ( (AwsScope . AwsAccountId)
                <$> checkedText "AWS account" 128 account
                <*> (AwsRegion <$> checkedText "AWS region" 128 region)
            )
    _ -> Left (AwsStackReaderFieldInvalid "AWS scope was only partially encoded")
  operation <- case scopeWireOperation wire of
    0 -> Right ReconcileDesiredAbsent
    1 -> Right ReconcileDesiredPresent
    2 -> Right RunTerminalEscapeAudit
    other -> Left (AwsStackReaderFieldInvalid ("invalid lifecycle operation " <> Text.pack (show other)))
  pure (mkObservationEvidenceScope surface revision runScope foundation awsScope operation)

providerConfigToWire :: ProviderStackConfig -> ProviderConfigWire
providerConfigToWire config = case providerStackConfigView config of
  AwsEksLegacyConfig operatorCidr -> AwsEksProviderConfigWire operatorCidr
  AwsTestLegacyConfig operatorCidr -> AwsTestProviderConfigWire operatorCidr
  AwsEksSubzoneConfig parentZone subzone ->
    AwsEksSubzoneProviderConfigWire parentZone subzone
  AwsEksProfileConfig profile desiredSize ->
    AwsEksProfileProviderConfigWire profile desiredSize
  AwsTestProfileConfig profile -> AwsTestProfileProviderConfigWire profile

providerConfigFromWire
  :: ProviderConfigWire -> Either AwsStackReaderError ProviderStackConfig
providerConfigFromWire wire =
  first (AwsStackReaderFieldInvalid . Text.pack . show) $ case wire of
    AwsEksProviderConfigWire operatorCidr -> mkAwsEksProviderStackConfig operatorCidr
    AwsTestProviderConfigWire operatorCidr -> mkAwsTestProviderStackConfig operatorCidr
    AwsEksSubzoneProviderConfigWire parentZone subzone ->
      mkAwsEksSubzoneProviderStackConfig parentZone subzone
    AwsEksProfileProviderConfigWire profile desiredSize ->
      mkAwsEksProfileProviderStackConfig profile desiredSize
    AwsTestProfileProviderConfigWire profile ->
      mkAwsTestProfileProviderStackConfig profile

checkedFailures
  :: [Text] -> Either AwsStackReaderError (NonEmpty ObservationFailure)
checkedFailures raw = do
  when (null raw) (Left (AwsStackReaderFieldInvalid "failure set was empty"))
  when (length raw > 32) (Left (AwsStackReaderFieldInvalid "failure set exceeded 32 entries"))
  checked <- mapM (checkedText "observation failure" 1024) raw
  case checked of
    firstFailure : remaining ->
      Right (ObservationFailure firstFailure :| map ObservationFailure remaining)
    [] -> Left (AwsStackReaderFieldInvalid "failure set was empty")

failureTexts :: NonEmpty ObservationFailure -> [Text]
failureTexts failures =
  [detail | ObservationFailure detail <- nonEmptyToList failures]

nonEmptyToList :: NonEmpty value -> [value]
nonEmptyToList (firstValue :| remaining) = firstValue : remaining

checkedText
  :: Text -> Int -> Text -> Either AwsStackReaderError Text
checkedText label maximumLength value
  | Text.null value = invalid "was empty"
  | Text.length value > maximumLength = invalid "was too long"
  | Text.any (\character -> not (isAscii character) || isControl character) value =
      invalid "contained a non-printable character"
  | otherwise = Right value
 where
  invalid detail = Left (AwsStackReaderFieldInvalid (label <> " " <> detail))

checkedNatural :: Text -> Integer -> Either AwsStackReaderError Natural
checkedNatural label value
  | value <= 0 = Left (AwsStackReaderFieldInvalid (label <> " must be positive"))
  | value > toInteger (maxBound :: Word) =
      Left (AwsStackReaderFieldInvalid (label <> " was too large"))
  | otherwise = Right (fromInteger value)

decodeBoundedEnum
  :: forall value
   . (Bounded value, Enum value)
  => Text
  -> Int
  -> Either AwsStackReaderError value
decodeBoundedEnum label raw
  | raw < fromEnum (minBound :: value) || raw > fromEnum (maxBound :: value) =
      Left (AwsStackReaderFieldInvalid (label <> " enum was out of range"))
  | otherwise = Right (toEnum raw)

decodeText
  :: Text
  -> (Text -> Either Text value)
  -> Text
  -> Either AwsStackReaderError value
decodeText label constructor raw =
  first (AwsStackReaderFieldInvalid . ((label <> ": ") <>)) (constructor raw)

canonicalBytes :: AwsStackReaderWire -> ByteString
canonicalBytes = LazyByteString.toStrict . serialise

existingDisposition :: AwsStackReaderBundle -> ByteString -> AwsStackReaderCommitResult
existingDisposition candidate existing
  | existing == awsStackReaderBundleBytes candidate = AwsStackReaderCommitExactReplay
  | otherwise = AwsStackReaderCommitConflict

conflictDisposition
  :: AwsStackReaderBundle
  -> ModelBObservation ByteString
  -> AwsStackReaderCommitResult
conflictDisposition candidate observation = case observation of
  ModelBObserved _ existing -> existingDisposition candidate existing
  ModelBMissing -> AwsStackReaderCommitConflict
  ModelBCorrupt detail ->
    AwsStackReaderCommitUnavailable (repositoryFailure "cas-conflict-corrupt" detail)
  ModelBEndpointUnready detail ->
    AwsStackReaderCommitUnavailable (repositoryFailure "cas-conflict-endpoint-unready" detail)
  ModelBUnobservable detail ->
    AwsStackReaderCommitResponseLost (repositoryFailure "cas-conflict-unobservable" detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    (Text.take 1024 ("AWS stack reader repository " <> category <> ": " <> detail))

renderClientError :: AwsStackReaderClientError -> Text
renderClientError = Text.take 1024 . Text.pack . show

frame :: Text -> Text
frame value = Text.pack (show (Text.length value)) <> ":" <> value

scopeIdentityFields :: ObservationEvidenceScope -> [Text]
scopeIdentityFields scope =
  [ Text.pack (show (evidenceCleanupSurface scope))
  , registryRevisionText (evidenceRegistryRevision scope)
  , runScopeText (evidenceDurableRunScope scope)
  , foundationText (evidenceLinuxRke2Foundation scope)
  , maybe "aws/absent" (const "aws/present") (evidenceAwsScope scope)
  , maybe "" accountText (evidenceAwsScope scope)
  , maybe "" regionText (evidenceAwsScope scope)
  , Text.pack (show (evidenceLifecycleOperation scope))
  ]

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

accountText :: AwsScope -> Text
accountText (AwsScope (AwsAccountId value) _) = value

regionText :: AwsScope -> Text
regionText (AwsScope _ (AwsRegion value)) = value

lifecycleOperationTag :: LifecycleOperation -> Int
lifecycleOperationTag operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

checkpointProvenanceText :: CheckpointProvenance -> Text
checkpointProvenanceText (CheckpointProvenance value) = value

checkpointVersionText :: CheckpointVersion -> Text
checkpointVersionText (CheckpointVersion value) = value

manifestProvenanceText :: OwnershipManifestProvenance -> Text
manifestProvenanceText (OwnershipManifestProvenance value) = value

manifestVersionText :: OwnershipManifestVersion -> Text
manifestVersionText (OwnershipManifestVersion value) = value
