{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Durable lowering for the closed lifecycle teardown program.  Stable node
-- and operation identities are derived from the run, registry revision,
-- exact local/AWS evidence scope, surface, registered key, and operation tag;
-- callers cannot inject an effect or callback into the graph.
module Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compiledDesiredAbsenceProgram
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceRunId
  , compiledDesiredAbsenceRunScope
  , compiledDesiredAbsenceObservationScope
  , compiledDesiredAbsenceOperations
  , compiledDesiredAbsenceRecoveryCapabilityCatalog
  , compiledDesiredAbsenceRecoveryCapabilityCatalogDigest
  , compiledOperationForNode
  , DesiredAbsenceGraphError (..)
  , compileDesiredAbsenceGraph
  , compileDesiredAbsenceGraphForRegisteredKeys
  , cleanupSurfaceRequiresAwsScope
  )
where

import Data.Bifunctor (first)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (..))
import Prodbox.ControlPlane.CapabilityRef (mkCapabilityRef)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDependency (..)
  , CleanupGraph
  , CleanupGraphError
  , CleanupNodeId
  , CleanupRunId
  , cleanupRunIdText
  , mkCleanupGraph
  , mkCleanupNodeId
  , mkCleanupNodePlan
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, hostedZoneIdText)
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.RecoveryCapability
  ( RecoveryCapabilityCatalog
  , RecoveryCapabilitySet
  , recoveryCapabilityCatalogDigest
  )
import Prodbox.Lifecycle.Teardown.RecoveryCapability.Internal
  ( RecoveryCapabilityCatalogDraft
  , bindRecoveryCapabilitiesToOperationIdentity
  , mkRecoveryCapabilityCatalogDraft
  , sealRecoveryCapabilityCatalog
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)

data CompiledDesiredAbsenceProgram surface = CompiledDesiredAbsenceProgram
  { internalCompiledDesiredAbsenceProgram :: !(DesiredAbsenceProgram surface)
  , internalCompiledDesiredAbsenceGraph :: !CleanupGraph
  , internalCompiledDesiredAbsenceRunId :: !CleanupRunId
  , internalCompiledDesiredAbsenceRunScope :: !DurableObservationRunScope
  , internalCompiledDesiredAbsenceObservationScope :: !ObservationEvidenceScope
  , internalCompiledDesiredAbsenceOperations
      :: !(Map CleanupNodeId (TeardownOperation surface))
  , internalCompiledDesiredAbsenceRecoveryCapabilityCatalog
      :: !RecoveryCapabilityCatalog
  }

compiledDesiredAbsenceProgram
  :: CompiledDesiredAbsenceProgram surface -> DesiredAbsenceProgram surface
compiledDesiredAbsenceProgram = internalCompiledDesiredAbsenceProgram

compiledDesiredAbsenceGraph
  :: CompiledDesiredAbsenceProgram surface -> CleanupGraph
compiledDesiredAbsenceGraph = internalCompiledDesiredAbsenceGraph

compiledDesiredAbsenceRunId
  :: CompiledDesiredAbsenceProgram surface -> CleanupRunId
compiledDesiredAbsenceRunId = internalCompiledDesiredAbsenceRunId

compiledDesiredAbsenceRunScope
  :: CompiledDesiredAbsenceProgram surface -> DurableObservationRunScope
compiledDesiredAbsenceRunScope = internalCompiledDesiredAbsenceRunScope

compiledDesiredAbsenceObservationScope
  :: CompiledDesiredAbsenceProgram surface -> ObservationEvidenceScope
compiledDesiredAbsenceObservationScope =
  internalCompiledDesiredAbsenceObservationScope

compiledDesiredAbsenceOperations
  :: CompiledDesiredAbsenceProgram surface
  -> [(CleanupNodeId, TeardownOperation surface)]
compiledDesiredAbsenceOperations =
  Map.toAscList . internalCompiledDesiredAbsenceOperations

