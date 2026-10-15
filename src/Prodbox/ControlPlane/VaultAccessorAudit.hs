{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Finite terminal proof for an ephemeral Vault service-token session.
-- The auditor itself must be a bounded, non-renewable batch token: Vault
-- stores no accessor for it, so observing the worker accessor absent does not
-- create a recursive auditor-cleanup obligation.
module Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditError (..)
  , VaultAccessorLookupError (..)
  , VaultAccessorAuditDetailedError (..)
  , VaultAccessorDetailedLookupError (..)
  , VaultAccessorSubject (..)
  , VaultAccessorAuditOps (..)
  , VaultAccessorAuditDetailedOps (..)
  , isBoundedBatchAuditorLogin
  , isExactBoundedBatchAuditorLogin
  , vaultAccessorMatchesSubject
  , classifyVaultAccessorLookupResponse
  , revokeAndProveVaultAccessorSubjectAbsent
  , revokeAndProveVaultAccessorSubjectAbsentDetailed
  , auditVaultTokenAccessorAbsence
  )
where

import Data.Foldable (traverse_)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Http.Client (HttpError)
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultAddress
  , VaultKubernetesLoginResult (..)
  , vaultAccessorLookupVanished
  , vaultKubernetesLoginWithLease
  , vaultTokenAccessorAbsent
  )

data VaultAccessorAuditError
  = VaultAccessorAuditIdentityInvalid
  | VaultAccessorAuditorLoginFailed
  | VaultAccessorAuditorEvidenceInvalid
  | VaultAccessorObservationFailed
  | VaultAccessorClassificationUnavailable
  | VaultAccessorClassificationFailed
  | VaultAccessorKnownIdentityMismatch
  | VaultAccessorRevocationFailed
  | VaultAccessorVisibilityWaitFailed
  | VaultAccessorStableAbsenceFailed
  deriving stock (Eq, Show)

-- | Closed, payload-free result of classifying one accessor named by a
-- preceding global inventory. Vault can legitimately remove that accessor
-- between LIST and lookup (a token expires, another cleanup revokes it, or a
-- revocation is still listed). That answer is distinct from an unavailable
-- lookup, and only the second fails the audit.
data VaultAccessorLookupError
  = VaultAccessorLookupAbsent
  | VaultAccessorLookupUnavailable
  deriving stock (Eq, Show)

-- | The finite audit result with the interpreter's closed operation failure
-- retained. Revoke failures are deliberately absent: revoke responses are
-- provisional and only later authoritative observations decide closure.
data VaultAccessorAuditDetailedError failure
  = VaultAccessorAuditDetailedIdentityInvalid
  | VaultAccessorAuditDetailedObservationFailed !failure
  | VaultAccessorAuditDetailedClassificationFailed !failure
  | VaultAccessorAuditDetailedVisibilityWaitFailed !failure
  | VaultAccessorAuditDetailedStableAbsenceFailed
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
  , auditLookupAccessor :: Text -> m (Either VaultAccessorLookupError TokenAccessorInfo)
  , auditRevokeAccessor :: Text -> m (Either Text ())
  , auditObserveAccessorAbsent :: Text -> m (Either Text Bool)
  , auditWaitVisibilityGrace :: m (Either Text ())
  }

-- | Erase HTTP payloads while retaining the one provider response that means
-- an accessor named by the preceding inventory no longer exists. Vault answers
-- that with HTTP 400 @invalid accessor@, not 404 ('vaultAccessorLookupVanished'),
-- so every other failure stays unavailable.
classifyVaultAccessorLookupResponse
  :: Either HttpError TokenAccessorInfo
  -> Either VaultAccessorLookupError TokenAccessorInfo
classifyVaultAccessorLookupResponse response = case response of
  Left failure
    | vaultAccessorLookupVanished failure -> Left VaultAccessorLookupAbsent
    | otherwise -> Left VaultAccessorLookupUnavailable
  Right info -> Right info

-- | What a lookup of one listed accessor can answer besides an identity: Vault
-- no longer knows the accessor, which makes it no member of any subject, or the
-- interpreter's closed failure for a lookup that could not decide.
data VaultAccessorDetailedLookupError failure
  = VaultAccessorDetailedLookupVanished
  | VaultAccessorDetailedLookupFailed !failure
  deriving stock (Eq, Show)

