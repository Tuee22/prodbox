{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Retained point-of-no-return transition for total decommission.
--
-- The wire request carries the already signed manifest plus the exact receipt
-- header/path acknowledged by the runner.  The Authority independently
-- authenticates all three bindings, re-observes its committed manifest, and
-- only then moves the admission aggregate from frozen to permanently stopped.
-- The retained fold makes an exact response-loss replay idempotent and refuses
-- any divergent manifest/receipt pair.
module Prodbox.Lifecycle.Decommission.AuthorityStop
  ( AuthorityDecommissionStopRepository (..)
  , AuthorityDecommissionStopRequest (..)
  , AuthorityDecommissionStopError (..)
  , AuthorityDecommissionStopResult (..)
  , AuthorityDecommissionStopResponse (..)
  , runAuthorityDecommissionStop
  , serveAuthorityDecommissionStopRequest
  , authorityDecommissionStopHttpStatus
  , authorityDecommissionStopSummary
  , authorityDecommissionStopResponseBody
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityDecommissionDecision (..)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( SignedDecommissionManifest
  , VerifiedDecommissionManifest
  , verifiedManifestDigest
  , verifySignedDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( ReceiptHeader
  , mkReceiptHeader
  , receiptAcknowledgementDigest
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( mkExternalReceiptPath
  )

data AuthorityDecommissionStopRepository m = AuthorityDecommissionStopRepository
  { readCommittedDecommissionManifest
      :: m (Either Text (Maybe VerifiedDecommissionManifest))
  , commitAuthorityPermanentStop
      :: FrameDigest
      -> FrameDigest
      -> m (Either Text AuthorityDecommissionDecision)
  }

data AuthorityDecommissionStopRequest = AuthorityDecommissionStopRequest
  { authorityStopManifest :: !SignedDecommissionManifest
  , authorityStopReceiptHeader :: !ReceiptHeader
  , authorityStopReceiptPath :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityDecommissionStopError
  = AuthorityStopBadRequest !ControlPlaneRequestCodecError
  | AuthorityStopManifestInvalid !Text
  | AuthorityStopReceiptPathInvalid !Text
  | AuthorityStopReceiptHeaderMismatch
  | AuthorityStopCommittedManifestUnavailable !Text
  | AuthorityStopCommittedManifestMissing
  | AuthorityStopCommittedManifestMismatch !FrameDigest !FrameDigest
  | AuthorityStopCommitUnavailable !Text
  | AuthorityStopNotFrozen
  | AuthorityStopAlreadyStoppedWithDifferentBinding
  | AuthorityStopFreezeAfterPermanentStop
  deriving stock (Eq, Show)

data AuthorityDecommissionStopResult
  = AuthorityDecommissionStopped
  | AuthorityDecommissionStopAlreadyCommitted
  | AuthorityDecommissionStopRefused !AuthorityDecommissionStopError
  deriving stock (Eq, Show)

data AuthorityDecommissionStopResponse
  = AuthorityDecommissionStopResponseStopped
  | AuthorityDecommissionStopResponseAlreadyStopped
  | AuthorityDecommissionStopResponseRefused !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

runAuthorityDecommissionStop
  :: (Monad m)
  => FrameDigest
  -> AuthorityDecommissionStopRepository m
  -> AuthorityDecommissionStopRequest
  -> m AuthorityDecommissionStopResult
runAuthorityDecommissionStop expectedSigner repository request =
  case verifySignedDecommissionManifest expectedSigner (authorityStopManifest request) of
    Left detail -> refuse (AuthorityStopManifestInvalid (Text.pack (show detail)))
    Right verified ->
      case mkExternalReceiptPath (authorityStopReceiptPath request) of
        Left detail ->
          refuse (AuthorityStopReceiptPathInvalid (Text.pack (show detail)))
        Right receiptPath
          | authorityStopReceiptHeader request /= mkReceiptHeader verified ->
              refuse AuthorityStopReceiptHeaderMismatch
          | otherwise -> do
              committedResult <- readCommittedDecommissionManifest repository
              case committedResult of
                Left detail ->
                  refuse (AuthorityStopCommittedManifestUnavailable detail)
                Right Nothing -> refuse AuthorityStopCommittedManifestMissing
                Right (Just committed)
                  | verifiedManifestDigest committed /= verifiedManifestDigest verified ->
                      refuse
                        ( AuthorityStopCommittedManifestMismatch
                            (verifiedManifestDigest committed)
                            (verifiedManifestDigest verified)
                        )
                  | otherwise -> do
                      committedStop <-
                        commitAuthorityPermanentStop
                          repository
                          (verifiedManifestDigest verified)
                          ( receiptAcknowledgementDigest
                              (authorityStopReceiptHeader request)
                              receiptPath
                          )
                      pure $ case committedStop of
                        Left detail ->
                          AuthorityDecommissionStopRefused
                            (AuthorityStopCommitUnavailable detail)
                        Right AuthorityDecommissionStopApplied ->
                          AuthorityDecommissionStopped
                        Right AuthorityDecommissionStopAlreadyApplied ->
                          AuthorityDecommissionStopAlreadyCommitted
                        Right AuthorityDecommissionStopRefusedBeforeFreeze ->
                          AuthorityDecommissionStopRefused AuthorityStopNotFrozen
                        Right AuthorityDecommissionStopRefusedBindingConflict {} ->
                          AuthorityDecommissionStopRefused
                            AuthorityStopAlreadyStoppedWithDifferentBinding
                        Right AuthorityDecommissionFreezeRefusedAlreadyStopped ->
                          AuthorityDecommissionStopRefused
                            AuthorityStopFreezeAfterPermanentStop
                        Right AuthorityDecommissionFreezeApplied ->
                          impossibleFreezeDecision
                        Right AuthorityDecommissionFreezeAlreadyApplied ->
                          impossibleFreezeDecision
 where
  refuse = pure . AuthorityDecommissionStopRefused
  impossibleFreezeDecision =
    AuthorityDecommissionStopRefused
      (AuthorityStopCommitUnavailable "permanent-stop repository returned a freeze decision")

serveAuthorityDecommissionStopRequest
  :: (Monad m)
  => Int
  -> FrameDigest
  -> AuthorityDecommissionStopRepository m
  -> LazyByteString.ByteString
  -> m AuthorityDecommissionStopResult
serveAuthorityDecommissionStopRequest maximumBytes expectedSigner repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left detail ->
      pure (AuthorityDecommissionStopRefused (AuthorityStopBadRequest detail))
    Right request -> runAuthorityDecommissionStop expectedSigner repository request

authorityDecommissionStopHttpStatus :: AuthorityDecommissionStopResult -> ReplyStatus
authorityDecommissionStopHttpStatus result = case result of
  AuthorityDecommissionStopped -> ReplyOk
  AuthorityDecommissionStopAlreadyCommitted -> ReplyOk
  AuthorityDecommissionStopRefused detail -> case detail of
    AuthorityStopBadRequest _ -> ReplyBadRequest
    AuthorityStopManifestInvalid _ -> ReplyForbidden
    AuthorityStopReceiptPathInvalid _ -> ReplyBadRequest
    AuthorityStopReceiptHeaderMismatch -> ReplyConflict
    AuthorityStopCommittedManifestUnavailable _ -> ReplyServiceUnavailable
    AuthorityStopCommittedManifestMissing -> ReplyConflict
    AuthorityStopCommittedManifestMismatch _ _ -> ReplyConflict
    AuthorityStopCommitUnavailable _ -> ReplyServiceUnavailable
    AuthorityStopNotFrozen -> ReplyConflict
    AuthorityStopAlreadyStoppedWithDifferentBinding -> ReplyConflict
    AuthorityStopFreezeAfterPermanentStop -> ReplyConflict

authorityDecommissionStopSummary :: AuthorityDecommissionStopResult -> Text
authorityDecommissionStopSummary result = case result of
  AuthorityDecommissionStopped -> "decommission-stopped"
  AuthorityDecommissionStopAlreadyCommitted -> "decommission-already-stopped"
  AuthorityDecommissionStopRefused detail -> case detail of
    AuthorityStopBadRequest codec ->
      "decommission-stop-bad-request-" <> controlPlaneRequestCodecToken codec
    AuthorityStopManifestInvalid _ -> "decommission-stop-manifest-invalid"
    AuthorityStopReceiptPathInvalid _ -> "decommission-stop-receipt-path-invalid"
    AuthorityStopReceiptHeaderMismatch -> "decommission-stop-receipt-mismatch"
    AuthorityStopCommittedManifestUnavailable _ -> "decommission-stop-manifest-unavailable"
    AuthorityStopCommittedManifestMissing -> "decommission-stop-manifest-missing"
    AuthorityStopCommittedManifestMismatch _ _ -> "decommission-stop-manifest-conflict"
    AuthorityStopCommitUnavailable _ -> "decommission-stop-commit-unavailable"
    AuthorityStopNotFrozen -> "decommission-stop-not-frozen"
    AuthorityStopAlreadyStoppedWithDifferentBinding -> "decommission-stop-binding-conflict"
    AuthorityStopFreezeAfterPermanentStop -> "decommission-stop-already-permanent"

authorityDecommissionStopResponseBody
  :: AuthorityDecommissionStopResult
  -> ByteString
authorityDecommissionStopResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        AuthorityDecommissionStopped -> AuthorityDecommissionStopResponseStopped
        AuthorityDecommissionStopAlreadyCommitted ->
          AuthorityDecommissionStopResponseAlreadyStopped
        AuthorityDecommissionStopRefused _ ->
          AuthorityDecommissionStopResponseRefused
            (authorityDecommissionStopSummary result)
    )