compiledOperationForNode
  :: CleanupNodeId
  -> CompiledDesiredAbsenceProgram surface
  -> Maybe (TeardownOperation surface)
compiledOperationForNode nodeId =
  Map.lookup nodeId . internalCompiledDesiredAbsenceOperations

compiledDesiredAbsenceRecoveryCapabilityCatalog
  :: CompiledDesiredAbsenceProgram surface -> RecoveryCapabilityCatalog
compiledDesiredAbsenceRecoveryCapabilityCatalog =
  internalCompiledDesiredAbsenceRecoveryCapabilityCatalog

compiledDesiredAbsenceRecoveryCapabilityCatalogDigest
  :: CompiledDesiredAbsenceProgram surface -> Text
compiledDesiredAbsenceRecoveryCapabilityCatalogDigest =
  recoveryCapabilityCatalogDigest
    . internalCompiledDesiredAbsenceRecoveryCapabilityCatalog

data DesiredAbsenceGraphError
  = DesiredAbsenceProgramInvalid !DesiredAbsenceProgramError
  | DesiredAbsenceNodeIdInvalid !Text !Text
  | DesiredAbsenceOperationIdInvalid !Text !Text
  | DesiredAbsenceCoordinateInvalid !Text
  | DesiredAbsenceAwsScopeRequired !CleanupSurface
  | DesiredAbsenceAwsScopeForbidden !CleanupSurface
  | DesiredAbsenceAwsDnsZoneForbidden !CleanupSurface
  | DesiredAbsenceDependencyUnknown !ProgramNodeName
  | DesiredAbsenceRecoveryCapabilityCatalogInvalid !Text
  | DesiredAbsenceCleanupGraphInvalid !CleanupGraphError
  deriving (Eq, Show)

compileDesiredAbsenceGraph
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> CleanupSurfaceWitness surface
  -> Either
       DesiredAbsenceGraphError
       (CompiledDesiredAbsenceProgram surface)
compileDesiredAbsenceGraph runId foundation awsScope awsDnsZone surface = do
  program <-
    first DesiredAbsenceProgramInvalid (compileDesiredAbsenceProgram surface)
  compileDesiredAbsenceGraphWithProgram
    runId
    foundation
    awsScope
    awsDnsZone
    surface
    program

compileDesiredAbsenceGraphForRegisteredKeys
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> CleanupSurfaceWitness surface
  -> [RegisteredResourceKey]
  -> Either
       DesiredAbsenceGraphError
       (CompiledDesiredAbsenceProgram surface)
compileDesiredAbsenceGraphForRegisteredKeys
  runId
  foundation
  awsScope
  awsDnsZone
  surface
  selectedKeys = do
    program <-
      first
        DesiredAbsenceProgramInvalid
        (compileDesiredAbsenceProgramForRegisteredKeys surface selectedKeys)
    compileDesiredAbsenceGraphWithProgram
      runId
      foundation
      awsScope
      awsDnsZone
      surface
      program

compileDesiredAbsenceGraphWithProgram
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> CleanupSurfaceWitness surface
  -> DesiredAbsenceProgram surface
  -> Either
       DesiredAbsenceGraphError
       (CompiledDesiredAbsenceProgram surface)
