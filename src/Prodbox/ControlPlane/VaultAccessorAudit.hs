{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Finite terminal proof for an ephemeral Vault service-token session.
-- The auditor itself must be a bounded, non-renewable batch token: Vault
-- stores no accessor for it, so observing the worker accessor absent does not
-- create a recursive auditor-cleanup obligation.
module Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditError (..)
  , VaultAccessorSubject (..)
  , VaultAccessorAuditOps (..)
  , isBoundedBatchAuditorLogin
  , vaultAccessorMatchesSubject
  , revokeAndProveVaultAccessorSubjectAbsent
  , auditVaultTokenAccessorAbsence
  )
where

import Data.Foldable (traverse_)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultAddress
  , VaultKubernetesLoginResult (..)
  , vaultKubernetesLoginWithLease
  , vaultTokenAccessorAbsent
  )

data VaultAccessorAuditError
  = VaultAccessorAuditIdentityInvalid
  | VaultAccessorAuditorLoginFailed
  | VaultAccessorAuditorEvidenceInvalid
  | VaultAccessorObservationFailed
  | VaultAccessorClassificationFailed
  | VaultAccessorKnownIdentityMismatch
  | VaultAccessorRevocationFailed
  | VaultAccessorVisibilityWaitFailed
  | VaultAccessorStableAbsenceFailed
  deriving stock (Eq, Show)

-- | Secret-free identity of one ephemeral login lane.  Policy equality is
-- exact (apart from ordering), while metadata is a required subset because
-- Vault may add plugin-version-specific, non-authoritative metadata fields.
-- The Kubernetes ServiceAccount UID belongs in this map; a name or policy by
-- itself is not an operation/session correlation.
data VaultAccessorSubject = VaultAccessorSubject
  { vaultAccessorSubjectPolicies :: ![Text]
  , vaultAccessorSubjectMetadata :: !(Map Text Text)
  , vaultAccessorSubjectCreationPath :: !Text
  }
  deriving stock (Eq, Show)

-- | Injectable accessor-admin surface.  Production supplies one validated
-- batch auditor token.  Tests can model response loss and concurrent
-- unrelated accessors without constructing bearer tokens.
data VaultAccessorAuditOps m = VaultAccessorAuditOps
  { auditListAccessors :: m (Either Text [Text])
  , auditLookupAccessor :: Text -> m (Either Text TokenAccessorInfo)
  , auditRevokeAccessor :: Text -> m (Either Text ())
  , auditObserveAccessorAbsent :: Text -> m (Either Text Bool)
  , auditWaitVisibilityGrace :: m (Either Text ())
  }

isBoundedBatchAuditorLogin
  :: Int -> VaultKubernetesLoginResult -> Bool
isBoundedBatchAuditorLogin maximumLeaseSeconds login =
  maximumLeaseSeconds > 0
    && vaultLoginTokenType login == "batch"
    && Text.null (Text.strip (vaultLoginAccessor login))
    && not (vaultLoginRenewable login)
    && vaultLoginLeaseSeconds login > 0
    && vaultLoginLeaseSeconds login <= maximumLeaseSeconds

vaultAccessorMatchesSubject
  :: VaultAccessorSubject -> TokenAccessorInfo -> Bool
vaultAccessorMatchesSubject subject info =
  sort (tokenAccessorInfoPolicies info)
    == sort (vaultAccessorSubjectPolicies subject)
    && tokenAccessorInfoCreationPath info
      == vaultAccessorSubjectCreationPath subject
    && all
      (\(key, expected) -> Map.lookup key (tokenAccessorInfoMetadata info) == Just expected)
      (Map.toList (vaultAccessorSubjectMetadata subject))

-- | Revoke every accessor correlated to one exact ephemeral login identity,
-- then require two fresh zero-member inventories.  If acquisition returned a
-- service-token accessor, its direct list-based absence is additionally
-- mandatory.  Thus a lost login response is closed by the correlated scan,
-- while a known response cannot disappear into the broader proof.
revokeAndProveVaultAccessorSubjectAbsent
  :: (Monad m)
  => VaultAccessorAuditOps m
  -> VaultAccessorSubject
  -> Maybe Text
  -> m (Either VaultAccessorAuditError ())
revokeAndProveVaultAccessorSubjectAbsent ops subject maybeKnown = do
  initial <- matchingAccessors ops subject
  case initial of
    Left err -> pure (Left err)
    Right accessors -> do
      -- A revoke response can be lost after Vault applied it. Attempt every
      -- correlated accessor and treat these responses as provisional; only
      -- the later authoritative inventories decide terminal closure.
      traverse_ (auditRevokeAccessor ops) accessors
      case fmap Text.strip maybeKnown of
        Just accessor
          | Text.null accessor ->
              pure (Left VaultAccessorAuditIdentityInvalid)
        normalizedKnown ->
          pollUntilStable maximumVisibilityPolls normalizedKnown
 where
  pollUntilStable remaining known
    | remaining == 0 = pure (Left VaultAccessorStableAbsenceFailed)
    | otherwise = do
        observation <- observeCorrelated known
        case observation of
          Left err -> pure (Left err)
          Right (True, []) -> do
            waited <- auditWaitVisibilityGrace ops
            case waited of
              Left _ -> pure (Left VaultAccessorVisibilityWaitFailed)
              Right () -> do
                confirmed <- observeCorrelated known
                case confirmed of
                  Right (True, []) -> pure (Right ())
                  Right (_, visible) -> do
                    traverse_ (auditRevokeAccessor ops) visible
                    pollUntilStable (remaining - 1) known
                  Left err -> pure (Left err)
          Right (_, visible) -> do
            -- Vault may expose a just-revoked accessor for a bounded
            -- eventual-consistency window. Revoke any still-correlated
            -- members provisionally, consume one fixed grace interval, and
            -- retry without extending this finite cleanup budget.
            traverse_ (auditRevokeAccessor ops) visible
            waited <- auditWaitVisibilityGrace ops
            case waited of
              Left _ -> pure (Left VaultAccessorVisibilityWaitFailed)
              Right () -> pollUntilStable (remaining - 1) known

  observeCorrelated known = do
    knownAbsent <- observeKnown known
    case knownAbsent of
      Left err -> pure (Left err)
      Right absent -> do
        matching <- matchingAccessors ops subject
        pure ((absent,) <$> matching)

  observeKnown known = case known of
    Nothing -> pure (Right True)
    Just accessor -> do
      observed <- auditObserveAccessorAbsent ops accessor
      pure $ case observed of
        Left _ -> Left VaultAccessorObservationFailed
        Right absent -> Right absent

maximumVisibilityPolls :: Int
maximumVisibilityPolls = 8

matchingAccessors
  :: (Monad m)
  => VaultAccessorAuditOps m
  -> VaultAccessorSubject
  -> m (Either VaultAccessorAuditError [Text])
matchingAccessors ops subject = do
  listed <- auditListAccessors ops
  case listed of
    Left _ -> pure (Left VaultAccessorObservationFailed)
    Right accessors -> classify [] accessors
 where
  classify matching [] = pure (Right (reverse matching))
  classify matching (accessor : rest) = do
    lookedUp <- auditLookupAccessor ops accessor
    case lookedUp of
      Left _ -> pure (Left VaultAccessorClassificationFailed)
      Right info ->
        classify
          (if vaultAccessorMatchesSubject subject info then accessor : matching else matching)
          rest

auditVaultTokenAccessorAbsence
  :: VaultAddress
  -> Text
  -> Text
  -> Text
  -> Int
  -> Text
  -> IO (Either VaultAccessorAuditError Bool)
auditVaultTokenAccessorAbsence address authPath auditorRole jwt maximumLeaseSeconds rawAccessor
  | Text.null accessor || accessor /= rawAccessor =
      pure (Left VaultAccessorAuditIdentityInvalid)
  | otherwise = do
      loggedIn <-
        vaultKubernetesLoginWithLease address authPath auditorRole jwt
      case loggedIn of
        Left _ -> pure (Left VaultAccessorAuditorLoginFailed)
        Right login
          | not (isBoundedBatchAuditorLogin maximumLeaseSeconds login) ->
              pure (Left VaultAccessorAuditorEvidenceInvalid)
          | otherwise -> do
              observed <-
                vaultTokenAccessorAbsent
                  address
                  (vaultLoginToken login)
                  accessor
              pure $ case observed of
                Left _ -> Left VaultAccessorObservationFailed
                Right absent -> Right absent
 where
  accessor = Text.strip rawAccessor
