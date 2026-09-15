{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Production sources for the bounded legacy-adoption lane.
--
-- The lane in "Prodbox.Lifecycle.Teardown.LegacyAdoptionLane" is polymorphic
-- over its three seams; this module builds them for the operator command, and
-- is the only place in the adoption path that opens a transport.
--
-- Four properties carry the design, and each is the reason a simpler shape was
-- rejected.
--
--   * __Observation stays inside the read-only Provider capability.__  Every
--     candidate read is a closed @Observe…@ intent dispatched through
--     'dispatchRegisteredProviderObservation' at the
--     'ProviderLegacyAdoptionObservation' purpose, which admits exactly the
--     four intents the observer issues and no mutation at all.  The host holds
--     no AWS credential here and there is no generic provider fallback.
--
--   * __The AWS scope is observed, never asserted.__  The account and region
--     come from a settled @ObserveProviderAwsScope@ receipt the Authority read
--     back, which is the same source the cascade candidate uses.  Reading them
--     from the host's own credentials would be an unregistered escape and would
--     also let an adoption be planned against an account the Provider is not
--     operating in.
--
--   * __The run scope is derived from the plan's own identity, not a clock.__
--     The adoption operation is keyed by the stack it adopts, so re-running the
--     command replays the same Authority submission rather than allocating a
--     new one, and the committed receipt lands at the same logical name.
--
--   * __Freshness is measured, not assumed.__  'admitAdminLegacyAdoptionPermit'
--     takes a 'PermitFreshness' observation.  A constant @PermitFresh@ would be
--     an inert device, so the observation here is the elapsed time between the
--     start of this invocation and the admission: confirming a plan is a
--     statement about the present, and an observation pass that outran
--     'maximumLegacyAdoptionConfirmationSeconds' no longer supports one.
module Prodbox.ControlPlane.LegacyAdoptionCompositionRoot
  ( LegacyAdoptionCompositionError (..)
  , renderLegacyAdoptionCompositionError
  , maximumLegacyAdoptionConfirmationSeconds
  , legacyAdoptionDispatchKeyFor
  , withProductionLegacyAdoption
  )
where

import Control.Monad (join)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError
  , dispatchAuthorityProviderIntentWithOperation
  )
import Prodbox.ControlPlane.CascadeRetainedSlotClient
  ( cascadeRetainedSlotModelBAdapter
  )
