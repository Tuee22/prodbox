{-# LANGUAGE OverloadedStrings #-}

-- | The Lifecycle Authority's narrow, pre-Vault journal read.
--
-- A separate listener of the same Authority process serves one read-only
-- question, the admission verdict of the mounted journal, before and
-- independently of the Vault-dependent startup. The caller authenticates with a
-- projected ServiceAccount token whose audience is this capability's own and
-- whose identity is exactly the reader ServiceAccount of the Authority's own
-- namespace, verified by the Kubernetes TokenReview API. That is the local
-- kind/control identity: minting such a token needs the control kubeconfig, it
-- needs no Vault login or Transit signing, and a token for any other
-- ServiceAccount or audience is refused. The route grants no secret read and
-- no provider or cloud effect, and accepts only GET.
module Prodbox.ControlPlane.AuthorityJournalReadServer
  ( journalReadAudience
  , journalReadServiceAccount
  , decideJournalReadAccess
  , bearerTokenOf
  , verdictCode
  , renderVerdictAnswer
  , runAuthorityJournalReadServer
  ) where

import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forever, void)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.Bootstrap.Broker.TokenReview
  ( BrokerTokenReviewResult (..)
  , BrokerTokenReviewUser (..)
  , BrokerTokenReviewer (..)
  )
import Prodbox.ControlPlane.AdmissionJournalMirror (JournalInitialization (..))
import Prodbox.ControlPlane.Deadline (RemainingDuration (..), deadlineAtOffset)
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.ControlPlane.ListenPort (authorityJournalReadPortNumber)
import Prodbox.ControlPlane.Server (renderHttpResponse)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.AdmissionHistory
  ( AdmissionVerdict (..)
  , JournalObservation
  , classifyAdmission
  , renderVerdict
  )
import System.Timeout (timeout)

-- | The audience of this capability's tokens. It is not the Broker's.
journalReadAudience :: Text
journalReadAudience = "prodbox-authority-journal-read"

-- | The one ServiceAccount, in the Authority's own namespace, that may read.
journalReadServiceAccount :: Text
journalReadServiceAccount = "prodbox-authority-reader"

-- | Fail-closed projection of a TokenReview answer. An unauthenticated token is
-- 401; anything authenticated that is not exactly the reader ServiceAccount of
-- this namespace for this audience is 403.
decideJournalReadAccess :: Text -> BrokerTokenReviewResult -> Either ReplyStatus ()
decideJournalReadAccess namespace result
  | not (tokenReviewAuthenticated result) = Left ReplyUnauthorized
  | tokenReviewAudiences result /= [journalReadAudience] = Left ReplyForbidden
  | otherwise = case tokenReviewUser result of
      Nothing -> Left ReplyForbidden
      Just user
        | tokenReviewUsername user /= expectedUsername -> Left ReplyForbidden
        | Text.null (Text.strip (tokenReviewUid user)) -> Left ReplyForbidden
        | otherwise -> Right ()
 where
  expectedUsername = "system:serviceaccount:" <> namespace <> ":" <> journalReadServiceAccount

-- | The bearer token of an HTTP request head, if exactly one is present.
bearerTokenOf :: ByteString -> Maybe ByteString
bearerTokenOf requestHead =
  case [ ByteString.drop 7 (Char8.dropWhile (== ' ') (Char8.drop 14 line))
       | line <- Char8.lines (Char8.filter (/= '\r') requestHead)
       , map toLower (Char8.unpack (Char8.take 14 line)) == "authorization:"
       , map toLower (Char8.unpack (Char8.take 7 (Char8.dropWhile (== ' ') (Char8.drop 14 line))))
           == "bearer "
       ] of
    [token] | not (ByteString.null token) -> Just (Char8.takeWhile (/= ' ') token)
    _ -> Nothing

verdictCode :: AdmissionVerdict -> Text
verdictCode verdict = case verdict of
  NeverAdmitted -> "never-admitted"
  AdmittedSettled -> "admitted-settled"
  AdmittedPending _ -> "admitted-pending"
  RecoveryRequired _ -> "recovery-required"

