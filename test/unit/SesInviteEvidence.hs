{-# LANGUAGE OverloadedStrings #-}

module SesInviteEvidence (sesInviteEvidenceSuite, fixtureInvitePublicKey) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderIntentOperation (ProviderIntentRetired)
  , operationForProviderIntent
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Ses.InviteEvidence
import TestSupport

sesInviteEvidenceSuite :: SuiteBuilder ()
sesInviteEvidenceSuite = describe "Sprint 5.53 confidential invite SesInviteEvidence" $ do
  it "delivers the exact key and link only to the invocation holding the receiver secret" $ do
    receiver <- newInviteMailReceiver
    wire <- sealed receiver
    openInviteMailEvidence receiver bucket recipient wire `shouldBe` Right (Just (objectKey, link))
    wire `shouldSatisfy` (not . Text.isInfixOf link)
    wire `shouldSatisfy` (not . Text.isInfixOf objectKey)
  it "refuses another receiver, bucket, recipient and all ciphertext tampering" $ do
    receiver <- newInviteMailReceiver
    other <- newInviteMailReceiver
    wire <- sealed receiver
    openInviteMailEvidence other bucket recipient wire `shouldSatisfy` isLeft
    openInviteMailEvidence receiver "other-capture-mail" recipient wire `shouldSatisfy` isLeft
    openInviteMailEvidence receiver bucket "test-other@receive.example.test" wire `shouldSatisfy` isLeft
    mapM_
      (\value -> openInviteMailEvidence receiver bucket recipient value `shouldSatisfy` isLeft)
      (tampered wire)
  it "accepts only the closed pending marker and rejects plaintext and malformed evidence" $ do
    receiver <- newInviteMailReceiver
    openInviteMailEvidence receiver bucket recipient pendingInviteMailEvidence `shouldBe` Right Nothing
    mapM_
      ( \wire -> validateInviteMailEvidence (inviteMailReceiverPublicKey receiver) wire `shouldSatisfy` isLeft
      )
      [ "ses-invite:pending"
      , "ses-invite:inbound/key " <> link
      , "ses-invite-sealed:v1:not-base64!"
      , "ses-invite-sealed:v2:pending"
      , Text.replicate 5000 "a"
      ]
  it "derives its complete evidence bound inside the unchanged shared Provider cap" $
    maximumInviteMailEvidenceCharacters `shouldSatisfy` (<= maximumProviderIntentEvidenceCharacters)
  it "uses new ephemeral encryption randomness for every observation" $ do
    receiver <- newInviteMailReceiver
    firstWire <- sealed receiver
    secondWire <- sealed receiver
    firstWire `shouldNotBe` secondWire
    openInviteMailEvidence receiver bucket recipient secondWire
      `shouldBe` Right (Just (objectKey, link))
  it "round-trips canonical public keys and refuses invalid, zero and low-order points" $ do
    receiver <- newInviteMailReceiver
    let public = inviteMailReceiverPublicKey receiver
    mkInviteMailPublicKey (inviteMailPublicKeyText public) `shouldBe` Right public
    deserialiseOrFail (serialise public) `shouldBe` Right public
    mapM_
      (\key -> mkInviteMailPublicKey key `shouldSatisfy` isLeft)
      [ ""
      , Text.replicate 1000 "a"
      , Encoding.decodeUtf8 (Base64.encode (BS.replicate 32 0))
      , Encoding.decodeUtf8 (Base64.encode (BS.cons 1 (BS.replicate 31 0)))
      ]
  it "does not render the receiver private key" $ do
    receiver <- newInviteMailReceiver
    show receiver `shouldBe` "<invite-mail-receiver>"
  it "refuses oversized, malformed and wrong-prefix payloads before emitting evidence" $ do
    receiver <- newInviteMailReceiver
    mapM_
      ( \(key, url) ->
          sealInviteMailEvidence (inviteMailReceiverPublicKey receiver) bucket recipient key url
            >>= (`shouldSatisfy` isLeft)
      )
      [ ("elsewhere/key", link)
      , ("inbound/", link)
      , ("inbound/key\n", link)
      , ("inbound/" <> Text.replicate 1024 "x", link)
      , (objectKey, "http://auth.example.test/login-actions/action-token?key=k")
      , (objectKey, link <> Text.replicate maximumInviteMailPlaintextBytes "x")
      ]
  it "preserves the measured historical intent CBOR and returns only the retired marker" $ do
    let legacy = RetiredSesInviteMailObservation bucket recipient
        historical =
          either
            error
            id
            (Base64.decode "gxghdGZpeHR1cmUtY2FwdHVyZS1tYWlseCR0ZXN0LTE3NTk5MDAwMDBAcmVjZWl2ZS5leGFtcGxlLnRlc3Q=")
    serialise legacy `shouldBe` BL.fromStrict historical
    deserialiseOrFail (BL.fromStrict historical) `shouldBe` Right legacy
    validateProviderIntentEvidence legacy ("ses-invite:" <> objectKey <> " " <> link)
      `shouldSatisfy` isLeft
    validateProviderIntentEvidence legacy retiredInviteMailEvidence
      `shouldBe` Right retiredInviteMailEvidence
    case operationForProviderIntent (error "retired slot consulted executable capabilities") legacy of
      ProviderIntentRetired -> pure ()
      _ -> expectationFailure "retired slot selected an executable capability"
  it "admits only receiver-bound sealed evidence through the actual settlement validator" $ do
    receiver <- newInviteMailReceiver
    other <- newInviteMailReceiver
    wire <- sealed receiver
    let intent = ObserveSealedSesInviteMail bucket recipient (inviteMailReceiverPublicKey receiver)
    deserialiseOrFail (serialise intent) `shouldBe` Right intent
    validateProviderIntentEvidence intent wire `shouldBe` Right wire
    validateProviderIntentEvidence intent pendingInviteMailEvidence
      `shouldBe` Right pendingInviteMailEvidence
    validateProviderIntentEvidence intent ("ses-invite:" <> objectKey <> " " <> link)
      `shouldSatisfy` isLeft
    validateProviderIntentEvidence
      (ObserveSealedSesInviteMail bucket recipient (inviteMailReceiverPublicKey other))
      wire
      `shouldSatisfy` isLeft
 where
  sealed receiver = do
    result <-
      sealInviteMailEvidence (inviteMailReceiverPublicKey receiver) bucket recipient objectKey link
    either (error . Text.unpack) pure result

bucket, recipient, objectKey, link :: Text.Text
bucket = "fixture-capture-mail"
recipient = "test-1759900000@receive.example.test"
objectKey = "inbound/fixture-key"
link = "https://auth.example.test/realms/prodbox/login-actions/action-token?key=fixture-one-time-secret"

tampered :: Text.Text -> [Text.Text]
tampered wire =
  let prefix = "ses-invite-sealed:v1:"
      encoded = Encoding.encodeUtf8 (Text.drop (Text.length prefix) wire)
      bytes = either error id (Base64.decode encoded)
      replace index = BS.take index bytes <> BS.singleton (BS.index bytes index + 1) <> BS.drop (index + 1) bytes
   in [ prefix <> Encoding.decodeUtf8 (Base64.encode (replace index))
      | index <- [0, 4, 36, 70, BS.length bytes - 1]
      ]
        <> [prefix <> Encoding.decodeUtf8 (Base64.encode (bytes <> BL.toStrict (serialise (1 :: Int))))]

-- RFC 7748 Alice public key; no test or production receiver secret is retained.
fixtureInvitePublicKey :: InviteMailPublicKey
fixtureInvitePublicKey =
  either
    (error . Text.unpack)
    id
    (mkInviteMailPublicKey "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=")
