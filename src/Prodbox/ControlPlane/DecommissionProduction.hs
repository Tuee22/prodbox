{-# LANGUAGE OverloadedStrings #-}

-- | Response-loss-safe retained repository composition for Authority
-- decommission export and permanent stop.
--
-- The manifest inventory remains an injected, typed discovery effect.  This
-- module owns the transactional parts: admission freeze is committed in the
-- same aggregate used by submissions, the signed manifest is initialized once
-- at its distinct retained coordinate, and permanent stop is CAS/read-back
-- bound to that exact manifest and external receipt.
module Prodbox.ControlPlane.DecommissionProduction
  ( authorityDecommissionRepositories
  , readCommittedPlanOrDiscover
  , freezeAuthorityAdmissionWithReadBack
  , permanentlyStopAuthorityWithReadBack
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityDecommissionDecision (..)
  , AuthorityDecommissionState (..)
  , authorityAggregateDecommission
  , freezeAuthorityForDecommission
  , permanentlyStopAuthorityForDecommission
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityDecommissionExportRepository (..)
  )
import Prodbox.Lifecycle.Decommission.AuthorityStop
  ( AuthorityDecommissionStopRepository (..)
  )
import Prodbox.Lifecycle.Decommission.Commit
  ( DecommissionCommitError (..)
  , DecommissionCommitOutcome (..)
  , DecommissionCommitRepository (..)
  , commitDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionManifest
  , VerifiedDecommissionManifest
  , verifiedManifestPlan
  )

authorityDecommissionRepositories
  :: Natural
  -> AuthorityAdmissionRepository IO revision
  -> DecommissionCommitRepository IO commitRevision
  -> IO (Either Text DecommissionManifest)
  -> ( AuthorityDecommissionExportRepository IO
     , AuthorityDecommissionStopRepository IO
     )
authorityDecommissionRepositories maximumAttempts admission committedManifest discoverPlan =
  ( AuthorityDecommissionExportRepository
      { freezeAuthorityAdmission =
          freezeAuthorityAdmissionWithReadBack maximumAttempts admission
      , readAuthorityDecommissionPlan =
          readCommittedPlanOrDiscover committedManifest discoverPlan
      , commitAuthorityDecommissionManifest =
          commitManifestWithReadBack maximumAttempts committedManifest
      }
  , AuthorityDecommissionStopRepository
      { readCommittedDecommissionManifest = do
          observed <- readCommittedManifest committedManifest
          pure (fmap (fmap snd) observed)
      , commitAuthorityPermanentStop =
          permanentlyStopAuthorityWithReadBack maximumAttempts admission
      }
  )

-- | A resumed pinned runner is bound to the already-committed plan.  It must
-- not rediscover inventory after an earlier attempt has tombstoned a target
-- generation, because doing so would synthesize a different plan and strand
-- the authenticated receipt.  Discovery is used only before the first commit.
readCommittedPlanOrDiscover
  :: DecommissionCommitRepository IO revision
  -> IO (Either Text DecommissionManifest)
  -> IO (Either Text DecommissionManifest)
readCommittedPlanOrDiscover repository discover = do
  observed <- readCommittedManifest repository
  case observed of
    Left detail -> pure (Left detail)
    Right (Just (_, committed)) -> pure (Right (verifiedManifestPlan committed))
    Right Nothing -> discover

freezeAuthorityAdmissionWithReadBack
  :: Natural
  -> AuthorityAdmissionRepository IO revision
  -> IO (Either Text ())
freezeAuthorityAdmissionWithReadBack maximumAttempts repository =
  go maximumAttempts Nothing
 where
  go remaining lastFailure
    | remaining == 0 =
        pure
          ( Left
              ( "Authority decommission freeze CAS attempts exhausted"
                  <> maybe "" (": " <>) lastFailure
              )
          )
    | otherwise = do
        observed <- readAuthorityAdmission repository
        case observed of
          Left detail -> go (remaining - 1) (Just detail)
          Right snapshot ->
            case freezeAuthorityForDecommission (authorityAdmissionSnapshotState snapshot) of
              (AuthorityDecommissionFreezeAlreadyApplied, _) -> pure (Right ())
              (AuthorityDecommissionFreezeRefusedAlreadyStopped, _) ->
                pure (Left "Authority is already permanently stopped")
              (AuthorityDecommissionFreezeApplied, next) -> do
                attempted <-
                  compareAndSwapAuthorityAdmission
                    repository
                    (authorityAdmissionRevision snapshot)
                    next
                confirmed <- observeFrozen repository
                case confirmed of
                  Right True -> pure (Right ())
                  Right False ->
                    go (remaining - 1) (either Just (const Nothing) attempted)
                  Left detail ->
                    go
                      (remaining - 1)
                      (Just (either (<> "; " <> detail) (const detail) attempted))
              _ -> pure (Left "Authority freeze fold returned a stop decision")

permanentlyStopAuthorityWithReadBack
  :: Natural
  -> AuthorityAdmissionRepository IO revision
  -> FrameDigest
  -> FrameDigest
  -> IO (Either Text AuthorityDecommissionDecision)
permanentlyStopAuthorityWithReadBack maximumAttempts repository manifestDigest receiptDigest =
  go maximumAttempts Nothing
 where
  go remaining lastFailure
    | remaining == 0 =
        pure
          ( Left
              ( "Authority permanent-stop CAS attempts exhausted"
                  <> maybe "" (": " <>) lastFailure
              )
          )
    | otherwise = do
        observed <- readAuthorityAdmission repository
        case observed of
          Left detail -> go (remaining - 1) (Just detail)
          Right snapshot ->
            let (decision, next) =
                  permanentlyStopAuthorityForDecommission
                    manifestDigest
                    receiptDigest
                    (authorityAdmissionSnapshotState snapshot)
             in case decision of
                  AuthorityDecommissionStopApplied -> do
                    attempted <-
                      compareAndSwapAuthorityAdmission
                        repository
                        (authorityAdmissionRevision snapshot)
                        next
                    confirmed <- observeStopped repository manifestDigest receiptDigest
                    case confirmed of
                      Right True -> pure (Right AuthorityDecommissionStopApplied)
                      Right False ->
                        go (remaining - 1) (either Just (const Nothing) attempted)
                      Left detail ->
                        go
                          (remaining - 1)
                          (Just (either (<> "; " <> detail) (const detail) attempted))
                  AuthorityDecommissionStopAlreadyApplied -> pure (Right decision)
                  AuthorityDecommissionStopRefusedBeforeFreeze -> pure (Right decision)
                  AuthorityDecommissionStopRefusedBindingConflict {} -> pure (Right decision)
                  _ -> pure (Left "Authority permanent-stop fold returned a freeze decision")

observeFrozen
  :: AuthorityAdmissionRepository IO revision
  -> IO (Either Text Bool)
observeFrozen repository = do
  observed <- readAuthorityAdmission repository
  pure $ do
    snapshot <- observed
    Right $ case authorityAggregateDecommission (authorityAdmissionSnapshotState snapshot) of
      AuthorityDecommissionFrozen -> True
      AuthorityPermanentlyStopped _ _ -> True
      AuthorityServing -> False

observeStopped
  :: AuthorityAdmissionRepository IO revision
  -> FrameDigest
  -> FrameDigest
  -> IO (Either Text Bool)
observeStopped repository manifestDigest receiptDigest = do
  observed <- readAuthorityAdmission repository
  pure $ do
    snapshot <- observed
    Right
      ( authorityAggregateDecommission (authorityAdmissionSnapshotState snapshot)
          == AuthorityPermanentlyStopped manifestDigest receiptDigest
      )

commitManifestWithReadBack
  :: Natural
  -> DecommissionCommitRepository IO revision
  -> VerifiedDecommissionManifest
  -> IO (Either Text ())
commitManifestWithReadBack maximumAttempts repository proposed =
  go maximumAttempts Nothing
 where
  go remaining lastFailure
    | remaining == 0 =
        pure
          ( Left
              ( "decommission manifest commit attempts exhausted"
                  <> maybe "" (": " <>) lastFailure
              )
          )
    | otherwise = do
        outcome <- commitDecommissionManifest repository proposed
        case outcome of
          Right CommittedNew -> pure (Right ())
          Right CommittedAlready -> pure (Right ())
          Right (RefusedDifferentPlan committed proposedDigest) ->
            pure
              ( Left
                  ( "a different decommission manifest is already committed: committed="
                      <> Text.pack (show committed)
                      <> ", proposed="
                      <> Text.pack (show proposedDigest)
                  )
              )
          Left detail ->
            go (remaining - 1) (Just (renderCommitError detail))

renderCommitError :: DecommissionCommitError -> Text
renderCommitError detail = case detail of
  CommitReadFailed message -> message
  CommitWriteFailed message -> message
  CommitConcurrentWrite -> "concurrent manifest commit"
