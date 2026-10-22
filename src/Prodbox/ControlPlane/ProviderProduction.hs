{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Production binding for the closed Provider Worker vocabulary.  The only
-- credential read is the Provider assuming user's exact Vault KV object. It is
-- exchanged for the intent-selected registered role inside the rank-2 session
-- callback. Pulumi execution selects from three compiled
-- non-SES programs rooted at @/opt/build/pulumi@ and accepts only their typed
-- configuration constructors.
module Prodbox.ControlPlane.ProviderProduction
  ( ProviderProductionSession
  , providerDnsOwnerAuthority
  , publicARecordProgramOutcome
  , sesDnsOwnerAuthority
  , sesDnsProgramOutcome
  , providerProductionNarrowSession
  , providerProductionCapabilities
  , providerProductionReady
  , providerAwsCliLimits
  , deleteSecurityGroupsWithin
  , stackHasVpc
  , destroyPassBounds
  , pulumiChildLimitsFor
  , eksLoadBalancerControllerFamilyTags
  , validateEksLoadBalancerControllerFamilyProjection
  , DesiredState (..)
  , observePulumiStackVia
  , previewPulumiStackVia
  , pulumiDestroySelected
  , stackEvidence
  , withProviderChildProcessPermit
  , validationZoneNames
  , validDnsName
  , parseRetainedEbsEnsure
  , retainedEbsEnsureObservation
  , retainedEbsBindingsEvidence
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Monad qualified
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( Value (Array, Bool, Object, String)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Vector qualified as Vector
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws.CredentialHandle
  ( SessionCredentialHandle
  , baseCredentialHandleFromSettings
  )
import Prodbox.Aws.Native.Route53 qualified as NativeRoute53
import Prodbox.Aws.Native.Sts qualified as NativeSts
import Prodbox.Aws.Native.Wire (AwsClientError, httpSend)
import Prodbox.Aws.Region (awsGlobalServiceRegion)
import Prodbox.Aws.StsIdentity (renderStsIdentityEvidence)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.EksClientAuthProjection
  ( eksClientAuthEvidenceMarker
  , encodeEksClientAuthEnvelope
  , validateEksClusterArnBinding
  )
import Prodbox.ControlPlane.EksClientAuthProjection.Internal
  ( mkEksClientAuthProjection
  , mkEksClientAuthPublicKey
  , sealEksClientAuthProjection
  )
import Prodbox.ControlPlane.OperationBudget
  ( awsCliChildBoundMicros
  , declaredRoleMaximumSeconds
  , finalPassReserveMicros
  , firstPassCeilingMicros
  , passLimitMicros
  , planSessionDuration
  , renderSessionWindowRefusal
  , sessionWindowMicros
  , shortCommandCeilingMicros
  , verdictReserveMicros
  )
import Prodbox.ControlPlane.ProviderAssumedRoleSession
  ( expectedLifecycleProviderAssumedRoleArn
  , expectedLifecycleProviderBaseUserArn
  , lifecycleProviderAssumeRoleRequest
  , providerAssumeRoleRequestFor
  )
import Prodbox.ControlPlane.ProviderCredentialSession.Internal
  ( ValidatedProviderCredentialSession
  , validateProviderCredentialSessionInternal
  , validatedProviderCredentialSessionBindingInternal
  , validatedProviderCredentialSessionCredentialsInternal
  )
import Prodbox.ControlPlane.ProviderFailureSummary
  ( childTimeoutMarker
  , renderCommandFailure
  , transcriptReportsMissingStack
  , transcriptReportsPreviewChanges
  )
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ApplyFailure (..)
  , ProviderEffectObservation (..)
  , ProviderIntentCapabilities (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  )
import Prodbox.ControlPlane.ProviderPulumiConfigProjection
  ( providerPulumiDiffArguments
  , providerPulumiPreviewArguments
  , providerRunMarkerConfiguration
  )
import Prodbox.Error (errorMsg)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.AwsEksTestStack (pulumiAwsProviderEnv)
import Prodbox.Lib.Storage (StaticEbsVolumeBinding (..))
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.AwsAudit (mkAuditObservation)
import Prodbox.Lifecycle.AwsAuditEvidence (encodeAwsAuditEvidence)
import Prodbox.Lifecycle.AwsAuditField (auditPositiveControl, auditStackField)
import Prodbox.Lifecycle.AwsDestroyConverge
  ( ConvergeOutcome (..)
  , DestroyPass (..)
  , PassResult (..)
  )
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , observeAwsNativeStackFamily
  , reapAwsNativeStackFamilyWithin
  )
import Prodbox.Lifecycle.AwsNetworkDependents (deleteSecurityGroupsWithin)
import Prodbox.Lifecycle.AwsNetworkPurge
import Prodbox.Lifecycle.AwsProviderRecording qualified as Recording
import Prodbox.Lifecycle.AwsStackDestroy
  ( PulumiRun
  , StackDestroyWorld (..)
  , pulumiDestroyPass
  , pulumiRemoveStack
  , stackDestroy
  )
import Prodbox.Lifecycle.AwsStackDiff
  ( StackPreview
  , decodePulumiStackPreview
  , encodeStackPreviewEvidence
  )
import Prodbox.Lifecycle.AwsTestCanary qualified as Canary
import Prodbox.Lifecycle.AwsTestCanaryExecution qualified as CanaryExecution
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment (..))
import Prodbox.Lifecycle.DnsRecord
  ( AwsAccountId
  , DnsCoordinateError
  , DnsOwnerAuthority
  , DnsProgramResult (..)
  , DnsRecordBoundary (..)
  , DnsRecordCoordinate
  , DnsRecordObservation (..)
  , DnsRecordOwner (AwsLifecycleProviderDnsOwner, AwsSesDnsOwner)
  , DnsRecordProgram (EnsureDnsRecord)
  , DnsRecordSet
  , DnsRecordType (DnsRecordA, DnsRecordCname, DnsRecordMx, DnsRecordTxt)
  , HostedZoneId
  , OwnershipEpoch
  , authorizedDnsOwner
  , dnsCoordinateName
  , dnsCoordinateType
  , dnsOwnerAuthorityForProcess
  , dnsRecordSetValues
  , hostedZoneIdText
  , mkAwsAccountId
  , mkDnsRecordSet
  , mkDnsRecordValue
  , mkHostedZoneId
  , mkOwnershipEpoch
  , mkPublicARecordCoordinate
  , mkSesDkimCoordinate
  , mkSesInboundMxCoordinate
  , mkSesVerificationCoordinate
  , runDnsRecordProgram
  , sesDkimRecordName
  , sesInboundMxRecordName
  , sesVerificationRecordName
  )
import Prodbox.Lifecycle.DnsRecord.Route53 (nativeDnsRecordSet, nativeDnsRecordType)
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Lifecycle.OwnedResourceTagEvidence
  ( OwnedResourceTagEntry (..)
  , OwnedResourceTagObservation (..)
  , OwnedResourceTagQueryEcho (..)
  , renderOwnedResourceTagEvidenceError
  , renderOwnedResourceTagObservation
  )
import Prodbox.Lifecycle.OwnedResourceTags (sesCaptureBucketTags)
import Prodbox.Lifecycle.ProviderWorker.Evidence
  ( ProviderEvidence
  , ProviderEvidenceBound
  , encodeProviderEvidence
  , providerEvidenceFromWireText
  , renderProviderEvidenceRefusal
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
  , ProviderAuditControl
  , ProviderAuditTarget
  , ProviderCheckpointRef
  , ProviderIntent (ObserveHomeDns01Records)
  , ProviderIntentCoordinate
  , ProviderNativeStackFamilyRef
  , ProviderNetworkPurgeMode (..)
  , ProviderOwnedTagQuery (..)
  , ProviderReadinessProbe (..)
  , ProviderRunMarker
  , ProviderSpotPriceQuery
  , ProviderStackConfig
  , ProviderStackConfigView (..)
  , ProviderStackRef
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  , dns01ChallengeRecordEvidenceFamily
  , eksClientAuthRequestAccountId
  , eksClientAuthRequestClusterName
  , eksClientAuthRequestDestinationPublicKey
  , eksClientAuthRequestRegion
  , eksClusterIdentityRequestAccountId
  , eksClusterIdentityRequestClusterName
  , eksClusterIdentityRequestRegion
  , eksIamRoleFamilyEvidenceFamily
  , eksLoadBalancerControllerFamilyEvidenceFamily
  , inviteMailCleanupAbsentEvidence
  , mkProviderNativeStackFamilyRef
  , providerAuditControlBucket
  , providerAuditControlRegion
  , providerAuditTargetHostedZoneId
  , providerAuditTargetStack
  , providerCheckpointRefText
  , providerIntentResourceKey
  , providerNativeStackFamilyAccountId
  , providerNativeStackFamilyNetworkFamily
  , providerNativeStackFamilyPurgeMode
  , providerNativeStackFamilyRegion
  , providerSpotPriceInstanceType
  , providerSpotPriceProductDescription
  , providerStackConfigView
  , providerStackRefText
  , publicARecordFqdn
  , publicARecordHostedZoneId
  , publicARecordTtl
  , publicARecordValues
  , registeredStackAbsenceEvidence
  , renderInviteMailCleanupEvidence
  , sesBucketRefText
  , sesDnsHostedZoneId
  , sesDnsIdentityDomain
  , sesDnsReceiveSubdomain
  , sesIdentityRefText
  , sesRuleSetCaptureBucket
  , sesRuleSetRecipient
  , sesRuleSetRefText
  , validateTestVpcCanaryRef
  , validationHostedZoneEvidenceFamily
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Lifecycle.TaggedResourceQuery qualified as TaggedResourceQuery
import Prodbox.Lifecycle.Teardown.AwsNativeStackFamilyAdapter
  ( encodeAwsNativeStackFamilyEvidence
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal
  ( encodeProviderAwsScopeEvidence
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as TeardownRegistry
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Lifecycle.ValidationHostedZone qualified as Route53ValidationZone
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError
  , PulumiStackRef (..)
  , renderEncryptedBackendError
  , withAuthenticatedDecryptedStackEnvironment
  , withAuthenticatedObservedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import Prodbox.Ses.Capture qualified as SesCapture
import Prodbox.Ses.CaptureCleanup qualified as CaptureCleanup
import Prodbox.Ses.CaptureLifecycle qualified as CaptureLifecycle
import Prodbox.Ses.InviteDelivery qualified as InviteDelivery
import Prodbox.Ses.InviteEvidence (InviteMailPublicKey)
import Prodbox.Settings (Credentials (..))
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsEbsVolumeType
  , awsEksStackConfiguration
  , awsTestStackConfiguration
  , mkAwsEbsVolumeType
  , renderAwsSubstrateProfileError
  )
import Prodbox.Settings.Coordinate (S3BucketName, mkS3BucketName, s3BucketNameText)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , KillableSubprocessLimits (..)
  , KillableSubprocessOutcome (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessKillable
  )
import Prodbox.Substrate (Substrate (SubstrateAws))
import Prodbox.Vault.Client
  ( KvV2SecretMetadata (kvV2SecretMetadataCurrentVersion)
  , vaultKvReadExactVersionV2
  , vaultKvReadMetadataV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

data ProviderProductionSession = ProviderProductionSession
  { productionSessionCredentials :: !Credentials
  , productionSessionCredentialHandle :: !SessionCredentialHandle
  , productionSessionAuthorityTransport
      :: !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
  , productionSessionAuthorityEpoch :: !(IO (Either Text AuthorityEpoch))
  -- ^ Sprint 4.72: the retained Authority epoch this process is acting
  -- under, read on demand. A DNS coordinate binds an ownership generation,
  -- and the only truthful source of one is the Authority the role already
  -- trusts — not a number carried in the request.
  , productionSessionExpiresAtMicros :: !Natural
  -- ^ When STS stops honouring this session, in Authority-time microseconds.
  -- A long child is bounded by what is left of it, so the session cannot
  -- expire under a running child.
  , productionSessionNowMicros :: !(IO (Either Text Natural))
  , productionSessionCanaryEvidence :: !(IORef (Maybe Text))
  -- ^ Invocation-only scrubbed probe buffer; it grants no lifecycle authority.
  -- ^ The Authority clock the session window is judged against.
  }

-- | The world a wait runs in for this session: the session's own clock and
-- expiry, a real pause, and the intent lifetime the budgets' shares are shares
-- of. A wait therefore ends at its ceiling or when the session's usable window
-- does, whichever is nearer.
sessionWaitEnvironment :: ProviderProductionSession -> AwsWaitEnvironment IO
sessionWaitEnvironment session =
  AwsWaitEnvironment
    { awsWaitNowMicros = productionSessionNowMicros session
    , awsWaitPauseMicros = threadDelay . fromIntegral
    , awsWaitSessionExpiresAtMicros = productionSessionExpiresAtMicros session
    , awsWaitIntentLifetimeMicros = providerWorkerIntentLifetimeMicros
    }

providerProductionNarrowSession
  :: VaultSession
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either Text AuthorityEpoch)
  -> IO (Either Text AuthorityTime)
  -> ProviderNarrowSessionRunner IO ProviderProductionSession
providerProductionNarrowSession vaultSession authorityTransport readAuthorityEpoch authorityNow =
  ProviderNarrowSessionRunner
    { withProviderNarrowSession = \intent deadline action -> do
        credentialSession <- readProviderCredentialSession vaultSession
        case credentialSession of
          Left detail -> pure (Left detail)
          Right resolved -> do
            requestedAt <- authorityNow
            case requestedAt of
              Left detail -> pure (Left ("Provider session clock unavailable: " <> detail))
              Right now -> do
                -- The session must outlive the operation it serves: its lifetime
                -- is derived from the signed deadline, not fixed at the STS floor.
                assumed <-
                  assumeProviderRoleSession
                    ( providerAssumeRoleRequestFor
                        ( planSessionDuration
                            declaredRoleMaximumSeconds
                            (authorityTimeMicros now)
                            (authorityTimeMicros deadline)
                        )
                        intent
                    )
                    (validatedProviderCredentialSessionCredentialsInternal resolved)
                case assumed of
                  Left detail -> pure (Left detail)
                  Right roleSession -> do
                    let expiresAt = NativeSts.assumedRoleSessionExpiresAtMicros roleSession
                        clock = fmap (fmap authorityTimeMicros) authorityNow
                    startingAt <- clock
                    case startingAt >>= first renderSessionWindowRefusal . sessionWindowMicros expiresAt of
                      Left detail -> pure (Left detail)
                      Right _ -> do
                        canaryEvidence <- newIORef Nothing
                        action
                          (Just (validatedProviderCredentialSessionBindingInternal resolved))
                          ProviderProductionSession
                            { productionSessionCredentials =
                                NativeSts.assumedRoleSessionCredentials roleSession
                            , productionSessionCredentialHandle =
                                NativeSts.assumedRoleSessionHandle roleSession
                            , productionSessionAuthorityTransport = authorityTransport
                            , productionSessionAuthorityEpoch = readAuthorityEpoch
                            , productionSessionExpiresAtMicros = expiresAt
                            , productionSessionNowMicros = clock
                            , productionSessionCanaryEvidence = canaryEvidence
                            }
    }

providerProductionCapabilities
  :: ProviderIntentCapabilities IO ProviderProductionSession
providerProductionCapabilities =
  ProviderIntentCapabilities
    { reconcileRegisteredStackCapability = \ref _revision config marker ->
        pulumiMutation DesiredPresent ref config (Just marker)
    , destroyRegisteredStackCapability = \ref _revision config ->
        -- A destroy names a stack that already exists and must not restate the
        -- run that made it: the marker the provider holds is the creating run's
        -- and a destroy has no standing to overwrite it.
        pulumiMutation DesiredAbsent ref config Nothing
    , observeRegisteredStackCapability = \ref ->
        ProviderReadOnly
          ( \session _ providerBound ->
              sealProviderEvidence providerBound <$> observeStackRef session ref
          )
    , readBackRegisteredStackCapability = \ref ->
        ProviderReadOnly
          ( \session _ providerBound ->
              sealProviderEvidence providerBound <$> observeStackRef session ref
          )
    , previewRegisteredStackCapability = stackPreviewObservation
    , boundedScratchCheckpointCapability = scratchCheckpointMutation
    , reconcileSesSendingIdentityCapability = sesIdentityMutation
    , reconcileSesDkimCapability = sesDkimMutation
    , reconcileSesReceiptRulesCapability = sesReceiptRulesMutation
    , reconcileSesCaptureBucketCapability = sesCaptureBucketMutation
    , reconcileSesDnsCapability = sesDnsMutation
    , observePublicARecordCapability = publicARecordObservation
    , reconcilePublicARecordCapability = publicARecordMutation
    , reapTestEbsVolumesCapability = ebsReaperMutation
    , observeTestEbsVolumesCapability = testEbsObservation
    , observeValidationHostedZonesCapability = validationHostedZoneObservation
    , reapValidationHostedZonesCapability = validationHostedZoneReaperMutation
    , observeDns01ChallengeRecordsCapability = dns01ChallengeRecordObservation
    , observeRetainedEbsVolumesCapability = retainedEbsObservation
    , reapRetainedEbsVolumesCapability = retainedEbsReaperMutation
    , observeEksIamRoleFamilyCapability = eksIamRoleFamilyObservation
    , reapEksIamRoleFamilyCapability = eksIamRoleFamilyReaperMutation
    , observeEksLoadBalancerControllerFamilyCapability =
        eksLoadBalancerControllerFamilyObservation
    , reapEksLoadBalancerControllerFamilyCapability =
        eksLoadBalancerControllerFamilyReaperMutation
    , observeGlobalOwnedResourceTagsCapability =
        ownedResourceTagObservationInRegion (Just awsGlobalServiceRegion)
    , observeOwnedResourceTagsCapability = ownedResourceTagObservation
    , observeSpotPriceCapability = spotPriceObservation
    , observeOperationalIdentityCapability = operationalIdentityObservation
    , observeProviderAwsScopeCapability = providerAwsScopeObservation
    , observeProviderReadinessCapability = readinessObservation
    , issueEksClientAuthCapability = eksClientAuthObservation
    , observeEksClusterIdentityCapability = eksClusterIdentityObservation
    , plantTestVpcCanaryCapability = testVpcCanaryMutation
    , observeNativeStackFamilyCapability = nativeStackFamilyObservation
    , reapNativeStackFamilyCapability = nativeStackFamilyReaperMutation
    , observeAwsAuditCapability = awsAuditObservation
    , ensureValidationHostedZoneCapability = validationHostedZoneEnsureMutation
    , observeHomeDns01RecordsCapability = homeDns01RecordObservation
    , observeSesInviteMailResidueCapability = inviteMailResidueObservation
    , reapSesInviteMailResidueCapability = inviteMailResidueMutation
    , observeSealedSesInviteMailCapability = sesInviteMailObservation
    , ensureRetainedEbsVolumesCapability = retainedEbsEnsureMutation
    }

-- | Deep readiness for the production worker: the exact Provider Vault KV
-- object must be readable, its base identity must assume the deterministic
-- registered role, and that temporary session must identify as the expected
-- assumed-role caller. No ambient AWS source participates.
providerProductionReady :: VaultSession -> IO Bool
providerProductionReady vaultSession = do
  credentialSession <- readProviderCredentialSession vaultSession
  case credentialSession of
    Left _ -> pure False
    Right resolved -> do
      assumed <-
        assumeProviderRoleSession
          lifecycleProviderAssumeRoleRequest
          (validatedProviderCredentialSessionCredentialsInternal resolved)
      pure $ case assumed of
        Left _ -> False
        Right _ -> True

assumeProviderRoleSession
  :: (AwsAccountId -> NativeSts.AssumeRoleRequest)
  -> Credentials
  -> IO (Either Text NativeSts.AssumedRoleSession)
assumeProviderRoleSession requestForAccount credentials =
  case baseCredentialHandleFromSettings credentials of
    Left err -> pure (Left ("Provider AWS base credential is invalid: " <> Text.pack (show err)))
    Right baseHandle -> do
      let stsClient = NativeSts.newStsClient baseHandle httpSend
      baseIdentity <- NativeSts.getCallerIdentity stsClient
      case baseIdentity of
        Left err -> pure (Left (providerStsFailure "base identity" err))
        Right identity ->
          case coordinateError (mkAwsAccountId (NativeSts.callerIdentityAccount identity)) of
            Left detail -> pure (Left ("Provider STS returned an invalid account: " <> detail))
            Right account
              | NativeSts.callerIdentityArn identity
                  /= expectedLifecycleProviderBaseUserArn account ->
                  pure (Left "Provider Vault credential names an unexpected base caller")
              | otherwise -> do
                  assumed <- NativeSts.assumeRole stsClient (requestForAccount account)
                  case assumed of
                    Left err -> pure (Left (providerStsFailure "role assumption" err))
                    Right roleSession -> do
                      roleIdentity <-
                        NativeSts.getCallerIdentityForSession
                          (NativeSts.assumedRoleSessionHandle roleSession)
                          httpSend
                      pure $ case roleIdentity of
                        Left err -> Left (providerStsFailure "assumed-role identity" err)
                        Right observed
                          | NativeSts.callerIdentityAccount observed
                              /= NativeSts.callerIdentityAccount identity ->
                              Left "Provider assumed-role session changed AWS account"
                          | NativeSts.callerIdentityArn observed
                              /= expectedLifecycleProviderAssumedRoleArn account ->
                              Left "Provider assumed-role session names an unexpected caller"
                          | otherwise -> Right roleSession

providerStsFailure :: Text -> AwsClientError -> Text
providerStsFailure stage err =
  "Provider STS " <> stage <> " failed: " <> Text.pack (show err)

data DesiredState = DesiredPresent | DesiredAbsent
  deriving (Eq)

data CompiledStack = CompiledStack
  { compiledStackPulumiRef :: !PulumiStackRef
  , compiledStackProjectDirectory :: !FilePath
  , compiledStackConfiguration :: ![(String, String)]
  , compiledStackApplication :: !CompiledStackApplication
  , compiledStackChildLimits :: IO (Either Text KillableSubprocessLimits)
  -- ^ The wall-clock bound for the next Pulumi child, read when that child
  -- starts so each one is bounded by what is left of the session at that moment.
  }

data CompiledStackApplication
  = CompiledStackApplyable
  | CompiledStackObservationOnly
  deriving (Eq)

compiledStackFor
  :: ProviderStackRef
  -> ProviderStackConfig
  -> Maybe ProviderRunMarker
  -> Either Text CompiledStack
compiledStackFor ref config marker = case (providerStackRefText ref, config) of
  ("aws-eks", _) -> case providerStackConfigView config of
    AwsEksLegacyConfig _ ->
      Right (stack "prodbox-aws-eks-test" "aws-eks-test" "aws-eks" [] CompiledStackObservationOnly)
    AwsEksProfileConfig profile desiredSize -> do
      configuration <-
        first (Text.pack . renderAwsSubstrateProfileError) (awsEksStackConfiguration profile desiredSize)
      Right
        ( stack
            "prodbox-aws-eks-test"
            "aws-eks-test"
            "aws-eks"
            configuration
            CompiledStackApplyable
        )
    _ -> Left "provider stack/config pair is not in the compiled non-SES registry"
  ("aws-eks-subzone", _) -> case providerStackConfigView config of
    AwsEksSubzoneConfig parentZoneId subzoneName ->
      Right
        ( stack
            "prodbox-aws-eks-subzone"
            "aws-eks-subzone"
            "aws-eks-subzone"
            [ ("parentZoneId", Text.unpack parentZoneId)
            , ("subzoneName", Text.unpack subzoneName)
            ]
            CompiledStackApplyable
        )
    _ -> Left "provider stack/config pair is not in the compiled non-SES registry"
  ("aws-test", _) -> case providerStackConfigView config of
    AwsTestLegacyConfig _ ->
      Right (stack "prodbox-aws-test" "aws-test" "aws-test" [] CompiledStackObservationOnly)
    AwsTestProfileConfig profile -> do
      configuration <-
        first (Text.pack . renderAwsSubstrateProfileError) (awsTestStackConfiguration profile)
      Right
        ( stack
            "prodbox-aws-test"
            "aws-test"
            "aws-test"
            configuration
            CompiledStackApplyable
        )
    _ -> Left "provider stack/config pair is not in the compiled non-SES registry"
  _ -> Left "provider stack/config pair is not in the compiled non-SES registry"
 where
  stack project stackId subdirectory configuration application =
    CompiledStack
      { compiledStackPulumiRef = PulumiStackRef project stackId
      , compiledStackProjectDirectory = providerBuildRoot </> "pulumi" </> subdirectory
      , compiledStackConfiguration = configuration ++ runMarkerConfiguration
      , compiledStackApplication = application
      , compiledStackChildLimits = pure (Right pulumiChildLimits)
      }

  -- Sprint 7.41: the two values the provider stamps onto every resource it
  -- creates, projected on the preview as well as the apply.  Projecting them on
  -- only one of the two is the exact defect
  -- @PROVIDER-WORKER-PULUMI-STACK-CONFIG-ABSENT-2026-09-05@ froze: a preview run
  -- against different configuration than the apply reports an agreement the
  -- apply does not keep.  The consequence is stated rather than hidden -- a
  -- reconcile of a present stack now previews a tag change and applies it, so
  -- the marker the provider holds names the run that last proved it rather than
  -- a run that has since been forgotten.
  runMarkerConfiguration = maybe [] providerRunMarkerConfiguration marker

providerBuildRoot :: FilePath
providerBuildRoot = "/opt/build"

pulumiMutation
  :: DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> Maybe ProviderRunMarker
  -> ProviderMutation IO ProviderProductionSession
pulumiMutation desired ref config marker =
  ProviderMutation
    { observeProviderMutation = \session _coordinate ->
        observeDesiredStack session desired ref config marker
    , applyProviderMutation = \session _coordinate ->
        failedApply (applyDesiredStack session desired ref config marker)
    }

-- | Every production apply reports a failure the effect itself produced. The
-- worker boundary observes again after every apply, so whether the effect
-- landed is settled by that read-back and not by what the apply reported.
failedApply :: IO (Either Text ()) -> IO (Either ApplyFailure ())
failedApply = fmap (first ApplyFailed)

observeDesiredStack
  :: ProviderProductionSession
  -> DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> Maybe ProviderRunMarker
  -> IO ProviderEffectObservation
observeDesiredStack session desired ref config marker =
  case boundToSession session <$> compiledStackFor ref config marker of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right compiled
      | desired == DesiredPresent
      , compiledStackApplication compiled == CompiledStackObservationOnly ->
          pure
            ( ProviderEffectUnobservable
                "retained stack config predates the required authored AWS substrate profile"
            )
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      observed <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (observePulumiStack desired ref compiled)
      pure $ case observed of
        Left err -> ProviderEffectUnobservable (renderBackendError err)
        Right observation -> observation

applyDesiredStack
  :: ProviderProductionSession
  -> DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> Maybe ProviderRunMarker
  -> IO (Either Text ())
applyDesiredStack session desired ref config marker =
  case boundToSession session <$> compiledStackFor ref config marker of
    Left detail -> pure (Left detail)
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (applyWithinBackend session ref config desired compiled)
      pure (either (Left . renderBackendError) (const (Right ())) result)

-- | Sprint 4.111: what runs once the stack's backend is open. A destroy of a
-- stack that has a VPC converges; every other mutation is the single Pulumi
-- command it has always been.
applyWithinBackend
  :: ProviderProductionSession
  -> ProviderStackRef
  -> ProviderStackConfig
  -> DesiredState
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
applyWithinBackend session ref config desired compiled environment
  | desired == DesiredAbsent && stackHasVpc ref =
      convergeStackDestroy session ref config compiled environment
  | otherwise = runPulumiMutation desired compiled environment

-- | The registered stacks whose resources sit in a VPC of their own, and so can
-- be blocked by a child a controller left in it.
stackHasVpc :: ProviderStackRef -> Bool
stackHasVpc ref = providerStackRefText ref `elem` ["aws-eks", "aws-test"]

-- | Sprint 4.111: destroy a stack with a VPC as a converging loop -- a bounded
-- first pass, the repair of what a controller left, a final pass, and a reading
-- of the field that alone removes the stack record -- or say what stopped it.
convergeStackDestroy
  :: ProviderProductionSession
  -> ProviderStackRef
  -> ProviderStackConfig
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
convergeStackDestroy session ref config compiled environment = do
  login <- runPulumi compiled environment ["login", backendUrl environment]
  case commandSuccess login of
    Left detail -> pure (Left detail)
    Right _ -> do
      awsEnvironment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
      account <- providerSessionAccountId awsEnvironment
      case (,) <$> account <*> providerSessionRegion awsEnvironment of
        Left detail -> pure (Left (Text.unpack detail))
        Right (accountId, regionText) ->
          case mkProviderNativeStackFamilyRef ref accountId regionText Nothing of
            Left err -> pure (Left (show err))
            Right nativeRef -> do
              outcome <- stackDestroy (world nativeRef awsEnvironment)
              pure $ case outcome of
                Converged -> Right ()
                Blocked detail -> Left (Text.unpack detail)
 where
  lifetime = fromIntegral providerWorkerIntentLifetimeMicros
  reserve = finalPassReserveMicros lifetime
  world nativeRef awsEnvironment =
    StackDestroyWorld
      { worldStackName = stackName compiled
      , worldPulumi = \pass -> runPulumi (compiledFor pass) environment
      , worldPulumiShort = runPulumi shortCompiled environment
      , worldAws = AwsNativeStackFamilyRunner (runAws awsEnvironment)
      , worldWaits = sessionWaitEnvironment session
      , worldFinalPassReserveMicros = reserve
      , worldRef = nativeRef
      , worldConfig = config
      , worldCluster = clusterOf
      , worldLoadBalancers = loadBalancersOf
      }
  -- The commands around the passes are quick: bounded by the session and by a
  -- ceiling of their own, and reserving nothing.
  shortCompiled =
    compiled
      { compiledStackChildLimits = pulumiChildLimitsWithin 0 shortCommandCeilingMicros session
      }
  -- The first pass is cut at its share and leaves the final pass its reserve;
  -- the final pass has whatever window the session has left less what the
  -- reading and the commit after it need. Both leave the kill grace as well, so
  -- a pass that has to be killed still ends inside what it was given.
  compiledFor pass =
    let (reserveMicros, ceilingMicros) = destroyPassBounds lifetime pass
     in compiled
          { compiledStackChildLimits = pulumiChildLimitsWithin reserveMicros ceilingMicros session
          }
  clusterOf
    | providerStackRefText ref == "aws-eks" = Just TeardownRegistry.awsEksProvisionedClusterName
    | otherwise = Nothing
  loadBalancersOf
    | providerStackRefText ref == "aws-eks" =
        Just
          ( \waits ->
              reapEksLoadBalancerControllerFamilyWithin
                session
                waits
                TeardownRegistry.awsEksLoadBalancerControllerName
                eksLoadBalancerControllerFamilyTags
          )
    | otherwise = Nothing

observePulumiStack
  :: DesiredState
  -> ProviderStackRef
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ProviderEffectObservation)
observePulumiStack desired ref compiled environment =
  observePulumiStackVia
    (runPulumi compiled environment)
    (backendUrl environment)
    (stackName compiled)
    (compiledStackConfiguration compiled)
    desired
    ref

-- | The observation, over the Pulumi child runner it is given.
--
-- A stack whose preview proposes nothing is satisfied, and its evidence is the
-- digest of what the stack recorded: its outputs. Before Sprint @4.110@ the
-- evidence was the digest of what @pulumi stack select@ printed, which is
-- nothing, so every converged stack's receipt was the SHA-256 of zero bytes and
-- said nothing about AWS. A stack that recorded no outputs is unobservable, not
-- satisfied with a receipt that carries no content.
observePulumiStackVia
  :: (Monad m)
  => PulumiRun m
  -> String
  -> String
  -> [(String, String)]
  -> DesiredState
  -> ProviderStackRef
  -> m (Either String ProviderEffectObservation)
observePulumiStackVia run backend stack configuration desired ref = do
  login <- run ["login", backend]
  case commandSuccess login of
    Left detail -> pure (Right (ProviderEffectUnobservable (Text.pack detail)))
    Right _ -> do
      selected <- run ["stack", "select", "--stack", stack, "--non-interactive"]
      case processExitCode selected of
        ExitFailure _
          | missingStack selected ->
              pure
                ( Right $ case desired of
                    DesiredPresent ->
                      ProviderEffectNeedsApply (registeredStackAbsenceEvidence ref)
                    DesiredAbsent ->
                      ProviderEffectSatisfied (registeredStackAbsenceEvidence ref)
                )
          | otherwise -> pure (Right (ProviderEffectUnobservable (Text.pack (commandFailureDetail selected))))
        ExitSuccess -> case desired of
          DesiredAbsent -> pure (Right (ProviderEffectNeedsApply "registered stack is present"))
          DesiredPresent -> do
            preview <- run (providerPulumiPreviewArguments stack configuration)
            case processExitCode preview of
              ExitSuccess -> do
                recorded <- run ["stack", "output", "--stack", stack, "--json"]
                pure (Right (convergedStackObservation recorded))
              ExitFailure _
                | previewReportsChanges preview ->
                    pure (Right (ProviderEffectNeedsApply "Pulumi preview reports changes"))
                | otherwise ->
                    pure (Right (ProviderEffectUnobservable (Text.pack (commandFailureDetail preview))))

-- | What a stack whose preview proposes nothing reports, from the outputs it
-- recorded.
convergedStackObservation :: ProcessOutput -> ProviderEffectObservation
convergedStackObservation recorded =
  case commandSuccess recorded of
    Left detail -> ProviderEffectUnobservable (Text.pack detail)
    Right output
      | recordsNoOutputs output ->
          ProviderEffectUnobservable
            "the converged stack recorded no outputs, so its receipt would carry no content"
      | otherwise -> either ProviderEffectUnobservable ProviderEffectSatisfied (stackEvidence output)

-- | Whether the recorded outputs are empty or an empty object.
recordsNoOutputs :: ProcessOutput -> Bool
recordsNoOutputs output = Text.strip (Text.pack (processStdout output)) `elem` ["", "{}", "null"]

runPulumiMutation
  :: DesiredState
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
runPulumiMutation desired compiled environment = do
  case (desired, compiledStackApplication compiled) of
    (DesiredPresent, CompiledStackObservationOnly) ->
      pure (Left "retained stack config predates the required authored AWS substrate profile")
    _ -> run
 where
  run = do
    login <- runPulumi compiled environment ["login", backendUrl environment]
    case commandSuccess login of
      Left detail -> pure (Left detail)
      Right _ -> case desired of
        DesiredPresent -> do
          selected <-
            runPulumi
              compiled
              environment
              ["stack", "select", "--stack", stackName compiled, "--create", "--non-interactive"]
          case commandSuccess selected of
            Left detail -> pure (Left detail)
            Right _ -> do
              configured <- setPulumiConfiguration compiled environment
              case configured of
                Left detail -> pure (Left detail)
                Right () ->
                  do
                    updated <-
                      runPulumi
                        compiled
                        environment
                        ["up", "--stack", stackName compiled, "--yes", "--skip-preview", "--non-interactive"]
                    pure (Control.Monad.void (commandSuccess updated))
        DesiredAbsent -> pulumiDestroySelected (runPulumi compiled environment) (stackName compiled)

-- | Destroy a stack after the backend login with a single pass: a stack that is
-- not there is already destroyed; otherwise destroy it, and remove it only when
-- the destroy succeeded, so a stack that still holds resources keeps its record.
--
-- Sprint 4.111: this is the destroy of a stack with no VPC of its own (the
-- per-run subzone). A stack with a VPC converges instead
-- ('Prodbox.Lifecycle.AwsStackDestroy.stackDestroy'); both share the pass.
pulumiDestroySelected
  :: (Monad m)
  => PulumiRun m
  -> String
  -> m (Either String ())
pulumiDestroySelected run stack = do
  pass <- pulumiDestroyPass run stack
  case pass of
    PassStackAbsent -> pure (Right ())
    PassFailed detail -> pure (Left (Text.unpack detail))
    PassSucceeded -> first Text.unpack <$> pulumiRemoveStack run stack

setPulumiConfiguration
  :: CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
setPulumiConfiguration compiled environment = go (compiledStackConfiguration compiled)
 where
  go [] = pure (Right ())
  go ((key, value) : remaining) = do
    output <-
      runPulumi
        compiled
        environment
        ["config", "set", "--stack", stackName compiled, key, value, "--non-interactive"]
    case commandSuccess output of
      Left detail -> pure (Left detail)
      Right _ -> go remaining

-- | Seal an existing rendering against the bound of the intent being served.
-- Sprint @4.99@.
--
-- This is the migration seam, not the destination.  It re-applies the wire's
-- own rules to a value a producer has already rendered, so a producer that
-- emits something the wire refuses now fails as a typed 'Left' where it is
-- written rather than at a boundary 900 lines away -- which is where all six of
-- the defective encoders were discovered.  A family that has moved to the
-- canonical codec does not need it: 'encodeProviderEvidence' takes the same
-- bound and cannot produce a value that fails here.
sealProviderEvidence
  :: ProviderEvidenceBound -> Either Text Text -> Either Text ProviderEvidence
sealProviderEvidence providerBound result =
  result >>= providerEvidenceFromWireText providerBound

observeStackRef
  :: ProviderProductionSession
  -> ProviderStackRef
  -> IO (Either Text Text)
observeStackRef session ref =
  case boundToSession session <$> defaultCompiledStack ref of
    Left detail -> pure (Left detail)
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (readPulumiStack compiled)
      pure $ case result of
        Left err -> Left (renderBackendError err)
        Right PulumiStackObservedAbsent -> Right (registeredStackAbsenceEvidence ref)
        Right (PulumiStackObservedPresent evidence) -> Right evidence

stackPreviewObservation
  :: ProviderStackRef -> ProviderStackConfig -> ProviderReadOnly IO ProviderProductionSession
stackPreviewObservation ref config = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    case previewCompiledStack session ref config of
      Left detail -> pure (Left detail)
      Right unbounded -> do
        let compiled = boundToSession session unbounded
        environment <- pulumiEnvironment (productionSessionCredentials session)
        result <-
          withAuthenticatedObservedDecryptedStackEnvironment
            (productionSessionAuthorityTransport session)
            (compiledStackPulumiRef compiled)
            environment
            ( \configured ->
                first Text.unpack
                  <$> previewPulumiStackVia
                    (runPulumi compiled configured)
                    (backendUrl configured)
                    (stackName compiled)
                    (compiledStackConfiguration compiled)
            )
        pure $ case result of
          Left _ -> Left "Provider stack preview checkpoint is unobservable"
          Right preview -> encodeStackPreviewEvidence (providerStackRefText ref) preview

-- SES preview has its own compiler arm. The mutation compiler above continues
-- to reject SES, and stack-diff resource keys grant no stack mutation.
previewCompiledStack
  :: ProviderProductionSession -> ProviderStackRef -> ProviderStackConfig -> Either Text CompiledStack
previewCompiledStack session ref config = case (providerStackRefText ref, providerStackConfigView config) of
  ("aws-ses", AwsSesPreviewConfig sender receive bucket) ->
    Right
      CompiledStack
        { compiledStackPulumiRef = PulumiStackRef "prodbox-aws-ses" "aws-ses"
        , compiledStackProjectDirectory = providerBuildRoot </> "pulumi" </> "aws-ses"
        , compiledStackConfiguration =
            [ ("senderDomain", Text.unpack sender)
            , ("receiveSubdomain", Text.unpack receive)
            , ("captureBucket", Text.unpack bucket)
            , ("awsRegion", Text.unpack (region (productionSessionCredentials session)))
            ]
        , compiledStackApplication = CompiledStackObservationOnly
        , compiledStackChildLimits = pure (Right pulumiChildLimits)
        }
  _ -> do
    compiled <- compiledStackFor ref config Nothing
    case compiledStackApplication compiled of
      CompiledStackObservationOnly -> Left "stack diff requires an authored AWS substrate profile"
      CompiledStackApplyable -> Right compiled

-- | The complete diagnostic boundary. Failure text never includes a child
-- transcript: those fields can contain provider values even without secrets.
previewPulumiStackVia
  :: (Monad m)
  => PulumiRun m
  -> String
  -> String
  -> [(String, String)]
  -> m (Either Text StackPreview)
previewPulumiStackVia run backend stack configuration = do
  login <- run ["login", backend]
  case processExitCode login of
    ExitFailure _ -> pure (Left "Pulumi preview backend login failed")
    ExitSuccess -> do
      selected <- run ["stack", "select", "--stack", stack, "--non-interactive"]
      case processExitCode selected of
        ExitFailure _ -> pure (Left "Pulumi preview requires an observable registered checkpoint")
        ExitSuccess ->
          decodePulumiStackPreview <$> run (providerPulumiDiffArguments stack configuration)

defaultCompiledStack :: ProviderStackRef -> Either Text CompiledStack
defaultCompiledStack ref = case providerStackRefText ref of
  "aws-eks" -> observationStack "prodbox-aws-eks-test" "aws-eks-test" "aws-eks"
  "aws-eks-subzone" ->
    observationStack "prodbox-aws-eks-subzone" "aws-eks-subzone" "aws-eks-subzone"
  "aws-test" -> observationStack "prodbox-aws-test" "aws-test" "aws-test"
  _ -> Left "stack is not in the compiled non-SES registry"
 where
  observationStack project stackId subdirectory =
    Right
      CompiledStack
        { compiledStackPulumiRef = PulumiStackRef project stackId
        , compiledStackProjectDirectory = providerBuildRoot </> "pulumi" </> subdirectory
        , compiledStackConfiguration = []
        , compiledStackApplication = CompiledStackObservationOnly
        , compiledStackChildLimits = pure (Right pulumiChildLimits)
        }

-- | What a registered-stack read reports.  Sprint @4.98@ split this out of a
-- bare 'Text' so the absence arm is a constructor rather than a sentence, and
-- so the coordinate is attached by the caller that actually holds one.
data PulumiStackObservation
  = PulumiStackObservedAbsent
  | PulumiStackObservedPresent !Text

readPulumiStack
  :: CompiledStack
  -> [(String, String)]
  -> IO (Either String PulumiStackObservation)
readPulumiStack compiled environment = do
  login <- runPulumi compiled environment ["login", backendUrl environment]
  case commandSuccess login of
    Left detail -> pure (Left detail)
    Right _ -> do
      selected <-
        runPulumi
          compiled
          environment
          ["stack", "select", "--stack", stackName compiled, "--non-interactive"]
      if missingStack selected
        then pure (Right PulumiStackObservedAbsent)
        else case commandSuccess selected of
          Left detail -> pure (Left detail)
          Right _ -> do
            output <-
              runPulumi compiled environment ["stack", "output", "--stack", stackName compiled, "--json"]
            pure (commandSuccess output >>= first Text.unpack . fmap PulumiStackObservedPresent . stackEvidence)

pulumiEnvironment :: Credentials -> IO [(String, String)]
pulumiEnvironment credentials = do
  inherited <- getEnvironment
  let select key = maybe [] (\value -> [(key, value)]) (lookup key inherited)
  pure
    ( concatMap select ["PATH", "HOME", "LANG", "TERM", "USER"]
        <> [ ("AWS_EC2_METADATA_DISABLED", "true")
           , ("PULUMI_SKIP_UPDATE_CHECK", "true")
           ]
        <> pulumiAwsProviderEnv credentials
    )

runPulumi
  :: CompiledStack
  -> [(String, String)]
  -> [String]
  -> IO ProcessOutput
runPulumi compiled environment arguments = do
  limits <- compiledStackChildLimits compiled
  case limits of
    Left detail -> pure (ProcessOutput (ExitFailure 1) "" (Text.unpack detail))
    Right bound -> runPulumiWithin bound compiled environment arguments

-- | Run Pulumi under an explicit wall-clock bound.  The child is stopped by
-- SIGTERM and then SIGKILL, so it cannot outlive the bound or its caller, and
-- a child stopped at the bound still reports the transcript it had written.
runPulumiWithin
  :: KillableSubprocessLimits
  -> CompiledStack
  -> [(String, String)]
  -> [String]
  -> IO ProcessOutput
runPulumiWithin limits compiled environment arguments = do
  result <- withProviderChildProcessPermit $ do
    captureSubprocessKillable
      limits
      Subprocess
        { subprocessPath = "/usr/local/bin/pulumi"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just (compiledStackProjectDirectory compiled)
        }
  pure $ case result of
    Right (KillableSubprocessCompleted output) -> output
    Right (KillableSubprocessTimedOut output) -> timedOutPulumiOutput limits output
    Left detail -> ProcessOutput (ExitFailure 1) "" (Text.unpack (errorMsg detail))

-- | The Pulumi child's own wall-clock bound.  It sits strictly inside the
-- intent lifetime the handler enforces, so the innermost bound fires first and
-- the operator receives the child's transcript rather than a bare timeout: the
-- ordering the Provider budget states for child, server and caller.  The
-- allowance covers admission, session and observation before the child starts.
pulumiChildLimits :: KillableSubprocessLimits
pulumiChildLimits =
  KillableSubprocessLimits
    { killableSubprocessTimeoutMicros =
        fromIntegral providerWorkerIntentLifetimeMicros - pulumiPreChildAllowanceMicros
    , killableSubprocessKillGraceMicros = 30 * 1000 * 1000
    }

pulumiPreChildAllowanceMicros :: Int
pulumiPreChildAllowanceMicros = 120 * 1000 * 1000

-- | Bound every Pulumi child of this stack by what is left of the session.
boundToSession :: ProviderProductionSession -> CompiledStack -> CompiledStack
boundToSession session compiled =
  compiled {compiledStackChildLimits = pulumiChildLimitsForSession session}

-- | The bound for the next Pulumi child: the child maximum, or the window left
-- in the session once the read-back grace is reserved, whichever is smaller. A
-- session with no usable window left starts no child.
pulumiChildLimitsForSession
  :: ProviderProductionSession -> IO (Either Text KillableSubprocessLimits)
pulumiChildLimitsForSession session =
  pulumiChildLimitsWithin 0 (fromIntegral (killableSubprocessTimeoutMicros pulumiChildLimits)) session

-- | The bound for the next Pulumi child when part of the session is spoken for:
-- the window the session has left less what is reserved for the work after it,
-- the child maximum, and a ceiling the caller names (the first destroy pass's
-- share). A window the reserve leaves nothing of starts no child.
pulumiChildLimitsWithin
  :: Natural
  -> Natural
  -> ProviderProductionSession
  -> IO (Either Text KillableSubprocessLimits)
pulumiChildLimitsWithin reserveMicros ceilingMicros session = do
  nowResult <- productionSessionNowMicros session
  pure $ do
    now <- nowResult
    window <-
      first
        renderSessionWindowRefusal
        (sessionWindowMicros (productionSessionExpiresAtMicros session) now)
    pulumiChildLimitsFor reserveMicros ceilingMicros window

-- | The limits for a Pulumi child given the window the session has left, apart
-- from the clock that measured it.
pulumiChildLimitsFor :: Natural -> Natural -> Natural -> Either Text KillableSubprocessLimits
pulumiChildLimitsFor reserveMicros ceilingMicros window =
  case passLimitMicros
    ceilingMicros
    reserveMicros
    (fromIntegral (killableSubprocessTimeoutMicros pulumiChildLimits))
    window of
    Nothing -> Left "no session window is left for a Pulumi pass once the work after it is reserved for"
    Just limit -> Right pulumiChildLimits {killableSubprocessTimeoutMicros = fromIntegral limit}

-- | What each destroy pass reserves for the work after it, and the longest it
-- may run, for an intent of the given lifetime. The first pass leaves the final
-- pass its reserve and is cut at its share; the final pass leaves the reading of
-- the field and the commit that follow it, and the child maximum bounds it. Both
-- leave the kill grace, because a pass that is stopped by the kill spends it.
destroyPassBounds :: Natural -> DestroyPass -> (Natural, Natural)
destroyPassBounds lifetime pass = case pass of
  FirstPass -> (finalPassReserveMicros lifetime + killGrace, firstPassCeilingMicros lifetime)
  FinalPass ->
    (verdictReserveMicros + killGrace, fromIntegral (killableSubprocessTimeoutMicros pulumiChildLimits))
 where
  -- A pass that has to be stopped spends the grace, the five seconds the runner
  -- waits to confirm a kill, and up to ten settling the readers of its output.
  killGrace =
    fromIntegral (killableSubprocessKillGraceMicros pulumiChildLimits) + 15 * 1000 * 1000

-- | A child stopped at its bound is a failure whose transcript ends in the
-- timeout marker, which the failure summary names as the consequence.
timedOutPulumiOutput :: KillableSubprocessLimits -> ProcessOutput -> ProcessOutput
timedOutPulumiOutput limits output =
  output
    { processExitCode = ExitFailure 124
    , processStdout =
        processStdout output
          <> "\n"
          <> Text.unpack childTimeoutMarker
          <> " pulumi was stopped after "
          <> show (killableSubprocessTimeoutMicros limits `div` 1000000)
          <> " seconds"
    }

commandSuccess :: ProcessOutput -> Either String ProcessOutput
commandSuccess output = case processExitCode output of
  ExitSuccess -> Right output
  ExitFailure _ -> Left (commandFailureDetail output)

-- | The display text for a failed command: the cause and consequence first,
-- then a bounded head and tail of the transcript. Display only; no predicate
-- reads it, because a classifier must see the whole transcript.
commandFailureDetail :: ProcessOutput -> String
commandFailureDetail output =
  Text.unpack
    (renderCommandFailure (Text.pack (processStderr output)) (Text.pack (processStdout output)))

-- | The first 4096 characters of the transcript, kept as it was for the AWS
-- CLI predicates that match on it.
commandDetail :: ProcessOutput -> String
commandDetail output =
  let detail = processStderr output <> " " <> processStdout output
   in take 4096 detail

-- | The whole transcript, standard error first.
commandTranscript :: ProcessOutput -> Text
commandTranscript output =
  Text.pack (processStderr output) <> " " <> Text.pack (processStdout output)

missingStack :: ProcessOutput -> Bool
missingStack = transcriptReportsMissingStack . commandTranscript

previewReportsChanges :: ProcessOutput -> Bool
previewReportsChanges = transcriptReportsPreviewChanges . commandTranscript

containsAny :: [String] -> String -> Bool
containsAny needles haystack = any ((`Text.isInfixOf` lowered) . Text.pack) needles
 where
  lowered = Text.toLower (Text.pack haystack)

stackName :: CompiledStack -> String
stackName = Text.unpack . pulumiStackName . compiledStackPulumiRef

backendUrl :: [(String, String)] -> String
backendUrl environment = maybe "" id (lookup "PULUMI_BACKEND_URL" environment)

-- | The digest of what a command printed, as evidence. Input that is empty is
-- refused: the digest of zero bytes is one constant, so a receipt made from it
-- identifies nothing, and a producer that accepted it let three suites pass
-- on it for three days.
stackEvidence :: ProcessOutput -> Either Text Text
stackEvidence output
  | Text.null (Text.strip (Text.pack (processStdout output))) =
      Left "the command printed nothing, so a receipt made from it would be the digest of empty input"
  | otherwise =
      Right ("sha256:" <> sha256Text (TextEncoding.encodeUtf8 (Text.pack (processStdout output))))

renderBackendError :: EncryptedBackendError -> Text
renderBackendError = Text.pack . renderEncryptedBackendError

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

readProviderCredentialSession
  :: VaultSession
  -> IO (Either Text ValidatedProviderCredentialSession)
readProviderCredentialSession session = do
  observed <-
    withSessionToken session $ \token -> do
      metadataResult <-
        vaultKvReadMetadataV2
          (sessionAddress session)
          token
          "secret"
          "aws/lifecycle-provider"
      case metadataResult of
        Left err -> pure (Left err)
        Right metadata -> do
          exactResult <-
            vaultKvReadExactVersionV2
              (sessionAddress session)
              token
              "secret"
              "aws/lifecycle-provider"
              (kvV2SecretMetadataCurrentVersion metadata)
          pure ((metadata,) <$> exactResult)
  pure $ case observed of
    Left err -> Left (Text.pack (renderHttpError err))
    Right (metadata, exact) ->
      first
        (Text.pack . show)
        (validateProviderCredentialSessionInternal metadata exact)

ebsReaperMutation :: Text -> ProviderMutation IO ProviderProductionSession
ebsReaperMutation clusterName =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        observed <-
          EbsVolume.discoverEbsVolumesVia
            (boundedAwsCliRun environment)
            (EbsVolume.EbsPerRunTest (Text.unpack clusterName))
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable (Text.pack detail)
          Right [] -> ProviderEffectSatisfied "test-scoped EBS volumes are absent"
          Right _ -> ProviderEffectNeedsApply "test-scoped EBS volumes remain"
    , applyProviderMutation = \session _ -> failedApply $ do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        result <-
          EbsVolume.runTestScopedEbsReaperVia (boundedAwsCliRun environment) (Text.unpack clusterName)
        pure (either (Left . Text.pack) (const (Right ())) result)
    }

-- | Read-only, exact family observation for the lifecycle graph.  The
-- Provider session supplies the AWS account/region binding; the signed intent
-- supplies the cluster coordinate; and the evidence codec retains only the
-- bounded, client-side re-filtered volume identities.
testEbsObservation
  :: Text
  -> ProviderReadOnly IO ProviderProductionSession
testEbsObservation clusterName = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    observed <-
      EbsVolume.discoverEbsVolumesVia
        (boundedAwsCliRun environment)
        (EbsVolume.EbsPerRunTest (Text.unpack clusterName))
    pure $ case observed of
      Left detail -> Left (Text.pack detail)
      Right volumes ->
        Right
          ( EbsVolume.renderTestScopedEbsObservation
              ( EbsVolume.testScopedEbsObservation
                  (Text.unpack clusterName)
                  volumes
              )
          )

-- | Sprint 4.110: the provider-enumerated audit of one stack's declared field.
--
-- The same session checks as the native-family observation come first: the
-- credential must belong to the account and region the intent names. Every read
-- is a describe, get or list call through the bounded runner, so the audit
-- cannot change what it audits. A class a query did not answer is carried as a
-- gap in the evidence and never as an empty class.
awsAuditObservation
  :: ProviderAuditTarget
  -> ProviderStackConfig
  -> ProviderAuditControl
  -> ProviderReadOnly IO ProviderProductionSession
awsAuditObservation target config control = ProviderReadOnly $ \session _ providerBound -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  account <- providerSessionAccountId environment
  case (,) <$> account <*> providerSessionRegion environment of
    Left detail -> pure (Left detail)
    Right (accountId, regionText) ->
      case mkProviderNativeStackFamilyRef
        (providerAuditTargetStack target)
        accountId
        regionText
        (providerAuditTargetHostedZoneId target) of
        Left err -> pure (Left (Text.pack (show err)))
        Right ref -> do
          let runner = AwsNativeStackFamilyRunner (runAws environment)
          field <- auditStackField runner ref config
          case field of
            Left detail -> pure (Left detail)
            Right (stack, answers) -> do
              positive <-
                auditPositiveControl
                  runner
                  ref
                  (providerAuditControlBucket control)
                  (providerAuditControlRegion control)
              pure $ do
                observation <- first (Text.pack . show) (mkAuditObservation stack answers positive)
                encodeAwsAuditEvidence providerBound ref observation

-- | Checkpoint-independent observation of one closed registered stack family.
-- The Provider credential is independently checked against the account and
-- region signed into the intent before any family query runs.
nativeStackFamilyObservation
  :: ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> ProviderReadOnly IO ProviderProductionSession
nativeStackFamilyObservation ref _
  | Just NetworkPurgePlan <- providerNativeStackFamilyPurgeMode ref = ProviderReadOnly $ \session _ providerBound ->
      sealProviderEvidence providerBound <$> do
        observed <- observeNetworkPurgeForSession session ref
        pure (observed >>= encodeNetworkPurgeReport)
nativeStackFamilyObservation ref config = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    observed <- observeNativeStackFamilyForSession session ref config
    pure $ do
      identities <- observed
      firstShow (encodeAwsNativeStackFamilyEvidence ref identities)

nativeStackFamilyReaperMutation
  :: ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> [Text]
  -> ProviderMutation IO ProviderProductionSession
nativeStackFamilyReaperMutation ref _ []
  | Just (NetworkPurgeApply digest) <- providerNativeStackFamilyPurgeMode ref =
      ProviderMutation
        { observeProviderMutation = \session _ -> do
            observed <- observeNetworkPurgeForSession session ref
            pure $ case observed of
              Left detail -> ProviderEffectUnobservable detail
              Right plan | networkPurgeAbsent plan -> ProviderEffectSatisfied "registered EKS network families are absent"
              Right _ -> ProviderEffectNeedsApply "registered EKS network families remain"
        , applyProviderMutation = \session _ -> failedApply $ do
            environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
            binding <- validateNativeStackFamilySession environment ref
            case binding of
              Left detail -> pure (Left detail)
              Right () -> applyNetworkPurge (runAws environment) (sessionWaitEnvironment session) ref digest
        }
nativeStackFamilyReaperMutation ref config admittedIdentities =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        observed <- observeNativeStackFamilyForSession session ref config
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable detail
          Right [] -> ProviderEffectSatisfied "registered native stack family is absent"
          Right identities
            | maybe
                (all (`elem` admittedIdentities) identities)
                (const (null admittedIdentities))
                (providerNativeStackFamilyNetworkFamily ref) ->
                ProviderEffectNeedsApply "registered native stack family remains"
            | otherwise ->
                ProviderEffectUnobservable
                  "registered native stack family exceeded its manifest allowlist"
    , applyProviderMutation = \session _ -> failedApply $ do
        environment <-
          awsCliSubprocessEnvironment (productionSessionCredentials session)
        binding <- validateNativeStackFamilySession environment ref
        case binding of
          Left detail -> pure (Left detail)
          Right () ->
            reapAwsNativeStackFamilyWithin
              (AwsNativeStackFamilyRunner (runAws environment))
              (sessionWaitEnvironment session)
              ref
              config
              admittedIdentities
    }

-- Only the invocation-local scrubbed buffer can complete a plant. A restarted
-- worker may observe shapes, but cannot invent the provider errors a lost
-- invocation failed to return. Cleanup still owns those shapes in that case.
testVpcCanaryMutation
  :: ProviderNativeStackFamilyRef
  -> Canary.TestVpcCanaryRequest
  -> ProviderMutation IO ProviderProductionSession
testVpcCanaryMutation ref request =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        binding <- testCanarySessionBinding environment ref
        case binding of
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right () -> do
            observed <-
              CanaryExecution.observeTestVpcCanary (canaryRunWithinSession session environment) request
            recorded <- readIORef (productionSessionCanaryEvidence session)
            pure $ case observed of
              Left detail -> ProviderEffectUnobservable detail
              Right snapshot -> case (CanaryExecution.canaryPlantComplete snapshot, recorded) of
                (True, Just evidence) -> ProviderEffectSatisfied evidence
                _ ->
                  ProviderEffectNeedsApply
                    "the closed canary shapes and both captured dependency refusals are required"
    , applyProviderMutation = \session _ -> failedApply $ do
        modifyIORef' (productionSessionCanaryEvidence session) (const Nothing)
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        binding <- testCanarySessionBinding environment ref
        case binding of
          Left detail -> pure (Left detail)
          Right () -> do
            started <- productionSessionNowMicros session
            case started of
              Left detail -> pure (Left detail)
              Right at -> do
                probeCalls <- newIORef (at, [])
                result <-
                  CanaryExecution.plantTestVpcCanary
                    (runCanaryWithProbeCapture session environment probeCalls)
                    request
                case result of
                  Left detail -> pure (Left detail)
                  Right _ -> do
                    (_, calls) <- readIORef probeCalls
                    let transcript = Recording.ProviderTranscript Recording.LiveCanaryCapture calls
                        recorded =
                          Recording.scrubProviderRecording (canaryRecordingNames request) transcript
                            >>= Recording.canaryPlantRecordingEvidence
                    case recorded of
                      Left detail -> pure (Left detail)
                      Right evidence -> do
                        modifyIORef' (productionSessionCanaryEvidence session) (const (Just evidence))
                        pure (Right ())
    }

