{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.88: the @cluster delete@ entry table and its retained-state
-- narration.
--
-- The no-install short-circuit used to be selected by install presence alone,
-- so a @--cascade@ that reached no phase returned @ExitSuccess@ — and the only
-- supported narration about the retained root is rendered from arms that
-- reached a delete path, so the exit that reached none said nothing about the
-- store and still read as success. These cases pin the two tables that make
-- that arm unreachable.
module ClusterDeleteEntryArm
  ( clusterDeleteEntryArmSuite
  )
where

import Data.List (sort)
import Prodbox.CLI.Rke2
import Prodbox.Lifecycle.TagSweep
  ( TagSweepVerdict (..)
  , TaggedResource (..)
  )
import System.Exit (ExitCode (ExitSuccess))
import TestSupport

clusterDeleteEntryArmSuite :: SuiteBuilder ()
clusterDeleteEntryArmSuite =
  describe "Sprint 4.88 cluster delete entry arms" $ do
    it "selects exactly one no-install success arm, in the local-only mode" $ do
      let product' =
            [ (mode, presence)
            | mode <- [DeleteModeLocalUninstall, DeleteModeCascade]
            , presence <- [minBound .. maxBound]
            ]
          successArms =
            [ (mode, presence)
            | (mode, presence) <- product'
            , presence == Rke2NotInstalled
            , deleteArmIsNoInstallSuccess (selectDeleteEntryArm mode presence)
            ]
      length product' `shouldBe` 4
      successArms `shouldBe` [(DeleteModeLocalUninstall, Rke2NotInstalled)]
      -- The cascade mode cannot reach it, and cannot be given it by a later
      -- caller: the arm it selects is a different constructor entirely.
      selectDeleteEntryArm DeleteModeCascade Rke2NotInstalled
        `shouldBe` DeleteArmCascadeNoInstall

    it "maps every mode and presence pair to a distinct terminal arm" $ do
      let arms =
            [ selectDeleteEntryArm mode presence
            | mode <- [DeleteModeLocalUninstall, DeleteModeCascade]
            , presence <- [minBound .. maxBound]
            ]
      sort arms `shouldBe` sort ([minBound .. maxBound] :: [DeleteTerminalArm])

    it "licenses the retained root from exactly the local-only mode" $ do
      -- Every arm is enumerated: a new one with no narration fails to compile
      -- rather than silently rendering nothing, and this case pins which arms
      -- may say the store is preserved.
      let preserved =
            [ arm
            | arm <- [minBound .. maxBound]
            , retainedStateNarrationFor arm == RetainedStatePreserved
            ]
      -- Sprint 4.100: a local-only mode destroys no AWS by construction,
      -- whether or not an install was present, so both of its arms may say the
      -- store is preserved and neither cascade arm may.
      preserved
        `shouldBe` [DeleteArmLocalOnlyNoInstall, DeleteArmLocalOnlyUninstalled]
      -- The legacy cascade carries no completion receipt, so the arm that ran
      -- its phases names what it did not prove rather than licensing the store.
      retainedStateNarrationFor DeleteArmCascadeReachedPhases
        `shouldBe` RetainedStateUnproven
      -- And the cascade that reached no phase now names the store too. Silence
      -- on the exits that explain least is the defect this closes, so the
      -- narration type no longer has a case for it.
      retainedStateNarrationFor DeleteArmCascadeNoInstall
        `shouldBe` RetainedStateUnproven
      ([minBound .. maxBound] :: [RetainedStateNarration])
        `shouldBe` [RetainedStatePreserved, RetainedStateUnproven]

    it "gives every arm a sentence that does not claim what it did not do" $ do
      retainedStateNoticePerRunLine DeleteArmLocalOnlyUninstalled
        `shouldSatisfy` containsAll
          [ "were NOT destroyed by this local uninstall"
          , "preserved by this uninstall"
          ]
      retainedStateNoticePerRunLine DeleteArmCascadeReachedPhases
        `shouldSatisfy` containsAll
          [ "NO completion receipt"
          , "no exit status from this route authorizes deleting it"
          ]
      -- Sprint 4.100. The no-install arms may not borrow the sentences of the
      -- arms that ran something: one uninstalled nothing, the other attempted
      -- no destroy, and both used to render no sentence at all.
      retainedStateNoticePerRunLine DeleteArmLocalOnlyNoInstall
        `shouldSatisfy` containsAll
          [ "nothing was uninstalled"
          , "The retained root above is preserved"
          ]
      retainedStateNoticePerRunLine DeleteArmLocalOnlyNoInstall
        `shouldSatisfy` (not . isInfixOfString "this uninstall.")
      retainedStateNoticePerRunLine DeleteArmCascadeNoInstall
        `shouldSatisfy` containsAll
          [ "reached no phase and attempted no per-run AWS destroy"
          , "no confirmed postflight sweep"
          , "no exit status from this route authorizes deleting it"
          ]
      retainedStateNoticePerRunLine DeleteArmCascadeNoInstall
        `shouldSatisfy` (not . isInfixOfString "were attempted earlier in this cascade")

    it "names the retained root's capability classes and its resolved path" $ do
      -- The inventory called the root "MinIO-backed per-run Pulumi state" and
      -- printed a hardcoded `.data/` beside the resolved path, so a host whose
      -- manual_pv_host_root is configured elsewhere was shown a path it does
      -- not use. The resolved root is printed once and the classes are named.
      let rendered =
            unlines (retainedRootInventoryLines DeleteArmLocalOnlyUninstalled "/srv/elsewhere")
      rendered
        `shouldSatisfy` containsAll
          [ "retained root: /srv/elsewhere"
          , "multi-writer capability store"
          , "Vault durable PV: /srv/elsewhere/vault/vault/0"
          , "bootstrap unlock bundle"
          , "write-ahead ownership manifests"
          , "aws-ses"
          , "container-registry blobs"
          ]
      rendered `shouldSatisfy` (not . isInfixOfString ".data/")
      rendered `shouldSatisfy` (not . isInfixOfString "per-run Pulumi state) is retained")
      -- The heading may not claim an uninstall that did not happen.
      unlines (retainedRootInventoryLines DeleteArmLocalOnlyNoInstall "/srv/elsewhere")
        `shouldSatisfy` isInfixOfString "No local cluster was installed."
      unlines (retainedRootInventoryLines DeleteArmCascadeNoInstall "/srv/elsewhere")
        `shouldSatisfy` isInfixOfString "no cascade phase ran"

    it "mints a confirmed no-install cascade only from a confirming sweep" $ do
      -- The entry table cannot return this: it is a different type whose
      -- constructor this module cannot name. `confirmCascadeNoInstall` is the
      -- only producer in scope, and its admitting cases are exactly the two
      -- that `decideCascadeUninstallGate` admits.
      fmap confirmedNoInstallCascadeExit (confirmCascadeNoInstall CascadeSweepNotOwed)
        `shouldBe` Just ExitSuccess
      fmap
        confirmedNoInstallCascadeExit
        (confirmCascadeNoInstall (CascadeSweepRan (TagSweepConfirmedClean [])))
        `shouldBe` Just ExitSuccess
      confirmCascadeNoInstall (CascadeSweepNotRun "credential absent")
        `shouldBe` Nothing
      confirmCascadeNoInstall (CascadeSweepRan (TagSweepEscaped [] [escapedFixture]))
        `shouldBe` Nothing
      confirmCascadeNoInstall (CascadeSweepRan (TagSweepUnconfirmed "unreadable"))
        `shouldBe` Nothing

-- | One escaped row is all the verdict needs to be non-empty; the sweep's own
-- suite owns what a row means.
escapedFixture :: TaggedResource
escapedFixture =
  TaggedResource
    { taggedResourceArn =
        "arn:aws:ec2:"
          ++ fixtureAwsRegion FixtureEuWest2
          ++ ":000000000000:vpc/vpc-escaped"
    , taggedResourceMatchedTagKey = "prodbox.io/run-scope"
    , taggedResourceMatchedTagValue = "escaped-fixture"
    }

containsAll :: [String] -> String -> Bool
containsAll needles haystack = all (`isInfixOfString` haystack) needles

isInfixOfString :: String -> String -> Bool
isInfixOfString needle haystack =
  any (startsWith needle) (tailsOf haystack)
 where
  startsWith [] _ = True
  startsWith _ [] = False
  startsWith (x : xs) (y : ys) = x == y && startsWith xs ys
  tailsOf [] = [[]]
  tailsOf value@(_ : rest) = value : tailsOf rest