renderVerdictAnswer :: Text -> Text -> AdmissionVerdict -> ByteString
renderVerdictAnswer clusterId observedAt verdict =
  renderJournalAnswer clusterId observedAt verdict JournalInitializationLegacy

renderJournalAnswer :: Text -> Text -> AdmissionVerdict -> JournalInitialization -> ByteString
renderJournalAnswer clusterId observedAt verdict initialization =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "cluster_id" .= clusterId
            , "verdict" .= verdictCode verdict
            , "observed_at" .= observedAt
            , "detail" .= Text.pack (renderVerdict verdict)
            , "initialization" .= record
            ]
        )
    )
    <> "\n"
 where
  record = case (verdict, initialization) of
    (AdmittedPending pending, JournalInitializationArmed identifier)
      | pending == [identifier] -> Just (operation "pending" identifier)
    (RecoveryRequired _, _) -> Nothing
    (_, JournalInitializationComplete identifier) -> Just (operation "complete" identifier)
    _ -> Nothing
  operation phase identifier = Aeson.object ["state" .= (phase :: Text), "operation_id" .= identifier]

-- | Serve until cancelled. Connections are handled one at a time, each bounded
-- in time, because this is a narrow read.
runAuthorityJournalReadServer
  :: Text
  -> Text
  -> BrokerTokenReviewer
  -> IO JournalObservation
  -> IO JournalInitialization
  -> IO ()
runAuthorityJournalReadServer clusterId namespace reviewer observe observeInitialization =
  withSocketsDo $
    bracket open close $ \listener ->
      forever $ do
        (client, _) <- accept listener
        serveOne client `finally` close client
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet authorityJournalReadPortNumber (tupleToHostAddress (0, 0, 0, 0)))
    listen listener 16
    pure listener

  serveOne client = do
    outcome <- timeout (8 * 1000 * 1000) (try (answer client)) :: IO (Maybe (Either SomeException ()))
    case outcome of
      Just (Right ()) -> pure ()
      _ -> sendAll client (renderHttpResponse ReplyServiceUnavailable "unavailable\n") `orIgnore` ()

  orIgnore action () = void (try action :: IO (Either SomeException ()))

  answer client = do
    requestHead <- readHead client
    case Char8.words (Char8.takeWhile (/= '\r') requestHead) of
      (method : path : _)
        | method /= "GET" -> sendAll client (renderHttpResponse ReplyBadRequest "get-only\n")
        | path /= "/v1/journal/admission" ->
            sendAll client (renderHttpResponse ReplyNotFound "route-not-owned\n")
        | otherwise -> case bearerTokenOf requestHead of
            Nothing -> sendAll client (renderHttpResponse ReplyUnauthorized "bearer-token-required\n")
            Just token -> do
              now <- realMonotonicNow
              let deadline = deadlineAtOffset now (RemainingDuration 5000000)
              reviewed <- reviewBrokerToken reviewer token deadline
              case reviewed of
                Left _ -> sendAll client (renderHttpResponse ReplyServiceUnavailable "token-review-unavailable\n")
                Right result -> case decideJournalReadAccess namespace result of
                  Left refusal -> sendAll client (renderHttpResponse refusal "refused\n")
                  Right () -> do
                    observation <- observe
                    initialization <- observeInitialization
                    observedAt <- Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" <$> getCurrentTime
                    sendAll
                      client
                      ( renderHttpResponse
                          ReplyOk
                          (renderJournalAnswer clusterId observedAt (classifyAdmission observation) initialization)
                      )
      _ -> sendAll client (renderHttpResponse ReplyBadRequest "bad-request\n")

  readHead client = go ByteString.empty
   where
    go acc
      | "\r\n\r\n" `ByteString.isInfixOf` acc || ByteString.length acc > 16384 = pure acc
      | otherwise = do
          chunk <- recv client 4096
          if ByteString.null chunk then pure acc else go (acc <> chunk)
