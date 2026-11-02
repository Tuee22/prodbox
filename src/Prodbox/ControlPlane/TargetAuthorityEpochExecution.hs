{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Request-bounded execution of target-local epoch transitions. The
-- production interpreter owns the published epoch and fresh clock reads.
module Prodbox.ControlPlane.TargetAuthorityEpochExecution
  ( TargetEpochExecutionProgram (..)
  , TargetEpochExecutionInterpreter (..)
  , TargetEpochExecutionError (..)
  , TargetEpochMutationDisposition (..)
  , TargetEpochMutationResult (..)
  , TargetEpochObservation
  , vaultTargetEpochExecutionInterpreter
  , executeTargetAuthorityEpoch
  , observeTargetAuthorityEpoch
  , renderTargetEpochExecutionError
  )
where

import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..), authorityScopeText)
import Prodbox.ControlPlane.RequestAuthentication
  ( VerifiedControlPlaneRequest
  , verifiedRequestAuthorityEpoch
  , verifiedRequestAuthorityScope
  , verifiedRequestCalleeRole
  , verifiedRequestCallerPrincipal
  , verifiedRequestDeadline
  , verifiedRequestRoute
  )
import Prodbox.ControlPlane.RetainedAuthentication (readRetainedAuthorityEpoch)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (TargetSecretTrustInstall))
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochCodec
  ( TargetAuthorityEpochCodecError
  , decodeTargetAuthorityEpochFields
  )
import Prodbox.ControlPlane.TargetAuthorityTrustStore
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , TargetAgentIdentity
  , TargetIntentPublicKey
  , TargetIssuerKeyGeneration
  , acceptedTargetAgentIdentity
  , acceptedTargetId
  , acceptedTargetIssuerGeneration
  , acceptedTargetIssuerIdentity
  , acceptedTargetIssuerPublicKey
  , mkTargetIntentPublicKey
  , mkTargetIssuerKeyGeneration
  , targetAgentClusterIdentity
  )
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (readAuthorityManifestPublicKey)
  , vaultAuthorityManifestSigner
  )
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime)
  , runtimeRoleName
  )
import Prodbox.Vault.Session (VaultSession)
import System.Timeout (timeout)

data TargetEpochExecutionProgram result where
  ReadTargetEpochTime :: TargetEpochExecutionProgram AuthorityTime
  ReadPublishedTargetEpoch :: AuthorityTime -> TargetEpochExecutionProgram AuthorityEpoch
  ReadTargetEpochIssuer
    :: AuthorityTime -> TargetEpochExecutionProgram (TargetIssuerKeyGeneration, TargetIntentPublicKey)
  RunTargetEpochStore
    :: AuthorityTime -> TargetTrustRowProgram result -> TargetEpochExecutionProgram result

newtype TargetEpochExecutionInterpreter m = TargetEpochExecutionInterpreter
  { runTargetEpochExecutionProgram
      :: forall result. TargetEpochExecutionProgram result -> m (Either TargetEpochExecutionError result)
  }

data TargetEpochExecutionError
  = TargetEpochRequestBindingInvalid
  | TargetEpochLocalAgentMismatch
  | TargetEpochClockUnavailable
  | TargetEpochPublishedEpochUnavailable
  | TargetEpochIssuerUnavailable
  | TargetEpochIssuerMismatch
  | TargetEpochRequestEpochChanged
  | TargetEpochExecutionDeadlineReached
  | TargetEpochEffectTimedOut
  | TargetEpochStoreFailed !TargetTrustRowError
  | TargetEpochRecordCodecFailed !TargetAuthorityEpochCodecError
  | TargetEpochTransitionRefused !TargetAuthorityEpochRefusal
  | TargetEpochReadBackChanged
  deriving stock (Eq, Show)

data TargetEpochMutationDisposition
  = TargetEpochMutationAlreadyObserved
  | TargetEpochMutationApplied
  | TargetEpochMutationRecovered
  deriving stock (Eq, Show)

