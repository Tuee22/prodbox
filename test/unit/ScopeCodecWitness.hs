{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.92 witness for the canonical observation-scope codec.
--
-- Four properties are asserted here, and a fifth is asserted by the fact that
-- this module — and the whole tree — compiles:
--
--   * ROUND TRIP. A zoned scope survives the canonical wire form and compares
--     equal to its original, and a zoneless scope stays zoneless. This is the
--     exact assertion fifteen hand-authored decoders would have failed: each
--     rebuilt the scope through 'mkObservationEvidenceScope', whose documented
--     contract hardcodes the zone to absent, so a zoned scope decoded to a
--     zone-less one and the exact identity comparison that guards every
--     read-back then refused a bundle the same run had just committed.
--   * DISCRIMINATION. The canonical identity projection separates a zoned scope
--     from a zoneless one, and separates two different zones. A projection that
--     omits the zone gives two distinguishable scopes one digest, which is a
--     collision on an Authority-addressable key rather than a cosmetic loss.
--   * RE-SCOPING KEEPS THE ZONE. The terminal escape audit is scoped to the run
--     it audits, including the zone the run's DNS01 challenge records live in.
--     The two field-by-field re-mints this replaces copied five of six fields
--     and silently dropped the sixth.
--   * FAIL-CLOSED FIELDS. Every field rule refuses rather than coercing, and the
--     rules are the union of the strictest rule each superseded codec applied,
--     because they are rules about the field rather than about the envelope.
--   * COMPILE WITNESS. 'ObservationEvidenceScopeFields' is destructured
--     positionally by every projection in "Prodbox.Lifecycle.Teardown.ScopeCodec"
--     and constructed by name exactly once. Adding a field to the scope is
--     therefore a constructor-arity error at every projection and a
--     missing-field error at the one constructor, before it can be silently
--     dropped anywhere. Uncommenting either line below fails the build:
--
--     > eightFields (ObservationEvidenceScopeFields a b c d e f g h) = ()
--
--     > sixFields (ObservationEvidenceScopeFields a b c d e f) = ()
module ScopeCodecWitness
  ( scopeCodecWitnessSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , evidenceAwsDnsZone
  , evidenceCleanupSurface
  , evidenceLifecycleOperation
  , mkObservationEvidenceScope
  , mkObservationEvidenceScopeWithDnsZone
  )
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ScopeWire (..)
  , ScopeWireError (..)
  , observationEvidenceScopeFields
  , observationEvidenceScopeFromFields
  , scopeForCascadeTerminalAudit
  , scopeForTerminalAudit
  , scopeFromWire
  , scopeIdentityFields
  , scopeIdentityText
  , scopeToWire
  )
import TestSupport

