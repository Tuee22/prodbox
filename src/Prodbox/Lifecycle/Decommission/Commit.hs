{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: committing the decommission manifest to retained authority state
-- before the point of no return.
--
-- A total-teardown run freezes admission and then commits its signed manifest to a
-- @'ClusterRetained@ Model-B coordinate through this interpreter. The commit is an
-- initialize-if-absent compare-and-swap, so it establishes exactly one binding
-- decision:
--
--   * no manifest committed yet → this manifest becomes the committed plan
--     ('CommittedNew');
--   * the same manifest already committed → idempotent, so a resuming runner
--     proceeds against the plan it already recorded ('CommittedAlready');
--   * a /different/ manifest already committed → refuse
--     ('RefusedDifferentPlan'), because a run for another plan is in progress and
--     its committed plan must never be clobbered.
--
-- It is pure over an injected retained adapter, so an in-memory fixture exercises
-- every arm without a live object store. Freezing admission first is the runner's
-- sequencing obligation; this module owns only the commit decision.
module Prodbox.Lifecycle.Decommission.Commit
  ( DecommissionCommitRepository (..)
  , DecommissionCommitError (..)
  , DecommissionCommitOutcome (..)
  , decommissionManifestCodec
  , modelBDecommissionCommitRepository
  , commitDecommissionManifest
  )
where

import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCasAdapter (..)
  , ModelBCasRequest (ModelBInitialize)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( VerifiedDecommissionManifest
  , decodeSignedDecommissionManifest
  , encodeSignedDecommissionManifest
  , verifiedManifestDigest
  , verifiedSignedManifest
  , verifySignedDecommissionManifest
  )

-- | The retained store of the committed plan: read the current committed manifest
-- (if any) and initialize-if-absent a proposed one.
data DecommissionCommitRepository m revision = DecommissionCommitRepository
  { readCommittedManifest :: m (Either Text (Maybe (revision, VerifiedDecommissionManifest)))
  , initializeCommittedManifest :: VerifiedDecommissionManifest -> m (Either Text Bool)
  }

data DecommissionCommitError
  = CommitReadFailed !Text
  | CommitWriteFailed !Text
  | CommitConcurrentWrite
  deriving stock (Eq, Show)

data DecommissionCommitOutcome
  = CommittedNew
  | CommittedAlready
  | -- | A different plan is already committed: the committed and proposed digests.
    RefusedDifferentPlan !FrameDigest !FrameDigest
  deriving stock (Eq, Show)

-- | The Model-B payload codec for an authenticated complete manifest.  Decoding
-- re-verifies the signature against the externally pinned signer digest before a
-- retained value can enter the repository.
decommissionManifestCodec :: Int -> FrameDigest -> ModelBCodec VerifiedDecommissionManifest
decommissionManifestCodec maximumBytes expectedSigner =
  ModelBCodec
    { encodeModelBValue = encodeVerifiedManifest
    , decodeModelBValue = \bytes -> do
        signed <-
          either
            (Left . show)
            Right
            ( decodeSignedDecommissionManifest
                maximumBytes
                expectedSigner
                (LazyByteString.fromStrict bytes)
            )
        either (Left . show) Right (verifySignedDecommissionManifest expectedSigner signed)
    }
 where
  encodeVerifiedManifest verified =
    case verifySignedDecommissionManifest expectedSigner (verifiedSignedManifest verified) of
      Left err -> Left (show err)
      Right authenticated ->
        Right
          ( LazyByteString.toStrict
              (encodeSignedDecommissionManifest (verifiedSignedManifest authenticated))
          )

-- | Bind the commit repository to a retained Model-B coordinate. The type index
-- rejects a chart-lifetime or cross-cluster coordinate at this authority-primary
-- boundary.
modelBDecommissionCommitRepository
  :: (Monad m)
  => ModelBCasAdapter 'ClusterRetained m VerifiedDecommissionManifest
  -> ModelBObjectCoordinate 'ClusterRetained
  -> DecommissionCommitRepository m ModelBObjectVersion
modelBDecommissionCommitRepository adapter coordinate =
  DecommissionCommitRepository
    { readCommittedManifest = do
        observed <- modelBObserve adapter coordinate
        pure $ case observed of
          ModelBMissing -> Right Nothing
          ModelBObserved revision manifest -> Right (Just (revision, manifest))
          ModelBCorrupt detail -> Left ("committed decommission manifest is corrupt: " <> detail)
          ModelBEndpointUnready detail -> Left ("committed decommission manifest is unobservable: " <> detail)
          ModelBUnobservable detail -> Left ("committed decommission manifest is unobservable: " <> detail)
    , initializeCommittedManifest = \manifest -> do
        result <- modelBCompareAndSwap adapter (ModelBInitialize coordinate manifest)
        pure $ case result of
          ModelBCasApplied _ _ -> Right True
          ModelBCasConflict _ -> Right False
          ModelBCasRefusedCorrupt detail -> Left ("commit CAS refused corrupt: " <> detail)
          ModelBCasEndpointUnready detail -> Left ("commit CAS unobservable: " <> detail)
          ModelBCasUnobservable detail -> Left ("commit CAS unobservable: " <> detail)
    }

-- | Commit the manifest under a decision that never overwrites another plan.
commitDecommissionManifest
  :: (Monad m)
  => DecommissionCommitRepository m revision
  -> VerifiedDecommissionManifest
  -> m (Either DecommissionCommitError DecommissionCommitOutcome)
commitDecommissionManifest repository proposed = do
  current <- readCommittedManifest repository
  case current of
    Left detail -> pure (Left (CommitReadFailed detail))
    Right Nothing -> do
      written <- initializeCommittedManifest repository proposed
      pure $ case written of
        Left detail -> Left (CommitWriteFailed detail)
        Right False -> Left CommitConcurrentWrite
        Right True -> Right CommittedNew
    Right (Just (_, committed))
      | verifiedManifestDigest committed == verifiedManifestDigest proposed ->
          pure (Right CommittedAlready)
      | otherwise ->
          pure
            ( Right
                ( RefusedDifferentPlan
                    (verifiedManifestDigest committed)
                    (verifiedManifestDigest proposed)
                )
            )