testCanarySessionBinding
  :: [(String, String)] -> ProviderNativeStackFamilyRef -> IO (Either Text ())
testCanarySessionBinding environment ref = case validateTestVpcCanaryRef ref of
  Left _ -> pure (Left "test canary received a reference outside the test stack")
  Right () -> validateNativeStackFamilySession environment ref

canaryRunWithinSession
  :: ProviderProductionSession -> [(String, String)] -> [String] -> IO ProcessOutput
canaryRunWithinSession session environment arguments = do
  now <- productionSessionNowMicros session
  case now
    >>= first renderSessionWindowRefusal . sessionWindowMicros (productionSessionExpiresAtMicros session) of
    Right remaining | remaining >= awsCliChildBoundMicros -> runAws environment arguments
    _ ->
      pure
        (ProcessOutput (ExitFailure 1) "" "test canary has no session window for another bounded AWS child")

runCanaryWithProbeCapture
  :: ProviderProductionSession
  -> [(String, String)]
  -> IORef (Natural, [Recording.ProviderRecordedCall])
  -> [String]
  -> IO ProcessOutput
runCanaryWithProbeCapture session environment probeCalls arguments = do
  started <- productionSessionNowMicros session
  output <- canaryRunWithinSession session environment arguments
  case (take 2 arguments, started) of
    (["ec2", "delete-security-group"], Right at) -> do
      (previous, calls) <- readIORef probeCalls
      let label = case length calls of
            0 -> "delete-security-group:held"
            1 -> "delete-security-group:left"
            _ -> "unexpected-additional-probe"
          call =
            Recording.ProviderRecordedCall
              { Recording.recordedOperation = label
              , Recording.recordedDelayMicros = at - min at previous
              , Recording.recordedExitCode = case processExitCode output of
                  ExitSuccess -> 0
                  ExitFailure code -> code
              , Recording.recordedStdout = Text.pack (processStdout output)
              , Recording.recordedStderr = Text.pack (processStderr output)
              }
      modifyIORef' probeCalls (const (at, calls ++ [call]))
    _ -> pure ()
  pure output

canaryRecordingNames :: Canary.TestVpcCanaryRequest -> [(Text, Text)]
canaryRecordingNames request =
  Map.toList $
    Map.fromList
      ( [ (Canary.testCanaryRunScope binding, "recording-cleanup-run")
        , (Canary.testCanaryStackRunScope binding, "recording-stack-run")
        , (Canary.testCanaryStackSubmission binding, "recording-stack-submission")
        , (Canary.canaryInterfaceDescription binding, "recording-canary-interface")
        ]
          ++ [(Canary.canaryGroupName binding shape, "recording-canary-group") | shape <- [minBound .. maxBound]]
      )
 where
  binding = Canary.testCanaryBinding request

observeNativeStackFamilyForSession
  :: ProviderProductionSession
  -> ProviderNativeStackFamilyRef
  -> ProviderStackConfig
  -> IO (Either Text [Text])
observeNativeStackFamilyForSession session ref config = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  binding <- validateNativeStackFamilySession environment ref
  case binding of
    Left detail -> pure (Left detail)
    Right () ->
      observeAwsNativeStackFamily
        (AwsNativeStackFamilyRunner (runAws environment))
        ref
        config

observeNetworkPurgeForSession
  :: ProviderProductionSession -> ProviderNativeStackFamilyRef -> IO (Either Text NetworkPurgePlan)
observeNetworkPurgeForSession session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  binding <- validateNativeStackFamilySession environment ref
  case binding of
    Left detail -> pure (Left detail)
    Right () -> observeNetworkPurgePlan (runAws environment) ref

validateNativeStackFamilySession
  :: [(String, String)]
  -> ProviderNativeStackFamilyRef
  -> IO (Either Text ())
validateNativeStackFamilySession environment ref = do
  account <- providerSessionAccountId environment
  pure $ do
    accountId <- account
    region <- providerSessionRegion environment
    if accountId == providerNativeStackFamilyAccountId ref
      then Right ()
      else Left "Provider credential account does not equal the native stack-family account"
    if region == providerNativeStackFamilyRegion ref
      then Right ()
      else Left "Provider credential region does not equal the native stack-family region"

-- | Sprint 7.36 exact IAM family. The signed intent carries the canonical
-- registry projections, and this boundary independently checks them before it
-- reaches IAM. An Authority submission therefore cannot widen the family by
-- composing another role name under the same allowlist key.
eksIamRoleFamilyObservation
  :: Text
  -> Text
  -> ProviderReadOnly IO ProviderProductionSession
eksIamRoleFamilyObservation roleNames policyNames =
  ProviderReadOnly $ \session _ providerBound -> do
    observed <- observeEksIamRoleFamily session roleNames policyNames
    pure $ do
      (rows, _) <- observed
      first
        renderProviderEvidenceRefusal
        (encodeProviderEvidence providerBound eksIamRoleFamilyEvidenceFamily rows)

eksIamRoleFamilyReaperMutation
  :: Text
  -> Text
  -> ProviderMutation IO ProviderProductionSession
eksIamRoleFamilyReaperMutation roleNames policyNames =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        observed <- observeEksIamRoleFamily session roleNames policyNames
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable detail
          Right (_, True) -> ProviderEffectSatisfied "registered EKS IAM family is absent"
          Right (_, False) -> ProviderEffectNeedsApply "registered EKS IAM family remains"
    , applyProviderMutation = \session _ ->
        failedApply (reapEksIamRoleFamily session roleNames policyNames)
    }

observeEksIamRoleFamily
  :: ProviderProductionSession
  -> Text
  -> Text
  -> IO (Either Text ([[Text]], Bool))
observeEksIamRoleFamily session roleNames policyNames =
  case validateEksIamFamilyProjection roleNames policyNames of
    Left detail -> pure (Left detail)
    Right (roles, policies) -> do
      environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
      account <- providerSessionAccountId environment
      case account of
        Left detail -> pure (Left detail)
        Right accountId -> do
          roleRows <- traverse (observeRole environment) roles
          policyRows <- traverse (observePolicy environment accountId) policies
          pure $ do
            exactRoles <- sequence roleRows
            exactPolicies <- sequence policyRows
            let rows = exactRoles ++ exactPolicies
            Right (map fst rows, all snd rows)
 where
  observeRole environment roleName = do
    output <-
      runAws
        environment
        ["iam", "get-role", "--role-name", Text.unpack roleName, "--output", "json"]
    pure $ case processExitCode output of
      ExitSuccess -> do
        root <- decodeObject (processStdout output)
        role <- requireObjectField "Role" root
        returnedName <- requireTextField "RoleName" role
        arn <- requireTextField "Arn" role
        if returnedName == roleName
          then Right (["role", roleName, "present", arn], False)
          else Left "IAM get-role returned another role name"
      ExitFailure _
        | awsOutputIsNoSuchEntity output ->
            Right (["role", roleName, "absent"], True)
        | otherwise -> Left (awsOutputFailure "IAM get-role" output)

  observePolicy environment accountId policyName = do
    let arn = iamManagedPolicyArn accountId policyName
    output <-
      runAws
        environment
        ["iam", "get-policy", "--policy-arn", Text.unpack arn, "--output", "json"]
    pure $ case processExitCode output of
      ExitSuccess -> do
        root <- decodeObject (processStdout output)
        policy <- requireObjectField "Policy" root
        returnedName <- requireTextField "PolicyName" policy
        returnedArn <- requireTextField "Arn" policy
        if returnedName == policyName && returnedArn == arn
          then Right (["policy", policyName, "present", arn], False)
          else Left "IAM get-policy returned another managed policy"
      ExitFailure _
        | awsOutputIsNoSuchEntity output ->
            Right (["policy", policyName, "absent"], True)
        | otherwise -> Left (awsOutputFailure "IAM get-policy" output)

reapEksIamRoleFamily
  :: ProviderProductionSession
  -> Text
  -> Text
  -> IO (Either Text ())