data TargetEpochMutationResult = TargetEpochMutationResult
  { targetEpochMutationDisposition :: !TargetEpochMutationDisposition
  , targetEpochMutationVersion :: !Natural
  , targetEpochMutationRecord :: !TargetAuthorityEpochRecord
  }
  deriving stock (Eq, Show)

type TargetEpochObservation = Maybe (Natural, TargetAuthorityEpochRecord)

vaultTargetEpochExecutionInterpreter
  :: VaultSession -> IO (Either Text AuthorityTime) -> TargetEpochExecutionInterpreter IO
vaultTargetEpochExecutionInterpreter session readTime = TargetEpochExecutionInterpreter interpret
 where
  interpret :: TargetEpochExecutionProgram result -> IO (Either TargetEpochExecutionError result)
  interpret program = case program of
    ReadTargetEpochTime -> first (const TargetEpochClockUnavailable) <$> readTime
    ReadPublishedTargetEpoch deadline -> bounded deadline $ do
      observed <- readRetainedAuthorityEpoch session
      pure
        ( either
            (const (Left TargetEpochPublishedEpochUnavailable))
            (Right . AuthorityEpoch . Genesis.authorityEpochValue)
            observed
        )
    ReadTargetEpochIssuer deadline -> bounded deadline $ do
      observed <- readAuthorityManifestPublicKey (vaultAuthorityManifestSigner session)
      pure $ do
        (generation, key) <- first (const TargetEpochIssuerUnavailable) observed
        issuer <- first (const TargetEpochIssuerUnavailable) (mkTargetIssuerKeyGeneration generation)
        public <-
          first (const TargetEpochIssuerUnavailable) (mkTargetIntentPublicKey (manifestPublicKeyBytes key))
        pure (issuer, public)
    RunTargetEpochStore deadline operation ->
      bounded
        deadline
        ( fmap
            (first TargetEpochStoreFailed)
            (runTargetTrustRowProgram (vaultTargetTrustRowInterpreter session) operation)
        )

  bounded
    :: AuthorityTime
    -> IO (Either TargetEpochExecutionError result)
    -> IO (Either TargetEpochExecutionError result)
  bounded deadline effect = do
    observed <- readTime
    case observed of
      Left _ -> pure (Left TargetEpochClockUnavailable)
      Right now
        | now >= deadline -> pure (Left TargetEpochExecutionDeadlineReached)
        | otherwise -> do
            let remaining = authorityTimeMicros deadline - authorityTimeMicros now
                micros = fromIntegral (min remaining (fromIntegral (maxBound :: Int)))
            result <- timeout micros effect
            pure (maybe (Left TargetEpochEffectTimedOut) id result)

executeTargetAuthorityEpoch
  :: (Monad m)
  => TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> TargetAuthorityEpochAction
  -> m (Either TargetEpochExecutionError TargetEpochMutationResult)
