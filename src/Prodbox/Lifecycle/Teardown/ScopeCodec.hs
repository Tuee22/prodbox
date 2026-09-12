{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.92: the one wire form and the one identity projection of an
-- 'ObservationEvidenceScope'.
--
-- __What this replaces.__ The scope had roughly eighteen independently authored
-- byte-level codecs and eight digest or equality projections. Fifteen of the
-- codecs erased the run's retained DNS hosted zone, because their decoders
-- rebuilt the scope through 'mkObservationEvidenceScope', whose documented
-- contract hardcodes the zone to absent; five of the projections erased it too,
-- including both audit re-scopers, so a cascade's terminal escape audit ran
-- under a zone-less scope while claiming to be scoped to the run. One codec had
-- already been corrected, and carried the comment recording what the erasure
-- cost: an encode/decode round trip silently returned a zone-less scope, and
-- the exact identity comparison that guards every read-back then refused a
-- bundle the same run had just committed.
--
-- Fifteen separate patches would have left the eighteenth author free to forget
-- again. This module is the single encoder
-- [Pure FP Standards § 2.3a](../../../../documents/engineering/pure_fp_standards.md)
-- already required.
--
-- __How a forgotten field becomes a build failure.__ Every projection here is
-- written against 'ObservationEvidenceScopeFields', and every one of them
-- matches its constructor __positionally__. Adding a field to the scope
-- therefore fails to compile in three distinct places before it can be silently
-- dropped anywhere: 'observationEvidenceScopeFields' constructs the record by
-- name, so the new field is a missing-field error; and
-- 'observationEvidenceScopeFromFields', 'scopeToWire', and 'scopeIdentityFields'
-- each destructure it positionally, so the new field is a constructor-arity
-- error. That is the property the fifteen hand-authored decoders did not have,
-- and it is the reason this module states the field set once rather than
-- eighteen times.
--
-- __The audit re-scope decision, stated rather than implied.__
-- 'scopeForTerminalAudit' keeps the run's zone. A terminal escape audit exists
-- to find AWS resources the run created and did not remove, and the DNS01
-- challenge records it must look for live in exactly the zone the run was
-- compiled against. An audit scope that dropped the zone would either sweep the
-- wrong zone or refuse for want of one, and in both cases would be a different
-- scope from the run it claims to audit — which is what made the two
-- field-by-field re-mints it replaces a defect rather than a simplification.
module Prodbox.Lifecycle.Teardown.ScopeCodec
  ( -- * The complete field set
    ObservationEvidenceScopeFields (..)
  , observationEvidenceScopeFields
  , observationEvidenceScopeFromFields

    -- * Total re-scoping
  , scopeForTerminalAudit
  , scopeForCascadeTerminalAudit

    -- * The canonical wire form
  , ScopeWire (..)
  , scopeToWire
  , scopeFromWire
  , ScopeWireError (..)
  , renderScopeWireError

    -- * The canonical identity projection
  , scopeIdentityFields
  , scopeIdentityText
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.Lifecycle.DnsRecord
  ( HostedZoneId
  , hostedZoneIdText
  , mkHostedZoneId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , evidenceAwsDnsZone
  , evidenceAwsScope
  , evidenceCleanupSurface
  , evidenceDurableRunScope
  , evidenceLifecycleOperation
  , evidenceLinuxRke2Foundation
  , evidenceRegistryRevision
  , mkObservationEvidenceScope
  , mkObservationEvidenceScopeWithDnsZone
  )

-- | The scope's complete field set.
--
-- The record is deliberately both named and positional: it is constructed by
-- name exactly once, so a new field is a missing-field error there, and
-- destructured positionally everywhere else, so a new field is an arity error at
-- every projection. Nothing outside this module reaches for a scope accessor to
-- build a projection.
data ObservationEvidenceScopeFields = ObservationEvidenceScopeFields
  { scopeFieldCleanupSurface :: !CleanupSurface
  , scopeFieldRegistryRevision :: !RegistryRevision
  , scopeFieldDurableRunScope :: !DurableObservationRunScope
  , scopeFieldLinuxRke2Foundation :: !LinuxRke2FoundationId
  , scopeFieldAwsScope :: !(Maybe AwsScope)
  , scopeFieldAwsDnsZone :: !(Maybe HostedZoneId)
  , scopeFieldLifecycleOperation :: !LifecycleOperation
  }
  deriving stock (Eq, Ord, Show)

-- | The one place a scope becomes its field set.
observationEvidenceScopeFields
  :: ObservationEvidenceScope -> ObservationEvidenceScopeFields
observationEvidenceScopeFields scope =
  ObservationEvidenceScopeFields
    { scopeFieldCleanupSurface = evidenceCleanupSurface scope
    , scopeFieldRegistryRevision = evidenceRegistryRevision scope
    , scopeFieldDurableRunScope = evidenceDurableRunScope scope
    , scopeFieldLinuxRke2Foundation = evidenceLinuxRke2Foundation scope
    , scopeFieldAwsScope = evidenceAwsScope scope
    , scopeFieldAwsDnsZone = evidenceAwsDnsZone scope
    , scopeFieldLifecycleOperation = evidenceLifecycleOperation scope
    }

-- | The one place a field set becomes a scope.
observationEvidenceScopeFromFields
  :: ObservationEvidenceScopeFields -> ObservationEvidenceScope
observationEvidenceScopeFromFields
  ( ObservationEvidenceScopeFields
      surface
      revision
      runScope
      foundation
      awsScope
      dnsZone
      operation
    ) = case dnsZone of
    Nothing ->
      mkObservationEvidenceScope surface revision runScope foundation awsScope operation
    Just zone ->
      mkObservationEvidenceScopeWithDnsZone
        surface
        revision
        runScope
        foundation
        awsScope
        zone
        operation

-- | Re-scope a run's evidence scope to its terminal escape audit.
--
-- Record update rather than a field-by-field re-mint: the two functions this
-- replaces copied five of six fields and lost the sixth, so the audit ran under
-- a zone-less scope and its digest could not match the reservation it belonged
-- to. A record update cannot drop a field that is added later.
scopeForTerminalAudit :: ObservationEvidenceScope -> ObservationEvidenceScope
scopeForTerminalAudit scope =
  observationEvidenceScopeFromFields
    (observationEvidenceScopeFields scope)
      { scopeFieldLifecycleOperation = RunTerminalEscapeAudit
      }

-- | The cascade's terminal escape audit, which additionally pins the surface.
--
-- A cascade audits under the cascade surface whatever surface its originating
-- scope carried, which is the one field the cascade re-scoper deliberately
-- changes.
scopeForCascadeTerminalAudit :: ObservationEvidenceScope -> ObservationEvidenceScope
scopeForCascadeTerminalAudit scope =
  observationEvidenceScopeFromFields
    (observationEvidenceScopeFields scope)
      { scopeFieldCleanupSurface = Cascade
      , scopeFieldLifecycleOperation = RunTerminalEscapeAudit
      }

-- | The canonical encoded projection of a scope.
--
-- Every durable envelope in the tree embeds this as one nested value rather than
-- flattening the scope's fields among its own, so the field set has one
-- statement and an envelope's own version tag is the only thing an author has to
-- remember to bump.
data ScopeWire = ScopeWire
  { scopeWireSurface :: !Int
  , scopeWireRegistryRevision :: !Text
  , scopeWireRunScope :: !Text
  , scopeWireFoundation :: !Text
  , scopeWireAwsAccount :: !(Maybe Text)
  , scopeWireAwsRegion :: !(Maybe Text)
  , scopeWireAwsDnsZone :: !(Maybe Text)
  , scopeWireOperation :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Why a stored scope could not be decoded.
--
-- Each consumer maps this into its own error type rather than restating the
-- rules, so a refusal names which scope field was wrong wherever it surfaces.
-- | Why a stored scope could not be decoded.
--
-- The field rules are the union of the strictest rule each of the superseded
-- codecs applied to the same field, because they are rules about the field
-- rather than about the envelope that carries it: an AWS account is twelve
-- digits wherever it is read, and one codec knowing that while another did not
-- is the same class of defect as one codec carrying the zone while another did
-- not.
data ScopeWireError
  = ScopeWireSurfaceInvalid !Int
  | ScopeWireOperationInvalid !Int
  | ScopeWireFieldEmpty !Text
  | ScopeWireFieldTooLong !Text !Int
  | ScopeWireAwsScopePartial
  | ScopeWireAwsAccountInvalid !Text
  | ScopeWireAwsRegionInvalid !Text
  | ScopeWireDnsZoneInvalid !Text
  deriving stock (Eq, Show)

renderScopeWireError :: ScopeWireError -> Text
renderScopeWireError err = case err of
  ScopeWireSurfaceInvalid value ->
    "scope cleanup surface " <> Text.pack (show value) <> " is not a registered surface"
  ScopeWireOperationInvalid value ->
    "scope lifecycle operation " <> Text.pack (show value) <> " is not a registered operation"
  ScopeWireFieldEmpty field -> "scope " <> field <> " is empty"
  ScopeWireFieldTooLong field limit ->
    "scope " <> field <> " exceeds " <> Text.pack (show limit) <> " characters"
  ScopeWireAwsScopePartial -> "scope AWS account and region were only partially encoded"
  ScopeWireAwsAccountInvalid value ->
    "scope AWS account " <> value <> " is not twelve digits"
  ScopeWireAwsRegionInvalid value -> "scope AWS region " <> value <> " is invalid"
  ScopeWireDnsZoneInvalid value -> "scope AWS DNS zone " <> value <> " is invalid"

scopeToWire :: ObservationEvidenceScope -> ScopeWire
scopeToWire = encodeFields . observationEvidenceScopeFields
 where
  encodeFields
    ( ObservationEvidenceScopeFields
        surface
        (RegistryRevision revision)
        (DurableObservationRunScope runScope)
        (LinuxRke2FoundationId foundation)
        awsScope
        dnsZone
        operation
      ) =
      ScopeWire
        { scopeWireSurface = fromEnum surface
        , scopeWireRegistryRevision = revision
        , scopeWireRunScope = runScope
        , scopeWireFoundation = foundation
        , scopeWireAwsAccount = accountText <$> awsScope
        , scopeWireAwsRegion = regionText <$> awsScope
        , scopeWireAwsDnsZone = hostedZoneIdText <$> dnsZone
        , scopeWireOperation = operationTag operation
        }

scopeFromWire :: ScopeWire -> Either ScopeWireError ObservationEvidenceScope
scopeFromWire wire = do
  surface <- decodeSurface (scopeWireSurface wire)
  revision <- RegistryRevision <$> checked "registry revision" (scopeWireRegistryRevision wire)
  runScope <- DurableObservationRunScope <$> checked "run scope" (scopeWireRunScope wire)
  foundation <- LinuxRke2FoundationId <$> checked "foundation" (scopeWireFoundation wire)
  awsScope <- case (scopeWireAwsAccount wire, scopeWireAwsRegion wire) of
    (Nothing, Nothing) -> Right Nothing
    (Just account, Just region) -> do
      checkedAccount <- checkedAwsAccount account
      checkedRegion <- checkedAwsRegion region
      Right (Just (AwsScope (AwsAccountId checkedAccount) (AwsRegion checkedRegion)))
    _ -> Left ScopeWireAwsScopePartial
  dnsZone <- case scopeWireAwsDnsZone wire of
    Nothing -> Right Nothing
    Just raw -> Just <$> first (const (ScopeWireDnsZoneInvalid raw)) (mkHostedZoneId raw)
  operation <- decodeOperation (scopeWireOperation wire)
  Right
    ( observationEvidenceScopeFromFields
        ObservationEvidenceScopeFields
          { scopeFieldCleanupSurface = surface
          , scopeFieldRegistryRevision = revision
          , scopeFieldDurableRunScope = runScope
          , scopeFieldLinuxRke2Foundation = foundation
          , scopeFieldAwsScope = awsScope
          , scopeFieldAwsDnsZone = dnsZone
          , scopeFieldLifecycleOperation = operation
          }
    )

-- | The canonical identity projection of a scope.
--
-- Every field is emitted, and every optional field emits a present\/absent
-- discriminator __beside__ its value, so an absent zone and a present empty one
-- cannot render the same. Callers frame and join this list themselves, because
-- the framing convention belongs to the envelope rather than to the scope.
scopeIdentityFields :: ObservationEvidenceScope -> [Text]
scopeIdentityFields = identityFields . observationEvidenceScopeFields
 where
  identityFields
    ( ObservationEvidenceScopeFields
        surface
        (RegistryRevision revision)
        (DurableObservationRunScope runScope)
        (LinuxRke2FoundationId foundation)
        awsScope
        dnsZone
        operation
      ) =
      [ Text.pack (show surface)
      , revision
      , runScope
      , foundation
      , maybe "aws/absent" (const "aws/present") awsScope
      , maybe "" accountText awsScope
      , maybe "" regionText awsScope
      , maybe "zone/absent" (const "zone/present") dnsZone
      , maybe "" hostedZoneIdText dnsZone
      , Text.pack (show operation)
      ]

-- | The identity projection as one length-framed string.
--
-- Framing every component before joining is what keeps two scopes that differ
-- only in where a boundary falls from collapsing onto one digest.
scopeIdentityText :: ObservationEvidenceScope -> Text
scopeIdentityText = Text.concat . map frame . scopeIdentityFields
 where
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

accountText :: AwsScope -> Text
accountText scope = case awsScopeAccountId scope of
  AwsAccountId value -> value

regionText :: AwsScope -> Text
regionText scope = case awsScopeRegion scope of
  AwsRegion value -> value

operationTag :: LifecycleOperation -> Int
operationTag operation = case operation of
  ReconcileDesiredAbsent -> 0
  ReconcileDesiredPresent -> 1
  RunTerminalEscapeAudit -> 2

decodeOperation :: Int -> Either ScopeWireError LifecycleOperation
decodeOperation value = case value of
  0 -> Right ReconcileDesiredAbsent
  1 -> Right ReconcileDesiredPresent
  2 -> Right RunTerminalEscapeAudit
  other -> Left (ScopeWireOperationInvalid other)

decodeSurface :: Int -> Either ScopeWireError CleanupSurface
decodeSurface value
  | value >= fromEnum (minBound :: CleanupSurface)
      && value <= fromEnum (maxBound :: CleanupSurface) =
      Right (toEnum value)
  | otherwise = Left (ScopeWireSurfaceInvalid value)

-- | Scope text fields are non-empty and bounded.
checked :: Text -> Text -> Either ScopeWireError Text
checked field = checkedBounded field textFieldLimit

checkedBounded :: Text -> Int -> Text -> Either ScopeWireError Text
checkedBounded field limit value
  | Text.null value = Left (ScopeWireFieldEmpty field)
  | Text.length value > limit = Left (ScopeWireFieldTooLong field limit)
  | otherwise = Right value

-- | An AWS account identifier is exactly twelve digits.
checkedAwsAccount :: Text -> Either ScopeWireError Text
checkedAwsAccount value
  | Text.length value == 12 && Text.all isDigit value = Right value
  | otherwise = Left (ScopeWireAwsAccountInvalid value)

-- | An AWS region is a bounded lowercase/digit/hyphen label.
checkedAwsRegion :: Text -> Either ScopeWireError Text
checkedAwsRegion value
  | Text.null value || Text.length value > awsRegionLimit =
      Left (ScopeWireAwsRegionInvalid value)
  | Text.all regionCharacter value = Right value
  | otherwise = Left (ScopeWireAwsRegionInvalid value)
 where
  regionCharacter character =
    isAsciiLower character || isDigit character || character == '-'

-- | The scope's text-field ceiling.
--
-- The superseded codecs disagreed, at 256 and at 512. The looser bound is kept
-- deliberately: it is the one the already-corrected codec applied, so no value
-- any live run has committed becomes unreadable by tightening it here, and a
-- ceiling is a memory bound rather than a validation rule.
textFieldLimit :: Int
textFieldLimit = 512

awsRegionLimit :: Int
awsRegionLimit = 64
