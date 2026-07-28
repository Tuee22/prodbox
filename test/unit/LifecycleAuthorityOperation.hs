{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module LifecycleAuthorityOperation
  ( lifecycleAuthorityOperationSuite
  )
where

import Data.Either (isLeft)
import Data.Text (Text)
import Prodbox.Lifecycle.Authority.Operation
import Prodbox.Lifecycle.Authority.OperationStore (operationRecordCodec)
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import TestSupport

lifecycleAuthorityOperationSuite :: SuiteBuilder ()
lifecycleAuthorityOperationSuite =
  describe "Sprint 4.48 Lifecycle Authority durable operation journal" $ do
    it "arms an operation with its committed intent before any effect" $ do
      let record = newArmedOperation key intent :: OperationRecord Text Text Text
      operationIntent record `shouldBe` Just intent
      operationResult record `shouldBe` Nothing

    it "resumes an armed record's committed intent under the exact binding" $ do
      let record = newArmedOperation key intent :: OperationRecord Text Text Text
      resumeOperation key record `shouldBe` Right (ResumeArmedOperation intent)

    it "refuses to resume under a mismatched binding" $ do
      let record = newArmedOperation key intent :: OperationRecord Text Text Text
      resumeOperation "other-key" record `shouldBe` Left OperationBindingConflict

    it "records a terminal result append-only and replays it on resume" $ do
      let armed = newArmedOperation key intent :: OperationRecord Text Text Text
      fmap operationResult (completeOperation key "action-done" armed)
        `shouldBe` Right (Just "action-done")
      (completeOperation key "action-done" armed >>= resumeOperation key)
        `shouldBe` Right (ReplayCompletedOperation "action-done")

    it "refuses to rewrite an already-terminal record (at-most-once)" $ do
      let armed = newArmedOperation key intent :: OperationRecord Text Text Text
      (completeOperation key "action-done" armed >>= completeOperation key "action-again")
        `shouldBe` Left OperationCompletedRewriteRefused

    it "recovery executes the armed intent only when the source is provably current" $
      decideOperationRecovery matches intent OperationSourceStillCurrent
        `shouldBe` Right (ExecuteArmedOperation intent)

    it "recovery recovers (never repeats) an applied effect whose result matches" $
      decideOperationRecovery matches intent (OperationTargetReached "action-done")
        `shouldBe` Right (RecoverObservedOperation "action-done")

    it "recovery fails closed on mismatched, diverged, or unobservable targets" $ do
      decideOperationRecovery matches intent (OperationTargetReached "other")
        `shouldBe` Left OperationRecoveryResultMismatch
      decideOperationRecovery matches intent OperationTargetDiverged
        `shouldBe` Left OperationRecoveryTargetDiverged
      decideOperationRecovery matches intent OperationTargetUnobservable
        `shouldBe` Left OperationRecoveryObservationUnavailable

    it "round-trips armed and completed records through bounded canonical CBOR" $ do
      let codec = operationRecordCodec 4096
          armed = newArmedOperation key intent :: OperationRecord Text Text Text
          completed = expectRight (completeOperation key "action-done" armed)
      mapM_
        ( \record -> do
            let bytes = expectRight (encodeModelBValue codec record)
            decodeModelBValue codec bytes `shouldBe` Right record
        )
        [armed, completed]

    it "refuses operation records at the configured byte boundary" $ do
      let codec = operationRecordCodec 1
          record = newArmedOperation key intent :: OperationRecord Text Text Text
      encodeModelBValue codec record `shouldSatisfy` isLeft
 where
  key = "op-1" :: Text
  intent = "action" :: Text
  matches :: Text -> Text -> Bool
  matches i r = r == i <> "-done"

expectRight :: (Show err) => Either err value -> value
expectRight value = case value of
  Left err -> error ("expected Right, got " ++ show err)
  Right result -> result
