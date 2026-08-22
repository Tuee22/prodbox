{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}

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
  , cascadeAuditScope
  , mkCascadeTerminalAuditEvidence
  , CascadeCapabilityCustodyEvidence
  , cascadeExpectedCustodialCapabilities
  , mkCascadeCapabilityCustodyEvidence
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
  , requireCascadeConvergenceBinding
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
  , mkLocalOnlyUninstallEvidence
  , LocalOnlyProofBinding
  , LocalOnlyCompleteEvidence
  , localOnlyCompleteRunId
  , localOnlyCompleteGraphDigest
  , mkLocalOnlyCompleteEvidence
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
  , cascadeEvidenceRegressionLocalOnlyChainCloses
  , cascadeEvidenceRegressionLocalOnlyAwsScopeUncompilable
  , cascadeEvidenceRegressionLocalOnlyReceiptRefused
  , cascadeEvidenceRegressionLocalOnlyAbsenceRefused
  , cascadeEvidenceRegressionBindingGeneralisationPreserving
  , cascadeEvidenceRegressionCustodyLostRefused
  , cascadeEvidenceRegressionCustodyUnobservableRefused
  , cascadeEvidenceRegressionCustodyIncompleteRefused
  , cascadeEvidenceRegressionCustodyForeignBindingRefused
  , withFixedCascadeEvidenceFixtureInternal
  , withCascadeEvidenceFixtureForRunInternal
  , withCascadePreUninstallInputsInternal
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
import Data.Word (Word16)
import GHC.Generics (Generic)
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
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Internal
  ( CapabilityLoss (CapabilityLoss)
  , CheckpointCustody (..)
  , checkpointCustodyCapability
  , registeredCheckpointCapabilities
  )
import Prodbox.Lifecycle.Teardown.CapabilityCustody.Universe
  ( CustodialCapability (CheckpointCapability)
  )
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedCatalog
  , RetainedNameBinding
  , mkRetainedNameBinding
  , retainedCatalogAwsScope
  , retainedCatalogFor
  , retainedSetDigestFor
  , terminalAuditQueryCatalog
  , terminalAuditQueryDigestFor
  )

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
  | CascadeCapabilityCustodyComponent
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
  | CascadeTerminalAuditRetainedScopeMismatch !AwsScope !AwsScope
  | CascadeTerminalAuditFoundEscapes !(NonEmpty AwsResource)
  | CascadeTerminalAuditUnobservable !(NonEmpty ObservationFailure)
  | CascadeTerminalAuditInventoryScopeMismatch !AwsScope !AwsScope
  | CascadeCustodyAnswerSetMismatch
      ![CustodialCapability]
      ![CustodialCapability]
  | CascadeCustodyCapabilityLost !(NonEmpty CapabilityLoss)
  | CascadeCustodyCapabilityUnobservable
      !(NonEmpty (CustodialCapability, Text))
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
  | CascadeLocalOnlyAwsScopePresent
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

-- | What a compiled program's proofs are bound to, indexed by the surface that
-- compiled it.
--
-- Sprint 4.89 generalised this off its cascade-only index. The three identities
-- were never cascade-specific; only the AWS-scope rule is, and that rule is read
-- from the surface witness the compiler already uses. Keeping two structurally
-- identical bindings validated by opposite rules would have made the local-only
-- surface's proof a second implementation of the cascade's, which is how the two
-- drift.
data CleanupProofBinding (surface :: CleanupSurface) = CleanupProofBinding
  { internalCascadeBindingRunId :: !CleanupRunId
  , internalCascadeBindingGraphDigest :: !CleanupDigest
  , internalCascadeBindingScope :: !ObservationEvidenceScope
  }
  deriving (Eq, Show)

-- | The cascade instantiation, byte-identical to what it was before the
-- generalisation.
type CascadeProofBinding = CleanupProofBinding 'Cascade

-- | The local-only instantiation. It carries the same three identities and is
-- refused by the opposite AWS-scope rule.
type LocalOnlyProofBinding = CleanupProofBinding 'LocalOnly

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

