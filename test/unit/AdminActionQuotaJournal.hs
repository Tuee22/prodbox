{-# LANGUAGE OverloadedStrings #-}

module AdminActionQuotaJournal
  ( adminActionQuotaJournalSuite
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminQuotaItemReadBack (..)
  , AdminQuotaRequest (..)
  )
import Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaAttemptIntent (..)
  , QuotaExternalObservation (..)
  , QuotaHistoryObservation (..)
  , QuotaJournalOutcome (..)
  , advanceQuotaJournal
  , initialQuotaJournal
  , quotaJournalReadBack
  , quotaJournalStateCodec
  , recordQuotaProviderResponse
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import TestSupport

adminActionQuotaJournalSuite :: SuiteBuilder ()
adminActionQuotaJournalSuite =
  describe "Admin Action persist-before-effect quota journal" $ do
    it "completes from authoritative current quota without dispatching" $ do
      state <- accepted (initialQuotaJournal operationId [request])
      (_, outcome) <-
        accepted
          (advanceQuotaJournal now deadline [observation 11 []] state)
      case outcome of
        QuotaJournalCompleted [item] -> do
          adminQuotaProviderRequestIdentity item
            `shouldSatisfy` ("current-quota:" `Text.isPrefixOf`)
          adminQuotaStatus item `shouldBe` "CURRENT_SATISFIED"
        other -> expectationFailure ("expected current-quota completion, got " <> show other)

    it "persists one intent, requires two stable absence scans, and permits only one retry" $ do
      state0 <- accepted (initialQuotaJournal operationId [request])
      (state1, first) <- advance state0 1000000
      firstIntent <- expectDispatch 1 first

      (state2, firstAbsence) <- advance state1 2000000
      firstAbsence `shouldBe` QuotaJournalAwaitingHistory firstIntent 1

      (state3, retry) <- advance state2 3000000
      retryIntent <- expectDispatch 2 retry
      quotaAttemptIdentity retryIntent `shouldNotBe` quotaAttemptIdentity firstIntent

      (state4, retryAbsence) <- advance state3 4000000
      retryAbsence `shouldBe` QuotaJournalAwaitingHistory retryIntent 1

      (_, finalOutcome) <- advance state4 5000000
      finalOutcome
        `shouldBe` QuotaJournalRefused "stable-authoritative-absence-after-final-attempt"

    it "recovers an ambiguous response only from exact tuple and attempt-window history" $ do
      state0 <- accepted (initialQuotaJournal operationId [request])
      (state1, dispatched) <- advance state0 1000000
      intent <- expectDispatch 1 dispatched
      let wrongDesired =
            history
              { quotaHistoryDesiredValue = 12
              , quotaHistoryProviderRequestIdentity = "wrong-desired"
              }
          beforeWindow =
            history
              { quotaHistoryCreatedEpochSeconds = 0.5
              , quotaHistoryLastUpdatedEpochSeconds = 0.75
              , quotaHistoryProviderRequestIdentity = "before-window"
              }
          exact = history {quotaHistoryProviderRequestIdentity = "request-123"}
      (state2, completed) <-
        accepted
          ( advanceQuotaJournal
              (authorityTimeFromMicros 2000000)
              deadline
              [observation 5 [wrongDesired, beforeWindow, exact]]
              state1
          )
      case completed of
        QuotaJournalCompleted [item] -> do
          adminQuotaAttemptIdentity item `shouldBe` quotaAttemptIdentity intent
          adminQuotaProviderRequestIdentity item `shouldBe` "request-123"
          adminQuotaStatus item `shouldBe` "PENDING"
        other -> expectationFailure ("expected exact-history completion, got " <> show other)
      quotaJournalReadBack state2 `shouldSatisfy` isPresent

    it "records a confirmed provider response only against the persisted attempt" $ do
      state0 <- accepted (initialQuotaJournal operationId [request])
      (state1, dispatched) <- advance state0 1000000
      intent <- expectDispatch 1 dispatched
      recordQuotaProviderResponse "not-the-attempt" "provider-1" "PENDING" state1
        `shouldSatisfy` isLeft
      state2 <-
        accepted
          ( recordQuotaProviderResponse
              (quotaAttemptIdentity intent)
              "provider-1"
              "PENDING"
              state1
          )
      case quotaJournalReadBack state2 of
        Just [item] -> do
          adminQuotaAttemptIdentity item `shouldBe` quotaAttemptIdentity intent
          adminQuotaProviderRequestIdentity item `shouldBe` "provider-1"
        other -> expectationFailure ("expected provider read-back, got " <> show other)

    it "round-trips only canonical bounded durable state" $ do
      state <- accepted (initialQuotaJournal operationId [request])
      let codec = quotaJournalStateCodec 65536
      bytes <- accepted (encodeModelBValue codec state)
      decodeModelBValue codec bytes `shouldBe` Right state
      encodeModelBValue (quotaJournalStateCodec 1) state `shouldSatisfy` isLeft
 where
  advance state micros =
    accepted
      ( advanceQuotaJournal
          (authorityTimeFromMicros micros)
          deadline
          [observation 5 []]
          state
      )

request :: AdminQuotaRequest
request =
  AdminQuotaRequest
    { adminQuotaRequestAuthorityScope = "home"
    , adminQuotaRequestAuthorityEndpoint = "http://lifecycle-authority:8600"
    , adminQuotaRequestServiceCode = "vpc"
    , adminQuotaRequestCode = "L-F678F1CE"
    , adminQuotaRequestRegion = "ca-central-1"
    , adminQuotaRequestDesiredValue = "10"
    }

observation :: Double -> [QuotaHistoryObservation] -> QuotaExternalObservation
observation current historyItems =
  QuotaExternalObservation
    { quotaExternalRequest = request
    , quotaExternalCurrentValue = current
    , quotaExternalHistory = historyItems
    }

history :: QuotaHistoryObservation
history =
  QuotaHistoryObservation
    { quotaHistoryServiceCode = "vpc"
    , quotaHistoryQuotaCode = "L-F678F1CE"
    , quotaHistoryDesiredValue = 10
    , quotaHistoryProviderRequestIdentity = "request-default"
    , quotaHistoryStatus = "PENDING"
    , quotaHistoryCreatedEpochSeconds = 1.5
    , quotaHistoryLastUpdatedEpochSeconds = 1.75
    }

operationId :: Text
operationId = "admin-quota-operation-1"

now :: AuthorityTime
now = authorityTimeFromMicros 1000000

deadline :: AuthorityTime
deadline = authorityTimeFromMicros 10000000

expectDispatch :: Natural -> QuotaJournalOutcome -> IO QuotaAttemptIntent
expectDispatch attemptNumber outcome = case outcome of
  QuotaJournalDispatch intent
    | quotaAttemptNumber intent == attemptNumber -> pure intent
  other -> expectationFailure ("expected quota dispatch, got " <> show other) >> error "unreachable"

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> expectationFailure (show err) >> error "unreachable"
  Right value -> pure value

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

isPresent :: Maybe value -> Bool
isPresent value = case value of
  Just _ -> True
  Nothing -> False
