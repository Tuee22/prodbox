{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Durable receipt boundary for a confirmed Sprint 7.36 legacy adoption.
--
-- Planning and admin confirmation still perform no effect.  This repository
-- receives only an opaque confirmed-manifest write, commits its canonical
-- bytes at a stable identity, then performs an independent read-back.  Cleanup
-- evidence is minted only when that read-back is byte-exact; a commit response,
-- discovery result, or merely present object is never enough.
module Prodbox.ControlPlane.LegacyAdoptionManifestRepository
  ( LegacyAdoptionManifestIdentity
  , legacyAdoptionManifestIdentityStackKey
  , legacyAdoptionManifestIdentityScope
  , legacyAdoptionManifestIdentityPlanDigest
  , legacyAdoptionManifestLogicalName
  , LegacyAdoptionManifestCommitResult (..)
  , LegacyAdoptionManifestReadBack (..)
  , LegacyAdoptionManifestRepository (..)
  , LegacyAdoptionManifestRepositoryError (..)
  , legacyAdoptionManifestModelBCodec
  , modelBLegacyAdoptionManifestRepository
  , commitAndReadBackConfirmedLegacyAdoptionManifest
  , maximumLegacyAdoptionManifestReceiptBytes
  )
where

import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , modelBObjectVersionText
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( ConfirmedLegacyAdoptionPlan
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
  ( OwnershipManifestProvenance (..)
  , OwnershipManifestVersion (..)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( LegacyAdoptionPlanDigest
  , OwnershipManifestDecisionEvidence
  , OwnershipManifestError
  , completeConfirmedLegacyAdoptionManifestReadBack
  , confirmedLegacyAdoptionManifestWrite
  , confirmedLegacyAdoptionManifestWritePlanDigest
  , confirmedLegacyAdoptionManifestWriteReceiptBytes
  , confirmedLegacyAdoptionManifestWriteScope
  , confirmedLegacyAdoptionManifestWriteStackKey
  , legacyAdoptionPlanDigestText
  )

data LegacyAdoptionManifestIdentity = LegacyAdoptionManifestIdentity
  { internalLegacyAdoptionManifestIdentityStackKey :: !RegisteredResourceKey
  , internalLegacyAdoptionManifestIdentityScope :: !ObservationEvidenceScope
  , internalLegacyAdoptionManifestIdentityPlanDigest :: !LegacyAdoptionPlanDigest
  }
  deriving (Eq, Show)

legacyAdoptionManifestIdentityStackKey
  :: LegacyAdoptionManifestIdentity -> RegisteredResourceKey
legacyAdoptionManifestIdentityStackKey =
  internalLegacyAdoptionManifestIdentityStackKey

legacyAdoptionManifestIdentityScope
  :: LegacyAdoptionManifestIdentity -> ObservationEvidenceScope
legacyAdoptionManifestIdentityScope = internalLegacyAdoptionManifestIdentityScope

legacyAdoptionManifestIdentityPlanDigest
  :: LegacyAdoptionManifestIdentity -> LegacyAdoptionPlanDigest
legacyAdoptionManifestIdentityPlanDigest =
  internalLegacyAdoptionManifestIdentityPlanDigest

legacyAdoptionManifestLogicalName :: LegacyAdoptionManifestIdentity -> Text
legacyAdoptionManifestLogicalName identity =
  "authority/legacy-adoption-manifests/"
    <> registeredResourceKeyText
      (legacyAdoptionManifestIdentityStackKey identity)
    <> "/"
    <> runScopeText
      (evidenceDurableRunScope (legacyAdoptionManifestIdentityScope identity))
    <> "/"
    <> legacyAdoptionPlanDigestText
      (legacyAdoptionManifestIdentityPlanDigest identity)
 where
  runScopeText (DurableObservationRunScope value) = value

data LegacyAdoptionManifestCommitResult
  = LegacyAdoptionManifestCommitCreated
  | LegacyAdoptionManifestCommitExactReplay
  | LegacyAdoptionManifestCommitConflict
  | LegacyAdoptionManifestCommitResponseLost !ObservationFailure
  | LegacyAdoptionManifestCommitUnavailable !ObservationFailure
  deriving (Eq, Show)

data LegacyAdoptionManifestReadBack
  = LegacyAdoptionManifestReadBackPresent
      !OwnershipManifestProvenance
      !OwnershipManifestVersion
      !ByteString
  | LegacyAdoptionManifestReadBackMissing
  | LegacyAdoptionManifestReadBackCorrupt !Text
  | LegacyAdoptionManifestReadBackUnobservable !ObservationFailure
  | LegacyAdoptionManifestReadBackUnbounded !Int !Int
  deriving (Eq, Show)

data LegacyAdoptionManifestRepository m = LegacyAdoptionManifestRepository
  { commitLegacyAdoptionManifestReceipt
      :: LegacyAdoptionManifestIdentity
      -> ByteString
      -> m LegacyAdoptionManifestCommitResult
  , independentlyReadBackLegacyAdoptionManifestReceipt
      :: LegacyAdoptionManifestIdentity
      -> m LegacyAdoptionManifestReadBack
  }

data LegacyAdoptionManifestRepositoryError
  = LegacyAdoptionManifestPreparationInvalid !OwnershipManifestError
  | LegacyAdoptionManifestReceiptEmpty
  | LegacyAdoptionManifestReceiptTooLarge !Int !Int
  | LegacyAdoptionManifestReceiptMissing
  | LegacyAdoptionManifestReceiptCorrupt !Text
  | LegacyAdoptionManifestReceiptUnobservable !ObservationFailure
  | LegacyAdoptionManifestReceiptUnbounded !Int !Int
  | LegacyAdoptionManifestReceiptMismatch
  | LegacyAdoptionManifestCompletionInvalid !OwnershipManifestError
  deriving (Eq, Show)

maximumLegacyAdoptionManifestReceiptBytes :: Int
maximumLegacyAdoptionManifestReceiptBytes = 32 * 1024

legacyAdoptionManifestModelBCodec :: ModelBCodec ByteString
legacyAdoptionManifestModelBCodec =
  ModelBCodec
    { encodeModelBValue = validateCodecBytes
    , decodeModelBValue = validateCodecBytes
    }
 where
  validateCodecBytes bytes = do
    first show (validateReceiptBytes bytes)
    Right bytes

modelBLegacyAdoptionManifestRepository
  :: (Monad m)
  => LongLivedCheckpointAuthority
  -> ModelBCasAdapter 'ClusterRetained m ByteString
  -> LegacyAdoptionManifestRepository m
modelBLegacyAdoptionManifestRepository authority adapter =
  LegacyAdoptionManifestRepository
    { commitLegacyAdoptionManifestReceipt = commitReceipt
    , independentlyReadBackLegacyAdoptionManifestReceipt = readBackReceipt
    }
 where
  commitReceipt identity bytes = case coordinateFor identity of
    Left failure -> pure (LegacyAdoptionManifestCommitUnavailable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      case observed of
        ModelBMissing -> initialize coordinate bytes
        ModelBObserved _ existing -> pure (existingDisposition bytes existing)
        ModelBCorrupt detail -> pure (unavailable "corrupt" detail)
        ModelBEndpointUnready detail -> pure (unavailable "endpoint-unready" detail)
        ModelBUnobservable detail -> pure (unavailable "unobservable" detail)

  initialize coordinate bytes = do
    result <- modelBCompareAndSwap adapter (ModelBInitialize coordinate bytes)
    pure $ case result of
      ModelBCasApplied _ applied
        | applied == bytes -> LegacyAdoptionManifestCommitCreated
        | otherwise -> LegacyAdoptionManifestCommitConflict
      ModelBCasConflict observation -> conflictDisposition bytes observation
      ModelBCasRefusedCorrupt detail -> unavailable "cas-corrupt" detail
      ModelBCasEndpointUnready detail -> unavailable "cas-endpoint-unready" detail
      ModelBCasUnobservable detail ->
        LegacyAdoptionManifestCommitResponseLost
          (repositoryFailure "cas-response-unobservable" detail)

  readBackReceipt identity = case coordinateFor identity of
    Left failure -> pure (LegacyAdoptionManifestReadBackUnobservable failure)
    Right coordinate -> do
      observed <- modelBObserve adapter coordinate
      pure $ case observed of
        ModelBMissing -> LegacyAdoptionManifestReadBackMissing
        ModelBObserved version bytes
          | ByteString.length bytes > maximumLegacyAdoptionManifestReceiptBytes ->
              LegacyAdoptionManifestReadBackUnbounded
                maximumLegacyAdoptionManifestReceiptBytes
                (ByteString.length bytes)
          | otherwise ->
              LegacyAdoptionManifestReadBackPresent
                (OwnershipManifestProvenance authorityProvenance)
                (OwnershipManifestVersion (modelBObjectVersionText version))
                bytes
        ModelBCorrupt detail -> LegacyAdoptionManifestReadBackCorrupt detail
        ModelBEndpointUnready detail -> unobservable "endpoint-unready" detail
        ModelBUnobservable detail -> unobservable "unobservable" detail

  coordinateFor identity =
    first
      (repositoryFailure "coordinate" . Text.pack . show)
      ( mkClusterRetainedCoordinate
          authority
          (legacyAdoptionManifestLogicalName identity)
      )
  unavailable category detail =
    LegacyAdoptionManifestCommitUnavailable
      (repositoryFailure category detail)
  unobservable category detail =
    LegacyAdoptionManifestReadBackUnobservable
      (repositoryFailure category detail)

existingDisposition :: ByteString -> ByteString -> LegacyAdoptionManifestCommitResult
existingDisposition expected actual
  | expected == actual = LegacyAdoptionManifestCommitExactReplay
  | otherwise = LegacyAdoptionManifestCommitConflict

conflictDisposition
  :: ByteString
  -> ModelBObservation ByteString
  -> LegacyAdoptionManifestCommitResult
conflictDisposition expected observation = case observation of
  ModelBObserved _ actual -> existingDisposition expected actual
  ModelBMissing -> LegacyAdoptionManifestCommitConflict
  ModelBCorrupt detail -> unavailable "cas-conflict-corrupt" detail
  ModelBEndpointUnready detail -> unavailable "cas-conflict-endpoint-unready" detail
  ModelBUnobservable detail ->
    LegacyAdoptionManifestCommitResponseLost
      (repositoryFailure "cas-conflict-unobservable" detail)
 where
  unavailable category detail =
    LegacyAdoptionManifestCommitUnavailable
      (repositoryFailure category detail)

repositoryFailure :: Text -> Text -> ObservationFailure
repositoryFailure category detail =
  ObservationFailure
    ( Text.take
        1024
        ("legacy adoption manifest repository " <> category <> ": " <> detail)
    )

authorityProvenance :: Text
authorityProvenance = "lifecycle-authority/model-b/legacy-adoption/v1"

commitAndReadBackConfirmedLegacyAdoptionManifest
  :: (Monad m)
  => LegacyAdoptionManifestRepository m
  -> CleanupSurfaceWitness surface
  -> ConfirmedLegacyAdoptionPlan surface
  -> m
       ( Either
           LegacyAdoptionManifestRepositoryError
           OwnershipManifestDecisionEvidence
       )
commitAndReadBackConfirmedLegacyAdoptionManifest repository surface confirmed =
  case confirmedLegacyAdoptionManifestWrite surface confirmed of
    Left err -> pure (Left (LegacyAdoptionManifestPreparationInvalid err))
    Right write -> case validateReceiptBytes bytes of
      Left err -> pure (Left err)
      Right () -> do
        -- The disposition is deliberately not a completion witness.  Even an
        -- explicit conflict or unavailable response is followed by the same
        -- independent read-back: response loss may have committed the exact
        -- bytes, while a successful write may still be unreadable.
        _ <- commitLegacyAdoptionManifestReceipt repository identity bytes
        observed <-
          independentlyReadBackLegacyAdoptionManifestReceipt repository identity
        pure $ case observed of
          LegacyAdoptionManifestReadBackPresent provenance version actual -> do
            validateReceiptBytes actual
            unless
              (actual == bytes)
              (Left LegacyAdoptionManifestReceiptMismatch)
            either
              (Left . LegacyAdoptionManifestCompletionInvalid)
              Right
              ( completeConfirmedLegacyAdoptionManifestReadBack
                  provenance
                  version
                  write
              )
          LegacyAdoptionManifestReadBackMissing ->
            Left LegacyAdoptionManifestReceiptMissing
          LegacyAdoptionManifestReadBackCorrupt detail ->
            Left (LegacyAdoptionManifestReceiptCorrupt detail)
          LegacyAdoptionManifestReadBackUnobservable failure ->
            Left (LegacyAdoptionManifestReceiptUnobservable failure)
          LegacyAdoptionManifestReadBackUnbounded limit actual ->
            Left (LegacyAdoptionManifestReceiptUnbounded limit actual)
     where
      bytes = confirmedLegacyAdoptionManifestWriteReceiptBytes write
      identity =
        LegacyAdoptionManifestIdentity
          { internalLegacyAdoptionManifestIdentityStackKey =
              confirmedLegacyAdoptionManifestWriteStackKey write
          , internalLegacyAdoptionManifestIdentityScope =
              confirmedLegacyAdoptionManifestWriteScope write
          , internalLegacyAdoptionManifestIdentityPlanDigest =
              confirmedLegacyAdoptionManifestWritePlanDigest write
          }

validateReceiptBytes
  :: ByteString -> Either LegacyAdoptionManifestRepositoryError ()
validateReceiptBytes bytes = do
  when
    (ByteString.null bytes)
    (Left LegacyAdoptionManifestReceiptEmpty)
  when
    (ByteString.length bytes > maximumLegacyAdoptionManifestReceiptBytes)
    ( Left
        ( LegacyAdoptionManifestReceiptTooLarge
            maximumLegacyAdoptionManifestReceiptBytes
            (ByteString.length bytes)
        )
    )
