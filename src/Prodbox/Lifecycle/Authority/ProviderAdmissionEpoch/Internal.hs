{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private retained state for the Lifecycle Provider admission
-- epoch. The public facade exposes only read-only views and fixed diagnostics.
--
-- Sprint 4.85 added the two transitions this module previously described as
-- absent: binding a serving credential generation, and the atomic Cascade-audit
-- freeze that reserves exactly one terminal-audit submission while fencing
-- every other fresh one. Both are pure and package-private, and both are
-- consumed by @Prodbox.Lifecycle.Authority.Admission@ as commands over the same
-- retained aggregate the submission path reads — which is what makes the freeze
-- atomic with the pending-work proof rather than a second object that could
-- disagree.
--
-- What is still absent is an authenticated route that issues either command, so
-- no production caller can reach the frozen state yet. Revocation likewise has
-- no transition: 'ProviderCredentialRevocationReceipt' remains a retained shape
-- with no constructor.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
  ( ProviderAdmissionEpoch
  , ProviderAdmissionEpochView (..)
  , ProviderAdmissionEpochError (..)
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , providerAdmissionEpochView
  , initialLegacyProviderAdmissionEpochInternal
  , validateProviderAdmissionEpochInternal
  , providerAdmissionFreshSubmissionRefusalInternal
  , CascadeAuditFreezeBinding
  , mkCascadeAuditFreezeBinding
  , cascadeAuditFreezeBindingExpectedSubmissions
  , ProviderPendingWork (..)
  , ProviderAdmissionFreezeRefusal (..)
  , bindProviderAdmissionServingGenerationInternal
  , freezeProviderAdmissionForCascadeAuditInternal
  , ProviderAdmissionEpochRegression
  , fixedProviderAdmissionEpochRegression
  , providerAdmissionEpochRegressionLegacyPreserved
  , providerAdmissionEpochRegressionServingPermitsFresh
  , providerAdmissionEpochRegressionFrozenRefusesFresh
  , providerAdmissionEpochRegressionRevokedRefusesFresh
  , providerAdmissionEpochRegressionNoPendingClassified
  , providerAdmissionEpochRegressionOwnedPendingClassified
  , providerAdmissionEpochRegressionUnownedPendingClassified
  , providerAdmissionEpochRegressionFrozenShapeValidated
  , providerAdmissionEpochRegressionRevokedShapeValidated
  , providerAdmissionEpochRegressionInvalidGenerationRefused
  , providerAdmissionEpochRegressionNonCanonicalBindingRefused
  , ProviderAdmissionFreezeRegression
  , fixedProviderAdmissionFreezeRegression
  , freezeRegressionUnboundGenerationRefused
  , freezeRegressionPendingWorkRefused
  , freezeRegressionServingFreezes
  , freezeRegressionIdenticalFreezeIdempotent
  , freezeRegressionDifferentBindingRefused
  , freezeRegressionRevokedRefused
  , freezeRegressionGenerationBindIdempotent
  , freezeRegressionRebindDifferentGenerationRefused
  , freezeRegressionFrozenAdmitsOnlyReservation
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRunId
  , mkCleanupAttemptId
  , mkCleanupDigest
  , mkCleanupNodeId
  , mkCleanupOperationId
  , mkCleanupRunId
  )

newtype ProviderCredentialGeneration = ProviderCredentialGeneration Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | An abstract retained shape for the future atomic freeze-and-reserve
-- transition. The current slice can validate and render this shape after
-- durable decode, but cannot construct or transition to it. The eventual
-- transition must additionally prove and retain the exact terminal-audit
-- submission key, digest, and intent in the same aggregate CAS.
data CascadeAuditFreezeBinding
  = CascadeAuditFreezeBinding
      !CleanupRunId
      !CleanupDigest
      !CleanupDigest
      !Text
      !CleanupNodeId
      !CleanupOperationId
      !CleanupAttemptId
      ![ClientSubmissionKey]
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The future revoke protocol must bind independently read-back IAM and
-- retained Target generations. No constructor or transition is exported.
data ProviderCredentialRevocationReceipt
  = ProviderCredentialRevocationReceipt !CleanupDigest !CleanupDigest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ProviderAdmissionEpoch
  = ProviderAdmissionLegacyServingUnboundInternal
  | ProviderAdmissionServingInternal !ProviderCredentialGeneration
  | ProviderAdmissionCascadeAuditFrozenInternal
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
  | ProviderAdmissionCascadeCredentialRevokedInternal
      !ProviderCredentialGeneration
      !CascadeAuditFreezeBinding
      !ProviderCredentialRevocationReceipt
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Non-authorizing retained-state view. It intentionally omits the hidden
-- freeze binding and revocation receipt.
data ProviderAdmissionEpochView
  = ProviderAdmissionLegacyServingUnbound
  | ProviderAdmissionServing !Natural
  | ProviderAdmissionCascadeAuditFrozen !Natural
  | ProviderAdmissionCascadeCredentialRevoked !Natural
  deriving stock (Eq, Show)

data ProviderAdmissionEpochError
  = ProviderAdmissionCredentialGenerationInvalid !Natural
  | ProviderAdmissionFreezeScopeDigestInvalid !Text
  | ProviderAdmissionFreezeExpectedSubmissionsEmpty
  | ProviderAdmissionFreezeExpectedSubmissionsExceedMaximum !Int !Int
  | ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
  deriving stock (Eq, Show)

data ProviderAdmissionFreshSubmissionRefusal
  = ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  | ProviderAdmissionFreshSubmissionCredentialRevoked
  deriving stock (Eq, Show)

maximumExpectedProviderSubmissions :: Int
maximumExpectedProviderSubmissions = 4096

initialLegacyProviderAdmissionEpochInternal :: ProviderAdmissionEpoch
initialLegacyProviderAdmissionEpochInternal =
  ProviderAdmissionLegacyServingUnboundInternal

providerAdmissionEpochView
  :: ProviderAdmissionEpoch -> ProviderAdmissionEpochView
providerAdmissionEpochView epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal ->
    ProviderAdmissionLegacyServingUnbound
  ProviderAdmissionServingInternal generation ->
    ProviderAdmissionServing (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeAuditFrozenInternal generation _ ->
    ProviderAdmissionCascadeAuditFrozen
      (providerCredentialGenerationValue generation)
  ProviderAdmissionCascadeCredentialRevokedInternal generation _ _ ->
    ProviderAdmissionCascadeCredentialRevoked
      (providerCredentialGenerationValue generation)

validateProviderAdmissionEpochInternal
  :: ProviderAdmissionEpoch -> Either ProviderAdmissionEpochError ()
validateProviderAdmissionEpochInternal epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> Right ()
  ProviderAdmissionServingInternal generation -> validateGeneration generation
  ProviderAdmissionCascadeAuditFrozenInternal generation binding -> do
    validateGeneration generation
    validateCascadeAuditFreezeBinding binding
  ProviderAdmissionCascadeCredentialRevokedInternal generation binding _ -> do
    validateGeneration generation
    validateCascadeAuditFreezeBinding binding

-- | Whether a fresh Provider submission is fenced by the current epoch.
--
-- Sprint 4.85: the frozen arm now consults the freeze binding\'s reservation.
-- A freeze that fenced /every/ fresh submission would fence the terminal audit
-- it exists to run, so the audit could never be submitted and the frozen state
-- would be a dead end. The binding names the exact submission keys the freeze
-- reserved, and only those are admitted; every other fresh submission is
-- refused exactly as before.
--
-- Revocation admits nothing: after revocation there is no credential to
-- execute a reserved submission with.
providerAdmissionFreshSubmissionRefusalInternal
  :: ProviderAdmissionEpoch
  -> ClientSubmissionKey
  -> Maybe ProviderAdmissionFreshSubmissionRefusal
providerAdmissionFreshSubmissionRefusalInternal epoch submissionKey = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionCascadeAuditFrozenInternal _ binding
    | submissionKey `elem` cascadeAuditFreezeBindingExpectedSubmissions binding ->
        Nothing
    | otherwise -> Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  ProviderAdmissionCascadeCredentialRevokedInternal {} ->
    Just ProviderAdmissionFreshSubmissionCredentialRevoked

cascadeAuditFreezeBindingExpectedSubmissions
  :: CascadeAuditFreezeBinding -> [ClientSubmissionKey]
cascadeAuditFreezeBindingExpectedSubmissions
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ keys) = keys

-- | Pending Provider work observed in the same aggregate read as the freeze.
--
-- It is a value the caller projects from the retained aggregate rather than a
-- list the caller composes: a freeze whose pending-work proof came from a
-- separate read could be issued against an aggregate that had since accepted a
-- submission, which is the race the atomicity requirement exists to remove.
data ProviderPendingWork
  = NoPendingProviderWork
  | PendingProviderWork !Int
  deriving stock (Eq, Show)

data ProviderAdmissionFreezeRefusal
  = -- | The epoch has no bound credential generation, so a freeze could not
    -- name which generation it fenced and a later revoke could not prove which
    -- one it revoked.
    ProviderAdmissionFreezeGenerationUnbound
  | -- | Pending Provider work exists. Freezing over it would fence the retries
    -- that could settle it, stranding admitted operations.
    ProviderAdmissionFreezePendingWorkPresent !Int
  | -- | Already frozen under a different reservation. A second freeze would
    -- silently replace the reservation the first one committed.
    ProviderAdmissionFreezeAlreadyFrozenDifferently
  | -- | The credential is revoked; there is nothing left to fence.
    ProviderAdmissionFreezeCredentialRevoked
  | ProviderAdmissionFreezeBindingInvalid !ProviderAdmissionEpochError
  deriving stock (Eq, Show)

-- | Bind the serving credential generation.
--
-- Idempotent on the same generation, because a lost response must not be
-- distinguishable from a repeat. A different generation is refused rather than
-- replacing the bound one, and neither a frozen nor a revoked epoch may be
-- rebound.
bindProviderAdmissionServingGenerationInternal
  :: ProviderAdmissionEpoch
  -> Natural
  -> Either ProviderAdmissionEpochError ProviderAdmissionEpoch
bindProviderAdmissionServingGenerationInternal epoch generation = do
  bound <- providerCredentialGeneration generation
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal ->
      Right (ProviderAdmissionServingInternal bound)
    ProviderAdmissionServingInternal existing
      | existing == bound -> Right epoch
      | otherwise ->
          Left
            ( ProviderAdmissionCredentialGenerationInvalid
                (providerCredentialGenerationValue existing)
            )
    ProviderAdmissionCascadeAuditFrozenInternal existing _ ->
      Left
        ( ProviderAdmissionCredentialGenerationInvalid
            (providerCredentialGenerationValue existing)
        )
    ProviderAdmissionCascadeCredentialRevokedInternal existing _ _ ->
      Left
        ( ProviderAdmissionCredentialGenerationInvalid
            (providerCredentialGenerationValue existing)
        )

-- | Atomically freeze admission and reserve the terminal-audit submission.
--
-- The pending-work proof and the transition are one step over one aggregate, so
-- there is no window in which a submission is accepted between the proof and
-- the fence. Re-issuing the identical freeze is accepted unchanged: a lost
-- response must not burn a second reservation, and a second freeze under a
-- different binding is refused rather than replacing the first.
freezeProviderAdmissionForCascadeAuditInternal
  :: ProviderAdmissionEpoch
  -> CascadeAuditFreezeBinding
  -> ProviderPendingWork
  -> Either ProviderAdmissionFreezeRefusal ProviderAdmissionEpoch
freezeProviderAdmissionForCascadeAuditInternal epoch binding pending = do
  case validateCascadeAuditFreezeBinding binding of
    Left err -> Left (ProviderAdmissionFreezeBindingInvalid err)
    Right () -> Right ()
  case epoch of
    ProviderAdmissionLegacyServingUnboundInternal ->
      Left ProviderAdmissionFreezeGenerationUnbound
    ProviderAdmissionCascadeCredentialRevokedInternal {} ->
      Left ProviderAdmissionFreezeCredentialRevoked
    ProviderAdmissionCascadeAuditFrozenInternal _ existing
      | existing == binding -> Right epoch
      | otherwise -> Left ProviderAdmissionFreezeAlreadyFrozenDifferently
    ProviderAdmissionServingInternal generation -> case pending of
      PendingProviderWork count ->
        Left (ProviderAdmissionFreezePendingWorkPresent count)
      NoPendingProviderWork ->
        Right (ProviderAdmissionCascadeAuditFrozenInternal generation binding)

providerCredentialGeneration
  :: Natural
  -> Either ProviderAdmissionEpochError ProviderCredentialGeneration
providerCredentialGeneration generation
  | generation == 0 =
      Left (ProviderAdmissionCredentialGenerationInvalid generation)
  | otherwise = Right (ProviderCredentialGeneration generation)

validateGeneration
  :: ProviderCredentialGeneration -> Either ProviderAdmissionEpochError ()
validateGeneration (ProviderCredentialGeneration generation)
  | generation == 0 =
      Left (ProviderAdmissionCredentialGenerationInvalid generation)
  | otherwise = Right ()

providerCredentialGenerationValue :: ProviderCredentialGeneration -> Natural
providerCredentialGenerationValue (ProviderCredentialGeneration generation) =
  generation

mkCascadeAuditFreezeBinding
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupDigest
  -> Text
  -> CleanupNodeId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> [ClientSubmissionKey]
  -> Either ProviderAdmissionEpochError CascadeAuditFreezeBinding
mkCascadeAuditFreezeBinding
  runId
  descriptorDigest
  graphDigest
  scopeDigest
  nodeId
  operationId
  attemptId
  expectedSubmissionKeys = do
    let binding =
          CascadeAuditFreezeBinding
            runId
            descriptorDigest
            graphDigest
            scopeDigest
            nodeId
            operationId
            attemptId
            expectedSubmissionKeys
    validateCascadeAuditFreezeBinding binding
    Right binding

validateCascadeAuditFreezeBinding
  :: CascadeAuditFreezeBinding -> Either ProviderAdmissionEpochError ()
validateCascadeAuditFreezeBinding
  (CascadeAuditFreezeBinding _ _ _ scopeDigest _ _ _ keys)
    | not (isLowerHexSha256 scopeDigest) =
        Left (ProviderAdmissionFreezeScopeDigestInvalid scopeDigest)
    | null keys = Left ProviderAdmissionFreezeExpectedSubmissionsEmpty
    | length keys > maximumExpectedProviderSubmissions =
        Left
          ( ProviderAdmissionFreezeExpectedSubmissionsExceedMaximum
              (length keys)
              maximumExpectedProviderSubmissions
          )
    | keys /= sort (nub keys) =
        Left ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
    | otherwise = Right ()

data ProviderPendingClassification
  = ProviderNoPendingSubmissions
  | ProviderOwnedPendingSubmissions ![Text]
  | ProviderUnownedPendingSubmissions ![Text]
  deriving stock (Eq, Show)

-- | Pure inventory classification only. It cannot freeze admission. In the
-- eventual protocol, even @ProviderNoPendingSubmissions@ is insufficient:
-- the same CAS must reserve the exact terminal-audit submission before it
-- blocks every other fresh submission.
classifyPending
  :: CascadeAuditFreezeBinding
  -> [ClientSubmissionKey]
  -> ProviderPendingClassification
classifyPending
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ expected)
  pending
    | not (null unowned) =
        ProviderUnownedPendingSubmissions
          (fmap clientSubmissionKeyText unowned)
    | not (null canonicalPending) =
        ProviderOwnedPendingSubmissions
          (fmap clientSubmissionKeyText canonicalPending)
    | otherwise = ProviderNoPendingSubmissions
   where
    canonicalPending = sort (nub pending)
    unowned = filter (`notElem` expected) canonicalPending

