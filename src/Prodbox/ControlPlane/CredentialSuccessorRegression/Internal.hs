{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Fixed, non-authorizing diagnostics for private proof producers. Fake
-- repositories, Transit and Agent observations exist only inside this owner;
-- the public diagnostic returns facts and never a capability or proof.
module Prodbox.ControlPlane.CredentialSuccessorRegression.Internal
  ( CredentialSuccessorRegressionFixtures (..)
  , fixedCredentialSuccessorRegression
  ) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad.Trans.State.Strict (State, get, modify', put, runState)
import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Bifunctor (first)
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityBackupClient
  ( AuthorityAggregateBackupClient (..)
  , AuthorityAggregateBackupClientError (..)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminAuthorityRepositoryResolver
  , AwsAdminProviderCredentialBoundary (..)
  )
import Prodbox.ControlPlane.CleanupProgramDescriptorRepository.Internal
  ( modelBCleanupProgramDescriptorRepository
  )
import Prodbox.ControlPlane.ListenPort (controlPlaneClusterServiceUrlText)
import Prodbox.ControlPlane.ProviderCredentialAdmissionEvidence
import Prodbox.ControlPlane.ProviderCredentialMutationRuntime
  ( ProviderCredentialParentRecoveryBoundary (..)
  , providerCredentialMutationBoundary
  )
import Prodbox.ControlPlane.ProviderCredentialPublication.Internal
import Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (..)
  , TargetMaterialClientError (TargetMaterialClientRemoteRefused)
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint (TargetMaterialObservation (..))
import Prodbox.ControlPlane.TargetMaterialRegistry
import Prodbox.ControlPlane.TargetSecretAgentExecution (mkTargetAgentIdentity)
import Prodbox.ControlPlane.TargetSecretWorker
  ( encodeTargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasResult (..)
  , ModelBObservation (..)
  , mkLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CleanupRun (DescriptorBoundCleanupRunRepository (..))
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
import Prodbox.Lifecycle.Decommission.AuthorityExport (AuthorityManifestSigner (..))
import Prodbox.Lifecycle.Decommission.Manifest (mkManifestPublicKey)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.TargetCommitIntent

-- These are ordinary canonical metadata fixtures, not committed handles.
data CredentialSuccessorRegressionFixtures = CredentialSuccessorRegressionFixtures
  { regressionInstallArchive :: !ProviderCredentialLineageArchive
  , regressionRotateArchive :: !ProviderCredentialLineageArchive
  , regressionRevokeArchive :: !ProviderCredentialLineageArchive
  , regressionForeignArchive :: !ProviderCredentialLineageArchive
  }

data FixtureOperation = FixtureOperation
  { fixtureIntent :: !AwsAdminPermitIntent
  , fixturePermit :: !SignedAwsAdminPermit
  , fixtureReceipt :: !AwsAdminWorkerReceipt
  , fixtureOtherReceipt :: !AwsAdminWorkerReceipt
  , fixtureAuthorized :: !AwsAdminAuthorityState
  , fixtureCompleted :: !AwsAdminAuthorityState
  }

data FixtureFault
  = NormalWrite
  | LoseWriteReply
  | LieAboutWrite
  | RefuseFinalRead
  | StaleFinalRead
  | ChangedFinalReceipt
  deriving (Eq, Show)

data FixtureEvent = RepositoryRead !Int | RepositoryWrite | AgentRead !TargetSecretId
  deriving (Eq, Show)

data FixtureState = FixtureState
  { fixtureStateValue :: !AwsAdminAuthorityState
  , fixtureRevision :: !Int
  , fixtureReads :: !Int
  , fixtureFault :: !FixtureFault
  , fixtureEvents :: ![FixtureEvent]
  }

fixedCredentialSuccessorRegression
  :: CredentialSuccessorRegressionFixtures -> Either Text [(Text, Bool)]
fixedCredentialSuccessorRegression fixtures = do
  installed <- buildOperation InstallOperatorMaterial
  rotated <- buildOperation RotateOperatorMaterial
  revoked <- buildOperation RevokeOperatorMaterial
  base <-
    publicationCases installed (regressionInstallArchive fixtures) (regressionForeignArchive fixtures)
  agents <-
    concat
      <$> sequence
        [ admissionCases InstallOperatorMaterial installed (regressionInstallArchive fixtures)
        , admissionCases RotateOperatorMaterial rotated (regressionRotateArchive fixtures)
        , admissionCases RevokeOperatorMaterial revoked (regressionRevokeArchive fixtures)
        ]
  runtime <-
    concat
      <$> sequence
        [ runtimeCases installed (regressionInstallArchive fixtures)
        , runtimeCases rotated (regressionRotateArchive fixtures)
        , runtimeCases revoked (regressionRevokeArchive fixtures)
        ]
  children <- cleanupRuntimeCases
  Right (base ++ agents ++ runtime ++ children)

publicationCases
  :: FixtureOperation
  -> ProviderCredentialLineageArchive
  -> ProviderCredentialLineageArchive
  -> Either Text [(Text, Bool)]
publicationCases operation archive foreignArchive = do
  archived <- firstShow (commitAwsAdminProviderLineage archive completed)
  let legacy =
        LBS.toStrict
          ( serialise
              ( LegacyWire
                  1
                  4
                  Nothing
                  Nothing
                  (Just (encodeSignedAwsAdminPermit permit))
                  (Just (encodeAwsAdminWorkerReceipt receipt))
              )
          )
      unknown =
        LBS.toStrict
          ( serialise
              ( LegacyWire
                  9
                  4
                  Nothing
                  Nothing
                  (Just (encodeSignedAwsAdminPermit permit))
                  (Just (encodeAwsAdminWorkerReceipt receipt))
              )
          )
      base =
        [ ("unarchived v1 bytes unchanged", encodeAwsAdminAuthorityState completed == legacy)
        , ("unarchived v1 decodes", decodeAwsAdminAuthorityState legacy == Right completed)
        ,
          ( "archived state uses v2"
          , BS.take 3 (encodeAwsAdminAuthorityState archived) == BS.pack [0x88, 0, 2]
          )
        ,
          ( "archived state canonical round-trip"
          , decodeAwsAdminAuthorityState (encodeAwsAdminAuthorityState archived) == Right archived
          )
        ,
          ( "archive cannot precede completed receipt"
          , isLeft (commitAwsAdminProviderLineage archive (fixtureAuthorized operation))
          )
        , ("archive exact replay", commitAwsAdminProviderLineage archive archived == Right archived)
        ,
          ( "foreign operation archive refuses"
          , isLeft (commitAwsAdminProviderLineage foreignArchive completed)
          )
        , ("archive cannot be replaced", isLeft (commitAwsAdminProviderLineage foreignArchive archived))
        ,
          ( "unknown outbox version remains explicit"
          , decodeAwsAdminAuthorityState unknown == Left (AwsAdminAuthorityStateUnsupportedVersion 9)
          )
        ]
  Right
    ( base
        ++ concatMap
          faultCase
          [NormalWrite, LoseWriteReply, LieAboutWrite, RefuseFinalRead, StaleFinalRead, ChangedFinalReceipt]
    )
 where
  completed = fixtureCompleted operation
  permit = fixturePermit operation
  receipt = fixtureReceipt operation
  repository = fixtureRepository operation
  faultCase fault =
    let (answer, world) = runState (publishAwsAdminProviderLineage repository archive) (initialWorld operation fault)
        accepted = either (const False) ((== archive) . observedAwsAdminProviderLineageArchive) answer
        expected = case fault of NormalWrite -> accepted; LoseWriteReply -> accepted; _ -> isLeft answer
        retryCases = case fault of
          RefuseFinalRead -> retry world
          StaleFinalRead -> retry world
          ChangedFinalReceipt -> retry world
          _ -> []
     in (Text.pack (show fault) <> " independently settled", expected) : retryCases
  retry world =
    let (answer, after) = runState (publishAwsAdminProviderLineage repository archive) (world {fixtureFault = NormalWrite})
     in [
          ( "retry preserves durable archive without another write"
          , either (const False) ((== archive) . observedAwsAdminProviderLineageArchive) answer
              && fixtureStateValue after == fixtureStateValue world
              && fixtureRevision after == fixtureRevision world
          )
        ]

admissionCases
  :: OperatorMaterialAction
  -> FixtureOperation
  -> ProviderCredentialLineageArchive
  -> Either Text [(Text, Bool)]
admissionCases action operation archive = do
  (accepted, world) <- produce (Right exact)
  evidence <- firstShow accepted
  aggregate <- aggregateCases action (fixtureIntent operation) evidence
  (unavailable, _) <- produce (Left (TargetMaterialClientRemoteRefused "fixture-unavailable"))
  (opposite, _) <-
    produce (Right (case action of RevokeOperatorMaterial -> Just metadata; _ -> Nothing))
  mismatches <- case action of
    RevokeOperatorMaterial -> Right []
    _ ->
      traverse
        mismatchCase
        [ ("generation", metadata {targetMaterialObservedGeneration = 2})
        , ("Vault version", metadata {targetMaterialObservedVaultVersion = 2})
        ,
          ( "commitment"
          , metadata {targetMaterialObservedCommitment = "vault:v1:different-fixture-commitment"}
          )
        , ("request digest", metadata {targetMaterialObservedRequestDigest = Text.replicate 64 "c"})
        , ("action digest", metadata {targetMaterialObservedActionDigest = Text.replicate 64 "c"})
        , ("Pod UID", metadata {targetMaterialObservedPodUid = "different-fixture-pod"})
        , ("image", metadata {targetMaterialObservedImageDigest = "sha256:" <> Text.replicate 64 "d"})
        , ("invalid metadata", metadata {targetMaterialObservedVaultVersion = 0})
        ]
  let correctKind = case (action, observedProviderCredentialAdmissionKind evidence) of
        (InstallOperatorMaterial, ProviderCredentialAdmissionInstalled) -> True
        (RotateOperatorMaterial, ProviderCredentialAdmissionInstalled) -> True
        (RevokeOperatorMaterial, ProviderCredentialAdmissionRevoked _) -> True
        _ -> False
      exactOrder =
        fixtureEvents world
          == [RepositoryRead 1, RepositoryWrite, RepositoryRead 2, RepositoryRead 3, AgentRead target]
  Right
    ( [ (label "publication precedes exactly one independent Agent read", correctKind && exactOrder)
      , (label "unavailable Agent refuses", isLeft unavailable)
      , (label "missing/present contradiction refuses", isLeft opposite)
      ]
        ++ mismatches
        ++ aggregate
    )
 where
  intent = fixtureIntent operation
  target = TargetAwsCredential AwsLifecycleProvider
  metadata =
    TargetMaterialObservation
      1
      1
      "vault:v1:fixture-worker-commitment"
      "owner-nonce-1"
      1
      (targetValueDigestText (awsAdminPermitIntentRequestDigest intent))
      (Text.replicate 64 "b")
      "credential-provisioner-pod-1"
      imageDigest
  exact = case action of RevokeOperatorMaterial -> Nothing; _ -> Just metadata
  label suffix = Text.pack (show action) <> " " <> suffix
  produce observation =
    let actor = do
          publication <- publishAwsAdminProviderLineage (fixtureRepository operation) archive
          case publication of
            Left cause -> pure (Left (Text.pack (show cause)))
            Right published -> Right <$> observeProviderCredentialAdmission (fixtureAgent observation) published
        (answer, world) = runState actor (initialWorld operation NormalWrite)
     in (,world) <$> answer
  mismatchCase (name, changed) = do
    (answer, _) <- produce (Right (Just changed))
    Right (label ("mismatched " <> name <> " refuses"), isLeft answer)

aggregateCases
  :: OperatorMaterialAction
  -> AwsAdminPermitIntent
  -> ObservedProviderCredentialAdmission
  -> Either Text [(Text, Bool)]
aggregateCases action intent evidence = do
  initial <- firstShow (initialCleanInstallAuthority 1 1)
  reservation <- firstShow (providerCredentialMutationReservationForIntent intent)
  let commands =
        [ BeginGenesisEstablishment (GenesisPlan "fixture-genesis-plan" "fixture-backup-coordinate")
        , ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "fixture-target-generation")
        , ObserveBackupReceipt (BackupReceipt "fixture-backup-readback")
        ]
      step aggregate command = snd (stepAuthorityAdmission aggregate (ApplyAuthorityGenesis command))
      open = foldl step initial commands
  (pending, archived) <- firstShow (reserveAuthorityProviderCredentialMutation open reservation)
  completed <- firstShow (completeAuthorityProviderCredentialMutation pending evidence)
  let (_, afterBind) = stepAuthorityAdmission pending (BindProviderAdmissionGeneration 2)
      expected = case action of
        InstallOperatorMaterial -> ProviderAdmissionServing 1
        RotateOperatorMaterial -> ProviderAdmissionServing 1
        RevokeOperatorMaterial -> ProviderAdmissionOrdinaryCredentialRetired 1
      labelled (name, passed) = (Text.pack (show action) <> " " <> name, passed)
  Right
    ( map
        labelled
        [
          ( "genesis refuses reservation"
          , isLeft (reserveAuthorityProviderCredentialMutation initial reservation)
          )
        ,
          ( "genesis refuses completion"
          , isLeft (completeAuthorityProviderCredentialMutation initial evidence)
          )
        ,
          ( "unreserved completion refuses"
          , isLeft (completeAuthorityProviderCredentialMutation open evidence)
          )
        ,
          ( "reserved archive matches actual publication"
          , archived == observedProviderCredentialAdmissionArchive evidence
          )
        , ("pending archive is readable", authorityAggregatePendingCredentialArchive pending == Just archived)
        , ("pending aggregate round-trip", deserialiseOrFail (serialise pending) == Right pending)
        ,
          ( "reservation exact replay"
          , reserveAuthorityProviderCredentialMutation pending reservation == Right (pending, archived)
          )
        , ("pending reservation blocks blind generation bind", afterBind == pending)
        ,
          ( "completion clears pending archive"
          , authorityAggregatePendingCredentialArchive completed == Nothing
          )
        ,
          ( "completion exact replay"
          , completeAuthorityProviderCredentialMutation completed evidence == Right completed
          )
        , ("completed aggregate round-trip", deserialiseOrFail (serialise completed) == Right completed)
        ,
          ( "completion selects exact serving/retired phase"
          , authorityAggregateProviderAdmissionEpochView completed == expected
          )
        ]
    )

initialWorld :: FixtureOperation -> FixtureFault -> FixtureState
initialWorld operation fault = FixtureState (fixtureCompleted operation) 0 0 fault []

fixtureRepository :: FixtureOperation -> AwsAdminAuthorityRepository (State FixtureState) Int
fixtureRepository operation = AwsAdminAuthorityRepository observe commit
 where
  observe = do
    world <- get
    let count = fixtureReads world + 1
        state = fixtureStateValue world
        observed = case (count, fixtureFault world, state) of
          (3, StaleFinalRead, _) -> fixtureCompleted operation
          (3, ChangedFinalReceipt, AwsAdminAuthorityCompletedWithLineage permit _ archive) ->
            AwsAdminAuthorityCompletedWithLineage permit (fixtureOtherReceipt operation) archive
          _ -> state
    put world {fixtureReads = count, fixtureEvents = fixtureEvents world ++ [RepositoryRead count]}
    pure $ case (count, fixtureFault world) of
      (3, RefuseFinalRead) -> Left "fixture final read unavailable"
      _ -> Right (AwsAdminAuthoritySnapshot (fixtureRevision world) observed)
  commit revision next = do
    world <- get
    if revision /= fixtureRevision world
      then pure (Left "fixture CAS conflict")
      else case fixtureFault world of
        LieAboutWrite -> pure (Right ())
        fault -> do
          put
            world
              { fixtureStateValue = next
              , fixtureRevision = revision + 1
              , fixtureEvents = fixtureEvents world ++ [RepositoryWrite]
              }
          pure (if fault == LoseWriteReply then Left "fixture write reply lost" else Right ())

fixtureAgent
  :: Either TargetMaterialClientError (Maybe TargetMaterialObservation)
  -> TargetMaterialClient (State FixtureState)
fixtureAgent observation = TargetMaterialClient $ \target -> do
  modify' (\world -> world {fixtureEvents = fixtureEvents world ++ [AgentRead target]})
  pure observation

buildOperation :: OperatorMaterialAction -> Either Text FixtureOperation
buildOperation action = buildNamedOperation action "lineage/publication" 1

buildNamedOperation :: OperatorMaterialAction -> Text -> Natural -> Either Text FixtureOperation
buildNamedOperation action operationText generationValue = do
  generation <- firstShow (mkCredentialGeneration generationValue)
  operation <- firstShow (mkOperatorMaterialOperationId operationText)
  permitId <- firstShow (mkOperatorMaterialPermitId operationText)
  request <-
    firstShow (mkAwsOperatorMaterialRequest LifecycleProviderCredential action operation generation)
  let deadline = authorityTimeFromMicros 60000000
  operatorPermit <-
    firstShow (mkOperatorMaterialPermit permitId request deadline Nothing "fixture-operator-signature")
  agent <- firstShow (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "a"))
  actionDigest <- firstShow (mkTargetValueDigest (Text.replicate 64 "b"))
  prepared <-
    firstShow
      ( mkPreparedCredentialTargetObservation
          "owner-nonce-1"
          1
          agent
          (TargetAwsCredential AwsLifecycleProvider)
          generation
          (operatorMaterialRequestDigest request)
          actionDigest
          Nothing
          deadline
      )
  iam <-
    firstShow
      (mkLifecycleProviderIamParameters canonicalRegressionAwsRegion "123456789012" "prodbox-provider-role")
  intent <-
    firstShow
      ( mkNormalAwsAdminPermitIntent
          operatorPermit
          iam
          imageDigest
          "home"
          (controlPlaneClusterServiceUrlText "lifecycle-authority" "lifecycle-authority")
          prepared
      )
  binding <-
    firstShow
      ( mkAwsAdminJobBinding
          intent
          (awsAdminJobNameForPermit permitId)
          "job-uid-1"
          "credential-provisioner-pod-1"
          "pod-uid-1"
          imageDigest
          awsAdminWorkerServiceAccount
          "service-account-uid-1"
          (authorityTimeFromMicros 1000000)
      )
  ready <-
    firstShow (commitAwsAdminPrepared intent AwsAdminAuthorityVacant >>= commitAwsAdminAttested binding)
  signer <- fixtureSigner
  (authorized, permit) <-
    firstShow
      (runIdentity (authorizeAwsAdminAttestation signer (authorityTimeFromMicros 3000000) ready))
  receipt <- fixtureWorkerReceipt action intent "vault:v1:fixture-worker-commitment"
  changed <- fixtureWorkerReceipt action intent "vault:v1:different-fixture-worker-commitment"
  completed <- firstShow (commitAwsAdminCompleted receipt authorized)
  Right (FixtureOperation intent permit receipt changed authorized completed)

fixtureSigner :: Either Text (AuthorityManifestSigner Identity)
fixtureSigner = do
  secret <- case Ed25519.secretKey (BS.pack [0 .. 31]) of
    CryptoPassed key -> Right key
    CryptoFailed cause -> Left (Text.pack (show cause))
  let public = Ed25519.toPublic secret
  key <- firstShow (mkManifestPublicKey (ByteArray.convert public))
  Right
    ( AuthorityManifestSigner
        (pure (Right (7, key)))
        (\payload -> pure (Right (7, ByteArray.convert (Ed25519.sign secret public payload))))
    )

fixtureWorkerReceipt
  :: OperatorMaterialAction -> AwsAdminPermitIntent -> Text -> Either Text AwsAdminWorkerReceipt
fixtureWorkerReceipt action intent commitment = do
  digest <- firstShow (mkTargetValueDigest (Text.replicate 64 "b"))
  targetReceipt <-
    firstShow
      ( mkTargetWorkerReceiptProjection
          (awsAdminPermitIntentTarget intent)
          (awsAdminPermitIntentGeneration intent)
          1
          commitment
          (awsAdminPermitIntentRequestDigest intent)
          digest
          "credential-provisioner-pod-1"
          imageDigest
      )
  let (kind, readback) = case action of
        RevokeOperatorMaterial -> (2, "metadata-only revoked Target observation")
        _ -> (1, encodeTargetWorkerReceipt targetReceipt)
  firstShow
    ( decodeAwsAdminWorkerReceipt
        ( LBS.toStrict
            ( serialise
                ( ReceiptWire
                    1
                    kind
                    (operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent))
                    (targetValueDigestText (awsAdminPermitIntentRequestDigest intent))
                    (awsAdminPermitIntentTarget intent)
                    (credentialGenerationValue (awsAdminPermitIntentGeneration intent))
                    readback
                )
            )
        )
    )

