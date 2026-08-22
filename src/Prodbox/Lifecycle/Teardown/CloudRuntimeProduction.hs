{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Sprint 4.86: the composition root for the cloud half of a
-- descriptor-bound cascade.
--
-- "Prodbox.Lifecycle.Teardown.CloudRuntime" is the closed dispatcher for the
-- fourteen cloud-owned operations, and by the time this module was written
-- nothing in the repository constructed one outside a fixture: every component
-- it normalizes had a production surface, and no value put them together.  The
-- descriptor-bound dispatcher therefore admitted a closed cascade /host/
-- runtime it could construct and a closed cloud runtime it could not.
--
-- Five properties carry the design.
--
--   * __One registered-target interpreter, by construction.__  Checkpoint
--     recovery, EKS drain, and registered reconciliation must address the same
--     Provider boundary; 'mkCloudRuntime' already normalizes that, and this
--     module builds exactly one interpreter to hand it rather than three that
--     happen to agree.
--
--   * __Every durable input is read back, never remembered.__  The decision
--     inputs, the Provider binding, the post-recovery checkpoint pair, the
--     ownership manifest, and the creation binding are all obtained from the
--     Lifecycle Authority at the moment the node executes.  Nothing is carried
--     between nodes by this record, which is why it holds no mutable state.
--
--   * __The host reads through the closed authenticated protocol only.__  The
--     three durable readers and both EKS clients go over one authenticated
--     Authority transport; no arm opens an object store, a Vault session, or a
--     provider CLI of its own.  The one process this module causes to run is
--     @kubectl@ against a Provider-issued projection, inside the boundary that
--     already owns that ephemerality.
--
--   * __The ephemeral facts a selection needs are derived, not sampled.__  A
--     drain intent is committed durably and a resumed run must re-derive the
--     same one, so the two observation revisions come from the attempt's own
--     operation identity under two distinct dispatch purposes.  Sampling a
--     counter here would let a replay commit a second intent for one
--     operation.
--
--   * __Liveness is the only thing a clock decides.__  The drain deadline is
--     @now + lease@ under an operator-declared lease bounded at construction by
--     the session ceiling, so a deadline this runtime computes cannot be
--     refused later by 'Prodbox.Lifecycle.Teardown.EksDrainSession' for a
--     reason the operator could only discover mid-cascade.  The execution
--     identity the callback receives supplies no freedom, which is why it is
--     ignored rather than consulted.
--
-- What this module does not own: whether a cascade runs, which is the
-- non-public candidate entrypoint Sprint @4.86@ still owns; and the four
-- cascade host nodes, which reach "Prodbox.ControlPlane.CascadeHostRuntime"
-- instead.  Building this runtime issues no AWS mutation and no wire call.
module Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( -- * What the caller supplies
    ProductionCloudRuntimeInputs (..)

    -- * The bounded drain lease
  , EksDrainLeaseSeconds
  , eksDrainLeaseSecondsValue
  , mkEksDrainLeaseSeconds

    -- * What can go wrong before a node runs
  , ProductionCloudRuntimeError (..)
  , renderProductionCloudRuntimeError

    -- * The runtime
  , productionCloudRuntime
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityOperationClient
  ( lifecycleAuthorityOperationClientAuthenticated
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( committedAwsStackCreationConfig
  , committedAwsStackCreationRevision
  , readBackCommittedAwsStackCreationBindingForScope
  )
import Prodbox.ControlPlane.AwsStackCreationBindingTransportClient
  ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  )
import Prodbox.ControlPlane.AwsStackReaderRepository
  ( AwsStackReaderClient
  , readBackAwsStackDecisionInputs
  , readBackAwsStackProviderBinding
  )
import Prodbox.ControlPlane.AwsStackReaderTransportClient
  ( lifecycleAuthorityAwsStackReaderAuthenticatedClient
  )
import Prodbox.ControlPlane.EksDrainIntentTransportClient
  ( lifecycleAuthorityEksDrainIntentAuthenticatedClient
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptTransportClient
  ( lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( readBackOwnershipManifestDecisionForScope
  )
import Prodbox.ControlPlane.OwnershipManifestTransportClient
  ( lifecycleAuthorityOwnershipManifestAuthenticatedClient
  )
import Prodbox.ControlPlane.PulumiCheckpointClient
  ( PulumiCheckpointAuthority
  , lifecycleAuthorityPulumiCheckpointAuthenticated
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupOperationId
  , CleanupRunId
  )
import Prodbox.Lifecycle.PulumiCheckpoint
  ( RegisteredPulumiCheckpointError
  , registeredPulumiCheckpointByName
  )
import Prodbox.Lifecycle.Teardown.AwsCheckpointInterpreter
  ( AwsCheckpointInterpreter (..)
  , AwsCheckpointInterpreterError
  , mkAwsCheckpointAuthorities
  , observeAwsStackCheckpointPair
  )
import Prodbox.Lifecycle.Teardown.AwsEksRegisteredTargetDestroyInterpreter
  ( awsEksRegisteredTargetDestroyBoundary
  , mkAwsEksRegisteredTargetDestroyInterpreter
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
  ( AwsRegisteredTargetInterpreter (..)
  , AwsStackProviderBinding
  , mkAwsStackProviderBinding
  )
import Prodbox.Lifecycle.Teardown.AwsStackReaderInterpreter
  ( AwsStackReaderInterpreter (..)
  , mkAwsStackReaderInputReaders
  )
import Prodbox.Lifecycle.Teardown.CloudRuntime
  ( CloudRuntime
  , mkCloudRuntime
  )
import Prodbox.Lifecycle.Teardown.Dns01ChallengeOwnerDeleteInterpreter
  ( productionDns01ChallengeOwnerDeleteBoundary
  )
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
  ( mkEksDrainInterpreter
  , productionEksDrainAttemptBoundary
  , productionEksDrainCommitSelectionBoundary
  )
import Prodbox.Lifecycle.Teardown.EksDrainSession
  ( maximumEksDrainLifetimeSeconds
  )
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
  ( EksDrainSelectionParameters (..)
  , EksTeardownExecutor (..)
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownExecutionContext
  , teardownExecutionObservationScope
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  , teardownExecutionIdentityOperationId
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationRevision)
import Prodbox.Lifecycle.Teardown.Observation (CheckpointPairObservation)
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( OwnershipManifestDecisionEvidence
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , registeredTargetKey
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchPurpose
      ( ProviderAbsenceReadBack
      , ProviderDecisionObservation
      )
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  , productionTeardownProviderBoundary
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- ---------------------------------------------------------------------------
-- What the caller supplies
-- ---------------------------------------------------------------------------

-- | The inputs a cascade brings that cannot be read off the compiled program.
--
-- Deliberately small: everything the runtime addresses — stacks, checkpoint
-- registrations, scopes, resource keys — comes from the compiled program and
-- the lifecycle registry, so a caller cannot widen what the cloud half may
-- reach by supplying a different value here.
data ProductionCloudRuntimeInputs = ProductionCloudRuntimeInputs
  { productionCloudRepositoryRoot :: !FilePath
  , productionCloudCaller :: !ExternalLifecycleAuthorityCaller
  , productionCloudKubectlPath :: !FilePath
  , productionCloudKubectlEnvironment :: ![(String, String)]
  -- ^ The drain boundary filters the forbidden keys out of this itself, so a
  -- caller cannot leak a credential variable into the ephemeral client by
  -- forgetting to.
  , productionCloudKubectlWorkingDirectory :: !(Maybe FilePath)
  , productionCloudDrainLease :: !EksDrainLeaseSeconds
  }

-- ---------------------------------------------------------------------------
-- The bounded drain lease
-- ---------------------------------------------------------------------------

-- | How long past @now@ a freshly issued EKS drain session may live.
newtype EksDrainLeaseSeconds = EksDrainLeaseSeconds Integer
  deriving stock (Eq, Show)

eksDrainLeaseSecondsValue :: EksDrainLeaseSeconds -> Integer
eksDrainLeaseSecondsValue (EksDrainLeaseSeconds seconds) = seconds

mkEksDrainLeaseSeconds
  :: Integer -> Either ProductionCloudRuntimeError EksDrainLeaseSeconds
mkEksDrainLeaseSeconds seconds
  | seconds <= 0 || seconds > maximumEksDrainLifetimeSeconds =
      Left (ProductionCloudDrainLeaseInvalid seconds)
  | otherwise = Right (EksDrainLeaseSeconds seconds)

-- ---------------------------------------------------------------------------
-- What can go wrong before a node runs
-- ---------------------------------------------------------------------------

data ProductionCloudRuntimeError
  = ProductionCloudDrainLeaseInvalid !Integer
  | ProductionCloudCheckpointUnregistered
      !Text
      !RegisteredPulumiCheckpointError
  | ProductionCloudCheckpointAuthoritiesInvalid
      !AwsCheckpointInterpreterError
  deriving stock (Eq, Show)

renderProductionCloudRuntimeError :: ProductionCloudRuntimeError -> String
renderProductionCloudRuntimeError = \case
  ProductionCloudDrainLeaseInvalid seconds ->
    "the EKS drain lease must be within 1.."
      ++ show maximumEksDrainLifetimeSeconds
      ++ " seconds, not "
      ++ show seconds
  ProductionCloudCheckpointUnregistered name err ->
    "the Pulumi checkpoint "
      ++ Text.unpack name
      ++ " is not registered: "
      ++ show err
  ProductionCloudCheckpointAuthoritiesInvalid err ->
    "the checkpoint authorities do not match their registrations: " ++ show err

-- ---------------------------------------------------------------------------
-- The runtime
-- ---------------------------------------------------------------------------

-- | Assemble the closed cloud runtime for one compiled run.
--
-- The run and graph identities are arguments rather than fields of the inputs
-- because the stack-reader client seals them into every request it makes: a
-- runtime built for one run cannot commit or read back another run's bundle,
-- and that is a property of this value rather than of its callers' discipline.
productionCloudRuntime
  :: ProductionCloudRuntimeInputs
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> CleanupRunId
  -> CleanupDigest
  -> Either ProductionCloudRuntimeError (CloudRuntime IO)
productionCloudRuntime inputs transport runId graphDigest = do
  eks <- checkpointAuthority "aws-eks"
  subzone <- checkpointAuthority "aws-eks-subzone"
  testStack <- checkpointAuthority "aws-test"
  authorities <-
    first
      ProductionCloudCheckpointAuthoritiesInvalid
      (mkAwsCheckpointAuthorities eks subzone testStack)
  let checkpoint =
        AwsCheckpointInterpreter
          { awsCheckpointOperationAuthority =
              lifecycleAuthorityOperationClientAuthenticated transport
          , awsCheckpointAuthorities = authorities
          , awsCheckpointRegisteredTargetInterpreter = registered
          }

      -- The recursion is deliberate and is the point of the module.  The
      -- stack reader's checkpoint input comes from the same checkpoint
      -- interpreter the graph's own recovery nodes use, so the pair a stack
      -- decision is taken over and the pair a recovery read back cannot be two
      -- observations of different authorities.
      registered =
        AwsRegisteredTargetInterpreter
          { awsRegisteredTargetProviderBoundary = providerBoundary
          , awsRegisteredTargetReadStackDecisionInputs =
              readBackAwsStackDecisionInputs stackReaderClient
          , awsRegisteredTargetReadStackProviderBinding =
              readBackAwsStackProviderBinding stackReaderClient
          , awsRegisteredTargetPresentEksDestroyBoundary =
              awsEksRegisteredTargetDestroyBoundary destroyInterpreter
          , awsRegisteredTargetDns01ChallengeOwnerDeleteBoundary =
              dns01ChallengeOwnerDeleteBoundary
          }

      destroyInterpreter =
        mkAwsEksRegisteredTargetDestroyInterpreter
          stackReaderClient
          receiptClient
          drainInterpreter
          commitSelectionBoundary
          providerBoundary
          (\_ -> Right <$> drainDeadline)

      stackReader =
        AwsStackReaderInterpreter
          { awsStackReaderClient = stackReaderClient
          , awsStackReaderInputReaders =
              mkAwsStackReaderInputReaders
                (readPostRecoveryCheckpointPair checkpoint)
                (readCompleteOwnershipManifest transport)
                (readProviderCreationBinding transport)
          }

      eksExecutor =
        EksTeardownExecutor
          { eksTeardownRegisteredTargetInterpreter = registered
          , eksTeardownDrainInterpreter = drainInterpreter
          , eksTeardownCommitSelectionBoundary = commitSelectionBoundary
          , eksTeardownAttemptBoundary = attemptBoundary
          , eksTeardownIntentClient =
              lifecycleAuthorityEksDrainIntentAuthenticatedClient transport
          , eksTeardownReceiptClient = receiptClient
          , eksTeardownSelectionParameters = selectionParameters
          }
  Right (mkCloudRuntime registered checkpoint stackReader eksExecutor)
 where
  stackReaderClient :: AwsStackReaderClient IO
  stackReaderClient =
    lifecycleAuthorityAwsStackReaderAuthenticatedClient
      runId
      graphDigest
      transport

  receiptClient =
    lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient transport

  drainInterpreter = mkEksDrainInterpreter currentEpochSeconds

  providerBoundary =
    productionTeardownProviderBoundary
      (productionCloudCaller inputs)
      (productionCloudRepositoryRoot inputs)

  commitSelectionBoundary =
    productionEksDrainCommitSelectionBoundary
      (productionCloudCaller inputs)
      (productionCloudRepositoryRoot inputs)
      (productionCloudKubectlPath inputs)
      (productionCloudKubectlEnvironment inputs)
      (productionCloudKubectlWorkingDirectory inputs)

  dns01ChallengeOwnerDeleteBoundary =
    productionDns01ChallengeOwnerDeleteBoundary
      (productionCloudCaller inputs)
      (productionCloudRepositoryRoot inputs)
      (productionCloudKubectlPath inputs)
      (productionCloudKubectlEnvironment inputs)
      (productionCloudKubectlWorkingDirectory inputs)

  attemptBoundary =
    productionEksDrainAttemptBoundary
      (productionCloudCaller inputs)
      (productionCloudRepositoryRoot inputs)
      (productionCloudKubectlPath inputs)
      (productionCloudKubectlEnvironment inputs)
      (productionCloudKubectlWorkingDirectory inputs)

  checkpointAuthority
    :: Text -> Either ProductionCloudRuntimeError (PulumiCheckpointAuthority IO)
  checkpointAuthority name =
    fmap
      (lifecycleAuthorityPulumiCheckpointAuthenticated transport)
      ( first
          (ProductionCloudCheckpointUnregistered name)
          (registeredPulumiCheckpointByName name)
      )

  drainDeadline :: IO Integer
  drainDeadline = do
    now <- currentEpochSeconds
    pure (now + eksDrainLeaseSecondsValue (productionCloudDrainLease inputs))

  selectionParameters
    :: TeardownExecutionIdentity
    -> IO (Either Text EksDrainSelectionParameters)
  selectionParameters identity = do
    deadline <- drainDeadline
    pure $ do
      kubernetesRevision <- revisionFor identity ProviderDecisionObservation
      inventoryRevision <- revisionFor identity ProviderAbsenceReadBack
      Right
        EksDrainSelectionParameters
          { eksDrainSelectionKubernetesRevision = kubernetesRevision
          , eksDrainSelectionInventoryRevision = inventoryRevision
          , eksDrainSelectionDeadlineEpochSeconds = deadline
          }

-- | The post-recovery checkpoint pair, read again rather than remembered from
-- the recovery node that preceded this commit.
readPostRecoveryCheckpointPair
  :: AwsCheckpointInterpreter IO
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> IO (Either Text CheckpointPairObservation)
readPostRecoveryCheckpointPair checkpoint context target =
  first renderBounded <$> observeAwsStackCheckpointPair checkpoint context target

-- | The complete ownership manifest decision, addressed by the stack and the
-- run's own observation scope.
readCompleteOwnershipManifest
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> IO (Either Text OwnershipManifestDecisionEvidence)
readCompleteOwnershipManifest transport context target =
  first renderBounded
    <$> readBackOwnershipManifestDecisionForScope
      (lifecycleAuthorityOwnershipManifestAuthenticatedClient transport)
      (registeredTargetKey target)
      (teardownExecutionObservationScope context)

-- | The Provider creation binding this stack was created under.
--
-- The revision and the stack configuration come from the durable record; the
-- operation identity comes from the executing node.  Rebuilding the binding
-- through 'mkAwsStackProviderBinding' rather than returning the durable value
-- directly is what re-checks the configuration against the stack the key names.
readProviderCreationBinding
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> CleanupOperationId
  -> IO (Either Text AwsStackProviderBinding)
readProviderCreationBinding transport context target operationId = do
  observed <-
    readBackCommittedAwsStackCreationBindingForScope
      (lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient transport)
      key
      scope
  pure $ do
    committed <- first renderBounded observed
    first
      renderBounded
      ( mkAwsStackProviderBinding
          operationId
          key
          scope
          (committedAwsStackCreationRevision committed)
          (committedAwsStackCreationConfig committed)
      )
 where
  key = registeredTargetKey target
  scope = teardownExecutionObservationScope context

revisionFor
  :: TeardownExecutionIdentity
  -> ProviderDispatchPurpose
  -> Either Text ObservationRevision
revisionFor identity purpose =
  fmap
    observationRevisionForProviderDispatchKey
    ( first
        renderBounded
        ( mkProviderDispatchKey
            (teardownExecutionIdentityOperationId identity)
            purpose
        )
    )

renderBounded :: (Show err) => err -> Text
renderBounded = Text.take 1024 . Text.pack . show

currentEpochSeconds :: IO Integer
currentEpochSeconds = floor <$> getPOSIXTime