-- | Sprint 4.84: the retained set the cascade audit is entitled to leave
-- behind is now the terminal matcher catalog in
-- "Prodbox.Lifecycle.Teardown.RetainedInventory", not a projection of the
-- registry's explicit-long-lived cleanup targets.  The registry projection
-- named only registered targets, so an audit built on it could not tell an
-- intentionally retained S3, SES, or shared IAM resource from an escapee.
mkCascadeTerminalAuditEvidence
  :: RetainedCatalog 'Cascade
  -> CompiledDesiredAbsenceProgram 'Cascade
  -> TerminalAuditObservation 'Cascade
  -> Either CascadeEvidenceError CascadeTerminalAuditEvidence
mkCascadeTerminalAuditEvidence catalog compiled observation = do
  binding <- cascadeProofBinding compiled
  let observedAuditScope = terminalAuditScope observation
      expectedScope = cascadeAuditScope (internalCascadeBindingScope binding)
      actualScope = terminalAuditEvidenceScope observedAuditScope
  if actualScope == expectedScope
    then Right ()
    else Left (CascadeTerminalAuditScopeMismatch expectedScope actualScope)
  expectedAwsScope <- case evidenceAwsScope (internalCascadeBindingScope binding) of
    Nothing -> Left CascadeCompiledAwsScopeMissing
    Just scope -> Right scope
  -- The catalog composed its exact ARNs for one account and region.  Joining
  -- that to the compiled program's own AWS scope keeps a caller from supplying
  -- a foreign-account retained set whose digest happens to match the claim.
  if retainedCatalogAwsScope catalog == expectedAwsScope
    then Right ()
    else
      Left
        ( CascadeTerminalAuditRetainedScopeMismatch
            expectedAwsScope
            (retainedCatalogAwsScope catalog)
        )
  let expectedRetainedDigest = retainedSetDigestFor catalog
      actualRetainedDigest = terminalAuditRetainedSetDigest observedAuditScope
  if actualRetainedDigest == expectedRetainedDigest
    then Right ()
    else
      Left
        ( CascadeTerminalAuditRetainedProjectionMismatch
            expectedRetainedDigest
            actualRetainedDigest
        )
  case terminalAuditResult observation of
    TerminalAuditConfirmedClean inventory ->
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

-- | Sprint 4.89: every custodial capability this cascade run holds is still
-- held.
--
-- Readiness is what admits local RKE2 uninstall, and the uninstall destroys the
-- retained store the checkpoints live in.  A run that has already lost one of
-- those checkpoints cannot name the resources it reached, so destroying the
-- store under that state is precisely the event that stranded two AWS
-- resources.  Custody is therefore a /component/ of the readiness composition
-- rather than a warning printed beside it: a run holding a lost capability has
-- no value to pass, so it cannot compose readiness at all.
--
-- The three convergence evidences say the resources are gone.  This one says
-- the run can still prove that about them, which is a different question and is
-- unanswered by all three.
data CascadeCapabilityCustodyEvidence
  = CascadeCapabilityCustodyEvidence !CascadeProofBinding
  deriving (Eq, Show)

-- | The capabilities a compiled cascade run holds, derived from its own
-- registered stack targets rather than authored.
--
-- A run proves absence for the registered targets its program names; the
-- checkpoint of every stack among them is a capability that run holds, because
-- holding it is what made those resources destroyable.  Deriving the set from
-- the program keeps a run from answering the custody question for a stack it
-- never touched, and keeps a stack the program does touch from going
-- unanswered.
cascadeExpectedCustodialCapabilities
  :: CompiledDesiredAbsenceProgram 'Cascade -> [CustodialCapability]
cascadeExpectedCustodialCapabilities compiled =
  [ CheckpointCapability key
  | key <- cascadeExpectedAbsenceKeys compiled
  , key `elem` registeredCheckpointCapabilities
  ]

-- | Admit a custody answer set for one compiled cascade run.
--
-- Refuses an answer set that is not exactly the derived capability set — an
-- unanswered capability is not a held one, and an answer about a foreign
-- capability is about another run — then refuses any lost capability and any
-- capability whose custody could not be observed.  A corrupt checkpoint is
-- unobservable rather than lost, and it refuses too: readiness may not be
-- composed over a capability nobody could answer for.
mkCascadeCapabilityCustodyEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> [CheckpointCustody]
  -> Either CascadeEvidenceError CascadeCapabilityCustodyEvidence
