{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: the production lane that ends a cascade's Provider credential.
--
-- The epoch transition landed first and had no producer.
-- 'Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.mkProviderCredentialRevocationReceipt'
-- binds two independent read-backs — the joint IAM family disposition and the
-- retained Target generation's revocation — and refuses one digest standing for
-- both, and
-- @Prodbox.Lifecycle.Authority.Admission.revokeCascadeProviderCredentialInternal@
-- is reachable only from the recorded state and only over a clean verdict.  What
-- did not exist was anything that /produced/ those two digests and presented
-- them to the route, so the transition was a transition nothing could take.
--
-- __The order is a safety property, not a preference.__  The IAM family is
-- destroyed first, because the IAM identity is what /grants/: once it is gone,
-- any copy of the credential material that survives anywhere is already inert.
-- Retiring the Target-held material first would leave the grant standing while
-- removing the only record of what it was, which is the worse of the two
-- intermediate states.
--
-- __Neither half may stand in for the other.__  The two digests are derived by
-- different functions over different facts, so they cannot collide by accident;
-- the receipt's own independence check stays in front of the route anyway,
-- because a future derivation change must not be able to silently reduce the
-- two-sided proof to a one-sided one.
--
-- __Nothing here decides whether revocation is allowed.__  That is the epoch's
-- job: this lane submits, and the Authority refuses a submission that is not
-- frozen, not recorded, recorded under another binding, or recorded with a
-- verdict that is not clean.  A caller therefore cannot reach revocation by
-- composing this module differently.
module Prodbox.Lifecycle.Teardown.CascadeCredentialRevocation
  ( CascadeCredentialRevocationBoundary (..)
  , CascadeCredentialRevocationRefusal (..)
  , renderCascadeCredentialRevocationRefusal
  , retainedTargetGenerationRevocationDigest
  , revokeCascadeProviderCredential
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityControlPayload (AuthorityControlRevokeCascadeProviderCredential)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( CascadeAuditFreezeBinding
  , ProviderAdmissionEpochError
  , mkProviderCredentialRevocationReceipt
  )
import Prodbox.Lifecycle.CleanupRun (CleanupDigest, cleanupDigestOfBytes)
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( JointIamDispositionAuthorization
  , JointIamDispositionComplete
  , jointIamDispositionDigest
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( decommissionTargetGenerationValue
  )
import Prodbox.Lifecycle.Decommission.TargetTombstone
  ( TargetGenerationTombstoneCommand (..)
  , TargetGenerationTombstoneResult (..)
  )

-- | Everything this lane is allowed to touch.
--
-- Each field is one already-authorized production effect, so the lane composes
-- them and decides nothing about authorization itself.
data CascadeCredentialRevocationBoundary m = CascadeCredentialRevocationBoundary
  { cascadeRevocationDisposeIamFamily
      :: JointIamDispositionAuthorization
      -> m (Either Text JointIamDispositionComplete)
  -- ^ Destroy the credential class's whole IAM family and mint the completion
  -- from a read-back in which every member is independently absent.  In
  -- production this is
  -- @Prodbox.Lifecycle.CredentialProvisioner.ProductionIam.destroyProductionIamIdentity@.
  , cascadeRevocationTombstoneTargetGeneration
      :: TargetGenerationTombstoneCommand
      -> m TargetGenerationTombstoneResult
  -- ^ Destroy the retained Target generation and confirm it by an
  -- authoritative read-back.  In production this is
  -- @runAuthorizedTargetGenerationTombstone@ at
  -- 'Prodbox.Lifecycle.Decommission.TargetTombstone.DestroyTargetGeneration';
  -- the proof family that authorizes it here is the cascade audit's own
  -- reservation rather than a decommission manifest, which is exactly why that
  -- helper performs no proof-family conversion of its own.
  , cascadeRevocationSubmitControl
      :: AuthorityControlPayload -> m (Either Text Text)
  -- ^ Submit the revocation to the Lifecycle Authority's control route.
  }

data CascadeCredentialRevocationRefusal
  = -- | The IAM family was not proved gone.  Nothing is submitted, and the
    -- Target-held material is deliberately left alone: retiring it now would
    -- destroy the record of a credential whose grant still stands.
    CascadeRevocationIamFamilyNotDisposed !Text
  | -- | The IAM family is gone and the retained Target generation is not.  The
    -- credential is already inert; the surviving material is named so a retry
    -- resumes from it rather than starting over.
    CascadeRevocationTargetGenerationNotRevoked !TargetGenerationTombstoneResult
  | -- | Both halves succeeded and their digests are not two independent
    -- proofs.  This cannot arise from the derivations below, and the check
    -- stays in front of the route so a future change to either cannot quietly
    -- reduce the receipt to one proof.
    CascadeRevocationProofsNotIndependent !ProviderAdmissionEpochError
  | -- | The Authority refused the revocation.  Both halves have already
    -- happened, so this is a durable-record failure rather than an
    -- unperformed one, and the refusal text is the Authority's own.
    CascadeRevocationAuthorityRefused !Text
  deriving (Eq, Show)

renderCascadeCredentialRevocationRefusal
  :: CascadeCredentialRevocationRefusal -> Text
renderCascadeCredentialRevocationRefusal refusal = case refusal of
  CascadeRevocationIamFamilyNotDisposed detail ->
    "the cascade Provider credential's IAM family was not proved absent, so \
    \nothing was revoked: "
      <> detail
  CascadeRevocationTargetGenerationNotRevoked result ->
    "the cascade Provider credential's IAM family is absent and its retained \
    \Target generation is not, so the credential is inert and its material \
    \survives: "
      <> Text.pack (show result)
  CascadeRevocationProofsNotIndependent detail ->
    "the revocation's two read-backs are not independent proofs: "
      <> Text.pack (show detail)
  CascadeRevocationAuthorityRefused detail ->
    "both halves of the cascade Provider credential revocation are done and \
    \the Lifecycle Authority refused to record it: "
      <> detail

-- | The canonical digest of one proved retained-Target-generation revocation.
--
-- It names the exact coordinate reference, the exact generation, and which of
-- the two terminal read-backs proved absence, so a revocation of a different
-- coordinate or a different generation cannot share a digest.  The version
-- prefix is distinct from the IAM disposition's, which is what makes the two
-- halves of the receipt structurally unable to collide.
retainedTargetGenerationRevocationDigest
  :: TargetGenerationTombstoneCommand -> Text -> CleanupDigest
retainedTargetGenerationRevocationDigest command outcome =
  cleanupDigestOfBytes (TextEncoding.encodeUtf8 canonical)
 where
  canonical =
    Text.intercalate
      "\NUL"
      [ "retained-target-generation-revocation/v1"
      , Text.strip (targetTombstoneReference command)
      , Text.pack
          ( show
              ( decommissionTargetGenerationValue
                  (targetTombstoneGeneration command)
              )
          )
      , outcome
      ]

-- | Destroy the cascade's Provider credential on both sides and record it.
revokeCascadeProviderCredential
  :: (Monad m)
  => CascadeCredentialRevocationBoundary m
  -> CascadeAuditFreezeBinding
  -> JointIamDispositionAuthorization
  -> TargetGenerationTombstoneCommand
  -> m (Either CascadeCredentialRevocationRefusal Text)
revokeCascadeProviderCredential boundary binding authorization command = do
  disposed <- cascadeRevocationDisposeIamFamily boundary authorization
  case disposed of
    Left detail -> pure (Left (CascadeRevocationIamFamilyNotDisposed detail))
    Right complete -> do
      tombstoned <- cascadeRevocationTombstoneTargetGeneration boundary command
      case revocationOutcomeProof tombstoned of
        Nothing ->
          pure (Left (CascadeRevocationTargetGenerationNotRevoked tombstoned))
        Just outcome -> submit complete outcome
 where
  submit complete outcome =
    case mkProviderCredentialRevocationReceipt
      (jointIamProofDigest complete)
      (retainedTargetGenerationRevocationDigest command outcome) of
      Left detail -> pure (Left (CascadeRevocationProofsNotIndependent detail))
      Right receipt -> do
        submitted <-
          cascadeRevocationSubmitControl
            boundary
            (AuthorityControlRevokeCascadeProviderCredential binding receipt)
        pure (either (Left . CascadeRevocationAuthorityRefused) Right submitted)

-- | The IAM half's proof, re-digested into the cleanup-digest shape the receipt
-- carries.  'jointIamDispositionDigest' is already a lowercase hex SHA-256 of
-- its own canonical rendering; wrapping it under this lane's own prefix keeps
-- the receipt's two fields derived by two functions rather than by one shared
-- helper that a later edit could point at the same input.
jointIamProofDigest :: JointIamDispositionComplete -> CleanupDigest
jointIamProofDigest complete =
  cleanupDigestOfBytes
    ( TextEncoding.encodeUtf8
        ( Text.intercalate
            "\NUL"
            [ "cascade-provider-iam-disposition/v1"
            , jointIamDispositionDigest complete
            ]
        )
    )

-- | Which terminal tombstone results prove the generation gone, and under which
-- name.
--
-- Both are proofs and they are different facts: one says this run destroyed it,
-- the other says an earlier attempt already had.  They are kept distinct in the
-- digest so a retry that finds the work already done cannot produce the digest
-- of a run that did it.  @TargetGenerationPresent@ is not a proof at all — it is
-- the observe-only answer — and a refusal is a refusal.
revocationOutcomeProof :: TargetGenerationTombstoneResult -> Maybe Text
revocationOutcomeProof result = case result of
  TargetGenerationDestroyedAndReadBack -> Just "destroyed-and-read-back"
  TargetGenerationAlreadyAbsent -> Just "already-absent"
  TargetGenerationPresent -> Nothing
  TargetGenerationTombstoneRefused _ -> Nothing
