{-# LANGUAGE OverloadedStrings #-}

module HarnessInitRecovery (harnessInitRecoverySuite) where

import Control.Monad (forM_)
import Data.Text (Text)
import Prodbox.Bootstrap.Broker.InitializationEvidence
import Prodbox.Bootstrap.Broker.Types (VaultStorageGeneration, mkVaultStorageGeneration)
import Prodbox.Bootstrap.HarnessInitRecovery
import Prodbox.ControlPlane.Deadline
import TestSupport

harnessInitRecoverySuite :: SuiteBuilder ()
harnessInitRecoverySuite = describe "HARNESS-RETAINED-INIT-RECOVERY-2026-10-22" $ do
  it "preserves the fresh and healthy bootstrap projection" $ do
    decideHarnessInitRecovery fresh `shouldBe` HarnessContinueBootstrap
    decideHarnessInitRecovery durable `shouldBe` HarnessContinueBootstrap
    decideHarnessInitRecovery durable {harnessInitSealed = True} `shouldBe` HarnessContinueBootstrap
  forM_
    ( filter
        (\phase -> rootInitializationPending phase && phase /= InitResetInFlight)
        [minBound .. maxBound]
    )
    $ \phase ->
      it ("selects one retained continuation for " ++ show phase) $
        decideHarnessInitRecovery pending {harnessInitPhase = Just phase}
          `shouldBe` HarnessResumeInitialization
  forM_ [False, True] $ \initialized ->
    it ("selects audited ambiguity repair with initialized=" ++ show initialized) $
      decideHarnessInitRecovery ambiguous {harnessInitInitialized = initialized}
        `shouldBe` HarnessResetAmbiguousInitialization
  forM_ [originalGeneration, replacementGeneration] $ \current ->
    it ("replays the durable reset binding from current generation " ++ show current) $ do
      let pendingReset =
            ambiguous
              { harnessInitGeneration = current
              , harnessInitPhase = Just InitResetInFlight
              , harnessInitResetFrom = Just originalGeneration
              }
      decideHarnessInitRecovery pendingReset `shouldBe` HarnessResetAmbiguousInitialization
      harnessResetRequestGeneration pendingReset `shouldBe` Right originalGeneration
      decideHarnessInitAfterReset pendingReset resetPristine `shouldBe` HarnessContinueBootstrap
  it "refuses a pending reset whose old generation is unavailable" $
    decideHarnessInitRecovery ambiguous {harnessInitPhase = Just InitResetInFlight}
      `shouldBe` HarnessInitializationRefused HarnessInitResetLineageMismatch
  it "refuses an ambiguity tag that contradicts the flag" $
    decideHarnessInitRecovery ambiguous {harnessInitAmbiguous = False}
      `shouldBe` HarnessInitializationRefused HarnessInitObservationInconsistent
  it "refuses an initialized-state contradiction at durable custody" $
    decideHarnessInitRecovery durable {harnessInitInitialized = False}
      `shouldBe` HarnessInitializationRefused HarnessInitObservationInconsistent
  it "advances a recovered encrypted response only at exact completed custody" $
    decideHarnessInitAfterResume pending durable `shouldBe` HarnessContinueBootstrap
  it "requires the audited reset after missing-response recovery" $
    decideHarnessInitAfterResume pending ambiguous `shouldBe` HarnessResetAmbiguousInitialization
  it "preserves an unresolved continuation without a fresh init" $
    decideHarnessInitAfterResume pending pending
      `shouldBe` HarnessInitializationRefused HarnessInitResumeUnresolved
  it "refuses missing phase proof after a response-lost continuation" $
    decideHarnessInitAfterResume pending durable {harnessInitPhase = Nothing}
      `shouldBe` HarnessInitializationRefused HarnessInitResumeUnresolved
  it "refuses a changed generation during continuation" $
    decideHarnessInitAfterResume pending durable {harnessInitGeneration = replacementGeneration}
      `shouldBe` HarnessInitializationRefused HarnessInitResumeGenerationChanged
  it "closes reset only on a fresh sealed pristine descendant of the exact old generation" $
    decideHarnessInitAfterReset ambiguous resetPristine `shouldBe` HarnessContinueBootstrap
  forM_
    [
      ( "same generation"
      , resetPristine {harnessInitGeneration = originalGeneration}
      , HarnessInitResetGenerationUnchanged
      )
    , ("missing lineage", resetPristine {harnessInitResetFrom = Nothing}, HarnessInitResetLineageMismatch)
    ,
      ( "foreign lineage"
      , resetPristine {harnessInitResetFrom = Just foreignGeneration}
      , HarnessInitResetLineageMismatch
      )
    , ("initialized", resetPristine {harnessInitInitialized = True}, HarnessInitResetNotPristine)
    , ("unsealed", resetPristine {harnessInitSealed = False}, HarnessInitResetNotPristine)
    , ("ambiguous", resetPristine {harnessInitAmbiguous = True}, HarnessInitResetNotPristine)
    , ("pending", resetPristine {harnessInitPhase = Just InitCallInFlight}, HarnessInitResetNotPristine)
    , ("missing phase", resetPristine {harnessInitPhase = Nothing}, HarnessInitResetNotPristine)
    ,
      ( "plain pristine"
      , resetPristine {harnessInitPhase = Just InitPristine}
      , HarnessInitResetNotPristine
      )
    ]
    $ \(label, observed, cause) ->
      it ("preserves the generation after reset closing refusal: " ++ label) $
        decideHarnessInitAfterReset ambiguous observed `shouldBe` HarnessInitializationRefused cause
  it "uses the original three-request total and reserves unchanged transport plus server maxima" $ do
    harnessBootstrapBudgetMicros `shouldBe` 900000000
    harnessBrokerCallBudgetMicros `shouldBe` 600000000
  forM_
    [ (0, True)
    , (299999999, True)
    , (300000000, True)
    , (300000001, False)
    , (899999999, False)
    , (900000000, False)
    , (900000001, False)
    ]
    $ \(elapsed, expected) ->
      it ("never refreshes the parent budget at elapsed micros " ++ show elapsed) $ do
        let deadline = deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration harnessBootstrapBudgetMicros)
        harnessBrokerCallFits (monotonicInstantFromMicros elapsed) deadline `shouldBe` expected

originalGeneration :: VaultStorageGeneration
originalGeneration = generation "harness-original"

replacementGeneration :: VaultStorageGeneration
replacementGeneration = generation "harness-replacement"

foreignGeneration :: VaultStorageGeneration
foreignGeneration = generation "harness-foreign"

generation :: Text -> VaultStorageGeneration
generation value = either (error . show) id (mkVaultStorageGeneration value)

fresh :: HarnessInitObservation
fresh = HarnessInitObservation originalGeneration False True False Nothing Nothing

pending :: HarnessInitObservation
pending = fresh {harnessInitPhase = Just InitCallInFlight}

ambiguous :: HarnessInitObservation
ambiguous = pending {harnessInitAmbiguous = True, harnessInitPhase = Just InitAmbiguous}

durable :: HarnessInitObservation
durable =
  fresh
    { harnessInitInitialized = True
    , harnessInitSealed = False
    , harnessInitPhase = Just InitCustodyDurable
    }

resetPristine :: HarnessInitObservation
resetPristine =
  fresh
    { harnessInitGeneration = replacementGeneration
    , harnessInitPhase = Just InitResetPristine
    , harnessInitResetFrom = Just originalGeneration
    }
