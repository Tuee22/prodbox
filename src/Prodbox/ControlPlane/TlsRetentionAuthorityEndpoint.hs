{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Lifecycle Authority endpoint for the public-edge TLS current
-- reference.  Requests name only a compiled substrate and canonical
-- certificate scope; object-store coordinates and CAS revisions stay behind
-- the repository resolver.
module Prodbox.ControlPlane.TlsRetentionAuthorityEndpoint
  ( TlsAuthorityObserveRequest (..)
  , TlsAuthorityPromoteRequest (..)
  , TlsAuthorityResponse (..)
  , TlsAuthorityRepositoryResolver
  , serveTlsAuthorityObserveRequest
  , serveTlsAuthorityPromoteRequest
  , tlsAuthorityResponseHttpStatus
  , tlsAuthorityResponseBody
  , tlsAuthorityResponseMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.TlsRetentionAuthority
  ( TlsRetentionAuthorityError (..)
  , TlsRetentionAuthorityRepository
  , TlsRetentionPromotionResult (..)
  , TlsRetentionSlot
  , mkTlsRetentionSlot
  , observeTlsRetentionAuthority
  , promoteTlsRetentionAuthority
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.TlsRetention
  ( KeyRotationApproval
  , PromotionEvidence
  , RetainedTlsRef
  , TlsPromotionDecision (..)
  , TlsPromotionRefusal (..)
  , TlsRetentionState
  )

data TlsAuthorityObserveRequest = TlsAuthorityObserveRequest
  { tlsAuthorityObserveSubstrate :: !Text
  , tlsAuthorityObserveScope :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityPromoteRequest = TlsAuthorityPromoteRequest
  { tlsAuthorityPromoteSubstrate :: !Text
  , tlsAuthorityPromoteScope :: !Text
  , tlsAuthorityPromoteApproval :: !KeyRotationApproval
  , tlsAuthorityPromoteEvidence :: !PromotionEvidence
  , tlsAuthorityPromoteCandidate :: !RetainedTlsRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TlsAuthorityResponse
  = TlsAuthorityObserved !TlsRetentionState
  | TlsAuthorityPromotionApplied !TlsRetentionState
  | TlsAuthorityPromotionNoop !TlsRetentionState
  | TlsAuthorityPromotionRefused !Text
  | TlsAuthorityConcurrentWrite
  | TlsAuthorityUnavailable
  | TlsAuthorityRequestRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

type TlsAuthorityRepositoryResolver m revision =
  TlsRetentionSlot -> Either Text (TlsRetentionAuthorityRepository m revision)

tlsAuthorityResponseMaximumBytes :: Int
tlsAuthorityResponseMaximumBytes = 128 * 1024

serveTlsAuthorityObserveRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityObserveRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityObserveSubstrate request)
        (tlsAuthorityObserveScope request)
        (fmap observeResponse . observeTlsRetentionAuthority)

serveTlsAuthorityPromoteRequest
  :: (Monad m)
  => Int
  -> TlsAuthorityRepositoryResolver m revision
  -> LazyByteString.ByteString
  -> m TlsAuthorityResponse
serveTlsAuthorityPromoteRequest maximumBytes resolve body =
  case decodeControlPlaneRequest maximumBytes body of
    Left _ -> pure TlsAuthorityRequestRefused
    Right request ->
      withRepository
        resolve
        (tlsAuthorityPromoteSubstrate request)
        (tlsAuthorityPromoteScope request)
        ( \repository ->
            promotionResponse
              <$> promoteTlsRetentionAuthority
                repository
                (tlsAuthorityPromoteApproval request)
                (tlsAuthorityPromoteEvidence request)
                (tlsAuthorityPromoteCandidate request)
        )

withRepository
  :: (Monad m)
  => TlsAuthorityRepositoryResolver m revision
  -> Text
  -> Text
  -> (TlsRetentionAuthorityRepository m revision -> m TlsAuthorityResponse)
  -> m TlsAuthorityResponse
withRepository resolve substrate scope action =
  case mkTlsRetentionSlot substrate scope of
    Left _ -> pure TlsAuthorityRequestRefused
    Right slot -> case resolve slot of
      Left _ -> pure TlsAuthorityUnavailable
      Right repository -> action repository

observeResponse
  :: Either TlsRetentionAuthorityError TlsRetentionState
  -> TlsAuthorityResponse
observeResponse result = case result of
  Left _ -> TlsAuthorityUnavailable
  Right state -> TlsAuthorityObserved state

promotionResponse
  :: Either TlsRetentionAuthorityError TlsRetentionPromotionResult
  -> TlsAuthorityResponse
promotionResponse result = case result of
  Left TlsRetentionAuthorityConcurrentWrite -> TlsAuthorityConcurrentWrite
  Left _ -> TlsAuthorityUnavailable
  Right promotion -> case tlsRetentionPromotionDecision promotion of
    TlsPromoted _ ->
      TlsAuthorityPromotionApplied (tlsRetentionPromotionState promotion)
    TlsPromotionNoop _ ->
      TlsAuthorityPromotionNoop (tlsRetentionPromotionState promotion)
    TlsPromotionRefused refusal ->
      TlsAuthorityPromotionRefused (refusalToken refusal)

refusalToken :: TlsPromotionRefusal -> Text
refusalToken refusal = case refusal of
  TlsSourceNotReobserved -> "source-not-reobserved"
  TlsAdapterReadBackMismatch -> "adapter-readback-mismatch"
  TlsStaleVersion -> "stale-version"
  TlsValidityRegression -> "validity-regression"
  TlsUnapprovedKeyChange -> "unapproved-key-change"

tlsAuthorityResponseHttpStatus :: TlsAuthorityResponse -> ReplyStatus
tlsAuthorityResponseHttpStatus response = case response of
  TlsAuthorityObserved _ -> ReplyOk
  TlsAuthorityPromotionApplied _ -> ReplyOk
  TlsAuthorityPromotionNoop _ -> ReplyOk
  TlsAuthorityPromotionRefused _ -> ReplyConflict
  TlsAuthorityConcurrentWrite -> ReplyConflict
  TlsAuthorityUnavailable -> ReplyServiceUnavailable
  TlsAuthorityRequestRefused -> ReplyBadRequest

tlsAuthorityResponseBody :: TlsAuthorityResponse -> ByteString
tlsAuthorityResponseBody = LazyByteString.toStrict . encodeControlPlaneResponse
