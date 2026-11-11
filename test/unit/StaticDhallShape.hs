{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module StaticDhallShape (staticDhallShapeSuite) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Numeric.Natural (Natural)
import PinnedHeapGraph (GraphObservation, observeGraph, observedDataBytes)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CanonicalDhallValueShape.BoundedStage
import Prodbox.Config.CanonicalDhallValueShape.Stage (staticShapeTemplateExpression)
import Prodbox.Config.OrdinaryMemoryProfile.DeclaredShape (ordinaryMemoryProfileShapeTemplate)
import Prodbox.Config.OrdinaryMemoryProfile.Schema
  ( ordinaryMemoryProfileIdentity
  , ordinaryMemoryProfileRoles
  )
import Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope)
import Prodbox.ControlPlane.RpcBirthSettingsShape (rpcBirthSettingsShapeTemplate)
import StaticDhallShapeFixtures
import Test.Tasty.HUnit (assertBool, assertFailure, (@?=))
import TestSupport (SuiteBuilder, describe, it)

-- A distinct cold CAF allows observing demand before any other suite has used
-- the canonical template. Both derive from the same canonical envelope owner.
{-# NOINLINE coldSettingsTemplate #-}
coldSettingsTemplate :: StaticShapeTemplate SettingsEnvelope
coldSettingsTemplate =
  $( staticShapeTemplateExpression
       (Proxy :: Proxy SettingsEnvelope)
       [ StaticPathText ["parameters", "storage", "manual_pv_host_root"]
       , StaticAwsProfile ["parameters", "aws_substrate", "profile"]
       ]
   )

unicodeTemplate :: StaticShapeTemplate UnicodeRecord
unicodeTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy UnicodeRecord) [StaticAwsProfile []])
choiceTemplate :: StaticShapeTemplate Choice
choiceTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy Choice) [])
integerTemplate :: StaticShapeTemplate Integer
integerTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy Integer) [])
doubleTemplate :: StaticShapeTemplate Double
doubleTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy Double) [])
naturalTemplate :: StaticShapeTemplate (Maybe Natural)
naturalTemplate =
  $( staticShapeTemplateExpression
       (Proxy :: Proxy (Maybe Natural))
       [StaticRequirement [] (RequirePresentNatural (2 ^ (4096 :: Int)))]
   )
countedTemplate :: StaticShapeTemplate [Natural]
countedTemplate =
  $( staticShapeTemplateExpression
       (Proxy :: Proxy [Natural])
       [StaticRequirement [] (RequireListElements 2)]
   )
exactTextTemplate :: StaticShapeTemplate Text
exactTextTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy Text) [StaticRequirement [] (RequireText "λ😀")])
pathTemplate :: StaticShapeTemplate Text
pathTemplate = $(staticShapeTemplateExpression (Proxy :: Proxy Text) [StaticPathText []])