reapEksIamRoleFamily session roleNames policyNames =
  case validateEksIamFamilyProjection roleNames policyNames of
    Left detail -> pure (Left detail)
    Right (roles, policies) -> do
      environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
      roleResults <- traverse (deleteRoleAndAttachments environment) roles
      case sequence roleResults of
        Left detail -> pure (Left detail)
        Right _ -> do
          account <- providerSessionAccountId environment
          case account of
            Left detail -> pure (Left detail)
            Right accountId -> do
              policyResults <-
                traverse (deleteManagedPolicy environment accountId) policies
              pure (sequence_ policyResults)

deleteRoleAndAttachments :: [(String, String)] -> Text -> IO (Either Text ())
deleteRoleAndAttachments environment roleName = do
  attached <-
    listIamObjectTextFieldAllowMissing
      environment
      ["iam", "list-attached-role-policies", "--role-name", Text.unpack roleName]
      "AttachedPolicies"
      "PolicyArn"
  inline <-
    listIamTextFieldAllowMissing
      environment
      ["iam", "list-role-policies", "--role-name", Text.unpack roleName]
      "PolicyNames"
  profiles <-
    listIamObjectTextFieldAllowMissing
      environment
      ["iam", "list-instance-profiles-for-role", "--role-name", Text.unpack roleName]
      "InstanceProfiles"
      "InstanceProfileName"
  case (attached, inline, profiles) of
    (Right policyArns, Right inlineNames, Right profileNames) -> do
      detached <-
        traverse
          ( \policyArn ->
              runIamVoidAllowMissing
                environment
                [ "iam"
                , "detach-role-policy"
                , "--role-name"
                , Text.unpack roleName
                , "--policy-arn"
                , Text.unpack policyArn
                ]
          )
          policyArns
      deletedInline <-
        traverse
          ( \policyName ->
              runIamVoidAllowMissing
                environment
                [ "iam"
                , "delete-role-policy"
                , "--role-name"
                , Text.unpack roleName
                , "--policy-name"
                , Text.unpack policyName
                ]
          )
          inlineNames
      removedProfiles <-
        traverse
          ( \profileName ->
              runIamVoidAllowMissing
                environment
                [ "iam"
                , "remove-role-from-instance-profile"
                , "--instance-profile-name"
                , Text.unpack profileName
                , "--role-name"
                , Text.unpack roleName
                ]
          )
          profileNames
      case sequence (detached ++ deletedInline ++ removedProfiles) of
        Left detail -> pure (Left detail)
        Right _ ->
          runIamVoidAllowMissing
            environment
            ["iam", "delete-role", "--role-name", Text.unpack roleName]
    (Left detail, _, _) -> pure (Left detail)
    (_, Left detail, _) -> pure (Left detail)
    (_, _, Left detail) -> pure (Left detail)

deleteManagedPolicy
  :: [(String, String)] -> Text -> Text -> IO (Either Text ())
deleteManagedPolicy environment accountId policyName = do
  let arn = iamManagedPolicyArn accountId policyName
  versions <-
    listIamPolicyVersionsAllowMissing environment arn
  case versions of
    Left detail -> pure (Left detail)
    Right versionIds -> do
      deleted <-
        traverse
          ( \versionId ->
              runIamVoidAllowMissing
                environment
                [ "iam"
                , "delete-policy-version"
                , "--policy-arn"
                , Text.unpack arn
                , "--version-id"
                , Text.unpack versionId
                ]
          )
          versionIds
      case sequence deleted of
        Left detail -> pure (Left detail)
        Right _ ->
          runIamVoidAllowMissing
            environment
            ["iam", "delete-policy", "--policy-arn", Text.unpack arn]

validateEksIamFamilyProjection
  :: Text -> Text -> Either Text ([Text], [Text])
validateEksIamFamilyProjection roleNames policyNames = do
  let expectedRoles = TeardownRegistry.awsEksIamRoleNames
      expectedPolicies = TeardownRegistry.awsEksIamManagedPolicyNames
      actualRoles = Text.splitOn "|" roleNames
      actualPolicies = Text.splitOn "|" policyNames
  if actualRoles == expectedRoles
    then Right ()
    else Left "EKS IAM role family does not equal the registered coordinate"
  if actualPolicies == expectedPolicies
    then Right ()
    else Left "EKS IAM managed-policy family does not equal the registered coordinate"
  if length actualRoles == length (nub actualRoles)
    && length actualPolicies == length (nub actualPolicies)
    && all (not . Text.null) (actualRoles ++ actualPolicies)
    then Right (actualRoles, actualPolicies)
    else Left "EKS IAM family contains an empty or duplicate member"

-- | Exact controller-family observation. The deterministic name prevents a
-- family scan, while the complete registered tag projection is verified on
-- the load balancer and every attached security group before any ARN is
-- returned as lifecycle evidence.
eksLoadBalancerControllerFamilyObservation
  :: Text
  -> Text
  -> ProviderReadOnly IO ProviderProductionSession
eksLoadBalancerControllerFamilyObservation loadBalancerName tags =
  ProviderReadOnly $ \session _ providerBound -> do
    observed <-
      observeEksLoadBalancerControllerFamily session loadBalancerName tags
    pure $ do
      (rows, _) <- observed
      first
        renderProviderEvidenceRefusal
        ( encodeProviderEvidence
            providerBound
            eksLoadBalancerControllerFamilyEvidenceFamily
            rows
        )

eksLoadBalancerControllerFamilyReaperMutation
  :: Text
  -> Text
  -> ProviderMutation IO ProviderProductionSession
eksLoadBalancerControllerFamilyReaperMutation loadBalancerName tags =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        observed <-
          observeEksLoadBalancerControllerFamily session loadBalancerName tags
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable detail
          Right (_, True) ->
            ProviderEffectSatisfied
              "registered EKS load-balancer controller family is absent"
          Right (_, False) ->
            ProviderEffectNeedsApply
              "registered EKS load-balancer controller family remains"
    , applyProviderMutation = \session _ ->
        failedApply (reapEksLoadBalancerControllerFamily session loadBalancerName tags)
    }

observeEksLoadBalancerControllerFamily
  :: ProviderProductionSession
  -> Text
  -> Text
  -> IO (Either Text ([[Text]], Bool))
observeEksLoadBalancerControllerFamily session loadBalancerName tags =
  case validateEksLoadBalancerControllerFamilyProjection loadBalancerName tags of
    Left detail -> pure (Left detail)
    Right expectedTags -> do
      environment <-
        awsCliSubprocessEnvironment (productionSessionCredentials session)
      output <-
        runAws
          environment
          [ "elbv2"
          , "describe-load-balancers"
          , "--names"
          , Text.unpack loadBalancerName
          , "--output"
          , "json"
          ]
      case processExitCode output of
        ExitFailure _
          | awsOutputIsElbv2NotFound output -> pure (Right ([], True))
          | otherwise ->
              pure (Left (awsOutputFailure "ELBv2 describe-load-balancers" output))
        ExitSuccess -> case decodeLoadBalancerRoot (processStdout output) of
          Left detail -> pure (Left detail)
          Right (loadBalancerArn, securityGroupIds) -> do
            tagsMatch <-
              observeElbv2Tags environment loadBalancerArn expectedTags
            listeners <-
              observeElbv2ArnArray
                environment
                [ "elbv2"
                , "describe-listeners"
                , "--load-balancer-arn"
                , Text.unpack loadBalancerArn
                ]
                "Listeners"
                "ListenerArn"
            targetGroups <-
              observeElbv2ArnArray
                environment
                [ "elbv2"
                , "describe-target-groups"
                , "--load-balancer-arn"
                , Text.unpack loadBalancerArn
                ]
                "TargetGroups"
                "TargetGroupArn"
            securityGroups <-
              traverse
                (observeOwnedSecurityGroup environment expectedTags)
                securityGroupIds
            account <- providerSessionAccountId environment
            pure $ do
              exactTagsMatch <- tagsMatch
              if exactTagsMatch
                then Right ()
                else Left "load balancer omitted its registered ownership tags"
              exactListeners <- listeners
              exactTargetGroups <- targetGroups
              exactSecurityGroups <- sequence securityGroups
              accountId <- account
              region <- providerSessionRegion environment
              let securityGroupArns =
                    map (securityGroupArn accountId region) exactSecurityGroups
                  rows =
                    [["load-balancer", loadBalancerArn]]
                      ++ map (\arn -> ["listener", arn]) exactListeners
                      ++ map (\arn -> ["target-group", arn]) exactTargetGroups
                      ++ map (\arn -> ["security-group", arn]) securityGroupArns
              Right (rows, False)

reapEksLoadBalancerControllerFamily
  :: ProviderProductionSession
  -> Text
  -> Text
  -> IO (Either Text ())
reapEksLoadBalancerControllerFamily session =
  reapEksLoadBalancerControllerFamilyWithin session (sessionWaitEnvironment session)

-- | The same reaper, waiting under the environment it is given: a caller that
-- keeps part of the session for work after it hands one that ends sooner.
reapEksLoadBalancerControllerFamilyWithin
  :: ProviderProductionSession
  -> AwsWaitEnvironment IO
  -> Text
  -> Text
  -> IO (Either Text ())
reapEksLoadBalancerControllerFamilyWithin session waits loadBalancerName tags = do
  observed <-
    observeEksLoadBalancerControllerFamily session loadBalancerName tags
  case observed of
    Left detail -> pure (Left detail)
    Right (_, True) -> pure (Right ())
    Right (observedRows, False) -> do
      environment <-
        awsCliSubprocessEnvironment (productionSessionCredentials session)
      case traverse lbcFamilyMember observedRows of
        Left detail -> pure (Left detail)
        Right rows -> do
          listeners <-
            traverse
              (runElbv2VoidAllowMissing environment . deleteListenerArguments)
              (membersOfKind "listener" rows)
          case sequence listeners of
            Left detail -> pure (Left detail)
            Right _ -> do
              loadBalancers <-
                traverse
                  (runElbv2VoidAllowMissing environment . deleteLoadBalancerArguments)
                  (membersOfKind "load-balancer" rows)
              case sequence loadBalancers of
                Left detail -> pure (Left detail)
                Right _ -> do
                  targetGroups <-
                    traverse
                      (runElbv2VoidAllowMissing environment . deleteTargetGroupArguments)
                      (membersOfKind "target-group" rows)
                  case sequence targetGroups of
                    Left detail -> pure (Left detail)
                    Right _ ->
                      deleteSecurityGroupsWithin
                        (runAws environment)
                        waits
                        (map securityGroupIdFromArn (membersOfKind "security-group" rows))
 where
  deleteListenerArguments arn =
    ["elbv2", "delete-listener", "--listener-arn", Text.unpack arn]
  deleteLoadBalancerArguments arn =
    ["elbv2", "delete-load-balancer", "--load-balancer-arn", Text.unpack arn]
  deleteTargetGroupArguments arn =
    ["elbv2", "delete-target-group", "--target-group-arn", Text.unpack arn]

-- | The registered load balancer family's tags as the family's request spells
-- them, which is the form its validation accepts and nothing else.
eksLoadBalancerControllerFamilyTags :: Text
eksLoadBalancerControllerFamilyTags =
  Text.intercalate
    "|"
    [key <> "=" <> value | (key, value) <- TeardownRegistry.awsEksLoadBalancerControllerTags]

validateEksLoadBalancerControllerFamilyProjection
  :: Text -> Text -> Either Text [(Text, Text)]
validateEksLoadBalancerControllerFamilyProjection loadBalancerName rawTags = do
  if loadBalancerName == TeardownRegistry.awsEksLoadBalancerControllerName
    then Right ()
    else
      Left
        "EKS load-balancer name does not equal the registered coordinate"
  actualTags <- traverse parseTag (Text.splitOn "|" rawTags)
  if actualTags == TeardownRegistry.awsEksLoadBalancerControllerTags
    && actualTags == sort actualTags
    && length (map fst actualTags) == length (nub (map fst actualTags))
    then Right actualTags
    else
      Left
        "EKS load-balancer tags do not equal the registered coordinate"
 where
  parseTag raw = case Text.breakOn "=" raw of
    (key, valueWithSeparator)
      | Just value <- Text.stripPrefix "=" valueWithSeparator
      , not (Text.null key)
      , not (Text.null value) ->
          Right (key, value)
    _ -> Left "EKS load-balancer tag projection was malformed"

decodeLoadBalancerRoot :: String -> Either Text (Text, [Text])
decodeLoadBalancerRoot payload = do
  root <- decodeObject payload
  values <- requireArrayField "LoadBalancers" root
  case values of
    [Object loadBalancer] -> do
      arn <- requireTextField "LoadBalancerArn" loadBalancer
      securityGroups <- requireTextArrayField "SecurityGroups" loadBalancer
      Right (arn, securityGroups)
    _ -> Left "ELBv2 exact-name observation did not return exactly one load balancer"

observeElbv2Tags
  :: [(String, String)] -> Text -> [(Text, Text)] -> IO (Either Text Bool)