imageDigest :: Text
imageDigest = "sha256:" <> Text.replicate 64 "c"

data ReceiptWire = ReceiptWire !Word16 !Word8 !Text !Text !TargetSecretId !Natural !BS.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)
data LegacyWire
  = LegacyWire
      !Word16
      !Word8
      !(Maybe BS.ByteString)
      !(Maybe BS.ByteString)
      !(Maybe BS.ByteString)
      !(Maybe BS.ByteString)
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

data RuntimeFault
  = RuntimeNormal
  | RuntimeLostWriteReply
  | RuntimeLyingWrite
  | RuntimeUnavailableReadback
  | RuntimeUnavailableAgent
  | RuntimeLegacyWorkloadPresent
  | RuntimeLegacyWorkloadUnobservable
  deriving (Eq, Show)

data RuntimeWorld = RuntimeWorld
  { runtimeAggregate :: !AuthorityAdmissionAggregate
  , runtimeAggregateRevision :: !Int
  , runtimeAggregateReads :: !Int
  , runtimeAggregateWrites :: !Int
  , runtimeOutbox :: !AwsAdminAuthorityState
  , runtimeOutboxRevision :: !Int
  , runtimeOutboxWrites :: !Int
  , runtimeAgentReads :: !Int
  , runtimeParentReads :: !Int
  , runtimeFault :: !RuntimeFault
  }

runtimeCases :: FixtureOperation -> ProviderCredentialLineageArchive -> Either Text [(Text, Bool)]
runtimeCases operation archive = do
  open <- runtimeOpenAggregate
  boundary <-
    runtimeFixtureBoundary
      (const (Right runtimeOutboxRepository))
      runtimeAgent
      ( ProviderCredentialParentRecoveryBoundary
          (pure (Right (authorityTimeFromMicros 120000000)))
          (\_ -> pure (Right Nothing))
          (\_ _ -> pure (Right ()))
          ( do
              world <- get
              pure $ case runtimeFault world of
                RuntimeLegacyWorkloadPresent -> Left "legacy workload present"
                RuntimeLegacyWorkloadUnobservable -> Left "legacy workload unobservable"
                _ -> Right ()
          )
      )
  let intent = fixtureIntent operation
      permit = fixturePermit operation
      initialRuntime fault = RuntimeWorld open 0 0 0 (fixtureAuthorized operation) 0 0 0 0 fault
      actor = do
        reserved <- reserveAwsAdminProviderCredential boundary intent
        case reserved of
          Left cause -> pure (Left cause)
          Right () -> continue
      continue = do
        world <- get
        case runtimeOutbox world of
          AwsAdminAuthorityCompleted {} -> settle
          AwsAdminAuthorityCompletedWithLineage {} -> settle
          _ -> execute
      execute = do
        admitted <- admitAwsAdminProviderPermit boundary permit
        case admitted of
          Left cause -> pure (Left cause)
          Right () -> do
            modify' (\world -> world {runtimeOutbox = fixtureCompleted operation})
            settle
      settle = do
        settled <- settleAwsAdminProviderCredential boundary intent
        case settled of
          Left cause -> pure (Left cause)
          Right () -> settleAwsAdminProviderCredential boundary intent
      successful fault =
        let (answer, world) = runState actor (initialRuntime fault)
         in ( Text.pack (show fault) <> " runtime settlement uses independent aggregate reads"
            , answer == Right ()
                && runtimeAggregateWrites world == 2
                && runtimeOutboxWrites world == 1
                && runtimeAgentReads world == 2
                && authorityAggregatePendingCredentialArchive (runtimeAggregate world) == Nothing
            )
      refusal fault =
        let (answer, world) = runState actor (initialRuntime fault)
            shouldPending = fault /= RuntimeLyingWrite
            pending = authorityAggregatePendingCredentialArchive (runtimeAggregate world)
            (retry, repaired) = runState actor (world {runtimeFault = RuntimeNormal})
         in [
              ( Text.pack (show fault) <> " runtime refuses unresolved evidence"
              , isLeft answer && (if shouldPending then pending == Just archive else pending == Nothing)
              )
            ,
              ( Text.pack (show fault) <> " retry settles the original reservation"
              , retry == Right ()
                  && authorityAggregatePendingCredentialArchive (runtimeAggregate repaired) == Nothing
              )
            ]
      servingConfirmation fault =
        let (_, completed) = runState actor (initialRuntime RuntimeNormal)
            (answer, final) = runState (confirmAwsAdminProviderCredentialServing boundary) (completed {runtimeFault = fault})
            expected = awsAdminPermitIntentAction intent /= RevokeOperatorMaterial && fault == RuntimeNormal
         in ( "first-reconcile serving confirmation " <> Text.pack (show fault)
            , (answer == Right ()) == expected
                && runtimeAggregateWrites final == runtimeAggregateWrites completed
                && runtimeOutboxWrites final == runtimeOutboxWrites completed
            )
  pure
    ( [successful RuntimeNormal, successful RuntimeLostWriteReply]
        ++ map servingConfirmation [RuntimeNormal, RuntimeUnavailableAgent]
        ++ concatMap refusal [RuntimeLyingWrite, RuntimeUnavailableReadback, RuntimeUnavailableAgent]
        ++ [ ( Text.pack (show fault) <> " refuses before reserving an untracked epoch"
             , let
                 (answer, stopped) = runState actor (initialRuntime fault)
                 (retry, resumed) = runState actor (stopped {runtimeFault = RuntimeNormal})
                in
                 isLeft answer
                   && runtimeAggregate stopped == open
                   && runtimeAggregateWrites stopped == 0
                   && runtimeOutboxWrites stopped == 0
                   && runtimeAgentReads stopped == 0
                   && retry == Right ()
                   && not (authorityAggregateNeedsProviderCredentialQuiescence (runtimeAggregate resumed))
             )
           | fault <- [RuntimeLegacyWorkloadPresent, RuntimeLegacyWorkloadUnobservable]
           ]
        ++ [
             ( "capacity preflight accepts exact bound operation"
             , validateAwsAdminProviderLineageCapacity archive permit == Right ()
             )
           ]
    )
 where
  runtimeAgent = TargetMaterialClient $ \_ -> do
    world <- get
    put world {runtimeAgentReads = runtimeAgentReads world + 1}
    pure $
      if runtimeFault world == RuntimeUnavailableAgent
        then Left (TargetMaterialClientRemoteRefused "fixture Agent unavailable")
        else Right $ case awsAdminPermitIntentAction (fixtureIntent operation) of
          RevokeOperatorMaterial -> Nothing
          _ ->
            Just
              ( TargetMaterialObservation
                  1
                  1
                  "vault:v1:fixture-worker-commitment"
                  "owner-nonce-1"
                  1
                  (targetValueDigestText (awsAdminPermitIntentRequestDigest (fixtureIntent operation)))
                  (Text.replicate 64 "b")
                  "credential-provisioner-pod-1"
                  imageDigest
              )

