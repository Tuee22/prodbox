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

    it "licenses the retained root from exactly the explicit local uninstall" $ do
      -- Every arm is enumerated: a new one with no narration fails to compile
      -- rather than silently rendering nothing, and this case pins which arms
      -- may say the store is preserved.
      let preserved =
            [ arm
            | arm <- [minBound .. maxBound]
            , retainedStateNarrationFor arm == RetainedStatePreserved
            ]
      preserved `shouldBe` [DeleteArmLocalOnlyUninstalled]
      -- The legacy cascade carries no completion receipt, so the arm that ran
      -- its phases names what it did not prove rather than licensing the store.
      retainedStateNarrationFor DeleteArmCascadeReachedPhases
        `shouldBe` RetainedStateUnproven
      -- The two arms that reached no delete path say nothing about the store,
      -- which is what keeps the local-only no-install trace unchanged.
      retainedStateNarrationFor DeleteArmLocalOnlyNoInstall
        `shouldBe` RetainedStateSilent
      retainedStateNarrationFor DeleteArmCascadeNoInstall
        `shouldBe` RetainedStateSilent

    it "keeps the local-only per-run sentence and adds the cascade's refusal" $ do
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