mkCascadeCapabilityCustodyEvidence compiled answers = do
  binding <- cascadeProofBinding compiled
  let expected = sort (nub (cascadeExpectedCustodialCapabilities compiled))
      answered = sort (nub (map checkpointCustodyCapability answers))
  if answered == expected
    then Right ()
    else Left (CascadeCustodyAnswerSetMismatch expected answered)
  case [loss | CheckpointCustodyLost loss <- answers] of
    [] -> Right ()
    lost : rest -> Left (CascadeCustodyCapabilityLost (lost :| rest))
  case [ (capability, detail)
       | CheckpointCustodyUnobservable capability detail <- answers
       ] of
    [] -> Right ()
    unobservable : rest ->
      Left (CascadeCustodyCapabilityUnobservable (unobservable :| rest))
  Right (CascadeCapabilityCustodyEvidence binding)

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

-- | Sprint 4.86: the three convergence evidences all bind to this compiled run.
--
-- It exists so the pre-uninstall report can be /rendered/ outside this module
-- while still being admitted inside it.  A report is a durable statement that
-- one run reached exact absence, disposed its credentials, and passed its
-- terminal audit; rendering it from a compiled program that some other run's
-- evidences prove would make the statement about the wrong run, and the proof
-- bindings are the only thing that can refuse it.
--
-- It is deliberately the same three checks 'mkReadyToUninstallEvidence' makes
-- and not a weaker prefix of them, so a report and the readiness composed from
-- it cannot disagree about which run they belong to.
requireCascadeConvergenceBinding
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> Either CascadeEvidenceError ()
requireCascadeConvergenceBinding compiled absence credentials audit = do
  expectedBinding <- cascadeProofBinding compiled
  requireBinding CascadeAbsenceComponent expectedBinding (absenceBinding absence)
  requireBinding
    CascadeCredentialDispositionComponent
    expectedBinding
    (credentialBinding credentials)
  requireBinding
    CascadeTerminalAuditComponent
    expectedBinding
    (terminalAuditBinding audit)

mkReadyToUninstallEvidence
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeAbsenceEvidence
  -> CascadeCredentialDispositionEvidence
  -> CascadeTerminalAuditEvidence
  -> CascadeCapabilityCustodyEvidence
  -> CascadePreUninstallReportEvidence
  -> LocalCompletionPermit
  -> Either CascadeEvidenceError ReadyToUninstallEvidence
mkReadyToUninstallEvidence
  compiled
  absence
  credentials
  audit
  custody
  preUninstall
  permit = do
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
      CascadeCapabilityCustodyComponent
      expectedBinding
      (capabilityCustodyBinding custody)
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
        CleanupProofBinding
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

-- | The proof that a local RKE2 foundation is absent, indexed by the surface
-- whose compiled program licensed the uninstall.
--
-- Sprint @4.86@ added the index, and it is load-bearing rather than
-- descriptive.  The two surfaces reach local absence through different
-- authorities: a cascade may uninstall only under a signed one-shot permit
-- carried by 'ReadyToUninstallEvidence', while @cluster delete --yes@ has no
-- AWS targets, no terminal audit, and no permit to carry.  Before the index,
-- one type stood for both, so nothing but a caller's discipline stopped a
-- local-only absence from being handed to 'mkCascadeCompleteEvidence' — which
-- would have claimed a cascade converged on the strength of an observation
-- that says nothing about AWS.  There is deliberately no conversion in either
-- direction, and neither constructor is reachable outside this module.
data LocalUninstallEvidence (surface :: CleanupSurface) where
  CascadeLocalUninstallEvidence
    :: !ReadyFingerprint
    -> !AbsenceEvidence
    -> LocalUninstallEvidence 'Cascade
  LocalOnlyUninstallEvidence
    :: !LocalOnlyProofBinding
    -> !AbsenceEvidence
    -> LocalUninstallEvidence 'LocalOnly

deriving stock instance Eq (LocalUninstallEvidence surface)

deriving stock instance Show (LocalUninstallEvidence surface)

localUninstallAbsenceEvidence
  :: LocalUninstallEvidence surface -> AbsenceEvidence
