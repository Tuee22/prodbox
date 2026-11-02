{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle Authority issuance of the secret-free, signed intent consumed
-- by an attested one-shot Target worker.
--
-- The caller cannot supply an epoch, owner nonce, fencing token, deadline, or
-- sink coordinate.  Those values are recovered from the exact durable
-- prepared outbox intent and the current Authority epoch.  The private signing
-- key remains in Vault Transit; the result contains only the signed intent and
-- the public trust record that the selected Agent must CAS-install/read back
-- before a worker may start.
module Prodbox.ControlPlane.TargetIntentAuthority
  ( TargetIntentIssueRequest (..)
  , AuthorizedPreparedTargetIntent
  , mkAuthorizedPreparedTargetIntent
  , authorizedPreparedTargetIntentFromLegacy
  , TargetIntentIssuerBoundary (..)
  , TargetIntentWriter (..)
  , TargetIntentAdmissionObservation (..)
  , TargetIntentIssuanceAdmission
  , issuedTargetAdmission
  , recheckTargetIntentIssuance
  , issueAdmittedTargetWorkerExecutionPermit
  , TargetIntentIssueError (..)
  , IssuedTargetIntent
  , issuedTargetSignedIntent
  , issuedTargetAcceptedAuthority
  , issueTargetCommittedIntent
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ServiceSessionJournal (ServiceSessionBinding)
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  , compiledTargetSecretSink
  , targetSecretIdToken
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( AcceptedTargetAuthority
  , SignedTargetCommittedIntent
  , TargetAgentIdentity
  , TargetAgentRolloutEvidence
  , TargetCommittedIntentSpec (..)
  , acceptedTargetAgentIdentity
  , attachTargetCommittedIntentSignature
  , mkAcceptedTargetAuthority
  , mkTargetIntentPublicKey
  , mkTargetIssuerKeyGeneration
  , mkUnsignedTargetCommittedIntent
  , signedTargetCommittedIntentSpec
  , targetCommittedIntentSigningPayload
  , verifySignedTargetCommittedIntent
  )
import Prodbox.ControlPlane.TargetSecretWorker (TargetWorkerAttestation)
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( SignedTargetWorkerExecutionPermit
  , TargetWorkerExecutionPermitError
  , issueTargetWorkerExecutionPermit
  )
import Prodbox.Lifecycle.Authority.AdmissionGate (AuthoritySubmissionGateRefusal)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest (manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , FencingToken
  , OwnerNonce
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetCommitDisposition (TargetCommitPrepared)
  , TargetCommitIntent
  , TargetValueDigest
  , targetCommitDeadline
  , targetCommitDigest
  , targetCommitDisposition
  , targetCommitFencingToken
  , targetCommitGeneration
  , targetCommitOwnerNonce
  , targetCommitTargetIdentity
  )

-- | Caller-selected identity only.  Every authority-bearing field is loaded
-- from the retained outbox.  Expected generation/digest make a replay against
-- a later prepared intent fail rather than silently authorizing that intent.
data TargetIntentIssueRequest = TargetIntentIssueRequest
  { targetIntentIssueTarget :: !TargetSecretId
  , targetIntentIssueExpectedAgentIdentity :: !TargetAgentIdentity
  , targetIntentIssueExpectedGeneration :: !CredentialGeneration
  , targetIntentIssueExpectedReceiptDigest :: !TargetValueDigest
  , targetIntentIssueOperationId :: !Text
  , targetIntentIssueActionIndex :: !Natural
  , targetIntentIssueIdempotencyKey :: !Text
  }
  deriving stock (Eq, Show)

-- | A durable, secret-free outbox authorization normalized across legacy
-- target projections and retained-material aggregates.  Construction requires
-- already-typed lease identity/fence values; callers cannot smuggle physical
-- sink coordinates because those are selected from 'TargetSecretId' only.
data AuthorizedPreparedTargetIntent = AuthorizedPreparedTargetIntent
  { authorizedPreparedOwnerNonce :: !OwnerNonce
  , authorizedPreparedFencingToken :: !FencingToken
  , authorizedPreparedTargetAgentIdentity :: !TargetAgentIdentity
  , authorizedPreparedTarget :: !TargetSecretId
  , authorizedPreparedGeneration :: !CredentialGeneration
  , authorizedPreparedReceiptDigest :: !TargetValueDigest
  , authorizedPreparedDeadline :: !AuthorityTime
  }
  deriving stock (Eq, Show)

mkAuthorizedPreparedTargetIntent
  :: OwnerNonce
  -> FencingToken
  -> TargetAgentIdentity
  -> TargetSecretId
  -> CredentialGeneration
  -> TargetValueDigest
  -> AuthorityTime
  -> Either Text AuthorizedPreparedTargetIntent
mkAuthorizedPreparedTargetIntent owner fence agentIdentity target generation digest deadline
  | authorityTimeMicros deadline == 0 = Left "prepared Target intent deadline is invalid"
  | otherwise =
      Right
        AuthorizedPreparedTargetIntent
          { authorizedPreparedOwnerNonce = owner
          , authorizedPreparedFencingToken = fence
          , authorizedPreparedTargetAgentIdentity = agentIdentity
          , authorizedPreparedTarget = target
          , authorizedPreparedGeneration = generation
          , authorizedPreparedReceiptDigest = digest
          , authorizedPreparedDeadline = deadline
          }

authorizedPreparedTargetIntentFromLegacy
  :: TargetAgentIdentity
  -> Text
  -> TargetSecretId
  -> TargetCommitIntent
  -> Either Text AuthorizedPreparedTargetIntent
authorizedPreparedTargetIntentFromLegacy agentIdentity legacyIdentity target intent
  | targetCommitDisposition intent /= TargetCommitPrepared =
      Left "legacy Target intent is not prepared"
  | targetCommitTargetIdentity intent /= legacyIdentity =
      Left "legacy Target intent identity does not match its registered cluster"
  | otherwise =
      mkAuthorizedPreparedTargetIntent
        (targetCommitOwnerNonce intent)
        (targetCommitFencingToken intent)
        agentIdentity
        target
        (targetCommitGeneration intent)
        (targetCommitDigest intent)
        (targetCommitDeadline intent)

data TargetIntentWriter
  = TargetIntentLegacyWriter
  | TargetIntentAuthorityWriter
  | TargetIntentGenesisBackupWriter
  | TargetIntentBackupRepairWriter
  deriving stock (Eq, Show)

data TargetIntentAdmissionObservation
  = TargetIntentAdmissionReady !TargetIntentWriter !AuthorityEpoch
  | TargetIntentAdmissionRefused !AuthoritySubmissionGateRefusal
  deriving stock (Eq, Show)

-- | One locally sampled admission decision. It is not serializable and grants
-- no external effect permission; the issuer re-observes it around every stage.
data TargetIntentIssuanceAdmission
  = TargetIntentIssuanceAdmission
      !TargetIntentWriter
      !AuthorityEpoch
      !TargetIntentIssueRequest
  deriving stock (Eq, Show)

issuanceEpoch :: TargetIntentIssuanceAdmission -> AuthorityEpoch
issuanceEpoch (TargetIntentIssuanceAdmission _ epoch _) = epoch

data TargetIntentIssuerBoundary m = TargetIntentIssuerBoundary
  { readTargetIntentAuthorityAdmission
      :: TargetIntentIssueRequest -> m (Either Text TargetIntentAdmissionObservation)
  , readTargetIntentAuthorityTime :: m (Either Text AuthorityTime)
  , readAuthorizedPreparedTargetIntent
      :: TargetIntentIssueRequest
      -> m (Either Text AuthorizedPreparedTargetIntent)
  , targetIntentAuthoritySigner :: !(AuthorityManifestSigner m)
  , targetIntentAuthorityIssuerIdentity :: !Text
  , installIssuedTargetAuthority
      :: TargetSecretId
      -> AcceptedTargetAuthority
      -> m (Either Text AcceptedTargetAuthority)
  }

data TargetIntentIssueError
  = TargetIntentIssuePreparedIntentUnavailable !Text
  | TargetIntentIssueTargetUnregistered !Text
  | TargetIntentIssueTargetMismatch !Text !Text
  | TargetIntentIssueAgentIdentityMismatch !TargetAgentIdentity !TargetAgentIdentity
  | TargetIntentIssueNotPrepared
  | TargetIntentIssueGenerationMismatch
  | TargetIntentIssueReceiptDigestMismatch
  | TargetIntentIssueClockUnavailable !Text
  | TargetIntentIssueDeadlineReached
  | TargetIntentIssueAdmissionUnavailable !Text
  | TargetIntentIssueAdmissionClosed !AuthoritySubmissionGateRefusal
  | TargetIntentIssueAdmissionChanged
  | TargetIntentIssueAdmissionInvalid
  | TargetIntentIssueExecutionPermitFailed !TargetWorkerExecutionPermitError
  | TargetIntentIssueSignerUnavailable !Text
  | TargetIntentIssueSignerGenerationChanged !Natural !Natural
  | TargetIntentIssueValueInvalid !Text
  | TargetIntentIssueSignatureInvalid !Text
  | TargetIntentIssueTrustInstallUnavailable !Text
  | TargetIntentIssueTrustReadBackMismatch
  deriving stock (Eq, Show)

data IssuedTargetIntent = IssuedTargetIntent
  { issuedTargetSignedIntent :: !SignedTargetCommittedIntent
  , issuedTargetAcceptedAuthority :: !AcceptedTargetAuthority
  , issuedTargetAdmission :: !TargetIntentIssuanceAdmission
  }

issueTargetCommittedIntent
  :: (Monad m)
  => TargetIntentIssuerBoundary m
  -> TargetIntentIssueRequest
  -> m (Either TargetIntentIssueError IssuedTargetIntent)
issueTargetCommittedIntent boundary request = do
  admissionResult <- readIssuanceAdmission boundary request
  case admissionResult of
    Left err -> pure (Left err)
    Right admission -> do
      preparedResult <- readAuthorizedPreparedTargetIntent boundary request
      case preparedResult of
        Left detail -> pure (Left (TargetIntentIssuePreparedIntentUnavailable detail))
        Right prepared -> case validatePrepared prepared of
          Left err -> pure (Left err)
          Right () -> do
            nowResult <- readTargetIntentAuthorityTime boundary
            case nowResult of
              Left detail -> pure (Left (TargetIntentIssueClockUnavailable detail))
              Right now
                | authorityTimeMicros now >= authorityTimeMicros (authorizedPreparedDeadline prepared) ->
                    pure (Left TargetIntentIssueDeadlineReached)
                | otherwise -> signPrepared now admission prepared
 where
  validatePrepared intent
    | authorizedPreparedTarget intent /= targetIntentIssueTarget request =
        Left
          ( TargetIntentIssueTargetMismatch
              (targetSecretIdToken (targetIntentIssueTarget request))
              (targetSecretIdToken (authorizedPreparedTarget intent))
          )
    | authorizedPreparedTargetAgentIdentity intent
        /= targetIntentIssueExpectedAgentIdentity request =
        Left
          ( TargetIntentIssueAgentIdentityMismatch
              (targetIntentIssueExpectedAgentIdentity request)
              (authorizedPreparedTargetAgentIdentity intent)
          )
    | authorizedPreparedGeneration intent /= targetIntentIssueExpectedGeneration request =
        Left TargetIntentIssueGenerationMismatch
    | authorizedPreparedReceiptDigest intent /= targetIntentIssueExpectedReceiptDigest request =
        Left TargetIntentIssueReceiptDigestMismatch
    | otherwise = Right ()

  signPrepared now admission prepared =
    case compiledTargetSecretSink (targetIntentIssueTarget request) of
      Left detail -> pure (Left (TargetIntentIssueTargetUnregistered detail))
      Right sink -> do
        publicResult <-
          readAuthorityManifestPublicKey (targetIntentAuthoritySigner boundary)
        case publicResult of
          Left detail -> pure (Left (TargetIntentIssueSignerUnavailable detail))
          Right (publicGeneration, manifestPublic) ->
            case buildUnsigned publicGeneration manifestPublic (issuanceEpoch admission) sink prepared of
              Left err -> pure (Left err)
              Right (accepted, unsigned) -> do
                allowed <- recheckTargetIntentIssuance boundary admission (authorizedPreparedDeadline prepared)
                signedResult <- case allowed of
                  Left err -> pure (Left err)
                  Right () ->
                    fmap
                      ( either
                          (Left . TargetIntentIssueSignerUnavailable)
                          (validateSigned now sink publicGeneration accepted unsigned)
                      )
                      ( signAuthorityManifestPayload
                          (targetIntentAuthoritySigner boundary)
                          (targetCommittedIntentSigningPayload unsigned)
                      )
                case signedResult of
                  Left err -> pure (Left err)
                  Right signed -> do
                    stillAllowed <- recheckTargetIntentIssuance boundary admission (authorizedPreparedDeadline prepared)
                    installedResult <- case stillAllowed of
                      Left err -> pure (Left err)
                      Right () ->
                        fmap
                          (either (Left . TargetIntentIssueTrustInstallUnavailable) Right)
                          (installIssuedTargetAuthority boundary (targetIntentIssueTarget request) accepted)
                    case installedResult of
                      Left err -> pure (Left err)
                      Right readBack
                        | readBack == accepted -> do
                            finalAdmission <-
                              recheckTargetIntentIssuance boundary admission (authorizedPreparedDeadline prepared)
                            pure $
                              IssuedTargetIntent
                                { issuedTargetSignedIntent = signed
                                , issuedTargetAcceptedAuthority = readBack
                                , issuedTargetAdmission = admission
                                }
                                <$ finalAdmission
                        | otherwise -> pure (Left TargetIntentIssueTrustReadBackMismatch)
  validateSigned now sink publicGeneration accepted unsigned (signatureGeneration, signature) = do
    if signatureGeneration == publicGeneration
      then Right ()
      else
        Left
          ( TargetIntentIssueSignerGenerationChanged
              publicGeneration
              signatureGeneration
          )
    signed <-
      mapValueError
        (attachTargetCommittedIntentSignature unsigned signature)
    _ <-
      mapSignatureError
        ( verifySignedTargetCommittedIntent
            accepted
            now
            (acceptedTargetAgentIdentity accepted)
            sink
            signed
        )
    Right signed
  buildUnsigned publicGeneration manifestPublic epoch sink prepared = do
    issuerGeneration <-
      mapValueError (mkTargetIssuerKeyGeneration publicGeneration)
    publicKey <-
      mapSigningKeyError
        (mkTargetIntentPublicKey (manifestPublicKeyBytes manifestPublic))
    accepted <-
      mapAcceptedError
        ( mkAcceptedTargetAuthority
            issuerGeneration
            (targetIntentAuthorityIssuerIdentity boundary)
            publicKey
            epoch
            (authorizedPreparedFencingToken prepared)
            (authorizedPreparedTargetAgentIdentity prepared)
            sink
        )
    unsigned <-
      mapValueError
        ( mkUnsignedTargetCommittedIntent
            TargetCommittedIntentSpec
              { targetIntentIssuerGeneration = issuerGeneration
              , targetIntentIssuerIdentity = targetIntentAuthorityIssuerIdentity boundary
              , targetIntentAuthorityEpoch = epoch
              , targetIntentOperationId = targetIntentIssueOperationId request
              , targetIntentActionIndex = targetIntentIssueActionIndex request
              , targetIntentCommitReceiptDigest = authorizedPreparedReceiptDigest prepared
              , targetIntentOwnerNonce = authorizedPreparedOwnerNonce prepared
              , targetIntentFencingToken = authorizedPreparedFencingToken prepared
              , targetIntentAgentIdentity = authorizedPreparedTargetAgentIdentity prepared
              , targetIntentSink = sink
              , targetIntentGeneration = authorizedPreparedGeneration prepared
              , targetIntentDeadline = authorizedPreparedDeadline prepared
              , targetIntentIdempotencyKey = targetIntentIssueIdempotencyKey request
              }
        )
    Right (accepted, unsigned)

readIssuanceAdmission
  :: (Monad m)
  => TargetIntentIssuerBoundary m
  -> TargetIntentIssueRequest
  -> m (Either TargetIntentIssueError TargetIntentIssuanceAdmission)
readIssuanceAdmission boundary request = do
  observed <- readTargetIntentAuthorityAdmission boundary request
  pure $ case observed of
    Left detail -> Left (TargetIntentIssueAdmissionUnavailable detail)
    Right (TargetIntentAdmissionRefused refusal) -> Left (TargetIntentIssueAdmissionClosed refusal)
    Right (TargetIntentAdmissionReady writer epoch@(AuthorityEpoch value))
      | value == 0 -> Left TargetIntentIssueAdmissionInvalid
      | otherwise -> Right (TargetIntentIssuanceAdmission writer epoch request)

-- | These observations do not replace durable outbox/worker quiescence. They
-- prevent a closed or changed admission from releasing newly signed material;
-- an already in-flight effect still belongs to its original retained owner.
recheckTargetIntentIssuance
  :: (Monad m)
  => TargetIntentIssuerBoundary m
  -> TargetIntentIssuanceAdmission
  -> AuthorityTime
  -> m (Either TargetIntentIssueError ())
recheckTargetIntentIssuance boundary expected@(TargetIntentIssuanceAdmission _ _ request) deadline = do
  observed <- readIssuanceAdmission boundary request
  case observed of
    Left err -> pure (Left err)
    Right actual
      | actual /= expected -> pure (Left TargetIntentIssueAdmissionChanged)
      | otherwise -> do
          time <- readTargetIntentAuthorityTime boundary
          pure $ case time of
            Left detail -> Left (TargetIntentIssueClockUnavailable detail)
            Right now
              | authorityTimeMicros now >= authorityTimeMicros deadline -> Left TargetIntentIssueDeadlineReached
              | otherwise -> Right ()

-- | The attested worker permit is a second signature, and must independently
-- recheck the same admission before and after its signer. Reissuing the initial
-- intent alone does not fence this later signing interval.
issueAdmittedTargetWorkerExecutionPermit
  :: (Monad m)
  => TargetIntentIssuerBoundary m
  -> IssuedTargetIntent
  -> TargetAgentRolloutEvidence
  -> TargetWorkerAttestation
  -> ServiceSessionBinding
  -> m (Either TargetIntentIssueError SignedTargetWorkerExecutionPermit)
issueAdmittedTargetWorkerExecutionPermit boundary issued rollout attestation binding = do
  allowed <- recheckTargetIntentIssuance boundary admission deadline
  case allowed of
    Left err -> pure (Left err)
    Right () -> do
      permitted <-
        issueTargetWorkerExecutionPermit
          (targetIntentAuthoritySigner boundary)
          (issuedTargetAcceptedAuthority issued)
          rollout
          attestation
          binding
      case permitted of
        Left err -> pure (Left (TargetIntentIssueExecutionPermitFailed err))
        Right permit -> do
          stillAllowed <- recheckTargetIntentIssuance boundary admission deadline
          pure (permit <$ stillAllowed)
 where
  admission = issuedTargetAdmission issued
  deadline = targetIntentDeadline (signedTargetCommittedIntentSpec (issuedTargetSignedIntent issued))

mapValueError :: (Show err) => Either err value -> Either TargetIntentIssueError value
mapValueError = either (Left . TargetIntentIssueValueInvalid . Text.pack . show) Right

mapSigningKeyError :: (Show err) => Either err value -> Either TargetIntentIssueError value
mapSigningKeyError = either (Left . TargetIntentIssueValueInvalid . Text.pack . show) Right

mapAcceptedError :: (Show err) => Either err value -> Either TargetIntentIssueError value
mapAcceptedError = either (Left . TargetIntentIssueValueInvalid . Text.pack . show) Right

mapSignatureError :: (Show err) => Either err value -> Either TargetIntentIssueError value
mapSignatureError = either (Left . TargetIntentIssueSignatureInvalid . Text.pack . show) Right
