{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50 (Increment DD): the pure decision algebra for the fenced Provider
-- Worker role.
--
-- The Provider Worker is the one control-plane role that runs rare provider tooling
-- (registered-stack Pulumi reconcile, bounded scratch checkpoint execution,
-- authoritative observation and read-back, and the @aws-ses@ non-credential
-- inventory) under one narrow session, on an already sealed/read-back
-- Lifecycle-provider generation supplied by the Lifecycle Authority. Its fence is
-- both structural and dynamic:
--
--   * __Structural.__ 'ProviderIntent' is a closed sum. It cannot represent a
--     credential IAM identity/access-key create/delete/remint, an admin or
--     credential permit, an Authority state write, a backup/TLS identity, a target
--     secret, a Gateway/DNS election, or any SMTP IAM principal/policy/key — those
--     capabilities are unrepresentable, not merely rejected. The @aws-ses@ arm is
--     limited to the sending identity, DKIM, receipt rules, and capture bucket.
--   * __Dynamic.__ 'decideProviderWork' refuses an intent naming an unregistered
--     resource, a stale provider revision, or an expired session; and it admits at
--     most one intent at a time (a second, different intent is refused while one is
--     in flight). Canceled, expired, or ambiguous work enters explicit recovery and
--     a post-recovery grace state before a successor is admitted; a clean,
--     re-observed close returns straight to idle for immediate successor admission.
--
-- This module is pure and total. It mirrors the @decide@ / @evolve@ /
-- @decisionEvents@ / @step@ shape of 'Prodbox.Lifecycle.Authority.BackupRepair' and
-- 'Prodbox.Lifecycle.Authority.Genesis'. Binding the admitted decision to the real
-- narrow-session provider execution (Pulumi/AWS effect + authoritative read-back)
-- and to the retained-store compare-and-swap of the work state is the live-coupled
-- follow-on (Standard-O); the algebra fixes the admission/idempotency/fence
-- discipline so that follow-on cannot loosen it.
module Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( -- * Smart-constructed resource references
    ProviderRefError (..)
  , ProviderStackRef
  , mkProviderStackRef
  , providerStackRefText
  , ProviderCheckpointRef
  , mkProviderCheckpointRef
  , providerCheckpointRefText
  , SesIdentityRef
  , mkSesIdentityRef
  , sesIdentityRefText
  , SesRuleSetRef
  , mkSesRuleSetRef
  , sesRuleSetRefText
  , sesRuleSetRecipient
  , sesRuleSetCaptureBucket
  , SesBucketRef
  , mkSesBucketRef
  , sesBucketRefText
  , SesDnsRef
  , mkSesDnsRef
  , sesDnsHostedZoneId
  , sesDnsIdentityDomain
  , sesDnsReceiveSubdomain
  , PublicARecordRef
  , mkPublicARecordRef
  , publicARecordHostedZoneId
  , publicARecordFqdn
  , publicARecordTtl
  , publicARecordValues

    -- * Closed stack programs
  , ProviderStackConfig (..)
  , ProviderStackConfigError (..)
  , mkAwsEksProviderStackConfig
  , mkAwsTestProviderStackConfig
  , mkAwsEksSubzoneProviderStackConfig
  , providerStackConfigRef
  , validateProviderStackConfig

    -- * Closed native AWS programs
  , ProviderSpotPriceQuery
  , mkProviderSpotPriceQuery
  , providerSpotPriceInstanceType
  , providerSpotPriceProductDescription
  , ProviderReadinessProbe (..)
  , EksClientAuthRequest
  , mkEksClientAuthRequest
  , eksClientAuthRequestAccountId
  , eksClientAuthRequestRegion
  , eksClientAuthRequestClusterName
  , eksClientAuthRequestDestinationPublicKey

    -- * Provider revision
  , ProviderRevision
  , mkProviderRevision
  , providerRevisionNatural

    -- * Registered provider resources
  , RegisteredProviderResources
  , mkRegisteredProviderResources
  , registeredProviderResourceKeys
  , isProviderResourceRegistered

    -- * Intents and coordinates
  , ProviderIntent (..)
  , providerIntentResourceKey
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  , providerIntentCoordinateFromText
  , providerIntentCoordinateText

    -- * State
  , ProviderWorkState (..)
  , initialProviderWorkState
  , providerWorkActiveCoordinate

    -- * Decision algebra
  , ProviderWorkCommand (..)
  , ProviderWorkDecision (..)
  , ProviderWorkRefusal (..)
  , ProviderWorkEvent (..)
  , decideProviderWork
  , providerWorkDecisionEvents
  , evolveProviderWork
  , stepProviderWork
  )
where

import Codec.Serialise (Serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)

-- | Why a raw provider-resource reference failed validation.
data ProviderRefError
  = ProviderRefEmpty
  | ProviderRefTooLong !Int
  | ProviderRefMalformed !Text
  deriving (Eq, Show)

-- | The maximum reference length; a bounded key keeps coordinates and registered
-- sets small and prevents an unbounded body from smuggling a huge key.
maximumProviderRefLength :: Int
maximumProviderRefLength = 200

validateProviderRef :: Text -> Either ProviderRefError Text
validateProviderRef raw
  | Text.null raw = Left ProviderRefEmpty
  | Text.length raw > maximumProviderRefLength = Left (ProviderRefTooLong (Text.length raw))
  | otherwise = Right raw

-- | A registered Pulumi/provider stack the worker may reconcile, observe, or read
-- back. The named IAM roles it owns are non-credential by construction.
newtype ProviderStackRef = ProviderStackRef Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkProviderStackRef :: Text -> Either ProviderRefError ProviderStackRef
mkProviderStackRef = fmap ProviderStackRef . validateProviderRef

providerStackRefText :: ProviderStackRef -> Text
providerStackRefText (ProviderStackRef value) = value

-- | A bounded scratch-checkpoint execution target.
newtype ProviderCheckpointRef = ProviderCheckpointRef Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkProviderCheckpointRef :: Text -> Either ProviderRefError ProviderCheckpointRef
mkProviderCheckpointRef = fmap ProviderCheckpointRef . validateProviderRef

providerCheckpointRefText :: ProviderCheckpointRef -> Text
providerCheckpointRefText (ProviderCheckpointRef value) = value

-- | An @aws-ses@ sending identity (also the DKIM subject).
newtype SesIdentityRef = SesIdentityRef Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkSesIdentityRef :: Text -> Either ProviderRefError SesIdentityRef
mkSesIdentityRef = fmap SesIdentityRef . validateProviderRef

sesIdentityRefText :: SesIdentityRef -> Text
sesIdentityRefText (SesIdentityRef value) = value

-- | The exact @aws-ses@ receipt-rule program.  A rule-set name alone is not
-- enough to reconcile a useful receiving lane: the admitted intent must also
-- bind the sole recipient and capture bucket so neither can be recovered from
-- ambient configuration inside the Provider Worker.
data SesRuleSetRef = SesRuleSetRef
  { sesRuleSetRefText :: !Text
  , sesRuleSetRecipient :: !Text
  , sesRuleSetCaptureBucket :: !SesBucketRef
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkSesRuleSetRef :: Text -> Text -> Text -> Either ProviderRefError SesRuleSetRef
mkSesRuleSetRef rawRuleSet rawRecipient rawBucket = do
  ruleSet <- validateProviderRef rawRuleSet
  recipient <- validateProviderRef rawRecipient
  bucket <- SesBucketRef <$> validateProviderRef rawBucket
  pure
    SesRuleSetRef
      { sesRuleSetRefText = ruleSet
      , sesRuleSetRecipient = recipient
      , sesRuleSetCaptureBucket = bucket
      }

-- | An @aws-ses@ capture (inbound-mail) bucket.
newtype SesBucketRef = SesBucketRef Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkSesBucketRef :: Text -> Either ProviderRefError SesBucketRef
mkSesBucketRef = fmap SesBucketRef . validateProviderRef

sesBucketRefText :: SesBucketRef -> Text
sesBucketRefText (SesBucketRef value) = value

-- | The exact Route 53 coordinate set owned by the @aws-ses@ Provider
-- program. The AWS region is supplied by the same sealed narrow-session
-- credential used for SES, so the regional MX target cannot drift from the
-- account/region in which the receive rule is reconciled.
data SesDnsRef = SesDnsRef
  { sesDnsHostedZoneId :: !Text
  , sesDnsIdentityDomain :: !Text
  , sesDnsReceiveSubdomain :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | Exact registered AWS public-edge A record. Account/region are sealed by
-- the Provider session and the Authority registry; the intent binds the zone,
-- canonical name, TTL, and complete value set.
data PublicARecordRef = PublicARecordRef
  { publicARecordHostedZoneId :: !Text
  , publicARecordFqdn :: !Text
  , publicARecordTtl :: !Natural
  , publicARecordValues :: ![Text]
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

mkPublicARecordRef
  :: Text -> Text -> Natural -> [Text] -> Either ProviderRefError PublicARecordRef
mkPublicARecordRef rawZone rawFqdn ttl values = do
  zone <- validateProviderRef rawZone
  fqdn <- validateProviderRef (Text.toLower (Text.dropWhileEnd (== '.') rawFqdn))
  if ttl == 0 || ttl > 2147483647
    then Left (ProviderRefMalformed "public A-record TTL")
    else Right ()
  if null values || any (not . validIpv4) values
    then Left (ProviderRefMalformed "public A-record values")
    else Right ()
  pure (PublicARecordRef zone fqdn ttl (Set.toAscList (Set.fromList values)))
 where
  validIpv4 value = case traverse octet (Text.splitOn "." value) of
    Just [_, _, _, _] -> True
    _ -> False
  octet raw
    | Text.null raw || not (Text.all isDigit raw) = Nothing
    | Text.length raw > 1 && Text.head raw == '0' = Nothing
    | otherwise =
        let value = read (Text.unpack raw) :: Int
         in if value <= 255 then Just value else Nothing

mkSesDnsRef :: Text -> Text -> Text -> Either ProviderRefError SesDnsRef
mkSesDnsRef rawZoneId rawIdentity rawReceiveSubdomain = do
  zoneId <- validateProviderRef rawZoneId
  identity <- validateProviderRef rawIdentity
  receiveSubdomain <- validateProviderRef rawReceiveSubdomain
  pure
    SesDnsRef
      { sesDnsHostedZoneId = zoneId
      , sesDnsIdentityDomain = identity
      , sesDnsReceiveSubdomain = receiveSubdomain
      }

-- | Typed configuration for every registered Pulumi stack that the normal
-- Provider Worker may execute.  The constructors deliberately contain only
-- the non-secret settings consumed by the checked-in Pulumi programs.  There
-- is no generic map, project directory, command, environment, provider URL, or
-- SMTP-IAM setting.
data ProviderStackConfig
  = AwsEksProviderStackConfig !Text
  | AwsTestProviderStackConfig !Text
  | AwsEksSubzoneProviderStackConfig !Text !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderStackConfigError
  = ProviderStackConfigFieldInvalid !Text
  | ProviderStackConfigStackMismatch !ProviderStackRef !ProviderStackRef
  deriving stock (Eq, Show)

mkAwsEksProviderStackConfig :: Text -> Either ProviderStackConfigError ProviderStackConfig
mkAwsEksProviderStackConfig operatorCidr = do
  validateIpv4HostCidr "operator-cidr" operatorCidr
  pure (AwsEksProviderStackConfig operatorCidr)

mkAwsTestProviderStackConfig :: Text -> Either ProviderStackConfigError ProviderStackConfig
mkAwsTestProviderStackConfig operatorCidr = do
  validateIpv4HostCidr "operator-cidr" operatorCidr
  pure (AwsTestProviderStackConfig operatorCidr)

mkAwsEksSubzoneProviderStackConfig
  :: Text
  -> Text
  -> Either ProviderStackConfigError ProviderStackConfig
mkAwsEksSubzoneProviderStackConfig parentZoneId subzoneName = do
  validateOpaqueField "parent-zone-id" parentZoneId
  validateDnsName "subzone-name" subzoneName
  pure (AwsEksSubzoneProviderStackConfig parentZoneId subzoneName)

providerStackConfigRef :: ProviderStackConfig -> ProviderStackRef
providerStackConfigRef config = ProviderStackRef $ case config of
  -- The provider registry uses the logical resource name.  The interpreter
  -- alone maps this to Pulumi stack id @aws-eks-test@.
  AwsEksProviderStackConfig _ -> "aws-eks"
  AwsTestProviderStackConfig _ -> "aws-test"
  AwsEksSubzoneProviderStackConfig _ _ -> "aws-eks-subzone"

validateProviderStackConfig
  :: ProviderStackRef
  -> ProviderStackConfig
  -> Either ProviderStackConfigError ()
validateProviderStackConfig expected config = do
  rebuilt <- case config of
    AwsEksProviderStackConfig operatorCidr ->
      mkAwsEksProviderStackConfig operatorCidr
    AwsTestProviderStackConfig operatorCidr ->
      mkAwsTestProviderStackConfig operatorCidr
    AwsEksSubzoneProviderStackConfig parentZoneId subzoneName ->
      mkAwsEksSubzoneProviderStackConfig parentZoneId subzoneName
  let actual = providerStackConfigRef rebuilt
  if actual == expected
    then Right ()
    else Left (ProviderStackConfigStackMismatch expected actual)

-- | Closed read-only EC2 spot-price query.  Both fields are bounded and
-- printable; no AWS command-line fragment can be injected into the worker.
data ProviderSpotPriceQuery = ProviderSpotPriceQuery
  { providerSpotPriceInstanceType :: !Text
  , providerSpotPriceProductDescription :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkProviderSpotPriceQuery
  :: Text
  -> Text
  -> Either ProviderStackConfigError ProviderSpotPriceQuery
mkProviderSpotPriceQuery instanceType productDescription = do
  validateOpaqueField "spot-instance-type" instanceType
  validateOpaqueField "spot-product-description" productDescription
  pure
    ProviderSpotPriceQuery
      { providerSpotPriceInstanceType = instanceType
      , providerSpotPriceProductDescription = productDescription
      }

-- | Exact normal readiness probes the Lifecycle-provider identity may perform.
-- The Credential Provisioner's newly-created-key propagation proof is a
-- separate permit-scoped program and is intentionally absent.
data ProviderReadinessProbe
  = ProviderReadinessStsIdentity
  | ProviderReadinessRoute53Zone !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data EksClientAuthRequest = EksClientAuthRequest
  { eksClientAuthRequestAccountId :: !Text
  , eksClientAuthRequestRegion :: !Text
  , eksClientAuthRequestClusterName :: !Text
  , eksClientAuthRequestDestinationPublicKey :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

mkEksClientAuthRequest
  :: Text -> Text -> Text -> ByteString -> Either ProviderRefError EksClientAuthRequest
mkEksClientAuthRequest accountId region clusterName destinationPublicKey = do
  validatedAccount <- validateProviderRef accountId
  validatedRegion <- validateProviderRef region
  validatedCluster <- validateProviderRef clusterName
  if Text.length validatedAccount /= 12 || not (Text.all isDigit validatedAccount)
    then Left (ProviderRefMalformed "eks-account-id")
    else Right ()
  if not (validAwsRegion validatedRegion)
    then Left (ProviderRefMalformed "eks-region")
    else Right ()
  if not (validClusterName validatedCluster)
    then Left (ProviderRefMalformed "eks-cluster-name")
    else Right ()
  if ByteString.length destinationPublicKey /= 32
    then Left (ProviderRefTooLong (ByteString.length destinationPublicKey))
    else
      Right
        EksClientAuthRequest
          { eksClientAuthRequestAccountId = validatedAccount
          , eksClientAuthRequestRegion = validatedRegion
          , eksClientAuthRequestClusterName = validatedCluster
          , eksClientAuthRequestDestinationPublicKey = destinationPublicKey
          }
 where
  validAwsRegion value =
    Text.length value >= 6
      && Text.all (\character -> isAsciiLower character || isDigit character || character == '-') value
  validClusterName value =
    Text.all
      (\character -> isAsciiLower character || isDigit character || character == '-')
      (Text.toLower value)

validateOpaqueField :: Text -> Text -> Either ProviderStackConfigError ()
validateOpaqueField label value
  | Text.null value = invalid
  | Text.length value > 253 = invalid
  | Text.any invalidCharacter value = invalid
  | otherwise = Right ()
 where
  invalid = Left (ProviderStackConfigFieldInvalid label)
  invalidCharacter character = character < '\x20' || character == '\x7f'

validateDnsName :: Text -> Text -> Either ProviderStackConfigError ()
validateDnsName label value = do
  validateOpaqueField label value
  if Text.all validDnsCharacter value
    then Right ()
    else Left (ProviderStackConfigFieldInvalid label)
 where
  validDnsCharacter character =
    ('a' <= character && character <= 'z')
      || ('0' <= character && character <= '9')
      || character == '-'
      || character == '.'

validateIpv4HostCidr :: Text -> Text -> Either ProviderStackConfigError ()
validateIpv4HostCidr label value =
  case Text.stripSuffix "/32" value of
    Nothing -> invalid
    Just address ->
      case traverse parseOctet (Text.splitOn "." address) of
        Right [_, _, _, _] -> Right ()
        _ -> invalid
 where
  invalid = Left (ProviderStackConfigFieldInvalid label)
  parseOctet octet
    | Text.null octet = Left ()
    | Text.length octet > 3 = Left ()
    | Text.any (\character -> character < '0' || character > '9') octet = Left ()
    | otherwise =
        let valueInteger =
              Text.foldl'
                (\accumulator character -> accumulator * 10 + fromIntegral (fromEnum character - fromEnum '0'))
                (0 :: Integer)
                octet
         in if valueInteger <= 255 then Right valueInteger else Left ()

-- | A monotone provider revision. The worker only ever advances toward the bound
-- (committed) revision; a request naming an older revision is refused.
newtype ProviderRevision = ProviderRevision Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | Smart constructor: a provider revision is @>= 1@ (the genesis revision).
mkProviderRevision :: Natural -> Either Text ProviderRevision
mkProviderRevision value
  | value == 0 = Left "provider revision must be >= 1"
  | otherwise = Right (ProviderRevision value)

providerRevisionNatural :: ProviderRevision -> Natural
providerRevisionNatural (ProviderRevision value) = value

-- | The closed set of resource keys or typed resource families the current
-- committed Provider generation authorizes. A family admits only its
-- colon-delimited exact coordinate; the signed intent still binds every field.
newtype RegisteredProviderResources = RegisteredProviderResources (Set Text)
  deriving (Eq, Show)

mkRegisteredProviderResources :: [Text] -> RegisteredProviderResources
mkRegisteredProviderResources = RegisteredProviderResources . Set.fromList

registeredProviderResourceKeys :: RegisteredProviderResources -> Set Text
registeredProviderResourceKeys (RegisteredProviderResources keys) = keys

isProviderResourceRegistered :: Text -> RegisteredProviderResources -> Bool
isProviderResourceRegistered key (RegisteredProviderResources keys) =
  Set.member key keys
    || any (\family -> (family <> ":") `Text.isPrefixOf` key) (Set.toList keys)

-- | The closed set of normal provider intents. Forbidden capabilities are
-- unrepresentable: there is no constructor for a credential IAM identity/key, an
-- Authority state write, a backup/TLS identity, a target secret, a Gateway/DNS
-- election, or any SMTP IAM principal/policy/key. Only @ReconcileRegisteredStack@
-- carries a requested 'ProviderRevision'; the @aws-ses@ arm reconciles single
-- objects at the bound session revision.
data ProviderIntent
  = ReconcileRegisteredStack !ProviderStackRef !ProviderRevision !ProviderStackConfig
  | DestroyRegisteredStack !ProviderStackRef !ProviderRevision !ProviderStackConfig
  | ObserveRegisteredStack !ProviderStackRef
  | ReadBackRegisteredStack !ProviderStackRef
  | BoundedScratchCheckpoint !ProviderCheckpointRef
  | ReconcileSesSendingIdentity !SesIdentityRef
  | ReconcileSesDkim !SesIdentityRef
  | ReconcileSesReceiptRules !SesRuleSetRef
  | ReconcileSesCaptureBucket !SesBucketRef
  | ReconcileSesDns !SesDnsRef
  | ObservePublicARecord !PublicARecordRef
  | ReconcilePublicARecord !PublicARecordRef
  | ReapTestEbsVolumes !Text
  | ObserveSpotPrice !ProviderSpotPriceQuery
  | ObserveOperationalIdentity
  | ObserveProviderReadiness !ProviderReadinessProbe
  | IssueEksClientAuth !EksClientAuthRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The registered-resource key an intent draws on (the granularity at which the
-- Authority registers what the committed provider intent authorizes).
providerIntentResourceKey :: ProviderIntent -> Text
providerIntentResourceKey intent = case intent of
  ReconcileRegisteredStack ref _ _ -> "stack:" <> providerStackRefText ref
  DestroyRegisteredStack ref _ _ -> "stack:" <> providerStackRefText ref
  ObserveRegisteredStack ref -> "stack:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "stack:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref ->
    "checkpoint:pulumi-scratch:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref ->
    "ses:sending-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "ses:dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref ->
    "ses:receipt-rules:"
      <> sesRuleSetRefText ref
      <> ":"
      <> sesRuleSetRecipient ref
      <> ":"
      <> sesBucketRefText (sesRuleSetCaptureBucket ref)
  ReconcileSesCaptureBucket ref ->
    "ses:capture-bucket:" <> sesBucketRefText ref
  ReconcileSesDns ref ->
    "ses:dns:"
      <> sesDnsHostedZoneId ref
      <> ":"
      <> sesDnsIdentityDomain ref
      <> ":"
      <> sesDnsReceiveSubdomain ref
  ObservePublicARecord ref -> publicARecordResourceKey ref
  ReconcilePublicARecord ref -> publicARecordResourceKey ref
  ReapTestEbsVolumes clusterName -> "ebs-reaper:test-scoped:" <> clusterName
  ObserveSpotPrice query ->
    "spot-price:ec2:"
      <> providerSpotPriceInstanceType query
      <> ":"
      <> providerSpotPriceProductDescription query
  ObserveOperationalIdentity -> "operational-identity"
  ObserveProviderReadiness probe -> case probe of
    ProviderReadinessStsIdentity -> "readiness:sts"
    ProviderReadinessRoute53Zone zoneId -> "readiness:route53:" <> zoneId
  IssueEksClientAuth _ -> "eks-client-auth"

publicARecordResourceKey :: PublicARecordRef -> Text
publicARecordResourceKey ref =
  "public-edge:a:"
    <> publicARecordHostedZoneId ref
    <> ":"
    <> publicARecordFqdn ref

publicARecordCoordinate :: PublicARecordRef -> Text
publicARecordCoordinate ref =
  publicARecordResourceKey ref
    <> ":ttl="
    <> Text.pack (show (publicARecordTtl ref))
    <> ":values="
    <> Text.intercalate "," (publicARecordValues ref)

-- | The requested revision an intent is bound to, if it is a revision-bound
-- reconcile.
providerIntentRequestedRevision :: ProviderIntent -> Maybe ProviderRevision
providerIntentRequestedRevision intent = case intent of
  ReconcileRegisteredStack _ revision _ -> Just revision
  DestroyRegisteredStack _ revision _ -> Just revision
  _ -> Nothing

-- | A stable coordinate for an intent: operation kind plus resource key (plus the
-- requested revision for a stack reconcile). Two identical intents share a
-- coordinate, so a resubmission is idempotent; two distinct intents never collide,
-- so a different intent submitted while one is in flight is refused.
newtype ProviderIntentCoordinate = ProviderIntentCoordinate Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

providerIntentCoordinate :: ProviderIntent -> ProviderIntentCoordinate
providerIntentCoordinate intent = ProviderIntentCoordinate $ case intent of
  ReconcileRegisteredStack ref revision config ->
    "reconcile-stack:"
      <> providerStackRefText ref
      <> "@"
      <> Text.pack (show (providerRevisionNatural revision))
      <> ":"
      <> providerStackConfigCoordinate config
  DestroyRegisteredStack ref revision config ->
    "destroy-stack:"
      <> providerStackRefText ref
      <> "@"
      <> Text.pack (show (providerRevisionNatural revision))
      <> ":"
      <> providerStackConfigCoordinate config
  ObserveRegisteredStack ref -> "observe-stack:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "readback-stack:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref -> "scratch-checkpoint:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref -> "reconcile-ses-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "reconcile-ses-dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref ->
    "reconcile-ses-rules:"
      <> sesRuleSetRefText ref
      <> ":"
      <> sesRuleSetRecipient ref
      <> ":"
      <> sesBucketRefText (sesRuleSetCaptureBucket ref)
  ReconcileSesCaptureBucket ref -> "reconcile-ses-bucket:" <> sesBucketRefText ref
  ReconcileSesDns ref ->
    "reconcile-ses-dns:"
      <> sesDnsHostedZoneId ref
      <> ":"
      <> sesDnsIdentityDomain ref
      <> ":"
      <> sesDnsReceiveSubdomain ref
  ObservePublicARecord ref -> "observe-public-a:" <> publicARecordCoordinate ref
  ReconcilePublicARecord ref -> "reconcile-public-a:" <> publicARecordCoordinate ref
  ReapTestEbsVolumes clusterName -> "reap-test-ebs:" <> clusterName
  ObserveSpotPrice query ->
    "observe-spot-price:"
      <> providerSpotPriceInstanceType query
      <> ":"
      <> providerSpotPriceProductDescription query
  ObserveOperationalIdentity -> "observe-operational-identity"
  ObserveProviderReadiness probe -> case probe of
    ProviderReadinessStsIdentity -> "observe-readiness:sts"
    ProviderReadinessRoute53Zone zoneId -> "observe-readiness:route53:" <> zoneId
  IssueEksClientAuth request ->
    "issue-eks-client-auth:"
      <> eksClientAuthRequestAccountId request
      <> ":"
      <> eksClientAuthRequestRegion request
      <> ":"
      <> eksClientAuthRequestClusterName request
      <> ":"
      <> publicKeyDigest (eksClientAuthRequestDestinationPublicKey request)

providerStackConfigCoordinate :: ProviderStackConfig -> Text
providerStackConfigCoordinate config = case config of
  AwsEksProviderStackConfig operatorCidr -> operatorCidr
  AwsTestProviderStackConfig operatorCidr -> operatorCidr
  AwsEksSubzoneProviderStackConfig parentZoneId subzoneName ->
    parentZoneId <> ":" <> subzoneName

-- | A coordinate reference for a @close@/@recover@/@resolve@ command. It is an
-- opaque key the decision matches against the in-flight coordinate; an unknown key
-- simply fails to match and is refused.
providerIntentCoordinateFromText :: Text -> ProviderIntentCoordinate
providerIntentCoordinateFromText = ProviderIntentCoordinate

providerIntentCoordinateText :: ProviderIntentCoordinate -> Text
providerIntentCoordinateText (ProviderIntentCoordinate value) = value

publicKeyDigest :: ByteString -> Text
publicKeyDigest = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

-- | The single-narrow-session state. At most one intent is in flight; recovery and
-- grace mark the canceled/expired/ambiguous path back to admission.
data ProviderWorkState
  = -- | No work in flight; ready to admit a new intent.
    ProviderIdle
  | -- | Exactly one intent is executing under the narrow session.
    ProviderInFlight !ProviderIntentCoordinate
  | -- | The in-flight intent was canceled/expired/ambiguous and is being recovered.
    ProviderRecovering !ProviderIntentCoordinate
  | -- | Recovery resolved; a post-recovery grace state that admits a successor.
    ProviderGrace !ProviderIntentCoordinate
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialProviderWorkState :: ProviderWorkState
initialProviderWorkState = ProviderIdle

-- | The coordinate currently occupying the session, if any.
providerWorkActiveCoordinate :: ProviderWorkState -> Maybe ProviderIntentCoordinate
providerWorkActiveCoordinate state = case state of
  ProviderIdle -> Nothing
  ProviderInFlight coordinate -> Just coordinate
  ProviderRecovering coordinate -> Just coordinate
  ProviderGrace coordinate -> Just coordinate

-- | The apply-route commands: admit a new intent, or drive the in-flight intent
-- through its clean close or its recovery/grace lifecycle.
data ProviderWorkCommand
  = SubmitProviderIntent !ProviderIntent
  | CloseProviderWork !ProviderIntentCoordinate
  | RecoverProviderWork !ProviderIntentCoordinate
  | ResolveProviderRecovery !ProviderIntentCoordinate
  deriving (Eq, Show)

-- | Why a provider-work command was refused. Every arm is a precise, caller-actionable
-- reason.
data ProviderWorkRefusal
  = -- | The named resource is not in the registered set.
    ProviderWorkUnregisteredResource !Text
  | -- | A registered stack was paired with a configuration for another stack
    -- or with an invalid bounded field.
    ProviderWorkInvalidStackConfig !ProviderStackConfigError
  | -- | A stack reconcile requested a revision older than the bound revision
    -- (requested, bound).
    ProviderWorkRevisionStale !Natural !Natural
  | -- | The session deadline has passed.
    ProviderWorkDeadlineReached
  | -- | A different intent is already in flight (the occupying coordinate).
    ProviderWorkOutstandingIntent !ProviderIntentCoordinate
  | -- | A close/recover was issued but nothing is in flight.
    ProviderWorkNotInFlight
  | -- | A close/recover/resolve named a coordinate other than the active one.
    ProviderWorkCoordinateMismatch !ProviderIntentCoordinate
  | -- | A submit arrived while the session was recovering.
    ProviderWorkInRecovery !ProviderIntentCoordinate
  | -- | A resolve arrived but the session was not recovering.
    ProviderWorkNotInRecovery
  deriving (Eq, Show)

-- | The decision over a command against the current state.
data ProviderWorkDecision
  = -- | A new intent is admitted into the narrow session.
    ProviderWorkAdmitted !ProviderIntentCoordinate
  | -- | An idempotent resubmission of the already-in-flight intent (response-loss
    -- safe: never a second admission).
    ProviderWorkAlreadyInFlight !ProviderIntentCoordinate
  | -- | The in-flight intent cleanly closed; the session returns to idle.
    ProviderWorkClosed !ProviderIntentCoordinate
  | -- | The in-flight intent entered recovery.
    ProviderWorkRecovering !ProviderIntentCoordinate
  | -- | Recovery resolved; the session enters grace and admits a successor.
    ProviderWorkResolved !ProviderIntentCoordinate
  | -- | The command was refused; no state advance.
    ProviderWorkRefused !ProviderWorkRefusal
  deriving (Eq, Show)

-- | The state-transition events a decision folds into the next state.
data ProviderWorkEvent
  = ProviderWorkBecameInFlight !ProviderIntentCoordinate
  | ProviderWorkBecameIdle
  | ProviderWorkBecameRecovering !ProviderIntentCoordinate
  | ProviderWorkBecameGrace !ProviderIntentCoordinate
  deriving (Eq, Show)

-- | Decide a command against the current state, the registered resource set, the
-- bound provider revision, and the session clock/deadline. Total: every
-- (state, command) pair yields a decision.
decideProviderWork
  :: RegisteredProviderResources
  -> ProviderRevision
  -- ^ The bound (committed) session revision.
  -> AuthorityTime
  -- ^ Authority-supplied now.
  -> AuthorityTime
  -- ^ The session deadline.
  -> ProviderWorkState
  -> ProviderWorkCommand
  -> ProviderWorkDecision
decideProviderWork registered bound now deadline state command = case command of
  SubmitProviderIntent intent -> decideSubmit intent
  CloseProviderWork coordinate -> decideTransition coordinate onInFlight ProviderWorkClosed
  RecoverProviderWork coordinate -> decideTransition coordinate onInFlight ProviderWorkRecovering
  ResolveProviderRecovery coordinate -> decideResolve coordinate
 where
  decideSubmit intent
    | authorityTimeMicros now >= authorityTimeMicros deadline =
        ProviderWorkRefused ProviderWorkDeadlineReached
    | not (isProviderResourceRegistered key registered) =
        ProviderWorkRefused (ProviderWorkUnregisteredResource key)
    | Left configError <- validateIntentStackConfig intent =
        ProviderWorkRefused (ProviderWorkInvalidStackConfig configError)
    | Just requested <- providerIntentRequestedRevision intent
    , providerRevisionNatural requested < providerRevisionNatural bound =
        ProviderWorkRefused
          (ProviderWorkRevisionStale (providerRevisionNatural requested) (providerRevisionNatural bound))
    | otherwise = case state of
        ProviderIdle -> ProviderWorkAdmitted coordinate
        ProviderGrace _ -> ProviderWorkAdmitted coordinate
        ProviderInFlight active
          | active == coordinate -> ProviderWorkAlreadyInFlight active
          | otherwise -> ProviderWorkRefused (ProviderWorkOutstandingIntent active)
        ProviderRecovering active -> ProviderWorkRefused (ProviderWorkInRecovery active)
   where
    key = providerIntentResourceKey intent
    coordinate = providerIntentCoordinate intent

  validateIntentStackConfig submitted = case submitted of
    ReconcileRegisteredStack ref _ config -> validateProviderStackConfig ref config
    DestroyRegisteredStack ref _ config -> validateProviderStackConfig ref config
    _ -> Right ()

  -- A close/recover only applies to an in-flight session and only for the exact
  -- in-flight coordinate.
  onInFlight :: ProviderWorkState -> Maybe ProviderIntentCoordinate
  onInFlight st = case st of
    ProviderInFlight active -> Just active
    _ -> Nothing

  decideTransition coordinate select build = case select state of
    Just active
      | active == coordinate -> build coordinate
      | otherwise -> ProviderWorkRefused (ProviderWorkCoordinateMismatch active)
    Nothing -> ProviderWorkRefused ProviderWorkNotInFlight

  decideResolve coordinate = case state of
    ProviderRecovering active
      | active == coordinate -> ProviderWorkResolved coordinate
      | otherwise -> ProviderWorkRefused (ProviderWorkCoordinateMismatch active)
    _ -> ProviderWorkRefused ProviderWorkNotInRecovery

-- | The state-transition events a decision implies. A refusal or an idempotent
-- resubmission implies no transition.
providerWorkDecisionEvents :: ProviderWorkDecision -> [ProviderWorkEvent]
providerWorkDecisionEvents decision = case decision of
  ProviderWorkAdmitted coordinate -> [ProviderWorkBecameInFlight coordinate]
  ProviderWorkAlreadyInFlight _ -> []
  ProviderWorkClosed _ -> [ProviderWorkBecameIdle]
  ProviderWorkRecovering coordinate -> [ProviderWorkBecameRecovering coordinate]
  ProviderWorkResolved coordinate -> [ProviderWorkBecameGrace coordinate]
  ProviderWorkRefused _ -> []

-- | Fold one event into the next state. Total.
evolveProviderWork :: ProviderWorkState -> ProviderWorkEvent -> ProviderWorkState
evolveProviderWork _ event = case event of
  ProviderWorkBecameInFlight coordinate -> ProviderInFlight coordinate
  ProviderWorkBecameIdle -> ProviderIdle
  ProviderWorkBecameRecovering coordinate -> ProviderRecovering coordinate
  ProviderWorkBecameGrace coordinate -> ProviderGrace coordinate

-- | Decide and apply in one step, returning the decision and the resulting state.
stepProviderWork
  :: RegisteredProviderResources
  -> ProviderRevision
  -> AuthorityTime
  -> AuthorityTime
  -> ProviderWorkState
  -> ProviderWorkCommand
  -> (ProviderWorkDecision, ProviderWorkState)
stepProviderWork registered bound now deadline state command =
  let decision = decideProviderWork registered bound now deadline state command
   in (decision, foldl evolveProviderWork state (providerWorkDecisionEvents decision))