data CleanupRuntimeFault
  = CleanupNormal
  | CleanupLostWriteReply
  | CleanupCompletedJournal
  | CleanupJournalUnavailable
  | CleanupWorkloadPresent
  | CleanupWorkloadUnobservable
  | CleanupTimeUnavailable
  | CleanupAgentUnavailable
  | CleanupTargetAboveParent
  | CleanupTargetGenerationMismatch
  | CleanupParentChanged
  | CleanupParentCompleted
  | CleanupForeignParent
  | CleanupForeignOperation
  | CleanupInstallDraft
  | CleanupParentCompletedWithLineage
  | CleanupCompletedReceiptMismatch
  | CleanupCompletedTargetCurrent
  | CleanupTargetCommitted
  deriving (Eq, Show)

cleanupRuntimeCases :: Either Text [(Text, Bool)]
cleanupRuntimeCases =
  concat
    <$> sequence
      [ scenario action target fault
      | action <- [InstallOperatorMaterial, RotateOperatorMaterial]
      , target <- [False, True]
      , fault <-
          [ CleanupNormal
          , CleanupLostWriteReply
          , CleanupCompletedJournal
          , CleanupJournalUnavailable
          , CleanupWorkloadPresent
          , CleanupWorkloadUnobservable
          , CleanupTimeUnavailable
          , CleanupAgentUnavailable
          , CleanupTargetAboveParent
          , CleanupTargetGenerationMismatch
          , CleanupParentChanged
          , CleanupParentCompleted
          , CleanupForeignParent
          , CleanupForeignOperation
          , CleanupInstallDraft
          , CleanupParentCompletedWithLineage
          , CleanupCompletedReceiptMismatch
          , CleanupCompletedTargetCurrent
          , CleanupTargetCommitted
          ]
      ]
 where
  scenario action targetPresent fault = do
    open <- runtimeOpenAggregate
    parent <- buildNamedOperation action "cleanup/runtime-parent" 2
    parentReservation <-
      firstShow (providerCredentialMutationReservationForIntent (fixtureIntent parent))
    (pending, parentArchive) <-
      firstShow (reserveAuthorityProviderCredentialMutation open parentReservation)
    archivedParent <- firstShow (commitAwsAdminProviderLineage parentArchive (fixtureCompleted parent))
    operation <- providerCredentialCleanupOperationId parentReservation
    foreignParent <- buildNamedOperation action "cleanup/foreign-parent" 2
    let expectedGeneration = if targetPresent then 1 else 2
        childGeneration
          | fault `elem` [CleanupCompletedTargetCurrent, CleanupTargetCommitted] = 2
          | fault == CleanupTargetGenerationMismatch = 3 - expectedGeneration
          | otherwise = expectedGeneration
        childOperation =
          if fault == CleanupForeignOperation
            then "cleanup/foreign-child"
            else operatorMaterialOperationIdText operation
        childAction = if fault == CleanupInstallDraft then InstallOperatorMaterial else RevokeOperatorMaterial
    child <- buildNamedOperation childAction childOperation childGeneration
    let parentRepository =
          AwsAdminAuthorityRepository
            ( do
                world <- get
                let count = runtimeParentReads world + 1
                    observedParent
                      | fault == CleanupParentChanged && count > 1 = AwsAdminAuthorityVacant
                      | fault
                          `elem` [CleanupParentCompleted, CleanupCompletedReceiptMismatch, CleanupCompletedTargetCurrent] =
                          fixtureCompleted parent
                      | fault == CleanupParentCompletedWithLineage = archivedParent
                      | fault == CleanupForeignParent = fixtureAuthorized foreignParent
                      | otherwise = fixtureAuthorized parent
                put world {runtimeParentReads = count}
                pure (Right (AwsAdminAuthoritySnapshot 0 observedParent))
            )
            (\_ _ -> pure (Left "cleanup must never rewrite parent outbox"))
        resolver name
          | name == "cleanup/runtime-parent" = Right parentRepository
          | name == childOperation = Right runtimeOutboxRepository
          | otherwise = Left "cleanup fixture unknown operation"
        recovery =
          ProviderCredentialParentRecoveryBoundary
            ( pure
                ( if fault == CleanupTimeUnavailable
                    then Left "time unobservable"
                    else Right (authorityTimeFromMicros 120000000)
                )
            )
            ( \_ -> pure $ case fault of
                CleanupCompletedJournal -> Right (Just (fixtureReceipt parent))
                CleanupCompletedReceiptMismatch -> Right (Just (fixtureOtherReceipt parent))
                CleanupJournalUnavailable -> Left "completed journal unobservable"
                _ -> Right Nothing
            )
            ( \now permit -> pure $ case fault of
                CleanupWorkloadPresent -> Left "expired parent workload remains"
                CleanupWorkloadUnobservable -> Left "expired parent workload unobservable"
                _ ->
                  firstShow
                    ( validateAwsAdminExpiredAttemptAbsence
                        now
                        permit
                        AwsAdminAttemptResourceAbsent
                        AwsAdminAttemptResourceAbsent
                    )
            )
            (pure (Right ()))
        agent = TargetMaterialClient $ \_ -> do
          world <- get
          put world {runtimeAgentReads = runtimeAgentReads world + 1}
          pure $
            if fault == CleanupAgentUnavailable
              then Left (TargetMaterialClientRemoteRefused "Agent unobservable")
              else Right $ case runtimeOutbox world of
                AwsAdminAuthorityCompleted {} -> Nothing
                AwsAdminAuthorityCompletedWithLineage {} -> Nothing
                _
                  | fault `elem` [CleanupCompletedTargetCurrent, CleanupTargetCommitted] ->
                      Just
                        ( TargetMaterialObservation
                            2
                            1
                            "vault:v1:fixture-worker-commitment"
                            "owner-nonce-1"
                            1
                            (targetValueDigestText (awsAdminPermitIntentRequestDigest (fixtureIntent parent)))
                            (Text.replicate 64 "b")
                            "credential-provisioner-pod-1"
                            imageDigest
                        )
                  | targetPresent || fault == CleanupTargetAboveParent ->
                      Just
                        ( TargetMaterialObservation
                            (if fault == CleanupTargetAboveParent then 3 else 1)
                            1
                            "vault:v1:old-parent-target"
                            "old-parent-owner"
                            1
                            (Text.replicate 64 "a")
                            (Text.replicate 64 "b")
                            "old-parent-pod"
                            imageDigest
                        )
                  | otherwise -> Nothing
        state =
          RuntimeWorld
            pending
            0
            0
            0
            (fixtureAuthorized child)
            0
            0
            0
            0
            (if fault == CleanupLostWriteReply then RuntimeLostWriteReply else RuntimeNormal)
    boundary <- runtimeFixtureBoundary resolver agent recovery
    let actor = do
          reserved <- reserveAwsAdminProviderCredential boundary (fixtureIntent child)
          case reserved of
            Left cause -> pure (Left cause)
            Right () -> do
              replay <- reserveAwsAdminProviderCredential boundary (fixtureIntent child)
              admitted <- admitAwsAdminProviderPermit boundary (fixturePermit child)
              case (replay, admitted) of
                (Right (), Right ()) -> do
                  modify' (\world -> world {runtimeOutbox = fixtureCompleted child})
                  settled <- settleAwsAdminProviderCredential boundary (fixtureIntent child)
                  case settled of
                    Left cause -> pure (Left cause)
                    Right () -> settleAwsAdminProviderCredential boundary (fixtureIntent child)
                (Left cause, _) -> pure (Left cause)
                (_, Left cause) -> pure (Left cause)
        (answer, final) = runState actor state
        succeeds =
          fault
            `elem` [ CleanupNormal
                   , CleanupLostWriteReply
                   , CleanupCompletedJournal
                   , CleanupParentCompleted
                   , CleanupParentCompletedWithLineage
                   , CleanupTargetCommitted
                   ]
        label = Text.pack (show action <> " targetPresent=" <> show targetPresent <> " " <> show fault)
    Right
      [
        ( label <> " admission and retirement"
        , if succeeds
            then
              answer == Right ()
                && authorityAggregatePendingCredentialArchive (runtimeAggregate final) == Nothing
                && runtimeAggregateWrites final == 2
                && runtimeOutboxWrites final == 1
                && runtimeParentReads final == 2
            else
              isLeft answer
                && runtimeAggregate final == pending
                && runtimeAggregateWrites final == 0
                && runtimeOutboxWrites final == 0
        )
      ]