staticDhallShapeSuite :: SuiteBuilder ()
staticDhallShapeSuite = describe "build-time closed inspection metadata" $ do
  it "queries the numeric floor and refuses before metadata materialization" $ do
    required <- evaluate (staticShapeTemplateDataBytes coldSettingsTemplate)
    before <- try (observeGraph coldSettingsTemplate)
    requireDeferredMetadata before
    refuseBelowFloor (materializeStaticShapeTemplateWithin 0 coldSettingsTemplate) required
    after <- try (observeGraph coldSettingsTemplate)
    requireDeferredMetadata after
  it "returns quiescent canonical shape and Either data within the numeric floors" $ do
    checkTemplate ("settings", rpcBirthSettingsShapeTemplate)
    checkTemplate ("profile", ordinaryMemoryProfileShapeTemplate)
  it "derives metadata from the canonical envelope owner and actual profile producer" $ do
    settings <-
      right
        ( compileClosedDhallValueShape (Dhall.declared (Dhall.inject @SettingsEnvelope))
            >>= markCanonicalDhallPathText ["parameters", "storage", "manual_pv_host_root"]
            >>= markCanonicalDhallAwsProfile ["parameters", "aws_substrate", "profile"]
        )
    profile <-
      right
        ( compileClosedDhallValueShape (Dhall.declared (Dhall.inject @Capacity.RuntimeMemoryProfile))
            >>= requireCanonicalDhallValue ["runtime_profile_id"] (RequireText ordinaryMemoryProfileIdentity)
            >>= requireCanonicalDhallValue
              ["child_process_budget", "permit_capacity"]
              (RequirePresentNatural (fromIntegral ordinaryMemoryProfileRoles))
            >>= requireCanonicalDhallValue
              ["child_process_budget", "simultaneous_peak_bytes"]
              (RequireListElements (fromIntegral ordinaryMemoryProfileRoles))
        )
    assertBool
      "settings metadata drifted"
      (materializeStaticShapeTemplate rpcBirthSettingsShapeTemplate == settings)
    assertBool
      "profile metadata drifted"
      (materializeStaticShapeTemplate ordinaryMemoryProfileShapeTemplate == profile)
  it "preserves every constructor, non-ASCII metadata and wide scalar literals" $ do
    checkSpecial (Proxy @UnicodeRecord) [StaticAwsProfile []] unicodeTemplate
    checkSpecial (Proxy @Choice) [] choiceTemplate
    checkSpecial (Proxy @Integer) [] integerTemplate
    checkSpecial (Proxy @Double) [] doubleTemplate
    checkSpecial
      (Proxy @(Maybe Natural))
      [StaticRequirement [] (RequirePresentNatural (2 ^ (4096 :: Int)))]
      naturalTemplate
    checkSpecial (Proxy @[Natural]) [StaticRequirement [] (RequireListElements 2)] countedTemplate
    checkSpecial (Proxy @Text) [StaticRequirement [] (RequireText "λ😀")] exactTextTemplate
    checkSpecial (Proxy @Text) [StaticPathText []] pathTemplate
  it "refuses unsupported actual producer declarations during build preparation" $
    either Just (const Nothing) (prepareStaticShapeDefinition (Proxy @Unsupported) [])
      @?= Just (StaticShapeSchemaRefused CanonicalDhallValueSchemaUnsupported)
  it "refuses missing semantic paths during build preparation" $
    either
      Just
      (const Nothing)
      ( prepareStaticShapeDefinition
          (Proxy @SettingsEnvelope)
          [StaticRequirement ["missing"] (RequireText "missing")]
      )
      @?= Just (StaticShapeSchemaRefused CanonicalDhallValueSchemaUnsupported)
  it "refuses unbounded list and actual profile declarations before certification" $ do
    requireUnbounded (prepareBoundedStaticShapeDefinition (Proxy @[Natural]) [])
    requireUnbounded (prepareBoundedStaticShapeDefinition (Proxy @Capacity.RuntimeMemoryProfile) [])
  it "certifies exact-count lists and empty outer lists with unbounded elements" $ do
    _ <-
      right
        ( prepareBoundedStaticShapeDefinition
            (Proxy @[Natural])
            [StaticRequirement [] (RequireListElements 2)]
        )
    _ <-
      right
        ( prepareBoundedStaticShapeDefinition
            (Proxy @[[Natural]])
            [StaticRequirement [] (RequireListElements 0)]
        )
    pure ()
  it "retains structured preparation failures before the finite-count check" $ do
    let expected = BoundedStaticPreparationRefused (StaticShapeSchemaRefused CanonicalDhallValueSchemaUnsupported)
    either Just (const Nothing) (prepareBoundedStaticShapeDefinition (Proxy @Unsupported) [])
      @?= Just expected
    either
      Just
      (const Nothing)
      ( prepareBoundedStaticShapeDefinition
          (Proxy @Capacity.RuntimeMemoryProfile)
          [StaticRequirement ["missing"] (RequireText "missing")]
      )
      @?= Just expected

requireUnbounded :: Either BoundedStaticShapeError value -> IO ()
requireUnbounded result = case result of
  Left cause -> cause @?= BoundedStaticValueListUnbounded
  Right _ -> assertFailure "an unbounded declaration received a finite-count certificate"

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

requireDeferredMetadata :: Either SomeException GraphObservation -> IO ()
requireDeferredMetadata observation = case observation of
  Left cause ->
    assertBool
      ("unrelated pre-materialization refusal: " <> displayException cause)
      ("unexpected closure" `Text.isInfixOf` Text.pack (displayException cause))
  Right _ -> assertFailure "numeric-only query forced the complete template metadata"

refuseBelowFloor :: Either StaticShapeTemplateError value -> Natural -> IO ()
refuseBelowFloor observation required = case observation of
  Left cause -> cause @?= StaticShapeDataUnderfunded required 0
  Right _ -> assertFailure "underfunded metadata was materialized"

checkTemplate :: (String, StaticShapeTemplate value) -> IO ()
checkTemplate (label, template) = do
  required <- evaluate (staticShapeTemplateDataBytes template)
  numberGraph <- observeGraph required
  result <- evaluate (materializeStaticShapeTemplateWithin required template)
  graph <- observeGraph result
  _ <- right result
  assertBool
    "lifted shape exceeds constructor-data bound"
    (observedDataBytes graph <= toInteger required)
  print (label, required, observedDataBytes numberGraph, observedDataBytes graph)

checkSpecial
  :: (Dhall.ToDhall value)
  => Proxy value -> [StaticShapeTransform] -> StaticShapeTemplate value -> IO ()
checkSpecial producer transforms template = do
  checkTemplate ("special", template)
  definition <- right (prepareStaticShapeDefinition producer transforms)
  assertBool
    "lifted shape differs from actual canonical declaration"
    (materializeStaticShapeTemplate template == staticShapeDefinitionShape definition)
