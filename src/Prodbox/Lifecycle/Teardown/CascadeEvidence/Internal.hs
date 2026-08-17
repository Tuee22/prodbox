{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure proof boundary around the destructive half of cascade teardown.
-- Provider absence, credential disposition, the retained-set audit, the
-- pre-uninstall report, and the one-shot local permit remain distinct inputs.
-- The private readiness and completion constructors bind them to one compiled
-- run before local RKE2 absence can enter completion.
module Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( CascadeReportDigest
  , mkCascadeReportDigest
  , cascadeReportDigestText
  , LocalCompletionPermitId
  , mkLocalCompletionPermitId
  , localCompletionPermitIdText
  , CascadeCredentialDispositionResult (..)
  , CascadeCredentialDispositionObservation (..)
  , CascadePreUninstallReportObservation (..)
  , CascadeLocalOperationReferences (..)
  , cascadeLocalOperationReferences
  , LocalCompletionPermitGrant (..)
  , CascadeCompletionReceiptObservation (..)
  , CascadeEvidenceComponent (..)
  , CascadeEvidenceError (..)
  , CascadeAbsenceEvidence
  , mkCascadeAbsenceEvidence
  , CascadeCredentialDispositionEvidence
  , mkCascadeCredentialDispositionEvidence
  , CascadeTerminalAuditEvidence
  , cascadeIntentionallyRetainedProjectionDigest
  , mkCascadeTerminalAuditEvidence
  , CascadePreUninstallReportEvidence
  , mkCascadePreUninstallReportEvidence
  , LocalCompletionPermit
  , bindLocalCompletionPermit
  , ReadyToUninstallEvidence
  , readyToUninstallRunId
  , readyToUninstallGraphDigest
  , readyToUninstallScope
  , readyToUninstallReportDigest
  , readyToUninstallPermitId
  , readyToUninstallOperationReferences
  , mkReadyToUninstallEvidence
  , ReadyToUninstallBindingObservation
  , readyBindingObservationRunId
  , readyBindingObservationGraphDigest
  , readyBindingObservationScope
  , readyBindingObservationReportDigest
  , readyBindingObservationPermitId
  , readyBindingObservationOperationReferences
  , DurableReadyToUninstallBinding
  , maximumDurableReadyToUninstallBindingBytes
  , captureDurableReadyToUninstallBinding
  , observeDurableReadyToUninstallBinding
  , encodeDurableReadyToUninstallBinding
  , decodeDurableReadyToUninstallBinding
  , restoreReadyToUninstallEvidence
  , LocalUninstallEvidence
  , localUninstallAbsenceEvidence
  , mkLocalUninstallEvidence
  , CascadeCompleteEvidence
  , cascadeCompleteRunId
  , cascadeCompleteGraphDigest
  , cascadeCompleteReportDigest
  , cascadeCompletePermitId
  , mkCascadeCompleteEvidence
  , CascadeEvidenceRegression
  , fixedCascadeEvidenceRegression
  , cascadeEvidenceRegressionCompleteChain
  , cascadeEvidenceRegressionAbsenceRefused
  , cascadeEvidenceRegressionCredentialRefused
  , cascadeEvidenceRegressionAuditRefused
  , cascadeEvidenceRegressionPreUninstallRefused
  , cascadeEvidenceRegressionPermitRefused
  , cascadeEvidenceRegressionMixedBindingRefused
  , cascadeEvidenceRegressionLocalAbsenceRefused
  , cascadeEvidenceRegressionCompletionRefused
  , cascadeEvidenceRegressionDurableReadyCanonical
  , cascadeEvidenceRegressionDurableReadyCorruptionRefused
  , withFixedCascadeEvidenceFixtureInternal
  , withCascadeEvidenceFixtureForRunInternal
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (find, nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.AwsInventory
  ( AwsInventory
  , AwsResource
  , awsInventoryResources
  , awsResourceScope
  , normalizeAwsTagRows
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRun (cleanupRunGraph, cleanupRunGraphDigest, cleanupRunId)
  , CleanupRunId
  , cleanupGraphDigest
  , cleanupGraphNodes
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupNodeOperationId
  , cleanupOperationIdText
  , cleanupRunIdText
  , mkCleanupOperationId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry

newtype CascadeReportDigest = CascadeReportDigest Text
  deriving (Eq, Ord, Show)

mkCascadeReportDigest :: Text -> Either Text CascadeReportDigest
mkCascadeReportDigest raw
  | Text.length raw == 64 && Text.all isLowerHex raw =
      Right (CascadeReportDigest raw)
  | otherwise =
      Left "cascade report digest must contain exactly 64 lowercase hexadecimal characters"
 where
  isLowerHex character = character `elem` ("0123456789abcdef" :: String)

cascadeReportDigestText :: CascadeReportDigest -> Text
cascadeReportDigestText (CascadeReportDigest digest) = digest

newtype LocalCompletionPermitId = LocalCompletionPermitId Text
  deriving (Eq, Ord, Show)

mkLocalCompletionPermitId :: Text -> Either Text LocalCompletionPermitId
mkLocalCompletionPermitId raw
  | Text.null raw = Left "local completion permit ID must not be empty"
  | Text.length raw > 160 = Left "local completion permit ID exceeds 160 characters"
  | Text.any (not . validIdentityCharacter) raw =
      Left "local completion permit ID contains an invalid character"
  | otherwise = Right (LocalCompletionPermitId raw)
 where
  validIdentityCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || (isAscii character && isDigit character)
      || character `elem` ("-._:/" :: String)

localCompletionPermitIdText :: LocalCompletionPermitId -> Text
localCompletionPermitIdText (LocalCompletionPermitId permitId) = permitId

data CascadeCredentialDispositionResult
  = CascadeCredentialsDisposed
  | CascadeCredentialsOutstanding !(NonEmpty ObservedResourceIdentity)
  | CascadeCredentialDispositionUnobservable !(NonEmpty ObservationFailure)
  deriving (Eq, Show)

-- | Package-private adapter observation.  Only the lifecycle-owned Authority
-- interpreter may turn decoded fields into an opaque disposition proof.
data CascadeCredentialDispositionObservation
  = CascadeCredentialDispositionObservation
  { cascadeCredentialDispositionScope :: !ObservationEvidenceScope
  , cascadeCredentialDispositionResult :: !CascadeCredentialDispositionResult
  }
  deriving (Eq, Show)

data CascadePreUninstallReportObservation
  = CascadePreUninstallReportObservation
  { cascadePreUninstallReportDigest :: !CascadeReportDigest
  , cascadePreUninstallReportReceipt :: !DurableReceiptObservation
  }
  deriving (Eq, Show)

data CascadeLocalOperationReferences = CascadeLocalOperationReferences
  { cascadeLocalUninstallOperationId :: !CleanupOperationId
  , cascadeLocalCompletionOperationId :: !CleanupOperationId
  }
  deriving (Eq, Show)

-- | An authority grant is a flat external value.  Binding it produces the
-- opaque permit consumed by the readiness proof.
data LocalCompletionPermitGrant = LocalCompletionPermitGrant
  { localCompletionGrantPermitId :: !LocalCompletionPermitId
  , localCompletionGrantRunId :: !CleanupRunId
  , localCompletionGrantScope :: !ObservationEvidenceScope
  , localCompletionGrantGraphDigest :: !CleanupDigest
  , localCompletionGrantReportDigest :: !CascadeReportDigest
  , localCompletionGrantOperationReferences :: !CascadeLocalOperationReferences
  }
  deriving (Eq, Show)

data CascadeCompletionReceiptObservation
  = CascadeCompletionReceiptObservation
  { cascadeCompletionReceiptPermitId :: !LocalCompletionPermitId
  , cascadeCompletionReceiptReportDigest :: !CascadeReportDigest
  , cascadeCompletionReceipt :: !DurableReceiptObservation
  }
  deriving (Eq, Show)

data CascadeEvidenceComponent
  = CascadeAbsenceComponent
  | CascadeCredentialDispositionComponent
  | CascadeTerminalAuditComponent
  | CascadePreUninstallReportComponent
  | CascadeLocalCompletionPermitComponent
  deriving (Eq, Show)

data CascadeEvidenceError
  = CascadeCompiledOperationMismatch !LifecycleOperation
  | CascadeCompiledRegistryRevisionMismatch !RegistryRevision !RegistryRevision
  | CascadeCompiledRunScopeMismatch
      !DurableObservationRunScope
      !DurableObservationRunScope
  | CascadeCompiledAwsScopeMissing
  | CascadeAbsenceKeySetMismatch
      ![RegisteredResourceKey]
      ![RegisteredResourceKey]
  | CascadeAbsenceScopeMismatch
      !RegisteredResourceKey
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeResourceStillPresent !RegisteredResourceKey
  | CascadeResourceObservationPartial
      !RegisteredResourceKey
      !PartialEvidence
      !(NonEmpty ObservationFailure)
  | CascadeResourceUnobservable
      !RegisteredResourceKey
      !(NonEmpty ObservationFailure)
  | CascadeCredentialScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeCredentialsRemain !(NonEmpty ObservedResourceIdentity)
  | CascadeCredentialsUnobservable !(NonEmpty ObservationFailure)
  | CascadeTerminalAuditScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeTerminalAuditRetainedProjectionMismatch
      !TerminalAuditRetainedSetDigest
      !TerminalAuditRetainedSetDigest
  | CascadeTerminalAuditFoundEscapes !(NonEmpty AwsResource)
  | CascadeTerminalAuditUnobservable !(NonEmpty ObservationFailure)
  | CascadeTerminalAuditInventoryScopeMismatch !AwsScope !AwsScope
  | CascadeReceiptKindMismatch !DurableReceiptKind !DurableReceiptKind
  | CascadeReceiptScopeMismatch
      !DurableReceiptKind
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeReceiptGraphDigestMismatch
      !DurableReceiptKind
      !CleanupDigest
      !CleanupDigest
  | CascadeReceiptNotObserved
      !DurableReceiptKind
      !DurableReceiptObservationResult
  | CascadeLocalOperationMissing !Text
  | CascadeLocalOperationDuplicated !Text
  | CascadeLocalOperationPlanMissing !CleanupNodeId
  | CascadePermitRunMismatch !CleanupRunId !CleanupRunId
  | CascadePermitScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadePermitGraphDigestMismatch !CleanupDigest !CleanupDigest
  | CascadePermitOperationReferencesMismatch
      !CascadeLocalOperationReferences
      !CascadeLocalOperationReferences
  | CascadeEvidenceBindingMismatch !CascadeEvidenceComponent
  | CascadeReadyReportDigestMismatch !CascadeReportDigest !CascadeReportDigest
  | CascadeReadyBindingEncodedTooLarge !Int !Int
  | CascadeReadyBindingDecodeInvalid !Text
  | CascadeReadyBindingUnsupportedVersion !Word16
  | CascadeReadyBindingNonCanonical
  | CascadeReadyBindingRunMismatch !CleanupRunId !CleanupRunId
  | CascadeReadyBindingGraphMismatch !CleanupDigest !CleanupDigest
  | CascadeReadyBindingSurfaceMismatch !CleanupSurface
  | CascadeReadyBindingScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeReadyBindingOperationReferencesMismatch
      !CascadeLocalOperationReferences
      !CascadeLocalOperationReferences
  | CascadeLocalAbsenceScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | CascadeLocalFoundationStillPresent
  | CascadeLocalFoundationUnobservable !ObservationFailure
  | CascadeLocalAbsenceReadinessMismatch
  | CascadeCompletionPermitMismatch
      !LocalCompletionPermitId
      !LocalCompletionPermitId
  | CascadeCompletionReportDigestMismatch
      !CascadeReportDigest
      !CascadeReportDigest
  deriving (Eq, Show)

data CascadeProofBinding = CascadeProofBinding
  { internalCascadeBindingRunId :: !CleanupRunId
  , internalCascadeBindingGraphDigest :: !CleanupDigest
  , internalCascadeBindingScope :: !ObservationEvidenceScope
  }
  deriving (Eq, Show)

data CascadeAbsenceEvidence = CascadeAbsenceEvidence !CascadeProofBinding
  deriving (Eq, Show)

mkCascadeAbsenceEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CompleteObservationSet
  -> Either CascadeEvidenceError CascadeAbsenceEvidence
mkCascadeAbsenceEvidence compiled observations = do
  binding <- cascadeProofBinding compiled
  let expectedKeys = cascadeExpectedAbsenceKeys compiled
      actualKeys = sort (completeObservationSetKeys observations)
  if actualKeys == expectedKeys
    then Right ()
    else Left (CascadeAbsenceKeySetMismatch expectedKeys actualKeys)
  mapM_ (validateObservation binding) (completeObservationSetObservations observations)
  Right (CascadeAbsenceEvidence binding)
 where
  validateObservation binding observation
    | exactObservationEvidenceScope observation /= internalCascadeBindingScope binding =
        Left
          ( CascadeAbsenceScopeMismatch
              (exactObservationResourceKey observation)
              (internalCascadeBindingScope binding)
              (exactObservationEvidenceScope observation)
          )
    | otherwise = case exactObservationResult observation of
        ExactResourceAbsent _ -> Right ()
        ExactResourcePresent _ ->
          Left (CascadeResourceStillPresent (exactObservationResourceKey observation))
        ExactResourcePartial partial failures ->
          Left
            ( CascadeResourceObservationPartial
                (exactObservationResourceKey observation)
                partial
                failures
            )
        ExactResourceUnobservable failures ->
          Left
            ( CascadeResourceUnobservable
                (exactObservationResourceKey observation)
                failures
            )

data CascadeCredentialDispositionEvidence
  = CascadeCredentialDispositionEvidence !CascadeProofBinding
  deriving (Eq, Show)

mkCascadeCredentialDispositionEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeCredentialDispositionObservation
  -> Either CascadeEvidenceError CascadeCredentialDispositionEvidence
mkCascadeCredentialDispositionEvidence compiled observation = do
  binding <- cascadeProofBinding compiled
  if cascadeCredentialDispositionScope observation == internalCascadeBindingScope binding
    then Right ()
    else
      Left
        ( CascadeCredentialScopeMismatch
            (internalCascadeBindingScope binding)
            (cascadeCredentialDispositionScope observation)
        )
  case cascadeCredentialDispositionResult observation of
    CascadeCredentialsDisposed ->
      Right (CascadeCredentialDispositionEvidence binding)
    CascadeCredentialsOutstanding identities ->
      Left (CascadeCredentialsRemain identities)
    CascadeCredentialDispositionUnobservable failures ->
      Left (CascadeCredentialsUnobservable failures)

data CascadeTerminalAuditEvidence
  = CascadeTerminalAuditEvidence !CascadeProofBinding
  deriving (Eq, Show)

cascadeIntentionallyRetainedProjectionDigest
  :: TerminalAuditRetainedSetDigest
cascadeIntentionallyRetainedProjectionDigest =
  TerminalAuditRetainedSetDigest
    ( TextEncoding.decodeUtf8
        (hexSha256 (TextEncoding.encodeUtf8 canonicalProjection))
    )
 where
  retainedTargets = cleanupTargetsForSurface ExplicitLongLivedSurface
  canonicalProjection =
    Text.intercalate
      "\NUL"
      ( "cascade-intentionally-retained/v1"
          : registryRevisionText lifecycleRegistryRevision
          : [ registeredResourceKeyText (cleanupTargetKey target)
                <> ":"
                <> managedResourceCoordinateDigestText
                  (cleanupTargetCoordinateDigest target)
            | target <- retainedTargets
            ]
      )

mkCascadeTerminalAuditEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> TerminalAuditObservation 'Cascade
  -> Either CascadeEvidenceError CascadeTerminalAuditEvidence
mkCascadeTerminalAuditEvidence compiled observation = do
  binding <- cascadeProofBinding compiled
  let observedAuditScope = terminalAuditScope observation
      expectedScope = cascadeAuditScope (internalCascadeBindingScope binding)
      actualScope = terminalAuditEvidenceScope observedAuditScope
  if actualScope == expectedScope
    then Right ()
    else Left (CascadeTerminalAuditScopeMismatch expectedScope actualScope)
  let actualRetainedDigest = terminalAuditRetainedSetDigest observedAuditScope
  if actualRetainedDigest == cascadeIntentionallyRetainedProjectionDigest
    then Right ()
    else
      Left
        ( CascadeTerminalAuditRetainedProjectionMismatch
            cascadeIntentionallyRetainedProjectionDigest
            actualRetainedDigest
        )
  case terminalAuditResult observation of
    TerminalAuditConfirmedClean inventory -> do
      expectedAwsScope <- case evidenceAwsScope (internalCascadeBindingScope binding) of
        Nothing -> Left CascadeCompiledAwsScopeMissing
        Just scope -> Right scope
      case find
        ((/= expectedAwsScope) . awsResourceScope)
        (awsInventoryResources inventory) of
        Nothing -> Right (CascadeTerminalAuditEvidence binding)
        Just resource ->
          Left
            ( CascadeTerminalAuditInventoryScopeMismatch
                expectedAwsScope
                (awsResourceScope resource)
            )
    TerminalAuditFoundEscapes _ escaped ->
      Left (CascadeTerminalAuditFoundEscapes escaped)
    TerminalAuditUnobservable _ failures ->
      Left (CascadeTerminalAuditUnobservable failures)

data CascadePreUninstallReportEvidence = CascadePreUninstallReportEvidence
  { internalPreUninstallReportBinding :: !CascadeProofBinding
  , internalPreUninstallReportDigest :: !CascadeReportDigest
  }
  deriving (Eq, Show)

mkCascadePreUninstallReportEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadePreUninstallReportObservation
  -> Either CascadeEvidenceError CascadePreUninstallReportEvidence
mkCascadePreUninstallReportEvidence compiled observation = do
  binding <- cascadeProofBinding compiled
  validateReceipt
    binding
    CascadePreUninstallReportReceipt
    (cascadePreUninstallReportReceipt observation)
  Right
    CascadePreUninstallReportEvidence
      { internalPreUninstallReportBinding = binding
      , internalPreUninstallReportDigest = cascadePreUninstallReportDigest observation
      }

data LocalCompletionPermit = LocalCompletionPermit
  { internalLocalCompletionPermitBinding :: !CascadeProofBinding
  , internalLocalCompletionPermitId :: !LocalCompletionPermitId
  , internalLocalCompletionPermitReportDigest :: !CascadeReportDigest
  , internalLocalCompletionPermitOperations :: !CascadeLocalOperationReferences
  }
  deriving (Eq, Show)

cascadeLocalOperationReferences
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Either CascadeEvidenceError CascadeLocalOperationReferences
cascadeLocalOperationReferences compiled =
  CascadeLocalOperationReferences
    <$> operationIdFor compiled UninstallCascadeLocalFoundation
    <*> operationIdFor compiled CommitCascadeCompletion

bindLocalCompletionPermit
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> LocalCompletionPermitGrant
  -> Either CascadeEvidenceError LocalCompletionPermit
bindLocalCompletionPermit compiled grant = do
  binding <- cascadeProofBinding compiled
  expectedOperations <- cascadeLocalOperationReferences compiled
  if localCompletionGrantRunId grant == internalCascadeBindingRunId binding
    then Right ()
    else
      Left
        ( CascadePermitRunMismatch
            (internalCascadeBindingRunId binding)
            (localCompletionGrantRunId grant)
        )
  if localCompletionGrantScope grant == internalCascadeBindingScope binding
    then Right ()
    else
      Left
        ( CascadePermitScopeMismatch
            (internalCascadeBindingScope binding)
            (localCompletionGrantScope grant)
        )
  if localCompletionGrantGraphDigest grant == internalCascadeBindingGraphDigest binding
    then Right ()
    else
      Left
        ( CascadePermitGraphDigestMismatch
            (internalCascadeBindingGraphDigest binding)
            (localCompletionGrantGraphDigest grant)
        )
  if localCompletionGrantOperationReferences grant == expectedOperations
    then Right ()
    else
      Left
        ( CascadePermitOperationReferencesMismatch
            expectedOperations
            (localCompletionGrantOperationReferences grant)
        )
  Right
    LocalCompletionPermit
      { internalLocalCompletionPermitBinding = binding
      , internalLocalCompletionPermitId = localCompletionGrantPermitId grant
      , internalLocalCompletionPermitReportDigest =
          localCompletionGrantReportDigest grant
      , internalLocalCompletionPermitOperations = expectedOperations
      }

data ReadyFingerprint = ReadyFingerprint
  { internalReadyFingerprintBinding :: !CascadeProofBinding
  , internalReadyFingerprintReportDigest :: !CascadeReportDigest
  , internalReadyFingerprintPermitId :: !LocalCompletionPermitId
  }
  deriving (Eq, Show)

data ReadyToUninstallEvidence = ReadyToUninstallEvidence
  { internalReadyToUninstallFingerprint :: !ReadyFingerprint
  , internalReadyToUninstallOperations :: !CascadeLocalOperationReferences
  }
  deriving (Eq, Show)

readyToUninstallRunId :: ReadyToUninstallEvidence -> CleanupRunId
readyToUninstallRunId =
  internalCascadeBindingRunId
    . internalReadyFingerprintBinding
    . internalReadyToUninstallFingerprint

readyToUninstallGraphDigest :: ReadyToUninstallEvidence -> CleanupDigest
readyToUninstallGraphDigest =
  internalCascadeBindingGraphDigest
    . internalReadyFingerprintBinding
    . internalReadyToUninstallFingerprint

readyToUninstallScope :: ReadyToUninstallEvidence -> ObservationEvidenceScope
readyToUninstallScope =
  internalCascadeBindingScope
    . internalReadyFingerprintBinding
    . internalReadyToUninstallFingerprint

readyToUninstallReportDigest :: ReadyToUninstallEvidence -> CascadeReportDigest
readyToUninstallReportDigest =
  internalReadyFingerprintReportDigest . internalReadyToUninstallFingerprint

readyToUninstallPermitId :: ReadyToUninstallEvidence -> LocalCompletionPermitId
readyToUninstallPermitId =
  internalReadyFingerprintPermitId . internalReadyToUninstallFingerprint

readyToUninstallOperationReferences
  :: ReadyToUninstallEvidence -> CascadeLocalOperationReferences
readyToUninstallOperationReferences = internalReadyToUninstallOperations

mkReadyToUninstallEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> CascadePreUninstallReportEvidence
  -> LocalCompletionPermit
  -> Either CascadeEvidenceError ReadyToUninstallEvidence
mkReadyToUninstallEvidence compiled absence credentials audit preUninstall permit = do
  expectedBinding <- cascadeProofBinding compiled
  requireBinding
    CascadeAbsenceComponent
    expectedBinding
    (absenceBinding absence)
  requireBinding
    CascadeCredentialDispositionComponent
    expectedBinding
    (credentialBinding credentials)
  requireBinding
    CascadeTerminalAuditComponent
    expectedBinding
    (terminalAuditBinding audit)
  requireBinding
    CascadePreUninstallReportComponent
    expectedBinding
    (internalPreUninstallReportBinding preUninstall)
  requireBinding
    CascadeLocalCompletionPermitComponent
    expectedBinding
    (internalLocalCompletionPermitBinding permit)
  let expectedReportDigest = internalPreUninstallReportDigest preUninstall
      permitReportDigest = internalLocalCompletionPermitReportDigest permit
  if permitReportDigest == expectedReportDigest
    then Right ()
    else
      Left
        ( CascadeReadyReportDigestMismatch
            expectedReportDigest
            permitReportDigest
        )
  Right
    ReadyToUninstallEvidence
      { internalReadyToUninstallFingerprint =
          ReadyFingerprint
            { internalReadyFingerprintBinding = expectedBinding
            , internalReadyFingerprintReportDigest = expectedReportDigest
            , internalReadyFingerprintPermitId = internalLocalCompletionPermitId permit
            }
      , internalReadyToUninstallOperations =
          internalLocalCompletionPermitOperations permit
      }

-- | Flat, secret-free representation observed at the durable boundary.  The
-- constructor is intentionally not itself readiness evidence: only the
-- canonical opaque binding below can be restored, and restoration requires an
-- exact CleanupRun plus its exact observation scope.
data ReadyToUninstallBindingObservation = ReadyToUninstallBindingObservation
  { readyBindingObservationRunId :: !CleanupRunId
  , readyBindingObservationGraphDigest :: !CleanupDigest
  , readyBindingObservationScope :: !ObservationEvidenceScope
  , readyBindingObservationReportDigest :: !CascadeReportDigest
  , readyBindingObservationPermitId :: !LocalCompletionPermitId
  , readyBindingObservationOperationReferences :: !CascadeLocalOperationReferences
  }
  deriving (Eq, Show)

data DurableReadyToUninstallBinding = DurableReadyToUninstallBinding
  { internalDurableReadyObservation :: !ReadyToUninstallBindingObservation
  , internalDurableReadyBytes :: !ByteString
  }
  deriving (Eq, Show)

data DurableReadyToUninstallEnvelope = DurableReadyToUninstallEnvelope
  { durableReadyEnvelopeVersion :: !Word16
  , durableReadyEnvelopeRunId :: !CleanupRunId
  , durableReadyEnvelopeGraphDigest :: !CleanupDigest
  , durableReadyEnvelopeSurface :: !Word16
  , durableReadyEnvelopeRegistryRevision :: !Text
  , durableReadyEnvelopeRunScope :: !Text
  , durableReadyEnvelopeFoundation :: !Text
  , durableReadyEnvelopeAwsAccount :: !(Maybe Text)
  , durableReadyEnvelopeAwsRegion :: !(Maybe Text)
  , durableReadyEnvelopeLifecycleOperation :: !Word16
  , durableReadyEnvelopeReportDigest :: !Text
  , durableReadyEnvelopePermitId :: !Text
  , durableReadyEnvelopeUninstallOperation :: !CleanupOperationId
  , durableReadyEnvelopeCompletionOperation :: !CleanupOperationId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

durableReadyToUninstallBindingVersion :: Word16
durableReadyToUninstallBindingVersion = 1

maximumDurableReadyToUninstallBindingBytes :: Int
maximumDurableReadyToUninstallBindingBytes = 16 * 1024

readyToUninstallBindingObservation
  :: ReadyToUninstallEvidence -> ReadyToUninstallBindingObservation
readyToUninstallBindingObservation ready =
  ReadyToUninstallBindingObservation
    { readyBindingObservationRunId = readyToUninstallRunId ready
    , readyBindingObservationGraphDigest = readyToUninstallGraphDigest ready
    , readyBindingObservationScope = readyToUninstallScope ready
    , readyBindingObservationReportDigest = readyToUninstallReportDigest ready
    , readyBindingObservationPermitId = readyToUninstallPermitId ready
    , readyBindingObservationOperationReferences =
        readyToUninstallOperationReferences ready
    }

captureDurableReadyToUninstallBinding
  :: ReadyToUninstallEvidence
  -> Either CascadeEvidenceError DurableReadyToUninstallBinding
captureDurableReadyToUninstallBinding ready = do
  let observation = readyToUninstallBindingObservation ready
  validateReadyBindingObservation observation
  decodeDurableReadyToUninstallBinding (encodeReadyBindingObservation observation)

observeDurableReadyToUninstallBinding
  :: DurableReadyToUninstallBinding -> ReadyToUninstallBindingObservation
observeDurableReadyToUninstallBinding = internalDurableReadyObservation

encodeDurableReadyToUninstallBinding
  :: DurableReadyToUninstallBinding -> ByteString
encodeDurableReadyToUninstallBinding = internalDurableReadyBytes

decodeDurableReadyToUninstallBinding
  :: ByteString
  -> Either CascadeEvidenceError DurableReadyToUninstallBinding
decodeDurableReadyToUninstallBinding bytes
  | ByteString.length bytes > maximumDurableReadyToUninstallBindingBytes =
      Left
        ( CascadeReadyBindingEncodedTooLarge
            (ByteString.length bytes)
            maximumDurableReadyToUninstallBindingBytes
        )
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ -> Left (CascadeReadyBindingDecodeInvalid "invalid durable Ready envelope")
      Right envelope
        | durableReadyEnvelopeVersion envelope
            /= durableReadyToUninstallBindingVersion ->
            Left
              ( CascadeReadyBindingUnsupportedVersion
                  (durableReadyEnvelopeVersion envelope)
              )
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left CascadeReadyBindingNonCanonical
        | otherwise -> do
            observation <- decodeReadyBindingEnvelope envelope
            validateReadyBindingObservation observation
            Right
              DurableReadyToUninstallBinding
                { internalDurableReadyObservation = observation
                , internalDurableReadyBytes = bytes
                }

restoreReadyToUninstallEvidence
  :: CleanupRun
  -> ObservationEvidenceScope
  -> DurableReadyToUninstallBinding
  -> Either CascadeEvidenceError ReadyToUninstallEvidence
restoreReadyToUninstallEvidence expectedRun expectedScope durable = do
  let observation = observeDurableReadyToUninstallBinding durable
      expectedRunId = cleanupRunId expectedRun
      expectedGraphDigest = cleanupRunGraphDigest expectedRun
  validateReadyBindingObservation observation
  if cleanupGraphDigest (cleanupRunGraph expectedRun) == expectedGraphDigest
    then Right ()
    else
      Left
        ( CascadeReadyBindingGraphMismatch
            (cleanupGraphDigest (cleanupRunGraph expectedRun))
            expectedGraphDigest
        )
  if readyBindingObservationRunId observation == expectedRunId
    then Right ()
    else
      Left
        ( CascadeReadyBindingRunMismatch
            expectedRunId
            (readyBindingObservationRunId observation)
        )
  if readyBindingObservationGraphDigest observation == expectedGraphDigest
    then Right ()
    else
      Left
        ( CascadeReadyBindingGraphMismatch
            expectedGraphDigest
            (readyBindingObservationGraphDigest observation)
        )
  if readyBindingObservationScope observation == expectedScope
    then Right ()
    else
      Left
        ( CascadeReadyBindingScopeMismatch
            expectedScope
            (readyBindingObservationScope observation)
        )
  expectedOperations <- cleanupRunLocalOperationReferences expectedRun
  if readyBindingObservationOperationReferences observation == expectedOperations
    then Right ()
    else
      Left
        ( CascadeReadyBindingOperationReferencesMismatch
            expectedOperations
            (readyBindingObservationOperationReferences observation)
        )
  let binding =
        CascadeProofBinding
          { internalCascadeBindingRunId = expectedRunId
          , internalCascadeBindingGraphDigest = expectedGraphDigest
          , internalCascadeBindingScope = expectedScope
          }
  Right
    ReadyToUninstallEvidence
      { internalReadyToUninstallFingerprint =
          ReadyFingerprint
            { internalReadyFingerprintBinding = binding
            , internalReadyFingerprintReportDigest =
                readyBindingObservationReportDigest observation
            , internalReadyFingerprintPermitId =
                readyBindingObservationPermitId observation
            }
      , internalReadyToUninstallOperations = expectedOperations
      }

encodeReadyBindingObservation
  :: ReadyToUninstallBindingObservation -> ByteString
encodeReadyBindingObservation observation =
  LazyByteString.toStrict . serialise $
    DurableReadyToUninstallEnvelope
      { durableReadyEnvelopeVersion = durableReadyToUninstallBindingVersion
      , durableReadyEnvelopeRunId = readyBindingObservationRunId observation
      , durableReadyEnvelopeGraphDigest =
          readyBindingObservationGraphDigest observation
      , durableReadyEnvelopeSurface = encodeReadyCleanupSurface (evidenceCleanupSurface scope)
      , durableReadyEnvelopeRegistryRevision = registryRevisionText revision
      , durableReadyEnvelopeRunScope = durableObservationRunScopeText runScope
      , durableReadyEnvelopeFoundation = linuxRke2FoundationIdText foundation
      , durableReadyEnvelopeAwsAccount = awsAccountIdText <$> awsAccount
      , durableReadyEnvelopeAwsRegion = awsRegionText <$> awsRegion
      , durableReadyEnvelopeLifecycleOperation =
          encodeReadyLifecycleOperation (evidenceLifecycleOperation scope)
      , durableReadyEnvelopeReportDigest =
          cascadeReportDigestText (readyBindingObservationReportDigest observation)
      , durableReadyEnvelopePermitId =
          localCompletionPermitIdText (readyBindingObservationPermitId observation)
      , durableReadyEnvelopeUninstallOperation =
          cascadeLocalUninstallOperationId operations
      , durableReadyEnvelopeCompletionOperation =
          cascadeLocalCompletionOperationId operations
      }
 where
  scope = readyBindingObservationScope observation
  revision = evidenceRegistryRevision scope
  runScope = evidenceDurableRunScope scope
  foundation = evidenceLinuxRke2Foundation scope
  (awsAccount, awsRegion) = case evidenceAwsScope scope of
    Nothing -> (Nothing, Nothing)
    Just (AwsScope account region) -> (Just account, Just region)
  operations = readyBindingObservationOperationReferences observation

decodeReadyBindingEnvelope
  :: DurableReadyToUninstallEnvelope
  -> Either CascadeEvidenceError ReadyToUninstallBindingObservation
decodeReadyBindingEnvelope envelope = do
  surface <- decodeReadyCleanupSurface (durableReadyEnvelopeSurface envelope)
  operation <-
    decodeReadyLifecycleOperation (durableReadyEnvelopeLifecycleOperation envelope)
  awsScope <-
    decodeReadyAwsScope
      (durableReadyEnvelopeAwsAccount envelope)
      (durableReadyEnvelopeAwsRegion envelope)
  report <-
    either
      (Left . CascadeReadyBindingDecodeInvalid)
      Right
      (mkCascadeReportDigest (durableReadyEnvelopeReportDigest envelope))
  permit <-
    either
      (Left . CascadeReadyBindingDecodeInvalid)
      Right
      (mkLocalCompletionPermitId (durableReadyEnvelopePermitId envelope))
  let scope =
        mkObservationEvidenceScope
          surface
          (RegistryRevision (durableReadyEnvelopeRegistryRevision envelope))
          (DurableObservationRunScope (durableReadyEnvelopeRunScope envelope))
          (LinuxRke2FoundationId (durableReadyEnvelopeFoundation envelope))
          awsScope
          operation
  Right
    ReadyToUninstallBindingObservation
      { readyBindingObservationRunId = durableReadyEnvelopeRunId envelope
      , readyBindingObservationGraphDigest = durableReadyEnvelopeGraphDigest envelope
      , readyBindingObservationScope = scope
      , readyBindingObservationReportDigest = report
      , readyBindingObservationPermitId = permit
      , readyBindingObservationOperationReferences =
          CascadeLocalOperationReferences
            { cascadeLocalUninstallOperationId =
                durableReadyEnvelopeUninstallOperation envelope
            , cascadeLocalCompletionOperationId =
                durableReadyEnvelopeCompletionOperation envelope
            }
      }

validateReadyBindingObservation
  :: ReadyToUninstallBindingObservation -> Either CascadeEvidenceError ()
validateReadyBindingObservation observation = do
  let runId = readyBindingObservationRunId observation
      scope = readyBindingObservationScope observation
      operations = readyBindingObservationOperationReferences observation
      expectedRunScope = DurableObservationRunScope (cleanupRunIdText runId)
  validateReadyIdentity "cleanup run id" (cleanupRunIdText runId)
  validateReadyOperation
    (cascadeLocalUninstallOperationId operations)
  validateReadyOperation
    (cascadeLocalCompletionOperationId operations)
  if evidenceCleanupSurface scope == Cascade
    then Right ()
    else Left (CascadeReadyBindingSurfaceMismatch (evidenceCleanupSurface scope))
  if evidenceLifecycleOperation scope == ReconcileDesiredAbsent
    then Right ()
    else Left (CascadeCompiledOperationMismatch (evidenceLifecycleOperation scope))
  if evidenceRegistryRevision scope == lifecycleRegistryRevision
    then Right ()
    else
      Left
        ( CascadeCompiledRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  if evidenceDurableRunScope scope == expectedRunScope
    then Right ()
    else
      Left
        ( CascadeCompiledRunScopeMismatch
            expectedRunScope
            (evidenceDurableRunScope scope)
        )
  case evidenceAwsScope scope of
    Nothing -> Left CascadeCompiledAwsScopeMissing
    Just (AwsScope (AwsAccountId account) (AwsRegion region)) -> do
      if Text.length account == 12
        && Text.all (\character -> isAscii character && isDigit character) account
        then Right ()
        else
          Left
            ( CascadeReadyBindingDecodeInvalid
                "durable Ready AWS account must contain exactly 12 ASCII digits"
            )
      validateReadyIdentity "AWS region" region
  let RegistryRevision revision = evidenceRegistryRevision scope
      DurableObservationRunScope runScope = evidenceDurableRunScope scope
      LinuxRke2FoundationId foundation = evidenceLinuxRke2Foundation scope
  validateReadyIdentity "registry revision" revision
  validateReadyIdentity "durable run scope" runScope
  validateReadyIdentity "Linux RKE2 foundation" foundation

validateReadyOperation
  :: CleanupOperationId -> Either CascadeEvidenceError ()
validateReadyOperation operation =
  case mkCleanupOperationId (cleanupOperationIdText operation) of
    Right canonical
      | canonical == operation -> Right ()
    _ ->
      Left
        ( CascadeReadyBindingDecodeInvalid
            "durable Ready operation ID is invalid"
        )

validateReadyIdentity :: Text -> Text -> Either CascadeEvidenceError ()
validateReadyIdentity label raw
  | Text.null raw = invalid "must not be empty"
  | Text.length raw > 160 = invalid "exceeds 160 characters"
  | Text.any (not . validCharacter) raw = invalid "contains an invalid character"
  | otherwise = Right ()
 where
  invalid detail =
    Left (CascadeReadyBindingDecodeInvalid (label <> " " <> detail))
  validCharacter character =
    isAsciiLower character
      || isAsciiUpper character
      || (isAscii character && isDigit character)
      || character `elem` ("-._:/" :: String)

cleanupRunLocalOperationReferences
  :: CleanupRun -> Either CascadeEvidenceError CascadeLocalOperationReferences
cleanupRunLocalOperationReferences run =
  CascadeLocalOperationReferences
    <$> operationForCleanupRunNode "lifecycle/cascade/uninstall-local" run
    <*> operationForCleanupRunNode "lifecycle/cascade/commit-completion" run

operationForCleanupRunNode
  :: Text -> CleanupRun -> Either CascadeEvidenceError CleanupOperationId
operationForCleanupRunNode expectedNode run = case matchingOperations of
  [] -> Left (CascadeLocalOperationMissing expectedNode)
  [operation] -> Right operation
  _ -> Left (CascadeLocalOperationDuplicated expectedNode)
 where
  matchingOperations =
    [ cleanupNodeOperationId node
    | node <- cleanupGraphNodes (cleanupRunGraph run)
    , cleanupNodeIdText (cleanupNodeId node) == expectedNode
    ]

encodeReadyCleanupSurface :: CleanupSurface -> Word16
encodeReadyCleanupSurface surface = case surface of
  LocalOnly -> 0
  Cascade -> 1
  ExplicitPerRun -> 2
  OperationalTeardown -> 3
  ExplicitLongLived -> 4
  TotalDecommission -> 5

decodeReadyCleanupSurface
  :: Word16 -> Either CascadeEvidenceError CleanupSurface
decodeReadyCleanupSurface tag = case tag of
  0 -> Right LocalOnly
  1 -> Right Cascade
  2 -> Right ExplicitPerRun
  3 -> Right OperationalTeardown
  4 -> Right ExplicitLongLived
  5 -> Right TotalDecommission
  _ -> Left (CascadeReadyBindingDecodeInvalid "unknown cleanup surface tag")

encodeReadyLifecycleOperation :: LifecycleOperation -> Word16
encodeReadyLifecycleOperation operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

decodeReadyLifecycleOperation
  :: Word16 -> Either CascadeEvidenceError LifecycleOperation
decodeReadyLifecycleOperation tag = case tag of
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  _ -> Left (CascadeReadyBindingDecodeInvalid "unknown lifecycle operation tag")

decodeReadyAwsScope
  :: Maybe Text -> Maybe Text -> Either CascadeEvidenceError (Maybe AwsScope)
decodeReadyAwsScope account region = case (account, region) of
  (Nothing, Nothing) -> Right Nothing
  (Just accountId, Just regionId) ->
    Right (Just (AwsScope (AwsAccountId accountId) (AwsRegion regionId)))
  _ ->
    Left
      ( CascadeReadyBindingDecodeInvalid
          "AWS account and region must both be present or both be absent"
      )

durableObservationRunScopeText :: DurableObservationRunScope -> Text
durableObservationRunScopeText (DurableObservationRunScope value) = value

linuxRke2FoundationIdText :: LinuxRke2FoundationId -> Text
linuxRke2FoundationIdText (LinuxRke2FoundationId value) = value

awsAccountIdText :: AwsAccountId -> Text
awsAccountIdText (AwsAccountId value) = value

awsRegionText :: AwsRegion -> Text
awsRegionText (AwsRegion value) = value

data LocalUninstallEvidence = LocalUninstallEvidence
  { internalLocalUninstallFingerprint :: !ReadyFingerprint
  , internalLocalUninstallAbsenceEvidence :: !AbsenceEvidence
  }
  deriving (Eq, Show)

localUninstallAbsenceEvidence :: LocalUninstallEvidence -> AbsenceEvidence
localUninstallAbsenceEvidence = internalLocalUninstallAbsenceEvidence

mkLocalUninstallEvidence
  :: ReadyToUninstallEvidence
  -> LocalFoundationObservation
  -> Either CascadeEvidenceError LocalUninstallEvidence
mkLocalUninstallEvidence ready observation = do
  let expectedScope = readyToUninstallScope ready
  if localFoundationObservationScope observation == expectedScope
    then Right ()
    else
      Left
        ( CascadeLocalAbsenceScopeMismatch
            expectedScope
            (localFoundationObservationScope observation)
        )
  absence <- case localFoundationObservationResult observation of
    LocalFoundationAbsent evidence -> Right evidence
    LocalFoundationPresent -> Left CascadeLocalFoundationStillPresent
    LocalFoundationUnobservable failure ->
      Left (CascadeLocalFoundationUnobservable failure)
  Right
    LocalUninstallEvidence
      { internalLocalUninstallFingerprint = internalReadyToUninstallFingerprint ready
      , internalLocalUninstallAbsenceEvidence = absence
      }

data CascadeCompleteEvidence = CascadeCompleteEvidence
  { internalCascadeCompleteFingerprint :: !ReadyFingerprint
  , internalCascadeCompleteLocalAbsence :: !AbsenceEvidence
  }
  deriving (Eq, Show)

cascadeCompleteRunId :: CascadeCompleteEvidence -> CleanupRunId
cascadeCompleteRunId =
  internalCascadeBindingRunId
    . internalReadyFingerprintBinding
    . internalCascadeCompleteFingerprint

cascadeCompleteGraphDigest :: CascadeCompleteEvidence -> CleanupDigest
cascadeCompleteGraphDigest =
  internalCascadeBindingGraphDigest
    . internalReadyFingerprintBinding
    . internalCascadeCompleteFingerprint

cascadeCompleteReportDigest :: CascadeCompleteEvidence -> CascadeReportDigest
cascadeCompleteReportDigest =
  internalReadyFingerprintReportDigest . internalCascadeCompleteFingerprint

cascadeCompletePermitId :: CascadeCompleteEvidence -> LocalCompletionPermitId
cascadeCompletePermitId =
  internalReadyFingerprintPermitId . internalCascadeCompleteFingerprint

mkCascadeCompleteEvidence
  :: ReadyToUninstallEvidence
  -> LocalUninstallEvidence
  -> CascadeCompletionReceiptObservation
  -> Either CascadeEvidenceError CascadeCompleteEvidence
mkCascadeCompleteEvidence ready localAbsence completion = do
  let fingerprint = internalReadyToUninstallFingerprint ready
  if internalLocalUninstallFingerprint localAbsence == fingerprint
    then Right ()
    else Left CascadeLocalAbsenceReadinessMismatch
  let expectedPermitId = internalReadyFingerprintPermitId fingerprint
      actualPermitId = cascadeCompletionReceiptPermitId completion
  if actualPermitId == expectedPermitId
    then Right ()
    else
      Left
        ( CascadeCompletionPermitMismatch
            expectedPermitId
            actualPermitId
        )
  let expectedReportDigest = internalReadyFingerprintReportDigest fingerprint
      actualReportDigest = cascadeCompletionReceiptReportDigest completion
  if actualReportDigest == expectedReportDigest
    then Right ()
    else
      Left
        ( CascadeCompletionReportDigestMismatch
            expectedReportDigest
            actualReportDigest
        )
  validateReceipt
    (internalReadyFingerprintBinding fingerprint)
    CascadeCompletionReceipt
    (cascadeCompletionReceipt completion)
  Right
    CascadeCompleteEvidence
      { internalCascadeCompleteFingerprint = fingerprint
      , internalCascadeCompleteLocalAbsence =
          internalLocalUninstallAbsenceEvidence localAbsence
      }

cascadeProofBinding
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Either CascadeEvidenceError CascadeProofBinding
cascadeProofBinding compiled
  | evidenceLifecycleOperation scope /= ReconcileDesiredAbsent =
      Left (CascadeCompiledOperationMismatch (evidenceLifecycleOperation scope))
  | evidenceRegistryRevision scope /= lifecycleRegistryRevision =
      Left
        ( CascadeCompiledRegistryRevisionMismatch
            lifecycleRegistryRevision
            (evidenceRegistryRevision scope)
        )
  | evidenceDurableRunScope scope /= expectedRunScope =
      Left
        ( CascadeCompiledRunScopeMismatch
            expectedRunScope
            (evidenceDurableRunScope scope)
        )
  | evidenceAwsScope scope == Nothing = Left CascadeCompiledAwsScopeMissing
  | otherwise =
      Right
        CascadeProofBinding
          { internalCascadeBindingRunId = runId
          , internalCascadeBindingGraphDigest =
              cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
          , internalCascadeBindingScope = scope
          }
 where
  runId = compiledDesiredAbsenceRunId compiled
  expectedRunScope = DurableObservationRunScope (cleanupRunIdText runId)
  scope = compiledDesiredAbsenceObservationScope compiled

cascadeExpectedAbsenceKeys
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> [RegisteredResourceKey]
cascadeExpectedAbsenceKeys =
  nub
    . sort
    . map registeredTargetKey
    . foldMap targetForNode
    . desiredAbsenceProgramNodes
    . compiledDesiredAbsenceProgram
 where
  targetForNode node = case programNodeOperation node of
    ReadBackRegisteredTargetAbsent target -> [target]
    _ -> []

cascadeAuditScope :: ObservationEvidenceScope -> ObservationEvidenceScope
cascadeAuditScope scope =
  mkObservationEvidenceScope
    Cascade
    (evidenceRegistryRevision scope)
    (evidenceDurableRunScope scope)
    (evidenceLinuxRke2Foundation scope)
    (evidenceAwsScope scope)
    RunTerminalEscapeAudit

validateReceipt
  :: CascadeProofBinding
  -> DurableReceiptKind
  -> DurableReceiptObservation
  -> Either CascadeEvidenceError ()
validateReceipt binding expectedKind receipt
  | durableReceiptObservationKind receipt /= expectedKind =
      Left
        ( CascadeReceiptKindMismatch
            expectedKind
            (durableReceiptObservationKind receipt)
        )
  | durableReceiptObservationScope receipt /= internalCascadeBindingScope binding =
      Left
        ( CascadeReceiptScopeMismatch
            expectedKind
            (internalCascadeBindingScope binding)
            (durableReceiptObservationScope receipt)
        )
  | durableReceiptObservationGraphDigest receipt
      /= internalCascadeBindingGraphDigest binding =
      Left
        ( CascadeReceiptGraphDigestMismatch
            expectedKind
            (internalCascadeBindingGraphDigest binding)
            (durableReceiptObservationGraphDigest receipt)
        )
  | durableReceiptObservationResult receipt /= DurableReceiptObserved =
      Left
        ( CascadeReceiptNotObserved
            expectedKind
            (durableReceiptObservationResult receipt)
        )
  | otherwise = Right ()

operationIdFor
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> TeardownOperation 'Cascade
  -> Either CascadeEvidenceError CleanupOperationId
operationIdFor compiled expectedOperation = case matchingNodeIds of
  [] -> Left (CascadeLocalOperationMissing operationTag)
  [nodeId] -> case find ((== nodeId) . cleanupNodeId) graphNodes of
    Nothing -> Left (CascadeLocalOperationPlanMissing nodeId)
    Just plan -> Right (cleanupNodeOperationId plan)
  _ -> Left (CascadeLocalOperationDuplicated operationTag)
 where
  operationTag = teardownOperationTag expectedOperation
  matchingNodeIds =
    [ nodeId
    | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
    , operation == expectedOperation
    ]
  graphNodes = cleanupGraphNodes (compiledDesiredAbsenceGraph compiled)

requireBinding
  :: CascadeEvidenceComponent
  -> CascadeProofBinding
  -> CascadeProofBinding
  -> Either CascadeEvidenceError ()
requireBinding component expected actual
  | actual == expected = Right ()
  | otherwise = Left (CascadeEvidenceBindingMismatch component)

absenceBinding :: CascadeAbsenceEvidence -> CascadeProofBinding
absenceBinding (CascadeAbsenceEvidence binding) = binding

credentialBinding :: CascadeCredentialDispositionEvidence -> CascadeProofBinding
credentialBinding (CascadeCredentialDispositionEvidence binding) = binding

terminalAuditBinding :: CascadeTerminalAuditEvidence -> CascadeProofBinding
terminalAuditBinding (CascadeTerminalAuditEvidence binding) = binding

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision revision) = revision

-- | A fixed package-private fixture used only to exercise closed production
-- boundaries without publishing an authority-bearing value to a dependent
-- component.  The public facade exposes only the regression booleans below.
data FixedCascadeEvidenceFixture = FixedCascadeEvidenceFixture
  { fixedCascadeCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedCascadeRun :: !CleanupRun
  , fixedCascadeReady :: !ReadyToUninstallEvidence
  , fixedCascadeLocalUninstall :: !LocalUninstallEvidence
  , fixedCascadeComplete :: !CascadeCompleteEvidence
  }

withFixedCascadeEvidenceFixtureInternal
  :: ( CompiledDesiredAbsenceProgram 'Cascade
       -> CleanupRun
       -> ReadyToUninstallEvidence
       -> LocalUninstallEvidence
       -> CascadeCompleteEvidence
       -> result
     )
  -> Either Text result
withFixedCascadeEvidenceFixtureInternal =
  withCascadeEvidenceFixtureForRunInternal "cleanup-run/cascade-fixed-regression"

withCascadeEvidenceFixtureForRunInternal
  :: Text
  -> ( CompiledDesiredAbsenceProgram 'Cascade
       -> CleanupRun
       -> ReadyToUninstallEvidence
       -> LocalUninstallEvidence
       -> CascadeCompleteEvidence
       -> result
     )
  -> Either Text result
withCascadeEvidenceFixtureForRunInternal rawRunId consume = do
  fixture <- fixedCascadeEvidenceFixtureFor rawRunId fixedCascadeFoundation
  pure
    ( consume
        (fixedCascadeCompiled fixture)
        (fixedCascadeRun fixture)
        (fixedCascadeReady fixture)
        (fixedCascadeLocalUninstall fixture)
        (fixedCascadeComplete fixture)
    )

data CascadeEvidenceRegression = CascadeEvidenceRegression
  { cascadeEvidenceRegressionCompleteChain :: !Bool
  , cascadeEvidenceRegressionAbsenceRefused :: !Bool
  , cascadeEvidenceRegressionCredentialRefused :: !Bool
  , cascadeEvidenceRegressionAuditRefused :: !Bool
  , cascadeEvidenceRegressionPreUninstallRefused :: !Bool
  , cascadeEvidenceRegressionPermitRefused :: !Bool
  , cascadeEvidenceRegressionMixedBindingRefused :: !Bool
  , cascadeEvidenceRegressionLocalAbsenceRefused :: !Bool
  , cascadeEvidenceRegressionCompletionRefused :: !Bool
  , cascadeEvidenceRegressionDurableReadyCanonical :: !Bool
  , cascadeEvidenceRegressionDurableReadyCorruptionRefused :: !Bool
  }

fixedCascadeEvidenceRegression :: Either Text CascadeEvidenceRegression
fixedCascadeEvidenceRegression = do
  fixture <-
    fixedCascadeEvidenceFixtureFor
      "cleanup-run/cascade-fixed-regression"
      fixedCascadeFoundation
  other <-
    fixedCascadeEvidenceFixtureFor
      "cleanup-run/cascade-fixed-regression-other"
      fixedCascadeFoundation
  let compiled = fixedCascadeCompiled fixture
      ready = fixedCascadeReady fixture
      local = fixedCascadeLocalUninstall fixture
      complete = fixedCascadeComplete fixture
      scope = compiledDesiredAbsenceObservationScope compiled
      graphDigest = cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
      reportDigest = readyToUninstallReportDigest ready
      permitId = readyToUninstallPermitId ready
      receipt kind result =
        DurableReceiptObservation
          { durableReceiptObservationKind = kind
          , durableReceiptObservationScope = scope
          , durableReceiptObservationGraphDigest = graphDigest
          , durableReceiptObservationResult = result
          }
      completionObservation =
        CascadeCompletionReceiptObservation
          { cascadeCompletionReceiptPermitId = permitId
          , cascadeCompletionReceiptReportDigest = reportDigest
          , cascadeCompletionReceipt =
              receipt CascadeCompletionReceipt DurableReceiptObserved
          }
      badCredential =
        CascadeCredentialDispositionObservation
          { cascadeCredentialDispositionScope = scope
          , cascadeCredentialDispositionResult =
              CascadeCredentialsOutstanding
                (ObservedResourceIdentity "credential/fixed" :| [])
          }
      badAudit =
        TerminalAuditObservation
          { terminalAuditScope = fixedAuditScope compiled
          , terminalAuditRevision = ObservationRevision 2
          , terminalAuditResult =
              TerminalAuditUnobservable
                fixedEmptyInventory
                (ObservationFailure "fixed audit unavailable" :| [])
          }
      badPreUninstall =
        CascadePreUninstallReportObservation
          { cascadePreUninstallReportDigest = reportDigest
          , cascadePreUninstallReportReceipt =
              receipt CascadePreUninstallReportReceipt DurableReceiptMissing
          }
      expectedOperations = readyToUninstallOperationReferences ready
      badPermitGrant =
        LocalCompletionPermitGrant
          { localCompletionGrantPermitId = permitId
          , localCompletionGrantRunId = readyToUninstallRunId ready
          , localCompletionGrantScope = readyToUninstallScope ready
          , localCompletionGrantGraphDigest = readyToUninstallGraphDigest ready
          , localCompletionGrantReportDigest = reportDigest
          , localCompletionGrantOperationReferences =
              CascadeLocalOperationReferences
                { cascadeLocalUninstallOperationId =
                    cascadeLocalCompletionOperationId expectedOperations
                , cascadeLocalCompletionOperationId =
                    cascadeLocalUninstallOperationId expectedOperations
                }
          }
      badCompletion =
        completionObservation
          { cascadeCompletionReceipt =
              receipt CascadeCompletionReceipt DurableReceiptMissing
          }
      durable = captureDurableReadyToUninstallBinding ready
      restored = do
        captured <- durable
        decoded <- decodeDurableReadyToUninstallBinding (encodeDurableReadyToUninstallBinding captured)
        restoreReadyToUninstallEvidence
          (fixedCascadeRun fixture)
          scope
          decoded
  pure
    CascadeEvidenceRegression
      { cascadeEvidenceRegressionCompleteChain =
          cascadeCompleteRunId complete == readyToUninstallRunId ready
            && cascadeCompleteGraphDigest complete == readyToUninstallGraphDigest ready
            && cascadeCompleteReportDigest complete == reportDigest
            && cascadeCompletePermitId complete == permitId
      , cascadeEvidenceRegressionAbsenceRefused =
          isLeftMatching
            isAbsenceKeyMismatch
            (mkCascadeAbsenceEvidence compiled (fixedObservationSet compiled []))
      , cascadeEvidenceRegressionCredentialRefused =
          isLeftMatching
            isCredentialsRemain
            (mkCascadeCredentialDispositionEvidence compiled badCredential)
      , cascadeEvidenceRegressionAuditRefused =
          isLeftMatching
            isAuditUnobservable
            (mkCascadeTerminalAuditEvidence compiled badAudit)
      , cascadeEvidenceRegressionPreUninstallRefused =
          isLeftMatching
            isReceiptMissing
            (mkCascadePreUninstallReportEvidence compiled badPreUninstall)
      , cascadeEvidenceRegressionPermitRefused =
          isLeftMatching
            isPermitOperationsMismatch
            (bindLocalCompletionPermit compiled badPermitGrant)
      , cascadeEvidenceRegressionMixedBindingRefused =
          isLeftMatching
            (== CascadeEvidenceBindingMismatch CascadeAbsenceComponent)
            ( mkReadyToUninstallEvidence
                compiled
                (fixedCascadeAbsence (fixedCascadeCompiled other))
                (fixedCascadeCredentials fixture)
                (fixedCascadeAudit fixture)
                (fixedCascadePreUninstall fixture)
                (fixedCascadePermit fixture)
            )
      , cascadeEvidenceRegressionLocalAbsenceRefused =
          mkLocalUninstallEvidence
            ready
            LocalFoundationObservation
              { localFoundationObservationScope = scope
              , localFoundationObservationResult = LocalFoundationPresent
              }
            == Left CascadeLocalFoundationStillPresent
      , cascadeEvidenceRegressionCompletionRefused =
          isLeftMatching
            isReceiptMissing
            (mkCascadeCompleteEvidence ready local badCompletion)
      , cascadeEvidenceRegressionDurableReadyCanonical = restored == Right ready
      , cascadeEvidenceRegressionDurableReadyCorruptionRefused = case durable of
          Left _ -> False
          Right captured ->
            case decodeDurableReadyToUninstallBinding
              (ByteString.snoc (encodeDurableReadyToUninstallBinding captured) 0) of
              Left CascadeReadyBindingNonCanonical -> True
              _ -> False
      }

fixedCascadeEvidenceFixtureFor
  :: Text
  -> LinuxRke2FoundationId
  -> Either Text FixedCascadeEvidenceFixture
fixedCascadeEvidenceFixtureFor rawRunId foundation = do
  runId <- mkCleanupRunIdText rawRunId
  compiled <-
    firstShowInternal
      ( compileDesiredAbsenceGraph
          runId
          foundation
          (Just fixedCascadeAwsScope)
          CascadeSurface
      )
  owner <- firstShowInternal (mkCleanupOwnerId "cascade-evidence-fixed-regression")
  run <-
    firstShowInternal
      (newCleanupRun runId (compiledDesiredAbsenceGraph compiled) owner 0 100)
  reportDigest <- firstShowInternal (mkCascadeReportDigest (Text.replicate 64 "a"))
  permitId <- firstShowInternal (mkLocalCompletionPermitId (rawRunId <> "/permit"))
  let absence = fixedCascadeAbsence compiled
      credentials = fixedCascadeCredentialsFor compiled
      audit = fixedCascadeAuditFor compiled
      preUninstall = fixedCascadePreUninstallFor compiled reportDigest
      permit = fixedCascadePermitFor compiled reportDigest permitId
  ready <-
    firstShowInternal
      ( mkReadyToUninstallEvidence
          compiled
          absence
          credentials
          audit
          preUninstall
          permit
      )
  local <-
    firstShowInternal
      ( mkLocalUninstallEvidence
          ready
          LocalFoundationObservation
            { localFoundationObservationScope =
                compiledDesiredAbsenceObservationScope compiled
            , localFoundationObservationResult =
                LocalFoundationAbsent
                  (AbsenceEvidence "local-rke2-fixed-authoritative-not-found")
            }
      )
  complete <-
    firstShowInternal
      ( mkCascadeCompleteEvidence
          ready
          local
          CascadeCompletionReceiptObservation
            { cascadeCompletionReceiptPermitId = permitId
            , cascadeCompletionReceiptReportDigest = reportDigest
            , cascadeCompletionReceipt =
                fixedReceipt
                  compiled
                  CascadeCompletionReceipt
                  DurableReceiptObserved
            }
      )
  pure
    FixedCascadeEvidenceFixture
      { fixedCascadeCompiled = compiled
      , fixedCascadeRun = run
      , fixedCascadeReady = ready
      , fixedCascadeLocalUninstall = local
      , fixedCascadeComplete = complete
      }

fixedCascadeAbsence
  :: CompiledDesiredAbsenceProgram 'Cascade -> CascadeAbsenceEvidence
fixedCascadeAbsence compiled =
  mustRightInternal
    (mkCascadeAbsenceEvidence compiled (fixedObservationSet compiled fixedCascadeKeys))

fixedCascadeCredentials :: FixedCascadeEvidenceFixture -> CascadeCredentialDispositionEvidence
fixedCascadeCredentials = fixedCascadeCredentialsFor . fixedCascadeCompiled

fixedCascadeCredentialsFor
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeCredentialDispositionEvidence
fixedCascadeCredentialsFor compiled =
  mustRightInternal
    ( mkCascadeCredentialDispositionEvidence
        compiled
        CascadeCredentialDispositionObservation
          { cascadeCredentialDispositionScope =
              compiledDesiredAbsenceObservationScope compiled
          , cascadeCredentialDispositionResult = CascadeCredentialsDisposed
          }
    )

fixedCascadeAudit :: FixedCascadeEvidenceFixture -> CascadeTerminalAuditEvidence
fixedCascadeAudit = fixedCascadeAuditFor . fixedCascadeCompiled

fixedCascadeAuditFor
  :: CompiledDesiredAbsenceProgram 'Cascade -> CascadeTerminalAuditEvidence
fixedCascadeAuditFor compiled =
  mustRightInternal
    ( mkCascadeTerminalAuditEvidence
        compiled
        TerminalAuditObservation
          { terminalAuditScope = fixedAuditScope compiled
          , terminalAuditRevision = ObservationRevision 1
          , terminalAuditResult = TerminalAuditConfirmedClean fixedEmptyInventory
          }
    )

fixedCascadePreUninstall
  :: FixedCascadeEvidenceFixture -> CascadePreUninstallReportEvidence
fixedCascadePreUninstall fixture =
  fixedCascadePreUninstallFor
    (fixedCascadeCompiled fixture)
    (readyToUninstallReportDigest (fixedCascadeReady fixture))

fixedCascadePreUninstallFor
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeReportDigest
  -> CascadePreUninstallReportEvidence
fixedCascadePreUninstallFor compiled reportDigest =
  mustRightInternal
    ( mkCascadePreUninstallReportEvidence
        compiled
        CascadePreUninstallReportObservation
          { cascadePreUninstallReportDigest = reportDigest
          , cascadePreUninstallReportReceipt =
              fixedReceipt
                compiled
                CascadePreUninstallReportReceipt
                DurableReceiptObserved
          }
    )

fixedCascadePermit :: FixedCascadeEvidenceFixture -> LocalCompletionPermit
fixedCascadePermit fixture =
  fixedCascadePermitFor
    (fixedCascadeCompiled fixture)
    (readyToUninstallReportDigest (fixedCascadeReady fixture))
    (readyToUninstallPermitId (fixedCascadeReady fixture))

fixedCascadePermitFor
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeReportDigest
  -> LocalCompletionPermitId
  -> LocalCompletionPermit
fixedCascadePermitFor compiled reportDigest permitId =
  mustRightInternal
    ( bindLocalCompletionPermit
        compiled
        LocalCompletionPermitGrant
          { localCompletionGrantPermitId = permitId
          , localCompletionGrantRunId = compiledDesiredAbsenceRunId compiled
          , localCompletionGrantScope =
              compiledDesiredAbsenceObservationScope compiled
          , localCompletionGrantGraphDigest =
              cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
          , localCompletionGrantReportDigest = reportDigest
          , localCompletionGrantOperationReferences =
              mustRightInternal (cascadeLocalOperationReferences compiled)
          }
    )

fixedObservationSet
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> [RegisteredResourceKey]
  -> CompleteObservationSet
fixedObservationSet compiled keys =
  mustRightInternal
    ( mkCompleteObservationSet
        scope
        keys
        [ exactResourceObservationFor
            (mustRegisteredIdentityInternal key)
            (ObservationRevision 1)
            scope
            (ExactResourceAbsent (AbsenceEvidence "provider-fixed-authoritative-not-found"))
        | key <- keys
        ]
    )
 where
  scope = compiledDesiredAbsenceObservationScope compiled

fixedCascadeKeys :: [RegisteredResourceKey]
fixedCascadeKeys =
  sort
    [ cleanupTargetKey target
    | target <- cleanupTargetsForSurface CascadeSurface
    , cleanupTargetKind target /= LocalSubstrate
    ]

fixedAuditScope
  :: CompiledDesiredAbsenceProgram 'Cascade -> TerminalAuditScope 'Cascade
fixedAuditScope compiled =
  mustRightInternal
    ( mkTerminalAuditScope
        CascadeSurface
        (cascadeAuditScope (compiledDesiredAbsenceObservationScope compiled))
        (TerminalAuditQueryDigest "fixed-terminal-audit/v1")
        cascadeIntentionallyRetainedProjectionDigest
    )

fixedReceipt
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> DurableReceiptKind
  -> DurableReceiptObservationResult
  -> DurableReceiptObservation
fixedReceipt compiled kind result =
  DurableReceiptObservation
    { durableReceiptObservationKind = kind
    , durableReceiptObservationScope =
        compiledDesiredAbsenceObservationScope compiled
    , durableReceiptObservationGraphDigest =
        cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
    , durableReceiptObservationResult = result
    }

fixedEmptyInventory :: AwsInventory
fixedEmptyInventory = mustRightInternal (normalizeAwsTagRows [])

fixedCascadeFoundation :: LinuxRke2FoundationId
fixedCascadeFoundation = LinuxRke2FoundationId "linux-rke2/fixed"

fixedCascadeAwsScope :: AwsScope
fixedCascadeAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

mkCleanupRunIdText :: Text -> Either Text CleanupRunId
mkCleanupRunIdText raw = firstShowInternal (mkCleanupRunId raw)

mustRegisteredIdentityInternal :: RegisteredResourceKey -> RegisteredIdentity
mustRegisteredIdentityInternal key = case lookupRegisteredIdentity key of
  Nothing -> error "fixed cascade registry identity is missing"
  Just identity -> identity

firstShowInternal :: (Show err) => Either err value -> Either Text value
firstShowInternal result = case result of
  Left err -> Left (Text.pack (show err))
  Right value -> Right value

mustRightInternal :: (Show err) => Either err value -> value
mustRightInternal result = case result of
  Left err -> error (show err)
  Right value -> value

isLeftMatching :: (err -> Bool) -> Either err value -> Bool
isLeftMatching predicate result = case result of
  Left err -> predicate err
  Right _ -> False

isAbsenceKeyMismatch :: CascadeEvidenceError -> Bool
isAbsenceKeyMismatch err = case err of
  CascadeAbsenceKeySetMismatch {} -> True
  _ -> False

isCredentialsRemain :: CascadeEvidenceError -> Bool
isCredentialsRemain err = case err of
  CascadeCredentialsRemain {} -> True
  _ -> False

isAuditUnobservable :: CascadeEvidenceError -> Bool
isAuditUnobservable err = case err of
  CascadeTerminalAuditUnobservable {} -> True
  _ -> False

isReceiptMissing :: CascadeEvidenceError -> Bool
isReceiptMissing err = case err of
  CascadeReceiptNotObserved {} -> True
  _ -> False

isPermitOperationsMismatch :: CascadeEvidenceError -> Bool
isPermitOperationsMismatch err = case err of
  CascadePermitOperationReferencesMismatch {} -> True
  _ -> False