runtimeOpenAggregate :: Either Text AuthorityAdmissionAggregate
runtimeOpenAggregate = do
  initial <- firstShow (initialCleanInstallAuthority 1 1)
  let step aggregate command = snd (stepAuthorityAdmission aggregate (ApplyAuthorityGenesis command))
  pure
    ( foldl
        step
        initial
        [ BeginGenesisEstablishment (GenesisPlan "fixture-runtime-plan" "fixture-runtime-backup")
        , ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "fixture-runtime-target")
        , ObserveBackupReceipt (BackupReceipt "fixture-runtime-backup")
        ]
    )

runtimeFixtureBoundary
  :: AwsAdminAuthorityRepositoryResolver (State RuntimeWorld) Int
  -> TargetMaterialClient (State RuntimeWorld)
  -> ProviderCredentialParentRecoveryBoundary (State RuntimeWorld)
  -> Either Text (AwsAdminProviderCredentialBoundary (State RuntimeWorld))
runtimeFixtureBoundary resolver agent recovery = do
  authority <-
    firstShow
      ( mkLongLivedCheckpointAuthority
          "fixture-cluster"
          "fixture-bucket"
          "fixture-namespace"
          "fixture-vault"
      )
  let descriptors =
        modelBCleanupProgramDescriptorRepository
          authority
          ( ModelBCasAdapter
              (\_ -> pure (ModelBUnobservable "fixture must not read predecessor"))
              (\_ -> pure (ModelBCasUnobservable "fixture must not mutate descriptor"))
          )
      backup =
        AuthorityAggregateBackupClient
          (\_ -> pure (Left (AuthorityAggregateBackupCiphertextInvalid "fixture must not copy history")))
          (\_ -> pure (Left (AuthorityAggregateBackupCiphertextInvalid "fixture must not read history")))
      runs _ =
        DescriptorBoundCleanupRunRepository
          (pure (Left "fixture must not read predecessor"))
          (\(_ :: Maybe Int) _ _ -> pure (Left "fixture must not mutate predecessor"))
          (\_ _ _ -> pure (Left "fixture must not compact predecessor"))
  pure
    ( providerCredentialMutationBoundary
        runtimeAdmissionRepository
        resolver
        descriptors
        runs
        backup
        agent
        recovery
    )

