{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.85: the semantic operation universe of a total decommission, and
-- the join between the two implementations that each cover part of it.
--
-- Total decommission is described in two places that have never been compared.
--
--   * @Prodbox.Lifecycle.Teardown.Program.compileDesiredAbsenceProgram
--     TotalDecommissionSurface@ emits a closed result-indexed program over the
--     __typed registry__: the registered AWS targets, the local foundation
--     uninstall and its read-back, the final escape audit, the external
--     receipt observation, the @.data@ disposition, and the terminal receipt.
--   * @Prodbox.Lifecycle.Decommission.{Manifest,Graph,NodeEffect,Runner}@ runs
--     a signed 'DecommissionNode' inventory: SES quiescence and destroy, the
--     external SMTP IAM family, per-Agent target-generation tombstones,
--     retained-home custody, the retained TLS objects and their identity, the
--     Authority backup objects and their all-prefix absence proof, and the
--     shared object bucket.
--
-- Validation item 10 of Sprint @4.85@ requires bidirectional parity across the
-- complete universe: every source operation or registered projection maps to
-- exactly one semantic tag, and every tag has a source operation, a runner
-- program, a manifest dependency relation, an interpreter, and a receipt
-- codec. Nothing measured that, and the two sides are not the same set.
--
-- This module supplies the tag layer and the measurement. Both classifiers are
-- total and their result type __is__ the tag enumeration, so the forward
-- direction is a compile error rather than a runtime finding: adding a
-- 'DecommissionNode' or a total-decommission 'TeardownOperation' cannot be done
-- without saying which semantic operation it is. What
-- 'validateDecommissionProgramTagParity' then checks is the authored coverage
-- claim against the two __measured__ images — the operations the compiler
-- actually emits and the nodes the manifest universe actually contains — so a
-- claim that a tag is implemented on both sides cannot survive one side not
-- producing it.
--
-- The measurement was the finding: the two images were __disjoint__ across all
-- twenty-one tags. Sprint @4.85@ has since closed three of them --
-- 'TotalDecommissionEscapeAuditTag', 'HomeSubstrateUninstallTag', and
-- 'LocalDataDispositionTag' are implemented on both sides, because the final
-- no-retention audit, the home-substrate uninstall, and the operator's
-- retained-local-data disposition are now the ordered terminal phase of the
-- signed receipt graph. The compiled program still names no SES, TLS,
-- Authority-backup, custody, or shared-bucket work, and the runner still names
-- no terminal receipt. Recording that as a derived value rather than as prose
-- is what makes closing each one a change the build notices.
module Prodbox.Lifecycle.Decommission.ProgramTag
  ( DecommissionProgramTag (..)
  , decommissionProgramTagText
  , decommissionNodeProgramTag
  , totalDecommissionOperationProgramTag
  , DecommissionTagImplementation (..)
  , decommissionProgramTagImplementation
  , measuredCompiledDecommissionTags
  , measuredRunnerDecommissionTags
  , decommissionRunnerInterpreterIdentity
  , decommissionRunnerInterpretsTag
  , decommissionRunnerInterpreterRegistry
  , DecommissionInterpreterIdentityError (..)
  , renderDecommissionInterpreterIdentityError
  , validateDecommissionInterpreterIdentities
  , decommissionInterpreterIdentityViolations
  , compiledDecommissionTagPrecedes
  , DecommissionTerminalPhaseOrderError (..)
  , renderDecommissionTerminalPhaseOrderError
  , validateDecommissionTerminalPhaseOrder
  , decommissionTerminalPhaseOrderViolations
  , DecommissionProgramTagParityError (..)
  , renderDecommissionProgramTagParityError
  , validateDecommissionProgramTagParity
  , decommissionProgramTagParityViolations
  )
where

import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Decommission.Graph
  ( decommissionTerminalPhaseOrder
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , decommissionChoiceFamilyRepresentative
  , mkDecommissionTargetGeneration
  , requiredSingletonDecommissionNodes
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurface (TotalDecommission)
  , CleanupSurfaceWitness (TotalDecommissionSurface)
  )
import Prodbox.Lifecycle.Teardown.Program
  ( DesiredAbsenceProgramError
  , TeardownOperation (..)
  , compileDesiredAbsenceProgram
  , desiredAbsenceProgramNodes
  , programDependencyNode
  , programNodeDependencies
  , programNodeName
  , programNodeNameText
  , programNodeOperation
  )

-- | One semantic total-decommission operation.
--
-- A tag is the unit a resumable runner program owns: the mutating effect and
-- its mandatory read-back fuse into one tag, because a lost response is
-- recovered by re-reading through the same stable operation reference rather
-- than by re-running a second graph node. Tag count is therefore deliberately
-- not lifecycle graph-node count.
--
-- Registered targets collapse across keys for the same reason: the compiled
-- program emits one node set per registered key, but the semantic operation —
-- "reconcile this registered target to absent and read it back" — is one
-- program parameterized by the registry, which is what
-- 'Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor' selects an executor
-- for.
data DecommissionProgramTag
  = -- | Observe one registered target exactly before deciding.
    RegisteredTargetObservationTag
  | -- | Observe the checkpoint pair and restore a usable primary.
    RegisteredStackCheckpointRecoveryTag
  | -- | Commit and read back the AWS stack-reader bundle.
    RegisteredStackReaderBundleTag
  | -- | Commit, read back, and perform the exact EKS Kubernetes drain.
    RegisteredEksDrainTag
  | -- | Reconcile one registered target to absent and read the absence back.
    RegisteredTargetDesiredAbsenceTag
  | -- | Retire the checkpoint pair and read the retirement back.
    RegisteredStackCheckpointRetirementTag
  | -- | The final no-retention escape audit.
    TotalDecommissionEscapeAuditTag
  | -- | Observe the external decommission receipt.
    ExternalDecommissionReceiptTag
  | -- | Uninstall the home substrate and read back its absence.
    HomeSubstrateUninstallTag
  | -- | Apply the explicit @.data@ retain/delete disposition and read it back.
    LocalDataDispositionTag
  | -- | Append the terminal receipt frame and read it back.
    TerminalReceiptTag
  | -- | Prove every SES consumer quiescent.
    SesConsumerQuiescenceTag
  | -- | Destroy and read back the SES provider stack.
    SesProviderStackTag
  | -- | Destroy and read back the external SMTP IAM family.
    SesSmtpIamTag
  | -- | Tombstone and read back one exact Target Agent generation.
    TargetGenerationTombstoneTag
  | -- | Tombstone and read back retained-home custody.
    RetainedCustodyTombstoneTag
  | -- | Delete the retained TLS objects and versions.
    TlsRetainedObjectsTag
  | -- | Delete the TLS retention identity.
    TlsRetentionIdentityTag
  | -- | Prove every registered backup prefix absent.
    BackupPrefixAbsenceProofTag
  | -- | Delete the Authority backup objects and identity.
    AuthorityBackupObjectsTag
  | -- | Delete the shared object bucket — always last.
    SharedObjectBucketTag
  | -- | Sprint 4.85: revoke the Lifecycle-provider credential and read the
    -- revocation back.  Appended, so every earlier tag keeps its index.
    OperationalCredentialRevocationTag
  deriving (Bounded, Enum, Eq, Ord, Show)

decommissionProgramTagText :: DecommissionProgramTag -> Text
decommissionProgramTagText tag = case tag of
  RegisteredTargetObservationTag -> "registered-target-observation"
  RegisteredStackCheckpointRecoveryTag -> "registered-stack-checkpoint-recovery"
  RegisteredStackReaderBundleTag -> "registered-stack-reader-bundle"
  RegisteredEksDrainTag -> "registered-eks-drain"
  RegisteredTargetDesiredAbsenceTag -> "registered-target-desired-absence"
  RegisteredStackCheckpointRetirementTag -> "registered-stack-checkpoint-retirement"
  TotalDecommissionEscapeAuditTag -> "total-decommission-escape-audit"
  ExternalDecommissionReceiptTag -> "external-decommission-receipt"
  HomeSubstrateUninstallTag -> "home-substrate-uninstall"
  LocalDataDispositionTag -> "local-data-disposition"
  TerminalReceiptTag -> "terminal-receipt"
  SesConsumerQuiescenceTag -> "ses-consumer-quiescence"
  SesProviderStackTag -> "ses-provider-stack"
  SesSmtpIamTag -> "ses-smtp-iam"
  TargetGenerationTombstoneTag -> "target-generation-tombstone"
  RetainedCustodyTombstoneTag -> "retained-custody-tombstone"
  TlsRetainedObjectsTag -> "tls-retained-objects"
  TlsRetentionIdentityTag -> "tls-retention-identity"
  AuthorityBackupObjectsTag -> "authority-backup-objects"
  BackupPrefixAbsenceProofTag -> "backup-prefix-absence-proof"
  SharedObjectBucketTag -> "shared-object-bucket"
  OperationalCredentialRevocationTag -> "operational-credential-revocation"

-- | Total over the manifest node universe.
decommissionNodeProgramTag :: DecommissionNode -> DecommissionProgramTag
decommissionNodeProgramTag node = case node of
  SesConsumerQuiescence -> SesConsumerQuiescenceTag
  SesProviderStack -> SesProviderStackTag
  SesSmtpIam -> SesSmtpIamTag
  TargetGeneration _ _ -> TargetGenerationTombstoneTag
  RetainedCustody -> RetainedCustodyTombstoneTag
  TlsRetainedObjects -> TlsRetainedObjectsTag
  TlsRetentionIdentity -> TlsRetentionIdentityTag
  BackupObjects -> AuthorityBackupObjectsTag
  BackupPrefixAbsenceProof -> BackupPrefixAbsenceProofTag
  SharedObjectBucket -> SharedObjectBucketTag
  FinalNoRetentionAudit -> TotalDecommissionEscapeAuditTag
  HomeSubstrateUninstall -> HomeSubstrateUninstallTag
  LocalDataDisposition _ -> LocalDataDispositionTag
  DecommissionTerminalReceipt -> TerminalReceiptTag

-- | Total over the operations a total-decommission program can carry.
--
-- @Nothing@ is not "unclassified". It marks the three surface-polymorphic
-- constructors that are representable at this index but that
-- 'compileDesiredAbsenceProgram' never emits here: total decommission
-- establishes no recovery plane (there is no
-- @RecoverySurfaceWitness 'TotalDecommission@) and commits no ordinary surface
-- report (it has its own terminal receipt instead). A @Nothing@ appearing in an
-- actually compiled program is therefore a parity violation rather than an
-- expected absence, and 'validateDecommissionProgramTagParity' reports it as
-- one.
totalDecommissionOperationProgramTag
  :: TeardownOperation 'TotalDecommission -> Maybe DecommissionProgramTag
totalDecommissionOperationProgramTag operation = case operation of
  ObserveRegisteredTarget {} -> Just RegisteredTargetObservationTag
  ObserveStackCheckpointPair {} -> Just RegisteredStackCheckpointRecoveryTag
  ReconcileStackCheckpointRestore {} -> Just RegisteredStackCheckpointRecoveryTag
  ReadBackStackCheckpointRecovery {} -> Just RegisteredStackCheckpointRecoveryTag
  CommitAwsStackReaderBundle {} -> Just RegisteredStackReaderBundleTag
  ReadBackAwsStackReaderBundle {} -> Just RegisteredStackReaderBundleTag
  CommitEksDrainIntent {} -> Just RegisteredEksDrainTag
  ReadBackEksDrainIntent {} -> Just RegisteredEksDrainTag
  DrainEksKubernetesResources {} -> Just RegisteredEksDrainTag
  ReadBackEksKubernetesDrain {} -> Just RegisteredEksDrainTag
  ReconcileRegisteredTargetAbsent {} -> Just RegisteredTargetDesiredAbsenceTag
  ReadBackRegisteredTargetAbsent {} -> Just RegisteredTargetDesiredAbsenceTag
  RetireStackCheckpointPair {} -> Just RegisteredStackCheckpointRetirementTag
  ReadBackStackCheckpointRetirement {} ->
    Just RegisteredStackCheckpointRetirementTag
  AuditTotalDecommissionEscapes -> Just TotalDecommissionEscapeAuditTag
  RevokeOperationalCredential _ -> Just OperationalCredentialRevocationTag
  ReadBackOperationalCredentialRevocation _ ->
    Just OperationalCredentialRevocationTag
  ObserveExternalDecommissionReceipt -> Just ExternalDecommissionReceiptTag
  UninstallDecommissionLocalFoundation -> Just HomeSubstrateUninstallTag
  ReadBackDecommissionLocalAbsence -> Just HomeSubstrateUninstallTag
  ApplyDecommissionLocalDataDisposition -> Just LocalDataDispositionTag
  ReadBackDecommissionLocalDataDisposition -> Just LocalDataDispositionTag
  CommitDecommissionTerminalReceipt -> Just TerminalReceiptTag
  ReadBackDecommissionTerminalReceipt -> Just TerminalReceiptTag
  EstablishRecoveryPlane _ -> Nothing
  ReadBackRecoveryPlane _ -> Nothing
  ObserveRecoveryPlaneDisposition _ -> Nothing
  CommitOrdinarySurfaceReport -> Nothing
  ReadBackOrdinarySurfaceReport -> Nothing

-- | Which side of the total-decommission universe implements a tag.
--
-- This is the authored claim. It is checked against the two measured images
-- rather than trusted, which is the whole point: the previous state of this
-- parity was a prose sentence in a plan document, and a prose sentence cannot
-- notice a node being added.
data DecommissionTagImplementation
  = -- | The compiled desired-absence program emits it; the signed manifest and
    -- its runner have no node for it.
    CompiledProgramOnly
  | -- | The signed manifest and its runner own it; the compiled
    -- desired-absence program emits no operation for it.
    DecommissionRunnerOnly
  | -- | Both sides implement it, so one semantic operation has one resumable
    -- runner program with a source operation behind it.
    CompiledProgramAndRunner
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The current claim, tag by tag.
--
-- Three tags are two-sided: the final no-retention audit, the home-substrate
-- uninstall, and the retained-local-data disposition are each both a compiled
-- operation and a signed manifest node. Every other tag remains one-sided, and
-- that is the measured state of validation item 10 rather than an accepted
-- design -- the compiled program would destroy the registered AWS targets
-- while never touching SES, the retained TLS material, the Authority backup,
-- or the shared object bucket, and the runner would do the converse while
-- never appending a terminal receipt.
decommissionProgramTagImplementation
  :: DecommissionProgramTag -> DecommissionTagImplementation
decommissionProgramTagImplementation tag = case tag of
  RegisteredTargetObservationTag -> CompiledProgramOnly
  RegisteredStackCheckpointRecoveryTag -> CompiledProgramOnly
  RegisteredStackReaderBundleTag -> CompiledProgramOnly
  RegisteredEksDrainTag -> CompiledProgramOnly
  RegisteredTargetDesiredAbsenceTag -> CompiledProgramOnly
  RegisteredStackCheckpointRetirementTag -> CompiledProgramOnly
  TotalDecommissionEscapeAuditTag -> CompiledProgramAndRunner
  ExternalDecommissionReceiptTag -> CompiledProgramOnly
  HomeSubstrateUninstallTag -> CompiledProgramAndRunner
  LocalDataDispositionTag -> CompiledProgramAndRunner
  TerminalReceiptTag -> CompiledProgramAndRunner
  SesConsumerQuiescenceTag -> DecommissionRunnerOnly
  SesProviderStackTag -> DecommissionRunnerOnly
  SesSmtpIamTag -> DecommissionRunnerOnly
  TargetGenerationTombstoneTag -> DecommissionRunnerOnly
  RetainedCustodyTombstoneTag -> DecommissionRunnerOnly
  TlsRetainedObjectsTag -> DecommissionRunnerOnly
  TlsRetentionIdentityTag -> DecommissionRunnerOnly
  AuthorityBackupObjectsTag -> DecommissionRunnerOnly
  BackupPrefixAbsenceProofTag -> DecommissionRunnerOnly
  SharedObjectBucketTag -> DecommissionRunnerOnly
  -- The compiled program orders it strictly between the terminal audit and the
  -- home uninstall. The signed manifest has no node for it: revoking the
  -- Lifecycle-provider credential is not one of the resource families the
  -- external receipt graph names, and giving it one is part of the convergence
  -- Sprint 6.5 owns.
  OperationalCredentialRevocationTag -> CompiledProgramOnly

-- | The tags the compiled total-decommission program actually emits, measured
-- by compiling it.
measuredCompiledDecommissionTags
  :: Either DesiredAbsenceProgramError [DecommissionProgramTag]
measuredCompiledDecommissionTags =
  fmap
    ( sort
        . nub
        . concatMap
          ( maybe [] pure
              . totalDecommissionOperationProgramTag
              . programNodeOperation
          )
        . desiredAbsenceProgramNodes
    )
    (compileDesiredAbsenceProgram TotalDecommissionSurface)

-- | The tags the manifest node universe actually contains.
--
-- The singleton half comes from 'requiredSingletonDecommissionNodes', which is
-- itself derived from the closed 'DecommissionSingletonNode' enumeration, so a
-- newly added singleton reaches this measurement without anyone editing it. The
-- parameterized half contributes one representative 'TargetGeneration': a run
-- names as many as it has Agents, and they are all one semantic program.
measuredRunnerDecommissionTags :: [DecommissionProgramTag]
measuredRunnerDecommissionTags =
  sort
    ( nub
        ( map
            decommissionNodeProgramTag
            ( requiredSingletonDecommissionNodes
                ++ representativeChoiceNodes
                ++ representativeTargetGeneration
            )
        )
    )
 where
  representativeChoiceNodes =
    map decommissionChoiceFamilyRepresentative [minBound .. maxBound]
  representativeTargetGeneration =
    [ TargetGeneration "target/parity-representative" generation
    | Right generation <- [mkDecommissionTargetGeneration 1]
    ]

-- | The compiled interpreter identity the signed decommission runner holds for
-- a tag, if it holds one.
--
-- These exact strings are digested into 'VerifierMetadata' as the interpreter
-- registry identity and signed into the manifest, so the operator's signature
-- covers /which interpreters the runner was built with/. They were previously
-- authored twice in @Prodbox.CLI.Nuke@ — once as a @case@ over
-- 'DecommissionNode' and once again as a flat list whose digest is the signed
-- one — with nothing joining either to the node universe. A node added with a
-- tag would therefore have been absent from the signed registry while the
-- manifest that named it still verified, and the only check standing between
-- the two was that the @case@ arm returned a non-empty literal, which no arm
-- could fail.
--
-- 'Nothing' is not "unclassified": it marks a tag this runner deliberately does
-- not interpret, which today is exactly the compiled-program-only half of the
-- universe. 'validateDecommissionInterpreterIdentities' checks that against the
-- implementation claim, so a tag cannot be runner-implemented and identity-less
-- (a signed registry that omits a node the manifest may name) or identity-bearing
-- and runner-less (a signed registry naming an interpreter no node reaches).
decommissionRunnerInterpreterIdentity :: DecommissionProgramTag -> Maybe Text
decommissionRunnerInterpreterIdentity tag = case tag of
  RegisteredTargetObservationTag -> Nothing
  RegisteredStackCheckpointRecoveryTag -> Nothing
  RegisteredStackReaderBundleTag -> Nothing
  RegisteredEksDrainTag -> Nothing
  RegisteredTargetDesiredAbsenceTag -> Nothing
  RegisteredStackCheckpointRetirementTag -> Nothing
  TotalDecommissionEscapeAuditTag -> Just "total-decommission-escape-audit-v1"
  ExternalDecommissionReceiptTag -> Nothing
  HomeSubstrateUninstallTag -> Just "home-substrate-uninstall-v1"
  LocalDataDispositionTag -> Just "local-data-disposition-v1"
  TerminalReceiptTag -> Just "terminal-receipt-v1"
  SesConsumerQuiescenceTag -> Just "ses-consumer-quiescence-v1"
  SesProviderStackTag -> Just "ses-provider-stack-v1"
  SesSmtpIamTag -> Just "ses-smtp-iam-v1"
  TargetGenerationTombstoneTag -> Just "target-generation-v1"
  RetainedCustodyTombstoneTag -> Just "retained-custody-v1"
  TlsRetainedObjectsTag -> Just "tls-retained-objects-v1"
  TlsRetentionIdentityTag -> Just "tls-retention-identity-v1"
  BackupPrefixAbsenceProofTag -> Just "backup-prefix-absence-proof-v1"
  AuthorityBackupObjectsTag -> Just "backup-objects-identity-v1"
  OperationalCredentialRevocationTag -> Nothing
  SharedObjectBucketTag -> Just "shared-object-bucket-v1"

-- | Whether the signed decommission runner is claimed to implement a tag.
--
-- Derived from 'decommissionProgramTagImplementation' rather than authored, so
-- it inherits that claim's measurement: 'validateDecommissionProgramTagParity'
-- already refuses a claim the compiled program and the manifest node universe
-- do not produce.
decommissionRunnerInterpretsTag :: DecommissionProgramTag -> Bool
decommissionRunnerInterpretsTag tag =
  case decommissionProgramTagImplementation tag of
    CompiledProgramOnly -> False
    DecommissionRunnerOnly -> True
    CompiledProgramAndRunner -> True

-- | The signed interpreter registry, in tag order.
--
-- This is the value whose digest the Authority signs. Deriving it from the
-- closed tag enumeration is what makes a newly implemented node reach the
-- signed registry by construction instead of by someone remembering to add a
-- line beside it.
decommissionRunnerInterpreterRegistry :: [Text]
decommissionRunnerInterpreterRegistry =
  [ identity
  | tag <- [minBound .. maxBound]
  , Just identity <- [decommissionRunnerInterpreterIdentity tag]
  ]

data DecommissionInterpreterIdentityError
  = -- | The runner implements this tag but the signed registry names no
    -- interpreter for it.
    DecommissionInterpreterIdentityMissing !DecommissionProgramTag
  | -- | The signed registry names an interpreter for a tag the runner does not
    -- implement.
    DecommissionInterpreterIdentityUnreachable !DecommissionProgramTag !Text
  | -- | Two tags share one interpreter identity, so the signed registry cannot
    -- distinguish them.
    DecommissionInterpreterIdentityDuplicated !Text
  deriving (Eq, Show)

renderDecommissionInterpreterIdentityError
  :: DecommissionInterpreterIdentityError -> String
renderDecommissionInterpreterIdentityError err = case err of
  DecommissionInterpreterIdentityMissing tag ->
    "decommission program tag `"
      ++ Text.unpack (decommissionProgramTagText tag)
      ++ "` is implemented by the signed decommission runner but names no \
         \interpreter identity, so the registry digest the Authority signs \
         \would omit it while a manifest naming that node still verified \
         \(Sprint 4.85 validation item 10)."
  DecommissionInterpreterIdentityUnreachable tag identity ->
    "decommission program tag `"
      ++ Text.unpack (decommissionProgramTagText tag)
      ++ "` names interpreter identity `"
      ++ Text.unpack identity
      ++ "` but the signed decommission runner does not implement it, so the \
         \signed registry advertises an interpreter no manifest node can reach."
  DecommissionInterpreterIdentityDuplicated identity ->
    "interpreter identity `"
      ++ Text.unpack identity
      ++ "` is claimed by more than one decommission program tag; the signed \
         \registry could not distinguish which interpreter a node was verified \
         \against."

-- | Join the interpreter registry to the tag universe in both directions.
validateDecommissionInterpreterIdentities
  :: Either [DecommissionInterpreterIdentityError] ()
validateDecommissionInterpreterIdentities =
  case missing ++ unreachable ++ duplicated of
    [] -> Right ()
    errors -> Left errors
 where
  tags = [minBound .. maxBound] :: [DecommissionProgramTag]
  missing =
    [ DecommissionInterpreterIdentityMissing tag
    | tag <- tags
    , decommissionRunnerInterpretsTag tag
    , Nothing <- [decommissionRunnerInterpreterIdentity tag]
    ]
  unreachable =
    [ DecommissionInterpreterIdentityUnreachable tag identity
    | tag <- tags
    , not (decommissionRunnerInterpretsTag tag)
    , Just identity <- [decommissionRunnerInterpreterIdentity tag]
    ]
  duplicated =
    [ DecommissionInterpreterIdentityDuplicated identity
    | identity <- nub decommissionRunnerInterpreterRegistry
    , length (filter (== identity) decommissionRunnerInterpreterRegistry) > 1
    ]

decommissionInterpreterIdentityViolations :: [String]
decommissionInterpreterIdentityViolations =
  either
    (map renderDecommissionInterpreterIdentityError)
    (const [])
    validateDecommissionInterpreterIdentities

-- | Whether the compiled total-decommission program orders every node of one
-- tag before every node of another.
--
-- Sprint 4.85: the runner graph's terminal phase and the compiled program both
-- state an order over the same semantic operations, and until now each simply
-- asserted one. This is the measurement that joins them. It is deliberately
-- two-sided — every node of the later tag must transitively depend on some node
-- of the earlier tag, __and__ no node of the earlier tag may transitively
-- depend on the later — so an unordered pair does not read as ordered.
compiledDecommissionTagPrecedes
  :: DecommissionProgramTag -> DecommissionProgramTag -> Bool
compiledDecommissionTagPrecedes earlier later =
  case compileDesiredAbsenceProgram TotalDecommissionSurface of
    Left _ -> False
    Right program ->
      let nodes = desiredAbsenceProgramNodes program
          named tag =
            [ programNodeNameText (programNodeName node)
            | node <- nodes
            , totalDecommissionOperationProgramTag (programNodeOperation node) == Just tag
            ]
          dependenciesOf name =
            concat
              [ map (programNodeNameText . programDependencyNode) (programNodeDependencies node)
              | node <- nodes
              , programNodeNameText (programNodeName node) == name
              ]
          reaches seen name
            | name `elem` seen = seen
            | otherwise = foldl reaches (name : seen) (dependenciesOf name)
          reachable name = reaches [] name
          earlierNames = named earlier
          laterNames = named later
       in not (null earlierNames)
            && not (null laterNames)
            && all (\name -> any (`elem` reachable name) earlierNames) laterNames
            && not (any (\name -> any (`elem` reachable name) laterNames) earlierNames)

newtype DecommissionTerminalPhaseOrderError
  = -- | The runner graph runs the first tag before the second, and the compiled
    -- program does not order them that way.
    DecommissionTerminalPhaseOrderUnsupported
      (DecommissionProgramTag, DecommissionProgramTag)
  deriving (Eq, Show)

renderDecommissionTerminalPhaseOrderError
  :: DecommissionTerminalPhaseOrderError -> String
renderDecommissionTerminalPhaseOrderError err = case err of
  DecommissionTerminalPhaseOrderUnsupported (earlier, later) ->
    "the signed decommission graph runs `"
      ++ Text.unpack (decommissionProgramTagText earlier)
      ++ "` before `"
      ++ Text.unpack (decommissionProgramTagText later)
      ++ "`, but the compiled TotalDecommission program does not order them that \
         \way. One semantic operation must have one order, not one per \
         \implementation (Sprint 4.85 validation item 10)."

-- | The runner's terminal-phase order must be the compiled program's order.
--
-- Only consecutive pairs are checked, because the enumeration is a total order
-- and precedence is transitive in the compiled dependency graph.
validateDecommissionTerminalPhaseOrder
  :: Either [DecommissionTerminalPhaseOrderError] ()
validateDecommissionTerminalPhaseOrder =
  case unsupported of
    [] -> Right ()
    errors -> Left errors
 where
  terminalTags = map decommissionNodeProgramTag decommissionTerminalPhaseOrder
  consecutive = zip terminalTags (drop 1 terminalTags)
  unsupported =
    [ DecommissionTerminalPhaseOrderUnsupported pair
    | pair@(earlier, later) <- consecutive
    , not (compiledDecommissionTagPrecedes earlier later)
    ]

decommissionTerminalPhaseOrderViolations :: [String]
decommissionTerminalPhaseOrderViolations =
  either
    (map renderDecommissionTerminalPhaseOrderError)
    (const [])
    validateDecommissionTerminalPhaseOrder

data DecommissionProgramTagParityError
  = -- | The total-decommission program did not compile, so the compiled half
    -- of the parity cannot be measured at all.
    DecommissionParityProgramUncompilable !DesiredAbsenceProgramError
  | -- | A compiled node whose operation this tag layer maps to no tag. The
    -- three unmapped constructors are the ones the compiler never emits here,
    -- so one appearing means the program grew a shape the semantic universe
    -- does not name.
    DecommissionParityCompiledOperationUntagged !Text
  | -- | The claim and the measurement disagree for one tag.
    DecommissionParityImplementationMismatch
      !DecommissionProgramTag
      !DecommissionTagImplementation
      -- ^ claimed
      !(Maybe DecommissionTagImplementation)
      -- ^ measured; @Nothing@ when neither side produces the tag at all
  deriving (Eq, Show)

renderDecommissionProgramTagParityError
  :: DecommissionProgramTagParityError -> String
renderDecommissionProgramTagParityError err = case err of
  DecommissionParityProgramUncompilable detail ->
    "the total-decommission desired-absence program did not compile, so \
    \decommission program-tag parity cannot be measured: "
      ++ show detail
  DecommissionParityCompiledOperationUntagged nodeName ->
    "compiled total-decommission node `"
      ++ Text.unpack nodeName
      ++ "` carries an operation that Prodbox.Lifecycle.Decommission.ProgramTag \
         \maps to no semantic tag; every source operation must have exactly one \
         \(Sprint 4.85 validation item 10)."
  DecommissionParityImplementationMismatch tag claimed measured ->
    "decommission program tag `"
      ++ Text.unpack (decommissionProgramTagText tag)
      ++ "` is declared "
      ++ show claimed
      ++ " but measures "
      ++ maybe "implemented by neither side" show measured
      ++ "; update decommissionProgramTagImplementation in the same change that \
         \adds or removes the implementation."

-- | Measure both images and check the authored claim against them.
validateDecommissionProgramTagParity
  :: Either [DecommissionProgramTagParityError] ()
validateDecommissionProgramTagParity =
  case compileDesiredAbsenceProgram TotalDecommissionSurface of
    Left err -> Left [DecommissionParityProgramUncompilable err]
    Right program ->
      let untagged =
            [ DecommissionParityCompiledOperationUntagged
                (programNodeNameText (programNodeName node))
            | node <- desiredAbsenceProgramNodes program
            , Nothing <-
                [totalDecommissionOperationProgramTag (programNodeOperation node)]
            ]
          compiled = either (const []) id measuredCompiledDecommissionTags
          runner = measuredRunnerDecommissionTags
          mismatches =
            [ DecommissionParityImplementationMismatch
                tag
                (decommissionProgramTagImplementation tag)
                measured
            | tag <- [minBound .. maxBound]
            , let inCompiled = tag `elem` compiled
                  inRunner = tag `elem` runner
                  measured = measuredImplementation inCompiled inRunner
            , measured /= Just (decommissionProgramTagImplementation tag)
            ]
       in case untagged ++ mismatches of
            [] -> Right ()
            errors -> Left errors
 where
  measuredImplementation inCompiled inRunner = case (inCompiled, inRunner) of
    (True, True) -> Just CompiledProgramAndRunner
    (True, False) -> Just CompiledProgramOnly
    (False, True) -> Just DecommissionRunnerOnly
    (False, False) -> Nothing

decommissionProgramTagParityViolations :: [String]
decommissionProgramTagParityViolations =
  either
    (map renderDecommissionProgramTagParityError)
    (const [])
    validateDecommissionProgramTagParity