isLowerHexSha256 :: Text -> Bool
isLowerHexSha256 value =
  Text.length value == 64
    && Text.all (\character -> character `elem` ("0123456789abcdef" :: String)) value

data ProviderAdmissionEpochRegression = ProviderAdmissionEpochRegression
  { providerAdmissionEpochRegressionLegacyPreserved :: !Bool
  , providerAdmissionEpochRegressionServingPermitsFresh :: !Bool
  , providerAdmissionEpochRegressionFrozenRefusesFresh :: !Bool
  , providerAdmissionEpochRegressionRevokedRefusesFresh :: !Bool
  , providerAdmissionEpochRegressionNoPendingClassified :: !Bool
  , providerAdmissionEpochRegressionOwnedPendingClassified :: !Bool
  , providerAdmissionEpochRegressionUnownedPendingClassified :: !Bool
  , providerAdmissionEpochRegressionFrozenShapeValidated :: !Bool
  , providerAdmissionEpochRegressionRevokedShapeValidated :: !Bool
  , providerAdmissionEpochRegressionInvalidGenerationRefused :: !Bool
  , providerAdmissionEpochRegressionNonCanonicalBindingRefused :: !Bool
  }
  deriving stock (Eq, Show)

-- | Closed, non-authorizing coverage for otherwise hidden retained shapes.
-- It returns booleans only and cannot yield an epoch, binding, reservation,
-- or revocation receipt.
fixedProviderAdmissionEpochRegression
  :: Either Text ProviderAdmissionEpochRegression
fixedProviderAdmissionEpochRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  (keyA, keyB) <- case freezeBindingSubmissionKeys binding of
    [firstKey, secondKey] -> Right (firstKey, secondKey)
    _ -> Left "fixed Provider admission binding has unexpected key count"
  keyC <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/c")
  generation <- firstShow (providerCredentialGeneration 1)
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  let serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          (ProviderCredentialRevocationReceipt iamDigest targetDigest)
      nonCanonicalBinding = replaceFreezeBindingKeys [keyB, keyA] binding
  pure
    ProviderAdmissionEpochRegression
      { providerAdmissionEpochRegressionLegacyPreserved =
          providerAdmissionEpochView initialLegacyProviderAdmissionEpochInternal
            == ProviderAdmissionLegacyServingUnbound
            && providerAdmissionFreshSubmissionRefusalInternal
              initialLegacyProviderAdmissionEpochInternal
              keyC
              == Nothing
      , providerAdmissionEpochRegressionServingPermitsFresh =
          providerAdmissionFreshSubmissionRefusalInternal serving keyC == Nothing
      , providerAdmissionEpochRegressionFrozenRefusesFresh =
          -- An unreserved key is fenced; the reserved one is admitted, or the
          -- freeze would fence the audit it exists to run.
          providerAdmissionFreshSubmissionRefusalInternal frozen keyC
            == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
            && providerAdmissionFreshSubmissionRefusalInternal frozen keyA == Nothing
      , providerAdmissionEpochRegressionRevokedRefusesFresh =
          -- Revocation admits nothing, including the reserved key: there is no
          -- credential left to execute it with.
          providerAdmissionFreshSubmissionRefusalInternal revoked keyC
            == Just ProviderAdmissionFreshSubmissionCredentialRevoked
            && providerAdmissionFreshSubmissionRefusalInternal revoked keyA
              == Just ProviderAdmissionFreshSubmissionCredentialRevoked
      , providerAdmissionEpochRegressionNoPendingClassified =
          classifyPending binding [] == ProviderNoPendingSubmissions
      , providerAdmissionEpochRegressionOwnedPendingClassified =
          classifyPending binding [keyA]
            == ProviderOwnedPendingSubmissions [clientSubmissionKeyText keyA]
      , providerAdmissionEpochRegressionUnownedPendingClassified =
          classifyPending binding [keyC]
            == ProviderUnownedPendingSubmissions [clientSubmissionKeyText keyC]
      , providerAdmissionEpochRegressionFrozenShapeValidated =
          validateProviderAdmissionEpochInternal frozen == Right ()
      , providerAdmissionEpochRegressionRevokedShapeValidated =
          validateProviderAdmissionEpochInternal revoked == Right ()
      , providerAdmissionEpochRegressionInvalidGenerationRefused =
          providerCredentialGeneration 0
            == Left (ProviderAdmissionCredentialGenerationInvalid 0)
      , providerAdmissionEpochRegressionNonCanonicalBindingRefused =
          validateCascadeAuditFreezeBinding nonCanonicalBinding
            == Left ProviderAdmissionFreezeExpectedSubmissionsNonCanonical
      }

