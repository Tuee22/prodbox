{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.110: a converged stack's receipt identifies what the stack
-- recorded, not nothing.
--
-- On a stack that was already converged the satisfied observation's evidence
-- was the digest of what @pulumi stack select@ printed. That command prints
-- nothing on success, so every converged stack's receipt was the SHA-256 of zero
-- bytes: @aws-eks@, @pulumi@ and @ha-rke2-aws@ passed in three sweeps while
-- printing it, because their validations asserted only the @sha256:@ prefix.
-- The cases run the Provider's observation over a scripted Pulumi child and keep
-- the old derivation as a negative control.
module ProviderStackReceipt (providerStackReceiptSuite) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProviderNarrowSession (ProviderEffectObservation (..))
import Prodbox.ControlPlane.ProviderProduction
  ( DesiredState (..)
  , observePulumiStackVia
  , stackEvidence
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (mkProviderStackRef)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

-- | The SHA-256 of zero bytes, the constant three sweeps printed.
emptyInputDigest :: Text
emptyInputDigest = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

ok :: String -> ProcessOutput
ok stdout = ProcessOutput ExitSuccess stdout ""

refused :: String -> ProcessOutput
refused stderr = ProcessOutput (ExitFailure 255) "" stderr

-- | A Pulumi child that answers each command from a table keyed by its first two
-- words, and records what it was asked.
scripted
  :: [([String], ProcessOutput)]
  -> IO ([String] -> IO ProcessOutput, IO [[String]])
scripted table = do
  calls <- newIORef []
  let run arguments = do
        modifyIORef' calls (<> [arguments])
        pure $ case [answer | (prefix, answer) <- table, take (length prefix) arguments == prefix] of
          answer : _ -> answer
          [] -> refused ("unscripted: " <> unwords arguments)
  pure (run, readIORef calls)

observe
  :: DesiredState
  -> [([String], ProcessOutput)]
  -> IO (Either String ProviderEffectObservation, [[String]])
observe desired table = do
  (run, readCalls) <- scripted table
  ref <- either (fail . show) pure (mkProviderStackRef "aws-eks")
  observed <- observePulumiStackVia run "file:///scratch" "aws-eks-test" [] desired ref
  calls <- readCalls
  pure (observed, calls)

-- | The commands of a converged stack: it selects, previews nothing, and has
-- recorded the given outputs.
converged :: ProcessOutput -> [([String], ProcessOutput)]
converged outputs =
  [ (["login"], ok "")
  , (["stack", "select"], ok "")
  , (["preview"], ok "no changes")
  , (["stack", "output"], outputs)
  ]

providerStackReceiptSuite :: SuiteBuilder ()
providerStackReceiptSuite =
  describe "Sprint 4.110 a converged stack's receipt carries content" $ do
    it "is the digest of the outputs the stack recorded, which differ from the digest of nothing" $ do
      (observed, calls) <- observe DesiredPresent (converged (ok "{\"vpc_id\":\"vpc-0a1\"}"))
      case observed of
        Right (ProviderEffectSatisfied evidence) -> do
          evidence `shouldNotBe` emptyInputDigest
          evidence `shouldSatisfy` Text.isPrefixOf "sha256:"
          Text.length evidence `shouldBe` 71
        other -> expectationFailure ("expected a satisfied observation, got " <> show other)
      -- It read the stack's recorded outputs, and read them after the preview.
      map (take 2) calls
        `shouldBe` [["login", "file:///scratch"], ["stack", "select"], ["preview", "--stack"], ["stack", "output"]]

    it "changes when the stack's recorded outputs change, and is stable when they do not" $ do
      let receiptFor outputs = do
            (observed, _) <- observe DesiredPresent (converged (ok outputs))
            pure (fmap satisfiedEvidence observed)
      first' <- receiptFor "{\"vpc_id\":\"vpc-0a1\"}"
      again <- receiptFor "{\"vpc_id\":\"vpc-0a1\"}"
      other <- receiptFor "{\"vpc_id\":\"vpc-0b2\"}"
      again `shouldBe` first'
      other `shouldNotBe` first'

    it "negative control: the evidence the old derivation produced was the digest of empty input" $ do
      -- `pulumi stack select` prints nothing on success; that is what was hashed.
      stackEvidence (ok "") `shouldSatisfy` isRefused
      stackEvidence (ok "  \n") `shouldSatisfy` isRefused
      stackEvidence (ok "{\"vpc_id\":\"vpc-0a1\"}") `shouldSatisfy` isAccepted
      -- And the constant is the one three sweeps printed.
      Text.take 15 emptyInputDigest `shouldBe` "sha256:e3b0c442"

    it "is unobservable, never satisfied, when the stack recorded no outputs" $
      mapM_
        ( \outputs -> do
            (observed, _) <- observe DesiredPresent (converged (ok outputs))
            observed `shouldSatisfy` isUnobservable
        )
        ["", "\n", "{}", "null"]

    it "is unobservable when the recorded outputs cannot be read" $ do
      (observed, _) <- observe DesiredPresent (converged (refused "error: could not read the checkpoint"))
      case observed of
        Right (ProviderEffectUnobservable detail) ->
          detail `shouldSatisfy` Text.isInfixOf "could not read the checkpoint"
        other -> expectationFailure ("expected an unobservable observation, got " <> show other)

    it "needs an apply, and reads no outputs, when the preview proposes changes" $ do
      (observed, calls) <-
        observe
          DesiredPresent
          [ (["login"], ok "")
          , (["stack", "select"], ok "")
          , (["preview"], refused "error: no changes were expected but changes were proposed")
          ]
      observed `shouldBe` Right (ProviderEffectNeedsApply "Pulumi preview reports changes")
      map (take 2) calls `shouldNotContain` [["stack", "output"]]

    it "reads an absent stack as absent for a destroy and as needing an apply for a create" $ do
      let absent =
            [ (["login"], ok "")
            , (["stack", "select"], refused "error: no stack named 'aws-eks-test' found")
            ]
      (create, _) <- observe DesiredPresent absent
      (destroy, _) <- observe DesiredAbsent absent
      create `shouldSatisfy` isNeedsApply
      destroy `shouldSatisfy` isSatisfied
 where
  satisfiedEvidence observation = case observation of
    ProviderEffectSatisfied evidence -> Just evidence
    _ -> Nothing
  isRefused result = either (const True) (const False) result
  isAccepted result = either (const False) (const True) result
  isUnobservable observed = case observed of
    Right (ProviderEffectUnobservable _) -> True
    _ -> False
  isNeedsApply observed = case observed of
    Right (ProviderEffectNeedsApply _) -> True
    _ -> False
  isSatisfied observed = case observed of
    Right (ProviderEffectSatisfied _) -> True
    _ -> False