observeElbv2Tags environment resourceArn expected = do
  output <-
    runAws
      environment
      [ "elbv2"
      , "describe-tags"
      , "--resource-arns"
      , Text.unpack resourceArn
      , "--output"
      , "json"
      ]
  pure $ case processExitCode output of
    ExitFailure _ -> Left (awsOutputFailure "ELBv2 describe-tags" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      descriptions <- requireArrayField "TagDescriptions" root
      case descriptions of
        [Object description] -> do
          returnedArn <- requireTextField "ResourceArn" description
          tagValues <- requireArrayField "Tags" description
          parsed <- traverse parseAwsTag tagValues
          if returnedArn == resourceArn
            then Right (all (`elem` parsed) expected)
            else Left "ELBv2 tag observation returned another resource ARN"
        _ -> Left "ELBv2 tag observation did not return exactly one description"

observeElbv2ArnArray
  :: [(String, String)]
  -> [String]
  -> Text
  -> Text
  -> IO (Either Text [Text])
observeElbv2ArnArray environment arguments arrayName arnField = do
  output <- runAws environment (arguments ++ ["--output", "json"])
  pure $ case processExitCode output of
    ExitFailure _ -> Left (awsOutputFailure "ELBv2 family observation" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      values <- requireArrayField arrayName root
      traverse requireMemberArn values
 where
  requireMemberArn value = case value of
    Object member -> requireTextField (Key.fromText arnField) member
    _ -> Left "ELBv2 family member was not an object"

observeOwnedSecurityGroup
  :: [(String, String)]
  -> [(Text, Text)]
  -> Text
  -> IO (Either Text Text)
observeOwnedSecurityGroup environment expectedTags groupId = do
  output <-
    runAws
      environment
      [ "ec2"
      , "describe-security-groups"
      , "--group-ids"
      , Text.unpack groupId
      , "--output"
      , "json"
      ]
  pure $ case processExitCode output of
    ExitFailure _ -> Left (awsOutputFailure "EC2 describe-security-groups" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      values <- requireArrayField "SecurityGroups" root
      case values of
        [Object securityGroup] -> do
          returnedId <- requireTextField "GroupId" securityGroup
          tagValues <- requireArrayField "Tags" securityGroup
          parsed <- traverse parseAwsTag tagValues
          if returnedId == groupId && all (`elem` parsed) expectedTags
            then Right returnedId
            else
              Left
                "load-balancer security group omitted its exact identity or ownership tags"
        _ -> Left "EC2 exact security-group observation returned another cardinality"

parseAwsTag :: Value -> Either Text (Text, Text)
parseAwsTag value = case value of
  Object tag -> (,) <$> requireTextField "Key" tag <*> requireTextField "Value" tag
  _ -> Left "AWS tag row was not an object"

providerSessionRegion :: [(String, String)] -> Either Text Text
providerSessionRegion environment =
  case lookup "AWS_REGION" environment of
    Just region | not (null region) -> Right (Text.pack region)
    _ -> Left "Provider session omitted its exact AWS region"

securityGroupArn :: Text -> Text -> Text -> Text
securityGroupArn accountId region groupId =
  "arn:aws:ec2:"
    <> region
    <> ":"
    <> accountId
    <> ":security-group/"
    <> groupId

securityGroupIdFromArn :: Text -> Text
securityGroupIdFromArn arn =
  maybe arn id (Text.stripPrefix "security-group/" (snd (Text.breakOnEnd ":" arn)))

-- | One member of the controller family, from the rows the observation
-- returned.  Sprint @4.99@.
--
-- This replaces @parseLbcFamilyRows@, which re-parsed the rendered evidence a
-- second time to decide what the reaper would delete.  That second parser was
-- the hidden seam in this family: it selected ARNs for deletion, and a kind it
-- failed to recognise silently deleted nothing of that kind rather than
-- refusing.  The reaper now reads the same rows the encoder was handed, so
-- there is no second grammar to drift.
lbcFamilyMember :: [Text] -> Either Text (Text, Text)
lbcFamilyMember row = case row of
  [kind, arn]
    | kind `elem` ["load-balancer", "listener", "target-group", "security-group"]
    , not (Text.null arn) ->
        Right (kind, arn)
  _ -> Left "EKS load-balancer controller evidence row was malformed"

membersOfKind :: Text -> [(Text, Text)] -> [Text]
membersOfKind expected = map snd . filter ((== expected) . fst)

runElbv2VoidAllowMissing
  :: [(String, String)] -> [String] -> IO (Either Text ())
runElbv2VoidAllowMissing environment arguments = do
  output <- runAws environment arguments
  pure $ case processExitCode output of
    ExitSuccess -> Right ()
    ExitFailure _
      | awsOutputIsElbv2NotFound output -> Right ()
      | otherwise -> Left (awsOutputFailure "ELBv2 mutation" output)

awsOutputIsElbv2NotFound :: ProcessOutput -> Bool
awsOutputIsElbv2NotFound output =
  containsAny
    ["loadbalancernotfound", "listenernotfound", "targetgroupnotfound"]
    (processStderr output <> processStdout output)

providerSessionAccountId :: [(String, String)] -> IO (Either Text Text)
providerSessionAccountId environment = do
  output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
  pure $ do
    root <-
      first
        (const (awsOutputFailure "STS get-caller-identity" output))
        (decodeObject (processStdout output))
    requireTextField "Account" root

iamManagedPolicyArn :: Text -> Text -> Text
iamManagedPolicyArn accountId policyName =
  "arn:aws:iam::" <> accountId <> ":policy/" <> policyName

listIamTextFieldAllowMissing
  :: [(String, String)] -> [String] -> Text -> IO (Either Text [Text])
listIamTextFieldAllowMissing environment arguments fieldName = do
  output <- runAws environment (arguments ++ ["--output", "json"])
  pure $ case processExitCode output of
    ExitFailure _
      | awsOutputIsNoSuchEntity output -> Right []
      | otherwise -> Left (awsOutputFailure "IAM list" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      values <- requireArrayField fieldName root
      traverse requireString values

listIamObjectTextFieldAllowMissing
  :: [(String, String)]
  -> [String]
  -> Text
  -> Text
  -> IO (Either Text [Text])
listIamObjectTextFieldAllowMissing environment arguments arrayName fieldName = do
  output <- runAws environment (arguments ++ ["--output", "json"])
  pure $ case processExitCode output of
    ExitFailure _
      | awsOutputIsNoSuchEntity output -> Right []
      | otherwise -> Left (awsOutputFailure "IAM list" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      values <- requireArrayField arrayName root
      traverse requireRowField values
 where
  requireRowField value = case value of
    Object objectValue -> requireTextField (Key.fromText fieldName) objectValue
    _ -> Left ("IAM " <> arrayName <> " row was not an object")

listIamPolicyVersionsAllowMissing
  :: [(String, String)] -> Text -> IO (Either Text [Text])
listIamPolicyVersionsAllowMissing environment policyArn = do
  output <-
    runAws
      environment
      ["iam", "list-policy-versions", "--policy-arn", Text.unpack policyArn, "--output", "json"]
  pure $ case processExitCode output of
    ExitFailure _
      | awsOutputIsNoSuchEntity output -> Right []
      | otherwise -> Left (awsOutputFailure "IAM list-policy-versions" output)
    ExitSuccess -> do
      root <- decodeObject (processStdout output)
      values <- requireArrayField "Versions" root
      fmap concat $ traverse nonDefaultVersion values
 where
  nonDefaultVersion value = case value of
    Object objectValue -> do
      versionId <- requireTextField "VersionId" objectValue
      case KeyMap.lookup "IsDefaultVersion" objectValue of
        Just (Bool True) -> Right []
        Just (Bool False) -> Right [versionId]
        _ -> Left "IAM policy version omitted IsDefaultVersion"
    _ -> Left "IAM policy version row was not an object"

requireArrayField :: Text -> KeyMap.KeyMap Value -> Either Text [Value]
requireArrayField fieldName objectValue =
  case KeyMap.lookup (Key.fromText fieldName) objectValue of
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left ("AWS response omitted array field " <> fieldName)

requireString :: Value -> Either Text Text
requireString value = case value of
  String textValue -> Right textValue
  _ -> Left "AWS response array contained a non-string value"

runIamVoidAllowMissing
  :: [(String, String)] -> [String] -> IO (Either Text ())
runIamVoidAllowMissing environment arguments = do
  output <- runAws environment arguments
  pure $ case processExitCode output of
    ExitSuccess -> Right ()
    ExitFailure _
      | awsOutputIsNoSuchEntity output -> Right ()
      | otherwise -> Left (awsOutputFailure "IAM mutation" output)

awsOutputIsNoSuchEntity :: ProcessOutput -> Bool
awsOutputIsNoSuchEntity output =
  "NoSuchEntity" `Text.isInfixOf` Text.pack (processStderr output <> processStdout output)

awsOutputFailure :: Text -> ProcessOutput -> Text
awsOutputFailure label output =
  Text.take
    1024
    ( label
        <> " failed: "
        <> Text.pack (processStderr output <> processStdout output)
    )

-- | Sprint 7.36: read-only observation of the @dns-aws@ validation hosted-zone
-- family, through the Provider Worker's own session credentials.
--
-- The family is the registered zone-name prefix and nothing else, and the
-- discovery it runs filters by that same constant, so the registry and the
-- observation cannot disagree about which zones are in scope. A listing this
-- run cannot obtain is unobservable rather than empty — the doctrine rule that
-- an unanswerable query is never an absence.
validationHostedZoneObservation
  :: Text
  -> ProviderReadOnly IO ProviderProductionSession
validationHostedZoneObservation namePrefix = ProviderReadOnly $ \session _ providerBound -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  observed <-
    Route53ValidationZone.discoverValidationHostedZones (boundedAwsCliText environment)
  pure $ case observed of
    Left detail -> Left (Text.pack detail)
    Right zones ->
      first
        renderProviderEvidenceRefusal
        ( encodeProviderEvidence
            providerBound
            validationHostedZoneEvidenceFamily
            ( ["family", namePrefix]
                : [ ["zone", Text.pack zoneId, Text.pack zoneName]
                  | (zoneId, zoneName) <- zones
                  ]
            )
        )

-- | Sprint 7.36: the destroy half of the same family.
--
-- Observe-before-apply, so an already-absent family is satisfied without a
-- mutation, and a listing that cannot be obtained refuses rather than reporting
-- absence.
validationHostedZoneReaperMutation
  :: Text -> ProviderMutation IO ProviderProductionSession
validationHostedZoneReaperMutation _namePrefix =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        observed <-
          Route53ValidationZone.discoverValidationHostedZones (boundedAwsCliText environment)
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable (Text.pack detail)
          Right [] ->
            ProviderEffectSatisfied "validation hosted zones are absent"
          Right _ -> ProviderEffectNeedsApply "validation hosted zones remain"
    , applyProviderMutation = \session _ -> failedApply $ do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        result <-
          Route53ValidationZone.destroyValidationHostedZones (boundedAwsCliText environment)
        pure $ case result of
          ExitSuccess -> Right ()
          ExitFailure code ->
            Left
              ( Text.pack
                  ("validation hosted-zone reap exited " <> show code)
              )
    }

-- | Sprint 7.36: the DNS01 challenge record family inside one retained hosted
-- zone.
--
-- Read-only, and it is the whole Provider half of the family: the removal is a
-- Kubernetes owner delete, because cert-manager's solver would rewrite a record
-- the Provider deleted underneath it.
--
-- The scan is 'NativeRoute53.scanResourceRecordSetsByPrefix' rather than an
-- exact lookup, because a cleanup proving a __family__ absent has no names for
-- its members; it follows the truncation cursor to exhaustion and fails at its
-- page bound rather than returning a prefix, so a short answer cannot read as
-- absence.
dns01ChallengeRecordObservation
  :: Text
  -> Text
  -> ProviderReadOnly IO ProviderProductionSession
dns01ChallengeRecordObservation zoneId recordNamePrefix =
  ProviderReadOnly
    (\session _ providerBound -> scanDns01ChallengeRecords providerBound zoneId recordNamePrefix session)

scanDns01ChallengeRecords
  :: ProviderEvidenceBound
  -> Text
  -> Text
  -> ProviderProductionSession
  -> IO (Either Text ProviderEvidence)
scanDns01ChallengeRecords providerBound zoneId recordNamePrefix session =
  case route53ClientForSession session of
    Left detail -> pure (Left detail)
    Right client -> do
      scanned <-
        NativeRoute53.scanResourceRecordSetsByPrefix
          client
          zoneId
          recordNamePrefix
          NativeRoute53.RecordTXT
      pure (renderDns01ChallengeEvidence providerBound zoneId recordNamePrefix scanned)

-- | The canonical evidence form: the echoed family line, then one record name
-- per line.  The reader is
-- 'Prodbox.Lifecycle.Teardown.Dns01ChallengeRecordAdapter.parseDns01ChallengeObservation'.
renderDns01ChallengeEvidence
  :: ProviderEvidenceBound
  -> Text
  -> Text
  -> Either AwsClientError [NativeRoute53.ResourceRecordSet]
  -> Either Text ProviderEvidence
renderDns01ChallengeEvidence providerBound zoneId recordNamePrefix scanned = case scanned of
  Left err -> Left (nativeRoute53Error err)
  Right recordSets ->
    first
      renderProviderEvidenceRefusal
      ( encodeProviderEvidence
          providerBound
          dns01ChallengeRecordEvidenceFamily
          ( ["family", zoneId, recordNamePrefix]
              : [["record", NativeRoute53.rrsName recordSet] | recordSet <- recordSets]
          )
      )

-- | Sprint 5.50: the @dns-aws@ validation's throwaway hosted zone, through the
-- Provider rather than the host.
--
-- The host holds no AWS credential, so the validation that created this zone
-- inline could not run at all. The zone name and the caller reference are both
-- derived here from the nonce by the registered validation-zone owner; an
-- intent supplies a nonce and a base name, never a name to create. Satisfied
-- means the zone exists /and/ reads back every owned tag, because a zone an
-- interrupted create left untagged is invisible to the terminal audit.
validationHostedZoneEnsureMutation
  :: Text -> Text -> ProviderMutation IO ProviderProductionSession
validationHostedZoneEnsureMutation nonce baseZone =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeValidationZone session nonce baseZone
    , applyProviderMutation = \session _ ->
        failedApply $ case validationZoneNames nonce baseZone of
          Left detail -> pure (Left detail)
          Right (zoneName, callerReference, baseName) -> do
            environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
            discovered <-
              Route53ValidationZone.discoverValidationHostedZones (boundedAwsCliText environment)
            case discovered of
              Left detail -> pure (Left (Text.pack detail))
              Right zones -> case zoneIdNamed zoneName zones of
                Just zoneId ->
                  first Text.pack
                    <$> Route53ValidationZone.tagValidationHostedZone
                      (boundedAwsCliText environment)
                      zoneId
                Nothing -> createBeneathExistingZone environment zoneName callerReference baseName
    }

-- | Create the zone only beneath a zone that already exists in this account.
--
-- A create names a zone the caller derived from its own nonce and base name.
-- Requiring the base to be an existing hosted zone keeps an intent from
-- minting a billable public zone under a name nobody here owns.
createBeneathExistingZone
  :: [(String, String)] -> String -> String -> String -> IO (Either Text ())
createBeneathExistingZone environment zoneName callerReference baseName = do
  everyZone <- Route53ValidationZone.discoverAllHostedZones (boundedAwsCliText environment)
  case everyZone of
    Left detail -> pure (Left (Text.pack detail))
    Right zones -> case zoneIdNamed baseName zones of
      Nothing ->
        pure (Left ("the base hosted zone " <> Text.pack baseName <> " does not exist in this account"))
      Just _ ->
        fmap
          (first Text.pack . Control.Monad.void)
          ( Route53ValidationZone.createValidationHostedZone
              (boundedAwsCliText environment)
              zoneName
              callerReference
          )

observeValidationZone
  :: ProviderProductionSession -> Text -> Text -> IO ProviderEffectObservation
observeValidationZone session nonce baseZone =
  case validationZoneNames nonce baseZone of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right (zoneName, _, _) -> do
      environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
      discovered <-
        Route53ValidationZone.discoverValidationHostedZones (boundedAwsCliText environment)
      case discovered of
        Left detail -> pure (ProviderEffectUnobservable (Text.pack detail))
        Right zones -> case zoneIdNamed zoneName zones of
          Nothing -> pure (ProviderEffectNeedsApply "validation hosted zone is absent")
          Just zoneId -> do
            tagged <-
              Route53ValidationZone.validationHostedZoneOwnedTagsPresent
                (boundedAwsCliText environment)
                zoneId
            pure $ case tagged of
              Left detail -> ProviderEffectUnobservable (Text.pack detail)
              Right True -> ProviderEffectSatisfied (validationZoneEvidence zoneId)
              Right False -> ProviderEffectNeedsApply (validationZoneEvidence zoneId)

-- | The zone name and caller reference one nonce and base name derive, after
-- both are checked to be what the registered owner would itself create.
validationZoneNames :: Text -> Text -> Either Text (String, String, String)
validationZoneNames nonce baseZone
  | Text.null nonce
      || Text.length nonce > 32
      || not (Text.all (\character -> isAsciiLower character || isDigit character) nonce) =
      Left "validation hosted-zone nonce is not a short lowercase alphanumeric token"
  | not (validDnsName baseZone) =
      Left "validation hosted-zone base name is not a valid DNS name"
  | otherwise =
      Right
        ( Route53ValidationZone.validationHostedZoneName nonceText baseText
        , Route53ValidationZone.validationHostedZoneCallerReference nonceText
        , baseText
        )
 where
  nonceText = Text.unpack nonce
  baseText = Text.unpack (Text.dropWhileEnd (== '.') baseZone)

-- | A dotted DNS name in lowercase letters, digits and hyphens, no label empty
-- or edged with a hyphen, with an optional trailing dot.
validDnsName :: Text -> Bool
validDnsName raw =
  not (Text.null trimmed)
    && Text.length trimmed <= 190
    && all validLabel (Text.splitOn "." trimmed)
 where
  trimmed = Text.dropWhileEnd (== '.') raw
  validLabel label =
    not (Text.null label)
      && Text.length label <= 63
      && Text.all (\character -> isAsciiLower character || isDigit character || character == '-') label
      && Text.head label /= '-'
      && Text.last label /= '-'

-- | The id of the listed zone whose name is exactly the wanted one, which
-- Route 53 reports with a trailing dot.
zoneIdNamed :: String -> [(String, String)] -> Maybe String
zoneIdNamed wanted zones =
  case [zoneId | (zoneId, name) <- zones, name == wanted || name == wanted <> "."] of
    zoneId : _ -> Just zoneId
    [] -> Nothing

validationZoneEvidence :: String -> Text
validationZoneEvidence zoneId =
  "validation-zone:" <> Text.pack (Route53ValidationZone.bareHostedZoneId zoneId)

-- | Read one recipient's captured mail through the fenced runner. Only the
-- invocation receiver can open the evidence retained by the Authority.
sesInviteMailObservation
  :: Text -> Text -> InviteMailPublicKey -> ProviderReadOnly IO ProviderProductionSession
sesInviteMailObservation bucket recipient destination = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    guarded <- requireSesInviteTarget environment bucket recipient
    case guarded of
      Left detail -> pure (Left detail)
      Right () ->
        InviteDelivery.observeCapturedInviteEvidence
          (captureRunner environment)
          destination
          bucket
          recipient

-- | The Provider's bounded AWS CLI invocation, in the shape the capture reader
-- takes, so every capture call carries the child-process permit and bound.
captureRunner :: [(String, String)] -> SesCapture.CaptureRunner
captureRunner environment =
  SesCapture.CaptureRunner
    { SesCapture.runCaptureAws = runAws environment
    , SesCapture.captureNow = getPOSIXTime
    }

-- | The bucket must carry the SES capture-bucket owned tags, and the recipient
-- must be a validation recipient, before anything is read or deleted.
requireSesInviteTarget
  :: [(String, String)] -> Text -> Text -> IO (Either Text ())
requireSesInviteTarget environment bucket recipient
  | not (validBucketName bucket) = pure (Left "SES invite bucket is not a valid bucket name")
  | not (validRecipient recipient) = pure (Left "SES invite recipient is not a single mail address")
  | otherwise = do
      tagging <-
        runAws
          environment
          ["s3api", "get-bucket-tagging", "--bucket", Text.unpack bucket, "--output", "json"]
      pure $ case observedSesCaptureBucketTagging tagging of
        Left detail -> Left detail
        Right True -> Right ()
        Right False ->
          Left "the named bucket is not the SES capture bucket: it lacks the capture-bucket owned tags"
 where
  validBucketName name =
    Text.length name >= 3
      && Text.length name <= 63
      && Text.all
        (\character -> isAsciiLower character || isDigit character || character == '.' || character == '-')
        name
      && Text.head name /= '-'
  -- The shape the invite validation addresses: @test-\<hex nonce>\@\<domain>@.
  -- Narrower than a mail address on purpose: the same predicate decides what a
  -- reap deletes from a bucket that also holds mail nobody here sent.
  validRecipient address =
    case Text.splitOn "@" address of
      [localPart, domain] ->
        Text.length address <= 254
          && Text.isPrefixOf "test-" localPart
          && validNonceToken (Text.drop 5 localPart)
          && validDnsName domain
      _ -> False
  validNonceToken token =
    not (Text.null token)
      && Text.length token <= 32
      && Text.all (\character -> isAsciiLower character || isDigit character) token

-- | Sprint 5.50: the retained EBS volumes the AWS substrate's PersistentVolumes
-- bind to, created through the Provider because the host holds no credential
-- and the substrate platform used to invoke an ambient @aws@ directly.
--
-- The required volumes travel as @name:size-gib:zone@ entries joined by commas
-- and are checked here, never taken as an argument vector. Satisfied means every
-- required volume exists exactly once, in the required zone, and is attachable;
-- the evidence is one line of @name=volume-id=zone@ bindings.
retainedEbsEnsureMutation
  :: Text -> Text -> ProviderMutation IO ProviderProductionSession
retainedEbsEnsureMutation volumeType specs =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeRetainedEbsEnsure session volumeType specs
    , applyProviderMutation = \session _ ->
        failedApply $ case parseRetainedEbsEnsure volumeType specs of
          Left detail -> pure (Left detail)
          Right (typed, required) -> do
            environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
            ensured <-
              EbsVolume.ensureRetainedEbsVolumesVia
                (boundedAwsCliRun environment)
                (sessionWaitEnvironment session)
                typed
                required
            pure (first Text.pack (Control.Monad.void ensured))
    }

observeRetainedEbsEnsure
  :: ProviderProductionSession -> Text -> Text -> IO ProviderEffectObservation
observeRetainedEbsEnsure session volumeType specs =
  case parseRetainedEbsEnsure volumeType specs of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right (_, required) -> do
      environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
      discovered <-
        EbsVolume.discoverEbsVolumesVia (boundedAwsCliRun environment) (EbsVolume.EbsRetainedProduction)
      pure (retainedEbsEnsureObservation required discovered)

retainedEbsEnsureObservation
  :: [EbsVolume.EbsRequiredVolume]
  -> Either String [EbsVolume.EbsVolume]
  -> ProviderEffectObservation
retainedEbsEnsureObservation required discovered = case discovered of
  Left detail -> ProviderEffectUnobservable (Text.pack detail)
  Right volumes
    | not (null (EbsVolume.missingRequiredVolumes required volumes)) ->
        ProviderEffectNeedsApply
          "retained EBS volumes are missing from the listing (a volume created moments ago can lag it: confirm whether it exists before creating it again)"
    | otherwise ->
        case EbsVolume.retainedEbsVolumeBindingsFromDiscovered required volumes of
          Left detail -> ProviderEffectUnobservable (Text.pack detail)
          Right bindings -> ProviderEffectSatisfied (retainedEbsBindingsEvidence bindings)

parseRetainedEbsEnsure
  :: Text -> Text -> Either Text (AwsEbsVolumeType, [EbsVolume.EbsRequiredVolume])
parseRetainedEbsEnsure volumeType specs = do
  typed <-
    first
      (Text.pack . renderAwsSubstrateProfileError)
      (mkAwsEbsVolumeType volumeType)
  entries <- traverse parseEntry (Text.splitOn "," specs)
  let names = map EbsVolume.ebsRequiredPersistentVolumeName entries
  if null entries || length entries > 64
    then Left "retained EBS ensure names no volume, or more than 64"
    else
      if length (nub names) /= length names
        then Left "retained EBS ensure names the same volume twice"
        else Right (typed, entries)
 where
  parseEntry entry = case Text.splitOn ":" entry of
    [name, sizeText, zone]
      | validVolumeName name
          && not (Text.null sizeText)
          && Text.length sizeText <= 5
          && Text.all isDigit sizeText
          && validZone zone ->
          let size = read (Text.unpack sizeText) :: Int
           in if size >= 1 && size <= 16384
                then
                  Right
                    EbsVolume.EbsRequiredVolume
                      { EbsVolume.ebsRequiredPersistentVolumeName = Text.unpack name
                      , EbsVolume.ebsRequiredSizeGiB = size
                      , EbsVolume.ebsRequiredAvailabilityZone = Text.unpack zone
                      }
                else Left "retained EBS volume size is outside 1..16384 GiB"
    _ -> Left "retained EBS volume entry is not name:size-gib:zone"
  validVolumeName name =
    not (Text.null name)
      && Text.length name <= 128
      && Text.all
        (\character -> isAsciiLower character || isDigit character || character == '-' || character == '.')
        name
  validZone zone =
    Text.length zone >= 3
      && Text.length zone <= 32
      && Text.all (\character -> isAsciiLower character || isDigit character || character == '-') zone

-- | One line of bindings. @=@ cannot occur in a validated name, volume id or
-- zone, so the line splits back without ambiguity.
retainedEbsBindingsEvidence :: [StaticEbsVolumeBinding] -> Text
retainedEbsBindingsEvidence bindings =
  "retained-ebs-bindings:"
    <> Text.intercalate
      ","
      [ Text.pack (staticEbsVolumeBindingPersistentVolumeName binding)
          <> "="
          <> Text.pack (staticEbsVolumeBindingVolumeHandle binding)
          <> "="
          <> Text.pack (staticEbsVolumeBindingAvailabilityZone binding)
      | binding <- bindings
      ]

spotPriceObservation
  :: ProviderSpotPriceQuery
  -> ProviderReadOnly IO ProviderProductionSession
spotPriceObservation query = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    output <-
      runAws
        environment
        [ "ec2"
        , "describe-spot-price-history"
        , "--instance-types"
        , Text.unpack (providerSpotPriceInstanceType query)
        , "--product-descriptions"
        , Text.unpack (providerSpotPriceProductDescription query)
        , "--max-results"
        , "1"
        , "--output"
        , "json"
        ]
    pure $ do
      successful <- firstText (Text.pack . processStdout <$> commandSuccess output)
      extractSpotPrice successful

extractSpotPrice :: Text -> Either Text Text
extractSpotPrice payload = case eitherDecodeStrict' (TextEncoding.encodeUtf8 payload) of
  Right (Object root) -> case KeyMap.lookup "SpotPriceHistory" root of
    Just (Array history) -> case Vector.toList history of
      Object entry : _ -> case KeyMap.lookup "SpotPrice" entry of
        Just (String price) | not (Text.null (Text.strip price)) -> Right ("spot-price:" <> price)
        _ -> Left "spot price response has no price"
      _ -> Left "spot price response has no history"
    Just _ -> Left "spot price response history is invalid"
    Nothing -> Left "spot price response has no history"
  _ -> Left "spot price response is invalid JSON"

operationalIdentityObservation :: ProviderReadOnly IO ProviderProductionSession
operationalIdentityObservation = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
    pure $ do
      successful <- firstText (processStdout <$> commandSuccess output)
      root <- decodeObject successful
      arn <- requireTextField "Arn" root
      renderStsIdentityEvidence arn

-- | Exact account/region observation for lifecycle admission.  Account comes
-- only from a successful STS response under the scoped Provider session;
-- region comes from the same session's sealed Vault credentials.  The hidden
-- codec emits neither credentials nor the raw STS response.
providerAwsScopeObservation :: ProviderReadOnly IO ProviderProductionSession
providerAwsScopeObservation = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    let credentials = productionSessionCredentials session
    environment <- awsCliSubprocessEnvironment credentials
    output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
    pure $ do
      successful <- firstText (processStdout <$> commandSuccess output)
      root <- decodeObject successful
      account <- requireTextField "Account" root
      first
        (Text.pack . show)
        (encodeProviderAwsScopeEvidence account (region credentials))

readinessObservation
  :: ProviderReadinessProbe
  -> ProviderReadOnly IO ProviderProductionSession
readinessObservation probe = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    case probe of
      ProviderReadinessStsIdentity -> do
        output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
        pure $ do
          _ <- firstText (commandSuccess output)
          ("provider-readiness:" <>) <$> stackEvidence output
      ProviderReadinessRoute53Zone zoneId -> do
        output <-
          runAws environment ["route53", "get-hosted-zone", "--id", Text.unpack zoneId, "--output", "json"]
        pure $ do
          payload <- firstText (processStdout <$> commandSuccess output)
          if length payload > 2400
            then Left "Route 53 hosted-zone observation exceeds the evidence bound"
            else
              Right
                ( "provider-readiness-route53-json:"
                    <> TextEncoding.decodeUtf8
                      (Base64.encode (TextEncoding.encodeUtf8 (Text.pack payload)))
                )

-- | Exact EKS control-plane identity observation.  Only a successful
-- DescribeCluster response can produce an ARN.  Absence is recognized from
-- the exact AWS CLI error grammar for this named request; every other failure
-- remains unobservable at the Provider boundary.
eksClusterIdentityObservation
  :: EksClusterIdentityRequest
  -> ProviderReadOnly IO ProviderProductionSession
eksClusterIdentityObservation request = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    let credentials = productionSessionCredentials session
        requestedAccount = eksClusterIdentityRequestAccountId request
        requestedRegion = eksClusterIdentityRequestRegion request
        requestedCluster = eksClusterIdentityRequestClusterName request
    if Text.strip (region credentials) /= requestedRegion
      then pure (Left "EKS identity request region does not match the Provider session")
      else do
        environment <- awsCliSubprocessEnvironment credentials
        identityOutput <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
        clusterOutput <-
          runAws
            environment
            [ "eks"
            , "describe-cluster"
            , "--region"
            , Text.unpack requestedRegion
            , "--name"
            , Text.unpack requestedCluster
            , "--output"
            , "json"
            ]
        pure $ do
          identity <- firstText (processStdout <$> commandSuccess identityOutput) >>= decodeObject
          account <- requireTextField "Account" identity
          if account == requestedAccount
            then Right ()
            else Left "EKS identity request account does not match the Provider session"
          case commandSuccess clusterOutput of
            Left _
              | exactEksClusterNotFound requestedCluster clusterOutput ->
                  Right "registered EKS cluster is absent"
              | otherwise -> Left (Text.pack (commandDetail clusterOutput))
            Right successful -> do
              clusterRoot <- decodeObject (processStdout successful)
              cluster <- requireObjectField "cluster" clusterRoot
              clusterName <- requireTextField "name" cluster
              clusterArn <- requireTextField "arn" cluster
              if clusterName == requestedCluster
                then Right ()
                else Left "EKS describe-cluster returned the wrong cluster identity"
              firstShow
                ( validateEksClusterArnBinding
                    account
                    requestedRegion
                    requestedCluster
                    clusterArn
                )
              Right ("eks-cluster-arn:" <> clusterArn)

exactEksClusterNotFound :: Text -> ProcessOutput -> Bool
exactEksClusterNotFound clusterName output =
  processExitCode output /= ExitSuccess
    && Text.null (Text.strip (Text.pack (processStdout output)))
    && Text.strip (Text.pack (processStderr output))
      == ( "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: "
             <> "No cluster found for name: "
             <> clusterName
             <> "."
         )

eksClientAuthObservation
  :: EksClientAuthRequest
  -> ProviderReadOnly IO ProviderProductionSession
eksClientAuthObservation request = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    let credentials = productionSessionCredentials session
        requestedRegion = eksClientAuthRequestRegion request
        requestedCluster = eksClientAuthRequestClusterName request
    if Text.strip (region credentials) /= requestedRegion
      then pure (Left "EKS client-auth request region does not match the Provider session")
      else do
        environment <- awsCliSubprocessEnvironment credentials
        identityOutput <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
        clusterOutput <-
          runAws
            environment
            [ "eks"
            , "describe-cluster"
            , "--region"
            , Text.unpack requestedRegion
            , "--name"
            , Text.unpack requestedCluster
            , "--output"
            , "json"
            ]
        tokenOutput <-
          runAws
            environment
            [ "eks"
            , "get-token"
            , "--region"
            , Text.unpack requestedRegion
            , "--cluster-name"
            , Text.unpack requestedCluster
            , "--output"
            , "json"
            ]
        now <- floor <$> getPOSIXTime
        case parseProjection now identityOutput clusterOutput tokenOutput of
          Left detail -> pure (Left detail)
          Right (projection, publicKey) -> do
            sealed <- sealEksClientAuthProjection publicKey projection
            pure $ do
              envelope <- firstShow sealed
              Right
                ( eksClientAuthEvidenceMarker
                    <> TextEncoding.decodeUtf8 (Base64.encode (encodeEksClientAuthEnvelope envelope))
                )
 where
  parseProjection now identityOutput clusterOutput tokenOutput = do
    identity <- firstText (processStdout <$> commandSuccess identityOutput) >>= decodeObject
    account <- requireTextField "Account" identity
    if account == eksClientAuthRequestAccountId request
      then Right ()
      else Left "EKS client-auth request account does not match the Provider session"
    clusterRoot <- firstText (processStdout <$> commandSuccess clusterOutput) >>= decodeObject
    cluster <- requireObjectField "cluster" clusterRoot
    clusterName <- requireTextField "name" cluster
    clusterArn <- requireTextField "arn" cluster
    endpoint <- requireTextField "endpoint" cluster
    certificateAuthority <- requireObjectField "certificateAuthority" cluster
    certificateAuthorityData <- requireTextField "data" certificateAuthority
    if clusterName == eksClientAuthRequestClusterName request
      then Right ()
      else Left "EKS describe-cluster returned the wrong cluster identity"
    tokenRoot <- firstText (processStdout <$> commandSuccess tokenOutput) >>= decodeObject
    status <- requireObjectField "status" tokenRoot
    bearer <- requireTextField "token" status
    expirationTimestamp <- requireTextField "expirationTimestamp" status
    expires <- parseEksTokenExpiration expirationTimestamp
    if expires <= now || expires > now + 900
      then Left "EKS client-auth bearer expiration is outside the short-lived bound"
      else Right ()
    projection <-
      firstShow
        ( mkEksClientAuthProjection
            account
            (eksClientAuthRequestRegion request)
            (eksClientAuthRequestClusterName request)
            clusterArn
            endpoint
            certificateAuthorityData
            bearer
            expires
        )
    publicKey <-
      firstShow
        (mkEksClientAuthPublicKey (eksClientAuthRequestDestinationPublicKey request))
    Right (projection, publicKey)

parseEksTokenExpiration :: Text -> Either Text Integer
parseEksTokenExpiration raw =
  case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (Text.unpack raw) :: Maybe UTCTime of
    Nothing -> Left "EKS get-token returned an invalid expirationTimestamp"
    Just value -> Right (floor (utcTimeToPOSIXSeconds value))

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = either (Left . Text.pack . show) Right

-- | Physical bounds for every AWS CLI child started by the Provider Worker.
--
-- The 30-second lifetime is the same deadline compiled into the Provider
-- runtime-memory child schedule, and the one every wait's per-poll child
-- maximum is checked against ('awsCliChildBoundMicros'). Output ceilings are
-- deliberately wider than any accepted Provider evidence while still
-- preventing a child from growing the parent heap without bound.
providerAwsCliLimits :: BoundedSubprocessLimits
providerAwsCliLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 4 * 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 1024 * 1024
    , boundedSubprocessTimeoutMicros = fromIntegral awsCliChildBoundMicros
    }

-- | The Provider process owns one physical subprocess lane shared by its four
-- request workers and independent readiness observer. The top-level cell is
-- process-local and deliberately non-reentrant: AWS and Pulumi launch sites are
-- both leaves, so no permitted action attempts to acquire it twice.
{-# NOINLINE providerChildProcessPermit #-}
providerChildProcessPermit :: MVar ()
providerChildProcessPermit = unsafePerformIO (newMVar ())

withProviderChildProcessPermit :: IO value -> IO value
withProviderChildProcessPermit =
  withMVar providerChildProcessPermit . const

runAws :: [(String, String)] -> [String] -> IO ProcessOutput
runAws environment arguments = do
  result <- withProviderChildProcessPermit $ do
    captureSubprocessBounded
      providerAwsCliLimits
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Right output -> output
    Left detail -> ProcessOutput (ExitFailure 1) "" (Text.unpack (errorMsg detail))

-- | Sprint 5.53: the EBS interpreters start the AWS CLI through 'runAws', so
-- they carry the child-process permit and the same physical bounds as every
-- other AWS child the Provider starts. A process that cannot start is already
-- folded into 'runAws'' output, so this runner never answers 'Failure'.
boundedAwsCliRun :: [(String, String)] -> EbsVolume.AwsCliRun
boundedAwsCliRun environment arguments = Success <$> runAws environment arguments

-- | Sprint 5.53: the owned-tag listing runs each page through the same runner,
-- so a Tagging API call that never answers is a failure after the bound and not
-- a Provider request held open without one.
boundedTaggedPageRunner :: TaggedResourceQuery.TaggedPageRunner
boundedTaggedPageRunner subprocess =
  Success
    <$> runAws
      (fromMaybe [] (subprocessEnvironment subprocess))
      (subprocessArguments subprocess)

-- | Sprint 5.53: the same runner, in the shape the Route 53 validation-zone
-- interpreters take: standard output, or why the invocation failed.
boundedAwsCliText :: [(String, String)] -> Route53ValidationZone.AwsCliText
boundedAwsCliText environment arguments =
  Route53ValidationZone.awsCliTextFromOutput arguments <$> runAws environment arguments

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right

scratchCheckpointMutation
  :: ProviderCheckpointRef
  -> ProviderMutation IO ProviderProductionSession
scratchCheckpointMutation checkpointRef =
  ProviderMutation
    { observeProviderMutation = observeScratchCheckpoint checkpointRef
    , applyProviderMutation = \session coordinate ->
        failedApply (applyScratchCheckpoint checkpointRef session coordinate)
    }

observeScratchCheckpoint
  :: ProviderCheckpointRef
  -> ProviderProductionSession
  -> ProviderIntentCoordinate
  -> IO ProviderEffectObservation
observeScratchCheckpoint checkpointRef session _ =
  case checkpointStackFor checkpointRef of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right stackRef -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      observed <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          stackRef
          environment
          verifyScratchEnvironment
      pure $ case observed of
        Left err -> ProviderEffectUnobservable (renderBackendError err)
        Right () -> ProviderEffectSatisfied "checkpoint hydrated into bounded RAM scratch"

applyScratchCheckpoint
  :: ProviderCheckpointRef
  -> ProviderProductionSession
  -> ProviderIntentCoordinate
  -> IO (Either Text ())
applyScratchCheckpoint checkpointRef session _ =
  case checkpointStackFor checkpointRef of
    Left detail -> pure (Left detail)
    Right stackRef -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          stackRef
          environment
          verifyScratchEnvironment
      pure (either (Left . renderBackendError) (const (Right ())) result)

checkpointStackFor :: ProviderCheckpointRef -> Either Text PulumiStackRef
checkpointStackFor checkpointRef =
  case providerCheckpointRefText checkpointRef of
    "aws-eks" -> Right (PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test")
    "aws-eks-subzone" -> Right (PulumiStackRef "prodbox-aws-eks-subzone" "aws-eks-subzone")
    "aws-test" -> Right (PulumiStackRef "prodbox-aws-test" "aws-test")
    _ -> Left "checkpoint is not in the compiled Provider scratch registry"

verifyScratchEnvironment :: [(String, String)] -> IO (Either String ())
verifyScratchEnvironment environment =
  pure $ case lookup "PULUMI_BACKEND_URL" environment of
    Just value
      | "file://" `Text.isPrefixOf` Text.pack value -> Right ()
    _ -> Left "Authority checkpoint hydration did not supply a RAM file backend"

sesIdentityMutation :: SesIdentityRef -> ProviderMutation IO ProviderProductionSession
sesIdentityMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesIdentity session ref
    , applyProviderMutation = \session _ ->
        failedApply $
          applySingleAwsCommand
            session
            ["ses", "verify-domain-identity", "--domain", Text.unpack (sesIdentityRefText ref)]
    }

observeSesIdentity
  :: ProviderProductionSession
  -> SesIdentityRef
  -> IO ProviderEffectObservation
observeSesIdentity session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <-
    runAws
      environment
      [ "ses"
      , "get-identity-verification-attributes"
      , "--identities"
      , Text.unpack (sesIdentityRefText ref)
      , "--output"
      , "json"
      ]
  pure $ case commandSuccess output of
    Left detail -> ProviderEffectUnobservable (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> ProviderEffectUnobservable detail
      Right root -> case KeyMap.lookup "VerificationAttributes" root of
        Just (Object attributes) ->
          case KeyMap.lookup (Key.fromText (sesIdentityRefText ref)) attributes of
            Nothing -> ProviderEffectNeedsApply "SES sending identity is absent"
            Just (Object identity)
              | Just (String token) <- KeyMap.lookup "VerificationToken" identity
              , not (Text.null (Text.strip token)) ->
                  ProviderEffectSatisfied (providerAwsEvidence "ses-identity" [output])
            _ -> ProviderEffectUnobservable "SES sending identity response is malformed"
        _ -> ProviderEffectUnobservable "SES verification attributes are missing"

sesDkimMutation :: SesIdentityRef -> ProviderMutation IO ProviderProductionSession
sesDkimMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesDkim session ref
    , applyProviderMutation = \session _ ->
        failedApply $
          applySingleAwsCommand
            session
            ["ses", "verify-domain-dkim", "--domain", Text.unpack (sesIdentityRefText ref)]
    }

observeSesDkim
  :: ProviderProductionSession
  -> SesIdentityRef
  -> IO ProviderEffectObservation
observeSesDkim session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <-
    runAws
      environment
      [ "ses"
      , "get-identity-dkim-attributes"
      , "--identities"
      , Text.unpack (sesIdentityRefText ref)
      , "--output"
      , "json"
      ]
  pure $ case commandSuccess output of
    Left detail -> ProviderEffectUnobservable (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> ProviderEffectUnobservable detail
      Right root -> case KeyMap.lookup "DkimAttributes" root of
        Just (Object attributes) ->
          case KeyMap.lookup (Key.fromText (sesIdentityRefText ref)) attributes of
            Nothing -> ProviderEffectNeedsApply "SES DKIM identity is absent"
            Just (Object identity)
              | Just (Array tokens) <- KeyMap.lookup "DkimTokens" identity
              , not (Vector.null tokens)
              , all nonEmptyString (Vector.toList tokens) ->
                  ProviderEffectSatisfied (providerAwsEvidence "ses-dkim" [output])
            _ -> ProviderEffectUnobservable "SES DKIM response is malformed"
        _ -> ProviderEffectUnobservable "SES DKIM attributes are missing"

-- | Exact Route 53 ownership for the SES identity and receive lane. Pulumi is
-- deliberately absent from this mutation: the signed intent fixes the zone
-- and names, while the sealed Provider credential fixes the regional inbound
-- endpoint.
sesDnsMutation :: SesDnsRef -> ProviderMutation IO ProviderProductionSession
sesDnsMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesDns session ref
    , applyProviderMutation = \session _ -> failedApply (applySesDns session ref)
    }

publicARecordObservation
  :: PublicARecordRef -> ProviderReadOnly IO ProviderProductionSession
publicARecordObservation ref = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    observed <- observePublicARecord session ref
    pure $ case observed of
      ProviderEffectSatisfied evidence -> Right evidence
      ProviderEffectNeedsApply evidence -> Right evidence
      ProviderEffectUnobservable detail -> Left detail

publicARecordMutation
  :: PublicARecordRef -> ProviderMutation IO ProviderProductionSession
publicARecordMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observePublicARecord session ref
    , applyProviderMutation = \session _ -> failedApply (applyPublicARecord session ref)
    }

observePublicARecord
  :: ProviderProductionSession -> PublicARecordRef -> IO ProviderEffectObservation
observePublicARecord session ref = case route53ClientForSession session of
  Left detail -> pure (ProviderEffectUnobservable detail)
  Right client -> do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        (publicARecordHostedZoneId ref)
        (publicARecordFqdn ref)
        NativeRoute53.RecordA
    pure $ case observed of
      Left err -> ProviderEffectUnobservable (nativeRoute53Error err)
      Right Nothing -> ProviderEffectNeedsApply "public-a-values:"
      Right (Just record) ->
        let values = NativeRoute53.rrsRecords record
            evidence = "public-a-values:" <> Text.intercalate "," values
         in if NativeRoute53.rrsTtl record == fromIntegral (publicARecordTtl ref)
              && values == publicARecordValues ref
              then ProviderEffectSatisfied evidence
              else ProviderEffectNeedsApply evidence

-- | Sprint 4.72: the public A record is written through the typed DNS program.
--
-- The superseded body called @changeResourceRecordSets@ directly, so it carried
-- no owner value at all — and until this sprint __@DnsRecordProgram@ had no
-- production caller whatsoever__, which makes the claim it exists to support
-- narrower than it looked: it was exercised only by two unit suites. Routing
-- this writer through it is what makes the program load-bearing for the first
-- time, the same defect shape Sprint @1.82@ closed for the Tier-0 secret guard.
--
-- The coordinate's two non-request facts are __observed rather than asserted__.
-- The AWS account comes from @sts get-caller-identity@ — the account this
-- process is actually acting in — and the ownership epoch from the retained
-- Authority epoch the role already reads. Carrying either in the intent would
-- let a request /claim/ an account; observing them proves one.
applyPublicARecord
  :: ProviderProductionSession -> PublicARecordRef -> IO (Either Text ())
applyPublicARecord session ref = case route53ClientForSession session of
  Left detail -> pure (Left detail)
  Right client -> do
    prepared <- preparePublicARecordProgram session ref
    case prepared of
      Left detail -> pure (Left detail)
      Right (coordinate, values) -> do
        outcome <-
          runDnsRecordProgram
            (publicARecordDnsBoundary client coordinate ref)
            coordinate
            (EnsureDnsRecord providerDnsOwnerAuthority values)
        pure (publicARecordProgramOutcome outcome)

-- | The per-run public A-record authority this role holds.
--
-- @dnsOwnerAuthorityForProcess@ is total over @RuntimeRole \u00d7 Substrate@ and
-- the table decides which lanes the pair holds, so the Provider Worker cannot
-- name a lane it does not own — naming an owner and holding one are different
-- things ("Prodbox.Lifecycle.DnsRecord.Owner").
providerDnsOwnerAuthority :: DnsOwnerAuthority
providerDnsOwnerAuthority = heldDnsOwnerAuthority AwsLifecycleProviderDnsOwner

-- | The long-lived SES authority this role holds.
--
-- Sprint @4.73@: a separate lane rather than a second use of the one above,
-- because an owner decides the lifecycle class and the admissible record types,
-- and the SES records differ from the public A record on both.
sesDnsOwnerAuthority :: DnsOwnerAuthority
sesDnsOwnerAuthority = heldDnsOwnerAuthority AwsSesDnsOwner

heldDnsOwnerAuthority :: DnsRecordOwner -> DnsOwnerAuthority
heldDnsOwnerAuthority owner =
  case dnsOwnerAuthorityForProcess ProviderWorkerRuntime SubstrateAws owner of
    Just authority -> authority
    Nothing ->
      -- Unreachable: the minter's table is written out pair by pair and both
      -- lanes this module names are listed beside this pair. Adding a role or a
      -- substrate is a compile error there, not a silent `Nothing` here.
      error ("the Provider Worker holds no AWS DNS ownership for " <> show owner)

preparePublicARecordProgram
  :: ProviderProductionSession
  -> PublicARecordRef
  -> IO (Either Text (DnsRecordCoordinate, DnsRecordSet))
preparePublicARecordProgram session ref = do
  accountResult <- observeProviderAwsAccountId session
  case accountResult of
    Left detail -> pure (Left detail)
    Right account -> do
      epochResult <- productionSessionAuthorityEpoch session
      pure $ do
        epoch <- epochResult
        zone <- coordinateError (mkHostedZoneId (publicARecordHostedZoneId ref))
        coordinate <-
          coordinateError
            ( mkPublicARecordCoordinate
                account
                zone
                (publicARecordFqdn ref)
                (authorizedDnsOwner providerDnsOwnerAuthority)
                (mkOwnershipEpoch epoch)
            )
        values <- publicARecordValueSet (publicARecordTtl ref) (publicARecordValues ref)
        pure (coordinate, values)

publicARecordValueSet :: Natural -> [Text] -> Either Text DnsRecordSet
publicARecordValueSet ttl rawValues = do
  parsed <- traverse (coordinateError . mkDnsRecordValue DnsRecordA) rawValues
  case NonEmpty.nonEmpty parsed of
    Nothing -> Left "public A record intent carries no address"
    Just values -> coordinateError (mkDnsRecordSet ttl values)

coordinateError :: Either DnsCoordinateError value -> Either Text value
coordinateError = first (Text.pack . show)

-- | The Route 53 side of the program: one exact coordinate, observed and
-- mutated through the same client. @destroy@ is a real delete rather than a
-- refusal, because a boundary whose destroy cannot act would make the program's
-- absence read-back untestable against this lane.
publicARecordDnsBoundary
  :: NativeRoute53.Route53Client
  -> DnsRecordCoordinate
  -> PublicARecordRef
  -> DnsRecordBoundary IO
publicARecordDnsBoundary client coordinate ref =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = observe
    , dnsBoundaryEnsure = change NativeRoute53.Upsert
    , dnsBoundaryDestroy = change NativeRoute53.DeleteRecord
    }
 where
  zone = publicARecordHostedZoneId ref
  name = publicARecordFqdn ref

  observe = do
    observed <-
      NativeRoute53.listExactResourceRecordSet client zone name NativeRoute53.RecordA
    pure $ case observed of
      Left err -> DnsRecordUnobservable (nativeRoute53Error err)
      Right Nothing -> DnsRecordMissing
      Right (Just record) ->
        case publicARecordValueSet
          (fromIntegral (NativeRoute53.rrsTtl record))
          (NativeRoute53.rrsRecords record) of
          Left detail -> DnsRecordUnobservable detail
          Right values -> DnsRecordObserved values

  -- Sprint 4.73: the wire shape comes from the one shared renderer rather than
  -- a copy assembled here, so the name and type this lane writes are the
  -- coordinate's by construction.
  change action values = do
    changed <-
      NativeRoute53.changeResourceRecordSets
        client
        zone
        [(action, nativeDnsRecordSet coordinate values)]
    case changed of
      Left err -> pure (Left (nativeRoute53Error err))
      Right (changeId, status) -> awaitRoute53Change client changeId status

-- | Every arm is named. A refusal that reached this lane as a bare @Left@ would
-- lose which of the program's five distinct refusals occurred, and two of them
-- — an unauthorized owner and a coordinate mismatch — are the whole point of
-- routing through it.
publicARecordProgramOutcome :: DnsProgramResult -> Either Text ()
publicARecordProgramOutcome result = case result of
  DnsEnsureAlreadyConverged -> Right ()
  DnsEnsureAppliedAndReadBack -> Right ()
  DnsDestroyAlreadyAbsent -> Left "public A record ensure answered a destroy result"
  DnsDestroyAppliedAndReadBack -> Left "public A record ensure answered a destroy result"
  DnsProgramOwnerMismatch expected actual ->
    Left
      ( "public A record coordinate owner mismatch: expected "
          <> Text.pack (show expected)
          <> ", bound to "
          <> Text.pack (show actual)
      )
  DnsProgramOwnerUnauthorized held bound ->
    Left
      ( "this process holds "
          <> Text.pack (show held)
          <> " and the public A record coordinate is owned by "
          <> Text.pack (show bound)
      )
  DnsProgramCoordinateMismatch _ _ ->
    Left "public A record boundary is bound to a different coordinate"
  DnsProgramInitialObservationRefused observation ->
    Left ("public A record is unobservable before mutation: " <> Text.pack (show observation))
  DnsProgramMutationFailed detail _ -> Left detail
  DnsProgramPostconditionFailed observation ->
    Left ("public A record read-back did not converge: " <> Text.pack (show observation))

-- | The AWS account this Provider session is acting in, observed rather than
-- carried. A request that names its own account is an assertion; @sts
-- get-caller-identity@ is evidence.
observeProviderAwsAccountId
  :: ProviderProductionSession -> IO (Either Text AwsAccountId)
observeProviderAwsAccountId session = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
  pure $ case commandSuccess output of
    Left detail -> Left (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> Left detail
      Right root -> case KeyMap.lookup "Account" root of
        Just (String account) -> coordinateError (mkAwsAccountId account)
        _ -> Left "aws sts get-caller-identity returned no Account field"

data SesDnsInputs = SesDnsInputs
  { sesDnsVerificationToken :: !Text
  , sesDnsDkimTokens :: ![Text]
  }

observeSesDns
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO ProviderEffectObservation
observeSesDns session ref = do
  inputsResult <- readSesDnsInputs session ref
  case inputsResult of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right Nothing ->
      pure
        ( ProviderEffectNeedsApply
            "SES identity or DKIM tokens are absent before DNS reconciliation"
        )
    Right (Just inputs) ->
      case sesDnsRecordPlans session inputs of
        Left detail -> pure (ProviderEffectUnobservable detail)
        Right plans -> observeSesDnsRecords session ref plans

-- | Sprint 4.73: the SES DNS records are written through the typed DNS program,
-- under an owner this process holds.
--
-- Sprint 4.72 routed the public A record the same way and measured why this
-- lane was not the same rerouting. Each of the three reasons is answered here
-- rather than deferred again:
--
--   * It writes three record types where @DnsRecordType@ defined two.
--     @DnsRecordCname@ and @DnsRecordMx@ now exist with their own canonical
--     value forms, and @ownerAcceptsType@ is total over the whole matrix, so
--     the SES lane's admissible types are a decision per pair rather than a
--     wildcard @False@.
--   * It wrote five records in one batched change with one propagation wait. A
--     coordinate is one name and one type, so the program necessarily submits
--     five changes; @ensureSesDnsLanes@ submits them all before awaiting any,
--     which keeps the propagation windows overlapping the way the batch's did.
--   * Its desired values are not known until the SES identity exists.
--     @ensureSesDnsInputs@ therefore still runs first and the coordinates are
--     built from its result, so the program's ensure always begins from a
--     conclusive observation.
applySesDns
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text ())
applySesDns session ref = do
  inputsResult <- ensureSesDnsInputs session ref
  case inputsResult >>= sesDnsRecordPlans session of
    Left detail -> pure (Left detail)
    Right plans ->
      case route53ClientForSession session of
        Left detail -> pure (Left detail)
        Right client -> do
          prepared <- prepareSesDnsLanes session ref plans
          case prepared of
            Left detail -> pure (Left detail)
            Right lanes -> ensureSesDnsLanes client (sesDnsHostedZoneId ref) lanes

ensureSesDnsInputs
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text SesDnsInputs)
ensureSesDnsInputs session ref = do
  existing <- readSesDnsInputs session ref
  case existing of
    Left detail -> pure (Left detail)
    Right (Just inputs) -> pure (Right inputs)
    Right Nothing -> do
      identityResult <-
        applySingleAwsCommand
          session
          [ "ses"
          , "verify-domain-identity"
          , "--domain"
          , Text.unpack (sesDnsIdentityDomain ref)
          ]
      case identityResult of
        Left detail -> pure (Left detail)
        Right () -> do
          dkimResult <-
            applySingleAwsCommand
              session
              [ "ses"
              , "verify-domain-dkim"
              , "--domain"
              , Text.unpack (sesDnsIdentityDomain ref)
              ]
          case dkimResult of
            Left detail -> pure (Left detail)
            Right () -> do
              refreshed <- readSesDnsInputs session ref
              pure $ case refreshed of
                Left detail -> Left detail
                Right Nothing ->
                  Left "SES identity or DKIM tokens remained absent after reconcile"
                Right (Just inputs) -> Right inputs

readSesDnsInputs
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text (Maybe SesDnsInputs))
readSesDnsInputs session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  identityOutput <-
    runAws
      environment
      [ "ses"
      , "get-identity-verification-attributes"
      , "--identities"
      , Text.unpack (sesDnsIdentityDomain ref)
      , "--output"
      , "json"
      ]
  dkimOutput <-
    runAws
      environment
      [ "ses"
      , "get-identity-dkim-attributes"
      , "--identities"
      , Text.unpack (sesDnsIdentityDomain ref)
      , "--output"
      , "json"
      ]
  pure $ do
    _ <- firstText (commandSuccess identityOutput)
    _ <- firstText (commandSuccess dkimOutput)
    identityRoot <- decodeObject (processStdout identityOutput)
    dkimRoot <- decodeObject (processStdout dkimOutput)
    verificationToken <-
      optionalSesIdentityText
        "VerificationAttributes"
        "VerificationToken"
        (sesDnsIdentityDomain ref)
        identityRoot
    dkimTokens <-
      optionalSesIdentityTextArray
        "DkimAttributes"
        "DkimTokens"
        (sesDnsIdentityDomain ref)
        dkimRoot
    case (verificationToken, dkimTokens) of
      (Nothing, _) -> Right Nothing
      (_, Nothing) -> Right Nothing
      (Just token, Just tokens)
        | length tokens == 3 ->
            Right
              ( Just
                  SesDnsInputs
                    { sesDnsVerificationToken = token
                    , sesDnsDkimTokens = tokens
                    }
              )
        | otherwise -> Left "SES DKIM response did not contain exactly three tokens"

optionalSesIdentityText
  :: Text
  -> Text
  -> Text
  -> KeyMap.KeyMap Value
  -> Either Text (Maybe Text)
optionalSesIdentityText collectionName fieldName identity root =
  case KeyMap.lookup (Key.fromText collectionName) root of
    Just (Object attributes) ->
      case KeyMap.lookup (Key.fromText identity) attributes of
        Nothing -> Right Nothing
        Just (Object value) -> case KeyMap.lookup (Key.fromText fieldName) value of
          Just (String textValue)
            | not (Text.null (Text.strip textValue)) -> Right (Just textValue)
          _ -> Left ("SES " <> fieldName <> " field is malformed")
        _ -> Left ("SES " <> collectionName <> " identity is malformed")
    _ -> Left ("SES " <> collectionName <> " collection is missing")

optionalSesIdentityTextArray
  :: Text
  -> Text
  -> Text
  -> KeyMap.KeyMap Value
  -> Either Text (Maybe [Text])
optionalSesIdentityTextArray collectionName fieldName identity root =
  case KeyMap.lookup (Key.fromText collectionName) root of
    Just (Object attributes) ->
      case KeyMap.lookup (Key.fromText identity) attributes of
        Nothing -> Right Nothing
        Just (Object value) -> case KeyMap.lookup (Key.fromText fieldName) value of
          Just (Array rawValues) ->
            let values = [textValue | String textValue <- Vector.toList rawValues]
             in if length values == Vector.length rawValues
                  && all (not . Text.null . Text.strip) values
                  then Right (Just values)
                  else Left ("SES " <> fieldName <> " field is malformed")
          _ -> Left ("SES " <> fieldName <> " field is malformed")
        _ -> Left ("SES " <> collectionName <> " identity is malformed")
    _ -> Left ("SES " <> collectionName <> " collection is missing")

-- | Which of the SES lane's records a plan is.
--
-- A closed sum rather than a rendered record, because the coordinate a lane
-- needs at apply time cannot be recovered from a rendered name: the DKIM lane's
-- coordinate is a function of its token.
data SesDnsLaneKind
  = SesVerificationLane
  | SesDkimLane !Text
  | SesInboundMxLane

data SesDnsRecordPlan = SesDnsRecordPlan
  { sesPlanKind :: !SesDnsLaneKind
  , sesPlanValues :: !DnsRecordSet
  }

-- | The one derivation of what the SES lane's records are.
--
-- The observation that decides whether an apply is needed and the ensure that
-- performs it both consume this, so they cannot disagree about a name, a TTL,
-- or a value — the drift a second renderer would reintroduce
-- (@chaos_hardening_doctrine.md § 23@).
sesDnsRecordPlans
  :: ProviderProductionSession
  -> SesDnsInputs
  -> Either Text [SesDnsRecordPlan]
sesDnsRecordPlans session inputs = do
  providerRegion <-
    if Text.null strippedRegion
      then Left "Provider AWS region is empty while rendering the SES MX target"
      else Right strippedRegion
  verification <-
    plan SesVerificationLane (route53TxtValue (sesDnsVerificationToken inputs))
  dkim <-
    traverse
      (\token -> plan (SesDkimLane token) (token <> ".dkim.amazonses.com."))
      (sesDnsDkimTokens inputs)
  inboundMx <-
    plan
      SesInboundMxLane
      ("10 inbound-smtp." <> providerRegion <> ".amazonaws.com.")
  pure (verification : dkim <> [inboundMx])
 where
  strippedRegion = Text.strip (region (productionSessionCredentials session))
  plan kind rawValue = do
    value <- coordinateError (mkDnsRecordValue (sesLaneRecordType kind) rawValue)
    values <- coordinateError (mkDnsRecordSet sesDnsRecordTtl (value NonEmpty.:| []))
    pure SesDnsRecordPlan {sesPlanKind = kind, sesPlanValues = values}

sesLaneRecordType :: SesDnsLaneKind -> DnsRecordType
sesLaneRecordType kind = case kind of
  SesVerificationLane -> DnsRecordTxt
  SesDkimLane _ -> DnsRecordCname
  SesInboundMxLane -> DnsRecordMx

-- | The record name a lane owns, from the single definition in
-- "Prodbox.Lifecycle.DnsRecord" that the coordinate constructors also use.
sesLaneRecordName :: SesDnsRef -> SesDnsLaneKind -> Either Text Text
sesLaneRecordName ref kind =
  coordinateError $ case kind of
    SesVerificationLane -> sesVerificationRecordName (sesDnsIdentityDomain ref)
    SesDkimLane token -> sesDkimRecordName token (sesDnsIdentityDomain ref)
    SesInboundMxLane -> sesInboundMxRecordName (sesDnsReceiveSubdomain ref)

observeSesDnsRecords
  :: ProviderProductionSession
  -> SesDnsRef
  -> [SesDnsRecordPlan]
  -> IO ProviderEffectObservation
observeSesDnsRecords session ref plans =
  case (route53ClientForSession session, traverse (sesLaneRecordName ref . sesPlanKind) plans) of
    (Left detail, _) -> pure (ProviderEffectUnobservable detail)
    (_, Left detail) -> pure (ProviderEffectUnobservable detail)
    (Right client, Right names) -> go names client (zip names plans)
 where
  go names _ [] =
    pure
      ( ProviderEffectSatisfied
          ( "ses-dns:"
              <> sesDnsHostedZoneId ref
              <> ":"
              <> Text.intercalate "," names
          )
      )
  go names client ((name, expected) : remaining) = do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        (sesDnsHostedZoneId ref)
        name
        (nativeDnsRecordType (sesLaneRecordType (sesPlanKind expected)))
    case observed of
      Left err -> pure (ProviderEffectUnobservable (nativeRoute53Error err))
      Right Nothing ->
        pure (ProviderEffectNeedsApply ("SES DNS record is absent: " <> name))
      Right (Just actual) ->
        case observedDnsRecordSet (sesLaneRecordType (sesPlanKind expected)) actual of
          -- A value the canonical form refuses is not evidence of absence and
          -- not evidence of a match; "cannot observe" stays its own answer.
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right actualValues
            | actualValues == sesPlanValues expected -> go names client remaining
            | otherwise ->
                pure (ProviderEffectNeedsApply ("SES DNS record differs: " <> name))

-- | An observed Route 53 record set in the canonical form the desired set is
-- already in, so the comparison is exact equality rather than a second
-- normalizing comparator that could disagree with the constructor.
observedDnsRecordSet
  :: DnsRecordType
  -> NativeRoute53.ResourceRecordSet
  -> Either Text DnsRecordSet
observedDnsRecordSet recordType observed = do
  parsed <-
    traverse
      (coordinateError . mkDnsRecordValue recordType)
      (NativeRoute53.rrsRecords observed)
  values <-
    maybe
      (Left "Route 53 SES DNS record carried no values")
      Right
      (NonEmpty.nonEmpty parsed)
  recordSet <-
    coordinateError (mkDnsRecordSet (fromIntegral (NativeRoute53.rrsTtl observed)) values)
  -- A set that lost members to deduplication is not the response that was
  -- observed, and comparing the smaller set could report a duplicated record as
  -- converged. The home Gateway DNS observation has made this check since it
  -- was written; the two paths now agree.
  if Set.size (dnsRecordSetValues recordSet) == length (NativeRoute53.rrsRecords observed)
    then Right recordSet
    else Left "Route 53 SES DNS record carried duplicate values"

-- | Lift each plan to an exact coordinate.
--
-- The account and the ownership epoch are observed rather than carried, for the
-- reason Sprint 4.72 gives on the public A-record lane: a request that names
-- its own account is an assertion, and @sts get-caller-identity@ is evidence.
prepareSesDnsLanes
  :: ProviderProductionSession
  -> SesDnsRef
  -> [SesDnsRecordPlan]
  -> IO (Either Text [(DnsRecordCoordinate, DnsRecordSet)])
prepareSesDnsLanes session ref plans = do
  accountResult <- observeProviderAwsAccountId session
  case accountResult of
    Left detail -> pure (Left detail)
    Right account -> do
      epochResult <- productionSessionAuthorityEpoch session
      pure $ do
        epoch <- epochResult
        zone <- coordinateError (mkHostedZoneId (sesDnsHostedZoneId ref))
        traverse (lane account zone (mkOwnershipEpoch epoch)) plans
 where
  lane account zone epoch item = do
    coordinate <-
      coordinateError (sesLaneCoordinate ref account zone epoch (sesPlanKind item))
    pure (coordinate, sesPlanValues item)

sesLaneCoordinate
  :: SesDnsRef
  -> AwsAccountId
  -> HostedZoneId
  -> OwnershipEpoch
  -> SesDnsLaneKind
  -> Either DnsCoordinateError DnsRecordCoordinate
sesLaneCoordinate ref account zone epoch kind = case kind of
  SesVerificationLane ->
    mkSesVerificationCoordinate account zone (sesDnsIdentityDomain ref) owner epoch
  SesDkimLane token ->
    mkSesDkimCoordinate account zone token (sesDnsIdentityDomain ref) owner epoch
  SesInboundMxLane ->
    mkSesInboundMxCoordinate account zone (sesDnsReceiveSubdomain ref) owner epoch
 where
  owner = authorizedDnsOwner sesDnsOwnerAuthority

-- | Ensure every SES lane, then discharge propagation once.
--
-- The superseded body sent all five records in one @changeResourceRecordSets@
-- batch and waited for that single change to reach INSYNC. A coordinate is one
-- name and one type, so the typed program necessarily submits one change per
-- lane — and if each awaited inline, this lane would spend five propagation
-- windows in series where it used to spend one. Submitting first and awaiting
-- afterwards keeps the windows overlapping, which is the property the batch
-- had; what is added is a per-coordinate observation before the write and a
-- read-back after it, neither of which the batch performed at all.
--
-- Deferring the wait does not weaken the read-back.
-- @ListResourceRecordSets@ answers from the hosted zone's record data, which a
-- change updates when it is accepted, while PENDING and INSYNC describe
-- replication to the Route 53 name servers. The post-apply observation this
-- repository already performs reads the same way.
ensureSesDnsLanes
  :: NativeRoute53.Route53Client
  -> Text
  -> [(DnsRecordCoordinate, DnsRecordSet)]
  -> IO (Either Text ())
ensureSesDnsLanes client zone lanes = do
  pending <- newIORef []
  ensured <- ensureEach pending lanes
  case ensured of
    Left detail -> pure (Left detail)
    Right () -> readIORef pending >>= awaitPending
 where
  ensureEach _ [] = pure (Right ())
  ensureEach pending ((coordinate, values) : remaining) = do
    outcome <-
      runDnsRecordProgram
        (sesDnsRecordBoundary client zone pending coordinate)
        coordinate
        (EnsureDnsRecord sesDnsOwnerAuthority values)
    case sesDnsProgramOutcome coordinate outcome of
      Left detail -> pure (Left detail)
      Right () -> ensureEach pending remaining

  awaitPending [] = pure (Right ())
  awaitPending (changeId : remaining) = do
    completed <- awaitRoute53Change client changeId NativeRoute53.ChangePending
    case completed of
      Left detail -> pure (Left detail)
      Right () -> awaitPending remaining

sesDnsRecordBoundary
  :: NativeRoute53.Route53Client
  -> Text
  -> IORef [NativeRoute53.ChangeId]
  -> DnsRecordCoordinate
  -> DnsRecordBoundary IO
sesDnsRecordBoundary client zone pending coordinate =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = observe
    , dnsBoundaryEnsure = submit NativeRoute53.Upsert
    , dnsBoundaryDestroy = submit NativeRoute53.DeleteRecord
    }
 where
  observe = do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        zone
        (dnsCoordinateName coordinate)
        (nativeDnsRecordType (dnsCoordinateType coordinate))
    pure $ case observed of
      Left err -> DnsRecordUnobservable (nativeRoute53Error err)
      Right Nothing -> DnsRecordMissing
      Right (Just record) ->
        case observedDnsRecordSet (dnsCoordinateType coordinate) record of
          Left detail -> DnsRecordUnobservable detail
          Right values -> DnsRecordObserved values

  submit action values = do
    changed <-
      NativeRoute53.changeResourceRecordSets
        client
        zone
        [(action, nativeDnsRecordSet coordinate values)]
    case changed of
      Left err -> pure (Left (nativeRoute53Error err))
      Right (_, NativeRoute53.ChangeInsync) -> pure (Right ())
      Right (changeId, NativeRoute53.ChangePending) -> do
        modifyIORef' pending (changeId :)
        pure (Right ())

-- | Every arm is named, and each names the coordinate it refused.
--
-- Five lanes run in sequence, so a bare @Left@ would lose both which refusal
-- occurred and which record provoked it.
sesDnsProgramOutcome :: DnsRecordCoordinate -> DnsProgramResult -> Either Text ()
sesDnsProgramOutcome coordinate result = case result of
  DnsEnsureAlreadyConverged -> Right ()
  DnsEnsureAppliedAndReadBack -> Right ()
  DnsDestroyAlreadyAbsent -> refused "ensure answered a destroy result"
  DnsDestroyAppliedAndReadBack -> refused "ensure answered a destroy result"
  DnsProgramOwnerMismatch expected actual ->
    refused
      ( "coordinate owner mismatch: expected "
          <> Text.pack (show expected)
          <> ", bound to "
          <> Text.pack (show actual)
      )
  DnsProgramOwnerUnauthorized held bound ->
    refused
      ( "this process holds "
          <> Text.pack (show held)
          <> " and the coordinate is owned by "
          <> Text.pack (show bound)
      )
  DnsProgramCoordinateMismatch _ _ ->
    refused "boundary is bound to a different coordinate"
  DnsProgramInitialObservationRefused observation ->
    refused ("unobservable before mutation: " <> Text.pack (show observation))
  DnsProgramMutationFailed detail _ -> refused detail
  DnsProgramPostconditionFailed observation ->
    refused ("read-back did not converge: " <> Text.pack (show observation))
 where
  refused detail =
    Left ("SES DNS record " <> dnsCoordinateName coordinate <> ": " <> detail)

route53ClientForSession
  :: ProviderProductionSession
  -> Either Text NativeRoute53.Route53Client
route53ClientForSession session =
  Right
    ( NativeRoute53.newRoute53Client
        (productionSessionCredentialHandle session)
        httpSend
    )

awaitRoute53Change
  :: NativeRoute53.Route53Client
  -> NativeRoute53.ChangeId
  -> NativeRoute53.ChangeStatus
  -> IO (Either Text ())
awaitRoute53Change _ _ NativeRoute53.ChangeInsync = pure (Right ())
awaitRoute53Change client changeId NativeRoute53.ChangePending = do
  completed <- timeout sesDnsChangeTimeoutMicros (poll sesDnsChangePollLimit)
  pure $ case completed of
    Nothing -> Left "Route 53 SES DNS change timed out before INSYNC"
    Just result -> result
 where
  poll attempts
    | attempts <= (0 :: Int) = pure (Left "Route 53 SES DNS change remained PENDING")
    | otherwise = do
        threadDelay sesDnsChangePollDelayMicros
        observed <- NativeRoute53.getChange client changeId
        case observed of
          Left err -> pure (Left (nativeRoute53Error err))
          Right NativeRoute53.ChangeInsync -> pure (Right ())
          Right NativeRoute53.ChangePending -> poll (attempts - 1)

route53TxtValue :: Text -> Text
route53TxtValue value = "\"" <> value <> "\""

nativeRoute53Error :: (Show errorValue) => errorValue -> Text
nativeRoute53Error = ("Route 53 SES DNS request failed: " <>) . Text.pack . show

sesDnsRecordTtl :: Natural
sesDnsRecordTtl = 300

sesDnsChangePollLimit :: Int
sesDnsChangePollLimit = 30

sesDnsChangePollDelayMicros :: Int
sesDnsChangePollDelayMicros = 1000000

sesDnsChangeTimeoutMicros :: Int
sesDnsChangeTimeoutMicros = 35000000

sesReceiptRulesMutation
  :: SesRuleSetRef
  -> ProviderMutation IO ProviderProductionSession
sesReceiptRulesMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesReceiptRules session ref
    , applyProviderMutation = \session _ -> failedApply (applySesReceiptRules session ref)
    }

observeSesReceiptRules
  :: ProviderProductionSession
  -> SesRuleSetRef
  -> IO ProviderEffectObservation
observeSesReceiptRules session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let ruleSetName = Text.unpack (sesRuleSetRefText ref)
  ruleSet <-
    runAws
      environment
      ["ses", "describe-receipt-rule-set", "--rule-set-name", ruleSetName, "--output", "json"]
  case commandSuccess ruleSet of
    Left _
      | knownAwsAbsent ruleSet ->
          pure (ProviderEffectNeedsApply "SES receipt rule set is absent")
      | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail ruleSet)))
    Right _ -> do
      rule <-
        runAws
          environment
          [ "ses"
          , "describe-receipt-rule"
          , "--rule-set-name"
          , ruleSetName
          , "--rule-name"
          , sesReceiveRuleName
          , "--output"
          , "json"
          ]
      case commandSuccess rule of
        Left _
          | knownAwsAbsent rule ->
              pure (ProviderEffectNeedsApply "SES capture receipt rule is absent")
          | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail rule)))
        Right _ -> case exactSesReceiptRule ref (processStdout rule) of
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right False -> pure (ProviderEffectNeedsApply "SES capture receipt rule differs")
          Right True -> do
            active <-
              runAws environment ["ses", "describe-active-receipt-rule-set", "--output", "json"]
            pure $ case commandSuccess active of
              Left detail -> ProviderEffectUnobservable (Text.pack detail)
              Right _ -> case activeSesRuleSetName (processStdout active) of
                Left detail -> ProviderEffectUnobservable detail
                Right (Just actual)
                  | actual == sesRuleSetRefText ref ->
                      ProviderEffectSatisfied
                        (providerAwsEvidence "ses-receipt-rules" [ruleSet, rule, active])
                Right _ -> ProviderEffectNeedsApply "SES receipt rule set is not active"

applySesReceiptRules
  :: ProviderProductionSession
  -> SesRuleSetRef
  -> IO (Either Text ())
applySesReceiptRules session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let ruleSetName = Text.unpack (sesRuleSetRefText ref)
  created <-
    runAws environment ["ses", "create-receipt-rule-set", "--rule-set-name", ruleSetName]
  case commandSuccess created of
    Left detail
      | not (knownAwsAlreadyExists created) -> pure (Left (Text.pack detail))
    _ -> do
      existing <-
        runAws
          environment
          [ "ses"
          , "describe-receipt-rule"
          , "--rule-set-name"
          , ruleSetName
          , "--rule-name"
          , sesReceiveRuleName
          , "--output"
          , "json"
          ]
      ruleVerb <- case commandSuccess existing of
        Right _ -> pure (Right "update-receipt-rule")
        Left _
          | knownAwsAbsent existing -> pure (Right "create-receipt-rule")
          | otherwise -> pure (Left (Text.pack (commandDetail existing)))
      case ruleVerb of
        Left detail -> pure (Left detail)
        Right verb -> do
          ruleResult <-
            runAws
              environment
              [ "ses"
              , verb
              , "--rule-set-name"
              , ruleSetName
              , "--rule"
              , jsonArgument (desiredSesReceiptRule ref)
              ]
          case commandSuccess ruleResult of
            Left detail -> pure (Left (Text.pack detail))
            Right _ -> do
              active <-
                runAws
                  environment
                  ["ses", "set-active-receipt-rule-set", "--rule-set-name", ruleSetName]
              pure (Control.Monad.void (firstText (commandSuccess active)))

sesCaptureBucketMutation
  :: SesBucketRef
  -> ProviderMutation IO ProviderProductionSession
sesCaptureBucketMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesCaptureBucket session ref
    , applyProviderMutation = \session _ -> failedApply (applySesCaptureBucket session ref)
    }

observeSesCaptureBucket
  :: ProviderProductionSession
  -> SesBucketRef
  -> IO ProviderEffectObservation
observeSesCaptureBucket session ref =
  case mkS3BucketName (sesBucketRefText ref) of
    Left _ -> pure (ProviderEffectUnobservable "SES capture bucket name is invalid")
    Right bucket -> observeSesCaptureBucketBound session ref bucket

observeSesCaptureBucketBound
  :: ProviderProductionSession -> SesBucketRef -> S3BucketName -> IO ProviderEffectObservation