executeTargetAuthorityEpoch localAgent interpreter verified action = runExceptT $ do
  validateRequest localAgent verified
  unless (acceptedTargetAgentIdentity desired == localAgent) (throwE TargetEpochLocalAgentMismatch)
  firstObserved <- readRecord localAgent interpreter operationDeadline target
  let initialVersion = maybe 0 fst firstObserved
  initial <- case firstObserved of
    Nothing -> fromTransition (initialTargetAuthorityEpochRecord target Nothing)
    Just (_, record) -> pure record
  (published, now) <- mutationFacts operationDeadline
  next <- fromTransition (stepTargetAuthorityEpoch published now action initial)
  attempted <-
    if next == initial
      then pure Nothing
      else do
        (beforePublished, beforeNow) <- mutationFacts operationDeadline
        confirmed <- fromTransition (stepTargetAuthorityEpoch beforePublished beforeNow action initial)
        unless (confirmed == next) (throwE TargetEpochReadBackChanged)
        Just
          <$> lift
            ( runTargetEpochExecutionProgram
                interpreter
                (RunTargetEpochStore operationDeadline (CompareAndSwapTargetTrustRow target initialVersion next))
            )
  -- Closing reads may diagnose an expired preparation under this request's
  -- still-valid deadline, but the final transition check cannot grant it.
  closing <- readRecord localAgent interpreter requestDeadline target
  (version, actual) <- case closing of
    Just value -> pure value
    Nothing -> throwE (failedAttempt attempted)
  unless
    (actual == next && version >= initialVersion && (next == initial || version > initialVersion))
    (throwE (failedAttempt attempted))
  (closingPublished, closingNow) <- mutationFacts requestDeadline
  expected <- fromTransition (stepTargetAuthorityEpoch closingPublished closingNow action initial)
  unless (actual == expected) (throwE TargetEpochReadBackChanged)
  pure (TargetEpochMutationResult (disposition attempted) version actual)
 where
  preparation = actionPreparation action
  desired = targetEpochPreparationAuthority preparation
  target = acceptedTargetId desired
  requestDeadline = verifiedRequestDeadline verified
  operationDeadline = case action of
    PrepareTargetAuthorityEpoch _ -> min requestDeadline contextDeadline
    PromoteTargetAuthorityEpoch _ -> min requestDeadline contextDeadline
    RetireTargetAuthorityEpoch _ -> requestDeadline
  contextDeadline = targetEpochDeadline (targetEpochPreparationContext preparation)
  mutationFacts deadline = do
    case action of
      RetireTargetAuthorityEpoch _ -> pure ()
      PrepareTargetAuthorityEpoch _ -> confirmIssuer deadline
      PromoteTargetAuthorityEpoch _ -> confirmIssuer deadline
    readFacts interpreter verified deadline
  confirmIssuer deadline = do
    (generation, public) <-
      ExceptT (runTargetEpochExecutionProgram interpreter (ReadTargetEpochIssuer deadline))
    unless
      ( acceptedTargetIssuerGeneration desired == generation
          && acceptedTargetIssuerPublicKey desired == public
          && acceptedTargetIssuerIdentity desired == Text.pack (runtimeRoleName LifecycleAuthorityRuntime)
      )
      (throwE TargetEpochIssuerMismatch)
  fromTransition = either (throwE . TargetEpochTransitionRefused) pure
  failedAttempt attempted = case attempted of
    Just (Left err) -> err
    Just (Right ()) -> TargetEpochReadBackChanged
    Nothing -> TargetEpochReadBackChanged
  disposition attempted = case attempted of
    Nothing -> TargetEpochMutationAlreadyObserved
    Just (Right ()) -> TargetEpochMutationApplied
    Just (Left _) -> TargetEpochMutationRecovered

observeTargetAuthorityEpoch
  :: (Monad m)
  => TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> TargetSecretId
  -> m (Either TargetEpochExecutionError TargetEpochObservation)
observeTargetAuthorityEpoch localAgent interpreter verified target = runExceptT $ do
  validateRequest localAgent verified
  _ <- readFacts interpreter verified deadline
  observed <- readRecord localAgent interpreter deadline target
  _ <- readFacts interpreter verified deadline
  pure observed
 where
  deadline = verifiedRequestDeadline verified

validateRequest
  :: (Monad m)
  => TargetAgentIdentity -> VerifiedControlPlaneRequest -> ExceptT TargetEpochExecutionError m ()
validateRequest localAgent verified =
  unless
    ( verifiedRequestCallerPrincipal verified == CallerService LifecycleAuthorityRuntime
        && verifiedRequestCalleeRole verified == TargetSecretAgentRuntime
        && verifiedRequestRoute verified == TargetSecretTrustInstall
        && authorityScopeText (verifiedRequestAuthorityScope verified) == targetAgentClusterIdentity localAgent
    )
    (throwE TargetEpochRequestBindingInvalid)

