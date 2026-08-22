{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Package-private canonical codec and exact recompilation checks for a
-- desired-absence program descriptor.  The public facade can capture a
-- candidate from an already compiled program and its exact initial run; only
-- the Authority repository imports the decoder that can validate stored bytes.
module Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor.Internal
  ( CleanupProgramDescriptor
  , CleanupProgramDescriptorError (..)
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorRunId
  , cleanupProgramDescriptorSurface
  , cleanupProgramDescriptorFoundation
  , cleanupProgramDescriptorAwsScope
  , cleanupProgramDescriptorRegistryRevision
  , cleanupProgramDescriptorLifecycleOperation
  , cleanupProgramDescriptorGraphDigest
  , cleanupProgramDescriptorCapabilityCatalogDigest
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorFormatVersion
  , cleanupProgramDescriptorCompilerVersion
  , cleanupProgramDescriptorOperationIdentityVersion
  , cleanupProgramDescriptorCapabilityCatalogVersion
  , cleanupProgramDescriptorCapabilitySetVersion
  , maximumCleanupProgramDescriptorBytes
  , decodeAndValidateCleanupProgramDescriptor
  , withRecompiledCleanupProgramDescriptor
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupLease (..)
  , CleanupRun (..)
  , CleanupRunCodecError
  , CleanupRunError
  , CleanupRunId
  , cleanupDigestOfBytes
  , cleanupDigestText
  , cleanupNodeIdText
  , cleanupRunIdText
  , decodeCleanupRun
  , encodeCleanupRun
  , mkCleanupDigest
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , DesiredAbsenceGraphError
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRecoveryCapabilityCatalogDigest
  , compiledDesiredAbsenceRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , CleanupSurfaceWitness (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (ReconcileDesiredAbsent)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , ResourceKind (..)
  , cleanupSurfaceFromWitness
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , managedResourceCoordinateDigestText
  , registeredResourceKeyText
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , TeardownOperation (..)
  , registeredTargetCoordinateDigest
  , registeredTargetKey
  , registeredTargetKind
  , registeredTargetLifecycleClass
  , registeredTargetRecoveryCapabilities
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( recoveryCapabilityCatalogVersion
  , recoveryCapabilitySetDigest
  , recoveryCapabilitySetNames
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal
  ( recoveryCapabilityOperationIdentityVersion
  , recoveryCapabilitySetVersion
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)

data CleanupProgramDescriptor = CleanupProgramDescriptor
  { internalDescriptorRunId :: !CleanupRunId
  , internalDescriptorSurface :: !CleanupSurface
  , internalDescriptorFoundation :: !LinuxRke2FoundationId
  , internalDescriptorAwsScope :: !(Maybe AwsScope)
  , internalDescriptorRegistryRevision :: !RegistryRevision
  , internalDescriptorLifecycleOperation :: !LifecycleOperation
  , internalDescriptorGraphDigest :: !CleanupDigest
  , internalDescriptorCapabilityCatalogDigest :: !Text
  , internalDescriptorBytes :: !ByteString
  }

instance Eq CleanupProgramDescriptor where
  left == right =
    cleanupProgramDescriptorBytes left == cleanupProgramDescriptorBytes right

instance Show CleanupProgramDescriptor where
  show descriptor =
    "<cleanup-program-descriptor:"
      <> Text.unpack (cleanupRunIdText (cleanupProgramDescriptorRunId descriptor))
      <> ">"

data CleanupProgramDescriptorError
  = CleanupProgramDescriptorEmpty
  | CleanupProgramDescriptorTooLarge !Int !Int
  | CleanupProgramDescriptorDecodeFailed !Text
  | CleanupProgramDescriptorNonCanonical
  | CleanupProgramDescriptorVersionUnsupported !Int
  | CleanupProgramDescriptorFieldInvalid !Text
  | CleanupProgramDescriptorRunCodecFailed !CleanupRunCodecError
  | CleanupProgramDescriptorRunInvalid !CleanupRunError
  | CleanupProgramDescriptorRunIdMismatch !CleanupRunId !CleanupRunId
  | CleanupProgramDescriptorGraphMismatch
  | CleanupProgramDescriptorGraphDigestMismatch !CleanupDigest !CleanupDigest
  | CleanupProgramDescriptorRunNotInitial
  | CleanupProgramDescriptorScopeMismatch !Text
  | CleanupProgramDescriptorCompilerVersionMismatch !Text !Text
  | CleanupProgramDescriptorOperationIdentityVersionMismatch !Text !Text
  | CleanupProgramDescriptorCapabilityCatalogVersionMismatch !Text !Text
  | CleanupProgramDescriptorCapabilitySetVersionMismatch !Text !Text
  | CleanupProgramDescriptorCapabilityCatalogDigestMismatch !Text !Text
  | CleanupProgramDescriptorSemanticOperationCatalogMismatch
  | CleanupProgramDescriptorCompilationFailed !DesiredAbsenceGraphError
  deriving stock (Eq, Show)

data SemanticTargetWire = SemanticTargetWire
  { semanticTargetKey :: !Text
  , semanticTargetLifecycleClass :: !(Maybe Text)
  , semanticTargetKind :: !Text
  , semanticTargetCoordinateDigest :: !Text
  , semanticTargetRecoveryCapabilities :: ![Text]
  , semanticTargetRecoveryCapabilitySetDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data SemanticOperationWire = SemanticOperationWire
  { semanticOperationNodeId :: !Text
  , semanticOperationTag :: !Text
  , semanticOperationTarget :: !(Maybe SemanticTargetWire)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data CleanupProgramDescriptorWire = CleanupProgramDescriptorWire
  { descriptorWireFormatVersion :: !Int
  , descriptorWireRunId :: !Text
  , descriptorWireSurface :: !Int
  , descriptorWireFoundation :: !Text
  , descriptorWireAwsAccount :: !(Maybe Text)
  , descriptorWireAwsRegion :: !(Maybe Text)
  , descriptorWireRegistryRevision :: !Text
  , descriptorWireDurableRunScope :: !Text
  , descriptorWireLifecycleOperation :: !Int
  , descriptorWireCompilerVersion :: !Text
  , descriptorWireOperationIdentityVersion :: !Text
  , descriptorWireCapabilityCatalogVersion :: !Text
  , descriptorWireCapabilitySetVersion :: !Text
  , descriptorWireGraphDigest :: !Text
  , descriptorWireCapabilityCatalogDigest :: !Text
  , descriptorWireInitialRun :: !ByteString
  , descriptorWireSemanticOperations :: ![SemanticOperationWire]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

cleanupProgramDescriptorFormatVersion :: Int
cleanupProgramDescriptorFormatVersion = 1

cleanupProgramDescriptorCompilerVersion :: Text
cleanupProgramDescriptorCompilerVersion =
  "lifecycle-desired-absence-program-compiler/v3"

cleanupProgramDescriptorOperationIdentityVersion :: Text
cleanupProgramDescriptorOperationIdentityVersion =
  recoveryCapabilityOperationIdentityVersion

cleanupProgramDescriptorCapabilityCatalogVersion :: Text
cleanupProgramDescriptorCapabilityCatalogVersion =
  recoveryCapabilityCatalogVersion

cleanupProgramDescriptorCapabilitySetVersion :: Text
cleanupProgramDescriptorCapabilitySetVersion = recoveryCapabilitySetVersion

maximumCleanupProgramDescriptorBytes :: Int
maximumCleanupProgramDescriptorBytes = 2 * 1024 * 1024

maximumDescriptorCleanupRunBytes :: Int
maximumDescriptorCleanupRunBytes = 1024 * 1024

captureCleanupProgramDescriptor
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either CleanupProgramDescriptorError CleanupProgramDescriptor
captureCleanupProgramDescriptor compiled initialRun = do
  validateCompiledInitialRun compiled initialRun
  initialRunBytes <-
    first
      CleanupProgramDescriptorRunCodecFailed
      (encodeCleanupRun maximumDescriptorCleanupRunBytes initialRun)
  let scope = compiledDesiredAbsenceObservationScope compiled
      wire =
        CleanupProgramDescriptorWire
          { descriptorWireFormatVersion = cleanupProgramDescriptorFormatVersion
          , descriptorWireRunId =
              cleanupRunIdText (compiledDesiredAbsenceRunId compiled)
          , descriptorWireSurface = fromEnum (evidenceCleanupSurface scope)
          , descriptorWireFoundation = foundationText scope
          , descriptorWireAwsAccount = awsAccountText <$> evidenceAwsScope scope
          , descriptorWireAwsRegion = awsRegionText <$> evidenceAwsScope scope
          , descriptorWireRegistryRevision = registryRevisionText scope
          , descriptorWireDurableRunScope = durableRunScopeText scope
          , descriptorWireLifecycleOperation = 0
          , descriptorWireCompilerVersion =
              cleanupProgramDescriptorCompilerVersion
          , descriptorWireOperationIdentityVersion =
              cleanupProgramDescriptorOperationIdentityVersion
          , descriptorWireCapabilityCatalogVersion =
              cleanupProgramDescriptorCapabilityCatalogVersion
          , descriptorWireCapabilitySetVersion =
              cleanupProgramDescriptorCapabilitySetVersion
          , descriptorWireGraphDigest =
              cleanupDigestText (cleanupRunGraphDigest initialRun)
          , descriptorWireCapabilityCatalogDigest =
              compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
          , descriptorWireInitialRun = initialRunBytes
          , descriptorWireSemanticOperations = semanticOperations compiled
          }
      bytes = LazyByteString.toStrict (serialise wire)
  when
    (ByteString.length bytes > maximumCleanupProgramDescriptorBytes)
    ( Left
        ( CleanupProgramDescriptorTooLarge
            (ByteString.length bytes)
            maximumCleanupProgramDescriptorBytes
        )
    )
  decodeAndValidateCleanupProgramDescriptor bytes

decodeAndValidateCleanupProgramDescriptor
  :: ByteString
  -> Either CleanupProgramDescriptorError CleanupProgramDescriptor
decodeAndValidateCleanupProgramDescriptor bytes =
  decodeAndValidateCleanupProgramDescriptorWith bytes $ \_ _ _ descriptor ->
    descriptor

-- | Package-private restart eliminator.  The retained canonical bytes are
-- decoded again and the closed surface witness is used to recompile and
-- revalidate both the program and its exact initial run before either value
-- reaches the continuation.
withRecompiledCleanupProgramDescriptor
  :: CleanupProgramDescriptor
  -> ( forall surface
        . CleanupSurfaceWitness surface
       -> CompiledDesiredAbsenceProgram surface
       -> CleanupRun
       -> result
     )
  -> Either CleanupProgramDescriptorError result
withRecompiledCleanupProgramDescriptor descriptor consume =
  decodeAndValidateCleanupProgramDescriptorWith
    (internalDescriptorBytes descriptor)
    (\witness compiled initialRun _ -> consume witness compiled initialRun)

decodeAndValidateCleanupProgramDescriptorWith
  :: ByteString
  -> ( forall surface
        . CleanupSurfaceWitness surface
       -> CompiledDesiredAbsenceProgram surface
       -> CleanupRun
       -> CleanupProgramDescriptor
       -> result
     )
  -> Either CleanupProgramDescriptorError result
decodeAndValidateCleanupProgramDescriptorWith bytes consume = do
  when (ByteString.null bytes) (Left CleanupProgramDescriptorEmpty)
  when
    (ByteString.length bytes > maximumCleanupProgramDescriptorBytes)
    ( Left
        ( CleanupProgramDescriptorTooLarge
            (ByteString.length bytes)
            maximumCleanupProgramDescriptorBytes
        )
    )
  wire <-
    first
      (CleanupProgramDescriptorDecodeFailed . Text.pack . show)
      (deserialiseOrFail (LazyByteString.fromStrict bytes))
  unless
    (LazyByteString.toStrict (serialise wire) == bytes)
    (Left CleanupProgramDescriptorNonCanonical)
  unless
    (descriptorWireFormatVersion wire == cleanupProgramDescriptorFormatVersion)
    ( Left
        ( CleanupProgramDescriptorVersionUnsupported
            (descriptorWireFormatVersion wire)
        )
    )
  requireVersion
    CleanupProgramDescriptorCompilerVersionMismatch
    cleanupProgramDescriptorCompilerVersion
    (descriptorWireCompilerVersion wire)
  requireVersion
    CleanupProgramDescriptorOperationIdentityVersionMismatch
    cleanupProgramDescriptorOperationIdentityVersion
    (descriptorWireOperationIdentityVersion wire)
  requireVersion
    CleanupProgramDescriptorCapabilityCatalogVersionMismatch
    cleanupProgramDescriptorCapabilityCatalogVersion
    (descriptorWireCapabilityCatalogVersion wire)
  requireVersion
    CleanupProgramDescriptorCapabilitySetVersionMismatch
    cleanupProgramDescriptorCapabilitySetVersion
    (descriptorWireCapabilitySetVersion wire)
  runId <-
    first
      CleanupProgramDescriptorFieldInvalid
      (mkCleanupRunId (descriptorWireRunId wire))
  surface <- decodeSurface (descriptorWireSurface wire)
  foundationValue <-
    checkedText "Linux RKE2 foundation" 512 (descriptorWireFoundation wire)
  awsScope <- decodeAwsScope wire
  let foundation = LinuxRke2FoundationId foundationValue
      registryRevision = RegistryRevision (descriptorWireRegistryRevision wire)
      lifecycleOperation = ReconcileDesiredAbsent
  unless
    (registryRevision == lifecycleRegistryRevision)
    (Left (CleanupProgramDescriptorScopeMismatch "registry revision"))
  unless
    (descriptorWireLifecycleOperation wire == 0)
    (Left (CleanupProgramDescriptorScopeMismatch "lifecycle operation"))
  runScope <-
    checkedText
      "durable run scope"
      512
      (descriptorWireDurableRunScope wire)
  unless
    (runScope == cleanupRunIdText runId)
    (Left (CleanupProgramDescriptorScopeMismatch "durable run scope"))
  graphDigest <-
    first
      CleanupProgramDescriptorFieldInvalid
      (mkCleanupDigest (descriptorWireGraphDigest wire))
  catalogDigest <-
    validateSha256
      "recovery capability catalog digest"
      (descriptorWireCapabilityCatalogDigest wire)
  initialRun <-
    first
      CleanupProgramDescriptorRunCodecFailed
      ( decodeCleanupRun
          maximumDescriptorCleanupRunBytes
          (descriptorWireInitialRun wire)
      )
  validateForSurfaceWith
    surface
    runId
    foundation
    awsScope
    wire
    initialRun
    ( \witness compiled validatedRun descriptor ->
        consume
          witness
          compiled
          validatedRun
          descriptor
            { internalDescriptorRegistryRevision = registryRevision
            , internalDescriptorLifecycleOperation = lifecycleOperation
            , internalDescriptorGraphDigest = graphDigest
            , internalDescriptorCapabilityCatalogDigest = catalogDigest
            , internalDescriptorBytes = bytes
            }
    )

validateForSurfaceWith
  :: CleanupSurface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> CleanupProgramDescriptorWire
  -> CleanupRun
  -> ( forall surface
        . CleanupSurfaceWitness surface
       -> CompiledDesiredAbsenceProgram surface
       -> CleanupRun
       -> CleanupProgramDescriptor
       -> result
     )
  -> Either CleanupProgramDescriptorError result
validateForSurfaceWith surface runId foundation awsScope wire initialRun consume =
  case surface of
    LocalOnly ->
      validateDescriptorForWitnessWith
        LocalOnlySurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume
    Cascade ->
      validateDescriptorForWitnessWith
        CascadeSurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume
    ExplicitPerRun ->
      validateDescriptorForWitnessWith
        ExplicitPerRunSurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume
    OperationalTeardown ->
      validateDescriptorForWitnessWith
        OperationalTeardownSurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume
    ExplicitLongLived ->
      validateDescriptorForWitnessWith
        ExplicitLongLivedSurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume
    TotalDecommission ->
      validateDescriptorForWitnessWith
        TotalDecommissionSurface
        runId
        foundation
        awsScope
        wire
        initialRun
        consume

validateDescriptorForWitnessWith
  :: CleanupSurfaceWitness surface
  -> CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> CleanupProgramDescriptorWire
  -> CleanupRun
  -> ( forall validatedSurface
        . CleanupSurfaceWitness validatedSurface
       -> CompiledDesiredAbsenceProgram validatedSurface
       -> CleanupRun
       -> CleanupProgramDescriptor
       -> result
     )
  -> Either CleanupProgramDescriptorError result
validateDescriptorForWitnessWith
  witness
  runId
  foundation
  awsScope
  wire
  initialRun
  consume = do
    compiled <-
      first
        CleanupProgramDescriptorCompilationFailed
        (compileDesiredAbsenceGraph runId foundation awsScope witness)
    validateCompiledWire compiled wire initialRun
    let descriptor =
          CleanupProgramDescriptor
            { internalDescriptorRunId = runId
            , internalDescriptorSurface = cleanupSurfaceFromWitness witness
            , internalDescriptorFoundation = foundation
            , internalDescriptorAwsScope = awsScope
            , internalDescriptorRegistryRevision = lifecycleRegistryRevision
            , internalDescriptorLifecycleOperation = ReconcileDesiredAbsent
            , internalDescriptorGraphDigest = cleanupRunGraphDigest initialRun
            , internalDescriptorCapabilityCatalogDigest =
                compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
            , internalDescriptorBytes = ByteString.empty
            }
    pure (consume witness compiled initialRun descriptor)

validateCompiledWire
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupProgramDescriptorWire
  -> CleanupRun
  -> Either CleanupProgramDescriptorError ()
validateCompiledWire compiled wire initialRun = do
  validateCompiledInitialRun compiled initialRun
  let scope = compiledDesiredAbsenceObservationScope compiled
      expectedGraphDigest = cleanupRunGraphDigest initialRun
      expectedCatalogDigest =
        compiledDesiredAbsenceRecoveryCapabilityCatalogDigest compiled
  observedGraphDigest <-
    first
      CleanupProgramDescriptorFieldInvalid
      (mkCleanupDigest (descriptorWireGraphDigest wire))
  unless
    (descriptorWireRunId wire == cleanupRunIdText (compiledDesiredAbsenceRunId compiled))
    (Left (CleanupProgramDescriptorScopeMismatch "run id"))
  unless
    (descriptorWireSurface wire == fromEnum (evidenceCleanupSurface scope))
    (Left (CleanupProgramDescriptorScopeMismatch "cleanup surface"))
  unless
    (descriptorWireFoundation wire == foundationText scope)
    (Left (CleanupProgramDescriptorScopeMismatch "Linux RKE2 foundation"))
  unless
    (descriptorWireAwsAccount wire == (awsAccountText <$> evidenceAwsScope scope))
    (Left (CleanupProgramDescriptorScopeMismatch "AWS account"))
  unless
    (descriptorWireAwsRegion wire == (awsRegionText <$> evidenceAwsScope scope))
    (Left (CleanupProgramDescriptorScopeMismatch "AWS region"))
  unless
    (descriptorWireRegistryRevision wire == registryRevisionText scope)
    (Left (CleanupProgramDescriptorScopeMismatch "registry revision"))
  unless
    (descriptorWireDurableRunScope wire == durableRunScopeText scope)
    (Left (CleanupProgramDescriptorScopeMismatch "durable run scope"))
  unless
    (evidenceLifecycleOperation scope == ReconcileDesiredAbsent)
    (Left (CleanupProgramDescriptorScopeMismatch "lifecycle operation"))
  unless
    (observedGraphDigest == expectedGraphDigest)
    ( Left
        ( CleanupProgramDescriptorGraphDigestMismatch
            expectedGraphDigest
            observedGraphDigest
        )
    )
  unless
    (descriptorWireCapabilityCatalogDigest wire == expectedCatalogDigest)
    ( Left
        ( CleanupProgramDescriptorCapabilityCatalogDigestMismatch
            expectedCatalogDigest
            (descriptorWireCapabilityCatalogDigest wire)
        )
    )
  unless
    (descriptorWireSemanticOperations wire == semanticOperations compiled)
    (Left CleanupProgramDescriptorSemanticOperationCatalogMismatch)

validateCompiledInitialRun
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either CleanupProgramDescriptorError ()
validateCompiledInitialRun compiled initialRun = do
  unless
    (cleanupRunId initialRun == compiledDesiredAbsenceRunId compiled)
    ( Left
        ( CleanupProgramDescriptorRunIdMismatch
            (compiledDesiredAbsenceRunId compiled)
            (cleanupRunId initialRun)
        )
    )
  unless
    (cleanupRunGraph initialRun == compiledDesiredAbsenceGraph compiled)
    (Left CleanupProgramDescriptorGraphMismatch)
  expectedInitial <-
    first
      CleanupProgramDescriptorRunInvalid
      ( newCleanupRun
          (compiledDesiredAbsenceRunId compiled)
          (compiledDesiredAbsenceGraph compiled)
          (cleanupLeaseOwner lease)
          0
          (cleanupLeaseExpiresAtMicros lease)
      )
  unless
    (cleanupRunGraphDigest initialRun == cleanupRunGraphDigest expectedInitial)
    ( Left
        ( CleanupProgramDescriptorGraphDigestMismatch
            (cleanupRunGraphDigest expectedInitial)
            (cleanupRunGraphDigest initialRun)
        )
    )
  unless (initialRun == expectedInitial) (Left CleanupProgramDescriptorRunNotInitial)
 where
  lease = cleanupRunLease initialRun

semanticOperations
  :: CompiledDesiredAbsenceProgram surface -> [SemanticOperationWire]
semanticOperations compiled =
  [ SemanticOperationWire
      { semanticOperationNodeId = cleanupNodeIdText nodeId
      , semanticOperationTag = teardownOperationTag operation
      , semanticOperationTarget = semanticTarget <$> operationTarget operation
      }
  | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
  ]

semanticTarget :: RegisteredTargetBinding -> SemanticTargetWire
semanticTarget target =
  SemanticTargetWire
    { semanticTargetKey = registeredResourceKeyText (registeredTargetKey target)
    , semanticTargetLifecycleClass =
        lifecycleClassText <$> registeredTargetLifecycleClass target
    , semanticTargetKind = resourceKindText (registeredTargetKind target)
    , semanticTargetCoordinateDigest =
        managedResourceCoordinateDigestText
          (registeredTargetCoordinateDigest target)
    , semanticTargetRecoveryCapabilities =
        recoveryCapabilitySetNames (registeredTargetRecoveryCapabilities target)
    , semanticTargetRecoveryCapabilitySetDigest =
        recoveryCapabilitySetDigest (registeredTargetRecoveryCapabilities target)
    }

operationTarget
  :: TeardownOperation surface -> Maybe RegisteredTargetBinding
operationTarget operation = case operation of
  ObserveRegisteredTarget target -> Just target
  ObserveStackCheckpointPair target -> Just target
  ReconcileStackCheckpointRestore target -> Just target
  ReadBackStackCheckpointRecovery target -> Just target
  CommitAwsStackReaderBundle target -> Just target
  ReadBackAwsStackReaderBundle target -> Just target
  CommitEksDrainIntent target -> Just target
  ReadBackEksDrainIntent target -> Just target
  DrainEksKubernetesResources target -> Just target
  ReadBackEksKubernetesDrain target -> Just target
  ReconcileRegisteredTargetAbsent target -> Just target
  ReadBackRegisteredTargetAbsent target -> Just target
  RetireStackCheckpointPair target -> Just target
  ReadBackStackCheckpointRetirement target -> Just target
  EstablishRecoveryPlane _ -> Nothing
  ReadBackRecoveryPlane _ -> Nothing
  ObserveRecoveryPlaneDisposition _ -> Nothing
  AuditCascadeEscapes -> Nothing
  CommitCascadePreUninstallReport -> Nothing
  ReadBackCascadePreUninstallReport -> Nothing
  UninstallCascadeLocalFoundation -> Nothing
  ReadBackCascadeLocalAbsence -> Nothing
  CommitCascadeCompletion -> Nothing
  ReadBackCascadeCompletion -> Nothing
  UninstallLocalOnlyFoundation -> Nothing
  ReadBackLocalOnlyAbsence -> Nothing
  CommitLocalOnlyCompletion -> Nothing
  ReadBackLocalOnlyCompletion -> Nothing
  RevokeOperationalCredential _ -> Nothing
  ReadBackOperationalCredentialRevocation _ -> Nothing
  CommitOrdinarySurfaceReport -> Nothing
  ReadBackOrdinarySurfaceReport -> Nothing
  AuditTotalDecommissionEscapes -> Nothing
  ObserveExternalDecommissionReceipt -> Nothing
  UninstallDecommissionLocalFoundation -> Nothing
  ReadBackDecommissionLocalAbsence -> Nothing
  ApplyDecommissionLocalDataDisposition -> Nothing
  ReadBackDecommissionLocalDataDisposition -> Nothing
  CommitDecommissionTerminalReceipt -> Nothing
  ReadBackDecommissionTerminalReceipt -> Nothing

decodeSurface
  :: Int -> Either CleanupProgramDescriptorError CleanupSurface
decodeSurface value
  | value < fromEnum (minBound :: CleanupSurface)
      || value > fromEnum (maxBound :: CleanupSurface) =
      Left (CleanupProgramDescriptorFieldInvalid "cleanup surface")
  | otherwise = Right (toEnum value)

decodeAwsScope
  :: CleanupProgramDescriptorWire
  -> Either CleanupProgramDescriptorError (Maybe AwsScope)
decodeAwsScope wire = case (descriptorWireAwsAccount wire, descriptorWireAwsRegion wire) of
  (Nothing, Nothing) -> Right Nothing
  (Just account, Just region) -> do
    account' <- checkedText "AWS account" 128 account
    region' <- checkedText "AWS region" 128 region
    Right (Just (AwsScope (AwsAccountId account') (AwsRegion region')))
  _ -> Left (CleanupProgramDescriptorScopeMismatch "incomplete AWS scope")

requireVersion
  :: (Text -> Text -> CleanupProgramDescriptorError)
  -> Text
  -> Text
  -> Either CleanupProgramDescriptorError ()
requireVersion constructor expected observed =
  unless (observed == expected) (Left (constructor expected observed))

checkedText
  :: Text
  -> Int
  -> Text
  -> Either CleanupProgramDescriptorError Text
checkedText label maximumLength value
  | Text.null value = invalid "is empty"
  | Text.length value > maximumLength = invalid "exceeds its bound"
  | Text.any isControl value = invalid "contains control characters"
  | Text.any isSpace value = invalid "contains whitespace"
  | otherwise = Right value
 where
  invalid detail =
    Left
      ( CleanupProgramDescriptorFieldInvalid
          (label <> " " <> detail)
      )

validateSha256
  :: Text
  -> Text
  -> Either CleanupProgramDescriptorError Text
validateSha256 label value = do
  _ <-
    first
      (CleanupProgramDescriptorFieldInvalid . ((label <> ": ") <>))
      (mkCleanupDigest value)
  pure value

foundationText :: ObservationEvidenceScope -> Text
foundationText scope =
  case evidenceLinuxRke2Foundation scope of
    LinuxRke2FoundationId value -> value

awsAccountText :: AwsScope -> Text
awsAccountText (AwsScope (AwsAccountId value) _) = value

awsRegionText :: AwsScope -> Text
awsRegionText (AwsScope _ (AwsRegion value)) = value

registryRevisionText :: ObservationEvidenceScope -> Text
registryRevisionText scope =
  case evidenceRegistryRevision scope of
    RegistryRevision value -> value

durableRunScopeText :: ObservationEvidenceScope -> Text
durableRunScopeText scope =
  case evidenceDurableRunScope scope of
    DurableObservationRunScope value -> value

lifecycleClassText :: LifecycleClass -> Text
lifecycleClassText lifecycleClass = case lifecycleClass of
  PerRun -> "per-run"
  LongLived -> "long-lived"
  Operational -> "operational"

resourceKindText :: ResourceKind -> Text
resourceKindText resourceKind = case resourceKind of
  Stack -> "stack"
  ControllerFamily -> "controller-family"
  Singleton -> "singleton"
  Topic -> "topic"
  Credential -> "credential"
  VolumeFamily -> "volume-family"
  DnsZoneFamily -> "dns-zone-family"
  DnsRecordFamily -> "dns-record-family"
  LocalSubstrate -> "local-substrate"

cleanupProgramDescriptorRunId :: CleanupProgramDescriptor -> CleanupRunId
cleanupProgramDescriptorRunId = internalDescriptorRunId

cleanupProgramDescriptorSurface :: CleanupProgramDescriptor -> CleanupSurface
cleanupProgramDescriptorSurface = internalDescriptorSurface

cleanupProgramDescriptorFoundation
  :: CleanupProgramDescriptor -> LinuxRke2FoundationId
cleanupProgramDescriptorFoundation = internalDescriptorFoundation

cleanupProgramDescriptorAwsScope
  :: CleanupProgramDescriptor -> Maybe AwsScope
cleanupProgramDescriptorAwsScope = internalDescriptorAwsScope

cleanupProgramDescriptorRegistryRevision
  :: CleanupProgramDescriptor -> RegistryRevision
cleanupProgramDescriptorRegistryRevision = internalDescriptorRegistryRevision

cleanupProgramDescriptorLifecycleOperation
  :: CleanupProgramDescriptor -> LifecycleOperation
cleanupProgramDescriptorLifecycleOperation = internalDescriptorLifecycleOperation

cleanupProgramDescriptorGraphDigest
  :: CleanupProgramDescriptor -> CleanupDigest
cleanupProgramDescriptorGraphDigest = internalDescriptorGraphDigest

cleanupProgramDescriptorCapabilityCatalogDigest
  :: CleanupProgramDescriptor -> Text
cleanupProgramDescriptorCapabilityCatalogDigest =
  internalDescriptorCapabilityCatalogDigest

cleanupProgramDescriptorDigest :: CleanupProgramDescriptor -> CleanupDigest
cleanupProgramDescriptorDigest = cleanupDigestOfBytes . internalDescriptorBytes

cleanupProgramDescriptorBytes :: CleanupProgramDescriptor -> ByteString
cleanupProgramDescriptorBytes = internalDescriptorBytes
