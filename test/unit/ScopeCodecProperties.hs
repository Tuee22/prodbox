{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.46: the @decode . encode == id@ properties
-- [Unit Testing Policy § 3.2](../../documents/engineering/unit_testing_policy.md#32-properties)
-- has required all along.
--
-- __Why here and why now.__ The policy's first property bullet is
-- @decode . encode == id@ for bounded valid values, "at minimum". The tree held
-- roughly five property registrations in total, of which two were genuine wire
-- round trips, and both lived outside the primary unit suite — the suite the
-- policy's own tier table names as their home. That gap is not academic: it is
-- precisely why fifteen independently authored codecs for one durable type
-- could erase a field for weeks without a single failing test. The rule
-- existed; the test did not.
--
-- __What the generators have to do to be worth writing.__ A generator that
-- produces the same shape every time turns a property into a slow unit test, so
-- these deliberately do three things:
--
--   * generate zoned and zoneless scopes in roughly equal measure, because the
--     erasure was invisible exactly on the zoned half;
--   * discriminate fields from one another, so no two same-typed fields can
--     collide — a round trip that swapped the registry revision with the run
--     scope would pass a generator that gave them the same value; and
--   * never emit a value a decoder's own default could have produced, so a
--     decoder that silently substituted one would fail rather than pass.
--
-- The last is the one the erasure would have needed. A generator whose zone was
-- sometimes absent and whose present zones were all the same string would still
-- have caught it; a generator whose fields were all @\"x\"@ would not have
-- caught a field swap. Both are cheap to get wrong and neither is visible in a
-- passing run, which is why they are stated here rather than left to the
-- generator's shape.
module ScopeCodecProperties
  ( scopeCodecPropertiesSuite
  )
where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, hostedZoneIdText, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , evidenceAwsDnsZone
  )
import Prodbox.Lifecycle.Teardown.ScopeCodec
  ( ObservationEvidenceScopeFields (..)
  , observationEvidenceScopeFields
  , observationEvidenceScopeFromFields
  , scopeForCascadeTerminalAudit
  , scopeForTerminalAudit
  , scopeFromWire
  , scopeIdentityFields
  , scopeIdentityText
  , scopeToWire
  )
import Test.Tasty.QuickCheck
  ( Arbitrary (..)
  , Gen
  , Property
  , elements
  , frequency
  , (===)
  )
import TestSupport

-- | A generated scope, wrapped so its generator is this module's rather than an
-- orphan instance on a production type.
newtype GeneratedScope = GeneratedScope ObservationEvidenceScope
  deriving stock (Eq, Show)

instance Arbitrary GeneratedScope where
  arbitrary = GeneratedScope <$> genScope

genScope :: Gen ObservationEvidenceScope
genScope = do
  surface <- elements [minBound .. maxBound]
  revision <- RegistryRevision <$> genDiscriminated "registry-revision"
  runScope <- DurableObservationRunScope <$> genDiscriminated "cleanup-run"
  foundation <- LinuxRke2FoundationId <$> genDiscriminated "linux-rke2"
  awsScope <- frequency [(1, pure Nothing), (2, Just <$> genAwsScope)]
  -- Zoned and zoneless in roughly equal measure: the erasure this closes was
  -- invisible on exactly the zoned half, and a generator that produced zones
  -- rarely would have found it rarely.
  dnsZone <- frequency [(1, pure Nothing), (1, Just <$> genHostedZone)]
  operation <-
    elements [ReconcileDesiredAbsent, ReconcileDesiredPresent, RunTerminalEscapeAudit]
  pure
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

genAwsScope :: Gen AwsScope
genAwsScope = do
  account <- elements ["111122223333", "444455556666", "777788889999"]
  -- Through `TestSupport`'s synthetic constructors rather than as literals: a
  -- complete region coordinate compiled into Haskell is refused by the gate,
  -- and a generator is not an exception to that.
  region <- elements [FixtureCaCentral1, FixtureUsEast1, FixtureEuWest2]
  pure (AwsScope (AwsAccountId account) (AwsRegion (fixtureAwsRegion region)))

genHostedZone :: Gen HostedZoneId
genHostedZone = do
  suffix <- elements ["ALPHA", "BRAVO", "CHARLIE", "DELTA"]
  case mkHostedZoneId ("Z0" <> suffix <> "EXAMPLE") of
    Left err -> error ("ScopeCodecProperties: invalid generated zone: " <> show err)
    Right zone -> pure zone

-- | A field value that names the field it belongs to.
--
-- Three of the scope's fields are @Text@ newtypes, so a generator that gave
-- them interchangeable values would pass a codec that swapped two of them. The
-- prefix makes a swap a failing round trip rather than a passing one, and the
-- varying tail keeps the generator from degenerating into one value.
genDiscriminated :: Text -> Gen Text
genDiscriminated label = do
  suffix <- elements ["alpha", "bravo", "charlie", "delta", "echo"]
  pure (label <> "/" <> suffix)

scopeCodecPropertiesSuite :: SuiteBuilder ()
scopeCodecPropertiesSuite =
  describe "Sprint 5.46 observation-scope codec properties" $ do
    propertyTest "decode . encode == id over the canonical wire form" $
      \(GeneratedScope scope) -> scopeFromWire (scopeToWire scope) === Right scope

    propertyTest "the field set round-trips without touching the wire" $
      \(GeneratedScope scope) ->
        observationEvidenceScopeFromFields (observationEvidenceScopeFields scope) === scope

    propertyTest "a zone survives the round trip, and an absent one stays absent" $
      \(GeneratedScope scope) ->
        fmap evidenceAwsDnsZone (scopeFromWire (scopeToWire scope))
          === Right (evidenceAwsDnsZone scope)

    propertyTest "the identity projection separates scopes that differ" $
      \(GeneratedScope left) (GeneratedScope right) ->
        (left == right) === (scopeIdentityText left == scopeIdentityText right)

    propertyTest "every scope field reaches the identity projection" $
      \(GeneratedScope scope) -> everyFieldPresent scope

    propertyTest "a terminal audit re-scope keeps the run's zone" $
      \(GeneratedScope scope) ->
        evidenceAwsDnsZone (scopeForTerminalAudit scope) === evidenceAwsDnsZone scope

    propertyTest "a cascade terminal audit re-scope keeps the run's zone" $
      \(GeneratedScope scope) ->
        evidenceAwsDnsZone (scopeForCascadeTerminalAudit scope) === evidenceAwsDnsZone scope

-- | Every field's own value appears somewhere in the identity projection.
--
-- This is the property a dropped field fails. It is stated over the generated
-- value rather than over a field count, because a projection can carry the right
-- number of entries and still emit a constant where a field belongs — which is
-- exactly what @maybe "" hostedZoneIdText@ does for an absent zone, and why the
-- discriminator beside it is part of the projection rather than a nicety.
everyFieldPresent :: ObservationEvidenceScope -> Property
everyFieldPresent scope = missing === []
 where
  fields = scopeIdentityFields scope
  rendered = Text.concat fields
  missing =
    nub
      [ expected
      | expected <- expectedValues (observationEvidenceScopeFields scope)
      , not (expected `Text.isInfixOf` rendered)
      ]

expectedValues :: ObservationEvidenceScopeFields -> [Text]
expectedValues
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
    , Text.pack (show operation)
    ]
      ++ maybe
        ["aws/absent"]
        (\aws -> [accountValue aws, regionValue aws])
        awsScope
      ++ maybe ["zone/absent"] (pure . hostedZoneIdText) dnsZone

accountValue :: AwsScope -> Text
accountValue aws = case awsScopeAccountId aws of
  AwsAccountId value -> value

regionValue :: AwsScope -> Text
regionValue aws = case awsScopeRegion aws of
  AwsRegion value -> value