readFacts
  :: (Monad m)
  => TargetEpochExecutionInterpreter m
  -> VerifiedControlPlaneRequest
  -> AuthorityTime
  -> ExceptT TargetEpochExecutionError m (AuthorityEpoch, AuthorityTime)
readFacts interpreter verified deadline = do
  published <-
    ExceptT (runTargetEpochExecutionProgram interpreter (ReadPublishedTargetEpoch deadline))
  now <- ExceptT (runTargetEpochExecutionProgram interpreter ReadTargetEpochTime)
  unless
    (now < deadline && now < verifiedRequestDeadline verified)
    (throwE TargetEpochExecutionDeadlineReached)
  unless
    (published == AuthorityEpoch (Genesis.authorityEpochValue (verifiedRequestAuthorityEpoch verified)))
    (throwE TargetEpochRequestEpochChanged)
  pure (published, now)

readRecord
  :: (Monad m)
  => TargetAgentIdentity
  -> TargetEpochExecutionInterpreter m
  -> AuthorityTime
  -> TargetSecretId
  -> ExceptT TargetEpochExecutionError m TargetEpochObservation
readRecord localAgent interpreter deadline target = do
  observed <-
    ExceptT
      ( runTargetEpochExecutionProgram
          interpreter
          (RunTargetEpochStore deadline (ReadTargetTrustRow target))
      )
  case observed of
    Nothing -> pure Nothing
    Just (version, fields) -> do
      unless (version > 0) (throwE TargetEpochReadBackChanged)
      record <-
        either (throwE . TargetEpochRecordCodecFailed) pure (decodeTargetAuthorityEpochFields target fields)
      unless (all sameCluster (recordAuthorities record)) (throwE TargetEpochLocalAgentMismatch)
      pure (Just (version, record))
 where
  sameCluster accepted =
    targetAgentClusterIdentity (acceptedTargetAgentIdentity accepted)
      == targetAgentClusterIdentity localAgent

recordAuthorities :: TargetAuthorityEpochRecord -> [AcceptedTargetAuthority]
recordAuthorities record = maybe [] pure (targetEpochRecordActive record) <> pending
 where
  pending = case targetEpochRecordTransition record of
    TargetEpochNoTransition -> []
    TargetEpochPrepared preparation -> [targetEpochPreparationAuthority preparation]
    TargetEpochPromoted preparation -> [targetEpochPreparationAuthority preparation]
    TargetEpochRetired preparation -> [targetEpochPreparationAuthority preparation]

actionPreparation :: TargetAuthorityEpochAction -> TargetAuthorityEpochPreparation
actionPreparation action = case action of
  PrepareTargetAuthorityEpoch preparation -> preparation
  PromoteTargetAuthorityEpoch preparation -> preparation
  RetireTargetAuthorityEpoch preparation -> preparation

renderTargetEpochExecutionError :: TargetEpochExecutionError -> Text
renderTargetEpochExecutionError err = case err of
  TargetEpochRequestBindingInvalid -> "request-binding-invalid"
  TargetEpochLocalAgentMismatch -> "local-agent-mismatch"
  TargetEpochClockUnavailable -> "clock-unavailable"
  TargetEpochPublishedEpochUnavailable -> "published-epoch-unavailable"
  TargetEpochIssuerUnavailable -> "issuer-unavailable"
  TargetEpochIssuerMismatch -> "issuer-mismatch"
  TargetEpochRequestEpochChanged -> "request-epoch-changed"
  TargetEpochExecutionDeadlineReached -> "request-deadline-reached"
  TargetEpochEffectTimedOut -> "effect-timed-out"
  TargetEpochStoreFailed _ -> "store-unavailable"
  TargetEpochRecordCodecFailed _ -> "record-invalid"
  TargetEpochTransitionRefused refusal -> renderTargetAuthorityEpochRefusal refusal
  TargetEpochReadBackChanged -> "readback-changed"
