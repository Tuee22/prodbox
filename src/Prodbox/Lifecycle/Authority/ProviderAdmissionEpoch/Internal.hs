{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Package-private retained state for the Lifecycle Provider admission
-- epoch. The public facade exposes only read-only views and fixed diagnostics.
-- In particular, this module deliberately exports no serving-generation,
-- freeze, reservation, or revocation constructor. A future Cascade freeze
-- must atomically retain an opaque terminal-audit reservation; no such
-- capability exists yet.
module Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal
  ( ProviderAdmissionEpoch
  , ProviderAdmissionEpochView (..)
  , ProviderAdmissionEpochError (..)
  , ProviderAdmissionFreshSubmissionRefusal (..)
  , providerAdmissionEpochView
  , initialLegacyProviderAdmissionEpochInternal
  , validateProviderAdmissionEpochInternal
  , providerAdmissionFreshSubmissionRefusalInternal
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

providerAdmissionFreshSubmissionRefusalInternal
  :: ProviderAdmissionEpoch
  -> Maybe ProviderAdmissionFreshSubmissionRefusal
providerAdmissionFreshSubmissionRefusalInternal epoch = case epoch of
  ProviderAdmissionLegacyServingUnboundInternal -> Nothing
  ProviderAdmissionServingInternal _ -> Nothing
  ProviderAdmissionCascadeAuditFrozenInternal {} ->
    Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
  ProviderAdmissionCascadeCredentialRevokedInternal {} ->
    Just ProviderAdmissionFreshSubmissionCredentialRevoked

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
              == Nothing
      , providerAdmissionEpochRegressionServingPermitsFresh =
          providerAdmissionFreshSubmissionRefusalInternal serving == Nothing
      , providerAdmissionEpochRegressionFrozenRefusesFresh =
          providerAdmissionFreshSubmissionRefusalInternal frozen
            == Just ProviderAdmissionFreshSubmissionCascadeAuditFrozen
      , providerAdmissionEpochRegressionRevokedRefusesFresh =
          providerAdmissionFreshSubmissionRefusalInternal revoked
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