import Prodbox.ControlPlane.LegacyAdoptionManifestRepository
  ( modelBLegacyAdoptionManifestRepository
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt
  ( ProviderAwsScopeReceiptError
  , verifiedAuthorityProviderAwsScopeAccountId
  , verifiedAuthorityProviderAwsScopeRegion
  )
import Prodbox.ControlPlane.ProviderAwsScopeReceipt.Internal
  ( verifySettledAuthorityProviderAwsScopeReceipt
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( homeLinuxRke2FoundationId
  )
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , ClientSubmissionKeyError
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( longLivedCheckpointAuthorityFromBasics
  )
import Prodbox.Lifecycle.CheckpointAuthority (LongLivedCheckpointAuthority)
import Prodbox.Lifecycle.CleanupRun (mkCleanupOperationId)
import Prodbox.Lifecycle.DnsRecord (DnsCoordinateError, HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveProviderAwsScope)
  , ProviderStackConfig
  , ProviderStackConfigError
  , mkAwsEksProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , mkAwsTestProviderStackConfig
  , providerIntentCoordinate
  , providerIntentCoordinateText
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionLane
  ( AdoptableLegacyStack (AdoptAwsEks, AdoptAwsEksSubzone, AdoptAwsTest)
  , LegacyAdoptionRequest (..)
  , LegacyAdoptionSources (..)
  , adoptableLegacyStackKey
  , adoptableLegacyStackName
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionObserver
  ( LegacyAdoptionProviderObserver (..)
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchError
  , ProviderDispatchKey
  , ProviderDispatchPurpose (ProviderLegacyAdoptionObservation)
  , dispatchRegisteredProviderObservation
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  , productionTeardownProviderBoundary
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lifecycleRegistryRevision
  )
import Prodbox.Settings
  ( ValidatedCoordinates
  , coordinateAwsSubstrateSubzone
  , coordinateAwsSubstrateZoneId
  , loadConfigFile
  , validatedCoordinatesFor
  )
import Prodbox.Settings.Coordinate (route53ZoneIdText)
import Prodbox.Tls.CertScope (fqdnText)

-- | How recently the candidate family must have been observed for a
-- confirmation over it to be a statement about the present.
maximumLegacyAdoptionConfirmationSeconds :: Word
maximumLegacyAdoptionConfirmationSeconds = 300

-- | Everything that can fail before the lane runs.
data LegacyAdoptionCompositionError
  = LegacyAdoptionCompositionBasicsUnreadable !String
  | LegacyAdoptionCompositionConfigUnreadable !String
  | LegacyAdoptionCompositionCoordinatesInvalid !String
  | LegacyAdoptionCompositionZoneInvalid !DnsCoordinateError
  | LegacyAdoptionCompositionZoneMissing
  | LegacyAdoptionCompositionSubzoneMissing
  | LegacyAdoptionCompositionAuthorityCoordinateInvalid !String
  | LegacyAdoptionCompositionOperationIdInvalid !Text
  | LegacyAdoptionCompositionSubmissionKeyInvalid !ClientSubmissionKeyError
  | LegacyAdoptionCompositionDispatchKeyInvalid !ProviderDispatchError
  | LegacyAdoptionCompositionProviderConfigInvalid !ProviderStackConfigError
  | LegacyAdoptionCompositionScopeDispatchFailed !AuthorityProviderClientError
  | LegacyAdoptionCompositionScopeReceiptInvalid !ProviderAwsScopeReceiptError
  | LegacyAdoptionCompositionAuthenticationFailed
      !LifecycleAuthorityAuthenticationError
  deriving (Eq, Show)

renderLegacyAdoptionCompositionError :: LegacyAdoptionCompositionError -> String
renderLegacyAdoptionCompositionError err = case err of
  LegacyAdoptionCompositionBasicsUnreadable detail ->
    "the Tier-0 floor could not be read: " ++ detail
  LegacyAdoptionCompositionConfigUnreadable detail ->
    "the repository configuration could not be read: " ++ detail
  LegacyAdoptionCompositionCoordinatesInvalid detail ->
    "the configured coordinates are invalid: " ++ detail
  LegacyAdoptionCompositionZoneInvalid detail ->
    "the configured AWS substrate zone id is invalid: " ++ show detail
  LegacyAdoptionCompositionZoneMissing ->
    "adopting the aws-subzone stack requires a configured AWS substrate zone id"
  LegacyAdoptionCompositionSubzoneMissing ->
    "adopting the aws-subzone stack requires a configured AWS substrate subzone name"
  LegacyAdoptionCompositionAuthorityCoordinateInvalid detail ->
    "the retained authority coordinate is invalid: " ++ detail
  LegacyAdoptionCompositionOperationIdInvalid detail ->
    "the adoption operation id is invalid: " ++ Text.unpack detail
  LegacyAdoptionCompositionSubmissionKeyInvalid detail ->
    "the adoption submission key is invalid: " ++ show detail
  LegacyAdoptionCompositionDispatchKeyInvalid detail ->
    "the adoption dispatch key is invalid: " ++ show detail
  LegacyAdoptionCompositionProviderConfigInvalid detail ->
    "the stack's Provider configuration is invalid: " ++ show detail
  LegacyAdoptionCompositionScopeDispatchFailed detail ->
    "the AWS scope observation could not be dispatched: " ++ show detail
  LegacyAdoptionCompositionScopeReceiptInvalid detail ->
    "the AWS scope receipt is not a settled proof: " ++ show detail
  LegacyAdoptionCompositionAuthenticationFailed detail ->
    renderLifecycleAuthorityAuthenticationError detail

-- | Resolve the local half, open one authenticated Authority session, observe
-- the AWS scope through it, and hand the assembled sources and request to an
-- action.
--
-- Handed over rather than returned because the sources are session-scoped: a
-- record that outlived the transport would hold arms failing at their first
-- call for a reason that says nothing about the adoption.
withProductionLegacyAdoption
  :: FilePath
  -> AdoptableLegacyStack
  -> ( LegacyAdoptionSources IO
       -> LegacyAdoptionRequest
       -> IO value
     )
  -> IO (Either LegacyAdoptionCompositionError value)
withProductionLegacyAdoption repoRoot stack action = do
  startedAt <- getMonotonicTimeNSec
  local <- resolveLocal repoRoot stack
  case local of
    Left err -> pure (Left err)
    Right resolved -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication
          LifecycleAuthorityOperator
          repoRoot
          ( \authentication ->
              withLifecycleAuthorityAuthenticatedTransport authentication $
                \transport -> do
                  observed <-
                    dispatchAuthorityProviderIntentWithOperation
                      transport
                      (localScopeSubmissionKey resolved)
                      ObserveProviderAwsScope
                  case observed of
                    Left err ->
                      pure (Left (LegacyAdoptionCompositionScopeDispatchFailed err))
                    Right (operationId, receipt) ->
                      case verifySettledAuthorityProviderAwsScopeReceipt
                        operationId
                        receipt of
                        Left err ->
                          pure
                            (Left (LegacyAdoptionCompositionScopeReceiptInvalid err))
                        Right proof -> do
                          let awsScope =
                                AwsScope
                                  (verifiedAuthorityProviderAwsScopeAccountId proof)
                                  (verifiedAuthorityProviderAwsScopeRegion proof)
                          Right
                            <$> action
                              (sourcesFor resolved transport startedAt)
                              (requestFor resolved awsScope)
          )
      pure (flattenAuthentication authenticated)
 where
  flattenAuthentication outcome = case join outcome of
    Left err -> Left (LegacyAdoptionCompositionAuthenticationFailed err)
    Right value -> value

  boundary = productionTeardownProviderBoundary LifecycleAuthorityOperator repoRoot

  sourcesFor resolved transport startedAt =
    LegacyAdoptionSources
      { legacyAdoptionObserver =
          LegacyAdoptionProviderObserver $ \intent ->
            -- One dispatch key per family member, derived from the intent's
            -- own coordinate. A single key for the whole family would be a
            -- defect rather than a simplification: the submission key is the
            -- Authority's idempotency identity, so the second, third and
            -- fourth observations would replay the first one's evidence and
            -- the planner would see four answers about one resource.
            case legacyAdoptionDispatchKeyFor stack intent of
              Left err -> pure (Left (Text.pack (show err)))
              Right dispatchKey -> do
                dispatched <-
                  dispatchRegisteredProviderObservation boundary dispatchKey intent
                pure (first (Text.pack . show) dispatched)
      , legacyAdoptionRepository =
          modelBLegacyAdoptionManifestRepository
            (localAuthority resolved)
            (cascadeRetainedSlotModelBAdapter transport)
      , observeLegacyAdoptionPermitFreshness = observeFreshness startedAt
      }

  observeFreshness startedAt = do
    now <- getMonotonicTimeNSec
    let elapsedSeconds = (now - startedAt) `div` 1000000000
    pure
      ( if elapsedSeconds
          <= fromIntegral maximumLegacyAdoptionConfirmationSeconds
          then PermitFresh
          else PermitExpired
      )

  -- Stable across re-runs for one stack and one family member, so a repeated
  -- plan pass replays the Authority's retained observation instead of
  -- allocating a new identity for the same question.
  requestFor resolved awsScope =
    LegacyAdoptionRequest
      { legacyAdoptionRequestStackKey = adoptableLegacyStackKey stack
      , legacyAdoptionRequestScope = case localAwsDnsZone resolved of
          Nothing ->
            mkObservationEvidenceScope
              ExplicitPerRun
              lifecycleRegistryRevision
              (localRunScope resolved)
              (localFoundation resolved)
              (Just awsScope)
              ReconcileDesiredAbsent
          Just zone ->
            mkObservationEvidenceScopeWithDnsZone
              ExplicitPerRun
              lifecycleRegistryRevision
              (localRunScope resolved)
              (localFoundation resolved)
              (Just awsScope)
              zone
              ReconcileDesiredAbsent
      , legacyAdoptionRequestRevision =
          observationRevisionForProviderDispatchKey (localDispatchKey resolved)
      , legacyAdoptionRequestProviderConfig = localProviderConfig resolved
      }

-- | The Authority dispatch key one adoption observation is submitted under.
--
-- __One key per family member, and that is the whole point.__ The submission
-- key is the Authority's idempotency identity, so a single key for the whole
-- family would make the second, third and fourth observations replay the
-- first's evidence — the planner would then see four answers about one
-- resource, which is precisely the ambiguity the closed family exists to
-- refuse, arriving in a shape the planner cannot detect.
--
-- __And it is stable across re-runs.__ It is derived from the stack and the
-- intent's own coordinate rather than from a clock, so repeating the plan pass
-- replays the Authority's retained observation instead of allocating a new
-- identity for the same question.
--
-- The coordinate is unbounded and carries characters an operation id refuses,
-- so the member is named by a fixed-width digest of it. That digest is an
-- identity and never evidence: nothing decides anything from these bytes.
legacyAdoptionDispatchKeyFor
  :: AdoptableLegacyStack
  -> ProviderIntent
  -> Either LegacyAdoptionCompositionError ProviderDispatchKey
legacyAdoptionDispatchKeyFor stack intent = do
  operationId <-
    first
      LegacyAdoptionCompositionOperationIdInvalid
      ( mkCleanupOperationId
          ("legacy-adopt-" <> adoptableLegacyStackName stack <> ":" <> memberDigest)
      )
  first
    LegacyAdoptionCompositionDispatchKeyInvalid
    (mkProviderDispatchKey operationId ProviderLegacyAdoptionObservation)
 where
  memberDigest =
    Text.take
      32
      ( TextEncoding.decodeUtf8
          ( hexSha256
              ( TextEncoding.encodeUtf8
                  (providerIntentCoordinateText (providerIntentCoordinate intent))
              )
          )
      )

-- | Everything the composition can answer before any transport is opened.
--
-- Named and returned as a value so the transport-free half is exercisable, and
-- so a malformed coordinate is reported as a configuration fault rather than as
-- an Authority failure after a session has already been taken.
data LocalLegacyAdoptionComposition = LocalLegacyAdoptionComposition
  { localAuthority :: !LongLivedCheckpointAuthority
  , localFoundation :: !LinuxRke2FoundationId
  , localRunScope :: !DurableObservationRunScope
  , localScopeSubmissionKey :: !ClientSubmissionKey
  , localDispatchKey :: !ProviderDispatchKey
  , localProviderConfig :: !ProviderStackConfig
  , localAwsDnsZone :: !(Maybe HostedZoneId)
  }

resolveLocal
  :: FilePath
  -> AdoptableLegacyStack
  -> IO (Either LegacyAdoptionCompositionError LocalLegacyAdoptionComposition)
resolveLocal repoRoot stack = do
  basicsResult <- loadUnencryptedBasics repoRoot
  configResult <- loadConfigFile repoRoot
  pure $ do
    basics <- first LegacyAdoptionCompositionBasicsUnreadable basicsResult
    config <- first LegacyAdoptionCompositionConfigUnreadable configResult
    coordinates <-
      first LegacyAdoptionCompositionCoordinatesInvalid (validatedCoordinatesFor config)
    authority <-
      first
        (LegacyAdoptionCompositionAuthorityCoordinateInvalid . show)
        (longLivedCheckpointAuthorityFromBasics basics)
    (providerConfig, dnsZone) <- resolveProviderConfig coordinates
    operationId <-
      first
        LegacyAdoptionCompositionOperationIdInvalid
        (mkCleanupOperationId ("legacy-adopt-" <> stackName))
    submissionKey <-
      first
        LegacyAdoptionCompositionSubmissionKeyInvalid
        (mkClientSubmissionKey ("legacy-adoption-scope:" <> stackName))
    dispatchKey <-
      first
        LegacyAdoptionCompositionDispatchKeyInvalid
        (mkProviderDispatchKey operationId ProviderLegacyAdoptionObservation)
    pure
      LocalLegacyAdoptionComposition
        { localAuthority = authority
        , localFoundation = homeLinuxRke2FoundationId (basicsClusterId basics)
        , localRunScope = DurableObservationRunScope ("legacy-adoption/" <> stackName)
        , localScopeSubmissionKey = submissionKey
        , localDispatchKey = dispatchKey
        , localProviderConfig = providerConfig
        , localAwsDnsZone = dnsZone
        }
 where
  stackName = adoptableLegacyStackName stack

  -- The operator CIDR is the Provider's own concern for a destroy-side
  -- observation: nothing in the adoption family reads it, and the loopback
  -- value keeps the validated config from widening any network reach.
  -- The subzone arm is the only one that needs a zone, and it needs it twice:
  -- the Provider config carries the parent zone and the subzone name, and the
  -- native-stack-family observation request refuses a subzone scope that names
  -- no hosted zone.  Both come from the same validated coordinate, so they
  -- cannot describe different zones.
  resolveProviderConfig
    :: ValidatedCoordinates
    -> Either
         LegacyAdoptionCompositionError
         (ProviderStackConfig, Maybe HostedZoneId)
  resolveProviderConfig coordinates = case stack of
    AdoptAwsEks ->
      (,Nothing)
        <$> first
          LegacyAdoptionCompositionProviderConfigInvalid
          (mkAwsEksProviderStackConfig loopbackOperatorCidr)
    AdoptAwsTest ->
      (,Nothing)
        <$> first
          LegacyAdoptionCompositionProviderConfigInvalid
          (mkAwsTestProviderStackConfig loopbackOperatorCidr)
    AdoptAwsEksSubzone -> do
      zoneIdText <-
        maybe
          (Left LegacyAdoptionCompositionZoneMissing)
          (Right . route53ZoneIdText)
          (coordinateAwsSubstrateZoneId coordinates)
      subzone <-
        maybe
          (Left LegacyAdoptionCompositionSubzoneMissing)
          (Right . fqdnText)
          (coordinateAwsSubstrateSubzone coordinates)
      hostedZone <-
        first LegacyAdoptionCompositionZoneInvalid (mkHostedZoneId zoneIdText)
      config <-
        first
          LegacyAdoptionCompositionProviderConfigInvalid
          (mkAwsEksSubzoneProviderStackConfig zoneIdText subzone)
      pure (config, Just hostedZone)

  loopbackOperatorCidr = "127.0.0.1/32"
