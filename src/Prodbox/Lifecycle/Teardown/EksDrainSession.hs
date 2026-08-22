{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A short-lived, exact-target authorization for draining the remote EKS
-- control plane.  Checkpoint output, a terminal audit, and ambient kubeconfig
-- state cannot construct this value: the smart constructor requires a
-- positively-present observation for the registered @aws-eks@ identity and a
-- Provider-issued client projection bound to the same account, region, and
-- cluster.
module Prodbox.Lifecycle.Teardown.EksDrainSession
  ( EksClusterArn
  , eksClusterArnText
  , EksClusterUid
  , eksClusterUidText
  , EksDrainSessionId
  , eksDrainSessionIdText
  , EksKubernetesIdentityResult (..)
  , EksKubernetesIdentityObservation (..)
  , eksKubernetesIdentityObservationFor
  , EksDrainSession
  , eksDrainSessionOperationId
  , eksDrainSessionEvidenceScope
  , eksDrainSessionObservationRevision
  , eksDrainSessionKubernetesRevision
  , eksDrainSessionClusterArn
  , eksDrainSessionClusterUid
  , eksDrainSessionEndpointDigest
  , eksDrainSessionCertificateAuthorityDigest
  , eksDrainSessionExpiresAtEpochSeconds
  , withEksDrainClientProjection
  , EksDrainSessionError (..)
  , eksClusterArnFromExactObservation
  , mkEksDrainSession
  , validateEksDrainSession
  , maximumEksDrainLifetimeSeconds
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  , eksClientAuthAccountId
  , eksClientAuthBearerToken
  , eksClientAuthCertificateAuthorityData
  , eksClientAuthClusterArn
  , eksClientAuthClusterName
  , eksClientAuthEndpoint
  , eksClientAuthExpiresAtEpochSeconds
  , eksClientAuthRegion
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Registry

newtype EksClusterArn = EksClusterArn Text
  deriving (Eq, Ord, Show)

eksClusterArnText :: EksClusterArn -> Text
eksClusterArnText (EksClusterArn value) = value

newtype EksClusterUid = EksClusterUid Text
  deriving (Eq, Ord, Show)

eksClusterUidText :: EksClusterUid -> Text
eksClusterUidText (EksClusterUid value) = value

newtype EksDrainSessionId = EksDrainSessionId Text
  deriving (Eq, Ord, Show)

eksDrainSessionIdText :: EksDrainSessionId -> Text
eksDrainSessionIdText (EksDrainSessionId value) = value

-- | Flat read-only Kubernetes observation made with the Provider projection
-- before any drain mutation.  Its constructor is public because decoders may
-- return stale or malformed bindings; 'mkEksDrainSession' is the admission
-- boundary.  The UID is deliberately not accepted from a checkpoint or a
-- cluster-wide AWS audit.
data EksKubernetesIdentityResult
  = EksKubernetesIdentityPresent !Text
  | EksKubernetesIdentityAbsent !AbsenceEvidence
  | EksKubernetesIdentityUnobservable !ObservationFailure
  deriving (Eq, Show)

data EksKubernetesIdentityObservation = EksKubernetesIdentityObservation
  { eksKubernetesIdentityScope :: !ObservationEvidenceScope
  , eksKubernetesIdentityRevision :: !ObservationRevision
  , eksKubernetesIdentityClusterArn :: !Text
  , eksKubernetesIdentityEndpointDigest :: !Text
  , eksKubernetesIdentityCertificateAuthorityDigest :: !Text
  , eksKubernetesIdentityResult :: !EksKubernetesIdentityResult
  }
  deriving (Eq, Show)

eksKubernetesIdentityObservationFor
  :: ObservationEvidenceScope
  -> ObservationRevision
  -> Text
  -> EksKubernetesIdentityResult
  -> EksClientAuthProjection
  -> EksKubernetesIdentityObservation
eksKubernetesIdentityObservationFor scope revision clusterArn result projection =
  EksKubernetesIdentityObservation
    { eksKubernetesIdentityScope = scope
    , eksKubernetesIdentityRevision = revision
    , eksKubernetesIdentityClusterArn = clusterArn
    , eksKubernetesIdentityEndpointDigest =
        sha256Text (eksClientAuthEndpoint projection)
    , eksKubernetesIdentityCertificateAuthorityDigest =
        sha256Text (eksClientAuthCertificateAuthorityData projection)
    , eksKubernetesIdentityResult = result
    }

-- | The projection is deliberately retained behind an eliminator rather than
-- exposed as a record field.  Its 'Show' instance is already redacted, and the
-- session's own 'Show' instance never includes the bearer.
data EksDrainSession = EksDrainSession
  { internalEksDrainSessionId :: !EksDrainSessionId
  , internalEksDrainSessionOperationId :: !CleanupOperationId
  , internalEksDrainSessionEvidenceScope :: !ObservationEvidenceScope
  , internalEksDrainSessionObservationRevision :: !ObservationRevision
  , internalEksDrainSessionKubernetesRevision :: !ObservationRevision
  , internalEksDrainSessionClusterArn :: !EksClusterArn
  , internalEksDrainSessionClusterUid :: !EksClusterUid
  , internalEksDrainSessionEndpointDigest :: !Text
  , internalEksDrainSessionCertificateAuthorityDigest :: !Text
  , internalEksDrainSessionTokenDigest :: !Text
  , internalEksDrainSessionExpiresAtEpochSeconds :: !Integer
  , internalEksDrainSessionProjection :: !EksClientAuthProjection
  }
  deriving (Eq)

instance Show EksDrainSession where
  show session =
    "<eks-drain-session:id="
      <> Text.unpack (eksDrainSessionIdText (internalEksDrainSessionId session))
      <> ",cluster="
      <> Text.unpack (eksClusterArnText (internalEksDrainSessionClusterArn session))
      <> ",expires="
      <> show (internalEksDrainSessionExpiresAtEpochSeconds session)
      <> ">"

eksDrainSessionOperationId :: EksDrainSession -> CleanupOperationId
eksDrainSessionOperationId = internalEksDrainSessionOperationId

eksDrainSessionEvidenceScope :: EksDrainSession -> ObservationEvidenceScope
eksDrainSessionEvidenceScope = internalEksDrainSessionEvidenceScope

eksDrainSessionObservationRevision :: EksDrainSession -> ObservationRevision
eksDrainSessionObservationRevision = internalEksDrainSessionObservationRevision

eksDrainSessionKubernetesRevision :: EksDrainSession -> ObservationRevision
eksDrainSessionKubernetesRevision = internalEksDrainSessionKubernetesRevision

eksDrainSessionClusterArn :: EksDrainSession -> EksClusterArn
eksDrainSessionClusterArn = internalEksDrainSessionClusterArn

eksDrainSessionClusterUid :: EksDrainSession -> EksClusterUid
eksDrainSessionClusterUid = internalEksDrainSessionClusterUid

eksDrainSessionEndpointDigest :: EksDrainSession -> Text
eksDrainSessionEndpointDigest = internalEksDrainSessionEndpointDigest

eksDrainSessionCertificateAuthorityDigest :: EksDrainSession -> Text
eksDrainSessionCertificateAuthorityDigest =
  internalEksDrainSessionCertificateAuthorityDigest

eksDrainSessionExpiresAtEpochSeconds :: EksDrainSession -> Integer
eksDrainSessionExpiresAtEpochSeconds = internalEksDrainSessionExpiresAtEpochSeconds

withEksDrainClientProjection
  :: EksDrainSession -> (EksClientAuthProjection -> value) -> value
withEksDrainClientProjection session consume =
  consume (internalEksDrainSessionProjection session)

data EksDrainSessionError
  = EksDrainObservationKeyMismatch !RegisteredResourceKey
  | EksDrainObservationCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | EksDrainObservationAuthorityMismatch !ObservationAuthority
  | EksDrainObservationScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainObservationSurfaceInvalid !CleanupSurface
  | EksDrainObservationOperationInvalid !LifecycleOperation
  | EksDrainObservationAwsScopeMissing
  | EksDrainObservationNotPresent !ExactObservationResult
  | EksDrainClusterArnInvalid !Text
  | EksDrainClusterUidInvalid !Text
  | EksDrainClusterArnMissing
  | EksDrainClusterArnAmbiguous ![Text]
  | EksDrainKubernetesScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | EksDrainKubernetesClusterArnMismatch !EksClusterArn !Text
  | EksDrainKubernetesEndpointMismatch !Text !Text
  | EksDrainKubernetesCertificateAuthorityMismatch !Text !Text
  | EksDrainKubernetesIdentityNotPresent !EksKubernetesIdentityResult
  | EksDrainProjectionAccountMismatch !AwsAccountId !Text
  | EksDrainProjectionRegionMismatch !AwsRegion !Text
  | EksDrainProjectionClusterMismatch !Text !Text
  | EksDrainProjectionClusterArnMismatch !EksClusterArn !Text
  | EksDrainDeadlineInvalid !Integer !Integer
  | EksDrainDeadlineBeyondMaximum !Integer !Integer
  | EksDrainProjectionExpired !Integer !Integer
  | EksDrainSessionBindingMismatch
  | EksDrainSessionExpired !Integer !Integer
  deriving (Eq, Show)

-- | Mint one drain authorization.  The deadline is supplied explicitly so
-- the caller cannot later extend the Provider-issued bearer lifetime.
mkEksDrainSession
  :: Integer
  -> Integer
  -> CleanupOperationId
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksKubernetesIdentityObservation
  -> EksClientAuthProjection
  -> Either EksDrainSessionError EksDrainSession
mkEksDrainSession now deadline operationId expectedScope verified kubernetes projection = do
  let observation = verifiedAwsEksExactObservation verified
  clusterArn <- eksClusterArnFromExactObservation expectedScope observation
  awsScope <-
    maybe (Left EksDrainObservationAwsScopeMissing) Right (evidenceAwsScope expectedScope)
  validateProjectionBinding awsScope clusterArn projection
  let endpointDigest = sha256Text (eksClientAuthEndpoint projection)
      caDigest = sha256Text (eksClientAuthCertificateAuthorityData projection)
  clusterUid <-
    validateKubernetesIdentity
      expectedScope
      clusterArn
      endpointDigest
      caDigest
      kubernetes
  let projectionExpiry = eksClientAuthExpiresAtEpochSeconds projection
  if projectionExpiry <= now
    then Left (EksDrainProjectionExpired now projectionExpiry)
    else Right ()
  if deadline <= now || deadline > projectionExpiry
    then Left (EksDrainDeadlineInvalid now deadline)
    else Right ()
  if deadline > now + maximumEksDrainLifetimeSeconds
    then Left (EksDrainDeadlineBeyondMaximum deadline maximumEksDrainLifetimeSeconds)
    else Right ()
  let tokenDigest = sha256Text (eksClientAuthBearerToken projection)
      sessionId =
        EksDrainSessionId
          ( sha256Fields
              [ "eks-drain-session/v2"
              , cleanupOperationIdText operationId
              , renderEvidenceScope expectedScope
              , renderObservationRevision (exactObservationRevision observation)
              , renderObservationRevision (eksKubernetesIdentityRevision kubernetes)
              , eksClusterArnText clusterArn
              , eksClusterUidText clusterUid
              , endpointDigest
              , caDigest
              , tokenDigest
              , Text.pack (show deadline)
              ]
          )
  Right
    EksDrainSession
      { internalEksDrainSessionId = sessionId
      , internalEksDrainSessionOperationId = operationId
      , internalEksDrainSessionEvidenceScope = expectedScope
      , internalEksDrainSessionObservationRevision =
          exactObservationRevision observation
      , internalEksDrainSessionKubernetesRevision =
          eksKubernetesIdentityRevision kubernetes
      , internalEksDrainSessionClusterArn = clusterArn
      , internalEksDrainSessionClusterUid = clusterUid
      , internalEksDrainSessionEndpointDigest = endpointDigest
      , internalEksDrainSessionCertificateAuthorityDigest = caDigest
      , internalEksDrainSessionTokenDigest = tokenDigest
      , internalEksDrainSessionExpiresAtEpochSeconds = deadline
      , internalEksDrainSessionProjection = projection
      }

eksClusterArnFromExactObservation
  :: ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either EksDrainSessionError EksClusterArn
eksClusterArnFromExactObservation expectedScope observation = do
  validateObservationBinding expectedScope observation
  awsScope <-
    maybe (Left EksDrainObservationAwsScopeMissing) Right (evidenceAwsScope expectedScope)
  inventory <- case exactObservationResult observation of
    ExactResourcePresent present -> Right present
    other -> Left (EksDrainObservationNotPresent other)
  clusterArnFromInventory awsScope inventory

-- | Revalidate the complete authority binding immediately before use.  This
-- is intentionally stronger than a deadline check: a session cannot be
-- replayed under another durable cleanup run or a refreshed/different exact
-- cluster observation.
validateEksDrainSession
  :: Integer
  -> CleanupOperationId
  -> ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> EksKubernetesIdentityObservation
  -> EksDrainSession
  -> Either EksDrainSessionError ()
validateEksDrainSession now operationId expectedScope verified kubernetes session = do
  if now >= internalEksDrainSessionExpiresAtEpochSeconds session
    then
      Left
        ( EksDrainSessionExpired
            now
            (internalEksDrainSessionExpiresAtEpochSeconds session)
        )
    else Right ()
  rebuilt <-
    mkEksDrainSession
      now
      (internalEksDrainSessionExpiresAtEpochSeconds session)
      operationId
      expectedScope
      verified
      kubernetes
      (internalEksDrainSessionProjection session)
  if rebuilt == session
    then Right ()
    else Left EksDrainSessionBindingMismatch

validateObservationBinding
  :: ObservationEvidenceScope
  -> ExactResourceObservation
  -> Either EksDrainSessionError ()
validateObservationBinding expectedScope observation = do
  identity <-
    maybe
      (Left (EksDrainObservationKeyMismatch (exactObservationResourceKey observation)))
      Right
      (lookupRegisteredIdentity AwsEksKey)
  if exactObservationResourceKey observation /= AwsEksKey
    then Left (EksDrainObservationKeyMismatch (exactObservationResourceKey observation))
    else Right ()
  let expectedCoordinate = registeredIdentityCoordinateDigest identity
  if exactObservationCoordinateDigest observation /= expectedCoordinate
    then
      Left
        ( EksDrainObservationCoordinateMismatch
            expectedCoordinate
            (exactObservationCoordinateDigest observation)
        )
    else Right ()
  if exactObservationAuthority observation /= AwsResourceApiAuthority
    then Left (EksDrainObservationAuthorityMismatch (exactObservationAuthority observation))
    else Right ()
  if exactObservationEvidenceScope observation /= expectedScope
    then
      Left
        ( EksDrainObservationScopeMismatch
            expectedScope
            (exactObservationEvidenceScope observation)
        )
    else Right ()
  case evidenceCleanupSurface expectedScope of
    Cascade -> Right ()
    ExplicitPerRun -> Right ()
    TotalDecommission -> Right ()
    observed -> Left (EksDrainObservationSurfaceInvalid observed)
  if evidenceLifecycleOperation expectedScope == ReconcileDesiredAbsent
    then Right ()
    else
      Left
        ( EksDrainObservationOperationInvalid
            (evidenceLifecycleOperation expectedScope)
        )

mkEksClusterArn
  :: AwsScope -> Text -> Either EksDrainSessionError EksClusterArn
mkEksClusterArn scope raw = case Text.splitOn ":" raw of
  ["arn", partition, "eks", region, account, resource]
    | partition `elem` ["aws", "aws-cn", "aws-us-gov"]
    , region == awsRegionText (awsScopeRegion scope)
    , account == awsAccountIdText (awsScopeAccountId scope)
    , Just clusterName <- Text.stripPrefix "cluster/" resource
    , validIdentity clusterName ->
        Right (EksClusterArn raw)
  _ -> Left (EksDrainClusterArnInvalid raw)

mkEksClusterUid :: Text -> Either EksDrainSessionError EksClusterUid
mkEksClusterUid raw
  | validIdentity raw = Right (EksClusterUid raw)
  | otherwise = Left (EksDrainClusterUidInvalid raw)

clusterArnFromInventory
  :: AwsScope
  -> ExactResourceInventory
  -> Either EksDrainSessionError EksClusterArn
clusterArnFromInventory awsScope (ExactResourceInventory identities) =
  case [ identity
       | ObservedResourceIdentity identity <- NonEmpty.toList identities
       ] of
    [rawArn] -> mkEksClusterArn awsScope rawArn
    [] -> Left EksDrainClusterArnMissing
    rawArns -> Left (EksDrainClusterArnAmbiguous rawArns)

validateKubernetesIdentity
  :: ObservationEvidenceScope
  -> EksClusterArn
  -> Text
  -> Text
  -> EksKubernetesIdentityObservation
  -> Either EksDrainSessionError EksClusterUid
validateKubernetesIdentity expectedScope clusterArn endpointDigest caDigest observation = do
  if eksKubernetesIdentityScope observation == expectedScope
    then Right ()
    else
      Left
        ( EksDrainKubernetesScopeMismatch
            expectedScope
            (eksKubernetesIdentityScope observation)
        )
  if eksKubernetesIdentityClusterArn observation == eksClusterArnText clusterArn
    then Right ()
    else
      Left
        ( EksDrainKubernetesClusterArnMismatch
            clusterArn
            (eksKubernetesIdentityClusterArn observation)
        )
  if eksKubernetesIdentityEndpointDigest observation == endpointDigest
    then Right ()
    else
      Left
        ( EksDrainKubernetesEndpointMismatch
            endpointDigest
            (eksKubernetesIdentityEndpointDigest observation)
        )
  if eksKubernetesIdentityCertificateAuthorityDigest observation == caDigest
    then Right ()
    else
      Left
        ( EksDrainKubernetesCertificateAuthorityMismatch
            caDigest
            (eksKubernetesIdentityCertificateAuthorityDigest observation)
        )
  case eksKubernetesIdentityResult observation of
    EksKubernetesIdentityPresent rawUid -> mkEksClusterUid rawUid
    other -> Left (EksDrainKubernetesIdentityNotPresent other)

validateProjectionBinding
  :: AwsScope
  -> EksClusterArn
  -> EksClientAuthProjection
  -> Either EksDrainSessionError ()
validateProjectionBinding scope clusterArn projection = do
  let expectedAccount = awsScopeAccountId scope
      expectedRegion = awsScopeRegion scope
      observedAccount = eksClientAuthAccountId projection
      observedRegion = eksClientAuthRegion projection
      expectedCluster = clusterNameFromArn clusterArn
      observedCluster = eksClientAuthClusterName projection
      observedClusterArn = eksClientAuthClusterArn projection
  if observedAccount == awsAccountIdText expectedAccount
    then Right ()
    else Left (EksDrainProjectionAccountMismatch expectedAccount observedAccount)
  if observedRegion == awsRegionText expectedRegion
    then Right ()
    else Left (EksDrainProjectionRegionMismatch expectedRegion observedRegion)
  if observedCluster == expectedCluster
    then Right ()
    else Left (EksDrainProjectionClusterMismatch expectedCluster observedCluster)
  if observedClusterArn == eksClusterArnText clusterArn
    then Right ()
    else Left (EksDrainProjectionClusterArnMismatch clusterArn observedClusterArn)

clusterNameFromArn :: EksClusterArn -> Text
clusterNameFromArn (EksClusterArn raw) =
  case Text.breakOnEnd "cluster/" raw of
    (_, name) -> name

awsAccountIdText :: AwsAccountId -> Text
awsAccountIdText (AwsAccountId value) = value

awsRegionText :: AwsRegion -> Text
awsRegionText (AwsRegion value) = value

validIdentity :: Text -> Bool
validIdentity value =
  not (Text.null value)
    && Text.length value <= 256
    && Text.all validCharacter value
 where
  validCharacter character =
    isAsciiUpper character
      || isAsciiLower character
      || isDigit character
      || character `elem` ("-._/" :: String)

sha256Fields :: [Text] -> Text
sha256Fields = sha256Text . canonicalFields

canonicalFields :: [Text] -> Text
canonicalFields = Text.concat . map frame
 where
  frame field = Text.pack (show (Text.length field)) <> ":" <> field

renderEvidenceScope :: ObservationEvidenceScope -> Text
renderEvidenceScope scope =
  canonicalFields
    [ Text.pack (show (evidenceCleanupSurface scope))
    , revisionText (evidenceRegistryRevision scope)
    , runScopeText (evidenceDurableRunScope scope)
    , foundationText (evidenceLinuxRke2Foundation scope)
    , maybe "no-aws" renderAwsScope (evidenceAwsScope scope)
    , Text.pack (show (evidenceLifecycleOperation scope))
    ]
 where
  revisionText (RegistryRevision value) = value
  runScopeText (DurableObservationRunScope value) = value
  foundationText (LinuxRke2FoundationId value) = value
  renderAwsScope (AwsScope (AwsAccountId account) (AwsRegion region)) =
    account <> "/" <> region

renderObservationRevision :: ObservationRevision -> Text
renderObservationRevision (ObservationRevision revision) = Text.pack (show revision)

maximumEksDrainLifetimeSeconds :: Integer
maximumEksDrainLifetimeSeconds = 900

sha256Text :: Text -> Text
sha256Text value =
  Text.pack
    ( concatMap
        renderHexByte
        (ByteString.unpack (SHA256.hash (TextEncoding.encodeUtf8 value)))
    )
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits
