{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityConfig
  ( lifecycleAuthorityConfigSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.Config
import TestSupport

lifecycleAuthorityConfigSuite :: SuiteBuilder ()
lifecycleAuthorityConfigSuite =
  describe "Sprint 4.48 Lifecycle Authority in-force-config propose-CAS" $ do
    it "seeds once from the Tier-0 boot projection" $ do
      let (d, s) = stepConfigPropose SchemaSupported initialConfigState seed
      d `shouldBe` ConfigSeeded inForce1
      observeInForceConfig s `shouldBe` Just inForce1

    it "refuses a CAS update before the config is seeded" $
      decideConfigPropose SchemaSupported initialConfigState update
        `shouldBe` ConfigProposeRefused ConfigNotSeeded

    it "refuses a re-seed after the config is seeded" $
      decideConfigPropose SchemaSupported seeded seed
        `shouldBe` ConfigProposeRefused ConfigAlreadySeeded

    it "refuses an unsupported schema" $
      decideConfigPropose SchemaUnsupported initialConfigState seed
        `shouldBe` ConfigProposeRefused ConfigSchemaUnsupported

    it "CAS-advances the generation on a matching expected prior" $
      decideConfigPropose SchemaSupported seeded update
        `shouldBe` ConfigProposed inForce2

    it "refuses a stale or concurrent expected prior" $
      decideConfigPropose
        SchemaSupported
        seeded
        update {proposalExpectedPrior = Just (ConfigGeneration 5)}
        `shouldBe` ConfigProposeRefused ConfigCasConflict

    it "is an idempotent no-op when the in-force digest is re-proposed" $ do
      decideConfigPropose SchemaSupported seeded reproposeCurrent
        `shouldBe` ConfigProposeNoop inForce1
      -- even with a stale expected prior (a lost-response re-propose converges)
      decideConfigPropose
        SchemaSupported
        seeded
        reproposeCurrent {proposalExpectedPrior = Just (ConfigGeneration 0)}
        `shouldBe` ConfigProposeNoop inForce1

    it "observes nothing before seed and the current generation after" $ do
      observeInForceConfig initialConfigState `shouldBe` Nothing
      observeInForceConfig seeded `shouldBe` Just inForce1

    it "validates only positive generations/schema and lowercase ASCII SHA-256 identities" $ do
      validateConfigState ConfigUnseeded `shouldBe` Right ()
      validateConfigState (ConfigInForce validInForce) `shouldBe` Right ()
      validateConfigState
        (ConfigInForce validInForce {inForceGeneration = ConfigGeneration 0})
        `shouldBe` Left ConfigGenerationZero
      validateConfigState
        (ConfigInForce validInForce {inForceSchema = ConfigSchemaVersion 0})
        `shouldBe` Left ConfigSchemaVersionZero
      validateConfigState
        (ConfigInForce validInForce {inForceDigest = ConfigDigest (Text.replicate 64 "A")})
        `shouldBe` Left ConfigDigestInvalid
      validateConfigState
        (ConfigInForce validInForce {inForceReference = ConfigReference (Text.replicate 64 "١")})
        `shouldBe` Left ConfigReferenceInvalid
 where
  seed = ConfigProposal Nothing (ConfigSchemaVersion 1) (ConfigDigest "d1") (ConfigReference "r1")
  update =
    ConfigProposal
      (Just (ConfigGeneration 1))
      (ConfigSchemaVersion 1)
      (ConfigDigest "d2")
      (ConfigReference "r2")
  reproposeCurrent =
    ConfigProposal
      (Just (ConfigGeneration 1))
      (ConfigSchemaVersion 1)
      (ConfigDigest "d1")
      (ConfigReference "r1")
  inForce1 =
    InForceConfig
      (ConfigGeneration 1)
      (ConfigSchemaVersion 1)
      (ConfigDigest "d1")
      (ConfigReference "r1")
  inForce2 =
    InForceConfig
      (ConfigGeneration 2)
      (ConfigSchemaVersion 1)
      (ConfigDigest "d2")
      (ConfigReference "r2")
  seeded = snd (stepConfigPropose SchemaSupported initialConfigState seed)
  validInForce =
    InForceConfig
      (ConfigGeneration 1)
      (ConfigSchemaVersion 1)
      (ConfigDigest (Text.replicate 64 "a"))
      (ConfigReference (Text.replicate 64 "b"))