fixedCascadeAuditFreezeBinding
  :: Either Text CascadeAuditFreezeBinding
fixedCascadeAuditFreezeBinding = do
  runId <- mkCleanupRunId "provider-epoch-regression"
  nodeId <- mkCleanupNodeId "provider-epoch-audit"
  operationId <- mkCleanupOperationId "provider-epoch-audit-operation"
  attemptId <- mkCleanupAttemptId "provider-epoch-audit-attempt"
  descriptorDigest <- mkCleanupDigest (Text.replicate 64 "a")
  graphDigest <- mkCleanupDigest (Text.replicate 64 "b")
  keyA <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/a")
  keyB <- first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/b")
  firstShow
    ( mkCascadeAuditFreezeBinding
        runId
        descriptorDigest
        graphDigest
        (Text.replicate 64 "e")
        nodeId
        operationId
        attemptId
        [keyA, keyB]
    )

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

freezeBindingSubmissionKeys
  :: CascadeAuditFreezeBinding -> [ClientSubmissionKey]
freezeBindingSubmissionKeys
  (CascadeAuditFreezeBinding _ _ _ _ _ _ _ submissionKeys) = submissionKeys

replaceFreezeBindingKeys
  :: [ClientSubmissionKey]
  -> CascadeAuditFreezeBinding
  -> CascadeAuditFreezeBinding
