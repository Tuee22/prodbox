{-# LANGUAGE OverloadedStrings #-}

module AwsLifecycleDrillLedgerTests (awsLifecycleDrillLedgerSuite) where

import Control.Exception (ErrorCall (..), throwIO, try)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.AwsLifecycleDrillRecorder
import Prodbox.Test.AwsLifecycleReceipt
import Prodbox.Test.Qualification.AwsLifecycleDrillLedger
import Prodbox.Test.Qualification.AwsLifecycleDrillLedgerStore
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport (SuiteBuilder, describe, it)

digestA, digestB, imageA, imageB :: Text
digestA = "a"
digestB = "b"
imageA = "img-a"
imageB = "img-b"

-- | Append one complete drill.
drill
  :: Int
  -> DrillKind
  -> Text
  -> Text
  -> Int
  -> DrillOutcome
  -> Maybe Int
  -> Bool
  -> DrillLedger
  -> DrillLedger
drill identifier kind digest image day outcome minutes merged =
  appendDrillRecord
    ( RecordClosed
        DrillClosed
          { closedId = identifier
          , closedOutcome = outcome
          , closedDestroyMinutes = minutes
          , closedScopedDiffEmpty = outcome == DrillClean
          , closedAfterUnchangedScopeMerge = merged
          }
    )
    . appendDrillRecord
      ( RecordBegun
          DrillBegun
            { begunId = identifier
            , begunKind = kind
            , begunScopedDigest = digest
            , begunImageDigest = image
            , begunDay = day
            }
      )

clean :: Int -> DrillKind -> Text -> Int -> DrillLedger -> DrillLedger
clean identifier kind digest day = drill identifier kind digest imageA day DrillClean (Just 10) False

-- | Every criterion met on one digest.
fullLedger :: DrillLedger
fullLedger =
  foldl
    (\ledger step -> step ledger)
    emptyDrillLedger
    ( [ clean 1 DrillCanary digestA 0
      , clean 2 DrillCanary digestA 0
      , clean 3 DrillLeakInjectedDestroy digestA 0
      , clean 4 DrillKilledMidRunConverge digestA 0
      , clean 5 DrillEksCycle digestA 1
      , clean 6 DrillEksCycle digestA 1
      ]
        ++ [ drill (10 + n) DrillSoakRun digestA imageA n DrillClean (Just 10) (n >= 8)
           | n <- [0 .. 9]
           ]
    )

awsLifecycleDrillLedgerSuite :: SuiteBuilder ()
awsLifecycleDrillLedgerSuite =
  describe "AWS lifecycle drill ledger" $ do
    it "an empty ledger is not qualified, bounds nothing and prints the uncovered list" $ do
      let receipt = judgeReceipt emptyDrillLedger
      receiptVerdict receipt @?= NotQualified [minBound .. maxBound]
      receiptBoundPercent receipt @?= 100
      receiptUncovered receipt @?= uncoveredStatement
    it "every criterion met on one identity qualifies, and two clean cycles bound the rate at 78%" $ do
      let receipt = judgeReceipt fullLedger
      receiptVerdict receipt @?= Qualified
      receiptBoundPercent receipt @?= 78
      assertBool "chain intact" (receiptChainIntact receipt)
    it "a missing criterion refuses QUALIFIED and names it" $ do
      let one =
            foldl (\l s -> s l) emptyDrillLedger [clean 1 DrillCanary digestA 0, clean 2 DrillCanary digestA 0]
      case receiptVerdict (judgeReceipt one) of
        NotQualified missing -> assertBool "eks cycles missing" (TwoConsecutiveEksCycles `elem` missing)
        Qualified -> fail "must not qualify"
    it "a drill that needed a hand action breaks the count and is never counted" $ do
      let ledger =
            foldl
              (\l s -> s l)
              emptyDrillLedger
              [ clean 1 DrillEksCycle digestA 0
              , drill 2 DrillEksCycle digestA imageA 1 DrillNeededHandAction (Just 10) False
              , clean 3 DrillEksCycle digestA 2
              ]
          receipt = judgeReceipt ledger
      receiptRunLength receipt @?= 1
      assertBool "not qualified" (receiptVerdict receipt /= Qualified)
      receiptBoundPercent receipt @?= failureRateBoundPercent 1
    it "an interrupted drill (Begun, no Closed) breaks the run" $ do
      let ledger =
            appendDrillRecord
              (RecordBegun (DrillBegun 2 DrillCanary digestA imageA 1))
              (clean 1 DrillCanary digestA 0 emptyDrillLedger)
      currentRun (resolveDrillAttempts ledger) @?= []
    it "a source change inside the scope starts a new run" $ do
      let ledger =
            foldl
              (\l s -> s l)
              emptyDrillLedger
              [clean 1 DrillCanary digestA 0, clean 2 DrillCanary digestA 0, clean 3 DrillCanary digestB 1]
      length (currentRun (resolveDrillAttempts ledger)) @?= 1
    it "a Provider image digest change with an unchanged scoped digest is reported, not resetting" $ do
      let ledger =
            foldl
              (\l s -> s l)
              emptyDrillLedger
              [ drill 1 DrillCanary digestA imageA 0 DrillClean (Just 1) False
              , drill 2 DrillCanary digestA imageB 1 DrillClean (Just 1) False
              ]
          receipt = judgeReceipt ledger
      receiptRunLength receipt @?= 2
      receiptImageDigestChanges receipt @?= 1
    it "an EKS destroy over the bound does not count" $ do
      let ledger =
            foldl
              (\l s -> s l)
              emptyDrillLedger
              [ drill 1 DrillEksCycle digestA imageA 0 DrillClean (Just (maximumDestroyMinutes + 1)) False
              , clean 2 DrillEksCycle digestA 1
              ]
      case receiptVerdict (judgeReceipt ledger) of
        NotQualified missing -> assertBool "cycles unmet" (TwoConsecutiveEksCycles `elem` missing)
        Qualified -> fail "must not qualify"
    it "a soak shorter than five days or without merge runs is not enough" $ do
      let shortSoak =
            foldl
              (\l s -> s l)
              emptyDrillLedger
              [drill (n + 1) DrillSoakRun digestA imageA 0 DrillClean (Just 1) False | n <- [0 .. 9]]
      case receiptVerdict (judgeReceipt shortSoak) of
        NotQualified missing -> do
          assertBool "span unmet" (TenRunSoakOverFiveDays `elem` missing)
          assertBool "merge unmet" (SoakAfterUnchangedScopeMerges `elem` missing)
        Qualified -> fail "must not qualify"
    it "the chain verifies and its tip advances with each append" $ do
      assertBool "intact" (verifyDrillChain fullLedger)
      let tampered = appendDrillRecord (RecordBegun (DrillBegun 99 DrillCanary digestA imageA 0)) emptyDrillLedger
      assertBool "intact single" (verifyDrillChain tampered)
      assertBool
        "tip changes with each append"
        (drillLedgerTip tampered /= drillLedgerTip emptyDrillLedger)
    it "the ledger round-trips through its line format and still judges the same" $ do
      case parseDrillLedger (renderDrillLedger fullLedger) of
        Left err -> fail (Text.unpack err)
        Right parsed -> do
          drillLedgerTip parsed @?= drillLedgerTip fullLedger
          judgeReceipt parsed @?= judgeReceipt fullLedger
    it "an edited, reordered or dropped-middle ledger file is refused" $ do
      let rendered = Text.lines (renderDrillLedger fullLedger)
          dropped = Text.unlines (take 2 rendered ++ drop 3 rendered)
          swapped = Text.unlines (take 2 rendered ++ [rendered !! 3, rendered !! 2] ++ drop 4 rendered)
          outcomeEdit = Text.unlines (map (Text.replace "|DrillClean|" "|DrillFailed|") rendered)
      assertBool "the fixture has a closed outcome to edit" (outcomeEdit /= Text.unlines rendered)
      assertBool "dropped middle refused" (isLeft (parseDrillLedger dropped))
      assertBool "swapped refused" (isLeft (parseDrillLedger swapped))
      assertBool "closed outcome edit refused" (isLeft (parseDrillLedger outcomeEdit))
    it "the store appends at the expected tip, refuses a stale tip and a malformed record" $
      withSystemTempDirectory "drill-store" $ \directory -> do
        let path = directory </> "qualification" </> "drills.ledger"
            begun = RecordBegun (DrillBegun 1 DrillCanary digestA imageA 0)
            closed =
              RecordClosed (DrillClosed 1 DrillClean (Just 1) True False)
        absent <- readDrillLedger path
        absent @?= Right emptyDrillLedger
        first <- appendDrillRecordAtTip path (drillLedgerTip emptyDrillLedger) begun
        case first of
          Left err -> fail (renderDrillStoreError err)
          Right ledger -> do
            stale <- appendDrillRecordAtTip path (drillLedgerTip emptyDrillLedger) closed
            stale @?= Left DrillStoreTipChanged
            second <- appendDrillRecordAtTip path (drillLedgerTip ledger) closed
            case second of
              Left err -> fail (renderDrillStoreError err)
              Right both -> do
                reread <- readDrillLedger path
                reread @?= Right both
                length (resolveDrillAttempts both) @?= 1
        bad <-
          appendDrillRecordAtTip
            path
            (drillLedgerTip emptyDrillLedger)
            (RecordBegun (DrillBegun 2 DrillCanary "a|b" imageA 0))
        bad @?= Left DrillStoreMalformedRecord
    it "an unreadable or corrupt file is an error and never an empty ledger" $
      withSystemTempDirectory "drill-store" $ \directory -> do
        let path = directory </> "drills.ledger"
        writeFile path "not a ledger\n"
        corrupt <- readDrillLedger path
        assertBool "refused" (isLeft corrupt)
    it "the receipt command refuses a corrupt ledger file and never reports qualified" $
      withSystemTempDirectory "drill-receipt" $ \directory -> do
        let path = drillLedgerPath directory
        createDirectoryIfMissing True (takeDirectory path)
        writeFile path "not a ledger\n"
        report <- runAwsLifecycleReceipt directory
        awsReceiptQualified report @?= False
        assertBool "names the refusal" (any (Text.isPrefixOf "REFUSED=") (awsReceiptLines report))
    it "the receipt lines say not-qualified, the bound, the unmet criteria and the uncovered list" $ do
      let receipt = judgeReceipt emptyDrillLedger
          rendered = renderAwsReceiptLines receipt 0 Nothing "tree" False
      assertBool "not qualified" ("AWS_LIFECYCLE_QUALIFIED=false" `elem` rendered)
      assertBool "bound" ("FAILURE_RATE_BOUND_95_PERCENT=100" `elem` rendered)
      assertBool "uncovered" (("UNCOVERED=" <> uncoveredStatement) `elem` rendered)
      length [() | line <- rendered, Text.isPrefixOf "UNMET=" line]
        @?= length [minBound .. maxBound :: Criterion]
    it "a fully met ledger still refuses when the run is not on the current tree" $ do
      let receipt = judgeReceipt fullLedger
          off = renderAwsReceiptLines receipt 1 (Just "a") "other" False
          on = renderAwsReceiptLines receipt 1 (Just "a") "a" True
      assertBool "off tree refuses" ("AWS_LIFECYCLE_QUALIFIED=false" `elem` off)
      assertBool "on tree qualifies" ("AWS_LIFECYCLE_QUALIFIED=true" `elem` on)
    it "classifies a drill: hand action wins, then source drift or a nonzero exit fails, else clean" $ do
      classifyDrill False True ExitSuccess @?= DrillClean
      classifyDrill False True (ExitFailure 1) @?= DrillFailed
      classifyDrill False False ExitSuccess @?= DrillFailed
      classifyDrill True True ExitSuccess @?= DrillNeededHandAction
    it
      "the recorder brackets a drill with Begun and Closed, and records failure, hand action and interruption"
      $ withSystemTempDirectory "drill-recorder"
      $ \directory -> do
        let git arguments =
              callProcess
                "git"
                (["-C", directory, "-c", "user.name=t", "-c", "user.email=t@example.test"] ++ arguments)
            scopedFile = directory </> "src" </> "Prodbox" </> "Lifecycle" </> "AwsStackDestroy.hs"
        callProcess "git" ["init", "--quiet", directory]
        createDirectoryIfMissing True (takeDirectory scopedFile)
        writeFile scopedFile "module Prodbox.Lifecycle.AwsStackDestroy where\n"
        git ["add", "-A"]
        git ["commit", "--quiet", "-m", "fixture"]
        let attemptsOf = fmap (either (const []) resolveDrillAttempts) (readDrillLedger (drillLedgerPath directory))
            outcomesOf attempts = [closedOutcome c | DrillAttempt _ (Just c) <- attempts]
        first <- recordAwsLifecycleDrill directory [] DrillCanary (\_ -> pure ExitSuccess)
        first @?= Right ExitSuccess
        failed <- recordAwsLifecycleDrill directory [] DrillEksCycle (\_ -> pure (ExitFailure 3))
        failed @?= Right (ExitFailure 3)
        hand <-
          recordAwsLifecycleDrill directory [(handActionVariable, "1")] DrillEksCycle (\_ -> pure ExitSuccess)
        hand @?= Right ExitSuccess
        timed <-
          recordAwsLifecycleDrill directory [] DrillEksCycle $ \minutes ->
            noteDestroyElapsed minutes (pure ExitSuccess)
        timed @?= Right ExitSuccess
        attempts <- attemptsOf
        outcomesOf attempts @?= [DrillClean, DrillFailed, DrillNeededHandAction, DrillClean]
        map (begunId . attemptBegun) attempts @?= [1, 2, 3, 4]
        assertBool
          "a recorded destroy time"
          (any (maybe False ((== Just 1) . closedDestroyMinutes) . attemptClosed) attempts)
        -- A drill that dies leaves Begun with no Closed.
        interrupted <-
          try (recordAwsLifecycleDrill directory [] DrillCanary (\_ -> throwIO (ErrorCall "killed")))
        assertBool
          "exception propagates"
          (isLeft (interrupted :: Either ErrorCall (Either String ExitCode)))
        after <- attemptsOf
        length after @?= 5
        fmap attemptClosed (lastMaybe after) @?= Just Nothing
        -- The counted run ends at the interruption.
        currentRun after @?= []
        -- A corrupt ledger refuses before the drill runs.
        ran <- newIORef False
        writeFile (drillLedgerPath directory) "corrupt\n"
        refused <-
          recordAwsLifecycleDrill directory [] DrillCanary (\_ -> writeIORef ran True >> pure ExitSuccess)
        assertBool "refused" (isLeft refused)
        readIORef ran >>= (@?= False)
 where
  lastMaybe xs = if null xs then Nothing else Just (last xs)