localUninstallAbsenceEvidence evidence = case evidence of
  CascadeLocalUninstallEvidence _ absence -> absence
  LocalOnlyUninstallEvidence _ absence -> absence

mkLocalUninstallEvidence
  :: ReadyToUninstallEvidence
  -> LocalFoundationObservation
  -> Either CascadeEvidenceError (LocalUninstallEvidence 'Cascade)
mkLocalUninstallEvidence ready observation = do
  absence <-
    localFoundationAbsence (readyToUninstallScope ready) observation
  Right
    ( CascadeLocalUninstallEvidence
        (internalReadyToUninstallFingerprint ready)
        absence
    )

-- | The same observation on the local-only surface, licensed by the compiled
-- local-only program alone.
mkLocalOnlyUninstallEvidence
  :: CompiledDesiredAbsenceProgram 'LocalOnly
  -> LocalFoundationObservation
  -> Either CascadeEvidenceError (LocalUninstallEvidence 'LocalOnly)
mkLocalOnlyUninstallEvidence compiled observation = do
  binding <- localOnlyProofBinding compiled
  absence <-
    localFoundationAbsence (internalCascadeBindingScope binding) observation
  Right (LocalOnlyUninstallEvidence binding absence)

-- | Shared between the two surfaces: an observation of another scope is a
-- refusal, a present foundation has not converged, and an unobservable one has
-- said nothing.  Collapsing the last two would let an unreadable marker set
-- read as absence.
localFoundationAbsence
  :: ObservationEvidenceScope
  -> LocalFoundationObservation
  -> Either CascadeEvidenceError AbsenceEvidence
localFoundationAbsence expectedScope observation = do
  if localFoundationObservationScope observation == expectedScope
    then Right ()
    else
      Left
        ( CascadeLocalAbsenceScopeMismatch
            expectedScope
            (localFoundationObservationScope observation)
        )
  case localFoundationObservationResult observation of
    LocalFoundationAbsent evidence -> Right evidence
    LocalFoundationPresent -> Left CascadeLocalFoundationStillPresent
    LocalFoundationUnobservable failure ->
      Left (CascadeLocalFoundationUnobservable failure)

localOnlyProofBinding
  :: CompiledDesiredAbsenceProgram 'LocalOnly
  -> Either CascadeEvidenceError LocalOnlyProofBinding
localOnlyProofBinding = cleanupProofBinding LocalOnlySurface

-- | The terminal proof of a local-only teardown.
--
-- It is a different type from 'CascadeCompleteEvidence' and there is no
-- conversion: the whole content of the local-only surface is that it completes
-- /without/ claiming anything about AWS.
data LocalOnlyCompleteEvidence
  = LocalOnlyCompleteEvidence !LocalOnlyProofBinding !AbsenceEvidence
  deriving (Eq, Show)

localOnlyCompleteRunId :: LocalOnlyCompleteEvidence -> CleanupRunId
localOnlyCompleteRunId (LocalOnlyCompleteEvidence binding _) =
  internalCascadeBindingRunId binding

localOnlyCompleteGraphDigest :: LocalOnlyCompleteEvidence -> CleanupDigest
localOnlyCompleteGraphDigest (LocalOnlyCompleteEvidence binding _) =
  internalCascadeBindingGraphDigest binding

-- | The receipt is the one the local-only surface's own compiled node commits,
-- checked against the local-only binding by the same four rules a cascade
-- receipt goes through.  There is no permit and no report identity to compare,
-- because the local-only surface signs neither — which is exactly why its
-- completion cannot stand in for a cascade's.
mkLocalOnlyCompleteEvidence
  :: LocalUninstallEvidence 'LocalOnly
  -> DurableReceiptObservation
  -> Either CascadeEvidenceError LocalOnlyCompleteEvidence
mkLocalOnlyCompleteEvidence
  (LocalOnlyUninstallEvidence binding absence)
  receipt = do
    validateLocalOnlyReceipt binding LocalOnlyCompletionReceipt receipt
    Right (LocalOnlyCompleteEvidence binding absence)

validateLocalOnlyReceipt
  :: LocalOnlyProofBinding
  -> DurableReceiptKind
  -> DurableReceiptObservation
  -> Either CascadeEvidenceError ()
validateLocalOnlyReceipt binding expectedKind receipt
  | durableReceiptObservationKind receipt /= expectedKind =
      Left
        ( CascadeReceiptKindMismatch
            expectedKind
            (durableReceiptObservationKind receipt)
        )
  | durableReceiptObservationScope receipt
      /= internalCascadeBindingScope binding =
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
  -> LocalUninstallEvidence 'Cascade
  -> CascadeCompletionReceiptObservation
  -> Either CascadeEvidenceError CascadeCompleteEvidence
mkCascadeCompleteEvidence ready localAbsence completion = do
  let fingerprint = internalReadyToUninstallFingerprint ready
      CascadeLocalUninstallEvidence localFingerprint localAbsenceEvidence =
        localAbsence
  if localFingerprint == fingerprint
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
      , internalCascadeCompleteLocalAbsence = localAbsenceEvidence
      }

cascadeProofBinding
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> Either CascadeEvidenceError CascadeProofBinding
cascadeProofBinding = cleanupProofBinding CascadeSurface

-- | The binding a compiled program's proofs are bound to, for any surface.
--
-- The operation, registry revision, and durable run scope are checked
-- identically on every surface — they are facts about the compiler, not about
-- the target. The AWS scope is the one rule that differs, and it is read from
-- the same witness the compiler consulted: a surface that requires one refuses
-- its absence, and a surface that requires none refuses its presence, because a
-- local-only run naming a stack has proven nothing about it by observing the
-- host.
cleanupProofBinding
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> Either CascadeEvidenceError (CleanupProofBinding surface)
cleanupProofBinding surface compiled
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
  | requiresAwsScope && evidenceAwsScope scope == Nothing =
      Left CascadeCompiledAwsScopeMissing
  | not requiresAwsScope && evidenceAwsScope scope /= Nothing =
      Left CascadeLocalOnlyAwsScopePresent
  | otherwise =
      Right
        CleanupProofBinding
          { internalCascadeBindingRunId = runId
          , internalCascadeBindingGraphDigest =
              cleanupGraphDigest (compiledDesiredAbsenceGraph compiled)
          , internalCascadeBindingScope = scope
          }
 where
  requiresAwsScope = cleanupSurfaceRequiresAwsScope surface
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

capabilityCustodyBinding
  :: CascadeCapabilityCustodyEvidence -> CascadeProofBinding
capabilityCustodyBinding (CascadeCapabilityCustodyEvidence binding) = binding

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision revision) = revision