scopeCodecWitnessSuite :: SuiteBuilder ()
scopeCodecWitnessSuite =
  describe "Sprint 4.92 canonical observation-scope codec" $ do
    it "round-trips a zoned scope back to the value it started as" $ do
      let scope = zonedScope primaryZone
      scopeFromWire (scopeToWire scope) `shouldBe` Right scope
      fmap evidenceAwsDnsZone (scopeFromWire (scopeToWire scope))
        `shouldBe` Right (Just primaryZone)

    it "leaves a zoneless scope zoneless" $ do
      scopeFromWire (scopeToWire zonelessScope) `shouldBe` Right zonelessScope
      fmap evidenceAwsDnsZone (scopeFromWire (scopeToWire zonelessScope))
        `shouldBe` Right Nothing

    it "round-trips through the field set without touching the wire" $ do
      -- The field set is the seam the wire form and every digest projection are
      -- both derived from, so it has to be lossless on its own.
      observationEvidenceScopeFromFields
        (observationEvidenceScopeFields (zonedScope primaryZone))
        `shouldBe` zonedScope primaryZone
      observationEvidenceScopeFromFields
        (observationEvidenceScopeFields zonelessScope)
        `shouldBe` zonelessScope

    it "separates a zoned scope from a zoneless one in its identity projection" $ do
      -- A projection that omits the zone gives these two one digest. That is a
      -- collision on an Authority submission key, not a cosmetic loss.
      scopeIdentityFields (zonedScope primaryZone)
        `shouldNotBe` scopeIdentityFields zonelessScope
      scopeIdentityText (zonedScope primaryZone)
        `shouldNotBe` scopeIdentityText zonelessScope

    it "separates two different zones in its identity projection" $
      scopeIdentityText (zonedScope primaryZone)
        `shouldNotBe` scopeIdentityText (zonedScope secondaryZone)

    it "emits a present/absent discriminator beside the zone value" $ do
      -- Beside, not instead: an absent zone and a present empty one would
      -- otherwise render the same, and the framing cannot tell them apart.
      scopeIdentityFields (zonedScope primaryZone) `shouldContain` ["zone/present"]
      scopeIdentityFields zonelessScope `shouldContain` ["zone/absent"]

    it "keeps the run's zone when re-scoping to a terminal escape audit" $ do
      -- The audit looks for DNS01 challenge records in exactly the zone the run
      -- was compiled against. An audit scope without it either sweeps the wrong
      -- zone or refuses for want of one.
      let audited = scopeForTerminalAudit (zonedScope primaryZone)
      evidenceAwsDnsZone audited `shouldBe` Just primaryZone
      evidenceLifecycleOperation audited `shouldBe` RunTerminalEscapeAudit
      evidenceCleanupSurface audited `shouldBe` evidenceCleanupSurface (zonedScope primaryZone)

    it "pins the cascade audit surface while still keeping the zone" $ do
      let audited = scopeForCascadeTerminalAudit (localOnlyZonedScope primaryZone)
      evidenceAwsDnsZone audited `shouldBe` Just primaryZone
      evidenceCleanupSurface audited `shouldBe` Cascade
      evidenceLifecycleOperation audited `shouldBe` RunTerminalEscapeAudit

    it "refuses an invalid hosted zone rather than dropping it" $
      -- The failure mode this replaces was silent: a decoder that could not
      -- represent the zone returned a scope without one and no error at all.
      scopeFromWire (scopeToWire (zonedScope primaryZone)) {scopeWireAwsDnsZone = Just "not a zone"}
        `shouldBe` Left (ScopeWireDnsZoneInvalid "not a zone")

    it "refuses an AWS account that is not twelve digits" $
      scopeFromWire (scopeToWire (zonedScope primaryZone)) {scopeWireAwsAccount = Just "12345"}
        `shouldBe` Left (ScopeWireAwsAccountInvalid "12345")

    it "refuses a half-encoded AWS scope" $
      scopeFromWire (scopeToWire (zonedScope primaryZone)) {scopeWireAwsRegion = Nothing}
        `shouldBe` Left ScopeWireAwsScopePartial

    it "refuses an out-of-range cleanup surface and lifecycle operation" $ do
      scopeFromWire (scopeToWire zonelessScope) {scopeWireSurface = 99}
        `shouldBe` Left (ScopeWireSurfaceInvalid 99)
      scopeFromWire (scopeToWire zonelessScope) {scopeWireOperation = 7}
        `shouldBe` Left (ScopeWireOperationInvalid 7)

    it "refuses an empty and an oversized scope text field" $ do
      scopeFromWire (scopeToWire zonelessScope) {scopeWireRunScope = ""}
        `shouldBe` Left (ScopeWireFieldEmpty "run scope")
      scopeFromWire
        (scopeToWire zonelessScope) {scopeWireFoundation = Text.replicate 513 "x"}
        `shouldBe` Left (ScopeWireFieldTooLong "foundation" 512)

primaryZone :: HostedZoneId
primaryZone = mustZone "Z0PRIMARY0EXAMPLE"

secondaryZone :: HostedZoneId
secondaryZone = mustZone "Z0SECONDARY0EXAMPLE"

mustZone :: Text.Text -> HostedZoneId
mustZone raw = case mkHostedZoneId raw of
  Left err -> error ("ScopeCodecWitness: invalid fixture hosted zone: " ++ show err)
  Right zone -> zone

zonedScope :: HostedZoneId -> ObservationEvidenceScope
zonedScope zone =
  mkObservationEvidenceScopeWithDnsZone
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/scope-codec-witness")
    (LinuxRke2FoundationId "linux-rke2/home")
    (Just fixtureAwsScope)
    zone
    ReconcileDesiredAbsent

localOnlyZonedScope :: HostedZoneId -> ObservationEvidenceScope
localOnlyZonedScope zone =
  mkObservationEvidenceScopeWithDnsZone
    LocalOnly
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/scope-codec-witness")
    (LinuxRke2FoundationId "linux-rke2/home")
    (Just fixtureAwsScope)
    zone
    ReconcileDesiredAbsent

zonelessScope :: ObservationEvidenceScope
zonelessScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope "cleanup-run/scope-codec-witness")
    (LinuxRke2FoundationId "linux-rke2/home")
    (Just fixtureAwsScope)
    ReconcileDesiredAbsent

fixtureAwsScope :: AwsScope
fixtureAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion (fixtureAwsRegion FixtureCaCentral1))