compileDesiredAbsenceGraphWithProgram
  runId
  foundation
  awsScope
  awsDnsZone
  surface
  program = do
    case (cleanupSurfaceRequiresAwsScope surface, awsScope) of
      (True, Nothing) ->
        Left
          ( DesiredAbsenceAwsScopeRequired
              (cleanupSurfaceFromWitness surface)
          )
      (False, Just _) ->
        Left
          ( DesiredAbsenceAwsScopeForbidden
              (cleanupSurfaceFromWitness surface)
          )
      _ -> Right ()
    case (awsScope, awsDnsZone) of
      (Nothing, Just _) ->
        Left
          ( DesiredAbsenceAwsDnsZoneForbidden
              (cleanupSurfaceFromWitness surface)
          )
      _ -> Right ()
    nodeIdentities <-
      mapM compileNodeIdentity (desiredAbsenceProgramNodes program)
    recoveryCapabilityCatalogDraft <-
      first
        (DesiredAbsenceRecoveryCapabilityCatalogInvalid . Text.pack . show)
        ( mkRecoveryCapabilityCatalogDraft
            [ (nodeId, programNodeRecoveryCapabilities sourceNode)
            | (sourceNode, nodeId) <- nodeIdentities
            ]
        )
    identities <-
      mapM
        (compileOperationIdentity recoveryCapabilityCatalogDraft)
        nodeIdentities
    let nodeIds =
          Map.fromList
            [ (programNodeName sourceNode, nodeId)
            | (sourceNode, nodeId, _) <- identities
            ]
    plans <- mapM (compilePlan nodeIds) identities
    graph <- first DesiredAbsenceCleanupGraphInvalid (mkCleanupGraph plans)
    recoveryCapabilityCatalog <-
      first
        (DesiredAbsenceRecoveryCapabilityCatalogInvalid . Text.pack . show)
        ( sealRecoveryCapabilityCatalog
            recoveryCapabilityCatalogDraft
            [ (nodeId, operationId)
            | (_, nodeId, operationId) <- identities
            ]
        )
    pure
      CompiledDesiredAbsenceProgram
        { internalCompiledDesiredAbsenceProgram = program
        , internalCompiledDesiredAbsenceGraph = graph
        , internalCompiledDesiredAbsenceRunId = runId
        , internalCompiledDesiredAbsenceRunScope =
            DurableObservationRunScope (cleanupRunIdText runId)
        , internalCompiledDesiredAbsenceObservationScope =
            case awsDnsZone of
              Nothing ->
                mkObservationEvidenceScope
                  (cleanupSurfaceFromWitness surface)
                  lifecycleRegistryRevision
                  (DurableObservationRunScope (cleanupRunIdText runId))
                  foundation
                  awsScope
                  ReconcileDesiredAbsent
              Just dnsZone ->
                mkObservationEvidenceScopeWithDnsZone
                  (cleanupSurfaceFromWitness surface)
                  lifecycleRegistryRevision
                  (DurableObservationRunScope (cleanupRunIdText runId))
                  foundation
                  awsScope
                  dnsZone
                  ReconcileDesiredAbsent
        , internalCompiledDesiredAbsenceOperations =
            Map.fromList
              [ (nodeId, programNodeOperation sourceNode)
              | (sourceNode, nodeId, _) <- identities
              ]
        , internalCompiledDesiredAbsenceRecoveryCapabilityCatalog =
            recoveryCapabilityCatalog
        }
   where
    compileNodeIdentity sourceNode = do
      let ProgramNodeName sourceName = programNodeName sourceNode
      nodeId <-
        first
          (DesiredAbsenceNodeIdInvalid sourceName)
          (mkCleanupNodeId ("lifecycle/" <> sourceName))
      pure (sourceNode, nodeId)

    compileOperationIdentity recoveryCapabilityCatalog (sourceNode, nodeId) = do
      let ProgramNodeName sourceName = programNodeName sourceNode
      operationId <-
        first
          (DesiredAbsenceOperationIdInvalid sourceName)
          ( mkCleanupOperationId
              ( "lifecycle-operation/"
                  <> stableOperationDigest
                    runId
                    foundation
                    awsScope
                    awsDnsZone
                    surface
                    recoveryCapabilityCatalog
                    (programNodeRecoveryCapabilities sourceNode)
                    (programNodeOperation sourceNode)
              )
          )
      pure (sourceNode, nodeId, operationId)

    compilePlan nodeIds (sourceNode, nodeId, operationId) = do
      dependencies <- mapM (compileDependency nodeIds) (programNodeDependencies sourceNode)
      coordinate <- operationCoordinate surface (programNodeOperation sourceNode)
      pure $ case programNodeOperation sourceNode of
        EstablishRecoveryPlane _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedEnsure coordinate) nodeId operationId dependencies
        ReadBackRecoveryPlane _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        ObserveRecoveryPlaneDisposition _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedObserve coordinate) nodeId operationId dependencies
        ObserveRegisteredTarget _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedObserve coordinate) nodeId operationId dependencies
        ObserveStackCheckpointPair _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedObserve coordinate) nodeId operationId dependencies
        ReconcileStackCheckpointRestore _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedEnsure coordinate) nodeId operationId dependencies
        ReadBackStackCheckpointRecovery _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        CommitAwsStackReaderBundle _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackAwsStackReaderBundle _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        CommitEksDrainIntent _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackEksDrainIntent _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        DrainEksKubernetesResources _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackEksKubernetesDrain _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        ReconcileRegisteredTargetAbsent _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackRegisteredTargetAbsent _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        RetireStackCheckpointPair _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackStackCheckpointRetirement _ ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        AuditCascadeEscapes ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedObserve coordinate) nodeId operationId dependencies
        CommitCascadePreUninstallReport ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackCascadePreUninstallReport ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        UninstallCascadeLocalFoundation ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackCascadeLocalAbsence ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        CommitCascadeCompletion ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackCascadeCompletion ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        UninstallLocalOnlyFoundation ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackLocalOnlyAbsence ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        CommitLocalOnlyCompletion ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackLocalOnlyCompletion ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        RevokeOperationalCredential _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackOperationalCredentialRevocation _ ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        CommitOrdinarySurfaceReport ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackOrdinarySurfaceReport ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        AuditTotalDecommissionEscapes ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedObserve coordinate) nodeId operationId dependencies
        ObserveExternalDecommissionReceipt ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies
        UninstallDecommissionLocalFoundation ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackDecommissionLocalAbsence ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        ApplyDecommissionLocalDataDisposition ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedDestroy coordinate) nodeId operationId dependencies
        ReadBackDecommissionLocalDataDisposition ->
          mkCleanupNodePlan (mkCapabilityRef @'ManagedReadBack coordinate) nodeId operationId dependencies
        CommitDecommissionTerminalReceipt ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleSubmit coordinate) nodeId operationId dependencies
        ReadBackDecommissionTerminalReceipt ->
          mkCleanupNodePlan (mkCapabilityRef @'LifecycleObserve coordinate) nodeId operationId dependencies

compileDependency
  :: Map ProgramNodeName CleanupNodeId
  -> ProgramDependency
  -> Either DesiredAbsenceGraphError CleanupDependency
compileDependency nodeIds dependency =
  case Map.lookup (programDependencyNode dependency) nodeIds of
    Nothing -> Left (DesiredAbsenceDependencyUnknown (programDependencyNode dependency))
    Just nodeId ->
      Right
        CleanupDependency
          { cleanupDependencyNode = nodeId
          , cleanupDependencyKind = programDependencyKind dependency
          }

operationCoordinate
  :: CleanupSurfaceWitness surface
  -> TeardownOperation surface
  -> Either DesiredAbsenceGraphError CapabilityCoordinate
operationCoordinate surface operation =
  do
    service <- coordinatePart (mkServiceIdentity "lifecycle-authority")
    authority <- coordinatePart (mkAuthorityScope ("cleanup/" <> cleanupSurfaceText surface))
    endpoint <- coordinatePart (mkCapabilityEndpoint (teardownOperationTag operation))
    logical <- coordinatePart (mkLogicalName (operationLogicalName operation))
    generation <- coordinatePart (mkCredentialGeneration 1)
    pure (mkCoordinate service authority endpoint logical generation)
 where
  coordinatePart
    :: (Show error)
    => Either error value
    -> Either DesiredAbsenceGraphError value
  coordinatePart = first (DesiredAbsenceCoordinateInvalid . Text.pack . show)

operationLogicalName :: TeardownOperation surface -> Text
operationLogicalName operation = case operationTargetBinding operation of
  Nothing -> teardownOperationTag operation
  Just target ->
    Text.intercalate
      ":"
      [ registeredResourceKeyText (registeredTargetKey target)
      , managedResourceCoordinateDigestText
          (registeredTargetCoordinateDigest target)
      ]

stableOperationDigest
  :: CleanupRunId
  -> LinuxRke2FoundationId
  -> Maybe AwsScope
  -> Maybe HostedZoneId
  -> CleanupSurfaceWitness surface
  -> RecoveryCapabilityCatalogDraft
  -> RecoveryCapabilitySet
  -> TeardownOperation surface
  -> Text
stableOperationDigest
  runId
  foundation
  awsScope
  awsDnsZone
  surface
  recoveryCapabilityCatalogDraft
  recoveryCapabilities
  operation =
    bindRecoveryCapabilitiesToOperationIdentity
      baseIdentity
      recoveryCapabilityCatalogDraft
      recoveryCapabilities
   where
    baseIdentity =
      TextEncoding.decodeUtf8
        ( hexSha256
            ( TextEncoding.encodeUtf8
                ( canonicalTuple
                    ( [ "lifecycle-cleanup-operation-base/v1"
                      , cleanupRunIdText runId
                      , registryRevisionText lifecycleRegistryRevision
                      , cleanupSurfaceText surface
                      , foundationIdText foundation
                      ]
                        ++ awsScopeFields awsScope
                        ++ awsDnsZoneFields awsDnsZone
                        ++ [ teardownOperationTag operation
                           , operationLogicalName operation
                           ]
                    )
                )
            )
        )

    -- Length framing keeps the identity injective even though the opaque scope
    -- newtypes deliberately do not constrain their Text payloads.
    canonicalTuple = Text.concat . map canonicalField
    canonicalField value =
      Text.pack (show (Text.length value)) <> ":" <> value
    foundationIdText (LinuxRke2FoundationId value) = value
    awsScopeFields scope = case scope of
      Nothing -> ["aws-scope/none", "", ""]
      Just (AwsScope (AwsAccountId accountId) (AwsRegion region)) ->
        [ "aws-scope/present"
        , accountId
        , region
        ]
    -- Preserve the pre-Sprint-7.38 graph identity exactly for a zoneless
    -- program. A present zone extends the tuple and therefore every operation
    -- and graph digest; absence appends no field at all.
    awsDnsZoneFields zone = case zone of
      Nothing -> []
      Just hostedZone ->
        [ "aws-dns-zone/present"
        , hostedZoneIdText hostedZone
        ]

operationTargetBinding
  :: TeardownOperation surface -> Maybe RegisteredTargetBinding
operationTargetBinding operation = case operation of
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

cleanupSurfaceText :: CleanupSurfaceWitness surface -> Text
cleanupSurfaceText surface = case surface of
  LocalOnlySurface -> "local-only"
  CascadeSurface -> "cascade"
  ExplicitPerRunSurface -> "explicit-per-run"
  OperationalTeardownSurface -> "operational-teardown"
  ExplicitLongLivedSurface -> "explicit-long-lived"
  TotalDecommissionSurface -> "total-decommission"

cleanupSurfaceRequiresAwsScope :: CleanupSurfaceWitness surface -> Bool
cleanupSurfaceRequiresAwsScope surface = case surface of
  LocalOnlySurface -> False
  CascadeSurface -> True
  ExplicitPerRunSurface -> True
  OperationalTeardownSurface -> True
  ExplicitLongLivedSurface -> True
  TotalDecommissionSurface -> True

registryRevisionText :: RegistryRevision -> Text
registryRevisionText (RegistryRevision revision) = revision
