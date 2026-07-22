{-# LANGUAGE OverloadedStrings #-}

module BootstrapBrokerRequestJournal
  ( bootstrapBrokerRequestJournalSuite
  , main
  )
where

import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Request
  ( IdempotencyKey
  , RequestDigest
  , mkIdempotencyKey
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.RequestJournal
import Prodbox.Bootstrap.Broker.Routes (BrokerRoute (..))
import Prodbox.Bootstrap.Broker.StoreBoundary (StoreVersion (..))
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkVaultStorageGeneration
  )
import TestSupport

main :: IO ()
main = mainWithSuite "BootstrapBrokerRequestJournal" bootstrapBrokerRequestJournalSuite

bootstrapBrokerRequestJournalSuite :: SuiteBuilder ()
bootstrapBrokerRequestJournalSuite =
  describe "Sprint 2.33 durable Bootstrap Broker request journal" $ do
    it "preserves the immutable request binding through the terminal transition" $ do
      let completed =
            mustRight (recordTerminalBrokerResponse canonicalBinding canonicalResponse armedJournal)
      brokerRequestJournalBinding completed `shouldBe` canonicalBinding
      brokerRequestBindingIdempotencyKey (brokerRequestJournalBinding completed)
        `shouldBe` canonicalKey
      brokerRequestBindingRequestDigest (brokerRequestJournalBinding completed)
        `shouldBe` canonicalRequestDigest
      brokerRequestBindingRoute (brokerRequestJournalBinding completed)
        `shouldBe` BrokerVaultRotateTransitKey
      brokerRequestBindingActionDigest (brokerRequestJournalBinding completed)
        `shouldBe` digest 'b'
      brokerRequestBindingStorageGeneration (brokerRequestJournalBinding completed)
        `shouldBe` generation "root-generation-1"

    it "resumes only the exact armed request and retains its effect target" $ do
      resumeBrokerRequestJournal canonicalBinding armedJournal
        `shouldBe` Right (ResumeArmedBrokerRequest canonicalTarget)

    it "replays the exact bounded terminal status and encoded bytes" $ do
      let completed =
            mustRight (recordTerminalBrokerResponse canonicalBinding canonicalResponse armedJournal)
      resumeBrokerRequestJournal canonicalBinding completed
        `shouldBe` Right (ReplayTerminalBrokerResponse canonicalResponse)
      terminalBrokerResponseStatus canonicalResponse `shouldBe` BrokerTerminalAccepted
      terminalBrokerResponseRoute canonicalResponse `shouldBe` BrokerVaultRotateTransitKey
      terminalBrokerResponseBytes canonicalResponse `shouldBe` canonicalResponseBytes
      terminalBrokerResponseDigest canonicalResponse
        `shouldBe` requestDigestForBytes canonicalResponseBytes
      show canonicalResponse `shouldNotContain` canonicalResponseBytesAsString

    it "refuses every idempotency binding dimension independently" $ do
      let conflicts =
            [
              ( withKey alternateKey canonicalBinding
              , BrokerRequestIdempotencyKeyConflict
              )
            ,
              ( withRequestDigest alternateRequestDigest canonicalBinding
              , BrokerRequestDigestConflict
              )
            , (withRoute BrokerVaultPkiIssueTestCertificate canonicalBinding, BrokerRequestRouteConflict)
            , (withActionDigest (digest 'c') canonicalBinding, BrokerRequestActionDigestConflict)
            ,
              ( withStorageGeneration (generation "root-generation-2") canonicalBinding
              , BrokerRequestStorageGenerationConflict
              )
            ]
      mapM_
        ( \(binding, refusal) ->
            resumeBrokerRequestJournal binding armedJournal
              `shouldBe` Left refusal
        )
        conflicts

    it "refuses a terminal response for another route and every terminal rewrite" $ do
      let wrongRouteResponse =
            mustRight
              ( mkTerminalBrokerResponse
                  BrokerTerminalAccepted
                  BrokerVaultPkiIssueTestCertificate
                  canonicalResponseBytes
              )
      recordTerminalBrokerResponse canonicalBinding wrongRouteResponse armedJournal
        `shouldBe` Left BrokerRequestTerminalRouteMismatch
      let completed =
            mustRight (recordTerminalBrokerResponse canonicalBinding canonicalResponse armedJournal)
      recordTerminalBrokerResponse canonicalBinding canonicalResponse completed
        `shouldBe` Left BrokerRequestTerminalRewriteRefused
      recordTerminalBrokerResponse canonicalBinding alternateResponse completed
        `shouldBe` Left BrokerRequestTerminalRewriteRefused

    it "makes retryable and pre-prepare replies unrepresentable as durable statuses" $
      [minBound .. maxBound]
        `shouldBe` [BrokerTerminalOk, BrokerTerminalAccepted, BrokerTerminalConflict]

    it "executes only at the source and recovers only an exact target result" $ do
      decideBrokerEffectRecovery canonicalTarget BrokerEffectSourceStillCurrent
        `shouldBe` Right ExecuteArmedBrokerEffect
      decideBrokerEffectRecovery
        canonicalTarget
        (BrokerEffectTargetReached canonicalTransitResult)
        `shouldBe` Right (RecoverObservedBrokerEffect canonicalTransitResult)
      decideBrokerEffectRecovery
        canonicalTarget
        (BrokerEffectTargetReached (TransitKeyEffectResult (digest 'd') 8))
        `shouldBe` Left BrokerEffectObservedResultMismatch
      decideBrokerEffectRecovery
        canonicalTarget
        (BrokerEffectTargetReached (TransitKeyEffectResult (digest 'a') 9))
        `shouldBe` Left BrokerEffectObservedResultMismatch
      decideBrokerEffectRecovery canonicalTarget BrokerEffectTargetDiverged
        `shouldBe` Left BrokerEffectObservedTargetDiverged
      decideBrokerEffectRecovery canonicalTarget BrokerEffectTargetUnobservable
        `shouldBe` Left BrokerEffectObservationUnavailable

    it "checks exact unlock, durable-driver, and PKI result identities" $ do
      let unlockTarget =
            mustRight
              (mkUnlockBundleEffectTarget (StoreVersion 4) (digest '1') (StoreVersion 5) (digest '2'))
          unlockResult = UnlockBundleEffectResult (StoreVersion 5) (digest '2')
          driverTarget = durableDriverEffectTarget (digest '3')
          driverResult = DurableDriverEffectResult (digest '3')
          pkiTarget = mustRight (mkPkiIssueEffectTarget 6 (digest '4') (digest '5'))
          pkiResult =
            PkiIssueEffectResult
              6
              (digest '4')
              (digest '6')
              (digest '7')
              (digest '5')
      decideBrokerEffectRecovery unlockTarget (BrokerEffectTargetReached unlockResult)
        `shouldBe` Right (RecoverObservedBrokerEffect unlockResult)
      decideBrokerEffectRecovery driverTarget (BrokerEffectTargetReached driverResult)
        `shouldBe` Right (RecoverObservedBrokerEffect driverResult)
      decideBrokerEffectRecovery pkiTarget (BrokerEffectTargetReached pkiResult)
        `shouldBe` Right (RecoverObservedBrokerEffect pkiResult)
      decideBrokerEffectRecovery
        pkiTarget
        (BrokerEffectTargetReached (DurableDriverEffectResult (digest '4')))
        `shouldBe` Left BrokerEffectObservedResultMismatch

    it "requires positive single-step versions and a positive PKI issuer generation" $ do
      mkUnlockBundleEffectTarget (StoreVersion 0) (digest '1') (StoreVersion 1) (digest '2')
        `shouldBe` Left BrokerEffectSourceVersionMustBePositive
      mkUnlockBundleEffectTarget (StoreVersion 1) (digest '1') (StoreVersion 3) (digest '2')
        `shouldBe` Left BrokerEffectTargetVersionMustAdvanceExactlyOne
      mkTransitKeyEffectTarget (digest '3') 5 5
        `shouldBe` Left BrokerEffectTargetVersionMustAdvanceExactlyOne
      mkPkiIssueEffectTarget 0 (digest '4') (digest '5')
        `shouldBe` Left BrokerPkiIssuerGenerationMustBePositive

    it "accepts the exact response bound and rejects the first byte beyond it" $ do
      let atBound = ByteString.replicate (fromIntegral maximumTerminalBrokerResponseBytes) 120
          overBound = ByteString.snoc atBound 120
      mkTerminalBrokerResponse BrokerTerminalAccepted BrokerVaultRotateTransitKey atBound
        `shouldSatisfy` isRight
      mkTerminalBrokerResponse BrokerTerminalAccepted BrokerVaultRotateTransitKey overBound
        `shouldBe` Left
          ( TerminalBrokerResponseTooLarge
              maximumTerminalBrokerResponseBytes
              (maximumTerminalBrokerResponseBytes + 1)
          )

canonicalBinding :: BrokerRequestBinding
canonicalBinding =
  mkBrokerRequestBinding
    canonicalKey
    canonicalRequestDigest
    BrokerVaultRotateTransitKey
    (digest 'b')
    (generation "root-generation-1")

canonicalTarget :: BrokerEffectTarget
canonicalTarget = mustRight (mkTransitKeyEffectTarget (digest 'a') 7 8)

canonicalTransitResult :: BrokerEffectResult
canonicalTransitResult = TransitKeyEffectResult (digest 'a') 8

armedJournal :: BrokerRequestJournal
armedJournal = newArmedBrokerRequestJournal canonicalBinding canonicalTarget

canonicalResponse :: TerminalBrokerResponse
canonicalResponse =
  mustRight
    ( mkTerminalBrokerResponse
        BrokerTerminalAccepted
        BrokerVaultRotateTransitKey
        canonicalResponseBytes
    )

alternateResponse :: TerminalBrokerResponse
alternateResponse =
  mustRight
    ( mkTerminalBrokerResponse
        BrokerTerminalAccepted
        BrokerVaultRotateTransitKey
        "{\"operation\":\"vault_rotate_transit_key\",\"changed\":false}"
    )

canonicalResponseBytes :: ByteString.ByteString
canonicalResponseBytes =
  "{\"operation\":\"vault_rotate_transit_key\",\"changed\":true}"

canonicalResponseBytesAsString :: String
canonicalResponseBytesAsString =
  "{\"operation\":\"vault_rotate_transit_key\",\"changed\":true}"

canonicalKey :: IdempotencyKey
canonicalKey = mustRight (mkIdempotencyKey "durable-transit-rotation")

alternateKey :: IdempotencyKey
alternateKey = mustRight (mkIdempotencyKey "different-transit-rotation")

canonicalRequestDigest :: RequestDigest
canonicalRequestDigest = requestDigestForBytes "canonical-request"

alternateRequestDigest :: RequestDigest
alternateRequestDigest = requestDigestForBytes "different-request"

digest :: Char -> ArtifactDigest
digest character = mustRight (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

generation :: Text.Text -> VaultStorageGeneration
generation = mustRight . mkVaultStorageGeneration

withKey :: IdempotencyKey -> BrokerRequestBinding -> BrokerRequestBinding
withKey key binding =
  mkBrokerRequestBinding
    key
    (brokerRequestBindingRequestDigest binding)
    (brokerRequestBindingRoute binding)
    (brokerRequestBindingActionDigest binding)
    (brokerRequestBindingStorageGeneration binding)

withRequestDigest :: RequestDigest -> BrokerRequestBinding -> BrokerRequestBinding
withRequestDigest requestDigest binding =
  mkBrokerRequestBinding
    (brokerRequestBindingIdempotencyKey binding)
    requestDigest
    (brokerRequestBindingRoute binding)
    (brokerRequestBindingActionDigest binding)
    (brokerRequestBindingStorageGeneration binding)

withRoute :: BrokerRoute -> BrokerRequestBinding -> BrokerRequestBinding
withRoute route binding =
  mkBrokerRequestBinding
    (brokerRequestBindingIdempotencyKey binding)
    (brokerRequestBindingRequestDigest binding)
    route
    (brokerRequestBindingActionDigest binding)
    (brokerRequestBindingStorageGeneration binding)

withActionDigest :: ArtifactDigest -> BrokerRequestBinding -> BrokerRequestBinding
withActionDigest actionDigest binding =
  mkBrokerRequestBinding
    (brokerRequestBindingIdempotencyKey binding)
    (brokerRequestBindingRequestDigest binding)
    (brokerRequestBindingRoute binding)
    actionDigest
    (brokerRequestBindingStorageGeneration binding)

withStorageGeneration
  :: VaultStorageGeneration -> BrokerRequestBinding -> BrokerRequestBinding
withStorageGeneration storageGeneration binding =
  mkBrokerRequestBinding
    (brokerRequestBindingIdempotencyKey binding)
    (brokerRequestBindingRequestDigest binding)
    (brokerRequestBindingRoute binding)
    (brokerRequestBindingActionDigest binding)
    storageGeneration

isRight :: Either left right -> Bool
isRight value = case value of
  Right _ -> True
  Left _ -> False

mustRight :: (Show failure) => Either failure value -> value
mustRight outcome = case outcome of
  Right value -> value
  Left failure -> error ("invalid request-journal fixture: " ++ show failure)