replaceFreezeBindingKeys
  submissionKeys
  (CascadeAuditFreezeBinding runId descriptor graph scope node operation attempt _) =
    CascadeAuditFreezeBinding
      runId
      descriptor
      graph
      scope
      node
      operation
      attempt
      submissionKeys

-- | Fixed transition matrix for the Sprint-4.85 freeze and generation binding.
--
-- The private constructors stay private, so the matrix is computed here and
-- exposed as decided facts. Every arm is a decision a caller could otherwise
-- get wrong in a way no type would catch: freezing without a bound generation,
-- freezing over pending work, re-freezing under a different reservation, and
-- fencing the reserved submission the freeze exists to admit.
data ProviderAdmissionFreezeRegression = ProviderAdmissionFreezeRegression
  { freezeRegressionUnboundGenerationRefused :: !Bool
  , freezeRegressionPendingWorkRefused :: !Bool
  , freezeRegressionServingFreezes :: !Bool
  , freezeRegressionIdenticalFreezeIdempotent :: !Bool
  , freezeRegressionDifferentBindingRefused :: !Bool
  , freezeRegressionRevokedRefused :: !Bool
  , freezeRegressionGenerationBindIdempotent :: !Bool
  , freezeRegressionRebindDifferentGenerationRefused :: !Bool
  , freezeRegressionFrozenAdmitsOnlyReservation :: !Bool
  }
  deriving stock (Eq, Show)