-- | A fixed package-private fixture used only to exercise closed production
-- boundaries without publishing an authority-bearing value to a dependent
-- component.  The public facade exposes only the regression booleans below.
data FixedCascadeEvidenceFixture = FixedCascadeEvidenceFixture
  { fixedCascadeCompiled :: !(CompiledDesiredAbsenceProgram 'Cascade)
  , fixedCascadeRun :: !CleanupRun
  , fixedCascadeReady :: !ReadyToUninstallEvidence
  , fixedCascadeLocalUninstall :: !(LocalUninstallEvidence 'Cascade)
  , fixedCascadeComplete :: !CascadeCompleteEvidence
  }

withFixedCascadeEvidenceFixtureInternal
  :: ( CompiledDesiredAbsenceProgram 'Cascade
       -> CleanupRun
       -> ReadyToUninstallEvidence
       -> LocalUninstallEvidence 'Cascade
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
       -> LocalUninstallEvidence 'Cascade
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

-- | Hand a package-private consumer the three node-5\/6 evidences a Stage-C
-- readiness proof composes with, for one fixed compiled cascade run.
--
-- The Stage-C interpreter takes those evidences as inputs because earlier
-- cascade nodes produce them; without this accessor its own regression would
-- have to rebuild the registered-key observation set, the retained catalog,
-- and the audit scope, which would make its fixture a second copy of this
-- one and let the two drift.  Nothing authority-bearing escapes: the callback
-- receives opaque evidence values and the fixture stays inside the package.
withCascadePreUninstallInputsInternal
  :: Text
  -> ( CompiledDesiredAbsenceProgram 'Cascade
       -> CleanupRun
       -> CascadeAbsenceEvidence
       -> CascadeCredentialDispositionEvidence
       -> CascadeTerminalAuditEvidence
       -> CascadeCapabilityCustodyEvidence
       -> result
     )
  -> Either Text result
withCascadePreUninstallInputsInternal rawRunId consume = do
  fixture <- fixedCascadeEvidenceFixtureFor rawRunId fixedCascadeFoundation
  let compiled = fixedCascadeCompiled fixture
  pure
    ( consume
        compiled
        (fixedCascadeRun fixture)
        (fixedCascadeAbsence compiled)
        (fixedCascadeCredentialsFor compiled)
        (fixedCascadeAuditFor compiled)
        (fixedCascadeCustodyFor compiled)
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
  , cascadeEvidenceRegressionLocalOnlyChainCloses :: !Bool
  , cascadeEvidenceRegressionLocalOnlyAwsScopeUncompilable :: !Bool
  , cascadeEvidenceRegressionLocalOnlyReceiptRefused :: !Bool
  , cascadeEvidenceRegressionLocalOnlyAbsenceRefused :: !Bool
  , cascadeEvidenceRegressionBindingGeneralisationPreserving :: !Bool
  , cascadeEvidenceRegressionCustodyLostRefused :: !Bool
  , cascadeEvidenceRegressionCustodyUnobservableRefused :: !Bool
  , cascadeEvidenceRegressionCustodyIncompleteRefused :: !Bool
  , cascadeEvidenceRegressionCustodyForeignBindingRefused :: !Bool
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
      custodyCapabilities = cascadeExpectedCustodialCapabilities compiled
      custodyAnswersWithFirst answerFor = case custodyCapabilities of
        [] -> []
        first : rest -> answerFor first : map CheckpointCustodyHeld rest
      lostFirst capability =
        CheckpointCustodyLost
          (CapabilityLoss capability "the encrypted checkpoint object is absent")
      unobservableFirst capability =
        CheckpointCustodyUnobservable capability "unparseable"
      -- Sprint 4.86: the local-only surface, compiled from the same run id and
      -- foundation with no AWS scope at all.  It is a second compiled program
      -- rather than the cascade program re-read, because the whole content of
      -- the surface is that it names no stack.
      localOnlyCompiled =
        compileDesiredAbsenceGraph
          (compiledDesiredAbsenceRunId compiled)
          fixedCascadeFoundation
          Nothing
          LocalOnlySurface
      localOnlyScoped =
        compileDesiredAbsenceGraph
          (compiledDesiredAbsenceRunId compiled)
          fixedCascadeFoundation
          (Just fixedCascadeAwsScope)
          LocalOnlySurface
      localOnlyReceiptFor program result =
        DurableReceiptObservation
          { durableReceiptObservationKind = LocalOnlyCompletionReceipt
          , durableReceiptObservationScope =
              compiledDesiredAbsenceObservationScope program
          , durableReceiptObservationGraphDigest =
              cleanupGraphDigest (compiledDesiredAbsenceGraph program)
          , durableReceiptObservationResult = result
          }
      localOnlyAbsentObservation program =
        LocalFoundationObservation
          { localFoundationObservationScope =
              compiledDesiredAbsenceObservationScope program
          , localFoundationObservationResult =
              LocalFoundationAbsent
                (AbsenceEvidence "local-rke2-fixed-local-only-not-found")
          }
      localOnlyChain = case localOnlyCompiled of
        Left _ -> False
        Right program ->
          case mkLocalOnlyUninstallEvidence
            program
            (localOnlyAbsentObservation program) of
            Left _ -> False
            Right absence ->
              case mkLocalOnlyCompleteEvidence
                absence
                (localOnlyReceiptFor program DurableReceiptObserved) of
                Left _ -> False
                Right completed ->
                  localOnlyCompleteRunId completed
                    == compiledDesiredAbsenceRunId compiled
                    && localOnlyCompleteGraphDigest completed
                      == cleanupGraphDigest
                        (compiledDesiredAbsenceGraph program)
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
            (mkCascadeTerminalAuditEvidence fixedCascadeRetainedCatalog compiled badAudit)
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
                (fixedCascadeCustodyFor compiled)
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
      , -- The local-only surface closes on its own terms: an observed absence
        -- and its own committed receipt, with no report identity and no
        -- permit.  Handing the value it produces to `mkCascadeCompleteEvidence`
        -- is a type error rather than a runtime refusal, which is why there is
        -- no arm for it here.
        cascadeEvidenceRegressionLocalOnlyChainCloses = localOnlyChain
      , -- Measured where it is decidable: a local-only program carrying an AWS
        -- scope does not compile at all, so no such program can reach the
        -- binding.  The binding keeps its own AWS check anyway, because this
        -- module must not depend on another module's invariant to know that a
        -- local-only proof names no stack.
        cascadeEvidenceRegressionLocalOnlyAwsScopeUncompilable =
          case localOnlyScoped of
            Left _ -> True
            Right _ -> False
      , cascadeEvidenceRegressionLocalOnlyReceiptRefused =
          case localOnlyCompiled of
            Left _ -> False
            Right program ->
              case mkLocalOnlyUninstallEvidence
                program
                (localOnlyAbsentObservation program) of
                Left _ -> False
                Right absence ->
                  isLeftMatching
                    isReceiptMissing
                    ( mkLocalOnlyCompleteEvidence
                        absence
                        (localOnlyReceiptFor program DurableReceiptMissing)
                    )
      , -- Sprint 4.89: the generalisation is proven to change no existing
        -- proof. The cascade instantiation of the surface-indexed binding is
        -- the value the cascade-only function produced, field for field, and
        -- the local-only instantiation is refused by the opposite AWS-scope
        -- rule rather than by a second implementation of the same checks.
        cascadeEvidenceRegressionBindingGeneralisationPreserving =
          cascadeProofBinding compiled
            == cleanupProofBinding CascadeSurface compiled
            && fmap internalCascadeBindingRunId (cascadeProofBinding compiled)
              == Right (compiledDesiredAbsenceRunId compiled)
            && fmap internalCascadeBindingGraphDigest (cascadeProofBinding compiled)
              == Right graphDigest
            && fmap internalCascadeBindingScope (cascadeProofBinding compiled)
              == Right scope
            && case localOnlyScoped of
              Left _ -> True
              Right scopedProgram ->
                cleanupProofBinding LocalOnlySurface scopedProgram
                  == Left CascadeLocalOnlyAwsScopePresent
      , cascadeEvidenceRegressionLocalOnlyAbsenceRefused =
          case localOnlyCompiled of
            Left _ -> False
            Right program ->
              mkLocalOnlyUninstallEvidence
                program
                LocalFoundationObservation
                  { localFoundationObservationScope =
                      compiledDesiredAbsenceObservationScope program
                  , localFoundationObservationResult = LocalFoundationPresent
                  }
                == Left CascadeLocalFoundationStillPresent
      , -- Sprint 4.89: a run that has lost one of the checkpoints it holds
        -- cannot compose readiness.  Measured as the composition refusing:
        -- there is no custody evidence to hand `mkReadyToUninstallEvidence`,
        -- so the refusal is reached before a report identity or a permit is
        -- involved at all.  Every other capability in the set is answered
        -- held, so the loss is the only thing wrong.
        cascadeEvidenceRegressionCustodyLostRefused =
          not (null custodyCapabilities)
            && isLeftMatching
              isCustodyLost
              ( mkCascadeCapabilityCustodyEvidence
                  compiled
                  (custodyAnswersWithFirst lostFirst)
              )
      , -- A corrupt checkpoint is unobservable rather than lost, and readiness
        -- refuses it too: a capability nobody could answer for is not a held
        -- one.  Refusing it here is the asymmetry the residue classifier
        -- already applies, carried into the composition.
        cascadeEvidenceRegressionCustodyUnobservableRefused =
          isLeftMatching
            isCustodyUnobservable
            ( mkCascadeCapabilityCustodyEvidence
                compiled
                (custodyAnswersWithFirst unobservableFirst)
            )
      , -- An unanswered capability is not a held one.  Dropping one answer
        -- refuses on the set rather than passing, which is what stops a run
        -- from reaching readiness by answering only the capabilities it
        -- happened to look at.
        cascadeEvidenceRegressionCustodyIncompleteRefused =
          isLeftMatching
            isCustodyAnswerSetMismatch
            ( mkCascadeCapabilityCustodyEvidence
                compiled
                (drop 1 (map CheckpointCustodyHeld custodyCapabilities))
            )
            && isLeftMatching
              isCustodyAnswerSetMismatch
              (mkCascadeCapabilityCustodyEvidence compiled [])
      , -- Custody binds to its run like every other component: another run's
        -- custody evidence is refused by the binding rather than accepted
        -- because its answers happened to be held.
        cascadeEvidenceRegressionCustodyForeignBindingRefused =
          isLeftMatching
            (== CascadeEvidenceBindingMismatch CascadeCapabilityCustodyComponent)
            ( mkReadyToUninstallEvidence
                compiled
                (fixedCascadeAbsence compiled)
                (fixedCascadeCredentials fixture)
                (fixedCascadeAudit fixture)
                (fixedCascadeCustodyFor (fixedCascadeCompiled other))
                (fixedCascadePreUninstall fixture)
                (fixedCascadePermit fixture)
            )
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
      custody = fixedCascadeCustodyFor compiled
      preUninstall = fixedCascadePreUninstallFor compiled reportDigest
      permit = fixedCascadePermitFor compiled reportDigest permitId
  ready <-
    firstShowInternal
      ( mkReadyToUninstallEvidence
          compiled
          absence
          credentials
          audit
          custody
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

-- | Every capability the compiled run holds, answered held.
--
-- Built by running the same admission the production path runs, over the same
-- derived capability set, so a change to what a cascade holds moves the fixture
-- rather than leaving it as an authored constant.
fixedCascadeCustodyFor
  :: CompiledDesiredAbsenceProgram 'Cascade
  -> CascadeCapabilityCustodyEvidence
fixedCascadeCustodyFor compiled =
  mustRightInternal
    ( mkCascadeCapabilityCustodyEvidence
        compiled
        (map CheckpointCustodyHeld (cascadeExpectedCustodialCapabilities compiled))
    )

fixedCascadeAudit :: FixedCascadeEvidenceFixture -> CascadeTerminalAuditEvidence
fixedCascadeAudit = fixedCascadeAuditFor . fixedCascadeCompiled

fixedCascadeAuditFor
  :: CompiledDesiredAbsenceProgram 'Cascade -> CascadeTerminalAuditEvidence
fixedCascadeAuditFor compiled =
  mustRightInternal
    ( mkCascadeTerminalAuditEvidence
        fixedCascadeRetainedCatalog
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
        (terminalAuditQueryDigestFor (terminalAuditQueryCatalog fixedRetainedNameBinding))
        (retainedSetDigestFor fixedCascadeRetainedCatalog)
    )

-- | The frozen retained catalog the regression audits against.  Its names are
-- the fixture's, not the operator's: the fixture proves the join between the
-- catalog and the audit, and a live run composes its own catalog from
-- configuration.
fixedCascadeRetainedCatalog :: RetainedCatalog 'Cascade
fixedCascadeRetainedCatalog =
  mustRightInternal
    ( retainedCatalogFor
        CascadeSurface
        fixedCascadeAwsScope
        fixedRetainedNameBinding
    )

fixedRetainedNameBinding :: RetainedNameBinding
fixedRetainedNameBinding =
  mustRightInternal
    ( mkRetainedNameBinding
        "prodbox-fixed-state"
        "prodbox-fixed-ses-capture"
        "fixed.example.test"
        "aws-eks-test-cluster"
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

isCustodyLost :: CascadeEvidenceError -> Bool
isCustodyLost err = case err of
  CascadeCustodyCapabilityLost _ -> True
  _ -> False

isCustodyUnobservable :: CascadeEvidenceError -> Bool
isCustodyUnobservable err = case err of
  CascadeCustodyCapabilityUnobservable _ -> True
  _ -> False

isCustodyAnswerSetMismatch :: CascadeEvidenceError -> Bool
isCustodyAnswerSetMismatch err = case err of
  CascadeCustodyAnswerSetMismatch _ _ -> True
  _ -> False

isReceiptMissing :: CascadeEvidenceError -> Bool
isReceiptMissing err = case err of
  CascadeReceiptNotObserved {} -> True
  _ -> False

isPermitOperationsMismatch :: CascadeEvidenceError -> Bool
isPermitOperationsMismatch err = case err of
  CascadePermitOperationReferencesMismatch {} -> True
  _ -> False