-- | Typed counterpart to 'VaultAccessorAuditOps'. The interpreter supplies a
-- closed failure type that identifies the exact operation without retaining
-- arbitrary provider text.
data VaultAccessorAuditDetailedOps m failure = VaultAccessorAuditDetailedOps
  { detailedAuditListAccessors :: m (Either failure [Text])
  , detailedAuditLookupAccessor
      :: Text -> m (Either (VaultAccessorDetailedLookupError failure) TokenAccessorInfo)
  , detailedAuditRevokeAccessor :: Text -> m (Either failure ())
  , detailedAuditObserveAccessorAbsent :: Text -> m (Either failure Bool)
  , detailedAuditWaitVisibilityGrace :: m (Either failure ())
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

-- | Require both the safe batch-token shape and the exact compiled lease.
-- This is for callers whose child runtime is contained by that lease; merely
-- accepting a shorter server-issued lease would make the containment proof
-- about source configuration rather than the token actually in use.
isExactBoundedBatchAuditorLogin
  :: Int -> VaultKubernetesLoginResult -> Bool
isExactBoundedBatchAuditorLogin leaseSeconds login =
  isBoundedBatchAuditorLogin leaseSeconds login
    && vaultLoginLeaseSeconds login == fromIntegral leaseSeconds

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
revokeAndProveVaultAccessorSubjectAbsent ops subject maybeKnown =
  fmap (mapLeft collapseDetailedAuditError) $
    revokeAndProveVaultAccessorSubjectAbsentDetailed detailedOps subject maybeKnown
 where
  detailedOps =
    VaultAccessorAuditDetailedOps
      { detailedAuditListAccessors =
          fmap (mapLeft VaultAccessorAuditGeneralFailure) (auditListAccessors ops)
      , detailedAuditLookupAccessor = \accessor ->
          fmap
            (mapLeft detailedLookupError)
            (auditLookupAccessor ops accessor)
      , detailedAuditRevokeAccessor = \accessor ->
          fmap
            (mapLeft VaultAccessorAuditGeneralFailure)
            (auditRevokeAccessor ops accessor)
      , detailedAuditObserveAccessorAbsent = \accessor ->
          fmap
            (mapLeft VaultAccessorAuditGeneralFailure)
            (auditObserveAccessorAbsent ops accessor)
      , detailedAuditWaitVisibilityGrace =
          fmap
            (mapLeft VaultAccessorAuditGeneralFailure)
            (auditWaitVisibilityGrace ops)
      }

  detailedLookupError lookupError = case lookupError of
    VaultAccessorLookupAbsent -> VaultAccessorDetailedLookupVanished
    VaultAccessorLookupUnavailable ->
      VaultAccessorDetailedLookupFailed VaultAccessorAuditLookupUnavailable

  collapseDetailedAuditError failure = case failure of
    VaultAccessorAuditDetailedIdentityInvalid -> VaultAccessorAuditIdentityInvalid
    VaultAccessorAuditDetailedObservationFailed _ -> VaultAccessorObservationFailed
    VaultAccessorAuditDetailedClassificationFailed operationFailure -> case operationFailure of
      VaultAccessorAuditLookupUnavailable -> VaultAccessorClassificationUnavailable
      VaultAccessorAuditGeneralFailure _ -> VaultAccessorClassificationFailed
    VaultAccessorAuditDetailedVisibilityWaitFailed _ -> VaultAccessorVisibilityWaitFailed
    VaultAccessorAuditDetailedStableAbsenceFailed -> VaultAccessorStableAbsenceFailed

data VaultAccessorAuditOperationFailure
  = VaultAccessorAuditGeneralFailure !Text
  | VaultAccessorAuditLookupUnavailable

-- | Typed stable-zero proof. The provider-specific failure is returned only
-- for authoritative list, lookup, direct-absence, and visibility operations.
-- Revoke responses remain provisional and cannot decide terminal closure.
revokeAndProveVaultAccessorSubjectAbsentDetailed
  :: (Monad m)
  => VaultAccessorAuditDetailedOps m failure
  -> VaultAccessorSubject
  -> Maybe Text
  -> m (Either (VaultAccessorAuditDetailedError failure) ())
revokeAndProveVaultAccessorSubjectAbsentDetailed ops subject maybeKnown = do
  initial <- matchingAccessorsDetailed ops subject
  case initial of
    Left err -> pure (Left err)
    Right accessors -> do
      -- A revoke response can be lost after Vault applied it. Attempt every
      -- correlated accessor and treat these responses as provisional; only
      -- the later authoritative inventories decide terminal closure.
      traverse_ (detailedAuditRevokeAccessor ops) accessors
      case fmap Text.strip maybeKnown of
        Just accessor
          | Text.null accessor ->
              pure (Left VaultAccessorAuditDetailedIdentityInvalid)
        normalizedKnown ->
          pollUntilStable maximumVisibilityPolls normalizedKnown
 where
  pollUntilStable remaining known
    | remaining == 0 = pure (Left VaultAccessorAuditDetailedStableAbsenceFailed)
    | otherwise = do
        observation <- observeCorrelated known
        case observation of
          Left err -> pure (Left err)
          Right (True, []) -> do
            waited <- detailedAuditWaitVisibilityGrace ops
            case waited of
              Left failure ->
                pure (Left (VaultAccessorAuditDetailedVisibilityWaitFailed failure))
              Right () -> do
                confirmed <- observeCorrelated known
                case confirmed of
                  Right (True, []) -> pure (Right ())
                  Right (_, visible) -> do
                    traverse_ (detailedAuditRevokeAccessor ops) visible
                    pollUntilStable (remaining - 1) known
                  Left err -> pure (Left err)
          Right (_, visible) -> do
            -- Vault may expose a just-revoked accessor for a bounded
            -- eventual-consistency window. Revoke any still-correlated
            -- members provisionally, consume one fixed grace interval, and
            -- retry without extending this finite cleanup budget.
            traverse_ (detailedAuditRevokeAccessor ops) visible
            waited <- detailedAuditWaitVisibilityGrace ops
            case waited of
              Left failure ->
                pure (Left (VaultAccessorAuditDetailedVisibilityWaitFailed failure))
              Right () -> pollUntilStable (remaining - 1) known

  observeCorrelated known = do
    knownAbsent <- observeKnown known
    case knownAbsent of
      Left err -> pure (Left err)
      Right absent -> do
        matching <- matchingAccessorsDetailed ops subject
        pure ((absent,) <$> matching)

  observeKnown known = case known of
    Nothing -> pure (Right True)
    Just accessor -> do
      observed <- detailedAuditObserveAccessorAbsent ops accessor
      pure $ case observed of
        Left failure -> Left (VaultAccessorAuditDetailedObservationFailed failure)
        Right absent -> Right absent

maximumVisibilityPolls :: Int
maximumVisibilityPolls = 8

-- | One LIST and one lookup per listed accessor. An accessor Vault no longer
-- knows by the time it is looked up cannot be a live member of the subject, so
-- the scan passes over it: the stable-zero proof rests on fresh inventories,
-- never on this one. Any other lookup failure decides nothing and ends the scan.
matchingAccessorsDetailed
  :: (Monad m)
  => VaultAccessorAuditDetailedOps m failure
  -> VaultAccessorSubject
  -> m (Either (VaultAccessorAuditDetailedError failure) [Text])
matchingAccessorsDetailed ops subject = do
  listed <- detailedAuditListAccessors ops
  case listed of
    Left failure ->
      pure (Left (VaultAccessorAuditDetailedObservationFailed failure))
    Right accessors -> classify [] accessors
 where
  classify matching [] = pure (Right (reverse matching))
  classify matching (accessor : rest) = do
    lookedUp <- detailedAuditLookupAccessor ops accessor
    case lookedUp of
      Left VaultAccessorDetailedLookupVanished -> classify matching rest
      Left (VaultAccessorDetailedLookupFailed failure) ->
        pure (Left (VaultAccessorAuditDetailedClassificationFailed failure))
      Right info ->
        classify
          (if vaultAccessorMatchesSubject subject info then accessor : matching else matching)
          rest

mapLeft :: (left -> mapped) -> Either left value -> Either mapped value
mapLeft project value = case value of
  Left failure -> Left (project failure)
  Right result -> Right result

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