fixedProviderAdmissionFreezeRegression
  :: Either Text ProviderAdmissionFreezeRegression
fixedProviderAdmissionFreezeRegression = do
  binding <- fixedCascadeAuditFreezeBinding
  reserved <- case cascadeAuditFreezeBindingExpectedSubmissions binding of
    firstKey : _ -> Right firstKey
    [] -> Left "the fixed freeze binding reserves no submission"
  unrelated <-
    first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/unrelated")
  otherBinding <- fixedAlternateCascadeAuditFreezeBinding
  iamDigest <- mkCleanupDigest (Text.replicate 64 "c")
  targetDigest <- mkCleanupDigest (Text.replicate 64 "d")
  generation <- first (Text.pack . show) (providerCredentialGeneration 7)
  let legacy = ProviderAdmissionLegacyServingUnboundInternal
      serving = ProviderAdmissionServingInternal generation
      frozen = ProviderAdmissionCascadeAuditFrozenInternal generation binding
      revoked =
        ProviderAdmissionCascadeCredentialRevokedInternal
          generation
          binding
          (ProviderCredentialRevocationReceipt iamDigest targetDigest)
      freeze epoch pending =
        freezeProviderAdmissionForCascadeAuditInternal epoch binding pending
  pure
    ProviderAdmissionFreezeRegression
      { freezeRegressionUnboundGenerationRefused =
          freeze legacy NoPendingProviderWork
            == Left ProviderAdmissionFreezeGenerationUnbound
      , freezeRegressionPendingWorkRefused =
          freeze serving (PendingProviderWork 2)
            == Left (ProviderAdmissionFreezePendingWorkPresent 2)
      , freezeRegressionServingFreezes =
          freeze serving NoPendingProviderWork == Right frozen
      , freezeRegressionIdenticalFreezeIdempotent =
          freeze frozen NoPendingProviderWork == Right frozen
      , freezeRegressionDifferentBindingRefused =
          freezeProviderAdmissionForCascadeAuditInternal
            frozen
            otherBinding
            NoPendingProviderWork
            == Left ProviderAdmissionFreezeAlreadyFrozenDifferently
      , freezeRegressionRevokedRefused =
          freeze revoked NoPendingProviderWork
            == Left ProviderAdmissionFreezeCredentialRevoked
      , freezeRegressionGenerationBindIdempotent =
          bindProviderAdmissionServingGenerationInternal legacy 7 == Right serving
            && bindProviderAdmissionServingGenerationInternal serving 7 == Right serving
      , freezeRegressionRebindDifferentGenerationRefused =
          isLeftBind (bindProviderAdmissionServingGenerationInternal serving 8)
            && isLeftBind (bindProviderAdmissionServingGenerationInternal frozen 7)
      , freezeRegressionFrozenAdmitsOnlyReservation =
          providerAdmissionFreshSubmissionRefusalInternal frozen reserved == Nothing
            && providerAdmissionFreshSubmissionRefusalInternal frozen unrelated
              == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
      }
 where
  isLeftBind result = case result of
    Left _ -> True
    Right _ -> False

-- | A second freeze binding that differs only in its scope digest and reserved
-- submission, so "a different binding is refused" is a real comparison rather
-- than a comparison against a value that differs in every field.
fixedAlternateCascadeAuditFreezeBinding
  :: Either Text CascadeAuditFreezeBinding
fixedAlternateCascadeAuditFreezeBinding = do
  runId <- mkCleanupRunId "provider-epoch-regression"
  nodeId <- mkCleanupNodeId "provider-epoch-audit"
  operationId <- mkCleanupOperationId "provider-epoch-audit-operation"
  attemptId <- mkCleanupAttemptId "provider-epoch-audit-attempt"
  descriptorDigest <- mkCleanupDigest (Text.replicate 64 "a")
  graphDigest <- mkCleanupDigest (Text.replicate 64 "b")
  otherKey <-
    first (Text.pack . show) (mkClientSubmissionKey "provider-epoch/other")
  first
    (Text.pack . show)
    ( mkCascadeAuditFreezeBinding
        runId
        descriptorDigest
        graphDigest
        (Text.replicate 64 "f")
        nodeId
        operationId
        attemptId
        [otherKey]
    )
