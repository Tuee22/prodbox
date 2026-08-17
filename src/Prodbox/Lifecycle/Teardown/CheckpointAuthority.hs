{-# LANGUAGE OverloadedStrings #-}

-- | Stable, exact admission of cleanup checkpoint mutations through the
-- retained Lifecycle Authority.  A cleanup node never constructs an
-- Authority 'OperationId' and never allocates a fresh retry key: the complete
-- target/scope/reference request is deterministically bound to its durable
-- 'CleanupOperationId'.
module Prodbox.Lifecycle.Teardown.CheckpointAuthority
  ( CheckpointAuthorityPurpose (..)
  , CheckpointAuthorityOperation
  , checkpointAuthorityCleanupOperationId
  , checkpointAuthorityResourceKey
  , checkpointAuthorityCoordinateDigest
  , checkpointAuthorityScope
  , checkpointAuthorityPurpose
  , checkpointAuthorityExpectedReference
  , checkpointAuthoritySubmissionKey
  , checkpointAuthorityRequestDigest
  , checkpointAuthorityOperationId
  , ObservedCheckpointAuthorityOperation
  , observedCheckpointAuthorityOperationId
  , observedCheckpointAuthorityOperationStatus
  , observeCheckpointAuthorityOperation
  , bindObservedCheckpointAuthorityOperation
  , prepareCheckpointAuthorityOperation
  , admitCheckpointAuthorityOperation
  , CheckpointAuthorityError (..)
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.ControlPlane.AuthorityOperationClient
  ( AuthorityOperationAdmission (..)
  , AuthorityOperationClient (..)
  , AuthorityOperationClientError (..)
  , AuthorityOperationObservation (..)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , ClientSubmissionKeyError
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.PulumiCheckpointRegistry
  ( VerifiedPulumiCheckpointRef
  , verifiedPulumiCheckpointBackupVersion
  , verifiedPulumiCheckpointCiphertextDigest
  , verifiedPulumiCheckpointDigest
  , verifiedPulumiCheckpointPrimaryVersion
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (..)
  , SubmissionStatus
  , operationIdDigest
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( pulumiCheckpointDigestText
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry

data CheckpointAuthorityPurpose
  = CheckpointPrimaryRestore
  | CheckpointReferenceRetirement
  deriving (Bounded, Enum, Eq, Ord, Show)

data CheckpointAuthorityOperation = CheckpointAuthorityOperation
  { internalCheckpointAuthorityCleanupOperationId :: !CleanupOperationId
  , internalCheckpointAuthorityResourceKey :: !RegisteredResourceKey
  , internalCheckpointAuthorityCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalCheckpointAuthorityScope :: !ObservationEvidenceScope
  , internalCheckpointAuthorityPurpose :: !CheckpointAuthorityPurpose
  , internalCheckpointAuthorityExpectedReference
      :: !(Maybe VerifiedPulumiCheckpointRef)
  , internalCheckpointAuthoritySubmissionKey :: !ClientSubmissionKey
  , internalCheckpointAuthorityRequestDigest :: !RequestDigest
  , internalCheckpointAuthorityOperationId :: !(Maybe OperationId)
  }
  deriving (Eq, Show)

checkpointAuthorityCleanupOperationId
  :: CheckpointAuthorityOperation -> CleanupOperationId
checkpointAuthorityCleanupOperationId =
  internalCheckpointAuthorityCleanupOperationId

checkpointAuthorityResourceKey
  :: CheckpointAuthorityOperation -> RegisteredResourceKey
checkpointAuthorityResourceKey = internalCheckpointAuthorityResourceKey

checkpointAuthorityCoordinateDigest
  :: CheckpointAuthorityOperation -> ManagedResourceCoordinateDigest
checkpointAuthorityCoordinateDigest =
  internalCheckpointAuthorityCoordinateDigest

checkpointAuthorityScope
  :: CheckpointAuthorityOperation -> ObservationEvidenceScope
checkpointAuthorityScope = internalCheckpointAuthorityScope

checkpointAuthorityPurpose
  :: CheckpointAuthorityOperation -> CheckpointAuthorityPurpose
checkpointAuthorityPurpose = internalCheckpointAuthorityPurpose

checkpointAuthorityExpectedReference
  :: CheckpointAuthorityOperation -> Maybe VerifiedPulumiCheckpointRef
checkpointAuthorityExpectedReference =
  internalCheckpointAuthorityExpectedReference

checkpointAuthoritySubmissionKey
  :: CheckpointAuthorityOperation -> ClientSubmissionKey
checkpointAuthoritySubmissionKey = internalCheckpointAuthoritySubmissionKey

checkpointAuthorityRequestDigest
  :: CheckpointAuthorityOperation -> RequestDigest
checkpointAuthorityRequestDigest = internalCheckpointAuthorityRequestDigest

checkpointAuthorityOperationId
  :: CheckpointAuthorityOperation -> Maybe OperationId
checkpointAuthorityOperationId = internalCheckpointAuthorityOperationId

-- | Identity recovered from the Authority's durable submission-key index.
-- The exact checkpoint reference is deliberately absent until an independent
-- checkpoint read-back returns the reference retained in the operation phase.
data ObservedCheckpointAuthorityOperation = ObservedCheckpointAuthorityOperation
  { internalObservedCheckpointAuthorityCleanupOperationId :: !CleanupOperationId
  , internalObservedCheckpointAuthorityResourceKey :: !RegisteredResourceKey
  , internalObservedCheckpointAuthorityCoordinateDigest
      :: !ManagedResourceCoordinateDigest
  , internalObservedCheckpointAuthorityScope :: !ObservationEvidenceScope
  , internalObservedCheckpointAuthorityPurpose :: !CheckpointAuthorityPurpose
  , internalObservedCheckpointAuthoritySubmissionKey :: !ClientSubmissionKey
  , internalObservedCheckpointAuthorityOperationId :: !OperationId
  , internalObservedCheckpointAuthorityOperationStatus :: !SubmissionStatus
  }
  deriving (Eq, Show)

observedCheckpointAuthorityOperationId
  :: ObservedCheckpointAuthorityOperation -> OperationId
observedCheckpointAuthorityOperationId =
  internalObservedCheckpointAuthorityOperationId

observedCheckpointAuthorityOperationStatus
  :: ObservedCheckpointAuthorityOperation -> SubmissionStatus
observedCheckpointAuthorityOperationStatus =
  internalObservedCheckpointAuthorityOperationStatus

data CheckpointAuthorityError
  = CheckpointAuthorityResourceUnregistered !RegisteredResourceKey
  | CheckpointAuthorityResourceNotStack !RegisteredResourceKey !ResourceKind
  | CheckpointAuthoritySurfaceNotAllowed !RegisteredResourceKey !CleanupSurface
  | CheckpointAuthorityScopeOperationInvalid !LifecycleOperation
  | CheckpointAuthorityRegistryRevisionMismatch
      !RegistryRevision
      !RegistryRevision
  | CheckpointAuthorityAwsScopeRequired !RegisteredResourceKey
  | CheckpointAuthorityRestoreReferenceRequired
  | CheckpointAuthoritySubmissionKeyInvalid !ClientSubmissionKeyError
  | CheckpointAuthorityAdmissionRefused !AuthorityOperationClientError
  | CheckpointAuthorityAdmissionUnavailable !AuthorityOperationClientError
  | CheckpointAuthorityOperationUnknown !ClientSubmissionKey
  | CheckpointAuthorityObservationRefused !AuthorityOperationClientError
  | CheckpointAuthorityObservationUnavailable !AuthorityOperationClientError
  | CheckpointAuthorityObservedBindingMismatch
  | CheckpointAuthorityObservedDigestMismatch !RequestDigest !RequestDigest
  deriving (Eq, Show)

data CheckpointAuthorityBinding = CheckpointAuthorityBinding
  { checkpointAuthorityBindingCleanupOperationId :: !CleanupOperationId
  , checkpointAuthorityBindingResourceKey :: !RegisteredResourceKey
  , checkpointAuthorityBindingCoordinateDigest :: !ManagedResourceCoordinateDigest
  , checkpointAuthorityBindingScope :: !ObservationEvidenceScope
  , checkpointAuthorityBindingPurpose :: !CheckpointAuthorityPurpose
  , checkpointAuthorityBindingSubmissionKey :: !ClientSubmissionKey
  }

prepareCheckpointAuthorityOperation
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> Maybe VerifiedPulumiCheckpointRef
  -> Either CheckpointAuthorityError CheckpointAuthorityOperation
prepareCheckpointAuthorityOperation
  cleanupOperation
  resourceKey
  scope
  purpose
  expectedReference = do
    binding <-
      prepareCheckpointAuthorityBinding
        cleanupOperation
        resourceKey
        scope
        purpose
    case (purpose, expectedReference) of
      (CheckpointPrimaryRestore, Nothing) ->
        Left CheckpointAuthorityRestoreReferenceRequired
      _ -> Right ()
    let canonical =
          checkpointAuthorityCanonicalRequest
            cleanupOperation
            resourceKey
            (checkpointAuthorityBindingCoordinateDigest binding)
            scope
            purpose
            expectedReference
        digest = sha256Text canonical
    Right
      CheckpointAuthorityOperation
        { internalCheckpointAuthorityCleanupOperationId = cleanupOperation
        , internalCheckpointAuthorityResourceKey = resourceKey
        , internalCheckpointAuthorityCoordinateDigest =
            checkpointAuthorityBindingCoordinateDigest binding
        , internalCheckpointAuthorityScope = scope
        , internalCheckpointAuthorityPurpose = purpose
        , internalCheckpointAuthorityExpectedReference = expectedReference
        , internalCheckpointAuthoritySubmissionKey =
            checkpointAuthorityBindingSubmissionKey binding
        , internalCheckpointAuthorityRequestDigest = RequestDigest ("sha256:" <> digest)
        , internalCheckpointAuthorityOperationId = Nothing
        }

prepareCheckpointAuthorityBinding
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> Either CheckpointAuthorityError CheckpointAuthorityBinding
prepareCheckpointAuthorityBinding cleanupOperation resourceKey scope purpose = do
  identity <- case lookupRegisteredIdentity resourceKey of
    Nothing -> Left (CheckpointAuthorityResourceUnregistered resourceKey)
    Just value -> Right value
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( CheckpointAuthorityResourceNotStack
            resourceKey
            (registeredIdentityKind identity)
        )
  if cleanupSurfaceAllows (evidenceCleanupSurface scope) identity
    then Right ()
    else
      Left
        ( CheckpointAuthoritySurfaceNotAllowed
            resourceKey
            (evidenceCleanupSurface scope)
        )
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( CheckpointAuthorityScopeOperationInvalid
            (evidenceLifecycleOperation scope)
        )
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( CheckpointAuthorityRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  case evidenceAwsScope scope of
    Nothing -> Left (CheckpointAuthorityAwsScopeRequired resourceKey)
    Just _ -> Right ()
  let coordinateDigest = registeredIdentityCoordinateDigest identity
      stableIdentity =
        checkpointAuthorityCanonicalIdentity
          cleanupOperation
          resourceKey
          coordinateDigest
          scope
          purpose
      identityDigest = sha256Text stableIdentity
  submissionKey <-
    either
      (Left . CheckpointAuthoritySubmissionKeyInvalid)
      Right
      (mkClientSubmissionKey ("cleanup-checkpoint:" <> identityDigest))
  Right
    CheckpointAuthorityBinding
      { checkpointAuthorityBindingCleanupOperationId = cleanupOperation
      , checkpointAuthorityBindingResourceKey = resourceKey
      , checkpointAuthorityBindingCoordinateDigest = coordinateDigest
      , checkpointAuthorityBindingScope = scope
      , checkpointAuthorityBindingPurpose = purpose
      , checkpointAuthorityBindingSubmissionKey = submissionKey
      }

observeCheckpointAuthorityOperation
  :: (Monad m)
  => AuthorityOperationClient m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> m (Either CheckpointAuthorityError ObservedCheckpointAuthorityOperation)
observeCheckpointAuthorityOperation client cleanupOperation resourceKey scope purpose =
  case prepareCheckpointAuthorityBinding cleanupOperation resourceKey scope purpose of
    Left err -> pure (Left err)
    Right binding -> do
      observed <-
        observeAuthorityOperation
          client
          (checkpointAuthorityBindingSubmissionKey binding)
      pure $ case observed of
        Left err -> Left (classifyObservationError err)
        Right Nothing ->
          Left
            ( CheckpointAuthorityOperationUnknown
                (checkpointAuthorityBindingSubmissionKey binding)
            )
        Right (Just observation) ->
          Right
            ObservedCheckpointAuthorityOperation
              { internalObservedCheckpointAuthorityCleanupOperationId =
                  checkpointAuthorityBindingCleanupOperationId binding
              , internalObservedCheckpointAuthorityResourceKey =
                  checkpointAuthorityBindingResourceKey binding
              , internalObservedCheckpointAuthorityCoordinateDigest =
                  checkpointAuthorityBindingCoordinateDigest binding
              , internalObservedCheckpointAuthorityScope =
                  checkpointAuthorityBindingScope binding
              , internalObservedCheckpointAuthorityPurpose =
                  checkpointAuthorityBindingPurpose binding
              , internalObservedCheckpointAuthoritySubmissionKey =
                  checkpointAuthorityBindingSubmissionKey binding
              , internalObservedCheckpointAuthorityOperationId =
                  authorityOperationObservedId observation
              , internalObservedCheckpointAuthorityOperationStatus =
                  authorityOperationObservedStatus observation
              }

-- | Seal a recovered operation only after the checkpoint endpoint has
-- independently returned the exact reference retained by the Authority.  The
-- operation digest must match the original full request, including that
-- reference; observing a stable key alone is never mutation or completion
-- authority.
bindObservedCheckpointAuthorityOperation
  :: ObservedCheckpointAuthorityOperation
  -> Maybe VerifiedPulumiCheckpointRef
  -> Either CheckpointAuthorityError CheckpointAuthorityOperation
bindObservedCheckpointAuthorityOperation observed expectedReference = do
  prepared <-
    prepareCheckpointAuthorityOperation
      (internalObservedCheckpointAuthorityCleanupOperationId observed)
      (internalObservedCheckpointAuthorityResourceKey observed)
      (internalObservedCheckpointAuthorityScope observed)
      (internalObservedCheckpointAuthorityPurpose observed)
      expectedReference
  if checkpointAuthoritySubmissionKey prepared
    == internalObservedCheckpointAuthoritySubmissionKey observed
    && checkpointAuthorityCoordinateDigest prepared
      == internalObservedCheckpointAuthorityCoordinateDigest observed
    then Right ()
    else Left CheckpointAuthorityObservedBindingMismatch
  let actualDigest =
        operationIdDigest
          (internalObservedCheckpointAuthorityOperationId observed)
      expectedDigest = checkpointAuthorityRequestDigest prepared
  if actualDigest == expectedDigest
    then
      Right
        ( withOperationId
            (internalObservedCheckpointAuthorityOperationId observed)
            prepared
        )
    else
      Left
        ( CheckpointAuthorityObservedDigestMismatch
            expectedDigest
            actualDigest
        )

admitCheckpointAuthorityOperation
  :: (Monad m)
  => AuthorityOperationClient m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> Maybe VerifiedPulumiCheckpointRef
  -> m (Either CheckpointAuthorityError CheckpointAuthorityOperation)
admitCheckpointAuthorityOperation
  client
  cleanupOperation
  resourceKey
  scope
  purpose
  expectedReference =
    case prepareCheckpointAuthorityOperation
      cleanupOperation
      resourceKey
      scope
      purpose
      expectedReference of
      Left err -> pure (Left err)
      Right prepared -> do
        admitted <-
          submitAuthorityOperation
            client
            (checkpointAuthoritySubmissionKey prepared)
            (checkpointAuthorityRequestDigest prepared)
        pure $ case admitted of
          Left err -> Left (classifyAdmissionError err)
          Right (AuthorityOperationAdmissionAccepted operation) ->
            Right (withOperationId operation prepared)
          Right (AuthorityOperationAdmissionDuplicate operation) ->
            Right (withOperationId operation prepared)

withOperationId
  :: OperationId
  -> CheckpointAuthorityOperation
  -> CheckpointAuthorityOperation
withOperationId operation prepared =
  prepared {internalCheckpointAuthorityOperationId = Just operation}

classifyAdmissionError
  :: AuthorityOperationClientError -> CheckpointAuthorityError
classifyAdmissionError err = case err of
  AuthorityOperationRemoteRefused status _
    | status < 500 -> CheckpointAuthorityAdmissionRefused err
  AuthorityOperationTransportFailed _ ->
    CheckpointAuthorityAdmissionUnavailable err
  AuthorityOperationResponseInvalid _ ->
    CheckpointAuthorityAdmissionUnavailable err
  AuthorityOperationResponseStatusMismatch _ ->
    CheckpointAuthorityAdmissionUnavailable err
  AuthorityOperationResponseDigestMismatch ->
    CheckpointAuthorityAdmissionUnavailable err
  AuthorityOperationResponseShapeMismatch _ ->
    CheckpointAuthorityAdmissionUnavailable err
  AuthorityOperationRemoteRefused _ _ ->
    CheckpointAuthorityAdmissionUnavailable err

classifyObservationError
  :: AuthorityOperationClientError -> CheckpointAuthorityError
classifyObservationError err = case err of
  AuthorityOperationRemoteRefused status _
    | status < 500 -> CheckpointAuthorityObservationRefused err
  AuthorityOperationTransportFailed _ ->
    CheckpointAuthorityObservationUnavailable err
  AuthorityOperationResponseInvalid _ ->
    CheckpointAuthorityObservationUnavailable err
  AuthorityOperationResponseStatusMismatch _ ->
    CheckpointAuthorityObservationUnavailable err
  AuthorityOperationResponseDigestMismatch ->
    CheckpointAuthorityObservationUnavailable err
  AuthorityOperationResponseShapeMismatch _ ->
    CheckpointAuthorityObservationUnavailable err
  AuthorityOperationRemoteRefused _ _ ->
    CheckpointAuthorityObservationUnavailable err

checkpointAuthorityCanonicalIdentity
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ManagedResourceCoordinateDigest
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> Text
checkpointAuthorityCanonicalIdentity cleanupOperation resourceKey coordinateDigest scope purpose =
  canonicalFields
    ( [ "cleanup-checkpoint-identity/v2"
      , cleanupOperationIdText cleanupOperation
      , registeredResourceKeyText resourceKey
      , managedResourceCoordinateDigestText coordinateDigest
      , purposeText purpose
      ]
        <> scopeFields scope
    )

checkpointAuthorityCanonicalRequest
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ManagedResourceCoordinateDigest
  -> ObservationEvidenceScope
  -> CheckpointAuthorityPurpose
  -> Maybe VerifiedPulumiCheckpointRef
  -> Text
checkpointAuthorityCanonicalRequest
  cleanupOperation
  resourceKey
  coordinateDigest
  scope
  purpose
  expectedReference =
    canonicalFields
      ( [ "cleanup-checkpoint-operation/v2"
        , cleanupOperationIdText cleanupOperation
        , registeredResourceKeyText resourceKey
        , managedResourceCoordinateDigestText coordinateDigest
        , purposeText purpose
        ]
          <> scopeFields scope
          <> maybe ["reference/none"] referenceFields expectedReference
      )

purposeText :: CheckpointAuthorityPurpose -> Text
purposeText purpose = case purpose of
  CheckpointPrimaryRestore -> "primary-restore"
  CheckpointReferenceRetirement -> "reference-retirement"

scopeFields :: ObservationEvidenceScope -> [Text]
scopeFields scope =
  [ "scope/v1"
  , cleanupSurfaceText (evidenceCleanupSurface scope)
  , registryRevisionText (evidenceRegistryRevision scope)
  , runScopeText (evidenceDurableRunScope scope)
  , foundationText (evidenceLinuxRke2Foundation scope)
  ]
    <> awsScopeFields (evidenceAwsScope scope)
    <> [lifecycleOperationText (evidenceLifecycleOperation scope)]

cleanupSurfaceText :: CleanupSurface -> Text
cleanupSurfaceText surface = case surface of
  LocalOnly -> "local-only"
  Cascade -> "cascade"
  ExplicitPerRun -> "explicit-per-run"
  OperationalTeardown -> "operational-teardown"
  ExplicitLongLived -> "explicit-long-lived"
  TotalDecommission -> "total-decommission"

lifecycleOperationText :: LifecycleOperation -> Text
lifecycleOperationText operation = case operation of
  ReconcileDesiredAbsent -> "reconcile-desired-absent"
  ReconcileDesiredPresent -> "reconcile-desired-present"
  RunTerminalEscapeAudit -> "run-terminal-escape-audit"

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision value) = value

runScopeText :: DurableObservationRunScope -> Text
runScopeText (DurableObservationRunScope value) = value

foundationText :: LinuxRke2FoundationId -> Text
foundationText (LinuxRke2FoundationId value) = value

awsScopeFields :: Maybe AwsScope -> [Text]
awsScopeFields maybeAwsScope = case maybeAwsScope of
  Nothing -> ["aws-scope/none"]
  Just awsScope ->
    [ "aws-scope/some"
    , accountText (awsScopeAccountId awsScope)
    , regionText (awsScopeRegion awsScope)
    ]

accountText :: AwsAccountId -> Text
accountText (AwsAccountId value) = value

regionText :: AwsRegion -> Text
regionText (AwsRegion value) = value

referenceFields :: VerifiedPulumiCheckpointRef -> [Text]
referenceFields reference =
  [ "reference/some"
  , pulumiCheckpointDigestText (verifiedPulumiCheckpointDigest reference)
  , verifiedPulumiCheckpointCiphertextDigest reference
  , verifiedPulumiCheckpointPrimaryVersion reference
  , verifiedPulumiCheckpointBackupVersion reference
  ]

-- | A length-prefixed tuple remains injective even when a validated identity
-- intentionally permits separators or control characters.  The tuple is
-- hashed but never parsed at runtime; this encoding prevents two distinct
-- scope/reference bindings from sharing a request digest before hashing.
canonicalFields :: [Text] -> Text
canonicalFields =
  Text.concat
    . map
      ( \field ->
          Text.pack (show (Text.length field))
            <> ":"
            <> field
      )

sha256Text :: Text -> Text
sha256Text =
  Text.pack
    . concatMap renderHexByte
    . ByteString.unpack
    . SHA256.hash
    . TextEncoding.encodeUtf8
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits
