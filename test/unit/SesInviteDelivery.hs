{-# LANGUAGE OverloadedStrings #-}

module SesInviteDelivery (sesInviteDeliverySuite) where

import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isLeft)
import Data.IORef
import Data.Text qualified as Text
import Prodbox.Ses.Capture
import Prodbox.Ses.InviteDelivery
import Prodbox.Ses.InviteEvidence
import Prodbox.Subprocess
import System.Exit
import TestSupport

sesInviteDeliverySuite :: SuiteBuilder ()
sesInviteDeliverySuite = describe "Sprint 5.53 confidential invite SesInviteDelivery" $ do
  it "reads a captured message through the supplied runner and seals the actual parsed link" $ do
    receiver <- newInviteMailReceiver
    calls <- newIORef []
    observed <-
      observeCapturedInviteEvidence
        (runner calls Arrived)
        (inviteMailReceiverPublicKey receiver)
        bucket
        recipient
    case observed of
      Left err -> expectationFailure (Text.unpack err)
      Right evidence -> do
        openInviteMailEvidence receiver bucket recipient evidence
          `shouldBe` Right (Just ("inbound/fixture-key", link))
        evidence `shouldSatisfy` (not . Text.isInfixOf link)
    (length <$> readIORef calls) `shouldReturn` 2
  it "reports pending only after the complete empty listing" $ do
    receiver <- newInviteMailReceiver
    calls <- newIORef []
    observeCapturedInviteEvidence
      (runner calls Empty)
      (inviteMailReceiverPublicKey receiver)
      bucket
      recipient
      `shouldReturn` Right pendingInviteMailEvidence
    (length <$> readIORef calls) `shouldReturn` 1
  it "does not turn an unreadable capture or unusable message into pending or echo token bytes" $ do
    receiver <- newInviteMailReceiver
    calls <- newIORef []
    observeCapturedInviteEvidence
      (runner calls Unreadable)
      (inviteMailReceiverPublicKey receiver)
      bucket
      recipient
      `shouldReturn` Left "SES invite capture could not be observed"
    observed <-
      observeCapturedInviteEvidence
        (runner calls NoLink)
        (inviteMailReceiverPublicKey receiver)
        bucket
        recipient
    observed `shouldSatisfy` isLeft
    show observed `shouldNotContain` Text.unpack link

data Shape = Arrived | Empty | Unreadable | NoLink deriving (Eq)
runner :: IORef [[String]] -> Shape -> CaptureRunner
runner calls shape = CaptureRunner run (pure 1759900000)
 where
  run arguments = do
    modifyIORef' calls (arguments :)
    case take 2 arguments of
      ["s3api", "list-objects-v2"]
        | shape == Unreadable -> pure (ProcessOutput (ExitFailure 1) "" (Text.unpack link))
        | shape == Empty -> pure (ProcessOutput ExitSuccess "{}" "")
        | otherwise ->
            pure (ProcessOutput ExitSuccess "{\"Contents\":[{\"Key\":\"inbound/fixture-key\"}]}" "")
      ["s3api", "get-object"] -> do
        let body = if shape == NoLink then "unusable message" else Text.unpack link
        BL8.writeFile (last arguments) (BL8.pack ("To: " <> Text.unpack recipient <> "\r\n\r\n" <> body))
        pure (ProcessOutput ExitSuccess "{}" "")
      _ -> pure (ProcessOutput (ExitFailure 1) "" "unexpected fixture call")
bucket, recipient, link :: Text.Text
bucket = "fixture-capture-mail"
recipient = "test-1759900000@receive.example.test"
link = "https://auth.example.test/realms/prodbox/login-actions/action-token?key=fixture-one-time-secret"