runtimeAdmissionRepository :: AuthorityAdmissionRepository (State RuntimeWorld) Int
runtimeAdmissionRepository = AuthorityAdmissionRepository observe commit
 where
  observe = do
    world <- get
    let count = runtimeAggregateReads world + 1
    put world {runtimeAggregateReads = count}
    pure $
      if runtimeFault world == RuntimeUnavailableReadback && count == 3
        then Left "fixture aggregate closing read unavailable"
        else Right (AuthorityAdmissionSnapshot (runtimeAggregateRevision world) (runtimeAggregate world))
  commit revision aggregate = do
    world <- get
    if revision /= runtimeAggregateRevision world
      then pure (Left "fixture aggregate conflict")
      else case runtimeFault world of
        RuntimeLyingWrite -> pure (Right ())
        fault -> do
          put
            world
              { runtimeAggregate = aggregate
              , runtimeAggregateRevision = revision + 1
              , runtimeAggregateWrites = runtimeAggregateWrites world + 1
              }
          pure
            (if fault == RuntimeLostWriteReply then Left "fixture aggregate write reply lost" else Right ())

runtimeOutboxRepository :: AwsAdminAuthorityRepository (State RuntimeWorld) Int
runtimeOutboxRepository = AwsAdminAuthorityRepository observe commit
 where
  observe = do
    world <- get
    pure (Right (AwsAdminAuthoritySnapshot (runtimeOutboxRevision world) (runtimeOutbox world)))
  commit revision outbox = do
    world <- get
    if revision /= runtimeOutboxRevision world
      then pure (Left "fixture outbox conflict")
      else do
        put
          world
            { runtimeOutbox = outbox
            , runtimeOutboxRevision = revision + 1
            , runtimeOutboxWrites = runtimeOutboxWrites world + 1
            }
        pure (Right ())
