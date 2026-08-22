{-# LANGUAGE OverloadedStrings #-}

module HostCleanupCompositionRoot
  ( hostCleanupCompositionRootSuite
  )
where

import Data.List (nub)
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (OrdinaryTeardownWithoutTargetAgent)
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( mkLifecycleAuthorityAdmissionWait
  )
import Prodbox.Lifecycle.HostCleanupCompositionRoot
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction (mkSubstrateApiWait)
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

hostCleanupCompositionRootSuite :: SuiteBuilder ()
hostCleanupCompositionRootSuite =
  describe "Sprint 4.86 host cleanup composition root" $ do
    it "refuses a host with no Tier-0 floor without opening a session" $ do
      -- The ordering property, measured rather than asserted in a comment: an
      -- empty directory has no basics floor, and the refusal names that rather
      -- than an authentication failure — which is what a composition that
      -- authenticated first would have reported for an operator's config
      -- defect.
      withSystemTempDirectory "prodbox-host-cleanup-composition" $ \dir -> do
        resolved <- resolveHostCleanupLocalComposition (inputsFor dir)
        case resolved of
          Right _ ->
            expectationFailure
              "an empty directory must not resolve a host cleanup composition"
          Left err -> err `shouldSatisfy` isLocalRefusal

    it "derives the durable record from the same located root" $ do
      -- The artifact store, the completion journal, and the durable
      -- host-cleanup record all come from one locator, so a resumed run reads
      -- the phase it reached beside the bytes it reached it with.
      root <- readFile "src/Prodbox/Lifecycle/HostCleanupCompositionRoot.hs"
      root `shouldContain` "bootstrapLocatedRetainedArtifactStore locator"
      root `shouldContain` "bootstrapLocatedHostCleanupCompletionJournal locator"
      root `shouldContain` "bootstrapLocatedHostCleanupIntentStore locator"

    it "renders every refusal distinctly" $ do
      -- Each arm names the layer that refused, so an operator is told which
      -- surface to fix rather than that "the cascade could not start".
      let rendered = map renderHostCleanupCompositionError refusals
      length (nub rendered) `shouldBe` length refusals
      all (not . null) rendered `shouldBe` True
 where
  inputsFor dir =
    HostCleanupCompositionInputs
      { hostCleanupRepositoryRoot = dir
      , hostCleanupCaller = LifecycleAuthorityOperator
      , hostCleanupRecoveryTargetAgent = OrdinaryTeardownWithoutTargetAgent
      , hostCleanupSubstrateApiWait = requiredApiWait
      , hostCleanupAdmissionWait = requiredAdmissionWait
      , hostCleanupChartReconciler = \_ -> pure (Right ())
      }

  requiredApiWait = case mkSubstrateApiWait 1 1 of
    Right wait -> wait
    Left detail -> error (show detail)

  requiredAdmissionWait = case mkLifecycleAuthorityAdmissionWait 1 1 of
    Right wait -> wait
    Left detail -> error (show detail)

  refusals =
    [ HostCleanupCompositionBasicsUnreadable "no floor"
    , HostCleanupCompositionConfigUnreadable "no config"
    , HostCleanupCompositionAuthorityCoordinateInvalid "no coordinate"
    , HostCleanupCompositionJournalUnusable "no journal"
    ]

-- | A refusal that was decided on the host, before any session existed.
isLocalRefusal :: HostCleanupCompositionError -> Bool
isLocalRefusal err = case err of
  HostCleanupCompositionAuthenticationFailed _ -> False
  _ -> True
