{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production-independent oracle for the frozen @CREATE-INTERRUPTED-2026-09-08@
-- counterexample.  Like its teardown sibling this module has no lifecycle-runtime
-- imports: committed repository artifacts and typed qualification fakes are its
-- only inputs.
--
-- __What the counterexample names.__  On 2026-09-08 a registered-stack create
-- committed its lifecycle generation one second before the provider capability
-- ran, and the transport deadline then cancelled the reply.  The generation made
-- the /cycle/ addressable, which is what it is for; but a generation names a
-- cycle and not resources, so the VPC, the roles, the policy and the cluster the
-- next four seconds created were named by nothing.  A later cascade could see
-- that a create had happened and could not say what it made.
--
-- __What the oracle decides.__  For each implementation and each point at which
-- the run can stop, it answers one question: /does a durable record name the
-- coordinates this run may by then have created?/  The answer is a total
-- function of which lane steps had completed, which is why the superseded
-- implementation cannot be made to pass by choosing a kinder interruption and
-- the replacement cannot be made to fail by choosing a crueller one.
--
-- The distinction Standard P requires falls straight out of the two transition
-- lists: the superseded lane has no step that writes coordinates, so every
-- interruption at or after its effect answers 'OrphanUnnameable'; the
-- replacement lane commits and independently reads back a write-ahead ownership
-- manifest before its effect, so every interruption from that commit onward
-- answers 'CoordinatesNamed'.
module Prodbox.Test.Qualification.CreateInterruptedCounterexample
  ( -- * Identity and scope
    CreateFixtureId
  , createFixtureIdText
  , CreateEvidenceScope (..)
  , CreateImplementation (..)
  , createImplementationText

    -- * What the create said it would make
  , DeclaredCoordinate (..)
  , ObservedIdentity (..)
  , ProviderTagRow (..)

    -- * The lane, and where it can stop
  , CreateTransition (..)
  , createTransitionText
  , InterruptionKind (..)
  , interruptionKindText
  , InterruptionSide (..)
  , interruptionSideText
  , ExternalStateCase (..)
  , externalStateCaseText
  , SuccessorDisposition (..)
  , successorDispositionText

    -- * The matrices
  , InterruptionRow (..)
  , ExternalStateRow (..)
  , implementationTransitions
  , reachableExternalStateCases
  , successorDispositionFor
  , externalStateDispositionFor
  , canonicalInterruptionMatrix
  , canonicalExternalStateMatrix

    -- * The frozen fixture
  , CreateArtifactDigest
  , createArtifactDigestText
  , FrozenCreateCounterexample
  , frozenCreateFixtureId
  , frozenCreateEvidenceScope
  , frozenCreateDeclaredCoordinates
  , frozenCreateObservedIdentities
  , frozenCreateProviderTags
  , frozenCreateInterruptionMatrix
  , frozenCreateExternalStateMatrix
  , frozenCreateCausalProfile
  , frozenCreateProductionProfile
  , frozenCreateArtifactDigest
  , canonicalCreateFixtureId
  , canonicalCreateEvidenceScope

    -- * Loading
  , CreateArtifactKind (..)
  , CreateCounterexampleError (..)
  , CreateTraceFixture (..)
  , createTraceFixturePath
  , createDispositionsFixturePath
  , createCausalProfileFixturePath
  , createProductionProfileFixturePath
  , loadCreateCounterexampleFixture
  , loadCreateCounterexample
  , parseCreateCounterexampleArtifacts

    -- * The oracle
  , CreateOracleOutcome (..)
  , CreateOracleResult (..)
  , runCreateInterruptedOracle
  )
where

import Control.Exception (IOException, SomeException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List (group, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall qualified
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.Test.Qualification.CounterexampleProfile
  ( CounterexampleResourceProfile (..)
  , ProfileBackgroundLoad (..)
  , ProfileEnvelope (..)
  , ProfileEnvelopeMapping (..)
  , counterexampleArtifactDigestText
  , topologyNormalizedBudgetHolds
  )
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import Text.Read (readMaybe)

newtype CreateFixtureId = CreateFixtureId Text
  deriving stock (Eq, Ord, Show)

createFixtureIdText :: CreateFixtureId -> Text
createFixtureIdText (CreateFixtureId value) = value

-- | The scope one interrupted create ran under.  The run scope and the
-- submission key are both here because both are stamped provider-side by Sprint
-- @7.41@: they are the two values a cascade can read off a surviving resource.
data CreateEvidenceScope = CreateEvidenceScope
  { createScopeRun :: !Text
  , createScopeSubmission :: !Text
  , createScopeRegistryRevision :: !Text
  , createScopeSurface :: !Text
  , createScopeOperation :: !Text
  , createScopeFoundation :: !Text
  , createScopeAwsAccount :: !Text
  , createScopeAwsRegion :: !Text
  , createScopeStack :: !Text
  }
  deriving stock (Eq, Ord, Show)

data CreateImplementation
  = SupersededCreate
  | ReplacementCreate
  deriving stock (Bounded, Enum, Eq, Ord, Show)

createImplementationText :: CreateImplementation -> Text
createImplementationText implementation = case implementation of
  SupersededCreate -> "superseded"
  ReplacementCreate -> "replacement"

-- | One coordinate the create declared it was about to make.  The digest stands
-- for the provider type and logical name the write-ahead entry is keyed on.
data DeclaredCoordinate = DeclaredCoordinate
  { declaredCoordinateName :: !Text
  , declaredCoordinateType :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | An identity the provider reported having made, in the form the completion
-- append records it.
data ObservedIdentity = ObservedIdentity
  { observedIdentityCoordinate :: !Text
  , observedIdentityValue :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | A provider-held tag.  This is the only marker in the fixture that survives
-- the host process, which is what makes it worth freezing separately from the
-- durable records.
data ProviderTagRow = ProviderTagRow
  { providerTagKey :: !Text
  , providerTagValue :: !Text
  }
  deriving stock (Eq, Ord, Show)

-- | The steps of the registered-stack create lane, in execution order.
--
-- The superseded lane has a strict subset of them, which is the entire finding:
-- it has no step between the generation commit and the effect.
data CreateTransition
  = MintRunMarker
  | AdmitCreate
  | CommitGeneration
  | CommitWriteAheadManifest
  | ReadBackWriteAheadManifest
  | ExecuteAdmittedCreate
  | AppendObservedIdentities
  deriving stock (Bounded, Enum, Eq, Ord, Show)

createTransitionText :: CreateTransition -> Text
createTransitionText transition = case transition of
  MintRunMarker -> "mint-run-marker"
  AdmitCreate -> "admit-create"
  CommitGeneration -> "commit-generation"
  CommitWriteAheadManifest -> "commit-write-ahead-manifest"
  ReadBackWriteAheadManifest -> "read-back-write-ahead-manifest"
  ExecuteAdmittedCreate -> "execute-admitted-create"
  AppendObservedIdentities -> "append-observed-identities"

data InterruptionKind
  = CtrlC
  | SigKill
  | ClientDisconnect
  | OwnerLeaseExpiry
  | Restart
  deriving stock (Bounded, Enum, Eq, Ord, Show)

interruptionKindText :: InterruptionKind -> Text
interruptionKindText kind = case kind of
  CtrlC -> "ctrl-c"
  SigKill -> "sigkill"
  ClientDisconnect -> "client-disconnect"
  OwnerLeaseExpiry -> "owner-lease-expiry"
  Restart -> "restart"

data InterruptionSide
  = BeforeTransition
  | AfterTransition
  deriving stock (Bounded, Enum, Eq, Ord, Show)

interruptionSideText :: InterruptionSide -> Text
interruptionSideText side = case side of
  BeforeTransition -> "before"
  AfterTransition -> "after"

-- | The ways the world outside this process can fail a create.
--
-- Each one is an answer that was never received, which is exactly the class the
-- durable records exist for: the host cannot tell a request that was refused
-- from one that was served and whose reply was lost.
data ExternalStateCase
  = AuthorityUnreachable
  | AdmissionReplyLost
  | GenerationCommitReplyLost
  | ManifestCommitReplyLost
  | ManifestReadBackAbsent
  | ProviderDispatchReplyLost
  | ProviderAnsweredFailure
  | CompletionAppendReplyLost
  deriving stock (Bounded, Enum, Eq, Ord, Show)

externalStateCaseText :: ExternalStateCase -> Text
externalStateCaseText externalCase = case externalCase of
  AuthorityUnreachable -> "authority-unreachable"
  AdmissionReplyLost -> "admission-reply-lost"
  GenerationCommitReplyLost -> "generation-commit-reply-lost"
  ManifestCommitReplyLost -> "manifest-commit-reply-lost"
  ManifestReadBackAbsent -> "manifest-read-back-absent"
  ProviderDispatchReplyLost -> "provider-dispatch-reply-lost"
  ProviderAnsweredFailure -> "provider-answered-failure"
  CompletionAppendReplyLost -> "completion-append-reply-lost"

-- | What a successor run can say about the resources this run may have made.
data SuccessorDisposition
  = -- | Nothing durable and nothing created.  A successor owes nothing.
    NothingCreated
  | -- | A generation names the cycle, and no record names a resource.  A
    -- successor knows a create happened and cannot say what it made.
    CycleAddressableOnly
  | -- | A durable record names every coordinate the create declared, so a
    -- successor can destroy exactly them.
    CoordinatesNamed
  | -- | The effect may have run and nothing names its resources.  This is the
    -- counterexample.
    OrphanUnnameable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

successorDispositionText :: SuccessorDisposition -> Text
successorDispositionText disposition = case disposition of
  NothingCreated -> "nothing-created"
  CycleAddressableOnly -> "cycle-addressable-only"
  CoordinatesNamed -> "coordinates-named"
  OrphanUnnameable -> "orphan-unnameable"

data InterruptionRow = InterruptionRow
  { interruptionRowImplementation :: !CreateImplementation
  , interruptionRowKind :: !InterruptionKind
  , interruptionRowSide :: !InterruptionSide
  , interruptionRowTransition :: !CreateTransition
  , interruptionRowDisposition :: !SuccessorDisposition
  }
  deriving stock (Eq, Ord, Show)

data ExternalStateRow = ExternalStateRow
  { externalStateRowImplementation :: !CreateImplementation
  , externalStateRowCase :: !ExternalStateCase
  , externalStateRowDisposition :: !SuccessorDisposition
  }
  deriving stock (Eq, Ord, Show)

-- | The lane each implementation actually runs.
--
-- The superseded list is not an abbreviation of the replacement list for the
-- fixture's convenience: it is the lane as it stood on 2026-09-08, which minted
-- its run scope after admission and had nothing at all between the generation
-- commit and the dispatch.
implementationTransitions :: CreateImplementation -> [CreateTransition]
implementationTransitions implementation = case implementation of
  SupersededCreate ->
    [ AdmitCreate
    , CommitGeneration
    , ExecuteAdmittedCreate
    ]
  ReplacementCreate ->
    [ MintRunMarker
    , AdmitCreate
    , CommitGeneration
    , CommitWriteAheadManifest
    , ReadBackWriteAheadManifest
    , ExecuteAdmittedCreate
    , AppendObservedIdentities
    ]

-- | The disposition, derived from what had completed.
--
-- The order of the guards is the claim: a record that names coordinates
-- outranks one that names only a cycle, and an effect that may have run with no
-- naming record is the worst answer there is.
dispositionForCompleted :: [CreateTransition] -> Bool -> SuccessorDisposition
dispositionForCompleted completed effectMayHaveRun
  | CommitWriteAheadManifest `elem` completed = CoordinatesNamed
  | effectMayHaveRun || ExecuteAdmittedCreate `elem` completed = OrphanUnnameable
  | CommitGeneration `elem` completed = CycleAddressableOnly
  | otherwise = NothingCreated

-- | Everything strictly before the named step, plus the step itself when the
-- interruption lands after it.
completedAt
  :: CreateImplementation -> CreateTransition -> InterruptionSide -> [CreateTransition]
completedAt implementation transition side =
  takeWhile (/= transition) lane ++ case side of
    BeforeTransition -> []
    AfterTransition -> [transition]
 where
  lane = implementationTransitions implementation

successorDispositionFor
  :: CreateImplementation -> CreateTransition -> InterruptionSide -> SuccessorDisposition
successorDispositionFor implementation transition side =
  dispositionForCompleted (completedAt implementation transition side) False

-- | The step an external case needs in the lane before it can happen at all.
--
-- A superseded lane that never commits a manifest cannot lose the reply to one,
-- and a matrix that carried a disposition for it would be describing a lane
-- nobody ran.
externalStateRequiredStep :: ExternalStateCase -> Maybe CreateTransition
externalStateRequiredStep externalCase = case externalCase of
  AuthorityUnreachable -> Nothing
  AdmissionReplyLost -> Just AdmitCreate
  GenerationCommitReplyLost -> Just CommitGeneration
  ManifestCommitReplyLost -> Just CommitWriteAheadManifest
  ManifestReadBackAbsent -> Just ReadBackWriteAheadManifest
  ProviderDispatchReplyLost -> Just ExecuteAdmittedCreate
  ProviderAnsweredFailure -> Just ExecuteAdmittedCreate
  CompletionAppendReplyLost -> Just AppendObservedIdentities

reachableExternalStateCases :: CreateImplementation -> [ExternalStateCase]
reachableExternalStateCases implementation =
  [ externalCase
  | externalCase <- [minBound .. maxBound]
  , case externalStateRequiredStep externalCase of
      Nothing -> True
      Just step -> step `elem` implementationTransitions implementation
  ]

externalStateDispositionFor
  :: CreateImplementation -> ExternalStateCase -> SuccessorDisposition
externalStateDispositionFor implementation externalCase =
  dispositionForCompleted completed effectMayHaveRun
 where
  lane = implementationTransitions implementation
  -- A lost reply means the request may have been served, so the step that lost
  -- it counts as completed.  `manifest-read-back-absent` is the exception and
  -- the reason the read-back is a separate call: the commit answered, the
  -- read-back found nothing, and the honest reading of that is that nothing is
  -- named.
  completed = case externalCase of
    AuthorityUnreachable -> []
    ManifestReadBackAbsent -> takeWhile (/= CommitWriteAheadManifest) lane
    _ -> case externalStateRequiredStep externalCase of
      Nothing -> []
      Just step -> takeWhile (/= step) lane ++ [step]
  effectMayHaveRun = case externalCase of
    ProviderDispatchReplyLost -> True
    ProviderAnsweredFailure -> True
    CompletionAppendReplyLost -> True
    _ -> False

-- | The complete matrix, in the canonical order the committed file carries.
canonicalInterruptionMatrix :: [InterruptionRow]
canonicalInterruptionMatrix =
  [ InterruptionRow
      { interruptionRowImplementation = implementation
      , interruptionRowKind = kind
      , interruptionRowSide = side
      , interruptionRowTransition = transition
      , interruptionRowDisposition = successorDispositionFor implementation transition side
      }
  | implementation <- [minBound .. maxBound]
  , transition <- implementationTransitions implementation
  , kind <- [minBound .. maxBound]
  , side <- [minBound .. maxBound]
  ]

canonicalExternalStateMatrix :: [ExternalStateRow]
canonicalExternalStateMatrix =
  [ ExternalStateRow
      { externalStateRowImplementation = implementation
      , externalStateRowCase = externalCase
      , externalStateRowDisposition = externalStateDispositionFor implementation externalCase
      }
  | implementation <- [minBound .. maxBound]
  , externalCase <- reachableExternalStateCases implementation
  ]

newtype CreateArtifactDigest = CreateArtifactDigest Text
  deriving stock (Eq, Ord, Show)

createArtifactDigestText :: CreateArtifactDigest -> Text
createArtifactDigestText (CreateArtifactDigest value) = value

data FrozenCreateCounterexample = FrozenCreateCounterexample
  { internalCreateFixtureId :: !CreateFixtureId
  , internalCreateEvidenceScope :: !CreateEvidenceScope
  , internalCreateDeclaredCoordinates :: ![DeclaredCoordinate]
  , internalCreateObservedIdentities :: ![ObservedIdentity]
  , internalCreateProviderTags :: ![ProviderTagRow]
  , internalCreateInterruptionMatrix :: ![InterruptionRow]
  , internalCreateExternalStateMatrix :: ![ExternalStateRow]
  , internalCreateCausalProfile :: !CounterexampleResourceProfile
  , internalCreateProductionProfile :: !CounterexampleResourceProfile
  , internalCreateArtifactDigest :: !CreateArtifactDigest
  }
  deriving stock (Eq, Show)

frozenCreateFixtureId :: FrozenCreateCounterexample -> CreateFixtureId
frozenCreateFixtureId = internalCreateFixtureId

frozenCreateEvidenceScope :: FrozenCreateCounterexample -> CreateEvidenceScope
frozenCreateEvidenceScope = internalCreateEvidenceScope

frozenCreateDeclaredCoordinates :: FrozenCreateCounterexample -> [DeclaredCoordinate]
frozenCreateDeclaredCoordinates = internalCreateDeclaredCoordinates

frozenCreateObservedIdentities :: FrozenCreateCounterexample -> [ObservedIdentity]
frozenCreateObservedIdentities = internalCreateObservedIdentities

frozenCreateProviderTags :: FrozenCreateCounterexample -> [ProviderTagRow]
frozenCreateProviderTags = internalCreateProviderTags

frozenCreateInterruptionMatrix :: FrozenCreateCounterexample -> [InterruptionRow]
frozenCreateInterruptionMatrix = internalCreateInterruptionMatrix

frozenCreateExternalStateMatrix :: FrozenCreateCounterexample -> [ExternalStateRow]
frozenCreateExternalStateMatrix = internalCreateExternalStateMatrix

frozenCreateCausalProfile :: FrozenCreateCounterexample -> CounterexampleResourceProfile
frozenCreateCausalProfile = internalCreateCausalProfile

frozenCreateProductionProfile :: FrozenCreateCounterexample -> CounterexampleResourceProfile
frozenCreateProductionProfile = internalCreateProductionProfile

frozenCreateArtifactDigest :: FrozenCreateCounterexample -> CreateArtifactDigest
frozenCreateArtifactDigest = internalCreateArtifactDigest

canonicalCreateFixtureId :: CreateFixtureId
canonicalCreateFixtureId = CreateFixtureId "CREATE-INTERRUPTED-2026-09-08"

canonicalCreateEvidenceScope :: CreateEvidenceScope
canonicalCreateEvidenceScope =
  CreateEvidenceScope
    { createScopeRun = "stack-create/1757318400000000"
    , createScopeSubmission = "operator-reconcile-aws-eks-0001"
    , createScopeRegistryRevision = "lifecycle-registry/v1"
    , createScopeSurface = "registered-stack-create"
    , createScopeOperation = "reconcile-desired-present"
    , createScopeFoundation = "linux-rke2/home"
    , createScopeAwsAccount = "111122223333"
    , createScopeAwsRegion = canonicalRegressionAwsRegion
    , createScopeStack = "aws-eks"
    }

-- | The coordinates the 2026-09-08 create made and named with nothing.
canonicalDeclaredCoordinates :: [DeclaredCoordinate]
canonicalDeclaredCoordinates =
  [ DeclaredCoordinate "aws-eks-vpc" "aws:ec2:Vpc"
  , DeclaredCoordinate "aws-eks-cluster" "aws:eks:Cluster"
  , DeclaredCoordinate "aws-eks-node-group" "aws:eks:NodeGroup"
  , DeclaredCoordinate "aws-eks-node-role" "aws:iam:Role"
  , DeclaredCoordinate "aws-eks-node-role-policy" "aws:iam:RolePolicyAttachment"
  ]

canonicalObservedIdentities :: [ObservedIdentity]
canonicalObservedIdentities =
  [ ObservedIdentity "aws-eks-vpc" "provider-operation/vpc-0001"
  , ObservedIdentity "aws-eks-cluster" "provider-operation/cluster-0001"
  , ObservedIdentity "aws-eks-node-group" "provider-operation/node-group-0001"
  , ObservedIdentity "aws-eks-node-role" "provider-operation/node-role-0001"
  , ObservedIdentity "aws-eks-node-role-policy" "provider-operation/node-role-policy-0001"
  ]

canonicalProviderTags :: [ProviderTagRow]
canonicalProviderTags =
  [ ProviderTagRow "prodbox.io/run-scope" "stack-create/1757318400000000"
  , ProviderTagRow "prodbox.io/submission" "operator-reconcile-aws-eks-0001"
  ]

canonicalCreateFaultSchedule :: [Text]
canonicalCreateFaultSchedule =
  map createTransitionText (implementationTransitions ReplacementCreate)

canonicalCreateCausalProfile :: CounterexampleResourceProfile
canonicalCreateCausalProfile =
  createProfile
    "create-interrupted-causal-v1"
    "causal"
    (ProfileBackgroundLoad 4 2 1024)
    False
    (ProfileEnvelope "legacy-create-submitter" 900 1024 768 768)
    [ ProfileEnvelope "lifecycle-authority" 350 448 256 384
    , ProfileEnvelope "provider-worker" 300 320 256 192
    , ProfileEnvelope "ownership-manifest-store" 250 256 256 192
    ]

canonicalCreateProductionProfile :: CounterexampleResourceProfile
canonicalCreateProductionProfile =
  createProfile
    "create-interrupted-production-v1"
    "production"
    (ProfileBackgroundLoad 20 4 2048)
    True
    (ProfileEnvelope "legacy-create-submitter" 1500 2048 1536 1536)
    [ ProfileEnvelope "lifecycle-authority" 600 896 512 768
    , ProfileEnvelope "provider-worker" 500 640 512 384
    , ProfileEnvelope "ownership-manifest-store" 400 512 512 384
    ]

createProfile
  :: Text
  -> Text
  -> ProfileBackgroundLoad
  -> Bool
  -> ProfileEnvelope
  -> [ProfileEnvelope]
  -> CounterexampleResourceProfile
createProfile profileId profileKind load justified supersededEnvelope replacementEnvelopes =
  CounterexampleResourceProfile
    { format_version = 1
    , fixture_id = createFixtureIdText canonicalCreateFixtureId
    , profile_id = profileId
    , profile_kind = profileKind
    , background_load = load
    , fault_schedule = canonicalCreateFaultSchedule
    , fault_schedule_digest = counterexampleArtifactDigestText canonicalCreateFaultSchedule
    , independently_justified = justified
    , superseded_envelopes = [supersededEnvelope]
    , replacement_envelopes = replacementEnvelopes
    , envelope_mapping =
        [ ProfileEnvelopeMapping
            { superseded_component = component supersededEnvelope
            , replacement_components = map component replacementEnvelopes
            }
        ]
    }

data CreateArtifactKind
  = CreateTraceArtifact
  | CreateDispositionsArtifact
  | CreateCausalProfileArtifact
  | CreateProductionProfileArtifact
  deriving stock (Eq, Ord, Show)

data CreateCounterexampleError
  = CreateArtifactUnreadable !FilePath !Text
  | CreateArtifactUnbounded !CreateArtifactKind !Int !Int
  | CreateArtifactInvalidUtf8 !CreateArtifactKind !Text
  | CreateArtifactMalformed !CreateArtifactKind !Text
  | CreateArtifactSemanticMismatch !CreateArtifactKind !Text
  | CreateInterruptionDuplicate !InterruptionRow
  | CreateInterruptionInventoryIncomplete !Int !Int
  | CreateInterruptionDispositionMismatch
      !CreateImplementation
      !CreateTransition
      !InterruptionSide
      !SuccessorDisposition
      !SuccessorDisposition
  | CreateExternalStateDuplicate !CreateImplementation !ExternalStateCase
  | CreateExternalStateInventoryIncomplete !CreateImplementation ![ExternalStateCase]
  | CreateExternalStateUnreachable !CreateImplementation !ExternalStateCase
  | CreateExternalStateDispositionMismatch
      !CreateImplementation
      !ExternalStateCase
      !SuccessorDisposition
      !SuccessorDisposition
  | CreateProfileDecodeFailure !CreateArtifactKind !Text
  | CreateProfileMismatch !CreateArtifactKind
  | CreateProfileBudgetNotNormalized !CreateArtifactKind
  | CreateArtifactDigestMismatch !CreateArtifactDigest !CreateArtifactDigest
  deriving stock (Eq, Show)

data CreateTraceFixture
  = CanonicalCreateTrace
  | MutatedCreateTrace
  deriving stock (Eq, Ord, Show)

qualificationDirectory :: FilePath -> FilePath
qualificationDirectory repoRoot = repoRoot </> "test" </> "qualification"

createTraceFixturePath :: FilePath -> FilePath
createTraceFixturePath repoRoot =
  qualificationDirectory repoRoot </> "CREATE-INTERRUPTED-2026-09-08.trace"

createDispositionsFixturePath :: FilePath -> CreateTraceFixture -> FilePath
createDispositionsFixturePath repoRoot traceFixture =
  qualificationDirectory repoRoot </> case traceFixture of
    CanonicalCreateTrace -> "CREATE-INTERRUPTED-2026-09-08.dispositions"
    MutatedCreateTrace -> "CREATE-INTERRUPTED-2026-09-08.mutated.dispositions"

createCausalProfileFixturePath :: FilePath -> FilePath
createCausalProfileFixturePath repoRoot =
  qualificationDirectory repoRoot </> "CREATE-INTERRUPTED-2026-09-08.causal-profile.dhall"

createProductionProfileFixturePath :: FilePath -> FilePath
createProductionProfileFixturePath repoRoot =
  qualificationDirectory repoRoot
    </> "CREATE-INTERRUPTED-2026-09-08.production-profile.dhall"

maximumCreateTraceBytes, maximumCreateDispositionsBytes, maximumCreateProfileBytes :: Int
maximumCreateTraceBytes = 64 * 1024
maximumCreateDispositionsBytes = 128 * 1024
maximumCreateProfileBytes = 32 * 1024

loadCreateCounterexampleFixture
  :: FilePath
  -> CreateTraceFixture
  -> IO (Either CreateCounterexampleError FrozenCreateCounterexample)
loadCreateCounterexampleFixture repoRoot traceFixture = do
  traceResult <-
    readCreateArtifactBounded
      CreateTraceArtifact
      maximumCreateTraceBytes
      (createTraceFixturePath repoRoot)
  dispositionsResult <-
    readCreateArtifactBounded
      CreateDispositionsArtifact
      maximumCreateDispositionsBytes
      (createDispositionsFixturePath repoRoot traceFixture)
  causalResult <-
    readCreateArtifactBounded
      CreateCausalProfileArtifact
      maximumCreateProfileBytes
      (createCausalProfileFixturePath repoRoot)
  productionResult <-
    readCreateArtifactBounded
      CreateProductionProfileArtifact
      maximumCreateProfileBytes
      (createProductionProfileFixturePath repoRoot)
  case (traceResult, dispositionsResult, causalResult, productionResult) of
    (Right traceContents, Right dispositionContents, Right causalContents, Right productionContents) ->
      parseCreateCounterexampleArtifacts
        traceContents
        dispositionContents
        causalContents
        productionContents
    (Left err, _, _, _) -> pure (Left err)
    (_, Left err, _, _) -> pure (Left err)
    (_, _, Left err, _) -> pure (Left err)
    (_, _, _, Left err) -> pure (Left err)

loadCreateCounterexample
  :: FilePath -> IO (Either CreateCounterexampleError FrozenCreateCounterexample)
loadCreateCounterexample repoRoot =
  loadCreateCounterexampleFixture repoRoot CanonicalCreateTrace

readCreateArtifactBounded
  :: CreateArtifactKind
  -> Int
  -> FilePath
  -> IO (Either CreateCounterexampleError Text)
readCreateArtifactBounded artifactKind maximumBytes path = do
  readResult <-
    try (withBinaryFile path ReadMode (\handle -> ByteString.hGet handle (maximumBytes + 1)))
      :: IO (Either IOException ByteString)
  pure $ case readResult of
    Left err -> Left (CreateArtifactUnreadable path (Text.pack (show err)))
    Right bytes
      | ByteString.length bytes > maximumBytes ->
          Left (CreateArtifactUnbounded artifactKind maximumBytes (ByteString.length bytes))
      | otherwise -> case TextEncoding.decodeUtf8' bytes of
          Left err -> Left (CreateArtifactInvalidUtf8 artifactKind (Text.pack (show err)))
          Right contents -> Right contents

-- | Decode and validate all four bounded artifact schemas.
--
-- IO only because the two profile texts are decoded by Dhall.
parseCreateCounterexampleArtifacts
  :: Text
  -> Text
  -> Text
  -> Text
  -> IO (Either CreateCounterexampleError FrozenCreateCounterexample)
parseCreateCounterexampleArtifacts traceContents dispositionContents causalContents productionContents =
  case validateCreateTrace traceContents of
    Left err -> pure (Left err)
    Right () -> case parseDispositionMatrices dispositionContents of
      Left err -> pure (Left err)
      Right (interruptionRows, externalRows) -> do
        causalDecoded <- decodeCreateProfile CreateCausalProfileArtifact causalContents
        productionDecoded <-
          decodeCreateProfile CreateProductionProfileArtifact productionContents
        pure $ do
          causalProfile <- causalDecoded
          productionProfile <- productionDecoded
          requireCreateProfile
            CreateCausalProfileArtifact
            canonicalCreateCausalProfile
            causalProfile
          requireCreateProfile
            CreateProductionProfileArtifact
            canonicalCreateProductionProfile
            productionProfile
          -- The budget constant is checked here rather than asserted in a test,
          -- because a family whose profiles do not hold it is not a usable
          -- counterexample and should not load at all.
          requireNormalizedBudget CreateCausalProfileArtifact causalProfile
          requireNormalizedBudget CreateProductionProfileArtifact productionProfile
          let observedDigest =
                CreateArtifactDigest
                  ( counterexampleArtifactDigestText
                      [traceContents, dispositionContents, causalContents, productionContents]
                  )
          Right
            FrozenCreateCounterexample
              { internalCreateFixtureId = canonicalCreateFixtureId
              , internalCreateEvidenceScope = canonicalCreateEvidenceScope
              , internalCreateDeclaredCoordinates = canonicalDeclaredCoordinates
              , internalCreateObservedIdentities = canonicalObservedIdentities
              , internalCreateProviderTags = canonicalProviderTags
              , internalCreateInterruptionMatrix = interruptionRows
              , internalCreateExternalStateMatrix = externalRows
              , internalCreateCausalProfile = causalProfile
              , internalCreateProductionProfile = productionProfile
              , internalCreateArtifactDigest = observedDigest
              }

decodeCreateProfile
  :: CreateArtifactKind
  -> Text
  -> IO (Either CreateCounterexampleError CounterexampleResourceProfile)
decodeCreateProfile artifactKind contents = do
  decoded <-
    try (Dhall.input Dhall.auto contents)
      :: IO (Either SomeException CounterexampleResourceProfile)
  pure $ case decoded of
    Left err -> Left (CreateProfileDecodeFailure artifactKind (Text.pack (show err)))
    Right profile -> Right profile

requireCreateProfile
  :: CreateArtifactKind
  -> CounterexampleResourceProfile
  -> CounterexampleResourceProfile
  -> Either CreateCounterexampleError ()
requireCreateProfile artifactKind expected observed =
  if observed == expected then Right () else Left (CreateProfileMismatch artifactKind)

requireNormalizedBudget
  :: CreateArtifactKind
  -> CounterexampleResourceProfile
  -> Either CreateCounterexampleError ()
requireNormalizedBudget artifactKind profile =
  if topologyNormalizedBudgetHolds profile
    then Right ()
    else Left (CreateProfileBudgetNotNormalized artifactKind)

-- | The trace states the scope, the declared coordinates, the observed
-- identities, the provider tags, and each implementation's lane.  Every one of
-- them is compared against the in-module canonical value rather than trusted,
-- so an edited trace refuses instead of redefining the counterexample.
validateCreateTrace :: Text -> Either CreateCounterexampleError ()
validateCreateTrace contents = do
  facts <- traverse parseTraceLine (significantLines contents)
  requireTrace "format-version 1" (TraceFormatVersion 1 `elem` facts)
  requireTrace
    "fixture-id"
    (TraceFixtureId (createFixtureIdText canonicalCreateFixtureId) `elem` facts)
  requireTrace "run-scope" (TraceScope "run-scope" (createScopeRun scope) `elem` facts)
  requireTrace
    "submission-key"
    (TraceScope "submission-key" (createScopeSubmission scope) `elem` facts)
  requireTrace
    "registry-revision"
    (TraceScope "registry-revision" (createScopeRegistryRevision scope) `elem` facts)
  requireTrace "surface" (TraceScope "surface" (createScopeSurface scope) `elem` facts)
  requireTrace "operation" (TraceScope "operation" (createScopeOperation scope) `elem` facts)
  requireTrace "foundation" (TraceScope "foundation" (createScopeFoundation scope) `elem` facts)
  requireTrace
    "aws-account"
    (TraceScope "aws-account" (createScopeAwsAccount scope) `elem` facts)
  requireTrace "aws-region" (TraceScope "aws-region" (createScopeAwsRegion scope) `elem` facts)
  requireTrace "stack" (TraceScope "stack" (createScopeStack scope) `elem` facts)
  requireTrace
    "declared coordinates"
    ([coordinate | TraceDeclared coordinate <- facts] == canonicalDeclaredCoordinates)
  requireTrace
    "observed identities"
    ([identity | TraceObserved identity <- facts] == canonicalObservedIdentities)
  requireTrace
    "provider tags"
    ([tagRow | TraceProviderTag tagRow <- facts] == canonicalProviderTags)
  traverse_'
    ( \implementation ->
        requireTrace
          ("lane " <> createImplementationText implementation)
          ( [ transition
            | TraceLane laneImplementation transition <- facts
            , laneImplementation == implementation
            ]
              == implementationTransitions implementation
          )
    )
    [minBound .. maxBound]
 where
  scope = canonicalCreateEvidenceScope
  requireTrace subject holds =
    if holds
      then Right ()
      else Left (CreateArtifactSemanticMismatch CreateTraceArtifact subject)
  traverse_' action = foldr (\value rest -> action value >> rest) (Right ())

data TraceFact
  = TraceFormatVersion !Natural
  | TraceFixtureId !Text
  | TraceScope !Text !Text
  | TraceDeclared !DeclaredCoordinate
  | TraceObserved !ObservedIdentity
  | TraceProviderTag !ProviderTagRow
  | TraceLane !CreateImplementation !CreateTransition
  deriving stock (Eq, Show)

parseTraceLine :: Text -> Either CreateCounterexampleError TraceFact
parseTraceLine line = case Text.words line of
  ["format-version", value] ->
    maybe (malformed CreateTraceArtifact line) (Right . TraceFormatVersion) (readNatural value)
  ["fixture-id", value] -> Right (TraceFixtureId value)
  ["declared", name, resourceType] -> Right (TraceDeclared (DeclaredCoordinate name resourceType))
  ["observed", name, value] -> Right (TraceObserved (ObservedIdentity name value))
  ["provider-tag", key, value] -> Right (TraceProviderTag (ProviderTagRow key value))
  ["lane", implementationToken, transitionToken] -> do
    implementation <- parseImplementation CreateTraceArtifact line implementationToken
    transition <- parseTransition CreateTraceArtifact line transitionToken
    Right (TraceLane implementation transition)
  [key, value]
    | key
        `elem` [ "run-scope"
               , "submission-key"
               , "registry-revision"
               , "surface"
               , "operation"
               , "foundation"
               , "aws-account"
               , "aws-region"
               , "stack"
               ] ->
        Right (TraceScope key value)
  _ -> malformed CreateTraceArtifact line

-- | Read both matrices, then check each one against the derived inventory.
--
-- The check is bidirectional on purpose: a row the oracle does not derive is a
-- refusal, and a row the oracle derives that the file omits is a refusal too.
-- A one-directional check passes a file that says nothing.
parseDispositionMatrices
  :: Text
  -> Either CreateCounterexampleError ([InterruptionRow], [ExternalStateRow])
parseDispositionMatrices contents = do
  rows <- traverse parseDispositionLine (significantLines contents)
  validateDispositionHeader rows
  let interruptionRows = [row | DispositionInterruption row <- rows]
      externalRows = [row | DispositionExternal row <- rows]
  validateInterruptionMatrix interruptionRows
  validateExternalStateMatrix externalRows
  Right (interruptionRows, externalRows)

-- | The header states which side of the counterexample each implementation is
-- on.  Standard P wants that stated in the artifact and not only in the code
-- that reads it, and an unchecked header line would be a claim the fixture
-- makes and nothing tests.
validateDispositionHeader :: [DispositionLine] -> Either CreateCounterexampleError ()
validateDispositionHeader rows = do
  requireHeader "format-version 1" (DispositionFormatVersion 1 `elem` rows)
  requireHeader
    "fixture-id"
    ( DispositionFixtureId (createFixtureIdText canonicalCreateFixtureId)
        `elem` rows
    )
  requireHeader
    "superseded result"
    ( DispositionResult SupersededCreate "unnameable-create-orphan" "expected-failure"
        `elem` rows
    )
  requireHeader
    "replacement result"
    ( DispositionResult
        ReplacementCreate
        "write-ahead-record-names-coordinates"
        "expected-pass"
        `elem` rows
    )
  requireHeader
    "exactly one result per implementation"
    (length [() | DispositionResult {} <- rows] == 2)
 where
  requireHeader subject holds =
    if holds
      then Right ()
      else Left (CreateArtifactSemanticMismatch CreateDispositionsArtifact subject)

data DispositionLine
  = DispositionFormatVersion !Natural
  | DispositionFixtureId !Text
  | DispositionResult !CreateImplementation !Text !Text
  | DispositionInterruption !InterruptionRow
  | DispositionExternal !ExternalStateRow
  deriving stock (Eq, Show)

parseDispositionLine :: Text -> Either CreateCounterexampleError DispositionLine
parseDispositionLine line = case Text.words line of
  ["format-version", value] ->
    maybe
      (malformed CreateDispositionsArtifact line)
      (Right . DispositionFormatVersion)
      (readNatural value)
  ["fixture-id", value] -> Right (DispositionFixtureId value)
  ["result", implementationToken, mechanism, expectation] -> do
    implementation <- parseImplementation CreateDispositionsArtifact line implementationToken
    Right (DispositionResult implementation mechanism expectation)
  ["external", implementationToken, caseToken, dispositionToken] -> do
    implementation <- parseImplementation CreateDispositionsArtifact line implementationToken
    externalCase <- parseExternalCase line caseToken
    disposition <- parseDisposition CreateDispositionsArtifact line dispositionToken
    Right (DispositionExternal (ExternalStateRow implementation externalCase disposition))
  ["interrupt", implementationToken, kindToken, sideToken, transitionToken, dispositionToken] -> do
    implementation <- parseImplementation CreateDispositionsArtifact line implementationToken
    kind <- parseInterruptionKind line kindToken
    side <- parseInterruptionSide line sideToken
    transition <- parseTransition CreateDispositionsArtifact line transitionToken
    disposition <- parseDisposition CreateDispositionsArtifact line dispositionToken
    Right
      ( DispositionInterruption
          (InterruptionRow implementation kind side transition disposition)
      )
  _ -> malformed CreateDispositionsArtifact line

validateInterruptionMatrix :: [InterruptionRow] -> Either CreateCounterexampleError ()
validateInterruptionMatrix rows = do
  case duplicateValues (map interruptionRowCoordinate rows) of
    duplicate : _ ->
      case [row | row <- rows, interruptionRowCoordinate row == duplicate] of
        row : _ -> Left (CreateInterruptionDuplicate row)
        [] -> Right ()
    [] -> Right ()
  if length rows /= length canonicalInterruptionMatrix
    then
      Left
        ( CreateInterruptionInventoryIncomplete
            (length canonicalInterruptionMatrix)
            (length rows)
        )
    else foldr checkRow (Right ()) rows
 where
  interruptionRowCoordinate row =
    ( interruptionRowImplementation row
    , interruptionRowKind row
    , interruptionRowSide row
    , interruptionRowTransition row
    )
  checkRow row rest
    | interruptionRowTransition row
        `notElem` implementationTransitions (interruptionRowImplementation row) =
        Left
          ( CreateInterruptionDispositionMismatch
              (interruptionRowImplementation row)
              (interruptionRowTransition row)
              (interruptionRowSide row)
              (interruptionRowDisposition row)
              (interruptionRowDisposition row)
          )
    | interruptionRowDisposition row /= derived = Left (mismatch row derived)
    | otherwise = rest
   where
    derived =
      successorDispositionFor
        (interruptionRowImplementation row)
        (interruptionRowTransition row)
        (interruptionRowSide row)
  mismatch row derived =
    CreateInterruptionDispositionMismatch
      (interruptionRowImplementation row)
      (interruptionRowTransition row)
      (interruptionRowSide row)
      derived
      (interruptionRowDisposition row)

validateExternalStateMatrix :: [ExternalStateRow] -> Either CreateCounterexampleError ()
validateExternalStateMatrix rows =
  foldr checkImplementation (Right ()) [minBound .. maxBound]
 where
  checkImplementation implementation rest = do
    let implementationRows =
          [row | row <- rows, externalStateRowImplementation row == implementation]
        declaredCases = map externalStateRowCase implementationRows
        expectedCases = reachableExternalStateCases implementation
    case duplicateValues declaredCases of
      duplicate : _ -> Left (CreateExternalStateDuplicate implementation duplicate)
      [] -> Right ()
    case [externalCase | externalCase <- declaredCases, externalCase `notElem` expectedCases] of
      unreachable : _ -> Left (CreateExternalStateUnreachable implementation unreachable)
      [] -> Right ()
    case [externalCase | externalCase <- expectedCases, externalCase `notElem` declaredCases] of
      [] -> Right ()
      missing -> Left (CreateExternalStateInventoryIncomplete implementation missing)
    foldr (checkRow implementation) (Right ()) implementationRows
    rest
  checkRow implementation row rest =
    let derived = externalStateDispositionFor implementation (externalStateRowCase row)
     in if externalStateRowDisposition row == derived
          then rest
          else
            Left
              ( CreateExternalStateDispositionMismatch
                  implementation
                  (externalStateRowCase row)
                  derived
                  (externalStateRowDisposition row)
              )

parseImplementation
  :: CreateArtifactKind
  -> Text
  -> Text
  -> Either CreateCounterexampleError CreateImplementation
parseImplementation artifactKind line token =
  lookupToken artifactKind line createImplementationText token

parseTransition
  :: CreateArtifactKind -> Text -> Text -> Either CreateCounterexampleError CreateTransition
parseTransition artifactKind line token =
  lookupToken artifactKind line createTransitionText token

parseDisposition
  :: CreateArtifactKind
  -> Text
  -> Text
  -> Either CreateCounterexampleError SuccessorDisposition
parseDisposition artifactKind line token =
  lookupToken artifactKind line successorDispositionText token

parseInterruptionKind :: Text -> Text -> Either CreateCounterexampleError InterruptionKind
parseInterruptionKind line token =
  lookupToken CreateDispositionsArtifact line interruptionKindText token

parseInterruptionSide :: Text -> Text -> Either CreateCounterexampleError InterruptionSide
parseInterruptionSide line token =
  lookupToken CreateDispositionsArtifact line interruptionSideText token

parseExternalCase :: Text -> Text -> Either CreateCounterexampleError ExternalStateCase
parseExternalCase line token =
  lookupToken CreateDispositionsArtifact line externalStateCaseText token

-- | Read a token as a value of a bounded enumeration by rendering every
-- inhabitant.  There is one rendering function per type and it is the same one
-- the fixture is written with, so a value can never have a spelling the reader
-- and the writer disagree about.
lookupToken
  :: (Bounded value, Enum value)
  => CreateArtifactKind
  -> Text
  -> (value -> Text)
  -> Text
  -> Either CreateCounterexampleError value
lookupToken artifactKind line render token =
  case [value | value <- [minBound .. maxBound], render value == token] of
    value : _ -> Right value
    [] -> malformed artifactKind line

malformed :: CreateArtifactKind -> Text -> Either CreateCounterexampleError value
malformed artifactKind line = Left (CreateArtifactMalformed artifactKind line)

readNatural :: Text -> Maybe Natural
readNatural = readMaybe . Text.unpack

significantLines :: Text -> [Text]
significantLines contents =
  [ stripped
  | line <- Text.lines contents
  , let stripped = Text.strip line
  , not (Text.null stripped)
  , not ("#" `Text.isPrefixOf` stripped)
  ]

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues = foldr collectDuplicate [] . group . sort
 where
  collectDuplicate groupedValues duplicates = case groupedValues of
    value : _ : _ -> value : duplicates
    _ -> duplicates

-- | What the oracle answers for one implementation.
--
-- The counterexample is closed only if the superseded implementation reaches
-- 'OrphanUnnameable' somewhere and the replacement reaches it nowhere.  Both
-- halves are needed: an implementation that never runs the effect also never
-- orphans anything, and it is not a fix.
data CreateOracleOutcome = CreateOracleOutcome
  { oracleImplementation :: !CreateImplementation
  , oracleOrphanPoints :: ![InterruptionRow]
  , oracleNamedPoints :: ![InterruptionRow]
  , oracleRunsTheEffect :: !Bool
  }
  deriving stock (Eq, Show)

data CreateOracleResult = CreateOracleResult
  { oracleSupersededOutcome :: !CreateOracleOutcome
  , oracleReplacementOutcome :: !CreateOracleOutcome
  , oracleCounterexampleClosed :: !Bool
  }
  deriving stock (Eq, Show)

-- | Decide the counterexample from the loaded fixture.
runCreateInterruptedOracle :: FrozenCreateCounterexample -> CreateOracleResult
runCreateInterruptedOracle fixture =
  CreateOracleResult
    { oracleSupersededOutcome = superseded
    , oracleReplacementOutcome = replacement
    , oracleCounterexampleClosed =
        oracleRunsTheEffect superseded
          && oracleRunsTheEffect replacement
          && not (null (oracleOrphanPoints superseded))
          && null (oracleOrphanPoints replacement)
          && not (null (oracleNamedPoints replacement))
    }
 where
  superseded = outcomeFor SupersededCreate
  replacement = outcomeFor ReplacementCreate
  outcomeFor implementation =
    CreateOracleOutcome
      { oracleImplementation = implementation
      , oracleOrphanPoints = pointsWith implementation OrphanUnnameable
      , oracleNamedPoints = pointsWith implementation CoordinatesNamed
      , oracleRunsTheEffect =
          ExecuteAdmittedCreate `elem` implementationTransitions implementation
      }
  pointsWith implementation disposition =
    [ row
    | row <- frozenCreateInterruptionMatrix fixture
    , interruptionRowImplementation row == implementation
    , interruptionRowDisposition row == disposition
    ]