observeSesCaptureBucketBound session ref captureBucket = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let bucket = Text.unpack (s3BucketNameText captureBucket)
  headBucket <- runAws environment ["s3api", "head-bucket", "--bucket", bucket]
  case commandSuccess headBucket of
    Left _
      | knownAwsAbsent headBucket ->
          pure (ProviderEffectNeedsApply "SES capture bucket is absent")
      | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail headBucket)))
    Right _ -> do
      policy <-
        runAws environment ["s3api", "get-bucket-policy", "--bucket", bucket, "--output", "json"]
      case commandSuccess policy of
        Left _
          | knownAwsAbsent policy ->
              pure (ProviderEffectNeedsApply "SES capture bucket policy is absent")
          | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail policy)))
        Right _ -> case exactSesBucketPolicy ref (processStdout policy) of
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right False -> pure (ProviderEffectNeedsApply "SES capture bucket policy differs")
          Right True -> do
            tagging <-
              runAws environment ["s3api", "get-bucket-tagging", "--bucket", bucket, "--output", "json"]
            case observedSesCaptureBucketTagging tagging of
              Left detail -> pure (ProviderEffectUnobservable detail)
              Right False ->
                pure
                  ( ProviderEffectNeedsApply
                      "SES capture bucket does not carry its prodbox-owned tag families"
                  )
              Right True -> do
                (lifecycle, lifecycleRead) <-
                  CaptureLifecycle.observeCaptureLifecycle (runAws environment) captureBucket
                case lifecycle of
                  CaptureLifecycle.CaptureLifecycleMissing -> pure (ProviderEffectNeedsApply "SES capture lifecycle is absent")
                  CaptureLifecycle.CaptureLifecycleDifferent -> pure (ProviderEffectNeedsApply "SES capture lifecycle differs")
                  CaptureLifecycle.CaptureLifecycleUnobservable detail -> pure (ProviderEffectUnobservable detail)
                  CaptureLifecycle.CaptureLifecycleCurrent -> do
                    readiness <-
                      runAws
                        environment
                        [ "s3api"
                        , "head-object"
                        , "--bucket"
                        , bucket
                        , "--key"
                        , sesCaptureReadinessKey
                        ]
                    pure $ case commandSuccess readiness of
                      Left _
                        | knownAwsAbsent readiness ->
                            ProviderEffectNeedsApply "SES capture readiness object is absent"
                        | otherwise -> ProviderEffectUnobservable (Text.pack (commandDetail readiness))
                      Right _ ->
                        ProviderEffectSatisfied
                          ( providerAwsEvidence
                              "ses-capture-bucket"
                              [headBucket, policy, tagging, lifecycleRead, readiness]
                          )

applySesCaptureBucket
  :: ProviderProductionSession
  -> SesBucketRef
  -> IO (Either Text ())
applySesCaptureBucket session ref =
  case mkS3BucketName (sesBucketRefText ref) of
    Left _ -> pure (Left "SES capture bucket name is invalid")
    Right bucket -> applySesCaptureBucketBound session ref bucket

applySesCaptureBucketBound
  :: ProviderProductionSession -> SesBucketRef -> S3BucketName -> IO (Either Text ())
applySesCaptureBucketBound session ref captureBucket = do
  let credentials = productionSessionCredentials session
      awsRegion = Text.unpack (region credentials)
      bucket = Text.unpack (s3BucketNameText captureBucket)
      createArguments =
        ["s3api", "create-bucket", "--bucket", bucket]
          <> if awsRegion == awsGlobalServiceRegion
            then []
            else ["--create-bucket-configuration", "LocationConstraint=" <> awsRegion]
  environment <- awsCliSubprocessEnvironment credentials
  created <- runAws environment createArguments
  case commandSuccess created of
    Left detail
      | not (knownAwsAlreadyOwned created) -> pure (Left (Text.pack detail))
    _ -> do
      policy <-
        runAws
          environment
          [ "s3api"
          , "put-bucket-policy"
          , "--bucket"
          , bucket
          , "--policy"
          , jsonArgument (desiredSesBucketPolicy ref)
          ]
      case commandSuccess policy of
        Left detail -> pure (Left (Text.pack detail))
        Right _ -> do
          -- Sprint 4.84: without these families the bucket is returned by no
          -- terminal-audit query, so the audit can neither confirm the retained
          -- bucket present nor find it escaped, while the retained catalog
          -- declares the family discoverable.
          tagging <-
            runAws
              environment
              [ "s3api"
              , "put-bucket-tagging"
              , "--bucket"
              , bucket
              , "--tagging"
              , jsonArgument desiredSesCaptureBucketTagging
              ]
          case commandSuccess tagging of
            Left detail -> pure (Left (Text.pack detail))
            Right _ -> do
              lifecycle <- CaptureLifecycle.applyCaptureLifecycle (runAws environment) captureBucket
              case lifecycle of
                Left detail -> pure (Left detail)
                Right () -> do
                  readiness <-
                    runAws
                      environment
                      [ "s3api"
                      , "put-object"
                      , "--bucket"
                      , bucket
                      , "--key"
                      , sesCaptureReadinessKey
                      , "--body"
                      , "/dev/null"
                      , "--content-type"
                      , "text/plain"
                      ]
                  pure (Control.Monad.void (firstText (commandSuccess readiness)))

applySingleAwsCommand
  :: ProviderProductionSession
  -> [String]
  -> IO (Either Text ())
applySingleAwsCommand session arguments = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <- runAws environment arguments
  pure (Control.Monad.void (firstText (commandSuccess output)))

sesReceiveRuleName :: String
sesReceiveRuleName = "prodbox-capture-all-mail"

sesCaptureKeyPrefix :: Text
sesCaptureKeyPrefix = Text.pack CaptureLifecycle.sesCaptureMailPrefix

sesCaptureReadinessKey :: String
sesCaptureReadinessKey = CaptureLifecycle.sesCaptureReadinessObjectKey

desiredSesReceiptRule :: SesRuleSetRef -> Value
desiredSesReceiptRule ref =
  object
    [ "Name" .= Text.pack sesReceiveRuleName
    , "Enabled" .= True
    , "TlsPolicy" .= ("Optional" :: Text)
    , "ScanEnabled" .= True
    , "Recipients" .= [sesRuleSetRecipient ref]
    , "Actions"
        .= [ object
               [ "S3Action"
                   .= object
                     [ "BucketName" .= sesBucketRefText (sesRuleSetCaptureBucket ref)
                     , "ObjectKeyPrefix" .= sesCaptureKeyPrefix
                     ]
               ]
           ]
    ]

exactSesReceiptRule :: SesRuleSetRef -> String -> Either Text Bool
exactSesReceiptRule ref payload = do
  root <- decodeObject payload
  rule <- requireObjectField "Rule" root
  name <- requireTextField "Name" rule
  enabled <- requireBoolField "Enabled" rule
  scanEnabled <- requireBoolField "ScanEnabled" rule
  tlsPolicy <- requireTextField "TlsPolicy" rule
  recipients <- requireTextArrayField "Recipients" rule
  actions <- case KeyMap.lookup "Actions" rule of
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left "SES receipt rule actions are malformed"
  exactAction <- case actions of
    [Object action] -> do
      s3Action <- requireObjectField "S3Action" action
      bucket <- requireTextField "BucketName" s3Action
      prefix <- requireTextField "ObjectKeyPrefix" s3Action
      Right
        ( bucket == sesBucketRefText (sesRuleSetCaptureBucket ref)
            && prefix == sesCaptureKeyPrefix
        )
    _ -> Right False
  pure
    ( name == Text.pack sesReceiveRuleName
        && enabled
        && scanEnabled
        && tlsPolicy == "Optional"
        && recipients == [sesRuleSetRecipient ref]
        && exactAction
    )

activeSesRuleSetName :: String -> Either Text (Maybe Text)
activeSesRuleSetName payload = do
  root <- decodeObject payload
  case KeyMap.lookup "Metadata" root of
    Nothing -> Right Nothing
    Just (Object metadata) -> Just <$> requireTextField "Name" metadata
    _ -> Left "active SES receipt rule metadata is malformed"

desiredSesBucketPolicy :: SesBucketRef -> Value
desiredSesBucketPolicy ref =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("AllowSESPuts" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Principal" .= object ["Service" .= ("ses.amazonaws.com" :: Text)]
               , "Action" .= ("s3:PutObject" :: Text)
               , "Resource" .= ("arn:aws:s3:::" <> sesBucketRefText ref <> "/*")
               ]
           ]
    ]

-- | Sprint 4.84: the tag document the SES capture-bucket writer authors.
--
-- The families come from 'sesCaptureBucketTags', which the retained catalog
-- reads to decide whether this family is discoverable by the terminal audit at
-- all — so the writer and the audit's field-of-view claim are one value rather
-- than two agreeing statements.
desiredSesCaptureBucketTagging :: Value
desiredSesCaptureBucketTagging =
  object
    [ "TagSet"
        .= [ object ["Key" .= key, "Value" .= value]
           | (key, value) <- sesCaptureBucketTags
           ]
    ]

-- | Whether the observed bucket carries every prodbox-owned tag family.
--
-- Containment, not equality: the frozen @aws-ses@ provisioning program is still
-- a writer during migration and authors a @Name@ tag of its own, and an extra
-- tag is not drift in the families the audit queries. An absent tag set is a
-- definite @False@ rather than an unobservable, because S3 reports a bucket
-- with no tags that way.
observedSesCaptureBucketTagging :: ProcessOutput -> Either Text Bool
observedSesCaptureBucketTagging observed = case commandSuccess observed of
  Left _
    | knownAwsAbsentTagSet observed -> Right False
    | otherwise -> Left (Text.pack (commandDetail observed))
  Right _ -> sesCaptureBucketTagsPresent (processStdout observed)

knownAwsAbsentTagSet :: ProcessOutput -> Bool
knownAwsAbsentTagSet =
  containsAny ["nosuchtagset", "no such tagset", "notagset"] . commandDetail

sesCaptureBucketTagsPresent :: String -> Either Text Bool
sesCaptureBucketTagsPresent payload = do
  root <- decodeObject payload
  entries <- case KeyMap.lookup "TagSet" root of
    Just (Array items) -> Right (Vector.toList items)
    _ -> Left "SES capture bucket tagging response has no TagSet array"
  observed <- traverse tagPair entries
  Right (all (`elem` observed) sesCaptureBucketTags)
 where
  tagPair value = case value of
    Object entry -> do
      key <- requireTextField "Key" entry
      tagValue <- requireTextField "Value" entry
      Right (key, tagValue)
    _ -> Left "SES capture bucket tagging entry is not an object"

exactSesBucketPolicy :: SesBucketRef -> String -> Either Text Bool
exactSesBucketPolicy ref payload = do
  root <- decodeObject payload
  encodedPolicy <- requireTextField "Policy" root
  policy <- case eitherDecodeStrict' (TextEncoding.encodeUtf8 encodedPolicy) of
    Left _ -> Left "SES capture bucket policy is invalid JSON"
    Right value -> Right value
  Right (policy == desiredSesBucketPolicy ref)

decodeObject :: String -> Either Text (KeyMap.KeyMap Value)
decodeObject payload = case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack payload)) of
  Right (Object value) -> Right value
  _ -> Left "AWS response is invalid JSON"

requireObjectField :: Key.Key -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
requireObjectField key value = case KeyMap.lookup key value of
  Just (Object nested) -> Right nested
  _ -> Left ("AWS response object field is missing: " <> Key.toText key)

requireTextField :: Key.Key -> KeyMap.KeyMap Value -> Either Text Text
requireTextField key value = case KeyMap.lookup key value of
  Just (String textValue) -> Right textValue
  _ -> Left ("AWS response text field is missing: " <> Key.toText key)

requireBoolField :: Key.Key -> KeyMap.KeyMap Value -> Either Text Bool
requireBoolField key value = case KeyMap.lookup key value of
  Just (Bool boolValue) -> Right boolValue
  _ -> Left ("AWS response boolean field is missing: " <> Key.toText key)

requireTextArrayField :: Key.Key -> KeyMap.KeyMap Value -> Either Text [Text]
requireTextArrayField key value = case KeyMap.lookup key value of
  Just (Array values) -> traverse requireStringValue (Vector.toList values)
  _ -> Left ("AWS response array field is missing: " <> Key.toText key)
 where
  requireStringValue item = case item of
    String textValue -> Right textValue
    _ -> Left ("AWS response array contains a non-text value: " <> Key.toText key)

nonEmptyString :: Value -> Bool
nonEmptyString value = case value of
  String textValue -> not (Text.null (Text.strip textValue))
  _ -> False

jsonArgument :: Value -> String
jsonArgument =
  Text.unpack . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

knownAwsAbsent :: ProcessOutput -> Bool
knownAwsAbsent =
  containsAny
    [ "notfound"
    , "not found"
    , "nosuchbucket"
    , "nosuchkey"
    , "receiptrulesetdoesnotexist"
    , "rule does not exist"
    , "cannot be found"
    ]
    . commandDetail

knownAwsAlreadyExists :: ProcessOutput -> Bool
knownAwsAlreadyExists =
  containsAny ["alreadyexists", "already exists"] . commandDetail

knownAwsAlreadyOwned :: ProcessOutput -> Bool
knownAwsAlreadyOwned =
  containsAny ["bucketalreadyownedbyyou", "already owned by you"] . commandDetail

providerAwsEvidence :: Text -> [ProcessOutput] -> Text
providerAwsEvidence label outputs =
  label
    <> ":sha256:"
    <> sha256Text
      ( TextEncoding.encodeUtf8
          (Text.intercalate "\NUL" (Text.pack . processStdout <$> outputs))
      )

-- | Sprint 7.36: one owned-resource tag listing for the cascade's terminal
-- escape audit.
--
-- The listing follows the Tagging API's own cursor to exhaustion and fails
-- rather than returning a prefix, because the audit's claim is that nothing
-- escaped and a shortened listing is exactly how that claim goes wrong.  The
-- evidence echoes the query it answered and states the page count it consumed,
-- so a consumer can tell a complete empty answer from a truncated one.
ownedResourceTagObservation
  :: ProviderOwnedTagQuery
  -> ProviderReadOnly IO ProviderProductionSession
ownedResourceTagObservation = ownedResourceTagObservationInRegion Nothing

ownedResourceTagObservationInRegion
  :: Maybe Text -> ProviderOwnedTagQuery -> ProviderReadOnly IO ProviderProductionSession
ownedResourceTagObservationInRegion requestedRegion query = ProviderReadOnly $ \session _ providerBound ->
  sealProviderEvidence providerBound <$> do
    environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
    listed <-
      TaggedResourceQuery.discoverTaggedResourcesVia
        boundedTaggedPageRunner
        TaggedResourceQuery.TaggedResourceQueryInput
          { TaggedResourceQuery.taggedResourceQueryEnvironment = environment
          , TaggedResourceQuery.taggedResourceQueryWorkingDirectory = Nothing
          , TaggedResourceQuery.taggedResourceQueryFilter = queryFilter
          , -- The session's own region, stated in the argv rather than left to
            -- the environment this builder also sets.  The audit's *field of
            -- view across regions* is a separate question and is unchanged
            -- here: it belongs to
            -- "Prodbox.Lifecycle.Teardown.TaggingApiReach", which bounds what
            -- a clean verdict may claim when a service answers only from the
            -- global-service region.
            TaggedResourceQuery.taggedResourceQueryRegion =
              fromMaybe (region (productionSessionCredentials session)) requestedRegion
          }
    pure $ case listed of
      Left detail -> Left (Text.pack detail)
      Right listing ->
        case renderOwnedResourceTagObservation
          OwnedResourceTagObservation
            { ownedResourceTagObservationQuery = queryEcho
            , ownedResourceTagObservationEntries =
                [ OwnedResourceTagEntry
                    { ownedResourceTagEntryArn =
                        TaggedResourceQuery.taggedResourceEntryArn entry
                    , ownedResourceTagEntryTags =
                        TaggedResourceQuery.taggedResourceEntryTags entry
                    }
                | entry <- TaggedResourceQuery.taggedResourceListingEntries listing
                ]
            , ownedResourceTagObservationPages =
                TaggedResourceQuery.taggedResourceListingPages listing
            } of
          Left err -> Left (renderOwnedResourceTagEvidenceError err)
          Right evidence -> Right evidence
 where
  queryFilter = case query of
    ProviderOwnedTagKeyQuery key ->
      TaggedResourceQuery.TaggedResourceTagKeyFilter key
    ProviderOwnedTagPairQuery key value ->
      TaggedResourceQuery.TaggedResourceTagPairFilter key value
  queryEcho = case query of
    ProviderOwnedTagKeyQuery key -> OwnedResourceTagKeyEcho key
    ProviderOwnedTagPairQuery key value -> OwnedResourceTagPairEcho key value

-- | Sprint 7.36: exact read-only observation of the retained EBS family.
--
-- The lifecycle tag value is carried by the intent and checked here rather
-- than assumed, so an intent bounded to some other family cannot be served by
-- the retained query.  Transport or parse inability stays a 'Left' and never
-- becomes an empty family.
retainedEbsObservation
  :: Text
  -> ProviderReadOnly IO ProviderProductionSession
retainedEbsObservation lifecycleValue = ProviderReadOnly $ \session _ providerBound ->
  fmap (sealProviderEvidence providerBound) $
    if Text.unpack lifecycleValue /= TagSweep.ebsRetainedLifecycleValue
      then
        pure
          ( Left
              ( "retained EBS observation is bound to lifecycle value "
                  <> lifecycleValue
                  <> ", not the registered retained family"
              )
          )
      else do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        observed <-
          EbsVolume.discoverEbsVolumesVia (boundedAwsCliRun environment) (EbsVolume.EbsRetainedProduction)
        pure $ case observed of
          Left detail -> Left (Text.pack detail)
          Right volumes ->
            Right
              ( EbsVolume.renderRetainedEbsObservation
                  (EbsVolume.retainedEbsObservation volumes)
              )

-- | Sprint 7.36: the retained family's destructive reap, observed before it
-- applies.  It refuses an intent bound to any other lifecycle value for the
-- same reason the observation does: this is the one path that deletes storage
-- the rest of the system is built to preserve.
retainedEbsReaperMutation :: Text -> ProviderMutation IO ProviderProductionSession
retainedEbsReaperMutation lifecycleValue =
  ProviderMutation
    { observeProviderMutation = \session _ ->
        withRetainedFamily $ do
          environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
          observed <-
            EbsVolume.discoverEbsVolumesVia (boundedAwsCliRun environment) (EbsVolume.EbsRetainedProduction)
          pure $ case observed of
            Left detail -> ProviderEffectUnobservable (Text.pack detail)
            Right volumes ->
              case EbsVolume.retainedEbsObservationVolumeIds
                (EbsVolume.retainedEbsObservation volumes) of
                [] -> ProviderEffectSatisfied "retained EBS volumes are absent"
                _ -> ProviderEffectNeedsApply "retained EBS volumes remain"
    , applyProviderMutation = \session _ ->
        if wrongFamily
          then pure (Left (ApplyFailed wrongFamilyDetail))
          else do
            environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
            result <-
              EbsVolume.runRetainedEbsReaperVia (boundedAwsCliRun environment)
            pure (either (Left . ApplyFailed . Text.pack) (const (Right ())) result)
    }
 where
  wrongFamily = Text.unpack lifecycleValue /= TagSweep.ebsRetainedLifecycleValue
  wrongFamilyDetail =
    "retained EBS reap is bound to lifecycle value "
      <> lifecycleValue
      <> ", not the registered retained family"
  withRetainedFamily action =
    if wrongFamily
      then pure (ProviderEffectUnobservable wrongFamilyDetail)
      else action

-- Exact parent-zone names are durable coordinates, never a whole-zone prefix.
-- The Provider has no mutation for them; cert-manager owns their removal.
homeDns01RecordObservation :: HomeDns01Scope -> ProviderReadOnly IO ProviderProductionSession
homeDns01RecordObservation scope = ProviderReadOnly observe
 where
  observe session _ bound =
    case route53ClientForSession session of
      Left detail -> pure (Left detail)
      Right client -> do
        results <-
          traverse
            ( \name ->
                NativeRoute53.listExactResourceRecordSet
                  client
                  (hostedZoneIdText (homeDns01HostedZone scope))
                  name
                  NativeRoute53.RecordTXT
            )
            (NonEmpty.toList (homeDns01RecordNames scope))
        let exact =
              fmap
                (map (\row -> row {NativeRoute53.rrsName = Text.toLower (NativeRoute53.rrsName row)}) . catMaybes)
                (sequence results)
        pure
          ( renderDns01ChallengeEvidence
              bound
              (hostedZoneIdText (homeDns01HostedZone scope))
              (providerIntentResourceKey (ObserveHomeDns01Records scope))
              exact
          )

inviteMailResidueObservation :: InviteMailScope -> ProviderReadOnly IO ProviderProductionSession
inviteMailResidueObservation scope = ProviderReadOnly $ \session _ bound -> do
  observed <- observeInviteMailResidue session scope
  pure
    ( sealProviderEvidence
        bound
        ( observed >>= \versions -> renderInviteMailCleanupEvidence scope (map CaptureCleanup.capturedMailVersionIdentity versions)
        )
    )

observeInviteMailResidue
  :: ProviderProductionSession
  -> InviteMailScope
  -> IO (Either Text [CaptureCleanup.CapturedMailVersion])
observeInviteMailResidue session scope = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  guarded <- requireCaptureCleanupBucket environment scope
  case guarded of
    Left detail -> pure (Left detail)
    Right () -> CaptureCleanup.observeCapturedMailVersions (captureRunner environment) scope

requireCaptureCleanupBucket :: [(String, String)] -> InviteMailScope -> IO (Either Text ())
requireCaptureCleanupBucket environment scope = do
  tagging <-
    runAws
      environment
      [ "s3api"
      , "get-bucket-tagging"
      , "--bucket"
      , Text.unpack (s3BucketNameText (inviteMailBucket scope))
      , "--output"
      , "json"
      ]
  pure $ case observedSesCaptureBucketTagging tagging of
    Right True -> Right ()
    Right False -> Left "registered mail cleanup bucket lacks its exact capture-bucket owned tags"
    Left detail -> Left detail

inviteMailResidueMutation :: InviteMailScope -> ProviderMutation IO ProviderProductionSession
inviteMailResidueMutation scope =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        observed <- observeInviteMailResidue session scope
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable detail
          Right [] -> ProviderEffectSatisfied inviteMailCleanupAbsentEvidence
          Right _ -> ProviderEffectNeedsApply "registered invite mail data versions remain"
    , applyProviderMutation = \session _ -> failedApply $ do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        observed <- observeInviteMailResidue session scope
        case observed of
          Left detail -> pure (Left detail)
          Right versions -> CaptureCleanup.deleteCapturedMailVersions (captureRunner environment) scope versions
    }
